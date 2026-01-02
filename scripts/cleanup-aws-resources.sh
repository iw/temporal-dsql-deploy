#!/usr/bin/env bash
set -euo pipefail

# Cleanup script for AWS resources created by temporal-dsql-deploy
# This script safely tears down all infrastructure and cleans up certificates

echo "🧹 AWS Resources Cleanup for temporal-dsql-deploy"
echo "================================================="

# Check if we're in the right directory
if [[ ! -f "terraform/main.tf" ]]; then
    echo "❌ Error: Must be run from temporal-dsql-deploy root directory"
    exit 1
fi

# Function to confirm destructive actions
confirm_action() {
    local action="$1"
    echo ""
    echo "⚠️  WARNING: This will $action"
    read -p "Are you sure? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        echo "❌ Cancelled by user"
        exit 1
    fi
}

# Step 1: Terraform Destroy
echo ""
echo "🏗️  Step 1: Destroying Terraform Infrastructure"
echo "----------------------------------------------"
if [[ -f "terraform/terraform.tfstate" ]] || [[ -d "terraform/.terraform" ]]; then
    confirm_action "destroy ALL AWS infrastructure (VPC, DSQL, OpenSearch, VPN)"
    
    cd terraform
    echo "Running terraform destroy..."
    terraform destroy -auto-approve
    cd ..
    echo "✅ Terraform infrastructure destroyed"
else
    echo "ℹ️  No Terraform state found - skipping infrastructure destroy"
fi

# Step 2: Clean up ACM certificates
echo ""
echo "🔐 Step 2: Cleaning up ACM Certificates"
echo "--------------------------------------"
if [[ -f ".acm/server-import.json" ]] || [[ -f ".acm/root-import.json" ]]; then
    confirm_action "delete ACM certificates"
    
    # Delete server certificate
    if [[ -f ".acm/server-import.json" ]]; then
        SERVER_ARN=$(jq -r '.CertificateArn' .acm/server-import.json)
        echo "Deleting server certificate: $SERVER_ARN"
        aws acm delete-certificate --certificate-arn "$SERVER_ARN" --region eu-west-1 || echo "⚠️  Server certificate may already be deleted"
    fi
    
    # Delete root certificate
    if [[ -f ".acm/root-import.json" ]]; then
        ROOT_ARN=$(jq -r '.CertificateArn' .acm/root-import.json)
        echo "Deleting root certificate: $ROOT_ARN"
        aws acm delete-certificate --certificate-arn "$ROOT_ARN" --region eu-west-1 || echo "⚠️  Root certificate may already be deleted"
    fi
    
    echo "✅ ACM certificates cleaned up"
else
    echo "ℹ️  No ACM certificates found - skipping certificate cleanup"
fi

# Step 3: Clean up local certificate files
echo ""
echo "📁 Step 3: Cleaning up Local Certificate Files"
echo "---------------------------------------------"
if [[ -d "certs" ]] || [[ -d "server" ]] || [[ -d "clients" ]] || [[ -d ".acm" ]]; then
    confirm_action "delete all local certificate files and directories"
    
    uv run dsql-deploy clean || echo "⚠️  CLI clean failed, removing directories manually"
    
    # Manual cleanup if CLI fails
    rm -rf certs/ server/ clients/ .acm/ *.ext *.csr 2>/dev/null || true
    
    echo "✅ Local certificate files cleaned up"
else
    echo "ℹ️  No local certificate files found - skipping file cleanup"
fi

# Step 4: Clean up Docker images (optional)
echo ""
echo "🐳 Step 4: Docker Images Cleanup (Optional)"
echo "------------------------------------------"
if docker image inspect temporal-dsql:latest >/dev/null 2>&1 || docker image inspect temporal-dsql-runtime:test >/dev/null 2>&1; then
    echo "Found temporal-dsql Docker images:"
    docker images | grep temporal-dsql || true
    echo ""
    read -p "Remove temporal-dsql Docker images? (yes/no): " -r
    if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        docker rmi temporal-dsql:latest temporal-dsql-runtime:test 2>/dev/null || echo "⚠️  Some images may already be removed"
        echo "✅ Docker images cleaned up"
    else
        echo "ℹ️  Docker images kept"
    fi
else
    echo "ℹ️  No temporal-dsql Docker images found"
fi

# Step 5: Summary
echo ""
echo "📋 Cleanup Summary"
echo "=================="
echo "✅ Infrastructure: Destroyed (if existed)"
echo "✅ ACM Certificates: Deleted (if existed)"
echo "✅ Local Files: Cleaned up (if existed)"
echo "✅ Docker Images: Handled per user choice"
echo ""
echo "🎉 Cleanup completed successfully!"
echo ""
echo "💡 To start fresh:"
echo "   1. Run: ./scripts/deploy-test-env.sh"
echo "   2. Or follow the step-by-step integration guide"
echo ""
echo "💰 Cost Impact:"
echo "   • All billable AWS resources have been destroyed"
echo "   • No ongoing charges should occur"
echo "   • Verify in AWS Console if needed"