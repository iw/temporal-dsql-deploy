# DSQL Test Suite

Test scripts for validating Temporal with Aurora DSQL persistence.

## Structure

```
dsql-tests/
├── temporal/       # Temporal feature validation on DSQL
│                   # Exercises upstream Temporal features (schedules, nexus,
│                   # signals/queries) to confirm they work with DSQL persistence.
│
├── plugin/         # DSQL plugin validation
│                   # Exercises the DSQL plugin itself: connection management,
│                   # IAM token refresh, pool behavior, OCC retries.
│
├── copilot/        # Copilot stress & integration tests
│                   # Generates load and failure scenarios on the monitored
│                   # cluster so the SRE Copilot can observe and assess.
│                   # Includes metrics.py for Prometheus metrics export.
│
└── README.md
```

## Usage

All scripts connect to `localhost:7233` by default (the monitored cluster).
Override with `--address` or `TEMPORAL_ADDRESS` env var where supported.

```bash
# Run from repo root with uv
uv run python dsql-tests/temporal/chasm_scheduler_test.py
uv run python dsql-tests/plugin/token_refresh_test.py
uv run python dsql-tests/copilot/stress_workflows.py
```

## Categories

### temporal/ — Temporal Feature Validation

Scripts that exercise Temporal-authored features to confirm DSQL compatibility.
Run these after upgrading the Temporal server or applying schema changes.

| Script | What it tests |
|--------|---------------|
| `chasm_scheduler_test.py` | CHASM (V2) scheduler CRUD and trigger |
| `nexus_test.py` | Nexus endpoint CRUD, UUID pagination |
| `signals_queries_test.py` | Concurrent signals, queries, activities |

### plugin/ — DSQL Plugin Validation

Scripts that exercise the DSQL plugin's connection management, auth, and retry logic.
Run these after changing the plugin or connection configuration.

| Script | What it tests |
|--------|---------------|
| `token_refresh_test.py` | IAM token refresh under continuous load |
| `load_test.py` | 45-min soak test for connection pool stability |
| `hello_activity.py` | Basic smoke test (workflow + activity round-trip) |

### copilot/ — Copilot Stress & Integration

Scripts that generate observable conditions on the monitored cluster
for the SRE Copilot to detect and assess.

| Script | What it generates |
|--------|-------------------|
| `stress_workflows.py` | Sustained WPS load for forward-progress signals |
| `spike_load.py` | Sudden load spikes to trigger Stressed state |
| `error_injection.py` | Failing activities/workflows for error-rate signals |
| `metrics.py` | Shared Prometheus metrics helper (port 9091) for all copilot tests |
