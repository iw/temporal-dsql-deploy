use crate::model::ProjectConfig;
use crate::validate::ConfigError;

/// Generate a .env file content string from the config model.
///
/// Maps config fields to the environment variable names expected by the
/// Docker Compose stack. Returns an error if `dsql.identifier` is empty.
pub fn generate_env(config: &ProjectConfig) -> Result<String, ConfigError> {
    if config.dsql.identifier.is_empty() {
        return Err(ConfigError::MissingField("dsql.identifier".to_string()));
    }

    let dsql_endpoint = config.dsql.endpoint(&config.project.region);

    let mut lines = Vec::new();

    // Static variables
    lines.push("TEMPORAL_SQL_PLUGIN=dsql".to_string());
    lines.push("TEMPORAL_SQL_PLUGIN_NAME=dsql".to_string());
    lines.push("TEMPORAL_SQL_TLS_ENABLED=true".to_string());
    lines.push("TEMPORAL_SQL_IAM_AUTH=true".to_string());

    // Project
    lines.push(format!("AWS_REGION={}", config.project.region));
    lines.push(format!("TEMPORAL_SQL_AWS_REGION={}", config.project.region));

    // DSQL connection
    lines.push(format!("TEMPORAL_SQL_HOST={dsql_endpoint}"));
    lines.push(format!("TEMPORAL_SQL_PORT={}", config.dsql.port));
    lines.push(format!("TEMPORAL_SQL_USER={}", config.dsql.user));
    lines.push(format!("TEMPORAL_SQL_DATABASE={}", config.dsql.database));
    lines.push(format!("TEMPORAL_SQL_MAX_CONNS={}", config.dsql.max_conns));
    lines.push(format!(
        "TEMPORAL_SQL_MAX_IDLE_CONNS={}",
        config.dsql.max_idle_conns
    ));
    lines.push(format!(
        "TEMPORAL_SQL_CONNECTION_TIMEOUT={}",
        config.dsql.connection_timeout
    ));
    lines.push(format!(
        "TEMPORAL_SQL_MAX_CONN_LIFETIME={}",
        config.dsql.max_conn_lifetime
    ));

    // Elasticsearch
    lines.push(format!(
        "TEMPORAL_ELASTICSEARCH_HOST={}",
        config.elasticsearch.host
    ));
    lines.push(format!(
        "TEMPORAL_ELASTICSEARCH_PORT={}",
        config.elasticsearch.port
    ));
    lines.push(format!(
        "TEMPORAL_ELASTICSEARCH_SCHEME={}",
        config.elasticsearch.scheme
    ));
    lines.push(format!(
        "TEMPORAL_ELASTICSEARCH_VERSION={}",
        config.elasticsearch.version
    ));
    lines.push(format!(
        "TEMPORAL_ELASTICSEARCH_INDEX={}",
        config.elasticsearch.index
    ));

    // Temporal
    lines.push(format!("TEMPORAL_LOG_LEVEL={}", config.temporal.log_level));
    lines.push(format!(
        "TEMPORAL_HISTORY_SHARDS={}",
        config.temporal.history_shards
    ));
    lines.push(format!("TEMPORAL_IMAGE={}", config.temporal.image));

    // Reservoir
    lines.push(format!(
        "DSQL_RESERVOIR_ENABLED={}",
        config.dsql.reservoir.enabled
    ));
    lines.push(format!(
        "DSQL_RESERVOIR_TARGET_READY={}",
        config.dsql.reservoir.target_ready
    ));
    lines.push(format!(
        "DSQL_RESERVOIR_BASE_LIFETIME={}",
        config.dsql.reservoir.base_lifetime
    ));
    lines.push(format!(
        "DSQL_RESERVOIR_LIFETIME_JITTER={}",
        config.dsql.reservoir.lifetime_jitter
    ));
    lines.push(format!(
        "DSQL_RESERVOIR_GUARD_WINDOW={}",
        config.dsql.reservoir.guard_window
    ));
    lines.push(format!(
        "DSQL_RESERVOIR_INFLIGHT_LIMIT={}",
        config.dsql.reservoir.inflight_limit
    ));

    // Distributed rate coordination
    lines.push(format!(
        "DSQL_DISTRIBUTED_RATE_LIMITER_ENABLED={}",
        config.dsql.rate_coordination.enabled
    ));
    lines.push(format!(
        "DSQL_DISTRIBUTED_RATE_LIMITER_TABLE={}",
        config.dsql.rate_coordination.table_name
    ));
    lines.push(format!(
        "DSQL_DISTRIBUTED_RATE_LIMITER_LIMIT={}",
        config.dsql.rate_coordination.limit
    ));

    // Token bucket
    lines.push(format!(
        "DSQL_TOKEN_BUCKET_ENABLED={}",
        config.dsql.rate_coordination.token_bucket.enabled
    ));
    lines.push(format!(
        "DSQL_TOKEN_BUCKET_RATE={}",
        config.dsql.rate_coordination.token_bucket.rate
    ));
    lines.push(format!(
        "DSQL_TOKEN_BUCKET_CAPACITY={}",
        config.dsql.rate_coordination.token_bucket.capacity
    ));

    // Connection leasing
    lines.push(format!(
        "DSQL_DISTRIBUTED_CONN_LEASE_ENABLED={}",
        config.dsql.conn_lease.enabled
    ));
    lines.push(format!(
        "DSQL_DISTRIBUTED_CONN_LEASE_TABLE={}",
        config.dsql.conn_lease.table_name
    ));
    lines.push(format!(
        "DSQL_SLOT_BLOCK_SIZE={}",
        config.dsql.conn_lease.block_size
    ));
    lines.push(format!(
        "DSQL_SLOT_BLOCK_COUNT={}",
        config.dsql.conn_lease.block_count
    ));
    lines.push(format!(
        "DSQL_SLOT_BLOCK_TTL={}",
        config.dsql.conn_lease.block_ttl
    ));
    lines.push(format!(
        "DSQL_SLOT_BLOCK_RENEW_INTERVAL={}",
        config.dsql.conn_lease.renew_interval
    ));

    Ok(lines.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::*;

    fn config_with_identifier(identifier: &str) -> ProjectConfig {
        let mut config = ProjectConfig::default();
        config.dsql.identifier = identifier.to_string();
        config
    }

    #[test]
    fn generate_env_with_valid_config() {
        let config = config_with_identifier("my-cluster-id");
        let env = generate_env(&config).unwrap();

        // Static variables
        assert!(env.contains("TEMPORAL_SQL_PLUGIN=dsql"));
        assert!(env.contains("TEMPORAL_SQL_PLUGIN_NAME=dsql"));
        assert!(env.contains("TEMPORAL_SQL_TLS_ENABLED=true"));
        assert!(env.contains("TEMPORAL_SQL_IAM_AUTH=true"));

        // DSQL connection — endpoint derived from identifier + region
        assert!(env.contains("TEMPORAL_SQL_HOST=my-cluster-id.dsql.eu-west-1.on.aws"));
        assert!(env.contains("TEMPORAL_SQL_PORT=5432"));
        assert!(env.contains("TEMPORAL_SQL_USER=admin"));
        assert!(env.contains("TEMPORAL_SQL_DATABASE=postgres"));
        assert!(env.contains("TEMPORAL_SQL_MAX_CONNS=50"));
        assert!(env.contains("TEMPORAL_SQL_MAX_IDLE_CONNS=50"));

        // Region (both vars)
        assert!(env.contains("AWS_REGION=eu-west-1"));
        assert!(env.contains("TEMPORAL_SQL_AWS_REGION=eu-west-1"));

        // Elasticsearch
        assert!(env.contains("TEMPORAL_ELASTICSEARCH_HOST=elasticsearch"));
        assert!(env.contains("TEMPORAL_ELASTICSEARCH_PORT=9200"));

        // Temporal
        assert!(env.contains("TEMPORAL_IMAGE=temporal-dsql-server:latest"));
        assert!(env.contains("TEMPORAL_HISTORY_SHARDS=4"));

        // Reservoir (enabled by default)
        assert!(env.contains("DSQL_RESERVOIR_ENABLED=true"));
        assert!(env.contains("DSQL_RESERVOIR_TARGET_READY=50"));

        // Rate coordination (enabled by default)
        assert!(env.contains("DSQL_DISTRIBUTED_RATE_LIMITER_ENABLED=true"));
        assert!(env.contains("DSQL_TOKEN_BUCKET_ENABLED=true"));

        // Connection leasing (enabled by default)
        assert!(env.contains("DSQL_DISTRIBUTED_CONN_LEASE_ENABLED=true"));
        assert!(env.contains("DSQL_SLOT_BLOCK_SIZE=100"));
    }

    #[test]
    fn generate_env_missing_identifier() {
        let config = ProjectConfig::default();
        let result = generate_env(&config);
        assert!(matches!(result, Err(ConfigError::MissingField(ref f)) if f == "dsql.identifier"));
    }

    #[test]
    fn generate_env_custom_values() {
        let mut config = config_with_identifier("custom-cluster-id");
        config.project.region = "us-west-2".to_string();
        config.dsql.port = 5433;
        config.dsql.max_conns = 100;
        config.dsql.max_idle_conns = 100;
        config.temporal.history_shards = 8;
        config.dsql.reservoir.enabled = false;
        config.dsql.rate_coordination.table_name = "my-rate-table".to_string();
        config.dsql.conn_lease.table_name = "my-lease-table".to_string();

        let env = generate_env(&config).unwrap();

        assert!(env.contains("TEMPORAL_SQL_HOST=custom-cluster-id.dsql.us-west-2.on.aws"));
        assert!(env.contains("AWS_REGION=us-west-2"));
        assert!(env.contains("TEMPORAL_SQL_AWS_REGION=us-west-2"));
        assert!(env.contains("TEMPORAL_SQL_PORT=5433"));
        assert!(env.contains("TEMPORAL_SQL_MAX_CONNS=100"));
        assert!(env.contains("TEMPORAL_HISTORY_SHARDS=8"));
        assert!(env.contains("DSQL_RESERVOIR_ENABLED=false"));
        assert!(env.contains("DSQL_DISTRIBUTED_RATE_LIMITER_TABLE=my-rate-table"));
        assert!(env.contains("DSQL_DISTRIBUTED_CONN_LEASE_TABLE=my-lease-table"));
    }

    #[test]
    fn generate_env_each_line_is_key_value() {
        let config = config_with_identifier("test-cluster-id");
        let env = generate_env(&config).unwrap();

        for line in env.lines() {
            assert!(
                line.contains('='),
                "line should be KEY=VALUE format: {line}"
            );
            let parts: Vec<&str> = line.splitn(2, '=').collect();
            assert_eq!(
                parts.len(),
                2,
                "line should split into key and value: {line}"
            );
            assert!(!parts[0].is_empty(), "key should not be empty: {line}");
        }
    }
}
