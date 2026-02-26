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
└── README.md
```

## Usage

All scripts connect to `localhost:7233` by default.
Override with `--address` or `TEMPORAL_ADDRESS` env var where supported.

```bash
# Run from repo root with uv
uv run python dsql-tests/temporal/chasm_scheduler_test.py
uv run python dsql-tests/plugin/token_refresh_test.py
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
