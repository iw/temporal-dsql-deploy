use crate::ProjectConfig;

/// Errors that can occur when loading or validating configuration.
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("config file not found: {0}")]
    NotFound(std::path::PathBuf),

    #[error("failed to read config file {path}: {source}")]
    Read {
        path: std::path::PathBuf,
        #[source]
        source: std::io::Error,
    },

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

    if config.dsql.rate_coordination.enabled && config.dsql.rate_coordination.table_name.is_empty()
    {
        return Err(ConfigError::Validation {
            field: "dsql.rate_coordination.table_name".to_string(),
            message: "must be set when dsql.rate_coordination.enabled=true".to_string(),
        });
    }

    if config.dsql.conn_lease.enabled && config.dsql.conn_lease.table_name.is_empty() {
        return Err(ConfigError::Validation {
            field: "dsql.conn_lease.table_name".to_string(),
            message: "must be set when dsql.conn_lease.enabled=true".to_string(),
        });
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ProjectConfig;

    #[test]
    fn validates_pool_invariant() {
        let mut cfg = ProjectConfig::default();
        cfg.dsql.identifier = "cluster".into();
        cfg.dsql.max_idle_conns = 49;
        cfg.dsql.rate_coordination.table_name = "rate-table".into();
        cfg.dsql.conn_lease.table_name = "lease-table".into();

        let err = validate(&cfg).expect_err("max_idle_conns mismatch should fail");
        assert!(matches!(
            err,
            ConfigError::Validation { ref field, .. } if field == "dsql.max_idle_conns"
        ));
    }

    #[test]
    fn validates_required_tables_when_features_enabled() {
        let mut cfg = ProjectConfig::default();
        cfg.dsql.identifier = "cluster".into();
        cfg.dsql.max_idle_conns = cfg.dsql.max_conns;

        let err = validate(&cfg).expect_err("missing rate table should fail first");
        assert!(matches!(
            err,
            ConfigError::Validation { ref field, .. } if field == "dsql.rate_coordination.table_name"
        ));

        cfg.dsql.rate_coordination.table_name = "rate-table".into();
        let err = validate(&cfg).expect_err("missing lease table should fail next");
        assert!(matches!(
            err,
            ConfigError::Validation { ref field, .. } if field == "dsql.conn_lease.table_name"
        ));
    }

    #[test]
    fn allows_empty_tables_when_coordination_features_disabled() {
        let mut cfg = ProjectConfig::default();
        cfg.dsql.identifier = "cluster".into();
        cfg.dsql.max_idle_conns = cfg.dsql.max_conns;
        cfg.dsql.rate_coordination.enabled = false;
        cfg.dsql.conn_lease.enabled = false;

        validate(&cfg).expect("disabled features should not require table names");
    }
}
