# Scripts Workflow

This document explains how the scripts work together for different use cases.

## Complete End-to-End Workflow

### 1. **Full Automated Deployment** (Recommended)
```bash
# Set ACM certificate ARNs (from certificate helper)
export CLIENT_VPN_SERVER_CERT_ARN="arn:aws:acm:..."
export CLIENT_VPN_ROOT_CERT_ARN="arn:aws:acm:..."

# Deploy everything (builds images + deploys infrastructure)
./scripts/deploy-test-env.sh

# Connect and run
sudo openvpn --config client-vpn.ovpn --daemon
docker compose up -d
```

**What happens:**
1. ✅ Builds `temporal-dsql:latest` from your fork
2. ✅ Builds `temporal-dsql-runtime:test` deployment image  
3. ✅ Validates image compatibility
4. ✅ Deploys AWS infrastructure (VPC, DSQL, VPN)
5. ✅ Generates VPN config and `.env` file

---

## Individual Script Usage

### 2. **Build Images Only**
```bash
# Build with default path (../temporal-dsql)
./scripts/build-temporal-dsql.sh

# Build with custom path
./scripts/build-temporal-dsql.sh /path/to/temporal-dsql
```

**What it does:**
- Builds `temporal-dsql:latest` from your fork
- Validates base image structure
- Builds `temporal-dsql-runtime:test` 
- Tests configuration rendering
- **Does NOT deploy AWS infrastructure**

### 3. **Deploy Infrastructure Only**
```bash
# Skip image building (assumes images exist)
BUILD_IMAGES=false ./scripts/deploy-test-env.sh
```

**What it does:**
- Skips image building
- Deploys AWS infrastructure only
- Generates VPN config and `.env` file
- **Assumes `temporal-dsql:latest` already exists**

### 4. **Generate .env from Existing Infrastructure**
```bash
# Generate .env from Terraform state
./scripts/terraform-to-env.sh > .env
```

**What it does:**
- Reads existing Terraform outputs
- Generates Docker Compose `.env` file
- **Assumes infrastructure already deployed**

---

## Environment Variables

### Required (for deployment)
```bash
CLIENT_VPN_SERVER_CERT_ARN="arn:aws:acm:..."
CLIENT_VPN_ROOT_CERT_ARN="arn:aws:acm:..."
```

### Optional (for customization)
```bash
PROJECT_NAME="my-test-env"           # Default: temporal-test-<timestamp>
AWS_REGION="us-west-2"               # Default: eu-west-1
TEMPORAL_DSQL_PATH="/path/to/fork"   # Default: ../temporal-dsql
BUILD_IMAGES="false"                 # Default: true
```

---

## Common Workflows

### Development Workflow
```bash
# 1. Make changes to temporal-dsql fork
# 2. Build and test images
./scripts/build-temporal-dsql.sh

# 3. Deploy test environment  
./scripts/deploy-test-env.sh

# 4. Test your changes
docker compose up -d

# 5. Cleanup when done
cd terraform && terraform destroy -auto-approve
```

### CI/CD Workflow
```bash
# Build and test images
./scripts/build-temporal-dsql.sh $TEMPORAL_DSQL_PATH

# Deploy with custom settings
PROJECT_NAME="ci-test-$BUILD_ID" \
AWS_REGION="us-west-2" \
BUILD_IMAGES="false" \
./scripts/deploy-test-env.sh

# Run tests...

# Cleanup
cd terraform && terraform destroy -auto-approve
```

### Quick Infrastructure-Only Deployment
```bash
# If you already have images built
BUILD_IMAGES=false ./scripts/deploy-test-env.sh

# Or just generate config from existing infrastructure
./scripts/terraform-to-env.sh > .env
```

---

## Script Dependencies

```
deploy-test-env.sh
├── build-temporal-dsql.sh (optional, if BUILD_IMAGES=true)
├── terraform (required)
├── aws cli (required)
└── docker (required)

build-temporal-dsql.sh
├── temporal-dsql source (required)
└── docker (required)

terraform-to-env.sh  
├── terraform state (required)
└── jq (required)
```