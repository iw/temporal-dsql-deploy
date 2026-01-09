"""
5-minute load test to verify IAM token refresh behavior.

This test runs continuous workflows for 5+ minutes to ensure the DSQL
connection properly refreshes when IAM tokens expire (set to 5 min for testing).
"""

import asyncio
import time
import uuid
from datetime import timedelta
from temporalio import activity, workflow
from temporalio.client import Client
from temporalio.worker import Worker


@activity.defn
async def process_item(item_id: str) -> str:
    """Simulate processing an item."""
    await asyncio.sleep(0.05)  # 50ms work
    return f"processed-{item_id}"


@workflow.defn
class TokenRefreshTestWorkflow:
    @workflow.run
    async def run(self, batch_id: str) -> str:
        result = await workflow.execute_activity(
            process_item,
            batch_id,
            start_to_close_timeout=timedelta(seconds=30),
        )
        return result


async def run_single_workflow(client: Client, batch_num: int) -> tuple[bool, float, str]:
    """Run a single workflow, return (success, duration, error_msg)."""
    workflow_id = f"token-test-{uuid.uuid4().hex[:8]}"
    start = time.time()
    try:
        await client.execute_workflow(
            TokenRefreshTestWorkflow.run,
            f"batch-{batch_num}",
            id=workflow_id,
            task_queue="token-refresh-test-queue",
        )
        return True, time.time() - start, ""
    except Exception as e:
        return False, time.time() - start, str(e)


async def main():
    # Configuration
    test_duration_minutes = 6  # Run slightly longer than token expiry (5 min)
    workflows_per_second = 2   # Gentle load
    concurrency = 5
    
    test_duration_seconds = test_duration_minutes * 60
    
    print("=" * 70)
    print("🔐 DSQL IAM TOKEN REFRESH TEST")
    print("=" * 70)
    print(f"Duration:            {test_duration_minutes} minutes")
    print(f"Target rate:         {workflows_per_second} workflows/sec")
    print(f"Concurrency:         {concurrency}")
    print(f"Token expiry:        5 minutes (testing)")
    print("=" * 70)
    print("\n⏱️  Watch for 'IAM token refreshed' in logs around the 5-minute mark\n")
    
    client = await Client.connect("localhost:7233")
    
    # Stats
    total_success = 0
    total_failed = 0
    latencies = []
    errors_by_minute = {}
    
    async with Worker(
        client,
        task_queue="token-refresh-test-queue",
        workflows=[TokenRefreshTestWorkflow],
        activities=[process_item],
        max_concurrent_activities=concurrency * 2,
        max_concurrent_workflow_tasks=concurrency * 2,
    ):
        start_time = time.time()
        batch_num = 0
        semaphore = asyncio.Semaphore(concurrency)
        
        async def bounded_workflow(batch: int):
            async with semaphore:
                return await run_single_workflow(client, batch)
        
        pending_tasks = set()
        
        while True:
            elapsed = time.time() - start_time
            if elapsed >= test_duration_seconds:
                break
            
            current_minute = int(elapsed // 60)
            
            # Start new workflow
            batch_num += 1
            task = asyncio.create_task(bounded_workflow(batch_num))
            pending_tasks.add(task)
            
            # Check completed tasks
            done_tasks = {t for t in pending_tasks if t.done()}
            for task in done_tasks:
                pending_tasks.remove(task)
                try:
                    success, duration, error = task.result()
                    if success:
                        total_success += 1
                        latencies.append(duration)
                    else:
                        total_failed += 1
                        errors_by_minute.setdefault(current_minute, []).append(error)
                except Exception as e:
                    total_failed += 1
                    errors_by_minute.setdefault(current_minute, []).append(str(e))
            
            # Progress update every 30 seconds
            if batch_num % (workflows_per_second * 30) == 0:
                mins = int(elapsed // 60)
                secs = int(elapsed % 60)
                print(f"  [{mins:02d}:{secs:02d}] Workflows: {total_success} ok, {total_failed} failed")
            
            # Rate limiting
            await asyncio.sleep(1.0 / workflows_per_second)
        
        # Wait for remaining tasks
        if pending_tasks:
            print(f"\n  Waiting for {len(pending_tasks)} pending workflows...")
            results = await asyncio.gather(*pending_tasks, return_exceptions=True)
            for r in results:
                if isinstance(r, tuple):
                    success, duration, error = r
                    if success:
                        total_success += 1
                        latencies.append(duration)
                    else:
                        total_failed += 1
    
    # Results
    total_time = time.time() - start_time
    
    print("\n" + "=" * 70)
    print("📊 TEST RESULTS")
    print("=" * 70)
    print(f"Total duration:      {total_time / 60:.1f} minutes")
    print(f"Workflows started:   {batch_num}")
    print(f"Successful:          {total_success}")
    print(f"Failed:              {total_failed}")
    print(f"Success rate:        {100 * total_success / max(1, total_success + total_failed):.1f}%")
    
    if latencies:
        print(f"\nLatency:")
        print(f"  Min:               {min(latencies):.3f}s")
        print(f"  Max:               {max(latencies):.3f}s")
        print(f"  Avg:               {sum(latencies) / len(latencies):.3f}s")
    
    if errors_by_minute:
        print(f"\n❌ Errors by minute:")
        for minute, errs in sorted(errors_by_minute.items()):
            print(f"  Minute {minute}: {len(errs)} errors")
            if minute >= 4:  # Around token expiry time
                print(f"    Sample: {errs[0][:80]}...")
    
    # Token refresh verdict
    print("\n" + "=" * 70)
    if total_failed == 0:
        print("✅ TOKEN REFRESH TEST PASSED - No failures during token expiry window!")
    elif errors_by_minute.get(5, []) or errors_by_minute.get(4, []):
        print("⚠️  FAILURES AROUND TOKEN EXPIRY - Check if refresh is working")
    else:
        print("⚠️  Some failures occurred - review errors above")
    print("=" * 70)
    print("\n💡 Check logs: docker compose logs --since=7m | grep -i 'token refreshed'")


if __name__ == "__main__":
    asyncio.run(main())
