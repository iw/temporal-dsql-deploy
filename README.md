# temporal-dsql-deploy

Local development environment for **Temporal with Aurora DSQL persistence**.

The primary workspace for incremental development of the [DSQL persistence plugin](https://github.com/iw/temporal), a first-class Aurora DSQL backend for Temporal's workflow state storage. Build, run, and observe Temporal against a real DSQL cluster with full observability.

For production deployment, see [temporal-dsql-deploy-ecs](https://github.com/iw/temporal-dsql-deploy-ecs).

## Why DSQL?

[Aurora DSQL](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/what-is.html) is a serverless, PostgreSQL-compatible distributed SQL database from AWS. For Temporal, it replaces the traditional MySQL/PostgreSQL persistence backend with a serverless alternative that eliminates database operations overhead — no capacity planning, no connection management headaches, IAM authentication instead of passwords, and pay-per-transaction pricing.

The DSQL plugin handles the unique characteristics of DSQL: optimistic concurrency control (OCC) with automatic retry, application-level ID generation (DSQL doesn't support `BIGSERIAL`), connection rate limiting (100 conn/sec cluster-wide), and a connection reservoir that pre-creates connections to avoid rate limit pressure in the request path.

## Architecture

Four Temporal services against a DSQL cluster, with Elasticsearch for visibility and a full observability pipeline.

```
┌─────────────────────────────────────────────────────────────────┐
│                    LOCAL DEVELOPMENT (Docker)                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────┐ │
│  │   Temporal UI   │    │ Temporal Client │    │   Python    │ │
│  │  localhost:8080 │    │   Applications  │    │   Tests     │ │
│  └─────────────────┘    └─────────────────┘    └─────────────┘ │
│           │                       │                     │      │
│           └───────────────────────┼─────────────────────┘      │
│                                   │                            │
│  ┌────────────────────────────────▼──────────────────────────┐ │
│  │              TEMPORAL SERVICES (Docker)                    │ │
│  │  ┌───────────┐ ┌───────────┐ ┌───────────┐ ┌───────────┐ │ │
│  │  │ Frontend  │ │  History  │ │ Matching  │ │  Worker   │ │ │
│  │  │  :7233    │ │   :7234   │ │   :7235   │ │   :7239   │ │ │
│  │  └───────────┘ └───────────┘ └───────────┘ └───────────┘ │ │
│  └────────────────────────────────┬──────────────────────────┘ │
│                                   │                            │
│         ┌─────────────────────────┼─────────────────────┐      │
│         ▼                         ▼                     ▼      │
│  ┌─────────────────┐   ┌──────────────────┐   ┌─────────────┐ │
│  │  ELASTICSEARCH  │   │   OBSERVABILITY  │   │  CloudWatch │ │
│  │   (Visibility)  │   │ Alloy → Mimir →  │   │  (AWS DSQL  │ │
│  │   Port 9200     │   │     Grafana      │   │   metrics)  │ │
│  └─────────────────┘   └──────────────────┘   └─────────────┘ │
│                                                                 │
└─────────────────────────────┬───────────────────────────────────┘
                              │
                     ┌────────▼────────┐
                     │   AURORA DSQL   │
                     │  (Persistence)  │
                     │ Public Endpoint │
                     │ + IAM Auth      │
                     └─────────────────┘
```

## Benefits

- **No VPN required** — DSQL's public endpoint with IAM auth means you can develop from anywhere
- **Cost effective** — Pay only for DSQL transactions; Elasticsearch and observability run locally
- **Fast iteration** — Complete environment in minutes; rebuild and restart after code changes
- **Production-representative** — Same DSQL plugin, connection reservoir, and observability as the ECS production deployment
- **Full observability** — Grafana dashboards with Temporal server metrics, DSQL persistence metrics, and CloudWatch integration

## Quick Start

### Prerequisites

- Rust stable toolchain
- Docker and Docker Compose
- AWS CLI configured with appropriate permissions (`dsql:DbConnect`, `dsql:DbConnectAdmin`, `dynamodb:*`)
- [Dagger](https://docs.dagger.io/install/) >= 0.20 (for image builds)
- [temporal-dsql](https://github.com/iw/temporal) — Custom Temporal fork with DSQL persistence support

### 1. Build and Install the CLI

From the repository root:

```bash
cargo install --path crates/cli
```

The `dsqld-build` companion binary (for Dagger image builds):

```bash
cargo install --path crates/build
```

### 2. Initialize Configuration

```bash
dsqld config init --name my-project --region us-east-1
```

This generates a `config.toml` with your project name and region baked in. Both flags are optional (defaults: `temporal-dev`, `eu-west-1`). See `config.example.toml` for all available options.

### 3. Provision Infrastructure

```bash
dsqld infra apply
```

This creates a DSQL cluster with deletion protection and two DynamoDB tables (rate limiter + connection lease) via the AWS SDK. The DSQL endpoint is written back to `config.toml` automatically.

### 4. Build the Temporal DSQL Images

```bash
dsqld build temporal
```

Builds `temporal-dsql-server:latest` and `temporal-dsql-tool:latest` via Dagger. Expects the `temporal-dsql` repo at `../temporal-dsql` (override with `--source`).

### 5. Setup Database Schema

```bash
dsqld schema setup
```

The Elasticsearch visibility index is created automatically by Temporal on startup.

### 6. Start Services

```bash
dsqld dev up -d
```

### 7. Verify

- **Temporal UI**: http://localhost:8080
- **Grafana**: http://localhost:3000 (admin/admin)
- **Elasticsearch**: http://localhost:9200/_cluster/health
- **Temporal gRPC**: `nc -z localhost 7233`

### 8. Cleanup

```bash
dsqld dev down              # stop services, keep data
dsqld dev down -v           # stop services, remove volumes
```

## Connection Reservoir

All configurations enable the DSQL Connection Reservoir by default. DSQL has a cluster-wide connection rate limit of 100 connections/second with a burst capacity of 1,000. Traditional connection pools create connections on-demand, which competes for this budget under load. The reservoir solves this by pre-creating connections in a background goroutine so `driver.Open()` never blocks on rate limiting.

```
┌─────────────┐     ┌─────────────────────────────────────┐
│   Refiller  │────▶│  Channel Buffer (targetReady=50)    │
│  (goroutine)│     │  [conn][conn][conn]...[conn]        │
└─────────────┘     └──────────────────┬──────────────────┘
      │                                │
      │ Creates connections            │ Instant checkout
      │ (rate limited, background)     │ (sub-millisecond)
      ▼                                ▼
┌─────────────┐                ┌─────────────────┐
│ Rate Limiter│                │  database/sql   │
│ (100/sec)   │                │  connection pool │
└─────────────┘                └─────────────────┘
```

| Config Field | Default | Rationale |
|---|---|---|
| `dsql.reservoir.enabled` | `true` | Pre-create connections off the request path |
| `dsql.reservoir.target_ready` | `50` | Matches `dsql.max_conns` |
| `dsql.reservoir.base_lifetime` | `11m` | Well under DSQL's 60-minute connection limit |
| `dsql.reservoir.lifetime_jitter` | `2m` | Prevents thundering herd (effective range: 10–12m) |
| `dsql.reservoir.guard_window` | `45s` | Won't hand out connections about to expire |

This repo also exercises the full distributed coordination stack (DynamoDB-backed rate limiting and connection leasing), which is enabled by default. See the [ECS deployment](https://github.com/iw/temporal-dsql-deploy-ecs) for production configuration details.

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
│   ├── config/                 # TOML model + validation + env gen
│   ├── build/                  # dsqld-build binary (Dagger)
│   └── dagger-client/          # GraphQL client (from EKS repo)
├── dev/                        # Docker Compose dev environment
│   ├── docker-compose.yml
│   ├── config/                 # Alloy, Mimir, Grafana configs
│   └── dynamicconfig/
├── docker/                     # Shared Docker assets
├── grafana/                    # Dashboard JSON
├── dsql-tests/                 # Python integration tests
│   └── pyproject.toml          # Independent Python deps
└── Dockerfile                  # Temporal DSQL runtime image
```

## Observability

### Grafana Dashboards

Two dashboards are provisioned automatically:

1. **Temporal Server Health** (`grafana/server/server.json`)
   - State transitions per second (the primary "forward progress" signal)
   - Service request rates and latencies by operation
   - Workflow and activity outcomes (success, failure, timeout, cancel)
   - History task processing rate and attempt distribution
   - Shard health and membership churn
   - Persistence request rate, latency p95, and errors

2. **DSQL Persistence** (`grafana/dsql/persistence.json`)
   - Connection reservoir: size vs target, checkout latency, refills, empty events, discards by reason
   - Distributed coordination: slot block ownership, utilization, refiller in-flight
   - Persistence: latency by operation (p95), request rate, errors
   - OCC conflicts: conflict rate, retry rate, exhausted retries (collapsed)
   - CloudWatch metrics: DSQL throughput, commit latency, DPU usage, OCC conflicts (collapsed)

### Metrics Pipeline

```
Temporal Services :9090 → Alloy (scraper) → Mimir (storage) → Grafana (dashboards)
                                                                      ↑
                                                              CloudWatch (AWS DSQL)
```

CloudWatch integration requires AWS credentials (`~/.aws` is mounted into the Grafana container). Set the DSQL cluster ID in the dashboard variable to enable the CloudWatch panels.

## CLI Reference

```bash
# Configuration
dsqld config init                    # Generate config.toml with defaults
dsqld config init --name foo --region us-west-2  # With project name and region

# Infrastructure (AWS SDK)
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

## Development Workflow

```bash
# 1. Make changes to the DSQL plugin in ../temporal-dsql
# 2. Rebuild the runtime image
dsqld build temporal

# 3. Restart services
dsqld dev down
dsqld dev up -d

# 4. Run integration tests
cd dsql-tests && uv run python plugin/hello_activity.py
```

## Troubleshooting

1. **DSQL connection issues** — Check AWS credentials (`aws sts get-caller-identity`), verify cluster status (`dsqld infra status`), ensure IAM permissions include `dsql:DbConnect`
2. **Elasticsearch issues** — `dsqld dev logs elasticsearch`, verify health at http://localhost:9200/_cluster/health
3. **Temporal service crash loops** — Check `dsqld dev logs temporal-history` for schema errors. Run `dsqld schema setup` if the schema hasn't been initialized.
4. **Reservoir empty checkouts** — Check `dsql_reservoir_empty_total` in Grafana. If sustained non-zero, increase `dsql.reservoir.target_ready` in `config.toml`.
5. **Shard ownership churn** — If services are stuck in crash loops due to stale cluster membership, restart all services: `dsqld dev down && dsqld dev up -d`

## Related Projects

- [temporal-dsql](https://github.com/iw/temporal) — Custom Temporal fork with Aurora DSQL persistence plugin
- [temporal-dsql-deploy-ecs](https://github.com/iw/temporal-dsql-deploy-ecs) — Production ECS deployment (benchmarked at 150 WPS)

## License

MIT License — see [LICENSE](LICENSE) for details.
