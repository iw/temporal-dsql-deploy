#!/bin/bash

# Test AWS Client VPN connectivity to DSQL
# Run this after connecting with AWS Client VPN Desktop Application

set -e

echo "🧪 Testing AWS Client VPN Connectivity to DSQL"
echo "==============================================="

# Test 1: Basic VPC connectivity
echo "1️⃣ Testing basic VPC connectivity..."
if ping -c 3 10.50.10.1 > /dev/null 2>&1; then
    echo "✅ Can reach VPC gateway (10.50.10.1)"
else
    echo "❌ Cannot reach VPC gateway (10.50.10.1)"
    exit 1
fi

# Test 2: DNS resolution
echo ""
echo "2️⃣ Testing DNS resolution..."
if nslookup dsql-2syq.eu-west-1.on.aws > /dev/null 2>&1; then
    echo "✅ DNS resolution working for dsql-2syq.eu-west-1.on.aws"
    echo "   Resolved to:"
    nslookup dsql-2syq.eu-west-1.on.aws | grep "Address:" | grep -v "#53"
else
    echo "❌ DNS resolution failed for dsql-2syq.eu-west-1.on.aws"
    exit 1
fi

# Test 3: VPC endpoint connectivity
echo ""
echo "3️⃣ Testing VPC endpoint connectivity..."
VPC_ENDPOINT_IPS=$(nslookup dsql-2syq.eu-west-1.on.aws | grep "Address:" | grep -v "#53" | awk '{print $2}')

for ip in $VPC_ENDPOINT_IPS; do
    echo "   Testing connectivity to $ip..."
    if timeout 5 bash -c "echo >/dev/tcp/$ip/5432" 2>/dev/null; then
        echo "   ✅ Can connect to $ip:5432"
    else
        echo "   ❌ Cannot connect to $ip:5432"
    fi
done

# Test 4: DSQL connectivity with AWS sample
echo ""
echo "4️⃣ Testing DSQL connectivity with AWS sample..."
echo "   This will test IAM authentication and database operations..."

docker run --rm --network host \
    -e CLUSTER_ENDPOINT=dsql-2syq.eu-west-1.on.aws \
    -e REGION=eu-west-1 \
    -e CLUSTER_USER=admin \
    -e DB_NAME=postgres \
    -v ~/.aws:/root/.aws:ro \
    dsql-connectivity-test

echo ""
echo "🎉 All tests completed!"