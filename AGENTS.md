# TEMPORAL DSQL DEPLOYMENT GUIDE

## Mission
Local development environment for **Temporal with Aurora DSQL** persistence and **Elasticsearch** visibility. This repository aids development and testing of the DSQL plugin - it is **not** a production deployment solution. For production, see `temporal-dsql-deploy-ecs`.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    TEMPORAL DSQL ARCHITECTURE                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────┐  │
│  │   Temporal UI   │    │ Temporal Client │    │   Python    │  │
│  │  localhost:8080 │    │   Applications  │    │   Samples   │  │
│  └─────────────────┘    └─────────────────┘    └─────────────┘  │
│           │                       │                     │       │
│           └───────────────────────┼─────────────────────┘       │
│                                   │                             │
│  ┌─────────────────────────────────▼─────────────────────────────┐  │
│  │              TEMPORAL SERVICES (Docker)                     │  │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌────────┐ │  │
│  │  │  Frontend   │ │   History   │ │  Matching   │ │ Worker │ │  │
│  │  │   :7233     │ │    :7234    │ │    :7235    │ │  :7239 │ │  │
│  │  └─────────────┘ └─────────────┘ └─────────────┘ └────────┘ │  │
│  └─────────────────────────────────┬─────────────────────────────┘  │
│                                    │                                │
│         ┌──────────────────────────┼──────────────────────────┐     │
│         │                          │                          │     │
│         ▼                          ▼                          │     │
│  ┌─────────────────┐    ┌─────────────────────────────────────▼──┐  │
│  │  ELASTICSEARCH  │    │           AURORA DSQL                 │  │
│  │   (Visibility)  │    │         (Persistence)                │  │
│  │                 │    │                                      │  │
│  │ • Local Docker  │    │ • AWS Managed Service               │  │
│  │ • Port 9200     │    │ • Public Endpoint + IAM Auth        │  │
│  │ • Search/Filter │    │ • Serverless PostgreSQL-compatible │  │
│  │ • UI Queries    │    │ • Workflow State Storage            │  │
│  └─────────────────┘    └──────────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Key Components

1. **Aurora DSQL (AWS)**: Serverless PostgreSQL-compatible persistence layer
   - Stores workflow executions, activities, timers, and all Temporal state
   - Uses IAM authentication and public endpoint access
   - Optimized for DSQL's optimistic concurrency control model

2. **Elasticsearch (Local)**: Visibility and search functionality
   - Indexes workflow metadata for UI queries and advanced search
   - Runs in Docker container for development simplicity
   - Provides fast filtering, sorting, and aggregation capabilities

3. **Temporal Services**: Core workflow orchestration
   - Frontend, History, Matching, and Worker services
   - Custom DSQL plugin with retry logic for serialization conflicts
   - Connection Reservoir for rate-limit-aware connection management

## Quick Start

### Prerequisites
- **Docker & Docker Compose**: Container orchestration
- **AWS CLI**: Configured with appropriate permissions
- **Terraform**: Infrastructure provisioning (v1.0+)
- **temporal-dsql repository**: Built and available at `../temporal-dsql`

### Complete Setup (5 minutes)

```bash
# 1. Set project name for resource management
export PROJECT_NAME="my-temporal-test"

# 2. Build Temporal DSQL runtime image
./scripts/build-temporal-dsql.sh ../temporal-dsql

# 3. Deploy DSQL infrastructure and generate configuration
./scripts/deploy.sh

# 4. Setup database schema
./scripts/setup-schema.sh

# 5. Test complete integration
./scripts/test.sh

# 6. Access Temporal UI
open http://localhost:8080

# 7. Cleanup (when done)
./scripts/cleanup.sh
```

## Connection Reservoir (Recommended)

The DSQL plugin includes a **Connection Reservoir** - a channel-based buffer of pre-created connections that eliminates rate limit pressure in the request path.

### Why Reservoir Mode?

DSQL has a **cluster-wide connection rate limit of 100 connections/second**. Traditional connection pools create connections on-demand, which competes for this budget under load. The reservoir solves this by:

1. **Pre-creating connections** in a background goroutine (the "refiller")
2. **Storing them in a channel buffer** for instant checkout
3. **Proactively evicting** connections before they expire
4. **Never blocking** on rate limiters in the request path

### Configuration

```bash
# Enable reservoir mode (recommended for production)
DSQL_RESERVOIR_ENABLED=true
DSQL_RESERVOIR_TARGET_READY=50      # Connections to maintain
DSQL_RESERVOIR_BASE_LIFETIME=11m    # Connection lifetime
DSQL_RESERVOIR_LIFETIME_JITTER=2m   # Random jitter (9-13m effective)
DSQL_RESERVOIR_GUARD_WINDOW=45s     # Discard if too close to expiry
```

### How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                    CONNECTION RESERVOIR                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐     ┌─────────────────────────────────────┐   │
│  │   Refiller  │────▶│  Channel Buffer (targetReady=50)   │   │
│  │  (goroutine)│     │  [conn][conn][conn]...[conn]       │   │
│  └─────────────┘     └─────────────────────────────────────┘   │
│        │                              │                        │
│        │ Creates connections          │ Instant checkout       │
│        │ (rate limited)               │ (sub-millisecond)      │
│        ▼                              ▼                        │
│  ┌─────────────┐              ┌─────────────────┐              │
│  │ Rate Limiter│              │  database/sql   │              │
│  │ (100/sec)   │              │  connection pool│              │
│  └─────────────┘              └─────────────────┘              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Expected Startup Logs

```
DSQL reservoir starting  target_ready=50 base_lifetime=11m0s jitter=2m0s guard_window=45s
DSQL reservoir refiller started
DSQL reservoir initial fill complete  ready=50 elapsed=5.2s
```

### Metrics

| Metric | Description |
|--------|-------------|
| `dsql_reservoir_size` | Current connections in reservoir |
| `dsql_reservoir_checkouts` | Total successful checkouts |
| `dsql_reservoir_empty_checkouts` | Checkouts when reservoir was empty |
| `dsql_reservoir_discards` | Connections discarded (expired/guard) |
| `dsql_reservoir_refills` | Connections added by refiller |

## Distributed Connection Leasing (Optional)

For multi-service deployments, enable DynamoDB-backed connection leasing to coordinate the global connection count:

```bash
DSQL_DISTRIBUTED_CONN_LEASE_ENABLED=true
DSQL_DISTRIBUTED_CONN_LEASE_TABLE=temporal-dsql-conn-lease
DSQL_DISTRIBUTED_CONN_LIMIT=10000
```

This ensures the cluster doesn't exceed DSQL's 10,000 max connections limit.

## Configuration Details

### Environment Variables (.env)

```bash
# DSQL Configuration (AWS)
TEMPORAL_SQL_HOST=your-cluster.dsql.region.on.aws
TEMPORAL_SQL_PORT=5432
TEMPORAL_SQL_USER=admin
TEMPORAL_SQL_DATABASE=postgres
TEMPORAL_SQL_PLUGIN=dsql
TEMPORAL_SQL_TLS_ENABLED=true
TEMPORAL_SQL_IAM_AUTH=true

# Elasticsearch Configuration (Local)
TEMPORAL_ELASTICSEARCH_HOST=elasticsearch
TEMPORAL_ELASTICSEARCH_PORT=9200
TEMPORAL_ELASTICSEARCH_SCHEME=http
TEMPORAL_ELASTICSEARCH_INDEX=temporal_visibility_v1_dev

# Connection Pool Settings
TEMPORAL_SQL_MAX_CONNS=50
TEMPORAL_SQL_MAX_IDLE_CONNS=50
TEMPORAL_SQL_CONNECTION_TIMEOUT=30s

# Reservoir Configuration (recommended)
DSQL_RESERVOIR_ENABLED=true
DSQL_RESERVOIR_TARGET_READY=50
DSQL_RESERVOIR_BASE_LIFETIME=11m
DSQL_RESERVOIR_LIFETIME_JITTER=2m
DSQL_RESERVOIR_GUARD_WINDOW=45s
```

### Docker Compose Services

```yaml
services:
  elasticsearch:      # Visibility store
  temporal-history:   # Core workflow engine
  temporal-matching:  # Task queue management
  temporal-frontend:  # API gateway
  temporal-worker:    # System workflows
  temporal-ui:        # Web interface
  mimir:              # Metrics storage (Prometheus-compatible)
  alloy:              # Metrics collection (scrapes Temporal services)
  grafana:            # Dashboards and visualization
```

## Operational Procedures

### Daily Operations

```bash
# Check service health
docker compose ps

# View service logs
docker compose logs -f temporal-frontend

# Monitor Elasticsearch
curl http://localhost:9200/_cat/health?v

# Verify DSQL connectivity
aws dsql list-clusters --region eu-west-1
```

### Troubleshooting

#### Service Startup Issues
```bash
# Restart services to clear cached connection states
docker compose restart temporal-history temporal-matching temporal-frontend temporal-worker

# Check Elasticsearch health first
curl http://localhost:9200/_cluster/health?pretty

# Verify DSQL connectivity
aws dsql list-clusters --region eu-west-1
```

#### Common Issues

1. **"Shard status unknown" errors**
   - **Cause**: Service startup timing or cached connection states
   - **Solution**: Restart Temporal services after Elasticsearch is healthy

2. **Elasticsearch connection refused**
   - **Cause**: Elasticsearch not ready during service startup
   - **Solution**: Ensure Elasticsearch health check passes before starting Temporal

3. **DSQL access denied**
   - **Cause**: IAM credentials expired or cluster terminated
   - **Solution**: Check AWS credentials and cluster status

4. **UI not showing workflows**
   - **Cause**: Elasticsearch field mapping issues
   - **Solution**: Recreate index using `./scripts/setup-elasticsearch.sh`

5. **Reservoir empty checkouts**
   - **Cause**: Rate limiter too slow or high connection churn
   - **Solution**: Check `dsql_reservoir_empty_checkouts` metric, increase target_ready

### Cleanup

```bash
# Stop services and clean up resources
./scripts/cleanup.sh

# This will:
# - Stop and remove Docker containers
# - Remove Docker volumes
# - Optionally destroy AWS infrastructure
# - Clean up generated files
```

## Development Workflow

### Code Changes
```bash
# Rebuild images after temporal-dsql changes
./scripts/build-temporal-dsql.sh ../temporal-dsql

# Restart services
docker compose down && docker compose up -d

# Test changes
./scripts/test.sh
```

### Schema Changes
```bash
# Reset schema after changes
./scripts/setup-schema.sh

# Restart services
docker compose restart temporal-history
```

## Schema Setup

**IMPORTANT**: Use `temporal-dsql-tool` for DSQL schema setup:

```bash
# Setup schema using embedded DSQL schema (recommended)
./temporal-dsql-tool \
    --endpoint "$CLUSTER_ENDPOINT" \
    --region "$AWS_REGION" \
    setup-schema \
    --schema-name "dsql/v12/temporal" \
    --version 1.12
```

**For complete reset (with overwrite):**
```bash
./temporal-dsql-tool \
    --endpoint "$CLUSTER_ENDPOINT" \
    --region "$AWS_REGION" \
    setup-schema \
    --schema-name "dsql/v12/temporal" \
    --version 1.12 \
    --overwrite
```

## Grafana Dashboard

Access Grafana at http://localhost:3000 (admin/admin) to monitor:

- `dsql_reservoir_size` - Should stay at target_ready
- `dsql_reservoir_checkouts` - Successful connection checkouts
- `dsql_reservoir_empty_checkouts` - Should be 0 if reservoir is healthy
- `dsql_pool_in_use` - Connections actively in use
- `dsql_tx_conflict_total` - OCC conflicts (expected under load)

## Implementation Status

### ✅ Completed Features
- **DSQL Integration**: Full persistence layer with optimistic concurrency control
- **Connection Reservoir**: Rate-limit-aware connection management
- **Distributed Connection Leasing**: DynamoDB-backed global connection coordination
- **Elasticsearch Integration**: Local visibility store with proper field mappings
- **Docker Orchestration**: Complete service dependency management
- **Schema Management**: Automated setup using temporal-dsql-tool
- **Observability Stack**: Grafana + Alloy + Mimir for metrics and dashboards

### 🚀 Production Ready
- **Core Functionality**: All Temporal features working with DSQL + Elasticsearch
- **UI Integration**: Workflows visible and searchable in Temporal UI
- **Error Handling**: Robust retry logic for DSQL serialization conflicts
- **Monitoring**: Service health checks and connectivity validation

## Related Documentation

- `temporal-dsql/docs/dsql/reservoir-design.md` - Comprehensive reservoir architecture
- `temporal-dsql/docs/dsql/implementation.md` - DSQL plugin implementation details
- `temporal-dsql/docs/dsql/metrics.md` - Metrics reference
