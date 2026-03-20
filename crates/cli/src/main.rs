mod cmd;
mod exec;
mod paths;

use clap::{Parser, Subcommand};
use cmd::build::BuildAction;
use cmd::config::ConfigAction;
use cmd::dev::DevAction;
use cmd::infra::InfraAction;
use cmd::schema::SchemaAction;
use eyre::Result;

#[derive(Debug, Parser)]
#[command(name = "dsqld", about = "Temporal DSQL local development CLI")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Configuration management
    Config {
        #[command(subcommand)]
        action: ConfigAction,
    },
    /// Infrastructure provisioning (AWS SDK)
    Infra {
        #[command(subcommand)]
        action: InfraAction,
    },
    /// Build Docker images via Dagger
    Build {
        #[command(subcommand)]
        action: BuildAction,
    },
    /// DSQL schema setup
    Schema {
        #[command(subcommand)]
        action: SchemaAction,
    },
    /// Docker Compose dev stack lifecycle
    Dev {
        #[command(subcommand)]
        action: DevAction,
    },
}

fn main() -> Result<()> {
    color_eyre::install()?;
    let cli = Cli::parse();

    match cli.command {
        Command::Config { action } => cmd::config::config(action),
        Command::Infra { action } => cmd::infra::infra(action),
        Command::Build { action } => cmd::build::build(action),
        Command::Schema { action } => cmd::schema::schema(action),
        Command::Dev { action } => cmd::dev::dev(action),
    }
}
