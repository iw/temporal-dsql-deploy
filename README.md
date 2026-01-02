# temporal-dsql-deploy

Reference assets for provisioning an Aurora DSQL persistence backend for Temporal, and for producing a Temporal runtime image that is pre-configured to talk to Aurora DSQL and external OpenSearch services.

> **🔐 Security Note**: This project is configured for **development and testing**.
## What's here
- **Terraform module (`terraform/`):** Builds a private VPC, subnets, security groups, Aurora DSQL cluster, an interface VPC endpoint to reach the cluster, OpenSearch Provisioned domain for visibility, and a Client VPN endpoint so workstations can reach DSQL.
- **Certificate helper (`src/temporal_dsql_deploy/cli.py`):** Typer commands to mint Client VPN certificates, import them into ACM, and print the ARNs Terraform needs.
- **Docker runtime layer:** A thin renderer (`docker/render-and-start.sh` + `docker/config/persistence-dsql.template.yaml`) that templatises Temporal persistence/visibility configuration based on environment variables. The root `docker-compose.yml` wires the image with a UI and optional admin tools.

## Generate VPN certificates (feed Terraform)
Use the helper to create root/server/client certs, verify them, and import into ACM. The final ARNs feed Terraform variables:

```bash
uv run dsql-deploy init
uv run dsql-deploy create-root-ca
uv run dsql-deploy create-server
uv run dsql-deploy create-client client1
uv run dsql-deploy verify
uv run dsql-deploy acm-import-server
uv run dsql-deploy acm-import-root
uv run dsql-deploy print-acm-arns
```

## Provision with Terraform (only provisioning path)
Terraform now handles the infrastructure end-to-end. Supply the ACM ARNs from the helper above:

```bash
cd terraform
terraform init
terraform apply \
  -var 'project_name=temporal-dsql' \
  -var 'client_vpn_server_certificate_arn=arn:aws:acm:REGION:ACCOUNT:certificate/...' \
  -var 'client_vpn_authentication_options=[{type="certificate-authentication",root_certificate_chain_arn="arn:aws:acm:REGION:ACCOUNT:certificate/..."}]'
```

Tune `private_subnet_cidrs`, `allowed_client_cidrs`, and `client_vpn_cidr` if your network ranges differ. Key outputs:
- `dsql_vpc_endpoint_dns_entries[0].dns_name` → SQL host for Temporal.
- `opensearch_domain_endpoint` → OpenSearch Provisioned domain endpoint for visibility.
- `client_vpn_endpoint_id` → export profile and connect before running Temporal.
- `vpc_id` and security group IDs → feed into your secrets/credentials wiring and Docker runtime env vars.

## OpenSearch Visibility (Provisioned by Terraform)

This project now provisions an **OpenSearch Provisioned domain** as part of the Terraform deployment. The domain is configured with:

- **Domain name**: `{project_name}-visibility`
- **Instance type**: `t3.small.search` (configurable)
- **Multi-AZ**: Enabled for high availability
- **Security**: VPC-based with security groups and IAM authentication
- **Encryption**: At-rest and in-transit encryption enabled
- **Logging**: CloudWatch integration for monitoring
- **Network**: Public HTTPS access with IAM authentication
- **Encryption**: AWS-managed keys

### Authentication Options:

1. **Direct Connection with IAM** (Recommended for production):
   ```bash
   # Use the OpenSearch endpoint directly from Terraform outputs
   TEMPORAL_OPENSEARCH_ENDPOINT=$(terraform output -raw opensearch_domain_endpoint)
   # Ensure your AWS credentials have the required permissions
   ```

2. **Local aws-sigv4-proxy** (Development):
   ```bash
   # Run proxy locally to handle SigV4 signing
   OPENSEARCH_ENDPOINT=$(terraform output -raw opensearch_domain_endpoint)
   docker run -p 9200:9200 \
     -e AWS_REGION=eu-west-1 \
     awslabs/aws-sigv4-proxy:latest \
     -v -s opensearch \
     --name opensearch \
     --region eu-west-1 \
     --host ${OPENSEARCH_ENDPOINT#https://}
   
   # Set in .env:
   TEMPORAL_OPENSEARCH_ENDPOINT=http://host.docker.internal:9200
   ```

### IAM Permissions

The Terraform configuration automatically creates data access policies for the AWS account that runs `terraform apply`. For additional users or roles, you may need to update the access policy:

```bash
# View current access policy
aws opensearchserverless get-access-policy \
  --name $(terraform output -raw project_name)-data-access-policy \
  --type data

# Update policy to include additional principals if needed
```

## Build the Temporal runtime image
Render the base Temporal image with your SQL + OpenSearch defaults. Example using Terraform outputs:

```bash
SQL_HOST=$(terraform -chdir=terraform output -json dsql_vpc_endpoint_dns_entries | jq -r '.[0].dns_name')
OPENSEARCH_ENDPOINT=$(terraform -chdir=terraform output -raw opensearch_collection_endpoint)

DOCKER_BUILDKIT=1 docker build \
  --build-arg TEMPORAL_BASE_IMAGE=temporal-dsql:latest \
  --build-arg DSQL_ENDPOINT=${SQL_HOST} \
  --build-arg DSQL_PORT=5432 \
  --build-arg DSQL_USERNAME=temporal_admin \
  --build-arg DSQL_DATABASE=temporal \
  --build-arg SQL_PLUGIN_NAME=dsql \
  --build-arg OPENSEARCH_ENDPOINT=${OPENSEARCH_ENDPOINT} \
  -t temporal-dsql-runtime .
```

### Architecture Support

The build process supports multiple architectures following Temporal's official Docker build patterns:

```bash
# Build for current architecture (default)
./scripts/build-temporal-dsql.sh ../temporal-dsql

# Build for specific architecture
./scripts/build-temporal-dsql.sh ../temporal-dsql amd64
./scripts/build-temporal-dsql.sh ../temporal-dsql arm64

# Set architecture via environment variable
TARGET_ARCH=arm64 ./scripts/deploy-test-env.sh
```

Supported architectures:
- `amd64` (x86_64) - Intel/AMD 64-bit
- `arm64` (aarch64) - ARM 64-bit (Apple Silicon, AWS Graviton)

### Development vs Production

The current Docker build is optimized for **development and testing** with DSQL. It includes debugging tools, dynamic configuration rendering, and simplified deployment patterns.

For **production deployments**, consider implementing production-ready Docker builds following Temporal's official patterns with multi-stage builds, smaller image sizes, and enhanced security.

At runtime override any environment variables needed by the template (for example the SQL password file, TLS flags, or OpenSearch credentials) and mount the relevant secrets:

```bash
docker run \
  -e TEMPORAL_SQL_PASSWORD_FILE=/run/secrets/dsql-password \
  -e TEMPORAL_OPENSEARCH_PASSWORD_FILE=/run/secrets/opensearch-password \
  -v /secure/path/dsql-password:/run/secrets/dsql-password:ro \
  -v /secure/path/opensearch-password:/run/secrets/opensearch-password:ro \
  temporal-dsql-runtime
```

## Docker Compose

The project provides two main Docker Compose configurations:

1. **`docker-compose.services.yml`** - **AUTHORITATIVE** - Multi-service DSQL integration
   - Runs Temporal as separate services (history, matching, frontend, worker)
   - Uses Aurora DSQL for persistence and OpenSearch for visibility
   - Proper service dependencies and health checks
   - Production-like architecture for development and testing

2. **`docker-compose.local-test.yml`** - Local development without AWS dependencies
   - Uses SQLite for persistence and disables visibility
   - Minimal setup for local testing and development
   - No external AWS services required

The multi-service configuration expects Aurora DSQL and OpenSearch services to be available in AWS. It uses IAM authentication and requires proper AWS credentials to be configured.

For detailed automation workflows, see [scripts/WORKFLOW.md](scripts/WORKFLOW.md).

### DSQL Integration (Authoritative)
Steps:
1. `cp .env.example .env.integration` and fill in the values with Terraform outputs (SQL host from DSQL endpoint, OpenSearch endpoint, database name, Temporal user, etc.).
2. Create the secret files referenced in `.env.integration` (for example `./secrets/opensearch-password`) and populate them with the credentials pulled from your secrets store.
3. Build the runtime image and launch the multi-service stack:
   ```bash
   ./scripts/build-temporal-dsql.sh ../temporal-dsql arm64
   docker compose -f docker-compose.services.yml up -d
   ```
4. Access the Temporal UI at http://localhost:8080

### Local Development (No AWS Dependencies)
For local testing without AWS services:
```bash
docker compose -f docker-compose.local-test.yml up -d
```
   ```bash
   docker compose run --rm --profile admin temporal-admin-tools tctl namespace list
   ```

### Local Testing (without AWS services)
For testing the temporal-dsql image without provisioning DSQL and OpenSearch:

```bash
# Run minimal validation tests
./scripts/test-temporal-dsql-minimal.sh

# Start local stack with SQLite (no external dependencies)
docker compose -f docker-compose.local-test.yml up -d

# Access Temporal UI at http://localhost:8080
# Temporal gRPC endpoint: localhost:7233
```

The local testing setup uses SQLite for persistence and disables visibility features to avoid external dependencies.

Because Temporal talks to AWS-managed services, make sure you are connected to the Client VPN (for Aurora DSQL through the interface endpoint) and that your AWS credentials have the necessary IAM permissions for OpenSearch Serverless. The easiest visibility setup is to run [`aws-sigv4-proxy`](https://github.com/awslabs/aws-sigv4-proxy) on your workstation (or another Compose stack) and set `TEMPORAL_OPENSEARCH_ENDPOINT` to that listener (for example `http://host.docker.internal:9200`). Alternatively, you can point Temporal directly at the OpenSearch Serverless endpoint if your environment has proper IAM credentials configured.

## Automation Scripts

The `scripts/` directory contains automation tools for streamlined deployment:

- **`deploy-test-env.sh`** - Complete automated deployment (builds images + deploys infrastructure)
- **`build-temporal-dsql.sh`** - Build and validate Docker images from your temporal-dsql fork
- **`terraform-to-env.sh`** - Generate `.env` file from existing Terraform outputs

For detailed workflows and usage examples, see [scripts/WORKFLOW.md](scripts/WORKFLOW.md).

## Connectivity expectations
- Connect to the AWS Client VPN exported by Terraform before starting Temporal so the container can reach the interface VPC endpoint for DSQL.
- Use the DNS entry from `dsql_vpc_endpoint_dns_entries` (or any RDS proxy you front it with) as `TEMPORAL_SQL_HOST`, with TLS enabled unless you have an explicit reason to disable it.
- OpenSearch Serverless is provisioned by Terraform and accessible via the `opensearch_collection_endpoint` output. Use IAM authentication or run `aws-sigv4-proxy` locally for easier development.
- Ensure your AWS credentials have the necessary IAM permissions for the OpenSearch Serverless collection created by Terraform.

## 🔍 DSQL Connectivity Discovery & Current Development Approach

During development and testing, we discovered important connectivity behavior with Aurora DSQL that affects the deployment approach:

### VPC Endpoint Connectivity Issue ⚠️

**Issue**: DSQL VPC endpoints created by Terraform are not accepting connections on port 5432, resulting in "connection refused" errors even with proper VPN connectivity and security group configuration.

**Symptoms**:
- VPN connects successfully (gets IP in 10.254.0.0/22 range)
- DNS resolution works for VPC endpoint (resolves to private IPs)
- Port 5432 connections to VPC endpoint IPs are refused
- All security groups and network ACLs are properly configured

**Root Cause**: This appears to be a service-level issue with DSQL VPC endpoint connectivity, not a configuration problem.

### Current Working Solution: Public Endpoint ✅

**Solution**: Use the DSQL cluster's **public endpoint** with IAM authentication instead of the VPC endpoint.

**Current Working Configuration**:
```bash
# Public Endpoint (Working)
TEMPORAL_SQL_HOST=your-cluster-id.dsql.region.on.aws  # ✅ Works perfectly
TEMPORAL_SQL_USER=admin
TEMPORAL_SQL_DATABASE=postgres
# Uses IAM authentication - no password files needed
```

**Legacy VPC Endpoint Configuration** (for reference):
```bash
# VPC Endpoint (Not Working)
TEMPORAL_SQL_HOST=dsql-xxx.eu-west-1.on.aws  # ❌ Connection refused on port 5432
# Requires VPN connection but endpoint doesn't accept connections
```

### Development Configuration

For current development and testing, use this configuration approach:

1. **Deploy Infrastructure**: Still deploy VPC + VPN infrastructure for future use when VPC endpoint connectivity is resolved
2. **Use Public Endpoint**: Configure Temporal to use the public DSQL endpoint with IAM authentication
3. **Schema Setup**: Use `scripts/setup-dsql-schema-simple.sh` which handles public endpoint + IAM auth
4. **Integration Testing**: Use `scripts/test-temporal-dsql-integration.sh` for full integration validation

### Security Considerations

**Public Endpoint Security**:
- ✅ **IAM Authentication**: All connections use AWS IAM tokens (no static passwords)
- ✅ **TLS Encryption**: All traffic encrypted in transit
- ✅ **Network Security**: DSQL public endpoints only accept authenticated requests
- ✅ **Audit Trail**: All database operations logged via CloudTrail

**VPN Infrastructure Value**:
- Infrastructure remains deployed for when VPC endpoint connectivity is fixed
- Provides secure access to other AWS services in the VPC
- Demonstrates complete private networking setup for production reference

### Recommended Scripts

Use these scripts for the current public endpoint approach:

- ✅ **Schema Setup**: `./scripts/setup-dsql-schema-simple.sh`
- ✅ **Integration Testing**: `./scripts/test-temporal-dsql-integration.sh`
- ✅ **Connectivity Testing**: `./scripts/test-dsql-connectivity.sh`

### Future Considerations

When DSQL VPC endpoint connectivity is resolved:
1. Update configuration to use VPC endpoint DNS from Terraform outputs
2. Ensure VPN connectivity for private endpoint access
3. Switch back to private networking for enhanced security
4. Update scripts to use VPC endpoint instead of public endpoint

This discovery ensures immediate development progress while maintaining the infrastructure foundation for future private connectivity.

## Costs

This section provides cost estimates for running a minimal Aurora DSQL deployment with the required AWS infrastructure. Prices are based on EU West (Ireland) region as of December 2024.

### Aurora DSQL Pricing
Aurora DSQL uses a serverless, pay-per-use model with two main cost components:

| Component | Price (EU West Ireland) | Description |
|-----------|---------------------|-------------|
| **DPU (Distributed Processing Units)** | $8.00 per 1M DPUs | Covers compute, reads, writes, and background tasks |
| **Storage** | $0.33 per GB-month | Actual data stored in the cluster |

**Free Tier:** 100,000 DPUs and 1 GB storage per month (resets monthly)

**Minimal workload estimate:** A small Temporal deployment with basic workflow activity might consume 50,000-200,000 DPUs per month, costing $0.40-$1.60/month plus storage.

### OpenSearch Serverless Pricing
OpenSearch Serverless uses a capacity-based pricing model:

| Component | Price (EU West Ireland) | Description |
|-----------|---------------------|-------------|
| **Search OCU (OpenSearch Compute Units)** | $0.24 per OCU-hour | Indexing and search compute capacity |
| **Storage** | $0.024 per GB-month | Data storage in the collection |

**Minimal workload estimate:** A basic Temporal visibility setup typically requires 1-2 OCUs, costing $175-$350/month plus storage.

### Required AWS Infrastructure Costs

| Service | Component | Price | Monthly Cost (24/7) |
|---------|-----------|-------|-------------------|
| **VPC** | VPC, Subnets, Route Tables | Free | $0.00 |
| **Internet Gateway** | Attached to VPC | Free | $0.00 |
| **Security Groups** | Network access control | Free | $0.00 |
| **VPC Interface Endpoint** | DSQL service endpoint | $0.01/hour | $7.20 |
| **AWS Client VPN** | Endpoint association | $0.15/hour | $108.00 |
| **AWS Client VPN** | Per active connection | $0.10/hour | $72.00 (1 user) |
| **ACM Certificates** | SSL/TLS certificates | Free | $0.00 |

### Data Transfer Costs
| Transfer Type | Price | Notes |
|---------------|-------|-------|
| VPN data processing | $0.045/GB | Data through Client VPN |
| Inter-AZ (within VPC) | Free | VPC endpoint to DSQL |
| Internet egress | $0.09/GB (first 10TB) | OpenSearch Serverless traffic |

### Total Monthly Cost Estimates

#### Minimal Development Setup (1 user, light usage)
- Aurora DSQL: ~$1.00 (within free tier initially)
- OpenSearch Serverless: ~$175.00 (1 OCU + minimal storage)
- VPC Interface Endpoint: $7.20
- Client VPN (1 user): $180.00
- **Total: ~$363/month**

#### Small Team Setup (5 users, moderate usage)
- Aurora DSQL: ~$5.00 (200K DPUs + 2GB storage)
- OpenSearch Serverless: ~$350.00 (2 OCUs + 5GB storage)
- VPC Interface Endpoint: $7.20
- Client VPN (5 users): $540.00
- Data transfer: ~$10.00
- **Total: ~$912/month**

#### Production Setup (10 users, higher usage)
- Aurora DSQL: ~$25.00 (1M DPUs + 10GB storage)
- OpenSearch Serverless: ~$525.00 (3 OCUs + 20GB storage)
- VPC Interface Endpoint: $7.20
- Client VPN (10 users): $1,080.00
- Data transfer: ~$25.00
- **Total: ~$1,662/month**

### Ephemeral Development Usage (1-hour tests)

For short development tests, most infrastructure can be created and destroyed on-demand. Here's the cost breakdown for **1-hour usage**:

| Component | Hourly Rate | 1-Hour Cost | Can be ephemeral? |
|-----------|-------------|-------------|-------------------|
| **Aurora DSQL** | Pay-per-DPU | ~$0.01-0.05 | ✅ **Yes** - Serverless, no minimum |
| **OpenSearch Serverless** | $0.24/OCU-hour | ~$0.24-0.48 | ⚠️ **Limited** - Minimum 1 OCU, slow to scale down |
| **VPC Infrastructure** | Free | $0.00 | ✅ **Yes** - Quick to create/destroy |
| **VPC Interface Endpoint** | $0.01/hour | $0.01 | ✅ **Yes** - Can be created on-demand |
| **Client VPN Endpoint** | $0.15/hour | $0.15 | ✅ **Yes** - Can be created on-demand |
| **Client VPN Connection** | $0.10/hour | $0.10 | ✅ **Yes** - Only while connected |
| **ACM Certificates** | Free | $0.00 | ⚠️ **Reusable** - Keep between tests |

**Total cost per 1-hour test: ~$0.51-0.79** (OpenSearch is the primary cost driver for short tests)

### Ephemeral Deployment Strategy

#### What to keep persistent (reuse across tests):
- **ACM Certificates**: Free to store, time-consuming to recreate (~5 minutes)
- **Certificate files**: Store locally, reference in Terraform variables
- **OpenSearch Serverless Collection**: Consider keeping for multiple tests due to minimum OCU costs

#### What to create/destroy per test:
- **Terraform infrastructure**: VPC, subnets, DSQL cluster, VPC endpoint, Client VPN
- **Docker containers**: Temporal runtime, UI

#### Optimized workflow for 1-hour tests:

```bash
# One-time setup (reuse certificates and optionally OpenSearch)
uv run dsql-deploy init
uv run dsql-deploy create-root-ca
uv run dsql-deploy create-server  
uv run dsql-deploy create-client dev-user
uv run dsql-deploy acm-import-server
uv run dsql-deploy acm-import-root

# Per-test cycle (5-10 minutes setup)
cd terraform
terraform apply -var 'project_name=temporal-test-$(date +%s)' \
  -var 'client_vpn_server_certificate_arn=arn:aws:acm:...' \
  -var 'client_vpn_authentication_options=[{...}]' \
  -auto-approve

# Extract connection details
terraform output -json > ../outputs.json
aws ec2 export-client-vpn-client-configuration \
  --client-vpn-endpoint-id $(jq -r '.client_vpn_endpoint_id.value' ../outputs.json) \
  --output text > ../client-vpn.ovpn

# Run your tests (1 hour)
# ... connect VPN, run Temporal, execute tests ...

# Cleanup (2-3 minutes)
terraform destroy -auto-approve
```

### Cost Comparison: Ephemeral vs Persistent

| Usage Pattern | Setup | Aurora DSQL | OpenSearch | Infrastructure | Total Cost |
|---------------|-------|-------------|------------|----------------|------------|
| **1-hour test** | 5 min setup + 3 min cleanup | $0.01-0.05 | $0.24-0.48 | $0.26 | **$0.51-0.79** |
| **8-hour workday** | Once daily | $0.08-0.40 | $1.92-3.84 | $2.08 | **$4.08-6.32** |
| **Always-on (monthly)** | Once | $1-25 | $175-525 | $187 | **$363-737** |

### Automation Tips for Ephemeral Usage

1. **Terraform automation**:
   ```bash
   # Quick deploy script
   ./scripts/deploy-test-env.sh
   # Runs terraform apply with pre-configured variables
   # Outputs VPN config and connection details
   ```

2. **Auto-cleanup with timeouts**:
   ```bash
   # Auto-destroy after 2 hours
   echo "terraform destroy -auto-approve" | at now + 2 hours
   ```

3. **Docker Compose with dynamic config**:
   ```bash
   # Generate .env from Terraform outputs
   ./scripts/terraform-to-env.sh > .env
   docker compose up -d
   ```

4. **VPN connection automation**:
   ```bash
   # Import and connect to VPN profile
   sudo openvpn --config client-vpn.ovpn --daemon
   ```

### Ephemeral Limitations

- **Certificate creation**: 5-10 minutes initial setup (but reusable)
- **Terraform apply**: 3-5 minutes (VPC + DSQL cluster creation)
- **VPN connection**: 30-60 seconds to establish
- **Terraform destroy**: 2-3 minutes cleanup
- **Aurora DSQL**: No cold start delay (truly serverless)

**Bottom line**: After initial certificate setup, you can spin up a complete test environment in ~5 minutes for $0.51-0.79/hour, with OpenSearch Serverless being the primary cost driver for short development cycles.

### Cost Optimization Tips

1. **Use the free tier:** Start with Aurora DSQL's generous free tier (100K DPUs/month)
2. **Minimize VPN users:** Client VPN is a significant cost component at $72/user/month
3. **OpenSearch optimization:** Consider keeping OpenSearch collections persistent for multiple test cycles due to minimum OCU costs
4. **Consider alternatives:** For production, evaluate AWS Site-to-Site VPN or AWS Direct Connect
5. **Monitor DPU usage:** Use CloudWatch metrics to track and optimize database operations
6. **Optimize data transfer:** Use VPC endpoints for AWS services to avoid internet egress charges
7. **Regional pricing:** Consider other regions if your workload allows (prices may vary)
8. **OpenSearch scaling:** Monitor OCU usage and adjust capacity based on actual search/indexing needs

### Important Notes
- Prices are estimates and may vary by region and usage patterns
- Aurora DSQL pricing is based on actual resource consumption, making it difficult to predict exactly
- OpenSearch Serverless has minimum capacity requirements (1 OCU) which affects short-term usage costs
- Client VPN is a primary cost driver for small deployments
- Always monitor your AWS billing dashboard for actual costs
- Consider AWS Database Savings Plans for predictable workloads (1-year commitment)
