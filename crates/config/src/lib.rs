pub mod env;
pub mod model;
pub mod validate;

pub use model::ProjectConfig;
pub use validate::ConfigError;

use std::path::Path;

/// Load and deserialize config.toml from the given path.
pub fn load_config(path: &Path) -> Result<ProjectConfig, ConfigError> {
    let contents =
        std::fs::read_to_string(path).map_err(|_| ConfigError::NotFound(path.to_path_buf()))?;
    let config: ProjectConfig = toml::from_str(&contents)?;
    Ok(config)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn load_config_from_valid_toml() {
        let dir = std::env::temp_dir().join("dsqld-config-test-load");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config.toml");
        let mut f = std::fs::File::create(&path).unwrap();
        writeln!(
            f,
            r#"
[project]
name = "test-project"
region = "us-east-1"

[dsql]
identifier = "my-cluster-id"
"#
        )
        .unwrap();

        let config = load_config(&path).unwrap();
        assert_eq!(config.project.name, "test-project");
        assert_eq!(config.dsql.identifier, "my-cluster-id");
        assert_eq!(
            config.dsql.endpoint("us-east-1"),
            "my-cluster-id.dsql.us-east-1.on.aws"
        );

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn load_config_not_found() {
        let result = load_config(Path::new("/nonexistent/config.toml"));
        assert!(matches!(result, Err(ConfigError::NotFound(_))));
    }

    #[test]
    fn load_config_empty_file_uses_defaults() {
        let dir = std::env::temp_dir().join("dsqld-config-test-empty");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config.toml");
        std::fs::write(&path, "").unwrap();

        let config = load_config(&path).unwrap();
        assert_eq!(config.project.name, "temporal-dev");
        assert!(config.dsql.identifier.is_empty());
        assert_eq!(config.temporal.image, "temporal-dsql-server:latest");

        std::fs::remove_dir_all(&dir).ok();
    }
}
