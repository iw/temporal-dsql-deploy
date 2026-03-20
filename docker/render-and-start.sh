#!/bin/bash
set -euo pipefail

# render-and-start.sh — Renders persistence YAML template by substituting
# environment variables, validates the result, then starts temporal-server.
#
# All CLI arguments ($@) are passed through to temporal-server, enabling
# --config-file and --service flags from docker-compose command.

TEMPLATE="${TEMPORAL_PERSISTENCE_TEMPLATE:-/etc/temporal/config/persistence-dsql-elasticsearch.template.yaml}"
OUTPUT="${TEMPORAL_PERSISTENCE_CONFIG:-/etc/temporal/config/persistence-dsql.yaml}"

# --- Resolve bind and broadcast addresses ---
# If BIND_ON_IP is not set, resolve from hostname (matches base entrypoint logic)
: "${BIND_ON_IP:=$(getent hosts "$(hostname)" | awk '{print $1;}')}"
export BIND_ON_IP

# Broadcast address: the IP other services use to reach this one (ringpop).
# When binding to wildcard (0.0.0.0), resolve the actual container IP.
# Otherwise, broadcast the same IP we're binding to.
if [ "${BIND_ON_IP}" = "0.0.0.0" ] || [ "${BIND_ON_IP}" = "::0" ]; then
    : "${TEMPORAL_BROADCAST_ADDRESS:=$(getent hosts "$(hostname)" | awk '{print $1;}')}"
else
    : "${TEMPORAL_BROADCAST_ADDRESS:=${BIND_ON_IP}}"
fi
export TEMPORAL_BROADCAST_ADDRESS

echo "Bind IP: $BIND_ON_IP"
echo "Broadcast Address: $TEMPORAL_BROADCAST_ADDRESS"

# --- Validate required environment variables ---
REQUIRED_VARS=(
    TEMPORAL_SQL_HOST
    TEMPORAL_SQL_PORT
    TEMPORAL_SQL_USER
    TEMPORAL_SQL_DATABASE
    TEMPORAL_SQL_PLUGIN_NAME
    TEMPORAL_SQL_MAX_CONNS
    TEMPORAL_SQL_MAX_IDLE_CONNS
    TEMPORAL_SQL_TLS_ENABLED
    TEMPORAL_HISTORY_SHARDS
    TEMPORAL_ELASTICSEARCH_VERSION
    TEMPORAL_ELASTICSEARCH_SCHEME
    TEMPORAL_ELASTICSEARCH_HOST
    TEMPORAL_ELASTICSEARCH_PORT
    TEMPORAL_ELASTICSEARCH_INDEX
)

missing=()
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        missing+=("$var")
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: Missing required environment variables:"
    for var in "${missing[@]}"; do
        echo "  - $var"
    done
    exit 1
fi

# --- Validate template file exists ---
if [ ! -f "$TEMPLATE" ]; then
    echo "ERROR: Persistence template not found: $TEMPLATE"
    exit 1
fi

# --- Render template using Python's string.Template ---
python3 -c "
import os, sys
from string import Template

with open('$TEMPLATE', 'r') as f:
    tmpl = Template(f.read())

result = tmpl.safe_substitute(os.environ)

with open('$OUTPUT', 'w') as f:
    f.write(result)
"

# --- Check for unsubstituted variables ---
unsubstituted=$(grep -oE '\$\{?[A-Z_][A-Z0-9_]*\}?' "$OUTPUT" 2>/dev/null || true)
if [ -n "$unsubstituted" ]; then
    echo "ERROR: Unsubstituted variables found in rendered config:"
    echo "$unsubstituted" | sort -u | while read -r var; do
        echo "  - $var"
    done
    exit 1
fi

echo "Persistence config rendered: $OUTPUT"

# --- Start temporal-server directly with all CLI args ---
exec temporal-server "$@"
