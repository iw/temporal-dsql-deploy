#!/usr/bin/env bash
set -euo pipefail

# Simple VPN status checker
echo "🔍 Checking VPN Connection Status"
echo "================================="

VPN_IP=$(ifconfig | grep -E "inet (10\.254\.|172\.)" | head -1 | awk '{print $2}' 2>/dev/null || echo "")

if [[ -n "$VPN_IP" ]]; then
    echo "✅ VPN Connected: $VPN_IP"
    echo ""
    echo "🎉 Ready to proceed with DSQL schema setup!"
    echo "   Run: ./scripts/setup-dsql-schema.sh"
else
    echo "❌ VPN Not Connected"
    echo ""
    echo "📋 To connect:"
    echo "1. Import temporal-dsql-vpn-config.ovpn into Tunnelblick"
    echo "2. Connect to 'client-vpn-server'"
    echo "3. Run this script again to verify"
fi

echo ""
echo "💡 Expected VPN IP range: 10.254.0.0/22"