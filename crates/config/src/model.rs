use serde::{Deserialize, Serialize};

// ─── Default helper functions ───────────────────────────────────────────────

fn default_project_name() -> String {
    "temporal-dev".to_string()
}

fn default_region() -> String {
    "eu-west-1".to_string()
}

fn default_5432() -> u16 {
    5432
}

fn default_admin() -> String {
    "admin".to_string()
}

fn default_postgres() -> String {
    "postgres".to_string()
}

fn default_50() -> u32 {
    50
}

fn default_30s() -> String {
    "30s".to_string()
}

fn default_55m() -> String {
    "55m".to_string()
}

fn default_true() -> bool {
    true
}

fn default_11m() -> String {
    "11m".to_string()
}

fn default_2m() -> String {
    "2m".to_string()
}

fn default_45s() -> String {
    "45s".to_string()
}

fn default_8() -> u32 {
    8
}

fn default_100() -> u32 {
    100
}

fn default_1000() -> u32 {
    1000
}

fn default_3m() -> String {
    "3m".to_string()
}

fn default_1m() -> String {
    "1m".to_string()
}

fn default_es_host() -> String {
    "elasticsearch".to_string()
}

fn default_9200() -> u16 {
    9200
}

fn default_http() -> String {
    "http".to_string()
}

fn default_v8() -> String {
    "v8".to_string()
}

fn default_es_index() -> String {
    "temporal_visibility_v1_dev".to_string()
}

fn default_info() -> String {
    "info".to_string()
}

fn default_4() -> u32 {
    4
}

fn default_temporal_image() -> String {
    "temporal-dsql-server:latest".to_string()
}

// ─── Config structs ─────────────────────────────────────────────────────────

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ProjectConfig {
    #[serde(default)]
    pub project: ProjectSection,
    #[serde(default)]
    pub dsql: DsqlSection,
    #[serde(default)]
    pub elasticsearch: ElasticsearchSection,
    #[serde(default)]
    pub temporal: TemporalSection,
    #[serde(default)]
    pub dynamodb: DynamoDbSection,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectSection {
    #[serde(default = "default_project_name")]
    pub name: String,
    #[serde(default = "default_region")]
    pub region: String,
}

impl Default for ProjectSection {
    fn default() -> Self {
        Self {
            name: default_project_name(),
            region: default_region(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DsqlSection {
    /// DSQL cluster identifier (populated by `dsqld infra apply`).
    /// The connection endpoint is derived: `{identifier}.dsql.{region}.on.aws`.
    #[serde(default)]
    pub identifier: String,
    #[serde(default = "default_5432")]
    pub port: u16,
    #[serde(default = "default_admin")]
    pub user: String,
    #[serde(default = "default_postgres")]
    pub database: String,
    #[serde(default = "default_50")]
    pub max_conns: u32,
    #[serde(default = "default_50")]
    pub max_idle_conns: u32,
    #[serde(default = "default_30s")]
    pub connection_timeout: String,
    #[serde(default = "default_55m")]
    pub max_conn_lifetime: String,
    #[serde(default)]
    pub reservoir: ReservoirConfig,
    #[serde(default)]
    pub rate_coordination: RateCoordinationConfig,
    #[serde(default)]
    pub conn_lease: ConnLeaseConfig,
}

impl Default for DsqlSection {
    fn default() -> Self {
        Self {
            identifier: String::new(),
            port: default_5432(),
            user: default_admin(),
            database: default_postgres(),
            max_conns: default_50(),
            max_idle_conns: default_50(),
            connection_timeout: default_30s(),
            max_conn_lifetime: default_55m(),
            reservoir: ReservoirConfig::default(),
            rate_coordination: RateCoordinationConfig::default(),
            conn_lease: ConnLeaseConfig::default(),
        }
    }
}

impl DsqlSection {
    /// Derive the DSQL connection endpoint from the cluster identifier and region.
    /// Format: `{identifier}.dsql.{region}.on.aws`
    pub fn endpoint(&self, region: &str) -> String {
        format!("{}.dsql.{region}.on.aws", self.identifier)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReservoirConfig {
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default = "default_50")]
    pub target_ready: u32,
    #[serde(default = "default_11m")]
    pub base_lifetime: String,
    #[serde(default = "default_2m")]
    pub lifetime_jitter: String,
    #[serde(default = "default_45s")]
    pub guard_window: String,
    #[serde(default = "default_8")]
    pub inflight_limit: u32,
}

impl Default for ReservoirConfig {
    fn default() -> Self {
        Self {
            enabled: default_true(),
            target_ready: default_50(),
            base_lifetime: default_11m(),
            lifetime_jitter: default_2m(),
            guard_window: default_45s(),
            inflight_limit: default_8(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RateCoordinationConfig {
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub table_name: String,
    #[serde(default = "default_100")]
    pub limit: u32,
    #[serde(default)]
    pub token_bucket: TokenBucketConfig,
}

impl Default for RateCoordinationConfig {
    fn default() -> Self {
        Self {
            enabled: default_true(),
            table_name: String::new(),
            limit: default_100(),
            token_bucket: TokenBucketConfig::default(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TokenBucketConfig {
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default = "default_100")]
    pub rate: u32,
    #[serde(default = "default_1000")]
    pub capacity: u32,
}

impl Default for TokenBucketConfig {
    fn default() -> Self {
        Self {
            enabled: default_true(),
            rate: default_100(),
            capacity: default_1000(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConnLeaseConfig {
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub table_name: String,
    #[serde(default = "default_100")]
    pub block_size: u32,
    #[serde(default = "default_100")]
    pub block_count: u32,
    #[serde(default = "default_3m")]
    pub block_ttl: String,
    #[serde(default = "default_1m")]
    pub renew_interval: String,
}

impl Default for ConnLeaseConfig {
    fn default() -> Self {
        Self {
            enabled: default_true(),
            table_name: String::new(),
            block_size: default_100(),
            block_count: default_100(),
            block_ttl: default_3m(),
            renew_interval: default_1m(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ElasticsearchSection {
    #[serde(default = "default_es_host")]
    pub host: String,
    #[serde(default = "default_9200")]
    pub port: u16,
    #[serde(default = "default_http")]
    pub scheme: String,
    #[serde(default = "default_v8")]
    pub version: String,
    #[serde(default = "default_es_index")]
    pub index: String,
}

impl Default for ElasticsearchSection {
    fn default() -> Self {
        Self {
            host: default_es_host(),
            port: default_9200(),
            scheme: default_http(),
            version: default_v8(),
            index: default_es_index(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TemporalSection {
    #[serde(default = "default_info")]
    pub log_level: String,
    #[serde(default = "default_4")]
    pub history_shards: u32,
    #[serde(default = "default_temporal_image")]
    pub image: String,
}

impl Default for TemporalSection {
    fn default() -> Self {
        Self {
            log_level: default_info(),
            history_shards: default_4(),
            image: default_temporal_image(),
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DynamoDbSection {
    #[serde(default)]
    pub rate_limiter_table: String,
    #[serde(default)]
    pub conn_lease_table: String,
}
