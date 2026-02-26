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

- Docker and Docker Compose
- AWS CLI configured with appropriate permissions (`dsql:DbConnect`, `dsql:DbConnectAdmin`)
- Python 3.14+ and [uv](https://docs.astral.sh/uv/)
- [Terraform](https://www.terraform.io/downloads) >= 1.0
- [temporal-dsql](https://github.com/iw/temporal) — Custom Temporal fork with DSQL persistence support

### 1. Install the CLI

From the repository root:

```bash
uv sync
```

All CLI commands are invoked with `uv run tdeploy` from the repo root:

```bash
uv run tdeploy --help
```

### 2. Provision Infrastructure

```bash
uv run tdeploy infra apply-shared --project temporal-dev
```

This creates a long-lived DSQL cluster (with `prevent_destroy`). Run once, then forget about it.

### 3. Build the Temporal DSQL Runtime Image

```bash
uv run tdeploy build temporal ../temporal-dsql
```

### 4. Configure

```bash
cd profiles/dsql
cp .env.example .env
# Edit .env — set TEMPORAL_SQL_HOST from the terraform output
```

### 5. Setup Database Schema

```bash
uv run tdeploy schema setup
```

The Elasticsearch visibility index is created automatically by Temporal on startup.

### 6. Start Services

```bash
uv run tdeploy services up -d
```

### 7. Verify

- **Temporal UI**: http://localhost:8080
- **Grafana**: http://localhost:3000 (admin/admin)
- **Elasticsearch**: http://localhost:9200/_cluster/health
- **Temporal gRPC**: `nc -z localhost 7233`

### 8. Cleanup

```bash
uv run tdeploy services down              # stop services, keep data
uv run tdeploy services down --volumes    # stop services, remove volumes
```

## Connection Reservoir

All profiles enable the DSQL Connection Reservoir by default. DSQL has a cluster-wide connection rate limit of 100 connections/second with a burst capacity of 1,000. Traditional connection pools create connections on-demand, which competes for this budget under load. The reservoir solves this by pre-creating connections in a background goroutine so `driver.Open()` never blocks on rate limiting.

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

| Setting | Default | Rationale |
|---------|---------|-----------|
| `DSQL_RESERVOIR_ENABLED` | `true` | Pre-create connections off the request path |
| `DSQL_RESERVOIR_TARGET_READY` | `50` | Matches `TEMPORAL_SQL_MAX_CONNS` |
| `DSQL_RESERVOIR_BASE_LIFETIME` | `11m` | Well under DSQL's 60-minute connection limit |
| `DSQL_RESERVOIR_LIFETIME_JITTER` | `2m` | Prevents thundering herd (effective range: 10–12m) |
| `DSQL_RESERVOIR_GUARD_WINDOW` | `45s` | Won't hand out connections about to expire |

Distributed rate limiting and connection leasing (DynamoDB-backed) are available for multi-instance deployments but disabled for local dev. See the [ECS deployment](https://github.com/iw/temporal-dsql-deploy-ecs) for production configuration.

## Project Structure

```
temporal-dsql-deploy/
├── src/tdeploy/                   # Typer CLI (uv run tdeploy)
│   ├── main.py                    # App with subcommands
│   ├── infra.py                   # tdeploy infra apply-shared / status
│   ├── build.py                   # tdeploy build temporal
│   ├── schema.py                  # tdeploy schema setup
│   └── services.py               # tdeploy services up / down / ps / logs
├── terraform/
│   └── shared/                    # Long-lived: DSQL cluster + optional DynamoDB
├── profiles/
│   └── dsql/                      # DSQL development profile
│       ├── docker-compose.yml     # Temporal + ES + observability
│       ├── .env.example           # Environment template
│       ├── dynamicconfig/         # Temporal dynamic configuration
│       └── README.md
├── docker/                        # Shared Docker configuration
│   └── config/                    # Config templates and provisioning
├── grafana/                       # Grafana dashboards
│   ├── server/server.json         # Temporal server health
│   └── dsql/persistence.json      # DSQL persistence metrics
├── dsql-tests/                    # Python integration tests
│   ├── temporal/                  # Temporal feature validation on DSQL
│   └── plugin/                    # DSQL plugin validation
└── Dockerfile                     # Temporal DSQL runtime image
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

### DSQL Plugin Metrics

The DSQL plugin emits these metrics via OpenTelemetry:

| Metric | Type | Description |
|--------|------|-------------|
| `dsql_reservoir_size` | Gauge | Current connections in reservoir |
| `dsql_reservoir_target` | Gauge | Configured reservoir target |
| `dsql_reservoir_checkouts_total` | Counter | Successful checkouts |
| `dsql_reservoir_empty_total` | Counter | Checkouts when reservoir was empty (should be 0) |
| `dsql_reservoir_discards_total` | Counter | Connections discarded (by reason: expiry, guard, error) |
| `dsql_reservoir_refills_total` | Counter | Connections added by refiller |
| `dsql_refiller_inflight` | Gauge | Current concurrent Open() calls |
| `dsql_pool_in_use` | Gauge | Connections actively executing queries |
| `dsql_pool_idle` | Gauge | Idle connections in pool |
| `dsql_tx_conflict_total` | Counter | OCC serialization conflicts |
| `dsql_tx_retry_total` | Counter | Transaction retry attempts |
| `dsql_tx_exhausted_total` | Counter | Retries exhausted (terminal failures) |

## CLI Reference

```bash
# Infrastructure
uv run tdeploy infra apply-shared -p temporal-dev     # Provision DSQL + optional DynamoDB
uv run tdeploy infra status                           # Show what's provisioned

# Build
uv run tdeploy build temporal ../temporal-dsql        # Build runtime images

# Schema
uv run tdeploy schema setup                           # Setup DSQL schema

# Services
uv run tdeploy services up -d                         # Start services
uv run tdeploy services down                          # Stop services
uv run tdeploy services down -v                       # Stop and remove volumes
uv run tdeploy services ps                            # Show running services
uv run tdeploy services logs -f temporal-history      # Follow service logs
```

First-time setup: `uv sync`

## Infrastructure

Terraform manages a single long-lived module:

| Module | Lifecycle | Resources | Command |
|--------|-----------|-----------|---------|
| `terraform/shared/` | Long-lived | DSQL cluster, DynamoDB tables (optional) | `tdeploy infra apply-shared` |

Shared resources use `prevent_destroy` and `deletion_protection_enabled = true`. They persist across service restarts and schema resets. The DynamoDB tables (for distributed rate limiting and connection leasing) are optional — only needed for multi-instance deployments.

## Development Workflow

```bash
# 1. Make changes to the DSQL plugin in ../temporal-dsql
# 2. Rebuild the runtime image
uv run tdeploy build temporal ../temporal-dsql

# 3. Restart services
uv run tdeploy services down
uv run tdeploy services up -d

# 4. Run integration tests
cd dsql-tests
uv run pytest
```

## Troubleshooting

1. **DSQL connection issues** — Check AWS credentials (`aws sts get-caller-identity`), verify cluster status (`aws dsql list-clusters --region eu-west-1`), ensure IAM permissions include `dsql:DbConnect`
2. **Elasticsearch issues** — `docker compose logs elasticsearch`, verify health at http://localhost:9200/_cluster/health
3. **Temporal service crash loops** — Check `docker compose logs temporal-history` for schema errors. Run `uv run tdeploy schema setup` if the schema hasn't been initialized.
4. **Reservoir empty checkouts** — Check `dsql_reservoir_empty_total` in Grafana. If sustained non-zero, increase `DSQL_RESERVOIR_TARGET_READY` or check rate limiter logs.
5. **Shard ownership churn** — If services are stuck in crash loops due to stale cluster membership, restart all services: `docker compose down && docker compose up -d`

## Related Projects

- [temporal-dsql](https://github.com/iw/temporal) — Custom Temporal fork with Aurora DSQL persistence plugin
- [temporal-dsql-deploy-ecs](https://github.com/iw/temporal-dsql-deploy-ecs) — Production ECS deployment with Terraform (benchmarked at 150 WPS)

## License

MIT License — see [LICENSE](LICENSE) for details.
