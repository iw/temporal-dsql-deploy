# Copilot Profile

Development environment for the Temporal SRE Copilot. Runs a monitored Temporal cluster alongside the Copilot's own Temporal cluster, with Loki for log collection and Grafana for unified observability.

## Architecture

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

## Services

| Service | Port | Description |
|---------|------|-------------|
| temporal-frontend | 7233 | Monitored cluster gRPC API |
| temporal-ui | 8080 | Temporal Web UI (monitored cluster) |
| elasticsearch | 9200 | Visibility store |
| mimir | 9009 | Metrics storage |
| loki | 3100 | Log aggregation |
| alloy | 12345 | Metrics + log collection |
| grafana | 3000 | Dashboards (admin/admin) |
| copilot-temporal | 7243 | Copilot's own Temporal server |
| copilot-ui | 8082 | Temporal Web UI (copilot cluster) |
| copilot-worker | — | Pydantic AI workflow worker (internal) |
| copilot-api | 8081 | Copilot JSON API |

## Prerequisites

- Docker Desktop (4 CPUs / 6 GB memory minimum, 6 CPUs / 8 GB recommended)
- AWS CLI configured (`~/.aws/credentials`) with permissions for:
  - Aurora DSQL (both clusters)
  - Amazon Bedrock (Claude model invocation, Knowledge Base retrieval)
- `temporal-dsql-runtime:test` image built from [temporal-dsql](https://github.com/iw/temporal)
- `temporal-sre-copilot:dev` image built from [temporal-sre-copilot](https://github.com/iw/temporal-sre-copilot)

## Setup

All CLI commands run from the repo root with `uv run tdeploy` (first-time: `uv sync`).

### 1. Build images

```bash
uv run tdeploy build temporal ../temporal-dsql
uv run tdeploy build copilot ../temporal-sre-copilot
```

### 2. Provision AWS resources

You need two DSQL clusters plus a Bedrock Knowledge Base:
- Shared DSQL cluster for the monitored Temporal deployment (long-lived)
- Copilot DSQL cluster + Bedrock KB for the Copilot (ephemeral)

```bash
# Shared DSQL cluster (if not already provisioned)
uv run tdeploy infra apply-shared --project temporal-dev

# Copilot DSQL cluster + Bedrock Knowledge Base (ephemeral — destroy when done)
uv run tdeploy infra apply-copilot
```

### 3. Setup schemas

```bash
# Temporal persistence schema on the monitored cluster
uv run tdeploy schema setup --profile copilot

# Temporal persistence schema on the copilot cluster
uv run tdeploy schema setup-copilot
```

The Elasticsearch visibility index is created automatically by Temporal on startup.

### 4. Populate Knowledge Base (optional)

Upload the RAG corpus and trigger Bedrock ingestion so the Researcher agent has domain-specific context for explanations.

```bash
# Upload docs to S3 and trigger ingestion (reads terraform outputs automatically)
uv run tdeploy kb populate
```

The RAG corpus is sourced from `../temporal-sre-copilot/docs/rag` by default (override with `--source`). Without this step the Copilot still works — explanations just rely on the LLM's training data instead of project-specific docs.

Other KB commands: `uv run tdeploy kb sync`, `uv run tdeploy kb ingest`, `uv run tdeploy kb status`, `uv run tdeploy kb jobs`.

### 5. Configure environment

```bash
cp .env.example .env
```

Edit `.env` with:
- `TEMPORAL_SQL_HOST` — monitored cluster DSQL endpoint
- `COPILOT_DSQL_HOST` — copilot cluster DSQL endpoint
- `COPILOT_KNOWLEDGE_BASE_ID` — Bedrock KB ID (from `terraform output knowledge_base_id`)

### 6. Start everything

```bash
uv run tdeploy services up -p copilot -d
```

### 7. Verify

- Temporal UI: http://localhost:8080 (monitored cluster)
- Grafana: http://localhost:3000 (admin/admin) — includes Copilot dashboard
- Copilot API: http://localhost:8081/status
- Loki: `curl http://localhost:3100/ready`

## Stopping

```bash
uv run tdeploy services down -p copilot              # stop services, keep data
uv run tdeploy services down -p copilot --volumes    # stop services, remove volumes

# Destroy ephemeral Copilot infrastructure when done
uv run tdeploy infra destroy-copilot
```

## How It Works

### Metrics flow
Alloy scrapes Prometheus metrics from all four Temporal services on port 9090 and remote-writes to Mimir. The Copilot worker queries Mimir's Prometheus-compatible API at `http://mimir:9009/prometheus`.

### Log flow
Alloy connects to the Docker socket, discovers all containers, and ships their logs to Loki. The Copilot worker queries Loki at `http://loki:3100` for narrative signals (error patterns, membership changes, OCC failures).

### Health assessment flow
The Copilot worker runs Pydantic AI workflows on its own Temporal cluster:
1. `ObserveClusterWorkflow` queries Mimir every 30s, evaluates health state (deterministic rules)
2. On state change, `AssessHealthWorkflow` calls Bedrock Claude to explain the state
3. Assessments are stored in the Copilot's DSQL cluster
4. `copilot-api` serves assessments to Grafana via JSON API

### Grafana
Three dashboard folders are provisioned:
- Temporal (server metrics)
- DSQL (persistence metrics)
- Copilot (health state, signal taxonomy, log patterns)

The Copilot dashboard uses the `marcusolsson-json-datasource` plugin (auto-installed) to query `copilot-api:8080`.

## AWS Credentials

All services that need AWS access mount `~/.aws` read-only:
- Temporal services → DSQL IAM authentication
- Copilot worker → DSQL + Bedrock (model invocation + KB retrieval)
- Copilot API → DSQL
- Grafana → CloudWatch datasource

Ensure your AWS profile has permissions for both DSQL clusters and Bedrock.

## Configuration

### Copilot-specific environment variables

| Variable | Description | Default |
|----------|-------------|---------|
| `COPILOT_DSQL_HOST` | DSQL endpoint for Copilot state store | (required) |
| `COPILOT_DSQL_DATABASE` | Database name | `postgres` |
| `COPILOT_KNOWLEDGE_BASE_ID` | Bedrock KB ID for RAG | (empty = skip RAG) |

### Resource tuning

The Copilot Temporal server uses a small pool (10 connections) since it only runs Copilot workflows. If you see connection pressure, increase `TEMPORAL_SQL_MAX_CONNS` in the `copilot-temporal` service environment.

## Shared Resources

This profile references shared files from the repository root:
- `../../docker/config/` — Temporal config templates, Mimir config
- `../../grafana/` — Dashboard JSON files (server, dsql, copilot)
- `../../src/tdeploy/` — CLI source (`uv run tdeploy` from repo root)
