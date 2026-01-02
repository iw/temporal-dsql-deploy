#!/bin/bash

# Test SSL connectivity to DSQL endpoints
echo "🔐 Testing SSL connectivity to DSQL endpoints"
echo "=============================================="

# Test SSL connectivity to each endpoint IP
VPC_ENDPOINT_IPS=$(nslookup dsql-2syq.eu-west-1.on.aws | grep "Address:" | grep -v "#53" | awk '{print $2}')

for ip in $VPC_ENDPOINT_IPS; do
    echo "Testing SSL connectivity to $ip:5432..."
    
    # Test with openssl s_client using the proper hostname for SNI
    gtimeout 10 openssl s_client -connect $ip:5432 -servername dsql-2syq.eu-west-1.on.aws -verify_return_error < /dev/null 2>&1 | head -20 || echo "Connection failed or timed out"
    
    echo "---"
done

echo ""
echo "Testing with PostgreSQL SSL connection..."

# Test with psql using SSL
export PGPASSWORD="dummy"
gtimeout 10 psql "host=dsql-2syq.eu-west-1.on.aws port=5432 dbname=postgres user=admin sslmode=require" -c "SELECT 1;" 2>&1 || echo "Expected to fail with auth error, not connection error"