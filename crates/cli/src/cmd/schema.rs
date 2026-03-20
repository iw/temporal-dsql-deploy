use clap::Subcommand;
use eyre::{Result, bail};

use crate::{exec, paths};

const SCHEMA_NAME: &str = "dsql/temporal";
const TOOL_IMAGE: &str = "temporal-dsql-tool:latest";

#[derive(Debug, Subcommand)]
pub enum SchemaAction {
    /// Apply DSQL schema
    Setup {
        /// Schema version
        #[arg(long, default_value = "1.1")]
        version: String,
        /// Overwrite existing schema
        #[arg(long)]
        overwrite: bool,
        /// Docker image for temporal-dsql-tool
        #[arg(long, default_value = TOOL_IMAGE)]
        image: String,
    },
}

pub fn schema(action: SchemaAction) -> Result<()> {
    match action {
        SchemaAction::Setup {
            version,
            overwrite,
            image,
        } => setup(&version, overwrite, &image),
    }
}

fn setup(version: &str, overwrite: bool, image: &str) -> Result<()> {
    let config = dsqld_config::load_config(&paths::config_file())?;

    if config.dsql.identifier.is_empty() {
        bail!("dsql.identifier is empty — run 'dsqld infra apply' first or set it in config.toml");
    }

    let dsql_endpoint = config.dsql.endpoint(&config.project.region);
    let port = config.dsql.port.to_string();
    let region = &config.project.region;

    eprintln!("Schema setup:");
    eprintln!("  Cluster:  {}", config.dsql.identifier);
    eprintln!("  Endpoint: {dsql_endpoint}");
    eprintln!("  Database: {}", config.dsql.database);
    eprintln!("  Region:   {region}");
    eprintln!("  Version:  {version}");
    if overwrite {
        eprintln!("  Overwrite: yes (existing tables will be dropped)");
    }
    eprintln!();

    // temporal-dsql-tool lives in a Docker image built by `dsqld build temporal`.
    // Run it via `docker run` with host AWS credentials and IMDS disabled.
    let home = std::env::var("HOME")
        .map_err(|_| eyre::eyre!("HOME not set"))?;
    let aws_mount = format!("{home}/.aws:/home/temporal/.aws:ro");

    let mut args = vec![
        "run", "--rm", "--network", "host",
        "-v", &aws_mount,
        "-e", "AWS_EC2_METADATA_DISABLED=true",
    ];

    // Add the image name
    args.push(image);

    // Tool arguments (after the image name)
    let tool_args_owned = build_tool_args(&dsql_endpoint, &port, &config.dsql.user, &config.dsql.database, region, version, overwrite);
    let tool_args_refs: Vec<&str> = tool_args_owned.iter().map(|s| s.as_str()).collect();
    args.extend_from_slice(&tool_args_refs);

    exec::run("docker", &args)
}

fn build_tool_args(
    endpoint: &str,
    port: &str,
    user: &str,
    database: &str,
    region: &str,
    version: &str,
    overwrite: bool,
) -> Vec<String> {
    let mut args = vec![
        "--endpoint".into(), endpoint.into(),
        "--port".into(), port.into(),
        "--user".into(), user.into(),
        "--database".into(), database.into(),
        "--region".into(), region.into(),
        "setup-schema".into(),
        "--schema-name".into(), SCHEMA_NAME.into(),
        "--version".into(), version.into(),
    ];
    if overwrite {
        args.push("--overwrite".into());
    }
    args
}
