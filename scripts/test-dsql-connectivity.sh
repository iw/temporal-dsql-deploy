#!/usr/bin/env bash
set -euo pipefail

# DSQL Connectivity Test Script
# This script builds and runs the AWS DSQL sample to test connectivity independently of Temporal

echo "🧪 DSQL Connectivity Test"
echo "========================="

# Check prerequisites
if [[ ! -f ".env.integration" ]]; then
    echo "❌ Integration environment file not found: .env.integration"
    echo "   Run the secrets setup first"
    exit 1
fi

# Source environment variables
source .env.integration

echo "📡 DSQL Endpoint: $CLUSTER_ENDPOINT"
echo "🌍 Region: $REGION"
echo "👤 User: $CLUSTER_USER"
echo ""

# Check VPN connectivity first
echo "🔍 Checking VPN Connectivity"
echo "---------------------------"
VPN_IP=$(ifconfig | grep -E "inet (10\.254\.|172\.)" | head -1 | awk '{print $2}' 2>/dev/null || echo "")
if [[ -z "$VPN_IP" ]]; then
    echo "❌ No VPN connection detected"
    echo "   Expected IP range: 10.254.0.0/22"
    echo "   Connect to VPN first: ./scripts/connect-vpn.sh"
    exit 1
fi
echo "✅ VPN connected: $VPN_IP"

echo ""
echo "🏗️  Building DSQL Connectivity Test"
echo "==================================="

# Build the Docker image
echo "Building Docker image..."
docker build -t dsql-connectivity-test ./test-dsql-connectivity/

if [[ $? -ne 0 ]]; then
    echo "❌ Failed to build Docker image"
    exit 1
fi

echo "✅ Docker image built successfully"

echo ""
echo "🧪 Running DSQL Connectivity Test"
echo "================================="

# Run the connectivity test
docker run --rm \
    --network host \
    --env CLUSTER_ENDPOINT="$CLUSTER_ENDPOINT" \
    --env REGION="$REGION" \
    --env CLUSTER_USER="$CLUSTER_USER" \
    --env DB_PORT="5432" \
    --env DB_NAME="postgres" \
    --env TOKEN_EXPIRY_SECS="30" \
    --volume ~/.aws:/home/dsqltest/.aws:ro \
    --env AWS_PROFILE \
    --env AWS_ACCESS_KEY_ID \
    --env AWS_SECRET_ACCESS_KEY \
    --env AWS_SESSION_TOKEN \
    --env AWS_REGION="$REGION" \
    dsql-connectivity-test

if [[ $? -eq 0 ]]; then
    echo ""
    echo "🎉 DSQL Connectivity Test Completed Successfully!"
    echo ""
    echo "✅ This confirms that:"
    echo "   • VPN connectivity is working"
    echo "   • DSQL cluster is accessible"
    echo "   • IAM authentication is working"
    echo "   • PostgreSQL protocol is working"
    echo "   • Basic CRUD operations work"
    echo ""
    echo "💡 The issue with temporal-sql-tool might be:"
    echo "   • Configuration differences"
    echo "   • Different connection parameters"
    echo "   • Temporal-specific connection handling"
else
    echo ""
    echo "❌ DSQL Connectivity Test Failed"
    echo ""
    echo "🔧 This helps isolate the issue:"
    echo "   • If this test fails, the issue is with basic connectivity"
    echo "   • If this test passes, the issue is with Temporal's connection handling"
    echo ""
    echo "📋 Next steps:"
    echo "   • Check the error logs above"
    echo "   • Verify VPN connection"
    echo "   • Check AWS credentials"
    echo "   • Verify DSQL cluster status"
fi