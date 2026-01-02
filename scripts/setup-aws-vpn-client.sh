#!/bin/bash

# Setup AWS Client VPN Desktop Application
# This script helps transition from Tunnelblick to AWS Client VPN

set -e

echo "🔧 Setting up AWS Client VPN Desktop Application"
echo "================================================"

# Check if AWS Client VPN is installed
if ! command -v "/Applications/AWS VPN Client/AWS VPN Client.app/Contents/MacOS/AWS VPN Client" &> /dev/null; then
    echo "❌ AWS Client VPN Desktop Application not found"
    echo ""
    echo "Please download and install it from:"
    echo "https://aws.amazon.com/vpn/client-vpn-download/"
    echo ""
    echo "After installation, run this script again."
    exit 1
fi

echo "✅ AWS Client VPN Desktop Application found"

# Export the latest VPN configuration
echo "📥 Exporting latest VPN configuration..."
aws ec2 export-client-vpn-client-configuration \
    --client-vpn-endpoint-id cvpn-endpoint-0109c18902e9453d3 \
    --region eu-west-1 \
    --output text > temporal-dsql-aws-vpn.ovpn

echo "✅ VPN configuration exported to: temporal-dsql-aws-vpn.ovpn"

# Add client certificate to the configuration
echo "🔐 Adding client certificate to configuration..."
cat >> temporal-dsql-aws-vpn.ovpn << 'EOF'

<cert>
EOF

cat clients/client1.crt >> temporal-dsql-aws-vpn.ovpn

cat >> temporal-dsql-aws-vpn.ovpn << 'EOF'
</cert>

<key>
EOF

cat clients/client1.key >> temporal-dsql-aws-vpn.ovpn

cat >> temporal-dsql-aws-vpn.ovpn << 'EOF'
</key>
EOF

echo "✅ Client certificate added to configuration"

echo ""
echo "🎯 Next steps:"
echo "1. Disconnect from Tunnelblick if connected"
echo "2. Open AWS Client VPN Desktop Application"
echo "3. Import the configuration file: temporal-dsql-aws-vpn.ovpn"
echo "4. Connect to the VPN"
echo "5. Test DSQL connectivity"
echo ""
echo "The AWS Client VPN should automatically:"
echo "- Configure DNS resolution for private domains"
echo "- Set up proper routing for both VPC subnets"
echo "- Handle DHCP options correctly"