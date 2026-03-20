# Implementation Plan: Rust CLI Rewrite (`dsqld`)

## Overview

Rewrite the `temporal-dsql-deploy` Python CLI to Rust, producing a `dsqld` binary and a `dsqld-build` companion binary. Implementation follows a bottom-up order: foundational crates first (`dagger-client`, `config`), then the `build` crate, then the `cli` crate with its modules and subcommands, then directory migration and cleanup. Each task builds on the previous, ending with full integration.

## Tasks

- [x] 1. Scaffold Cargo workspace and foundational files
  - [x] 1.1 Create workspace `Cargo.toml`, `.cargo/config.toml`, and `rust-toolchain.toml`
    - Create `Cargo.toml` at workspace root with `members = ["crates/*"]`, edition 2024, resolver 2
    - Create `.cargo/config.toml` setting `DSQLD_WORKSPACE_ROOT` env var via `[env]` section
    - Create `rust-toolchain.toml` pinning stable toolchain
    - Create `config.example.toml` with all documented configuration sections and defaults
    - _Requirements: 1.1, 1.5, 1.7, 2.6_

- [x] 2. Copy `dagger-client` crate from EKS repo
  - [x] 2.1 Copy `crates/dagger-client/` verbatim from `temporal-dsql-deploy-eks/crates/dagger-client/`
    - Copy `Cargo.toml`, `src/lib.rs`, and any other files
    - Verify `cargo check -p dagger-client` passes with no changes
    - _Requirements: 1.4_

- [x] 3. Implement `config` crate — data model and defaults
  - [x] 3.1 Create `crates/config/Cargo.toml` and `crates/config/src/lib.rs` with module declarations
    - Dependencies: `serde`, `toml`, `thiserror`
    - Declare `pub mod model;`, `pub mod validate;`, `pub mod env;`
    - Export `pub use model::ProjectConfig;` and `pub fn load_config(path) -> Result<ProjectConfig, ConfigError>`
    - _Requirements: 1.9, 2.1_
  - [x] 3.2 Create `crates/config/src/model.rs` with all config structs
    - Implement `ProjectConfig`, `ProjectSection`, `DsqlSection`, `ReservoirConfig`, `RateCoordinationConfig`, `TokenBucketConfig`, `ConnLeaseConfig`, `ElasticsearchSection`, `TemporalSection`, `DynamoDbSection`
    - All structs derive `Debug, Clone, Serialize, Deserialize` with `#[serde(default)]` on each field
    - Implement `Default` with sensible defaults per design: `dsql.endpoint` empty, `temporal.image` = `"temporal-dsql-server:latest"`, reservoir/rate/lease enabled by default
    - Implement default helper functions for each field
    - _Requirements: 2.1, 2.2, 2.3, 11.2_
  - [ ]* 3.3 Write property test for config TOML round-trip (Property 1)
    - **Property 1: Config TOML round-trip**
    - Generate random `ProjectConfig` instances with valid string fields using `proptest`
    - Serialize to TOML, deserialize back, assert equivalence
    - **Validates: Requirements 2.1, 2.7**
  - [ ]* 3.4 Write unit test for default config sensible defaults (Property 2)
    - **Property 2: Default config has sensible defaults**
    - Assert `ProjectConfig::default()` has empty `dsql.endpoint`, non-empty defaults for all other fields, `temporal.image` == `"temporal-dsql-server:latest"`
    - **Validates: Requirements 2.3, 11.2**

- [x] 4. Implement `config` crate — validation
  - [x] 4.1 Create `crates/config/src/validate.rs` with `ConfigError` and `validate()` function
    - Define `ConfigError` enum with `thiserror`: `NotFound`, `Parse`, `Validation { field, message }`, `MissingField`
    - Implement `validate(config: &ProjectConfig) -> Result<(), ConfigError>`
    - Check `max_idle_conns == max_conns`, return `Validation` error if violated
    - _Requirements: 2.8, 13.1_
  - [ ]* 4.2 Write property test for pool invariant validation (Property 3)
    - **Property 3: Pool invariant validation**
    - Generate random `(max_conns, max_idle_conns)` pairs where they differ
    - Assert `validate()` returns `ConfigError::Validation` referencing `max_idle_conns`
    - **Validates: Requirements 2.8**

- [-] 5. Implement `config` crate — env generation
  - [x] 5.1 Create `crates/config/src/env.rs` with `generate_env()` function
    - Map all config fields to environment variable names per the design's env mapping table
    - Emit static variables: `TEMPORAL_SQL_PLUGIN=dsql`, `TEMPORAL_SQL_PLUGIN_NAME=dsql`, `TEMPORAL_SQL_TLS_ENABLED=true`, `TEMPORAL_SQL_IAM_AUTH=true`
    - Emit `AWS_REGION` and `TEMPORAL_SQL_AWS_REGION` from `project.region`
    - Return error if `dsql.endpoint` is empty
    - _Requirements: 3.1, 3.2, 3.3, 3.4_
  - [ ]* 5.2 Write property test for env generation round-trip (Property 4)
    - **Property 4: Env generation round-trip**
    - Generate random valid `ProjectConfig` with non-empty `dsql.endpoint`
    - Call `generate_env()`, parse resulting key-value pairs, assert values match original config fields
    - **Validates: Requirements 3.2, 3.5**
  - [ ]* 5.3 Write property test for missing endpoint prevents env generation (Property 5)
    - **Property 5: Missing endpoint prevents env generation**
    - Generate random `ProjectConfig` with empty `dsql.endpoint`
    - Assert `generate_env()` returns error identifying the missing field
    - **Validates: Requirements 3.4**

- [x] 6. Checkpoint — config crate complete
  - Ensure all tests pass with `cargo test -p dsqld-config`, ask the user if questions arise.

- [x] 7. Implement `build` crate — Dagger-based image builder
  - [x] 7.1 Create `crates/build/Cargo.toml` and `crates/build/src/main.rs`
    - Dependencies: `clap` (derive), `eyre`, `color-eyre`, `dagger-client`
    - Binary name: `dsqld-build`
    - Implement `Cli` struct with `Commands::Temporal { source, arch }` subcommand
    - Implement `resolve_temporal_dsql_path()`: `--source` > `TEMPORAL_DSQL_PATH` env > `../temporal-dsql`
    - Implement `go_version_from_mod()`: parse `go X.Y.Z` directive, return `"X.Y"`
    - Validate source dir contains `go.mod`
    - Implement `build_temporal()` using `dagger-client` to compile Go binaries and produce two images: `temporal-dsql-server:latest` and `temporal-dsql-tool:latest`
    - _Requirements: 1.3, 1.10, 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 11.1_
  - [ ]* 7.2 Write property test for Go version extraction (Property 7)
    - **Property 7: Go version extraction**
    - Generate random `(major, minor, patch)` tuples, construct `go.mod` content with `go X.Y.Z`
    - Assert `go_version_from_mod()` returns `"X.Y"`
    - **Validates: Requirements 5.4, 5.8**
  - [ ]* 7.3 Write unit tests for build crate edge cases
    - Test `go.mod` with no `go` directive returns error
    - Test `go.mod` with `go 1.24` (no patch) returns `"1.24"`
    - Test source dir without `go.mod` returns error
    - _Requirements: 5.3, 5.4_

- [x] 8. Scaffold `cli` crate — main, exec, paths modules
  - [x] 8.1 Create `crates/cli/Cargo.toml` with dependencies and binary name `dsqld`
    - Dependencies: `clap` (derive), `eyre`, `color-eyre`, `which`, `dsqld-config` (path dep), `aws-sdk-dsql`, `aws-sdk-dynamodb`, `aws-config`, `tokio` (full)
    - _Requirements: 1.2, 1.8_
  - [x] 8.2 Create `crates/cli/src/exec.rs` matching `temporal-loom` exec module
    - Implement `run(program, args) -> Result<()>`: verify tool on PATH via `which`, print `▸ command args` to stderr, run from workspace root, stream stdio, check exit code
    - Implement `run_in(program, args, dir) -> Result<()>`: same but in specified directory
    - _Requirements: 12.1, 12.3, 12.4_
  - [x] 8.3 Create `crates/cli/src/paths.rs` matching `temporal-loom` paths module
    - Define `const WORKSPACE_ROOT: &str = env!("DSQLD_WORKSPACE_ROOT")`
    - Implement `root()`, `compose_file()` → `dev/docker-compose.yml`, `env_file()` → `dev/.env`, `config_file()` → `config.toml`, `docker_dir()` → `docker/`
    - _Requirements: 8.5, 12.2_
  - [ ]* 8.4 Write unit test for path functions resolve under workspace root (Property 9)
    - **Property 9: Path functions resolve under workspace root**
    - Assert all path functions return paths starting with `paths::root()`
    - **Validates: Requirements 8.3, 12.2**

- [x] 9. Implement `cli` crate — main.rs and command routing
  - [x] 9.1 Create `crates/cli/src/main.rs` with clap `Cli` struct and `Command` enum
    - Define `Command` enum with `Config`, `Infra`, `Build`, `Schema`, `Dev` subcommands
    - Install `color_eyre`, parse CLI, dispatch to command handlers
    - Create `crates/cli/src/cmd/` directory with `mod.rs`
    - _Requirements: 1.2, 1.8_

- [x] 10. Implement `config` subcommand
  - [x] 10.1 Create `crates/cli/src/cmd/config.rs` with `ConfigAction::Init`
    - Generate `config.toml` with documented defaults and placeholder values
    - Refuse to overwrite if `config.toml` already exists
    - _Requirements: 2.4, 2.5_

- [x] 11. Implement `dev` subcommand — Docker Compose lifecycle
  - [x] 11.1 Create `crates/cli/src/cmd/dev.rs` with `DevAction` enum and compose helper
    - Implement `DevAction`: `Up { detach }`, `Down { volumes }`, `Ps`, `Logs { service, follow }`, `Restart { services }`
    - Implement `compose(args)` helper matching loom-cli pattern: prepend `-f dev/docker-compose.yml`
    - Verify `docker` on PATH before any compose operation
    - For `Up`: load config, validate, generate `dev/.env`, then invoke compose
    - For `Down`: pass `--volumes` flag if requested
    - For `Logs`: pass service name and `--follow` flag
    - For `Restart`: pass service names
    - Propagate subprocess exit codes
    - _Requirements: 3.1, 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7, 7.8, 7.9_

- [x] 12. Implement `infra` subcommand — AWS SDK infrastructure
  - [x] 12.1 Create `crates/cli/src/cmd/infra.rs` with `InfraAction` enum and async handlers
    - Implement `InfraAction`: `Apply`, `Destroy`, `Status`
    - `Apply`: create DSQL cluster via `aws-sdk-dsql` with deletion protection and tags, create two DynamoDB tables (rate limiter + conn lease) with on-demand billing and TTL, write endpoint back to `config.toml`
    - `Destroy`: require explicit confirmation before deleting resources
    - `Status`: query AWS APIs and display current resource state
    - Use project name as prefix for all resource names and tags
    - Use `tokio` runtime for async operations
    - Rely on SDK built-in retry for retryable errors, report clear messages for permission errors
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 4.8, 4.9_
  - [ ]* 12.2 Write property test for project name prefix (Property 6)
    - **Property 6: Project name prefix for resource names**
    - Generate random non-empty project name strings
    - Assert DSQL cluster name is prefixed with project name
    - Assert DynamoDB table names are `"{project_name}-dsql-rate-limiter"` and `"{project_name}-dsql-conn-lease"`
    - **Validates: Requirements 4.6**

- [x] 13. Implement `build` subcommand — delegate to dsqld-build
  - [x] 13.1 Create `crates/cli/src/cmd/build.rs` with `BuildAction::Temporal`
    - Accept `--source` and `--arch` arguments
    - Delegate to `dsqld-build` binary as a subprocess via `exec::run`
    - _Requirements: 5.1, 5.7_

- [x] 14. Implement `schema` subcommand
  - [x] 14.1 Create `crates/cli/src/cmd/schema.rs` with `SchemaAction::Setup`
    - Accept `--version` (default `1.1`), `--overwrite`, `--tool` (path to `temporal-dsql-tool`)
    - Load config, derive connection parameters from config fields
    - Execute `temporal-dsql-tool` as subprocess with appropriate arguments
    - Report clear error if tool binary not found
    - Propagate exit code on failure
    - _Requirements: 6.1, 6.2, 6.3, 6.4, 6.5_
  - [ ]* 14.2 Write property test for schema tool args derived from config (Property 8)
    - **Property 8: Schema tool args derived from config**
    - Generate random valid `ProjectConfig` with non-empty `dsql.endpoint`
    - Assert the argument builder produces args containing endpoint, port, user, database, and region
    - **Validates: Requirements 6.2**

- [ ] 15. Checkpoint — all crates compile and tests pass
  - Ensure `cargo build --workspace` and `cargo test --workspace` pass, ask the user if questions arise.

- [x] 16. Migrate directory structure — `profiles/dsql/` to `dev/`
  - [x] 16.1 Create `dev/` directory with migrated files
    - Move `profiles/dsql/docker-compose.yml` to `dev/docker-compose.yml`
    - Move `profiles/dsql/dynamicconfig/` to `dev/dynamicconfig/`
    - Move config files (Alloy, Mimir, Grafana) to `dev/config/`
    - Update `docker-compose.yml` paths: config files relative to `dev/`, Docker assets relative to workspace root (`../docker/`)
    - _Requirements: 8.1, 8.2_
  - [x] 16.2 Update `dev/docker-compose.yml` to remove hardcoded DSQL env vars
    - Remove all DSQL, reservoir, rate limiting, and connection lease environment variables from `environment:` blocks in temporal services
    - Keep only non-DSQL constants: `AWS_EC2_METADATA_DISABLED`, `TEMPORAL_PERSISTENCE_TEMPLATE`, `DSQL_TOKEN_DURATION`, `DSQL_STAGGERED_STARTUP`
    - All DSQL configuration flows through `env_file: [.env]`
    - _Requirements: 8.3_
  - [x] 16.3 Update Elasticsearch image to 8.17.0
    - Change `elasticsearch:8.11.0` to `docker.elastic.co/elasticsearch/elasticsearch:8.17.0`
    - _Requirements: 8.4_
  - [x] 16.4 Update image references to new naming convention
    - Change `temporal-dsql-runtime:test` to `temporal-dsql-server:latest` in compose file
    - _Requirements: 11.1, 11.3_

- [x] 17. Clean up Python artifacts and Terraform
  - [x] 17.1 Remove Python CLI artifacts
    - Delete `src/tdeploy/`, root `pyproject.toml`, `.python-version`
    - Retain `dsql-tests/` as independent Python test suite
    - Create `dsql-tests/pyproject.toml` with required Python dependencies (`temporalio`, `boto3`)
    - _Requirements: 9.1, 9.2, 9.3_
  - [x] 17.2 Remove Terraform directory
    - Delete `terraform/` directory and all contents
    - _Requirements: 10.1_
  - [x] 17.3 Remove `profiles/` directory
    - Delete `profiles/` directory after migration to `dev/`
    - _Requirements: 8.6_
  - [x] 17.4 Update `AGENTS.md` and `README.md`
    - Update documentation to reflect new Rust CLI commands, project structure, and removal of Terraform/Python
    - _Requirements: 9.4, 10.2_

- [x] 18. Final checkpoint — workspace quality checks
  - Run `cargo fmt --all -- --check`, `cargo clippy --workspace -- -D warnings`, and `cargo test --workspace`. Ensure zero warnings, zero test failures. Ask the user if questions arise.
  - _Requirements: 1.6, 13.1, 13.2, 13.3, 13.4, 13.5_

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
- Property tests validate universal correctness properties from the design document (9 properties total)
- The `dagger-client` crate is copied verbatim — no functional changes
- All DSQL env vars flow through generated `.env`, not hardcoded in `docker-compose.yml`
- Full connection management stack (reservoir + distributed rate limiting + connection leasing) enabled by default
