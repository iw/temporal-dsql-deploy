# Deployment Profiles

This directory contains self-contained Docker Compose environments. Each profile runs from its own directory with its own `.env` and config.

## Profiles

| Profile | Purpose | Services | Memory |
|---------|---------|----------|--------|
| [dsql](dsql/) | DSQL plugin development and testing | 9 (Temporal + ES + observability) | ~3.5 GB |

## Quick Reference

```bash
# DSQL profile
cd profiles/dsql
cp .env.example .env        # configure DSQL endpoint
docker compose up -d
```

Profiles share `docker/` (config templates) and `grafana/` (dashboards) from the repository root.

## Docker Desktop Requirements

| Profile | CPUs | Memory | Disk |
|---------|------|--------|------|
| dsql | 4 | 4 GB | default |

Check: Docker Desktop → Settings → Resources.
