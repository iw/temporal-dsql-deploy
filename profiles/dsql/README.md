# DSQL Profile

Standard development environment for testing Temporal with Aurora DSQL persistence and local Elasticsearch visibility.

## Services

| Service | Port | Description |
|---------|------|-------------|
| temporal-frontend | 7233 | Temporal gRPC API |
| temporal-history | 7234 | History service |
| temporal-matching | 7235 | Matching service |
| temporal-worker | 7239 | System worker |
| temporal-ui | 8080 | Temporal Web UI |
| elasticsearch | 9200 | Visibility store |
| mimir | 9009 | Metrics storage (Prometheus-compatible) |
| alloy | 12345 | Metrics collection |
| grafana | 3000 | Dashboards (admin/admin) |

## Setup

### Prerequisites

- Docker Desktop (4 CPUs, 4 GB memory minimum)
- AWS CLI configured (`~/.aws/credentials`)
- `temporal-dsql-runtime:test` image built from [temporal-dsql](https://github.com/iw/temporal)
- `tdeploy` CLI available (`uv sync` from repo root)

All CLI commands run from the repo root with `uv run tdeploy`.

### 1. Build the Temporal image

```bash
uv run tdeploy build temporal ../temporal-dsql
```

### 2. Deploy shared infrastructure

```bash
uv run tdeploy infra apply-shared --project temporal-dev
```

### 3. Configure environment

```bash
cp .env.example .env
# Edit .env with your DSQL endpoint (from terraform output)
```

### 4. Setup schema

```bash
uv run tdeploy schema setup
```

The Elasticsearch visibility index is created automatically by Temporal on startup.

### 5. Start services

```bash
uv run tdeploy services up -d
```

### 6. Verify

- Temporal UI: http://localhost:8080
- Grafana: http://localhost:3000 (admin/admin)
- Elasticsearch: `curl http://localhost:9200/_cluster/health`

## Stopping

```bash
uv run tdeploy services down              # stop services, keep data
uv run tdeploy services down --volumes    # stop services, remove volumes
```

## Configuration

The `.env` file controls DSQL connection settings and pool configuration. See `.env.example` for all options with documentation.

Key settings:
- `TEMPORAL_SQL_HOST` — DSQL cluster endpoint
- `TEMPORAL_SQL_MAX_CONNS` / `TEMPORAL_SQL_MAX_IDLE_CONNS` — must be equal (prevents pool decay)

The connection reservoir is enabled by default in `docker-compose.yml` with sensible values (target=50, lifetime=11m, jitter=2m, guard=45s). These can be overridden in `.env` if needed.

Distributed rate limiting and connection leasing are disabled — they require DynamoDB and are only needed for multi-instance deployments.

## Shared Resources

This profile references shared files from the repository root via relative paths:
- `../../docker/config/` — Temporal config templates, Mimir config, Alloy config, Grafana provisioning
- `../../grafana/` — Dashboard JSON files (server health, DSQL persistence)
- `../../src/tdeploy/` — CLI source (`uv run tdeploy` from repo root)
