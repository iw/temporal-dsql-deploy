use std::path::{Path, PathBuf};

const WORKSPACE_ROOT: &str = env!("DSQLD_WORKSPACE_ROOT");

pub fn root() -> &'static Path {
    Path::new(WORKSPACE_ROOT)
}

pub fn compose_file() -> PathBuf {
    root().join("dev/docker-compose.yml")
}

pub fn env_file() -> PathBuf {
    root().join("dev/.env")
}

pub fn config_file() -> PathBuf {
    root().join("config.toml")
}

#[allow(dead_code)] // Part of the paths API per design (Req 12.2), not yet called
pub fn docker_dir() -> PathBuf {
    root().join("docker")
}
