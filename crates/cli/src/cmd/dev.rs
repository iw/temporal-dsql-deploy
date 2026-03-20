use clap::Subcommand;
use eyre::Result;

use crate::{exec, paths};

#[derive(Debug, Subcommand)]
pub enum DevAction {
    /// Start dev stack
    Up {
        /// Run in background
        #[arg(short, long)]
        detach: bool,
    },
    /// Stop dev stack
    Down {
        /// Remove volumes
        #[arg(short, long)]
        volumes: bool,
    },
    /// Show service status
    Ps,
    /// Tail service logs
    Logs {
        /// Service name
        service: Option<String>,
        /// Follow log output
        #[arg(short, long)]
        follow: bool,
    },
    /// Restart services
    Restart {
        /// Service names (all if empty)
        services: Vec<String>,
    },
}

pub fn dev(action: DevAction) -> Result<()> {
    match action {
        DevAction::Up { detach } => up(detach),
        DevAction::Down { volumes } => down(volumes),
        DevAction::Ps => compose(&["ps"]),
        DevAction::Logs { service, follow } => logs(service.as_deref(), follow),
        DevAction::Restart { services } => restart(&services),
    }
}

/// Run a docker compose command against dev/docker-compose.yml.
fn compose(args: &[&str]) -> Result<()> {
    let cf = paths::compose_file();
    let cf_str = cf
        .to_str()
        .ok_or_else(|| eyre::eyre!("compose file path is not valid UTF-8"))?;
    let mut full_args = vec!["compose", "-f", cf_str];
    full_args.extend_from_slice(args);
    exec::run("docker", &full_args)
}

/// Load config, validate, generate dev/.env, then start the compose stack.
fn up(detach: bool) -> Result<()> {
    let config = dsqld_config::load_config(&paths::config_file())?;
    dsqld_config::validate::validate(&config)?;

    let env_content = dsqld_config::env::generate_env(&config)?;
    let env_path = paths::env_file();
    if let Some(parent) = env_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&env_path, env_content)?;
    eprintln!("▸ wrote {}", env_path.display());

    let mut args = vec!["up"];
    if detach {
        args.push("-d");
    }
    compose(&args)
}

fn down(volumes: bool) -> Result<()> {
    let mut args = vec!["down"];
    if volumes {
        args.push("--volumes");
    }
    compose(&args)
}

fn logs(service: Option<&str>, follow: bool) -> Result<()> {
    let mut args = vec!["logs"];
    if follow {
        args.push("--follow");
    }
    if let Some(svc) = service {
        args.push(svc);
    }
    compose(&args)
}

fn restart(services: &[String]) -> Result<()> {
    let svc_refs: Vec<&str> = services.iter().map(|s| s.as_str()).collect();
    let mut args = vec!["restart"];
    args.extend_from_slice(&svc_refs);
    compose(&args)
}
