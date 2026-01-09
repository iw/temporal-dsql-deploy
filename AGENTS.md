# TEMPORAL DSQL DEPLOYMENT GUIDE

## Mission
Deploy and operate Temporal with **Aurora DSQL** as the persistence layer and **Elasticsearch** as the visibility store. This repository provides a complete, production-ready solution for running Temporal with DSQL's serverless PostgreSQL-compatible database.

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
│  │ • Search/Filter │    │ • Serverless PostgreSQL             │  │
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
   - Optimized connection pooling for serverless architecture

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
```

### Verification

```bash
# Check service health
docker compose ps

# View logs
docker compose logs -f temporal-frontend

# Test with Python sample
cd samples-python
uv run hello_activity.py

# Monitor Elasticsearch
curl http://localhost:9200/_cat/health?v
```

## Detailed Setup Process

### Step 1: Build Docker Images

```bash
# Build for your architecture (auto-detected)
./scripts/build-temporal-dsql.sh ../temporal-dsql

# Or specify architecture explicitly
./scripts/build-temporal-dsql.sh ../temporal-dsql arm64  # Apple Silicon
./scripts/build-temporal-dsql.sh ../temporal-dsql amd64  # Intel/AMD
```

**Output Images:**
- `temporal-dsql:latest` - Base image from temporal-dsql repository
- `temporal-dsql-runtime:test` - Deployment runtime with DSQL configuration

### Step 2: Deploy Infrastructure

```bash
# Set project name (important for cleanup)
export PROJECT_NAME="my-temporal-test"

# Deploy DSQL cluster and generate environment
./scripts/deploy.sh
```

**What this creates:**
- Aurora DSQL cluster with public endpoint
- IAM authentication configuration
- Environment file (`.env`) with connection details
- Terraform state for infrastructure management

### Step 3: Setup Database Schema

```bash
# Initialize DSQL schema using Helm chart approach
./scripts/setup-schema.sh
```

**Schema setup process:**
1. Creates database if needed
2. Sets up base schema (version 0)
3. Updates to latest schema version using versioned migration files
4. Validates table creation

### Step 4: Start Services

```bash
# Start all services with proper dependency order
docker compose up -d

# Check service health
docker compose ps
```

**Service startup order:**
1. Elasticsearch (with health check)
2. History service (depends on Elasticsearch)
3. Matching service (depends on History)
4. Frontend service (depends on Matching)
5. Worker service (depends on Frontend)
6. Temporal UI (depends on Frontend)

### Step 5: Setup Elasticsearch Index

```bash
# Create visibility index with proper field mappings
./scripts/setup-elasticsearch.sh
```

**Elasticsearch setup:**
- Uses `temporal-elasticsearch-tool` (preferred) or curl fallback
- Creates proper field mappings for UI compatibility
- Validates search functionality
- Provides health check information

### Step 6: Test Integration

```bash
# Run comprehensive integration tests
./scripts/test.sh

# Or test manually with Python samples
cd samples-python
uv run hello_activity.py
```

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

# Connection Pool Settings (optimized for DSQL)
TEMPORAL_SQL_MAX_CONNS=20
TEMPORAL_SQL_MAX_IDLE_CONNS=5
TEMPORAL_SQL_CONNECTION_TIMEOUT=30s
TEMPORAL_SQL_MAX_CONN_LIFETIME=300s
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
```

### Persistence Configuration

The system uses a dual-store approach:
- **DSQL**: All workflow state, executions, activities, timers
- **Elasticsearch**: Workflow metadata for search and UI queries

## Operational Procedures

### Daily Operations

```bash
# Check service health
docker compose ps

# View service logs
docker compose logs -f temporal-frontend

# Monitor Elasticsearch
curl http://localhost:9200/_cat/health?v

# Check DSQL connectivity
./scripts/test-dsql-connectivity.sh
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
docker compose restart

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

### Configuration Changes
```bash
# Edit .env or docker-compose.yml
vim .env

# Restart affected services
docker compose restart
```

## Production Considerations

### Security
- **Use AWS Secrets Manager** for database credentials
- **Configure IAM roles** for DSQL authentication
- **Enable VPC endpoints** for private connectivity
- **Implement least-privilege access** policies

### Monitoring
- **DSQL Metrics**: Connection pool utilization, query latency, conflict rates
- **Elasticsearch Health**: Cluster status, index size, query performance
- **Temporal Metrics**: Workflow throughput, task queue depth, service health

### Scaling
- **DSQL**: Automatically scales with demand (serverless)
- **Elasticsearch**: Consider cluster deployment for production
- **Temporal Services**: Scale horizontally by adding more containers

### Backup & Recovery
- **DSQL**: Automatic backups and point-in-time recovery
- **Elasticsearch**: Regular index snapshots
- **Configuration**: Version control all configuration files

## Architecture Benefits

### Cost Optimization
- **DSQL**: Pay only for actual usage (serverless)
- **Local Elasticsearch**: No AWS OpenSearch costs during development
- **Simplified Infrastructure**: Minimal AWS resources required

### Operational Simplicity
- **No VPN Setup**: Direct public endpoint access to DSQL
- **Local Development**: Full control over Elasticsearch
- **Fast Iteration**: Quick setup and teardown cycles

### Production Ready
- **DSQL Optimizations**: Custom retry logic for optimistic concurrency
- **Proper Field Mappings**: UI compatibility with correct Elasticsearch schema
- **Health Checks**: Comprehensive service monitoring and dependency management
- **IAM Authentication**: Secure, credential-free database access

## Implementation Status

### ✅ Completed Features
- **DSQL Integration**: Full persistence layer with optimistic concurrency control
- **Elasticsearch Integration**: Local visibility store with proper field mappings
- **Docker Orchestration**: Complete service dependency management
- **Schema Management**: Automated setup using temporal-sql-tool
- **Testing Framework**: Comprehensive integration testing
- **Documentation**: Complete setup and operational guides

### 🚀 Production Ready
- **Core Functionality**: All Temporal features working with DSQL + Elasticsearch
- **UI Integration**: Workflows visible and searchable in Temporal UI
- **Sample Applications**: Python samples executing successfully
- **Error Handling**: Robust retry logic for DSQL serialization conflicts
- **Monitoring**: Service health checks and connectivity validation

This architecture provides a robust, cost-effective solution for running Temporal with Aurora DSQL persistence and Elasticsearch visibility, suitable for both development and production environments.

## Critical Schema Setup Commands

**IMPORTANT**: Use `temporal-dsql-tool` for DSQL schema setup. This is the canonical command:

```bash
# Setup schema using embedded DSQL schema (recommended)
# Note: --version is required to create schema_version table needed by Temporal server
./temporal-dsql-tool \
    --endpoint "$CLUSTER_ENDPOINT" \
    --region "$AWS_REGION" \
    setup-schema \
    --schema-name "dsql/v12/temporal" \
    --version 1.12
```

**For complete reset (with overwrite):**
```bash
# Drop existing tables and recreate schema
./temporal-dsql-tool \
    --endpoint "$CLUSTER_ENDPOINT" \
    --region "$AWS_REGION" \
    setup-schema \
    --schema-name "dsql/v12/temporal" \
    --version 1.12 \
    --overwrite
```

**Note**: `temporal-dsql-tool` uses IAM authentication automatically and has the DSQL schema embedded.
**Important**: Do NOT use `--disable-versioning` as Temporal server requires the `schema_version` table at startup.