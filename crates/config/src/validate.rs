use crate::ProjectConfig;

/// Errors that can occur when loading or validating configuration.
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("config file not found: {0}")]
    NotFound(std::path::PathBuf),

    #[error("TOML parse error: {0}")]
    Parse(#[from] toml::de::Error),

    #[error("validation error: {field} — {message}")]
    Validation { field: String, message: String },

    #[error("missing required field: {0}")]
    MissingField(String),
}

/// Validate config invariants. Returns Err on first violation.
pub fn validate(config: &ProjectConfig) -> Result<(), ConfigError> {
    if config.dsql.max_idle_conns != config.dsql.max_conns {
        return Err(ConfigError::Validation {
            field: "dsql.max_idle_conns".to_string(),
            message: format!(
                "max_idle_conns ({}) must equal max_conns ({}) to prevent pool decay",
                config.dsql.max_idle_conns, config.dsql.max_conns
            ),
        });
    }
    Ok(())
}
