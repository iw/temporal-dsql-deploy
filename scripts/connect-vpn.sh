#!/usr/bin/env bash
set -euo pipefail

# VPN Connection Helper Script
# This script helps connect to the AWS Client VPN and test DSQL connectivity

echo "🔐 AWS Client VPN Connection Helper"
echo "==================================="

# Check if VPN config exists
if [[ ! -f "temporal-dsql-vpn-config.ovpn" ]]; then
    echo "❌ VPN configuration file not found: temporal-dsql-vpn-config.ovpn"
    echo "   Run the infrastructure deployment first"
    exit 1
fi

# Get DSQL endpoint from Terraform outputs
if [[ -f "terraform/terraform.tfstate" ]]; then
    DSQL_ENDPOINT=$(terraform -chdir=terraform output -json dsql_vpc_endpoint_dns_entries | jq -r '.[0].dns_name')
    echo "📡 DSQL Endpoint: $DSQL_ENDPOINT"
else
    echo "⚠️  No Terraform state found - cannot determine DSQL endpoint"
    DSQL_ENDPOINT="unknown"
fi

echo ""
echo "📋 VPN Connection Instructions"
echo "=============================="
echo ""
echo "1. **Import VPN Configuration:**"
echo "   • macOS: Import 'temporal-dsql-vpn-config.ovpn' into Tunnelblick"
echo "   • Linux: Use OpenVPN client: sudo openvpn temporal-dsql-vpn-config.ovpn"
echo "   • Windows: Use OpenVPN GUI"
echo ""
echo "2. **Connect to VPN:**"
echo "   • Use your VPN client to connect"
echo "   • You should receive an IP in the range 10.254.0.0/22"
echo ""
echo "3. **Test Connectivity:**"
echo "   • Run this script with 'test' argument: $0 test"
echo ""

# Test connectivity if requested
if [[ "${1:-}" == "test" ]]; then
    echo "🧪 Testing VPN Connectivity"
    echo "=========================="
    echo ""
    
    # Check if we have a VPN IP
    VPN_IP=$(ifconfig | grep -E "inet (10\.254\.|172\.)" | head -1 | awk '{print $2}' || echo "")
    if [[ -n "$VPN_IP" ]]; then
        echo "✅ VPN IP detected: $VPN_IP"
    else
        echo "❌ No VPN IP detected - ensure VPN is connected"
        echo "   Expected IP range: 10.254.0.0/22"
        exit 1
    fi
    
    echo ""
    echo "🔍 Testing DSQL Connectivity"
    echo "---------------------------"
    
    if [[ "$DSQL_ENDPOINT" != "unknown" ]]; then
        echo "Testing connection to: $DSQL_ENDPOINT:5432"
        
        # Test with netcat if available
        if command -v nc >/dev/null 2>&1; then
            if timeout 5 nc -zv "$DSQL_ENDPOINT" 5432 2>/dev/null; then
                echo "✅ DSQL endpoint is reachable on port 5432"
            else
                echo "❌ DSQL endpoint is not reachable"
                echo "   This could be normal if:"
                echo "   • VPN is not connected"
                echo "   • Security groups are blocking access"
                echo "   • DSQL cluster is not ready"
            fi
        else
            echo "⚠️  netcat not available - cannot test port connectivity"
            echo "   Install netcat: brew install netcat (macOS) or apt-get install netcat (Linux)"
        fi
        
        # Test DNS resolution
        echo ""
        echo "🔍 Testing DNS Resolution"
        echo "-----------------------"
        if nslookup "$DSQL_ENDPOINT" >/dev/null 2>&1; then
            echo "✅ DNS resolution successful"
            nslookup "$DSQL_ENDPOINT" | grep -A2 "Name:"
        else
            echo "❌ DNS resolution failed"
        fi
    else
        echo "⚠️  Cannot test - DSQL endpoint unknown"
    fi
    
    echo ""
    echo "📋 Connection Summary"
    echo "===================="
    if [[ -n "$VPN_IP" ]]; then
        echo "✅ VPN: Connected ($VPN_IP)"
    else
        echo "❌ VPN: Not connected"
    fi
    
    if [[ "$DSQL_ENDPOINT" != "unknown" ]]; then
        echo "📡 DSQL: $DSQL_ENDPOINT:5432"
    else
        echo "❌ DSQL: Endpoint unknown"
    fi
    
    echo ""
    echo "💡 Next Steps:"
    echo "   • If connectivity works, proceed with database setup"
    echo "   • If issues, check VPN client logs and AWS Console"
    echo "   • Use AWS Console to verify VPN endpoint status"
fi

echo ""
echo "🔧 Troubleshooting"
echo "=================="
echo "• VPN Client Logs: Check your VPN client for connection errors"
echo "• AWS Console: EC2 > Client VPN Endpoints > cvpn-endpoint-0109c18902e9453d3"
echo "• Security Groups: Ensure port 5432 is allowed from VPN CIDR"
echo "• DSQL Status: Check DSQL cluster status in AWS Console"
echo ""
echo "🔐 Security Reminder"
echo "==================="
echo "• This setup uses local files for credentials (development only)"
echo "• For production: Use AWS Secrets Manager for database credentials"
echo "• Configure IAM roles for DSQL authentication where possible"
echo "• Enable automatic secret rotation and least-privilege access"
echo ""
echo "📞 Support Commands:"
echo "• Check VPN status: aws ec2 describe-client-vpn-endpoints --region eu-west-1"
echo "• Check DSQL status: aws dsql describe-cluster --identifier <cluster-id> --region eu-west-1"