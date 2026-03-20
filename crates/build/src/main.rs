use clap::{Parser, Subcommand};
use eyre::{Result, WrapErr, bail};
use std::path::{Path, PathBuf};

/// Workspace root, injected at compile time via `.cargo/config.toml`.
const WORKSPACE_ROOT: &str = env!("DSQLD_WORKSPACE_ROOT");

#[derive(Debug, Parser)]
#[command(
    name = "dsqld-build",
    about = "Dagger-based image builder for temporal-dsql"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Debug, Subcommand)]
enum Commands {
    /// Build temporal-dsql-server and temporal-dsql-tool images via Dagger.
    ///
    /// Compiles Go binaries from the temporal-dsql repo and produces two
    /// Docker images: a server image with runtime config and a minimal
    /// tool-only image.
    Temporal {
        /// Path to the temporal-dsql repository.
        /// Defaults to TEMPORAL_DSQL_PATH env var, then ../temporal-dsql.
        #[arg(long, env = "TEMPORAL_DSQL_PATH")]
        source: Option<PathBuf>,

        /// Target architecture (arm64 or amd64).
        #[arg(long, default_value = "arm64")]
        arch: String,
    },
}

fn main() -> Result<()> {
    color_eyre::install()?;
    let cli = Cli::parse();
    match cli.command {
        Commands::Temporal { source, arch } => {
            let source = resolve_temporal_dsql_path(source)?;
            build_temporal(&source, &arch)
        }
    }
}

/// Resolve the temporal-dsql repo path: explicit arg > env var > ../temporal-dsql.
pub fn resolve_temporal_dsql_path(explicit: Option<PathBuf>) -> Result<PathBuf> {
    let path = explicit.unwrap_or_else(|| Path::new(WORKSPACE_ROOT).join("../temporal-dsql"));
    let resolved = path.canonicalize().wrap_err_with(|| {
        format!(
            "temporal-dsql repo not found at '{}'. \
             Set --source or TEMPORAL_DSQL_PATH.",
            path.display()
        )
    })?;
    if !resolved.join("go.mod").exists() {
        bail!(
            "'{}' does not look like a Go repo (no go.mod found)",
            resolved.display()
        );
    }
    Ok(resolved)
}

/// Extract Go version from go.mod (e.g. "go 1.24.3" → "1.24").
pub fn go_version_from_mod(source: &Path) -> Result<String> {
    let go_mod =
        std::fs::read_to_string(source.join("go.mod")).wrap_err("Failed to read go.mod")?;
    for line in go_mod.lines() {
        if let Some(rest) = line.strip_prefix("go ") {
            return normalize_go_version(rest.trim());
        }
    }
    bail!("Could not find 'go' directive in go.mod")
}

fn normalize_go_version(version: &str) -> Result<String> {
    let parts: Vec<&str> = version.split('.').collect();
    match parts.len() {
        0 => bail!("invalid Go version in go.mod: '{version}'"),
        1 => Ok(parts[0].to_string()),
        _ => Ok(format!("{}.{}", parts[0], parts[1])),
    }
}

/// Resolve the docker directory relative to the workspace root.
fn docker_dir() -> PathBuf {
    Path::new(WORKSPACE_ROOT).join("docker")
}

fn build_temporal(source: &Path, arch: &str) -> Result<()> {
    let go_version = go_version_from_mod(source)?;
    let go_image = format!("golang:{go_version}-alpine");
    let docker = docker_dir();

    eprintln!("Building temporal-dsql images");
    eprintln!("  source: {}", source.display());
    eprintln!("  arch:   linux/{arch}");
    eprintln!("  go:     {go_image}");
    eprintln!();

    let client = dagger_client::Client::from_env()?;

    // ── Stage 1: Compile Go binaries ────────────────────────
    eprintln!("Stage 1/3: Compiling Go binaries ({go_image}) …");

    let source_str = source
        .to_str()
        .ok_or_else(|| eyre::eyre!("source path is not valid UTF-8"))?;
    let source_dir = client.host_directory(source_str)?;

    let builder = client
        .container_from(&go_image)?
        .with_exec(&["apk", "add", "--no-cache", "make", "git", "gcc", "musl-dev"])?
        .with_directory("/src", &source_dir)?
        .with_workdir("/src")?
        .with_env_variable("CGO_ENABLED", "0")?
        .with_env_variable("GOOS", "linux")?
        .with_env_variable("GOARCH", arch)?
        .with_exec(&[
            "go",
            "build",
            "-tags",
            "disable_grpc_modules",
            "-o",
            "temporal-server",
            "./cmd/server",
        ])?
        .with_exec(&[
            "go",
            "build",
            "-tags",
            "disable_grpc_modules",
            "-o",
            "temporal-dsql-tool",
            "./cmd/tools/dsql",
        ])?
        .with_exec(&[
            "go",
            "build",
            "-tags",
            "disable_grpc_modules",
            "-o",
            "temporal-elasticsearch-tool",
            "./cmd/tools/elasticsearch",
        ])?;

    let server_bin = builder.file("/src/temporal-server")?;
    let tool_bin = builder.file("/src/temporal-dsql-tool")?;
    let es_tool_bin = builder.file("/src/temporal-elasticsearch-tool")?;

    // ── Stage 2: Build temporal-dsql:latest (base) ─────────
    eprintln!("Stage 2/4: Building temporal-dsql:latest …");

    let base = client
        .container_from("alpine:3.23")?
        .with_exec(&[
            "sh",
            "-c",
            "apk add --no-cache ca-certificates tzdata curl python3 bash aws-cli \
             && addgroup -g 1000 temporal \
             && adduser -u 1000 -G temporal -D temporal",
        ])?
        .with_workdir("/etc/temporal")?
        .with_env_variable("TEMPORAL_HOME", "/etc/temporal")?
        .with_exec(&["mkdir", "-p", "/etc/temporal/config/dynamicconfig"])?
        .with_exec(&["chown", "-R", "temporal:temporal", "/etc/temporal"])?
        .with_file("/usr/local/bin/temporal-server", &server_bin)?
        .with_file("/usr/local/bin/temporal-dsql-tool", &tool_bin)?
        .with_file("/usr/local/bin/temporal-elasticsearch-tool", &es_tool_bin)?
        .with_new_file(
            "/etc/temporal/entrypoint.sh",
            "#!/bin/sh\nset -eu\nexec /usr/local/bin/temporal-server \"$@\"\n",
        )?
        .with_exec(&["chmod", "+x", "/etc/temporal/entrypoint.sh"])?
        .with_user("temporal")?
        .with_entrypoint(&["/etc/temporal/entrypoint.sh"])?
        .with_default_args(&[
            "--config-file",
            "/etc/temporal/config/development-dsql.yaml",
            "--allow-no-auth",
            "start",
        ])?;

    base.export_image("temporal-dsql:latest")?;
    eprintln!("  ✓ temporal-dsql:latest");

    // ── Stage 3: Layer runtime config → temporal-dsql-server:latest ──
    eprintln!("Stage 3/4: Building temporal-dsql-server:latest …");

    let docker_str = docker
        .to_str()
        .ok_or_else(|| eyre::eyre!("docker directory path is not valid UTF-8"))?;
    let docker_config = client.host_directory(docker_str)?;

    // Continue from the base container (not `from()` — local images
    // aren't visible to the Dagger engine).
    let server = base
        .with_user("root")?
        .with_file(
            "/etc/temporal/config/persistence-dsql-elasticsearch.template.yaml",
            &docker_config.file("config/persistence-dsql-elasticsearch.template.yaml")?,
        )?
        .with_file(
            "/usr/local/bin/render-and-start.sh",
            &docker_config.file("render-and-start.sh")?,
        )?
        .with_exec(&["chmod", "+x", "/usr/local/bin/render-and-start.sh"])?
        .with_user("temporal")?
        .with_entrypoint(&["/usr/local/bin/render-and-start.sh"])?
        .with_default_args(&[])?;

    server.export_image("temporal-dsql-server:latest")?;
    eprintln!("  ✓ temporal-dsql-server:latest");

    // ── Stage 4: Build temporal-dsql-tool:latest ────────────
    eprintln!("Stage 4/4: Building temporal-dsql-tool:latest …");

    let tool = client
        .container_from("alpine:3.23")?
        .with_exec(&[
            "sh",
            "-c",
            "apk add --no-cache ca-certificates tzdata \
             && addgroup -g 1000 temporal \
             && adduser -u 1000 -G temporal -D temporal",
        ])?
        .with_file("/usr/local/bin/temporal-dsql-tool", &tool_bin)?
        .with_user("temporal")?
        .with_entrypoint(&["/usr/local/bin/temporal-dsql-tool"])?
        .with_default_args(&[])?;

    tool.export_image("temporal-dsql-tool:latest")?;
    eprintln!("  ✓ temporal-dsql-tool:latest");

    eprintln!();
    eprintln!("✓ Temporal images built:");
    eprintln!("  temporal-dsql:latest         (linux/{arch})");
    eprintln!("  temporal-dsql-server:latest   (linux/{arch})");
    eprintln!("  temporal-dsql-tool:latest     (linux/{arch})");

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_test_dir(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(name);
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("create temp test directory");
        path
    }

    #[test]
    fn resolve_temporal_dsql_path_accepts_explicit_valid_repo() {
        let dir = make_test_dir("dsqld-build-test-valid-repo");
        std::fs::write(dir.join("go.mod"), "module example\n\ngo 1.24.3\n").expect("write go.mod");

        let resolved = resolve_temporal_dsql_path(Some(dir.clone())).expect("valid repo");
        assert_eq!(
            resolved,
            dir.canonicalize().expect("canonicalize temp repo path")
        );

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn resolve_temporal_dsql_path_rejects_missing_go_mod() {
        let dir = make_test_dir("dsqld-build-test-missing-gomod");

        let err = resolve_temporal_dsql_path(Some(dir.clone())).expect_err("should fail");
        let msg = err.to_string();
        assert!(msg.contains("no go.mod found"));

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn go_version_from_mod_extracts_major_minor() {
        let dir = make_test_dir("dsqld-build-test-go-version");
        std::fs::write(dir.join("go.mod"), "module example\n\ngo 1.24.3\n").expect("write go.mod");

        let version = go_version_from_mod(&dir).expect("extract go version");
        assert_eq!(version, "1.24");

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn go_version_from_mod_errors_without_go_directive() {
        let dir = make_test_dir("dsqld-build-test-go-missing-directive");
        std::fs::write(dir.join("go.mod"), "module example\n").expect("write go.mod");

        let err = go_version_from_mod(&dir).expect_err("missing go directive should fail");
        assert!(err.to_string().contains("Could not find 'go' directive"));

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn normalize_go_version_handles_minor_only_and_patch_versions() {
        assert_eq!(normalize_go_version("1.24").expect("parse"), "1.24");
        assert_eq!(normalize_go_version("1.24.3").expect("parse"), "1.24");
        assert_eq!(normalize_go_version("1").expect("parse"), "1");
    }
}
