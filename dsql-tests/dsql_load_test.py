"""Extended load test for Temporal with Aurora DSQL persistence.

This test runs for 45 minutes to validate connection refresher behavior.
With DSQL_CONN_REFRESH_INTERVAL=8m, we expect to see ~5 refresh cycles.

Key things to observe during the test:
- Connection pool stability (dsql_pool_open should stay at max)
- Refresh cycles in logs ("DSQL connection refresh triggered")
- No workflow failures during refresh windows
- dsql_db_closed_max_idle_time_total should stay at 0
"""

import asyncio
import time
import uuid
import argparse
from datetime import timedelta
from temporalio import activity, workflow
from temporalio.client import Client
from temporalio.worker import Worker


@activity.defn
async def say_hello(name: str) -> str:
    # Simulate some work
    await asyncio.sleep(0.1)
    return f"Hello, {name}!"


@workflow.defn
class GreetingWorkflow:
    @workflow.run
    async def run(self, name: str) -> str:
        return await workflow.execute_activity(
            say_hello,
            name,
            start_to_close_timeout=timedelta(seconds=30),
        )


async def run_workflow(client: Client, workflow_id: str, name: str) -> tuple[str, float]:
    """Run a single workflow and return result with duration."""
    start = time.time()
    result = await client.execute_workflow(
        GreetingWorkflow.run,
        name,
        id=workflow_id,
        task_queue="load-test-queue",
    )
    duration = time.time() - start
    return result, duration


def format_duration(seconds: float) -> str:
    """Format seconds as HH:MM:SS."""
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}"


async def main():
    parser = argparse.ArgumentParser(description="Extended load test for DSQL connection refresher")
    parser.add_argument("--duration", type=int, default=45, help="Test duration in minutes (default: 45)")
    parser.add_argument("--rate", type=float, default=2.0, help="Workflows per second (default: 2.0)")
    parser.add_argument("--concurrency", type=int, default=10, help="Max concurrent workflows (default: 10)")
    parser.add_argument("--report-interval", type=int, default=60, help="Progress report interval in seconds (default: 60)")
    args = parser.parse_args()

    # Configuration
    test_duration_minutes = args.duration
    test_duration_seconds = test_duration_minutes * 60
    workflows_per_second = args.rate
    concurrency = args.concurrency
    report_interval = args.report_interval
    
    print("=" * 70)
    print("🚀 DSQL CONNECTION REFRESHER LOAD TEST")
    print("=" * 70)
    print(f"Duration:            {test_duration_minutes} minutes")
    print(f"Target rate:         {workflows_per_second} workflows/sec")
    print(f"Concurrency:         {concurrency}")
    print(f"Report interval:     {report_interval}s")
    print()
    print("Expected refresh cycles (with 8m interval): ~" + str(test_duration_minutes // 8))
    print("Watch for: 'DSQL connection refresh triggered' in service logs")
    print("=" * 70)
    
    # Connect to Temporal server
    client = await Client.connect("localhost:7233")
    
    # Track results
    total_success = 0
    total_errors = 0
    interval_success = 0
    interval_errors = 0
    interval_durations = []
    all_durations = []
    error_samples = []
    
    # Semaphore for concurrency control
    semaphore = asyncio.Semaphore(concurrency)
    
    async def run_bounded_workflow(workflow_num: int) -> tuple[bool, float, str | None]:
        """Run a workflow with concurrency limiting."""
        async with semaphore:
            workflow_id = f"load-{uuid.uuid4().hex[:8]}-{workflow_num}"
            try:
                start = time.time()
                await client.execute_workflow(
                    GreetingWorkflow.run,
                    f"User-{workflow_num}",
                    id=workflow_id,
                    task_queue="load-test-queue",
                )
                duration = time.time() - start
                return True, duration, None
            except Exception as e:
                return False, 0.0, str(e)[:200]
    
    # Run worker
    async with Worker(
        client,
        task_queue="load-test-queue",
        workflows=[GreetingWorkflow],
        activities=[say_hello],
        max_concurrent_activities=concurrency * 2,
        max_concurrent_workflow_tasks=concurrency * 2,
    ):
        test_start = time.time()
        last_report = test_start
        workflow_num = 0
        pending_tasks = set()
        
        # Calculate delay between workflow starts
        delay_between_workflows = 1.0 / workflows_per_second
        
        print(f"\n⏱️  Test started at {time.strftime('%H:%M:%S')}")
        print("-" * 70)
        
        while True:
            current_time = time.time()
            elapsed = current_time - test_start
            
            # Check if test duration reached
            if elapsed >= test_duration_seconds:
                break
            
            # Start a new workflow
            workflow_num += 1
            task = asyncio.create_task(run_bounded_workflow(workflow_num))
            pending_tasks.add(task)
            
            # Process completed tasks
            done_tasks = {t for t in pending_tasks if t.done()}
            for task in done_tasks:
                pending_tasks.remove(task)
                try:
                    success, duration, error = task.result()
                    if success:
                        total_success += 1
                        interval_success += 1
                        interval_durations.append(duration)
                        all_durations.append(duration)
                    else:
                        total_errors += 1
                        interval_errors += 1
                        if len(error_samples) < 10:
                            error_samples.append(error)
                except Exception as e:
                    total_errors += 1
                    interval_errors += 1
                    if len(error_samples) < 10:
                        error_samples.append(str(e)[:200])
            
            # Print progress report
            if current_time - last_report >= report_interval:
                elapsed_str = format_duration(elapsed)
                remaining = test_duration_seconds - elapsed
                remaining_str = format_duration(remaining)
                
                # Calculate interval stats
                interval_rate = interval_success / report_interval if report_interval > 0 else 0
                avg_latency = sum(interval_durations) / len(interval_durations) if interval_durations else 0
                max_latency = max(interval_durations) if interval_durations else 0
                
                print(f"[{elapsed_str}] ✅ {interval_success:4d} ok | ❌ {interval_errors:2d} err | "
                      f"⚡ {interval_rate:.1f}/s | 📊 avg={avg_latency:.2f}s max={max_latency:.2f}s | "
                      f"⏳ {remaining_str} left")
                
                # Reset interval counters
                interval_success = 0
                interval_errors = 0
                interval_durations = []
                last_report = current_time
            
            # Rate limiting - wait before starting next workflow
            await asyncio.sleep(delay_between_workflows)
        
        # Wait for remaining workflows to complete
        print("\n⏳ Waiting for remaining workflows to complete...")
        if pending_tasks:
            results = await asyncio.gather(*pending_tasks, return_exceptions=True)
            for result in results:
                if isinstance(result, Exception):
                    total_errors += 1
                else:
                    success, duration, error = result
                    if success:
                        total_success += 1
                        all_durations.append(duration)
                    else:
                        total_errors += 1
        
        total_time = time.time() - test_start
    
    # Print final summary
    print("\n" + "=" * 70)
    print("📊 FINAL LOAD TEST RESULTS")
    print("=" * 70)
    print(f"Test duration:       {format_duration(total_time)} ({total_time:.1f}s)")
    print(f"Total workflows:     {total_success + total_errors}")
    print(f"Successful:          {total_success}")
    print(f"Failed:              {total_errors}")
    print(f"Success rate:        {100 * total_success / (total_success + total_errors):.2f}%")
    print(f"Actual throughput:   {(total_success + total_errors) / total_time:.2f} workflows/sec")
    
    if all_durations:
        sorted_durations = sorted(all_durations)
        p50_idx = int(len(sorted_durations) * 0.50)
        p95_idx = int(len(sorted_durations) * 0.95)
        p99_idx = int(len(sorted_durations) * 0.99)
        
        print(f"\nLatency percentiles:")
        print(f"  P50:               {sorted_durations[p50_idx]:.3f}s")
        print(f"  P95:               {sorted_durations[p95_idx]:.3f}s")
        print(f"  P99:               {sorted_durations[p99_idx]:.3f}s")
        print(f"  Max:               {max(all_durations):.3f}s")
        print(f"  Avg:               {sum(all_durations) / len(all_durations):.3f}s")
    
    if error_samples:
        print(f"\n❌ Error samples ({len(error_samples)} shown, {total_errors} total):")
        for i, err in enumerate(error_samples[:5]):
            print(f"  {i+1}. {err[:100]}")
    
    print("\n" + "=" * 70)
    if total_errors == 0:
        print("✅ LOAD TEST PASSED - No errors during connection refresh cycles!")
    else:
        print(f"⚠️  LOAD TEST COMPLETED WITH {total_errors} ERRORS")
    print("=" * 70)


if __name__ == "__main__":
    asyncio.run(main())
