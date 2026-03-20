use eyre::{Result, bail};
use std::process::{Command, Stdio};

use crate::paths;

/// Execute a command from the workspace root, streaming stdio to the terminal.
pub fn run(program: &str, args: &[&str]) -> Result<()> {
    let root = paths::root()
        .to_str()
        .ok_or_else(|| eyre::eyre!("workspace root path is not valid UTF-8"))?;
    run_in(program, args, root)
}

/// Execute a command in the given directory, streaming stdio to the terminal.
pub fn run_in(program: &str, args: &[&str], dir: &str) -> Result<()> {
    which::which(program)
        .map_err(|_| eyre::eyre!("'{program}' not found on PATH — is it installed?"))?;

    eprintln!("▸ {program} {}", args.join(" "));

    let status = Command::new(program)
        .args(args)
        .current_dir(dir)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()?;

    if !status.success() {
        let code = status.code().unwrap_or(1);
        bail!("'{program}' exited with code {code}");
    }
    Ok(())
}
