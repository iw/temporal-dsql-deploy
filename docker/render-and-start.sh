#!/usr/bin/env bash
set -euo pipefail

TEMPLATE_PATH="${TEMPORAL_PERSISTENCE_TEMPLATE:-/etc/temporal/config/persistence-dsql.template.yaml}"
OUTPUT_PATH="${TEMPORAL_PERSISTENCE_CONFIG:-/etc/temporal/config/persistence-dsql.yaml}"
BASE_ENTRYPOINT="${TEMPORAL_BASE_ENTRYPOINT:-/etc/temporal/entrypoint.sh}"

python3 - <<'PY'
import os
import re
from pathlib import Path
from string import Template

template_path = Path(os.environ.get("TEMPORAL_PERSISTENCE_TEMPLATE", "/etc/temporal/config/persistence-dsql.template.yaml"))
output_path = Path(os.environ.get("TEMPORAL_PERSISTENCE_CONFIG", "/etc/temporal/config/persistence-dsql.yaml"))

if not template_path.exists():
    raise SystemExit(f"Missing persistence template: {template_path}")

# Required environment variables for Temporal DSQL configuration
required_vars = [
    "TEMPORAL_SQL_HOST", "TEMPORAL_SQL_PORT", "TEMPORAL_SQL_DATABASE", 
    "TEMPORAL_SQL_USER", "TEMPORAL_SQL_PLUGIN_NAME",
    "TEMPORAL_SQL_TLS_ENABLED", "TEMPORAL_HISTORY_SHARDS",
    "TEMPORAL_SQL_MAX_CONNS", "TEMPORAL_SQL_MAX_IDLE_CONNS",
    "TEMPORAL_OPENSEARCH_ENDPOINT", "TEMPORAL_SQL_AWS_REGION"
]

# Check for missing required variables
missing_vars = [var for var in required_vars if not os.environ.get(var)]
if missing_vars:
    raise SystemExit(f"Missing required environment variables: {', '.join(missing_vars)}")

# Validate authentication method
iam_auth = os.environ.get("TEMPORAL_SQL_IAM_AUTH", "").lower() == "true"
password_file = os.environ.get("TEMPORAL_SQL_PASSWORD_FILE")

if not iam_auth and not password_file:
    raise SystemExit("Either TEMPORAL_SQL_IAM_AUTH=true or TEMPORAL_SQL_PASSWORD_FILE must be set")

# Validate that password files exist (only if not using IAM auth)
if not iam_auth and password_file and not Path(password_file).exists():
    raise SystemExit(f"SQL password file not found: {password_file}")

opensearch_password_file = os.environ.get("TEMPORAL_OPENSEARCH_PASSWORD_FILE")
# OpenSearch password file validation only if not using IAM (for backwards compatibility)
if opensearch_password_file and not Path(opensearch_password_file).exists():
    print(f"Warning: OpenSearch password file not found: {opensearch_password_file} (using IAM auth)")

content = Template(template_path.read_text())
rendered = content.substitute({k: v for k, v in os.environ.items()})

# Verify no unsubstituted variables remain
unsubstituted = re.findall(r'\$[A-Z_]+', rendered)
if unsubstituted:
    raise SystemExit(f"Template contains unsubstituted variables: {', '.join(set(unsubstituted))}")

output_path.parent.mkdir(parents=True, exist_ok=True)
output_path.write_text(rendered)
print(f"Successfully rendered {template_path} -> {output_path}")
PY

exec "${BASE_ENTRYPOINT}" "$@"
