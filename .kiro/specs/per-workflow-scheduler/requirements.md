# Requirements: Per-Workflow Scheduler Validation on DSQL

## Context

Temporal upstream merged a per-workflow `ExecutionQueueScheduler` (#9141) that serialises history task processing for contended workflow executions. When lock contention is detected on a workflow, tasks are routed from the shared FIFO scheduler to a dedicated per-workflow queue, eliminating retry storms caused by concurrent lock acquisition.

This feature is behind four dynamic config keys (all disabled by default):

| Key | Default | Purpose |
|-----|---------|---------|
| `history.taskSchedulerEnableExecutionQueueScheduler` | `false` | Master switch |
| `history.taskSchedulerExecutionQueueSchedulerMaxQueues` | `500` | Max concurrent per-workflow queues before fallback to FIFO |
| `history.taskSchedulerExecutionQueueSchedulerQueueTTL` | `5s` | Idle timeout before a per-workflow queue goroutine exits |
| `history.taskSchedulerExecutionQueueSchedulerQueueConcurrency` | `2` | Worker goroutines per workflow queue |

Upstream benchmarks (non-DSQL) showed 97x fewer task failures and 5.5x better p99 latency on a single workflow with 2,000 parallel activities. We need to validate this on DSQL where OCC conflicts add a second contention dimension.

## Goal

Validate that the per-workflow `ExecutionQueueScheduler` works correctly with Aurora DSQL persistence and quantify its impact on OCC conflict rates, task failure rates, and end-to-end latency under contention.

## Requirements

### REQ-1: Functional Correctness
The system shall execute a single workflow with a high number of parallel activities (500+) to completion with zero workflow failures when the `ExecutionQueueScheduler` is enabled, using DSQL as the persistence backend.

### REQ-2: Baseline Comparison
The test shall run in two modes — scheduler enabled and scheduler disabled — against the same DSQL cluster, collecting identical metrics in both runs, to produce a direct before/after comparison.

### REQ-3: OCC Conflict Measurement
The test shall collect DSQL OCC conflict metrics (`dsql_tx_conflict_total`, `dsql_tx_retry_total`, `dsql_tx_exhausted_total`) from the Temporal server's Prometheus endpoint during each run and report the delta.

### REQ-4: Task Failure Measurement
The test shall collect history task failure and retry metrics (`task_requests`, `task_errors`, `task_latency_queue`) from the Temporal server's Prometheus endpoint during each run and report the delta.

### REQ-5: Latency Measurement
The test shall measure end-to-end workflow completion latency (time from `StartWorkflowExecution` to workflow completion) and per-activity latency (schedule-to-close) for each run.

### REQ-6: Dynamic Config Toggle
The test shall programmatically toggle the `ExecutionQueueScheduler` dynamic config between runs without requiring a service restart, using the dynamic config file reload mechanism.

### REQ-7: Metrics Scraping
The test shall scrape Prometheus metrics directly from the Temporal history service endpoint(s) before and after each run to compute deltas, rather than depending on an external metrics pipeline.

### REQ-8: Results Report
The test shall produce a structured comparison report (printed to stdout) showing side-by-side metrics for both runs, including: workflow completion time, activity latency percentiles (p50/p95/p99), OCC conflicts, OCC retries, OCC exhausted, task failures, and task retries.

### REQ-9: Multi-Workflow Contention (Stretch)
As a stretch goal, the test should also validate behaviour under multi-workflow contention — multiple workflows each with moderate parallelism (50-100 activities) running concurrently — to confirm the scheduler's `MaxQueues` limit and FIFO fallback work correctly on DSQL.

### REQ-10: Test Location
The test shall be placed in `dsql-tests/temporal/per_workflow_scheduler_test.py` following the existing test conventions (standalone script, connects to `localhost:7233`, uses `temporalio` Python SDK).
