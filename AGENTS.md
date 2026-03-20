# temporal-dsql-deploy

## Mission

Local development environment for the [temporal-dsql](https://github.com/iw/temporal) fork, which adds Aurora DSQL as a first-class persistence backend for Temporal. This repo provides the Rust CLI (`dsqld`) and Docker Compose stack to build, run, and observe Temporal against a real DSQL cluster with full observability.

This is **not** a production deployment solution. For production, see `temporal-dsql-deploy-ecs`.

## Architecture

Four Temporal services against a DSQL cluster, with Elasticsearch for visibility and Alloy → Mimir → Grafana for metrics.

```
┌─────────────────────────────────────────────────────────────────┐
│                    LOCAL DEVELOPMENT (Docker)                   │
│                                                                 │
│  ┌───────────┐ ┌───────────┐ ┌───────────┐ ┌───────────┐      │
│  │ Frontend  │ │  History  │ │ Matching  │ │  Worker   │      │
│  │  :7233    │ │   :7234   │ │   :7235   │ │   :7239   │      │
│  └─────┬─────┘ └─────┬─────┘ └─────┬─────┘ └─────┬─────┘      │
│        └──────────────┼─────────────┼─────────────┘            │
│                       │             │                          │
│  ┌─────────────┐  ┌───▼─────────────▼───┐  ┌───────────────┐  │
│  │Elasticsearch│  │   Alloy → Mimir →   │  │   CloudWatch  │  │
│  │ (Visibility)│  │      Grafana        │  │  (DSQL metrics)│  │
│  │   :9200     │  │      :3000          │  │               │  │
│  └─────────────┘  └─────────────────────┘  └───────────────┘  │
│                                                                 │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                   ┌────────▼────────┐
                   │   AURORA DSQL   │
                   │  (Persistence)  │
                   │  IAM Auth       │
                   └─────────────────┘
```

## Quick Start

### Prerequisites
- Rust stable toolchain
- Docker & Docker Compose
- AWS CLI configured with appropriate permissions
- [Dagger](https://docs.dagger.io/install/) >= 0.20 (for image builds)
- [temporal-dsql](https://github.com/iw/temporal) repository at `../temporal-dsql`

### Setup

```bash
# 1. Build the CLI
cargo install --path crates/cli

# 2. Initialize config
dsqld config init

# 3. Provision DSQL cluster and DynamoDB tables
dsqld infra apply

# 4. Build Temporal DSQL images via Dagger
dsqld build temporal

# 5. Setup DSQL schema
dsqld schema setup

# 6. Start services
dsqld dev up -d

# 7. Verify
open http://localhost:8080    # Temporal UI
open http://localhost:3000    # Grafana (admin/admin)

# 8. Cleanup
dsqld dev down
```

## Project Structure

```
temporal-dsql-deploy/
├── .cargo/config.toml          # DSQLD_WORKSPACE_ROOT env
├── Cargo.toml                  # Workspace root (members = ["crates/*"])
├── Cargo.lock
├── config.toml                 # User config (gitignored)
├── config.example.toml         # Reference config (committed)
├── crates/
│   ├── cli/                    # dsqld binary
│   │   └── src/
│   │       ├── main.rs
│   │       ├── exec.rs         # Subprocess execution
│   │       ├── paths.rs        # Workspace-relative paths
│   │       └── cmd/
│   │           ├── config.rs   # dsqld config init
│   │           ├── infra.rs    # dsqld infra apply/destroy/status
│   │           ├── build.rs    # dsqld build temporal
│   │           ├── schema.rs   # dsqld schema setup
│   │           └── dev.rs      # dsqld dev up/down/ps/logs/restart
│   ├── config/                 # TOML model + validation + env gen
│   │   └── src/
│   │       ├── lib.rs
│   │       ├── model.rs        # ProjectConfig and all config structs
│   │       ├── validate.rs     # Config validation (pool invariants)
│   │       └── env.rs          # .env generation from config
│   ├── build/                  # dsqld-build binary (Dagger)
│   │   └── src/main.rs
│   └── dagger-client/          # GraphQL client (from EKS repo)
│       └── src/lib.rs
├── dev/                        # Docker Compose dev environment
│   ├── docker-compose.yml
│   ├── .env                    # Generated (gitignored)
│   ├── config/                 # Alloy, Mimir, Grafana configs
│   └── dynamicconfig/
├── docker/                     # Shared Docker assets
│   ├── config/
│   └── render-and-start.sh
├── grafana/                    # Dashboard JSON
├── dsql-tests/                 # Python integration tests
│   ├── pyproject.toml          # Independent Python deps
│   ├── temporal/               # Temporal feature validation
│   └── plugin/                 # DSQL plugin validation
├── Dockerfile                  # Temporal DSQL runtime image
├── AGENTS.md
└── README.md
```

## Workspace Architecture

Cargo workspace with four crates:

| Crate | Binary | Purpose | Dependencies |
|-------|--------|---------|-------------|
| `cli` | `dsqld` | Main CLI with subcommands | `config`, `clap`, `eyre`, `which`, `aws-sdk-*`, `tokio` |
| `config` | — | TOML config model, validation, env generation | `serde`, `toml`, `thiserror` |
| `build` | `dsqld-build` | Dagger-based image builder | `clap`, `eyre`, `dagger-client` |
| `dagger-client` | — | Lightweight GraphQL client for Dagger | (copied from EKS repo) |

Dependency flow: `cli` → `config`; `build` → `dagger-client`.

## CLI Reference

```bash
# Configuration
dsqld config init                    # Generate config.toml with defaults

# Infrastructure (AWS SDK — no Terraform)
dsqld infra apply                    # Provision DSQL cluster + DynamoDB tables
dsqld infra destroy                  # Destroy provisioned resources
dsqld infra status                   # Show current resource state

# Build (Dagger)
dsqld build temporal                 # Build temporal-dsql-server + tool images
dsqld build temporal --source ../temporal-dsql --arch arm64

# Schema
dsqld schema setup                   # Apply DSQL schema
dsqld schema setup --version 1.1 --overwrite

# Docker Compose lifecycle
dsqld dev up -d                      # Start services (detached)
dsqld dev down                       # Stop services
dsqld dev down -v                    # Stop + remove volumes
dsqld dev ps                         # Show service status
dsqld dev logs temporal-history -f   # Follow service logs
dsqld dev restart temporal-frontend  # Restart specific service
```

## Design Decisions

### 1. TOML Config as Single Source of Truth

`config.toml` drives all CLI commands. The `.env` file is a derived artifact generated before every `dev` command. Developers edit `config.toml` only — no hand-editing `.env` files.

### 2. Direct AWS SDK (No Terraform)

Infrastructure is managed via `aws-sdk-dsql` and `aws-sdk-dynamodb` directly. `dsqld infra apply` creates the DSQL cluster and DynamoDB tables; `dsqld infra destroy` tears them down. No Terraform state to manage.

### 3. Full Connection Management Stack

Unlike the EKS repo (which disables DynamoDB-backed layers for dev profiles), this repo exercises the full DSQL connection management stack:
- **Reservoir**: Pre-creates connections so `Open()` never blocks
- **Distributed rate limiting**: DynamoDB-backed token bucket (100 conn/sec budget)
- **Connection leasing**: DynamoDB-backed slot blocks (10k connection limit)

All three layers default to enabled. `infra apply` always creates the DynamoDB tables.

### 4. All DSQL Env Vars Flow Through Generated `.env`

The `dev/docker-compose.yml` does not hardcode any DSQL, reservoir, rate limiting, or connection lease environment variables. All configuration flows through the generated `dev/.env` via `env_file:`. The only `environment:` entries in compose are non-DSQL constants.

### 5. Compile-Time Workspace Root

`.cargo/config.toml` injects `DSQLD_WORKSPACE_ROOT` so all paths resolve without runtime discovery.

### 6. Subprocess Over Library Bindings

Docker Compose and `temporal-dsql-tool` are invoked as subprocesses (matching `temporal-loom`), not via Rust library bindings.

## Connection Reservoir

DSQL has a cluster-wide connection rate limit of 100 connections/second with a burst capacity of 1,000. The reservoir pre-creates connections in a background goroutine so `driver.Open()` never blocks on rate limiting.

| Config Field | Default | Rationale |
|---|---|---|
| `dsql.reservoir.enabled` | `true` | Pre-create connections off the request path |
| `dsql.reservoir.target_ready` | `50` | Matches `dsql.max_conns` |
| `dsql.reservoir.base_lifetime` | `11m` | Well under DSQL's 60-minute connection limit |
| `dsql.reservoir.lifetime_jitter` | `2m` | Prevents thundering herd (effective range: 10–12m) |
| `dsql.reservoir.guard_window` | `45s` | Won't hand out connections about to expire |

## Docker Compose Services

```yaml
services:
  elasticsearch:      # Visibility store (ES 8.17.0)
  temporal-history:   # Core workflow engine
  temporal-matching:  # Task queue management
  temporal-frontend:  # API gateway
  temporal-worker:    # System workflows
  temporal-ui:        # Web interface
  mimir:              # Metrics storage (Prometheus-compatible)
  alloy:              # Metrics collection
  grafana:            # Dashboards
```

## Non-Negotiable Rules

### Rust Standards

- Edition 2024, stable toolchain
- `cargo fmt` + `cargo clippy -- -D warnings` must pass with zero warnings
- `thiserror` in the config crate, `eyre` + `color-eyre` in CLI and build crates
- No `.unwrap()` outside tests
- All public types derive `Debug`
- No `unsafe` code

### Config Invariant

- `dsql.max_idle_conns` MUST equal `dsql.max_conns` — this is a DSQL survival invariant, not a suggestion. The config crate validates this at load time.

## Working Agreements

- All CLI commands go through `dsqld` — no standalone bash scripts
- `config.toml` is the single source of truth; `.env` is always generated
- Mirror patterns from `temporal-loom` (exec module, paths module, compose wrapping)
- Mirror patterns from `temporal-dsql-deploy-eks` (TOML config, Dagger client, AWS SDK)

## Troubleshooting

1. **DSQL connection issues** — Check `aws sts get-caller-identity`, verify cluster status
2. **Elasticsearch issues** — `dsqld dev logs elasticsearch`, check http://localhost:9200/_cluster/health
3. **Temporal crash loops** — Check `dsqld dev logs temporal-history` for schema errors, run `dsqld schema setup`
4. **Reservoir empty checkouts** — Check `dsql_reservoir_empty_total` in Grafana, increase `dsql.reservoir.target_ready` in `config.toml`
5. **Shard ownership churn** — Restart all services: `dsqld dev down && dsqld dev up -d`

## Spec Reference

- `.kiro/specs/rust-cli-rewrite/` — Rust CLI rewrite spec (requirements, design, tasks)
