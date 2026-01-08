# Scripts Directory

This directory contains automation scripts for the streamlined DSQL + Elasticsearch setup.

## Important: PROJECT_NAME Environment Variable

**Critical for AWS resource management**: The `PROJECT_NAME` environment variable is used to:
- Name AWS resources consistently
- Enable proper resource cleanup
- Avoid naming conflicts between deployments

### Setting PROJECT_NAME

```bash
# Option 1: Export for session (recommended)
export PROJECT_NAME="my-temporal-test"
./scripts/deploy.sh

# Option 2: Inline for single command
PROJECT_NAME="my-test" ./scripts/deploy.sh

# Option 3: Let script auto-generate (includes timestamp)
./scripts/deploy.sh  # Creates: temporal-dsql-1704123456
```

### Why PROJECT_NAME Matters

1. **Resource Naming**: AWS resources are tagged with this name
2. **Cleanup**: `cleanup.sh` uses this to identify resources to destroy
3. **Isolation**: Prevents conflicts with other deployments
4. **Tracking**: Makes it easy to identify your resources in AWS Console

**⚠️ Important**: If you don't set PROJECT_NAME, the script generates a timestamp-based name. Make note of it for cleanup!

## Core Scripts

### `build-temporal-dsql.sh`
**Docker image building**
- Builds Temporal DSQL runtime image from temporal-dsql repository
- Auto-detects system architecture (amd64, arm64, arm)
- Supports custom architecture specification
- Creates both base image and deployment runtime
- Follows Temporal's official Docker build patterns

```bash
# Auto-detect architecture
./scripts/build-temporal-dsql.sh ../temporal-dsql

# Specify architecture
./scripts/build-temporal-dsql.sh ../temporal-dsql arm64
./scripts/build-temporal-dsql.sh ../temporal-dsql amd64

# Custom path and architecture
./scripts/build-temporal-dsql.sh /path/to/temporal-dsql arm64
```

Using the architecture-specific invocation is the recommended method for building for the image. On Apple Silicon this would be:

```bash
./scripts/build-temporal-dsql.sh ../temporal-dsql arm64
```

**Output Images**:
- `temporal-dsql:latest` - Base image from temporal-dsql repository
- `temporal-dsql-runtime:test` - Deployment runtime with config templates

### `deploy.sh`
**Infrastructure deployment and environment setup**
- Deploys Aurora DSQL cluster via Terraform
- Generates environment configuration (.env file)
- Prepares the environment for Temporal services
- Does NOT setup database schema (use setup-schema.sh for that)
- Requires PROJECT_NAME environment variable or generates timestamp-based name

```bash
# With auto-generated project name
./scripts/deploy.sh

# With custom project name
PROJECT_NAME="my-temporal-test" ./scripts/deploy.sh
```

### `test.sh`
**Integration testing and validation**
- Tests DSQL connectivity
- Starts all services (Elasticsearch + Temporal)
- Validates service health
- Provides troubleshooting information

```bash
./scripts/test.sh
```

### `cleanup.sh`
**Resource cleanup**
- Stops Docker containers and removes volumes
- Optionally removes Docker images
- Optionally destroys AWS infrastructure
- Cleans up generated files

```bash
./scripts/cleanup.sh
```

## Setup Scripts

### `setup-schema.sh`
**DSQL schema initialization**
- Creates database if needed
- Sets up base schema (v0)
- Updates to latest schema version
- Uses temporal-sql-tool with Helm chart approach

```bash
./scripts/setup-schema.sh
```

### `setup-elasticsearch.sh`
**Elasticsearch index setup**
- Waits for Elasticsearch to be ready
- Creates visibility index with proper mappings
- Tests search functionality
- Provides health check information

```bash
./scripts/setup-elasticsearch.sh
```

## Utility Scripts

### `test-dsql-connectivity.sh`
**DSQL connection testing**
- Tests basic DSQL connectivity
- Validates IAM authentication
- Checks cluster status

```bash
./scripts/test-dsql-connectivity.sh
```

## Usage Patterns

### Complete Setup (Recommended)
```bash
# Set project name for easier cleanup
export PROJECT_NAME="my-temporal-test"

# Build Docker images first
./scripts/build-temporal-dsql.sh ../temporal-dsql

# Deploy infrastructure and setup environment
./scripts/deploy.sh

# Setup database schema
./scripts/setup-schema.sh

# Test the setup
./scripts/test.sh

# Use Temporal...

# Cleanup when done (uses PROJECT_NAME)
./scripts/cleanup.sh
```

### Manual Step-by-Step
```bash
# 0. Set project name
export PROJECT_NAME="my-temporal-test"

# 1. Build Docker images
./scripts/build-temporal-dsql.sh ../temporal-dsql

# 2. Deploy infrastructure only
cd terraform
terraform apply -var "project_name=$PROJECT_NAME"

# 3. Setup environment manually
cp .env.example .env
# Edit .env with DSQL endpoint from terraform output

# 4. Setup schema
./scripts/setup-schema.sh

# 5. Start services
docker compose up -d

# 6. Setup Elasticsearch
./scripts/setup-elasticsearch.sh

# 7. Test
./scripts/test.sh
```

# 4. Start services
docker compose up -d

# 5. Setup Elasticsearch
./scripts/setup-elasticsearch.sh

# 6. Test
./scripts/test.sh
```

### Development Workflow
```bash
# Set consistent project name for the session
export PROJECT_NAME="dev-temporal"

# Quick restart after code changes
docker compose restart

# View logs
docker compose logs -f temporal-frontend

# Reset schema (if needed)
./scripts/setup-schema.sh

# Full reset
./scripts/cleanup.sh
./scripts/deploy.sh
./scripts/setup-schema.sh
```

## Script Dependencies

### Required Tools
- **Docker & Docker Compose**: Container orchestration
- **AWS CLI**: AWS resource management
- **Terraform**: Infrastructure provisioning
- **curl**: HTTP testing
- **nc (netcat)**: Port connectivity testing
- **jq**: JSON processing (optional but recommended)

### Required Files
- **temporal-sql-tool**: Must be available at `../temporal-dsql/temporal-sql-tool`
- **DSQL Schema**: Must be available at `../temporal-dsql/schema/dsql/v12/temporal/versioned`
- **Docker Image**: `temporal-dsql-runtime:test` must be built using `./scripts/build-temporal-dsql.sh`
- **Temporal DSQL Source**: temporal-dsql repository must be available (typically at `../temporal-dsql`)

### Environment Variables
Scripts read from `.env`:
- `TEMPORAL_SQL_HOST`: DSQL endpoint
- `TEMPORAL_SQL_DATABASE`: Database name
- `TEMPORAL_SQL_USER`: Database user
- `TEMPORAL_ELASTICSEARCH_INDEX`: Elasticsearch index name
- `AWS_REGION`: AWS region

## Error Handling

All scripts include:
- **Exit on error**: `set -euo pipefail`
- **Validation checks**: Verify required files and tools
- **Graceful degradation**: Continue with warnings when possible
- **Clear error messages**: Explain what went wrong and how to fix

## Customization

### Environment Variables
Override default values by setting environment variables:
```bash
# Custom project name (recommended)
export PROJECT_NAME="my-temporal-test"
export AWS_REGION="us-west-2"
./scripts/deploy.sh

# Or inline
PROJECT_NAME="my-test" AWS_REGION="eu-west-1" ./scripts/deploy.sh
```

**Important Environment Variables:**
- `PROJECT_NAME`: Prefix for AWS resources (required for cleanup)
- `AWS_REGION`: AWS region for DSQL cluster (default: eu-west-1)

### Script Modification
Scripts are designed to be readable and modifiable:
- Clear section headers
- Descriptive variable names
- Modular structure
- Extensive comments

## Troubleshooting

### Common Issues

1. **temporal-sql-tool not found**
   - Ensure temporal-dsql repository is built
   - Check path: `../temporal-dsql/temporal-sql-tool`

2. **AWS permissions**
   - Ensure AWS CLI is configured
   - Check IAM permissions for DSQL and Terraform

3. **PROJECT_NAME issues**
   - Set PROJECT_NAME consistently across deploy/cleanup
   - Note auto-generated names for later cleanup
   - Use descriptive names to avoid confusion

4. **Docker issues**
   - Ensure Docker daemon is running
   - Check available disk space
   - Verify network connectivity

5. **Port conflicts**
   - Check if ports 7233, 8080, 9200 are available
   - Stop conflicting services

### Debug Mode
Run scripts with debug output:
```bash
bash -x ./scripts/deploy.sh
```

### Log Analysis
Check specific service logs:
```bash
# All services
docker compose logs

# Specific service
docker compose logs temporal-frontend

# Follow logs
docker compose logs -f elasticsearch
```