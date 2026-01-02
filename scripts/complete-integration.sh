#!/usr/bin/env bash
set -euo pipefail

# Complete DSQL Integration Workflow
# This script orchestrates the complete integration process

echo "🚀 Complete Temporal DSQL Integration Workflow"
echo "=============================================="
echo ""
echo "This script will guide you through the complete integration process:"
echo "1. Verify prerequisites"
echo "2. Setup database schema (requires VPN connection)"
echo "3. Run integration tests"
echo "4. Start Temporal services"
echo ""

# Check prerequisites
echo "📋 Checking Prerequisites"
echo "========================="

MISSING_PREREQS=0

# Check if infrastructure is deployed
if [[ ! -f "terraform/terraform.tfstate" ]]; then
    echo "❌ Terraform infrastructure not deployed"
    echo "   Run: terraform apply in terraform/ directory"
    MISSING_PREREQS=1
fi

# Check if secrets exist
if [[ ! -d "secrets" ]] || [[ ! -f "secrets/temporal-db-password" ]]; then
    echo "❌ Secrets not configured"
    echo "   Secrets were created in this session"
    MISSING_PREREQS=1
fi

# Check if Docker images exist
if ! docker image inspect temporal-dsql-runtime:test >/dev/null 2>&1; then
    echo "❌ Docker images not built"
    echo "   Run: ./scripts/build-temporal-dsql.sh ../temporal-dsql"
    MISSING_PREREQS=1
fi

# Check if VPN config exists
if [[ ! -f "temporal-dsql-vpn-config.ovpn" ]]; then
    echo "❌ VPN configuration not found"
    echo "   VPN config was generated in this session"
    MISSING_PREREQS=1
fi

if [[ $MISSING_PREREQS -eq 1 ]]; then
    echo ""
    echo "❌ Prerequisites not met. Please complete the missing steps above."
    exit 1
fi

echo "✅ All prerequisites met"
echo ""

# Check VPN connection
echo "🔍 Checking VPN Connection"
echo "=========================="
VPN_IP=$(ifconfig | grep -E "inet (10\.254\.|172\.)" | head -1 | awk '{print $2}' 2>/dev/null || echo "")
if [[ -z "$VPN_IP" ]]; then
    echo "❌ VPN not connected"
    echo ""
    echo "📋 VPN Connection Required"
    echo "========================="
    echo "1. Import VPN configuration: temporal-dsql-vpn-config.ovpn"
    echo "2. Connect using your VPN client"
    echo "3. Run this script again"
    echo ""
    echo "For help: ./scripts/connect-vpn.sh"
    exit 1
fi

echo "✅ VPN connected: $VPN_IP"
echo ""

# Step 1: Database Schema Setup
echo "🗄️  Step 1: Database Schema Setup"
echo "================================="
echo "Setting up DSQL database schema..."
echo ""

if ./scripts/setup-dsql-schema.sh; then
    echo "✅ Database schema setup completed"
else
    echo "❌ Database schema setup failed"
    echo "   Check the error messages above and resolve issues"
    exit 1
fi

echo ""

# Step 2: Integration Testing
echo "🧪 Step 2: Integration Testing"
echo "=============================="
echo "Running integration tests..."
echo ""

if ./scripts/test-temporal-integration.sh; then
    echo "✅ Integration tests passed"
else
    echo "❌ Integration tests failed"
    echo "   Check the error messages above"
    exit 1
fi

echo ""
echo "🎉 Complete Integration Successful!"
echo "=================================="
echo ""
echo "🌐 Your Temporal DSQL environment is ready:"
echo "   • Temporal gRPC: localhost:7233"
echo "   • Temporal HTTP: localhost:8233"
echo "   • Temporal UI: http://localhost:8080"
echo ""
echo "📊 Infrastructure Summary:"
echo "   • Aurora DSQL: $(terraform -chdir=terraform output -raw dsql_cluster_arn)"
echo "   • OpenSearch: $(terraform -chdir=terraform output -raw opensearch_collection_endpoint)"
echo "   • VPN Endpoint: $(terraform -chdir=terraform output -raw client_vpn_endpoint_id)"
echo ""
echo "💡 Next Steps:"
echo "   • Develop and test workflows using Temporal SDKs"
echo "   • Monitor performance and adjust configuration"
echo "   • Plan production migration using docs/PRODUCTION-MIGRATION.md"
echo ""
echo "🛑 To stop services:"
echo "   docker compose -f docker-compose.services.yml down"
echo ""
echo "🧹 To cleanup all resources:"
echo "   ./scripts/cleanup-aws-resources.sh"