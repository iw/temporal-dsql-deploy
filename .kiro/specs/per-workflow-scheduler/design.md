# Design: Per-Workflow Scheduler Validation on DSQL

## Overview

A Python test script that exercises the `ExecutionQueueScheduler` on a DSQL-backed Temporal cluster, running contention-heavy workloads with the scheduler enabled and disabled, scraping server metrics, and producing a comparison report.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    Test Script                           │
│  per_workflow_scheduler_test.py                          │
│                                                          │
│  1. Scrape baseline metrics from history :9090           │
│  2. Run contention workload (scheduler OFF)              │
│  3. Scrape post-run metrics, compute deltas              │
│  4. Toggle dynamic config (scheduler ON)                 │
│  5. Wait for config reload                               │
│  6. Scrape baseline metrics                              │
│  7. Run same contention workload                         │
│  8. Scrape post-run metrics, compute deltas              │
│  9. Print comparison report                              │
└──────────┬───────────────────────────┬───────────────────┘
           │                           │
           ▼                           ▼
    Temporal Client              HTTP GET :9090/metrics
    (localhost:7233)             (history service prometheus)
```

## Contention Workload

### Primary Test: Single Hot Workflow

A single workflow starts N parallel activities (default: 500). All activities target the same workflow execution, creating maximum lock contention on the history shard owning that execution.

```python
@workflow.defn
class ContentionWorkflow:
    @workflow.run
    async def run(self, activity_count: int) -> dict:
        # Fan out N activities in parallel
        tasks = [
            workflow.execute_activity(
                contention_activity,
                i,
                start_to_close_timeout=timedelta(seconds=60),
            )
            for i in range(activity_count)
        ]
        results = await asyncio.gather(*tasks)
        return {"completed": len(results)}
```

Each activity does minimal work (sleep 50-100ms) — the goal is contention, not throughput.

### Stretch Test: Multi-Workflow Contention

10 workflows each with 50 parallel activities, running concurrently. Tests the `MaxQueues` limit and FIFO fallback behaviour.

## Metrics Collection

### Prometheus Scraping

The test scrapes metrics directly from the history service's Prometheus endpoint. In the Docker Compose stack, history exposes `:9090/metrics`.

```python
async def scrape_metrics(endpoint: str) -> dict[str, float]:
    """Scrape Prometheus text format and extract relevant counters/histograms."""
    async with httpx.AsyncClient() as client:
        resp = await client.get(f"{endpoint}/metrics")
    return parse_prometheus_text(resp.text)
```

### Metrics of Interest

| Metric | Type | Source | Why |
|--------|------|--------|-----|
| `dsql_tx_conflict_total` | Counter | DSQL plugin | OCC serialisation conflicts |
| `dsql_tx_retry_total` | Counter | DSQL plugin | OCC retry attempts |
| `dsql_tx_exhausted_total` | Counter | DSQL plugin | Retries exhausted (terminal failures) |
| `task_requests` | Counter | History service | Total task processing attempts |
| `task_errors` | Counter | History service | Task processing failures |
| `task_latency_queue` | Histogram | History service | Per-task processing latency |
| `execution_queue_scheduler_tasks_submitted` | Counter | EQS | Tasks routed to per-workflow queues |
| `execution_queue_scheduler_tasks_completed` | Counter | EQS | Tasks completed via per-workflow queues |
| `execution_queue_scheduler_queues_active` | Gauge | EQS | Active per-workflow queues |

Delta = post-run value - pre-run value for counters.

### Metric Endpoint Discovery

The Docker Compose stack exposes history on a mapped port. The test accepts `--metrics-endpoint` (default: `http://localhost:9090`) to handle different port mappings. If multiple history replicas exist, the test scrapes all and sums the deltas.

## Dynamic Config Toggle

The dynamic config file is mounted into the Temporal containers. The test:

1. Reads the current `development-dsql.yaml`
2. For the "disabled" run: ensures `history.taskSchedulerEnableExecutionQueueScheduler` is absent or `false`
3. For the "enabled" run: appends the scheduler config block
4. Temporal reloads dynamic config on a polling interval (default 10s) — the test waits 15s after modification
5. After both runs: restores the original config file

```yaml
# Appended for enabled run
history.taskSchedulerEnableExecutionQueueScheduler:
  - value: true
    constraints: {}

history.taskSchedulerExecutionQueueSchedulerMaxQueues:
  - value: 500
    constraints: {}

history.taskSchedulerExecutionQueueSchedulerQueueConcurrency:
  - value: 2
    constraints: {}
```

## Comparison Report

```
══════════════════════════════════════════════════════════════
  PER-WORKFLOW SCHEDULER — DSQL CONTENTION COMPARISON
══════════════════════════════════════════════════════════════

  Workload: 1 workflow × 500 parallel activities

                              DISABLED    ENABLED    CHANGE
  ─────────────────────────────────────────────────────────
  Workflow completion (s)       12.4        5.1      -59%
  Activity latency p50 (ms)     180         95      -47%
  Activity latency p95 (ms)     890        210      -76%
  Activity latency p99 (ms)    2100        340      -84%

  OCC conflicts                 842        127      -85%
  OCC retries                  1204        183      -85%
  OCC exhausted                  14          0     -100%

  Task requests                3200       1100      -66%
  Task errors                   680         12      -98%

  EQS tasks submitted             —        488        —
  EQS queues active               —          1        —
══════════════════════════════════════════════════════════════
```

(Values are illustrative — actual numbers will vary.)

## CLI Interface

```bash
uv run python dsql-tests/temporal/per_workflow_scheduler_test.py \
    --activities 500 \
    --metrics-endpoint http://localhost:9090 \
    --dynamic-config profiles/dsql/dynamicconfig/development-dsql.yaml \
    --config-reload-wait 15
```

All arguments have sensible defaults. The test can also be run with `--skip-disabled` to only run the enabled case (useful for quick validation after enabling the scheduler).

## File Structure

```
dsql-tests/temporal/
└── per_workflow_scheduler_test.py    # Single self-contained test script
```

## Dependencies

- `temporalio` — Temporal Python SDK (already in project)
- `httpx` — HTTP client for Prometheus scraping (already in project)
- Standard library `re` for Prometheus text format parsing

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Dynamic config reload timing is non-deterministic | Wait 15s (1.5× the default 10s poll interval), verify via metrics endpoint that EQS counters appear |
| Multiple history replicas make metric aggregation complex | Sum deltas across all replica endpoints; accept that some tasks may land on different replicas |
| Activity count too high for local dev cluster | Default to 500 (not 2000 as in upstream benchmark); make configurable via `--activities` |
| Config file modification during test could affect other tests | Save and restore original config; use unique task queue and namespace |
