# AGENTS

## Critical Schema Setup Commands (DO NOT LOSE!)

**IMPORTANT**: Always use the Helm chart approach for schema setup. These are the canonical commands:

```bash
# 1. Create database (if needed)
./temporal-sql-tool --database temporal create-database

# 2. Setup base schema with version 0
SQL_DATABASE=temporal ./temporal-sql-tool setup-schema -v 0

# 3. Update schema to v1.0 using versioned files
SQL_DATABASE=temporal ./temporal-sql-tool update-schema --schema-dir schema/dsql/v12/temporal/versioned
```

**For complete reset:**
```bash
# Drop database (temporal-sql-tool supports this)
./temporal-sql-tool --database temporal drop-database

# Then follow the 3 steps above
```

**Never recreate custom table deletion scripts** - use temporal-sql-tool's built-in commands.

## Purpose
This repository bundles three cooperating automation surfaces for deploying Temporal with Aurora DSQL:
1. A Terraform module (`terraform/`) that builds a private VPC, subnets, security groups, an Aurora DSQL cluster reachable through an interface VPC endpoint, OpenSearch Serverless collection for visibility, and a Client VPN endpoint so workstations can reach the DSQL service.
2. A Typer-based certificate helper (`src/temporal_dsql_deploy/cli.py`) that generates VPN certificates/keys, imports them into ACM, and prints the ARNs Terraform needs.
3. A Docker-side template renderer (`docker/render-and-start.sh`) that validates environment variables and renders Temporal persistence configuration from templates before handing control back to the base Temporal entrypoint.

## Agent Catalog
| Agent | Location | Trigger | Responsibilities | Outputs |
| --- | --- | --- | --- | --- |
| Terraform Infrastructure Module | `terraform/` | `terraform apply` (per environment) | Build VPC, subnets, security groups, Aurora DSQL cluster, interface VPC endpoint to the cluster, OpenSearch Serverless collection, Client VPN endpoint, and networking glue required for local access | AWS infrastructure, Terraform state, outputs (`dsql_vpc_endpoint_dns_entries`, `opensearch_collection_endpoint`, `client_vpn_endpoint_id`, `vpc_id`, `dsql_cluster_arn`, `private_subnet_ids`, `dsql_vpce_security_group_id`, etc.) |
| Certificate Helper | `src/temporal_dsql_deploy/cli.py` | `uv run dsql-deploy …` | Create root/server/client certificates, verify them, import into ACM, and surface the ARNs to feed Terraform | `certs/ca.*`, `server/server.*`, `clients/<name>.*`, `.acm/*.json` with ACM ARNs |
| Template Renderer | `docker/render-and-start.sh` + `docker/config/persistence-dsql.template.yaml` | Container start (entrypoint) | Validate required environment variables, render Temporal persistence config from env vars, then jump back to the base entrypoint | `/etc/temporal/config/persistence-dsql.yaml` |
| Human Operator / Temporal Runtime | Workstation Docker (`docker run temporal-dsql-runtime`) | After infrastructure exists | Retrieve Terraform outputs, connect VPN, inject env vars/secrets, operate Temporal | Running Temporal instance configured for Aurora DSQL + OpenSearch |

## Terraform Module Details
- **Scope:** End-to-end environment for development or PoC use, including VPC, private subnets, internet gateway, security groups, an Aurora DSQL cluster, a dedicated interface VPC endpoint to reach the cluster, OpenSearch Serverless collection for visibility, AWS Client VPN endpoint, and certificate-based authentication.
- **Opinionated choices:**
  - Aurora DSQL connectivity goes through the interface VPC endpoint created inside the VPC. The module disables Private DNS on the endpoint; operators should use the DNS entries surfaced via Terraform outputs as the SQL host.
  - OpenSearch Serverless collection is provisioned with IAM-based data access policies and public HTTPS access for simplicity.
  - Client traffic arrives through AWS Client VPN (`aws_ec2_client_vpn_endpoint.this`), which drops clients into the VPC CIDR referenced by the endpoint security group.
  - Security groups restrict PostgreSQL traffic on port 5432 to the VPN client CIDR you specify; the endpoint SG denies lateral access from other sources by default.
  - Input validation ensures at least one authentication method is configured and authentication types are valid.
- **Enhanced outputs:** The module now provides comprehensive metadata including VPC ID, subnet IDs, security group IDs, DSQL endpoint details, and OpenSearch collection information for better observability and troubleshooting.
- **When to choose Terraform:** Use it when you want reproducible infrastructure, drift detection, and to manage the networking prerequisites (VPC, VPN, endpoint). Terraform is now the only provisioning path for DSQL, OpenSearch, and networking in this repository.

## Certificate Helper Details
- **Coupling with Terraform:** Run the helper before Terraform to mint VPN certificates, import them into ACM, and capture the resulting ARNs. Those ARNs feed `client_vpn_server_certificate_arn` and `client_vpn_authentication_options` in Terraform.
- **Implementation:** See `src/temporal_dsql_deploy/cli.py`; wraps `openssl` and `aws acm import-certificate` via Typer commands with enhanced error handling and file validation.
- **Certificate storage:** Certificates are organized in `certs/` (CA files), `server/` (server certificates), and `clients/` (client certificates). All generated files are properly excluded from version control.
- **Suggested flow:** `uv run dsql-deploy init` → `create-root-ca` → `create-server` → `create-client <name>` → `verify` → `acm-import-server` → `acm-import-root` → `print-acm-arns`, then plug ARNs into Terraform variables.
- **Security:** The helper includes validation for certificate file operations and proper cleanup commands to prevent accidental key exposure.

## Template Renderer Details
The renderer validates all required environment variables and performs strict template substitution to prevent silent configuration errors. Key improvements include:
- **Validation:** Checks for all required `TEMPORAL_SQL_*` and `TEMPORAL_OPENSEARCH_*` environment variables before rendering
- **Secret file validation:** Verifies that password files exist and are accessible
- **Strict substitution:** Uses `Template.substitute()` instead of `safe_substitute()` to fail fast on missing variables
- **Error reporting:** Provides clear error messages for missing variables or files

When using Terraform, derive the required values from:
- `terraform output -json dsql_vpc_endpoint_dns_entries | jq -r '.[0].dns_name'` → `TEMPORAL_SQL_HOST` (port 5432 by default)
- `terraform output -raw opensearch_collection_endpoint` → `TEMPORAL_OPENSEARCH_ENDPOINT`
- Database credentials sourced from your chosen secrets store → files mounted into the container referenced by `TEMPORAL_SQL_PASSWORD_FILE`
- OpenSearch credentials (if needed) → `TEMPORAL_OPENSEARCH_PASSWORD_FILE`

## Operator Responsibilities & Handoffs
1. **Generate VPN certificates** via the Typer helper, import into ACM, and capture ARNs.
2. **Provision infrastructure** via Terraform using the ACM ARNs for the Client VPN certificates. Capture outputs/metadata (`terraform output -json`), including the OpenSearch Serverless collection endpoint.
3. **Enroll in connectivity:** Download the AWS Client VPN profile exported by Terraform and connect before starting Temporal (or integrate with a private-link path that can reach the DSQL endpoint ENIs).
4. **Manage secrets:** Mirror database/OpenSearch credentials into local secret files and set `TEMPORAL_SQL_PASSWORD_FILE_HOST` / `TEMPORAL_OPENSEARCH_PASSWORD_FILE_HOST` in your environment for Docker Compose secret mounting.
5. **Configure runtime environment:** Use Docker env overrides (or Compose) to set the SQL host (Terraform endpoint DNS), port (`5432`), DB/user names, TLS assets, plus OpenSearch endpoint from Terraform outputs with appropriate IAM credentials or SigV4 proxy configuration.
6. **Run Temporal container** once VPN + env vars are ready; monitor via Docker health checks and the base image health endpoints.
7. **Monitor and troubleshoot:** Use the expanded Terraform outputs (VPC ID, subnet IDs, security group IDs) for debugging connectivity issues.

## Data & Secret Flow
1. Certificate helper generates VPN server/client assets in organized directories (`certs/`, `server/`, `clients/`, `.acm/`) and imports them into ACM. Terraform consumes the ARNs.
2. Terraform shapes the network + DSQL reachability with comprehensive validation and enhanced outputs, and provisions OpenSearch Serverless collection. Database credentials should be managed in your chosen secrets store.
3. Infrastructure metadata surfaces through expanded Terraform outputs including VPC details, security group IDs, DSQL endpoint information, and OpenSearch collection details.
4. Operators consume those outputs, create secret files locally, and configure Docker Compose secret mounting via `*_FILE_HOST` environment variables.
5. The runtime template renderer validates all required variables, verifies secret file accessibility, and substitutes values into `persistence-dsql.yaml`, which Temporal reads at startup.

## Connectivity From Local Docker Temporal to AWS Services

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                                LOCAL WORKSTATION                                │
├─────────────────────────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐    ┌──────────────────┐    ┌─────────────────────────────┐ │
│  │ Docker Temporal │    │ AWS Client VPN   │    │ aws-sigv4-proxy (optional)  │ │
│  │ Container       │    │ (OpenVPN client) │    │ :9200                       │ │
│  │                 │    │                  │    │                             │ │
│  └─────────────────┘    └──────────────────┘    └─────────────────────────────┘ │
│           │                       │                           │                 │
└───────────┼───────────────────────┼───────────────────────────┼─────────────────┘
            │                       │                           │
            │                       │                           │ (public HTTPS)
            │                       │                           │
            │              ┌────────▼────────┐                  │
            │              │ AWS Client VPN  │                  │
            │              │ Endpoint        │                  │
            │              │ TCP/443 (TLS)   │                  │
            │              └────────┬────────┘                  │
            │                       │                           │
            │              ┌────────▼────────┐                  │
            │              │ VPC Private     │                  │
            │              │ Subnet          │                  │
            │              │ 10.50.10.0/24   │                  │
            │              └────────┬────────┘                  │
            │                       │                           │
            │              ┌────────▼────────┐                  │
            │              │ Interface VPC   │                  │
            │              │ Endpoint        │                  │
            │              │ (DSQL Service)  │                  │
            │              │ Port 5432       │                  │
            │              └────────┬────────┘                  │
            │                       │                           │
            │              ┌────────▼────────┐                  │
            │              │ Aurora DSQL     │                  │
            │              │ Cluster         │                  │
            │              │ (PostgreSQL)    │                  │
            │              └─────────────────┘                  │
            │                                                   │
            └───────────────────────────────────────────────────┼─────────────────┐
                                                                │                 │
                                                       ┌────────▼────────┐        │
                                                       │ OpenSearch      │        │
                                                       │ Serverless      │        │
                                                       │ *.aoss.aws...   │        │
                                                       │ (IAM Auth)      │        │
                                                       └─────────────────┘        │
                                                                                  │
┌─────────────────────────────────────────────────────────────────────────────────┘
│                                AWS CLOUD
└─────────────────────────────────────────────────────────────────────────────────┘

Security Groups:
├─ Client VPN SG: Allows TCP/443 from allowed_client_cidrs
├─ DSQL VPC Endpoint SG: Allows TCP/5432 from VPN client CIDR (10.254.0.0/22)
└─ OpenSearch: Public HTTPS with IAM-based data access policies

Network Flow:
1. DSQL: Docker → VPN (TCP/443) → Private Subnet → VPC Endpoint → Aurora DSQL (TCP/5432)
2. OpenSearch: Docker → Internet → OpenSearch Serverless (HTTPS/443) [via sigv4-proxy or direct]
```

### Aurora DSQL via Interface VPC Endpoint
- Aurora DSQL traffic routes through the interface VPC endpoint created by Terraform. Use the DNS entries in `dsql_vpc_endpoint_dns_entries` as `TEMPORAL_SQL_HOST`.
- **Client path (reference architecture):** Local desktop → AWS Client VPN (OpenVPN TLS over TCP/443) → VPC private subnet → Interface VPC Endpoint (`dsql_vpc_endpoint_dns_entries`) → Aurora DSQL nodes. No public ingress exists along this path.
- **Security groups:** Ensure the endpoint SG only allows PostgreSQL traffic from the Client VPN CIDR (already encoded in Terraform) or your chosen private-link endpoints.

### OpenSearch Serverless
- OpenSearch Serverless collection is provisioned by Terraform with IAM-based data access policies. The collection endpoint is available via `opensearch_collection_endpoint` output.
- When running locally:
  - Use the provisioned collection endpoint directly with proper IAM credentials **or** run an `aws-sigv4-proxy` on the workstation for easier development.
  - Export `TEMPORAL_OPENSEARCH_ENDPOINT` from Terraform outputs and configure IAM credentials or signing proxy details via env vars.
- The Terraform configuration creates data access policies for the AWS account that runs `terraform apply`. Additional users may need to be added to the access policy.
- Because connectivity happens over the public internet, ensure your corporate egress policy permits `*.aoss.amazonaws.com` and that your AWS credentials match the account whose principal appears in the data policy.

## Connectivity From Local Docker Temporal to AWS Services
### Aurora DSQL via Interface VPC Endpoint
- Aurora DSQL traffic routes through the interface VPC endpoint created by Terraform. Use the DNS entries in `dsql_vpc_endpoint_dns_entries` as `TEMPORAL_SQL_HOST`.
- **Client path (reference architecture from README):** Local desktop → AWS Client VPN (OpenVPN TLS over TCP/443) → VPC private subnet → Interface VPC Endpoint (`dsql_vpc_endpoint_dns_entries`) → Aurora DSQL nodes. No public ingress exists along this path.
- **Security groups:** Ensure the endpoint SG only allows PostgreSQL traffic from the Client VPN CIDR (already encoded in Terraform) or your chosen private-link endpoints.

### OpenSearch Serverless
- OpenSearch Serverless collection is provisioned by Terraform with IAM-based data access policies. The collection endpoint is available via `opensearch_collection_endpoint` output.
- When running locally:
  - Use the provisioned collection endpoint directly with proper IAM credentials **or** run an `aws-sigv4-proxy` on the workstation for easier development.
  - Export `TEMPORAL_OPENSEARCH_ENDPOINT` from Terraform outputs and configure IAM credentials or signing proxy details via env vars.
- The Terraform configuration creates data access policies for the AWS account that runs `terraform apply`. Additional users may need to be added to the access policy.
- Because connectivity happens over the public internet, ensure your corporate egress policy permits `*.aoss.amazonaws.com` and that your AWS credentials match the account whose principal appears in the data policy.

## Future Enhancements
- ~~Add optional Terraform module for OpenSearch Serverless provisioning so a single `terraform apply` can yield both persistence + visibility.~~ ✅ **Completed:** OpenSearch Serverless is now provisioned by Terraform.
- Add optional Terraform toggles for RDS Proxy provisioning.
- Surface Terraform outputs directly as `.env` snippets or Docker Compose overrides to reduce manual wiring.
- ~~Extend the template renderer to validate that the expected endpoint/VPN env vars are set before launching Temporal.~~ ✅ **Completed:** Template renderer now includes comprehensive validation.
- Add automated testing for the certificate generation workflow and Terraform module validation.
- Consider adding support for alternative authentication methods (SAML, directory service) in addition to mutual TLS.
- **Production Migration**: Implement production-ready Docker builds following Temporal's official patterns with multi-stage builds, smaller image sizes, and enhanced security.

## 🔍 Critical Discovery: DSQL VPC Endpoint Connectivity Issue

### Issue Summary
During development and testing (December 2024), we discovered that **DSQL VPC endpoints are not accepting connections on port 5432**, despite proper infrastructure configuration. This affects the primary connectivity approach documented above.

### Technical Details
- **Symptom**: Connection refused errors when attempting to connect to VPC endpoint IPs on port 5432
- **Scope**: Affects all VPC endpoint connectivity, not configuration-specific
- **VPN Status**: VPN connectivity works correctly (proper IP assignment, DNS resolution)
- **Security Groups**: All security groups and network ACLs are properly configured
- **Root Cause**: Appears to be a service-level issue with DSQL VPC endpoint connectivity

### Current Workaround: Public Endpoint
**Solution**: Use DSQL cluster's public endpoint with IAM authentication instead of VPC endpoint.

**Working Configuration**:
```bash
# Public Endpoint (working)
TEMPORAL_SQL_HOST=your-cluster-id.dsql.region.on.aws
TEMPORAL_SQL_USER=admin
TEMPORAL_SQL_DATABASE=postgres
# IAM authentication - no password files needed
```

### Impact on Architecture
1. **Infrastructure**: VPC + VPN infrastructure remains valuable for future use and other AWS services
2. **Development**: Immediate development progress using public endpoint with IAM auth
3. **Security**: Public endpoint maintains security through IAM authentication and TLS encryption
4. **Scripts**: Updated scripts to use public endpoint approach (`setup-dsql-schema-simple.sh`, `test-temporal-dsql-integration.sh`)

### Updated Recommendations
- **Current Development**: Use public endpoint with scripts in `scripts/README.md`
- **Infrastructure**: Keep VPC/VPN infrastructure for when VPC endpoint connectivity is resolved
- **Security**: IAM authentication provides strong security even with public endpoint
- **Future**: Monitor AWS service updates for VPC endpoint connectivity resolution

## 📋 Project Status & Cleanup Summary

### Infrastructure Cleanup ✅ COMPLETED
- **Terraform Destroy**: Successfully completed on December 30, 2024
- **DSQL Cluster**: Deletion protection disabled and cluster destroyed (`pvtnxl7gj4cexuathdwbqkc3ke`)
- **AWS Resources**: All Terraform-managed resources removed (15 resources destroyed)
- **Docker Containers**: All temporal-dsql containers stopped and removed
- **Docker Images**: All temporal-dsql images cleaned up (freed ~1.1GB)
- **Cost Impact**: $0/month - no ongoing charges
- **State Files**: Terraform state is empty, all resources cleaned up

### Development Achievements ✅ COMPLETED
1. **Schema Compatibility**: DSQL-compatible schema created and validated
2. **Persistence Layer**: ID generation service and DSQL plugin implemented
3. **Configuration**: Development configuration files created
4. **Code Quality**: All DSQL code passes linting and unit tests
5. **Documentation**: Comprehensive migration notes and implementation tracking
6. **Infrastructure**: AWS infrastructure successfully deployed and tested
7. **Connectivity Discovery**: Identified VPC endpoint issue and public endpoint workaround
8. **Script Organization**: Comprehensive script documentation and cleanup

### Key Deliverables
- ✅ **Working DSQL Integration**: Temporal successfully connects to Aurora DSQL using public endpoint
- ✅ **Schema Setup**: Database schema created and validated with IAM authentication
- ✅ **Docker Images**: Custom Temporal images built with DSQL support (multi-architecture)
- ✅ **Infrastructure Code**: Complete Terraform module for VPC, DSQL, OpenSearch, and VPN
- ✅ **Documentation**: Comprehensive guides, scripts documentation, and production migration roadmap
- ✅ **Security**: IAM-based authentication implemented (no static passwords)

### Next Steps for Future Development
1. **Monitor VPC Endpoint**: Watch for AWS service updates resolving VPC endpoint connectivity
2. **Production Migration**: Follow [Production Migration Guide](docs/PRODUCTION-MIGRATION.md) for production deployment
3. **Integration Testing**: Continue development using public endpoint approach
4. **Performance Testing**: Benchmark DSQL performance under production-like loads
5. **Observability**: Implement DSQL-specific metrics and monitoring

### Script Usage for Continued Development
```bash
# Schema setup (public endpoint)
./scripts/setup-dsql-schema-simple.sh

# Integration testing
./scripts/test-temporal-dsql-integration.sh

# Build custom images
./scripts/build-temporal-dsql.sh ../temporal-dsql

# Infrastructure deployment (when needed)
./scripts/deploy-test-env.sh

# Cleanup resources
./scripts/cleanup-aws-resources.sh
```

**Project Status**: ⚠️ **PARTIAL FUNCTIONALITY** - Core components implemented but DSQL locking limitation discovered. See [ISSUE-DSQL-LOCKING.md](./ISSUE-DSQL-LOCKING.md) for details.

## 🚨 Active Issues

### Critical Issues
- **[DSQL-LOCK-001](./ISSUE-DSQL-LOCKING.md)**: DSQL Locking Limitation
  - **Status**: Open - High Priority
  - **Impact**: System workflows fail to initialize due to unsupported locking clauses
  - **Error**: `ERROR: locking clauses other than FOR UPDATE are not supported (SQLSTATE 0A000)`
  - **Next Action**: Implement DSQL-compatible shard locking mechanism

### Medium Priority Issues
- **[OPENSEARCH-001](./ISSUE-OPENSEARCH-SERVERLESS.md)**: OpenSearch Serverless Compatibility
  - **Status**: In Progress - Medium Priority
  - **Branch**: `feature/opensearch-provisioned`
  - **Impact**: Visibility store may not function correctly with serverless OpenSearch
  - **Solution**: Replace with provisioned OpenSearch cluster (t3.small.search)
  - **Timeline**: In Development - Terraform configuration update
  - **Next Action**: Update Terraform to use provisioned OpenSearch domain

### Resolved Issues
- **[DSQL-BIN-001]**: Nexus Endpoints Binary Field Panic ✅ **RESOLVED**
  - **Fix**: Safe UUID string conversion with `bytesToUUIDString()` helper
  - **Impact**: All containers now run without crashes
  - **Date Resolved**: 2024-12-30

## 📋 Development Roadmap

### Immediate Priority (Next 1-2 days)
1. **🚨 CRITICAL**: Resolve DSQL locking limitation (DSQL-LOCK-001)
2. **📅 TOMORROW**: Replace OpenSearch Serverless with Provisioned (OPENSEARCH-001)
   - Update Terraform configuration for t3.small.search instances
   - Test connectivity and Temporal visibility integration
   - Validate search and indexing functionality
3. **Monitor VPC Endpoint**: Watch for AWS service updates resolving VPC endpoint connectivity

### Short Term (1-2 weeks)
1. **Performance Testing**: Benchmark DSQL performance under production-like loads
2. **Integration Testing**: Comprehensive testing with both DSQL and OpenSearch fixes
3. **Observability**: Implement DSQL-specific metrics and monitoring

### Medium Term (1-2 months)
1. **Production Migration**: Follow [Production Migration Guide](docs/PRODUCTION-MIGRATION.md) for production deployment
2. **Security Enhancement**: Implement AWS Secrets Manager integration
3. **OpenSearch Optimization**: Multi-AZ deployment and enhanced monitoring

### Long Term (3+ months)
1. **Multi-Region Support**: Plan for DSQL's multi-region capabilities
2. **Performance Optimization**: Optimize for DSQL's optimistic concurrency model
3. **Production Hardening**: Enhanced monitoring, alerting, and operational procedures
