# temporal-dsql-deploy

## Mission

Local development environment for two interrelated projects:

1. **DSQL persistence plugin** — The [temporal-dsql](https://github.com/iw/temporal) fork adds Aurora DSQL as a first-class persistence backend for Temporal. This repo provides the Docker Compose stack to build, run, and observe Temporal against a real DSQL cluster with full observability.

2. **Temporal SRE Copilot** — The [temporal-sre-copilot](https://github.com/iw/temporal-sre-copilot) is an AI-powered observability agent that monitors a Temporal+DSQL deployment, derives health state from forward progress signals, and uses LLMs to explain what's happening. This repo provides the monitored cluster, observability stack (Mimir + Loki), and a second Temporal cluster for the Copilot's own Pydantic AI workflows.

Both use cases share the same foundation: Temporal services against Aurora DSQL, Elasticsearch for visibility, and Grafana for dashboards. The Copilot profile extends this with Loki, a second Temporal cluster, and Amazon Bedrock integration.

This is **not** a production deployment solution. For production, see `temporal-dsql-deploy-ecs`.

## Architecture

### DSQL Profile — Plugin development

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

### Copilot Profile — SRE Copilot development

Everything in the DSQL profile, plus Loki for log collection, a second Temporal cluster for the Copilot's own Pydantic AI workflows, and Bedrock integration for AI-powered health assessments.

```
┌─────────────────────────────────────────────────────────────────────┐
│                     DOCKER COMPOSE NETWORK                          │
│                                                                     │
│  MONITORED CLUSTER              OBSERVABILITY        COPILOT        │
│  ┌──────────────────┐          ┌────────────┐       ┌────────────┐ │
│  │ temporal-frontend │──┐      │ mimir      │       │ copilot-   │ │
│  │ temporal-history  │  │      │ (metrics)  │◄──────│ temporal   │ │
│  │ temporal-matching │  ├─────▶│            │       │            │ │
│  │ temporal-worker   │  │      ├────────────┤       ├────────────┤ │
│  └──────────────────┘  │      │ loki       │       │ copilot-   │ │
│  ┌──────────────────┐  │      │ (logs)     │◄──────│ worker     │ │
│  │ elasticsearch    │  │      ├────────────┤       │ (Pydantic  │ │
│  │ temporal-ui      │  │      │ alloy      │       │  AI)       │ │
│  └──────────────────┘  │      │ (collector)│       ├────────────┤ │
│                        │      ├────────────┤       │ copilot-   │ │
│                        └─────▶│ grafana    │◄──────│ api        │ │
│                               │ :3000      │       │ :8081      │ │
│                               └────────────┘       └────────────┘ │
│                                                          │        │
│  ┌──────────────────┐                          ┌─────────▼──────┐ │
│  │ Aurora DSQL      │                          │ Aurora DSQL    │ │
│  │ (monitored)      │                          │ (copilot)      │ │
│  └──────────────────┘                          └────────────────┘ │
│                                                          │        │
│                                                ┌─────────▼──────┐ │
│                                                │ Amazon Bedrock │ │
│                                                │ (Claude, KB)   │ │
│                                                └────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

## Quick Start

### Prerequisites
- Docker & Docker Compose
- AWS CLI configured with appropriate permissions
- Python 3.14+ and [uv](https://docs.astral.sh/uv/)
- [Terraform](https://www.terraform.io/downloads) >= 1.0
- [temporal-dsql](https://github.com/iw/temporal) repository built and available at `../temporal-dsql`

### Setup

```bash
# 1. Install CLI
uv sync

# 2. Provision shared DSQL cluster (one-time)
uv run tdeploy infra apply-shared --project temporal-dev

# 3. Build Temporal DSQL runtime image
uv run tdeploy build temporal ../temporal-dsql

# 4. Configure environment
cd profiles/dsql && cp .env.example .env
# Edit .env — set TEMPORAL_SQL_HOST from terraform output

# 5. Setup DSQL schema
uv run tdeploy schema setup

# 6. Start services
uv run tdeploy services up -d

# 7. Verify
open http://localhost:8080    # Temporal UI
open http://localhost:3000    # Grafana (admin/admin)

# 8. Cleanup
uv run tdeploy services down
```

### Copilot Setup

```bash
# Provision ephemeral Copilot infrastructure (DSQL cluster + Bedrock KB)
uv run tdeploy infra apply-copilot

# Build both images
uv run tdeploy build temporal ../temporal-dsql
uv run tdeploy build copilot ../temporal-sre-copilot

# Configure and start
cd profiles/copilot && cp .env.example .env
# Edit .env — set both DSQL endpoints + Bedrock KB ID
cd ../..
uv run tdeploy schema setup --profile copilot
uv run tdeploy schema setup-copilot
uv run tdeploy services up -p copilot -d

# When done
uv run tdeploy services down -p copilot
uv run tdeploy infra destroy-copilot
```

## Profiles

| Profile | Purpose | Services | Memory |
|---------|---------|----------|--------|
| [dsql](profiles/dsql/) | DSQL plugin development and testing | 9 (Temporal + ES + observability) | ~3.5 GB |
| [copilot](profiles/copilot/) | SRE Copilot development with monitored cluster | 15 (above + Loki + Copilot cluster + Bedrock) | ~5 GB |

## Project Structure

```
temporal-dsql-deploy/
├── src/tdeploy/               # Typer CLI (uv run tdeploy)
│   ├── main.py                # App with subcommands
│   ├── infra.py               # infra apply-shared / apply-copilot / destroy-copilot
│   ├── build.py               # build temporal / copilot
│   ├── kb.py                  # kb sync / ingest / status (Knowledge Base)
│   ├── schema.py              # schema setup / setup-copilot
│   └── services.py            # services up / down / ps / logs
├── terraform/                 # Modular Terraform
│   ├── shared/                # Long-lived: DSQL cluster + optional DynamoDB
│   └── copilot/               # Ephemeral: Copilot DSQL cluster + Bedrock KB
├── profiles/                  # Deployment profiles
│   ├── dsql/                  # DSQL development profile
│   │   ├── docker-compose.yml
│   │   ├── .env.example
│   │   ├── dynamicconfig/
│   │   └── README.md
│   └── copilot/               # SRE Copilot profile
│       ├── docker-compose.yml
│       ├── .env.example
│       ├── config/            # Loki, Alloy, Grafana config
│       ├── dynamicconfig/
│       └── README.md
├── docker/                    # Shared Docker configuration
│   └── config/                # Config templates and provisioning
├── grafana/                   # Shared Grafana dashboards
│   ├── server/server.json     # Temporal server health
│   ├── dsql/persistence.json  # DSQL persistence metrics
│   └── copilot/copilot.json   # SRE Copilot health state
├── dsql-tests/                # Python integration tests
│   ├── temporal/              # Temporal feature validation on DSQL
│   ├── plugin/                # DSQL plugin validation
│   └── copilot/               # Copilot stress & integration tests
├── Dockerfile                 # Temporal DSQL runtime image
└── pyproject.toml             # Project config (uv)
```

## CLI Reference

All commands run from the repo root with `uv run tdeploy`:

```bash
# Infrastructure
uv run tdeploy infra apply-shared -p temporal-dev
uv run tdeploy infra apply-copilot
uv run tdeploy infra destroy-copilot
uv run tdeploy infra status

# Build
uv run tdeploy build temporal ../temporal-dsql
uv run tdeploy build copilot ../temporal-sre-copilot

# Schema
uv run tdeploy schema setup
uv run tdeploy schema setup --profile copilot
uv run tdeploy schema setup-copilot

# Services
uv run tdeploy services up -d
uv run tdeploy services up -p copilot -d
uv run tdeploy services down
uv run tdeploy services down -v
uv run tdeploy services ps
uv run tdeploy services logs -f temporal-history

# Knowledge Base (copilot profile)
uv run tdeploy kb populate
uv run tdeploy kb sync
uv run tdeploy kb ingest
uv run tdeploy kb status
```

## Connection Reservoir

DSQL has a cluster-wide connection rate limit of 100 connections/second with a burst capacity of 1,000. The reservoir pre-creates connections in a background goroutine so `driver.Open()` never blocks on rate limiting.

| Setting | Default | Rationale |
|---------|---------|-----------|
| `DSQL_RESERVOIR_ENABLED` | `true` | Pre-create connections off the request path |
| `DSQL_RESERVOIR_TARGET_READY` | `50` | Matches `TEMPORAL_SQL_MAX_CONNS` |
| `DSQL_RESERVOIR_BASE_LIFETIME` | `11m` | Well under DSQL's 60-minute connection limit |
| `DSQL_RESERVOIR_LIFETIME_JITTER` | `2m` | Prevents thundering herd (effective range: 10–12m) |
| `DSQL_RESERVOIR_GUARD_WINDOW` | `45s` | Won't hand out connections about to expire |

Distributed rate limiting and connection leasing (DynamoDB-backed) are available for multi-instance deployments but disabled for local dev.

## Docker Compose Services

### DSQL Profile
```yaml
services:
  elasticsearch:      # Visibility store
  temporal-history:   # Core workflow engine
  temporal-matching:  # Task queue management
  temporal-frontend:  # API gateway
  temporal-worker:    # System workflows
  temporal-ui:        # Web interface
  mimir:              # Metrics storage (Prometheus-compatible)
  alloy:              # Metrics collection
  grafana:            # Dashboards
```

### Copilot Profile (extends DSQL)
Adds: `loki`, `copilot-temporal`, `copilot-ui`, `copilot-worker`, `copilot-api`, plus `elasticsearch-setup` uses `temporalio/auto-setup` for ES index creation.

## Elasticsearch Setup

The `elasticsearch-setup` init container uses the `temporalio/auto-setup` image (which has curl and the ES schema files) to apply cluster settings, index templates, and create visibility indices. This runs once and exits.

## Working Agreements

- Mirror existing code style, naming, and error handling patterns
- All CLI commands go through `uv run tdeploy` — no standalone bash scripts
- Profiles are self-contained: each has its own `.env`, config, and compose file
- Shared resources live at the repo root: `docker/config/`, `grafana/`, `src/tdeploy/`
- Terraform is split by lifecycle: `shared/` (long-lived) vs `copilot/` (ephemeral)
- Connection pool: `MaxIdleConns` MUST equal `MaxConns` to prevent pool decay

## Troubleshooting

1. **DSQL connection issues** — Check `aws sts get-caller-identity`, verify cluster status
2. **Elasticsearch issues** — `docker compose logs elasticsearch`, check http://localhost:9200/_cluster/health
3. **Temporal crash loops** — Check logs for schema errors, run `uv run tdeploy schema setup`
4. **Reservoir empty checkouts** — Check `dsql_reservoir_empty_total` in Grafana, increase target
5. **Shard ownership churn** — Restart all services: `uv run tdeploy services down && uv run tdeploy services up -d`
