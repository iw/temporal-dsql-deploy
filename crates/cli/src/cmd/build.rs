use std::path::PathBuf;

use clap::Subcommand;
use eyre::Result;

use crate::exec;

#[derive(Debug, Subcommand)]
pub enum BuildAction {
    /// Build temporal-dsql-server and temporal-dsql-tool images
    Temporal {
        /// Path to temporal-dsql source repo
        #[arg(long, env = "TEMPORAL_DSQL_PATH")]
        source: Option<PathBuf>,
        /// Target architecture
        #[arg(long, default_value = "arm64")]
        arch: String,
    },
}

pub fn build(action: BuildAction) -> Result<()> {
    match action {
        BuildAction::Temporal { source, arch } => {
            // dsqld-build is a Dagger SDK client — it must be launched via
            // `dagger run` so Dagger injects DAGGER_SESSION_PORT/TOKEN.
            let mut args = vec!["run", "dsqld-build", "temporal", "--arch", &arch];
            let source_str = source.as_ref().map(|p| p.display().to_string());
            if let Some(ref s) = source_str {
                args.push("--source");
                args.push(s);
            }
            exec::run("dagger", &args)
        }
    }
}
