# Scripts Directory

This directory contains automation scripts for deploying and testing Temporal with Aurora DSQL.

## 🚀 Quick Start

For immediate development and testing with Aurora DSQL:

```bash
# 1. Deploy infrastructure
./scripts/deploy-test-env.sh

# 2. Setup schema (uses public endpoint + IAM auth)
./scripts/setup-dsql-schema-simple.sh

# 3. Test integration
./scripts/test-temporal-dsql-integration.sh

# 4. Cleanup when done
./scripts/cleanup-aws-resources.sh
```

## 📋 Script Categories

### ✅ Current & Recommended (Public Endpoint)
- **`setup-dsql-schema-simple.sh`** - Schema setup using DSQL public endpoint with IAM auth
- **`test-temporal-dsql-integration.sh`** - Full Temporal integration test with DSQL public endpoint
- **`build-temporal-dsql.sh`** - Build custom Temporal Docker images (multi-architecture)
- **`deploy-test-env.sh`** - Complete infrastructure deployment
- **`cleanup-aws-resources.sh`** - Clean up AWS resources and local state

### 🔧 Infrastructure & Deployment
- **`terraform-to-env.sh`** - Extract Terraform outputs to environment variables
- **`connect-vpn.sh`** - Download and configure AWS Client VPN profile
- **`setup-aws-vpn-client.sh`** - Install AWS Client VPN Desktop Application
- **`check-vpn-status.sh`** - Check VPN connection status

### 🧪 Testing & Validation
- **`test-dsql-connectivity.sh`** - Test DSQL connectivity using Go sample application
- **`test-temporal-dsql-minimal.sh`** - Minimal Docker image validation (no external dependencies)
- **`test-temporal-dsql-public.sh`** - Test Temporal with DSQL public endpoint
- **`test-aws-vpn-connectivity.sh`** - Test VPN connectivity and DNS resolution
- **`test-ssl-connectivity.sh`** - Test SSL/TLS connectivity to DSQL endpoints

### ⚠️ Legacy Scripts (VPC Endpoint Issues)
- **`setup-dsql-schema.sh`** - VPC endpoint schema setup (connectivity issues)
- **`test-temporal-integration.sh`** - VPC endpoint integration test (connectivity issues)
- **`complete-integration.sh`** - VPC endpoint workflow (connectivity issues)
- **`run-schema-setup.sh`** - Wrapper for legacy schema operations

### 📚 Documentation
- **`WORKFLOW.md`** - Detailed workflow documentation and step-by-step guides

## 🔍 DSQL Connectivity Discovery

### Current Working Approach: Public Endpoint ✅

During development, we discovered that **DSQL VPC endpoints have connectivity issues** on port 5432. The current working solution uses the **public endpoint** with IAM authentication:

```bash
# Working Configuration (Public Endpoint)
TEMPORAL_SQL_HOST=your-cluster-id.dsql.region.on.aws  # ✅ Works
TEMPORAL_SQL_USER=admin
TEMPORAL_SQL_DATABASE=postgres
# Uses IAM authentication - no password files needed
```

**Benefits of Public Endpoint Approach:**
- ✅ **Immediate connectivity** - No VPC endpoint issues
- ✅ **IAM authentication** - Secure, no static passwords
- ✅ **TLS encryption** - All traffic encrypted in transit
- ✅ **Simplified setup** - No VPN dependency for database access

### VPC Endpoint Issues (Legacy)

```bash
# VPC Endpoint (Not Working)
TEMPORAL_SQL_HOST=dsql-xxx.eu-west-1.on.aws  # ❌ Connection refused on port 5432
# Requires VPN connection but endpoint doesn't accept connections
```

**Symptoms:**
- VPN connects successfully (gets IP in 10.254.0.0/22 range)
- DNS resolution works for VPC endpoint
- Port 5432 connections are refused despite proper security groups
- Appears to be a service-level issue with DSQL VPC endpoints

### Infrastructure Value

The VPC + VPN infrastructure remains valuable:
- **Future-proofing**: Ready when VPC endpoint connectivity is resolved
- **Security reference**: Demonstrates complete private networking setup
- **Other services**: Provides secure access to other AWS services in the VPC

## 📊 Schema Management

### Temporal Schema Only

The current schema setup scripts create **only the Temporal persistence schema**:

```bash
# Creates Temporal persistence tables in 'postgres' database
./scripts/setup-dsql-schema-simple.sh
```

**What gets created:**
- Temporal workflow execution tables
- Task queue tables  
- History tables
- Timer tables
- All persistence-related schema objects

### Visibility Schema (OpenSearch)

**Visibility is handled by OpenSearch Provisioned**, not DSQL:
- Terraform provisions OpenSearch domain automatically
- No separate visibility schema setup needed in DSQL
- Temporal writes visibility data to OpenSearch, not the persistence database

**Configuration:**
```bash
# Persistence (DSQL)
TEMPORAL_SQL_HOST=your-cluster-id.dsql.region.on.aws
TEMPORAL_SQL_DATABASE=postgres

# Visibility (OpenSearch Provisioned)
TEMPORAL_OPENSEARCH_ENDPOINT=https://xxx.region.es.amazonaws.com
```

## 🏗️ Architecture Support

All build scripts support multiple architectures:

```bash
# Auto-detect architecture (recommended)
./scripts/build-temporal-dsql.sh ../temporal-dsql

# Explicit architecture
./scripts/build-temporal-dsql.sh ../temporal-dsql arm64  # Apple Silicon
./scripts/build-temporal-dsql.sh ../temporal-dsql amd64  # Intel/AMD

# Environment variable
TARGET_ARCH=arm64 ./scripts/deploy-test-env.sh
```

**Supported architectures:**
- `arm64` (aarch64) - Apple Silicon, AWS Graviton
- `amd64` (x86_64) - Intel/AMD 64-bit

## 🔐 Security & Authentication

### DSQL Authentication
- **IAM-based**: Uses AWS IAM tokens (no static passwords)
- **Automatic**: DSQL plugin handles token generation
- **Secure**: All connections use TLS encryption

### OpenSearch Authentication
- **IAM-based**: Uses AWS IAM for data access
- **Flexible**: Direct connection or via aws-sigv4-proxy
- **Scoped**: Access policies created by Terraform

### AWS Credentials
Scripts use standard AWS credential chain:
```bash
# Environment variables
AWS_ACCESS_KEY_ID=xxx
AWS_SECRET_ACCESS_KEY=xxx
AWS_SESSION_TOKEN=xxx  # If using temporary credentials

# Or AWS profiles
AWS_PROFILE=your-profile

# Or IAM roles (in EC2/ECS)
```

## 📝 Environment Variables

### Core DSQL Configuration
```bash
TEMPORAL_SQL_HOST=your-cluster-id.dsql.region.on.aws
TEMPORAL_SQL_PORT=5432
TEMPORAL_SQL_USER=admin
TEMPORAL_SQL_DATABASE=postgres
TEMPORAL_SQL_PLUGIN=dsql
TEMPORAL_SQL_TLS_ENABLED=true
```

### OpenSearch Configuration
```bash
TEMPORAL_OPENSEARCH_ENDPOINT=https://xxx.region.es.amazonaws.com
# No password needed - uses IAM authentication
```

### AWS Configuration
```bash
AWS_REGION=eu-west-1
AWS_ACCESS_KEY_ID=xxx
AWS_SECRET_ACCESS_KEY=xxx
```

## 🚨 Common Issues & Solutions

### "Connection refused" on port 5432
- **Cause**: Using VPC endpoint instead of public endpoint
- **Solution**: Use public endpoint in `TEMPORAL_SQL_HOST`

### "Authentication failed"
- **Cause**: Missing or invalid AWS credentials
- **Solution**: Verify AWS credentials and IAM permissions

### "Image not found" errors
- **Cause**: Docker images not built for correct architecture
- **Solution**: Use `./scripts/build-temporal-dsql.sh` with correct arch

### Schema version mismatch
- **Cause**: Using wrong schema version
- **Solution**: Use version 1.0 in schema setup scripts

## 💡 Development Tips

1. **Use public endpoint**: Faster setup, no VPN dependency
2. **Keep infrastructure**: VPC/VPN useful for future and other services
3. **IAM authentication**: More secure than static passwords
4. **Multi-arch builds**: Ensure correct architecture for your platform
5. **OpenSearch separate**: Visibility uses OpenSearch, not DSQL