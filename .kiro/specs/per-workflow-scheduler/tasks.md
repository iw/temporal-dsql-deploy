# Tasks: Per-Workflow Scheduler Validation on DSQL

## Task 1: Prometheus Metrics Scraper
- [ ] Implement `scrape_metrics(endpoint)` that fetches `/metrics` from a Temporal history service endpoint
- [ ] Parse Prometheus text exposition format to extract counter values and histogram quantiles
- [ ] Handle multi-replica scraping: accept a list of endpoints, sum counter deltas across replicas
- [ ] Extract the specific metrics: `dsql_tx_conflict_total`, `dsql_tx_retry_total`, `dsql_tx_exhausted_total`, `task_requests`, `task_errors`, `task_latency_queue`, and EQS-specific counters

## Task 2: Contention Workload
- [ ] Implement `ContentionWorkflow` — a single workflow that fans out N parallel activities
- [ ] Implement `contention_activity` — minimal work (50-100ms sleep) to maximise scheduling contention
- [ ] Implement `run_contention_workload(client, activity_count)` that starts the workflow, runs a worker, and waits for completion
- [ ] Measure end-to-end workflow completion time and collect per-activity latency from workflow result
- [ ] Use a unique task queue per run to avoid cross-contamination

## Task 3: Dynamic Config Toggle
- [ ] Implement `toggle_scheduler(config_path, enabled)` that reads the YAML, adds/removes the scheduler config block, and writes it back
- [ ] Preserve all existing config entries — only modify the four `taskSchedulerExecutionQueueScheduler*` keys
- [ ] Implement `restore_config(config_path, original_content)` for cleanup
- [ ] Wait for config reload after toggle (configurable, default 15s)

## Task 4: Test Orchestration
- [ ] Implement the two-phase test flow: disabled run → toggle → enabled run
- [ ] Scrape metrics before and after each run to compute deltas
- [ ] Handle `--skip-disabled` flag for quick single-run validation
- [ ] Implement CLI argument parsing (argparse): `--activities`, `--metrics-endpoint`, `--dynamic-config`, `--config-reload-wait`, `--skip-disabled`
- [ ] Ensure cleanup (config restore) runs even on test failure

## Task 5: Comparison Report
- [ ] Implement `print_comparison_report(disabled_results, enabled_results)` with side-by-side formatting
- [ ] Calculate percentage change for each metric
- [ ] Include: workflow completion time, activity latency percentiles, OCC metrics, task metrics, EQS metrics
- [ ] Handle the case where disabled run is skipped (show enabled-only results)

## Task 6: Multi-Workflow Stretch Test
- [ ] Implement `MultiContentionWorkflow` — 10 concurrent workflows × 50 activities each
- [ ] Add `--multi-workflow` flag to run this variant instead of the single-workflow test
- [ ] Verify `MaxQueues` limit behaviour: with 10 workflows, expect up to 10 active EQS queues

## Task 7: Documentation and Integration
- [ ] Add the test to `dsql-tests/README.md` with description and usage
- [ ] Add the scheduler dynamic config block (commented out) to `profiles/dsql/dynamicconfig/development-dsql.yaml` with explanatory comments
- [ ] Update `AGENTS.md` to reference the per-workflow scheduler test and its dynamic config requirements
