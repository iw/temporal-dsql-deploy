# temporal-dsql-deploy

Streamlined deployment for Temporal with Aurora DSQL persistence and local Elasticsearch visibility.

> **🔐 Security Note**: This project is configured for **development and testing**.

## Quick Start

### Prerequisites
- Docker and Docker Compose
- AWS CLI configured with appropriate permissions
- [temporal-dsql](https://github.com/iw/temporal) - Custom Temporal fork with DSQL persistence support (build the runtime image first)

### 1. Deploy Infrastructure
```bash
# Deploy Aurora DSQL cluster and generate environment
./scripts/deploy.sh
```

### 2. Setup Database Schema
```bash
# Initialize DSQL database schema
./scripts/setup-schema.sh
```

### 3. Test Complete Setup
```bash
# Test DSQL + Elasticsearch integration
./scripts/test.sh
```

### 4. Access Services
- **Temporal UI**: http://localhost:8080
- **Grafana**: http://localhost:3000 (admin/admin)
- **Elasticsearch**: http://localhost:9200
- **Temporal gRPC**: localhost:7233
- **Alloy UI**: http://localhost:12345

### 5. Cleanup
```bash
# Stop services and optionally destroy AWS resources
./scripts/cleanup.sh
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    LOCAL DEVELOPMENT                            │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐    ┌─────────────────┐                    │
│  │ Temporal        │    │ Elasticsearch   │                    │
│  │ Services        │    │ Container       │                    │
│  │ (Docker)        │    │ :9200           │                    │
│  └─────────────────┘    └─────────────────┘                    │
│           │                       │                            │
└───────────┼───────────────────────┼────────────────────────────┘
            │                       │
            │              ┌────────▼────────┐
            │              │ Local Docker    │
            │              │ Network         │
            │              │ (Visibility)    │
            │              └─────────────────┘
            │
            └───────────────────────────────────────────────────┐
                                                                │
                                                       ┌────────▼────────┐
                                                       │ Aurora DSQL     │
                                                       │ Public Endpoint │
                                                       │ (Persistence)   │
                                                       └─────────────────┘
                                                                │
┌─────────────────────────────────────────────────────────────────┘
│                        AWS CLOUD
└─────────────────────────────────────────────────────────────────┘
```

## Benefits

- **Simplified Setup**: No VPN or complex networking required
- **Cost Effective**: Only pay for DSQL usage, Elasticsearch runs locally
- **Development Friendly**: Full control over Elasticsearch configuration
- **Fast Iteration**: Complete environment in minutes

## Manual Setup

If you prefer manual control:

### 1. Setup Environment
```bash
# Copy and edit configuration
cp .env.example .env
# Edit .env with your DSQL endpoint
```

### 2. Deploy DSQL Only
```bash
cd terraform
terraform init
terraform apply -var "project_name=my-temporal-test"
```

### 3. Setup Schema
```bash
# Update .env with DSQL endpoint from Terraform output
# Uses temporal-dsql-tool with embedded DSQL schema
./scripts/setup-schema.sh
```

### 4. Start Services
```bash
docker compose up -d
```

## Project Structure

```
temporal-dsql-deploy/
├── docker-compose.yml              # Main Docker Compose configuration
├── .env.example                    # Environment template
├── terraform/                      # DSQL infrastructure
│   ├── main.tf                    # DSQL cluster definition
│   └── variables.tf               # Configuration variables
├── docker/                        # Docker configuration
│   └── config/                    # Temporal config templates
│       ├── persistence-dsql-elasticsearch.template.yaml
│       ├── grafana-datasources.yaml
│       └── grafana-dashboards.yaml
├── grafana/                       # Grafana dashboards
│   ├── server/server.json         # Temporal server metrics
│   └── dsql/persistence.json      # DSQL persistence metrics
├── scripts/                       # Automation scripts
│   ├── deploy.sh                  # Deploy infrastructure + setup
│   ├── test.sh                    # Test complete integration
│   ├── cleanup.sh                 # Cleanup resources
│   ├── setup-schema.sh            # DSQL schema setup
│   └── setup-elasticsearch.sh     # Elasticsearch index setup
└── dynamicconfig/                 # Temporal dynamic configuration
```

## Key Scripts

- **`./scripts/deploy.sh`**: Infrastructure deployment + environment setup
- **`./scripts/setup-schema.sh`**: Database schema initialization (uses temporal-dsql-tool)
- **`./scripts/test.sh`**: Integration testing and validation
- **`./scripts/cleanup.sh`**: Resource cleanup (Docker + AWS)
- **`./scripts/build-temporal-dsql.sh`**: Docker image building
- **`./scripts/setup-elasticsearch.sh`**: Elasticsearch index setup

## Configuration

### Environment Variables (.env)
```bash
# DSQL Configuration
TEMPORAL_SQL_HOST=your-cluster-id.dsql.region.on.aws
TEMPORAL_SQL_PORT=5432
TEMPORAL_SQL_USER=admin
TEMPORAL_SQL_DATABASE=postgres
TEMPORAL_SQL_PLUGIN=dsql
TEMPORAL_SQL_TLS_ENABLED=true
TEMPORAL_SQL_IAM_AUTH=true

# Elasticsearch Configuration
TEMPORAL_ELASTICSEARCH_HOST=elasticsearch
TEMPORAL_ELASTICSEARCH_PORT=9200
TEMPORAL_ELASTICSEARCH_SCHEME=http
TEMPORAL_ELASTICSEARCH_VERSION=v8
TEMPORAL_ELASTICSEARCH_INDEX=temporal_visibility_v1_dev

# AWS Configuration
AWS_REGION=eu-west-1
```

### Terraform Variables
```bash
# Required
project_name = "temporal-test"

# Optional
region = "eu-west-1"  # Default
```

## Observability

### Grafana Dashboards

Two pre-configured dashboards are included:

1. **Temporal Server Dashboard** (`grafana/server/server.json`)
   - Service request rates and latencies
   - Workflow execution outcomes
   - History task processing
   - Persistence latency by operation
   - Shard health monitoring

2. **DSQL Persistence Dashboard** (`grafana/dsql/persistence.json`)
   - Connection pool utilization (max_open, open, in_use, idle)
   - Transaction conflicts and retries (OCC metrics)
   - CloudWatch metrics for DSQL cluster health
   - DPU usage and commit latency

### Metrics Architecture

```
┌─────────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│ Temporal        │────▶│ Alloy       │────▶│ Mimir       │────▶│ Grafana     │
│ Services :9090  │     │ (scraper)   │     │ (storage)   │     │ (dashboards)│
└─────────────────┘     └─────────────┘     └─────────────┘     └─────────────┘
                                                                       ▲
                                                                       │
                                                              ┌─────────────┐
                                                              │ CloudWatch  │
                                                              │ (AWS DSQL)  │
                                                              └─────────────┘
```

- **Prometheus metrics**: Exposed by Temporal services on port 9090
- **Alloy**: Scrapes metrics from all Temporal services
- **Mimir**: Prometheus-compatible long-term storage
- **Grafana**: Visualization with Mimir and CloudWatch datasources

### CloudWatch Integration

The DSQL dashboard includes AWS CloudWatch metrics for the Aurora DSQL cluster:
- BytesRead/BytesWritten throughput
- CommitLatency and TotalTransactions
- DPU (Database Processing Units) usage
- OCC (Optimistic Concurrency Control) conflicts

**Setup**: CloudWatch queries require AWS credentials. The Grafana container mounts `~/.aws` for credential access. Set the DSQL cluster identifier in the dashboard variable.

### DSQL Plugin Metrics

The custom DSQL plugin emits these metrics (requires `framework: opentelemetry` in config):

| Metric | Type | Description |
|--------|------|-------------|
| `dsql_pool_max_open` | Gauge | Maximum configured connections |
| `dsql_pool_open` | Gauge | Currently open connections |
| `dsql_pool_in_use` | Gauge | Connections actively in use |
| `dsql_pool_idle` | Gauge | Idle connections in pool |
| `dsql_pool_wait_total` | Counter | Requests that waited for a connection |
| `dsql_pool_wait_duration` | Histogram | Time spent waiting for connections |
| `dsql_tx_conflict_total` | Counter | Transaction serialization conflicts |
| `dsql_tx_retry_total` | Counter | Transaction retry attempts |
| `dsql_tx_exhausted_total` | Counter | Retries exhausted (failures) |
| `dsql_tx_latency` | Histogram | Transaction latency including retries |

## Troubleshooting

### Common Issues

1. **DSQL Connection Issues**
   - Ensure AWS credentials are configured
   - Check DSQL cluster status in AWS Console
   - Verify IAM permissions for DSQL access

2. **Elasticsearch Issues**
   - Check container logs: `docker compose logs elasticsearch`
   - Verify index exists: `curl http://localhost:9200/temporal_visibility_v1_dev`
   - Restart Elasticsearch: `docker compose restart elasticsearch`

3. **Temporal Service Issues**
   - Check service logs: `docker compose logs [service-name]`
   - Verify schema setup: `./scripts/setup-schema.sh`
   - Restart services: `docker compose restart`

### Useful Commands

```bash
# Check all service status
docker compose ps

# View logs for specific service
docker compose logs temporal-frontend

# Test Elasticsearch health
curl http://localhost:9200/_cluster/health

# Test Temporal connectivity
nc -z localhost 7233
```

## Development Notes

- **ID Generation**: Application-level ID generation for DSQL compatibility
- **Locking**: Optimistic concurrency control for DSQL limitations
- **Monitoring**: Elasticsearch provides full-text search for workflow visibility

## Security Considerations

- **Development Only**: This setup is for development and testing
- **IAM Authentication**: Uses AWS IAM for DSQL access (no static passwords)
- **Local Elasticsearch**: No authentication configured (development only)
- **Network**: Services communicate over Docker network

For production deployment, consider:
- VPC-based networking
- Elasticsearch authentication and encryption
- AWS Secrets Manager for credential management
- Multi-AZ deployment for high availability

## Related Projects

- [temporal-dsql](https://github.com/iw/temporal) - Custom Temporal fork with Aurora DSQL persistence support
- [temporal-dsql-deploy-ecs](https://github.com/iw/temporal-dsql-deploy-ecs) - Production ECS deployment with Terraform

## Acknowledgments

This project was developed with significant assistance from [Kiro](https://kiro.dev), an AI-powered IDE.

## License

Apache 2.0