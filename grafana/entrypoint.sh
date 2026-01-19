#!/usr/bin/env sh
set -eu

# Substitute environment variables in datasources.yaml
# PROMETHEUS_URL - Prometheus/Mimir endpoint URL
# AWS_REGION - AWS region for CloudWatch (optional)

DATASOURCES_FILE="/etc/grafana/provisioning/datasources/datasources.yaml"

if [ -n "${PROMETHEUS_URL:-}" ]; then
    sed -i "s|\${PROMETHEUS_URL}|${PROMETHEUS_URL}|g" "$DATASOURCES_FILE"
fi

if [ -n "${AWS_REGION:-}" ]; then
    sed -i "s|\${AWS_REGION}|${AWS_REGION}|g" "$DATASOURCES_FILE"
fi

exec /run.sh
