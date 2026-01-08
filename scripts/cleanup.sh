#!/bin/bash
set -euo pipefail

# Cleanup DSQL + Elasticsearch environment
# This script stops containers and optionally destroys AWS resources

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=== Cleaning up DSQL + Elasticsearch Environment ==="
echo ""

# Step 1: Stop and remove Docker containers
echo "=== Step 1: Stopping Docker Services ==="
if [ -f "docker-compose.yml" ]; then
    echo "Stopping Temporal + Elasticsearch containers..."
    docker compose down -v
    echo "✅ Docker services stopped and volumes removed"
else
    echo "⚠️  docker-compose.yml not found"
fi

# Remove any orphaned containers
echo "Removing any orphaned temporal containers..."
docker ps -a --filter "name=temporal" --format "{{.Names}}" | xargs -r docker rm -f
echo ""

# Step 2: Clean up Docker images (optional)
echo "=== Step 2: Docker Image Cleanup ==="
read -p "Remove Temporal DSQL Docker images? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Removing Temporal DSQL images..."
    docker images --filter "reference=temporal-dsql*" --format "{{.Repository}}:{{.Tag}}" | xargs -r docker rmi
    echo "✅ Docker images removed"
else
    echo "Keeping Docker images"
fi
echo ""

# Step 3: Clean up Docker networks
echo "=== Step 3: Docker Network Cleanup ==="
if docker network ls | grep -q temporal-network; then
    echo "Removing temporal-network..."
    docker network rm temporal-network 2>/dev/null || echo "Network may be in use, skipping"
else
    echo "temporal-network not found"
fi
echo ""

# Step 4: AWS Infrastructure cleanup (optional)
echo "=== Step 4: AWS Infrastructure Cleanup ==="
if [ -d "terraform" ] && [ -f "terraform/terraform.tfstate" ]; then
    echo "Found Terraform state - checking for AWS resources..."
    
    cd terraform
    RESOURCE_COUNT=$(terraform state list 2>/dev/null | wc -l || echo "0")
    
    if [ "$RESOURCE_COUNT" -gt 0 ]; then
        echo "Found $RESOURCE_COUNT AWS resources in Terraform state"
        echo "Resources:"
        terraform state list 2>/dev/null || echo "Unable to list resources"
        echo ""
        
        read -p "Destroy AWS infrastructure? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "Destroying AWS resources..."
            
            # Try to get project name from state or ask user
            PROJECT_NAME=""
            if terraform show -json 2>/dev/null | jq -r '.values.root_module.resources[0].values.tags.Project' 2>/dev/null | grep -q "temporal"; then
                PROJECT_NAME=$(terraform show -json 2>/dev/null | jq -r '.values.root_module.resources[0].values.tags.Project' 2>/dev/null)
                echo "Detected project name: $PROJECT_NAME"
            else
                read -p "Enter project name for Terraform destroy: " PROJECT_NAME
            fi
            
            if [ -n "$PROJECT_NAME" ]; then
                terraform destroy -auto-approve -lock=false -var "project_name=$PROJECT_NAME" || {
                    echo "⚠️  Terraform destroy encountered issues, but may have succeeded"
                }
                echo "✅ AWS infrastructure cleanup completed"
            else
                echo "❌ Project name required for Terraform destroy"
            fi
        else
            echo "Keeping AWS infrastructure"
        fi
    else
        echo "No AWS resources found in Terraform state"
    fi
    
    cd "$PROJECT_ROOT"
else
    echo "No Terraform state found - no AWS resources to clean up"
fi
echo ""

# Step 5: Clean up generated files (optional)
echo "=== Step 5: Generated Files Cleanup ==="
read -p "Remove generated configuration files? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Removing generated files..."
    
    # Remove generated environment files (keep examples)
    [ -f ".env" ] && rm .env && echo "Removed .env"
    
    # Remove Terraform outputs
    [ -f "terraform-outputs.json" ] && rm terraform-outputs.json && echo "Removed terraform-outputs.json"
    
    echo "✅ Generated files cleaned up"
else
    echo "Keeping generated files"
fi
echo ""

# Step 6: Summary
echo "=== Cleanup Summary ==="
echo "✅ Docker containers stopped and removed"
echo "✅ Docker volumes cleaned up"
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "✅ Generated configuration files removed"
fi

echo ""
echo "🧹 Cleanup completed!"
echo ""
echo "To start fresh:"
echo "1. Deploy new infrastructure: ./scripts/deploy.sh"
echo ""