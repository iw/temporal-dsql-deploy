# Deployment Profiles

This directory contains self-contained Docker Compose environments for different use cases. Each profile runs from its own directory with its own `.env` and config.

## Profiles

| Profile | Purpose | Services | Memory |
|---------|---------|----------|--------|
| [dsql](dsql/) | DSQL plugin development and testing | 9 (Temporal + ES + observability) | ~3.5 GB |
| [copilot](copilot/) | SRE Copilot development with a monitored Temporal cluster | 15 (above + Loki + Copilot cluster) | ~5 GB |

## Quick Reference

```bash
# DSQL profile
cd profiles/dsql
cp .env.example .env        # configure DSQL endpoint
docker compose up -d

# Copilot profile
cd profiles/copilot
cp .env.example .env        # configure both DSQL endpoints + Bedrock KB
docker compose up -d
```

Both profiles share `docker/` (config templates), `grafana/` (dashboards), and `scripts/` from the repository root.

## Docker Desktop Requirements

| Profile | CPUs | Memory | Disk |
|---------|------|--------|------|
| dsql | 4 | 4 GB | default |
| copilot | 4 (6 recommended) | 6 GB (8 recommended) | default |

Check: Docker Desktop → Settings → Resources.
