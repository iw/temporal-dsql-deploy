"""Mini load test for Temporal with Aurora DSQL persistence - concurrent workflow invocations."""

import asyncio
import time
import uuid
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


async def main():
    # Configuration
    num_workflows = 50
    concurrency = 10  # Number of concurrent workflows at a time
    
    print(f"🚀 Starting load test: {num_workflows} workflows, {concurrency} concurrent")
    print("=" * 60)
    
    # Connect to Temporal server
    client = await Client.connect("localhost:7233")
    
    # Track results
    results = []
    errors = []
    
    # Run worker with multiple concurrent activity executors
    async with Worker(
        client,
        task_queue="load-test-queue",
        workflows=[GreetingWorkflow],
        activities=[say_hello],
        max_concurrent_activities=concurrency * 2,
        max_concurrent_workflow_tasks=concurrency * 2,
    ):
        start_time = time.time()
        
        # Create all workflow tasks
        tasks = []
        for i in range(num_workflows):
            workflow_id = f"load-test-{uuid.uuid4().hex[:8]}-{i}"
            task = run_workflow(client, workflow_id, f"User-{i}")
            tasks.append(task)
        
        # Run with limited concurrency using semaphore
        semaphore = asyncio.Semaphore(concurrency)
        
        async def bounded_run(task):
            async with semaphore:
                return await task
        
        # Execute all workflows
        bounded_tasks = [bounded_run(t) for t in tasks]
        completed = await asyncio.gather(*bounded_tasks, return_exceptions=True)
        
        total_time = time.time() - start_time
        
        # Process results
        for i, result in enumerate(completed):
            if isinstance(result, Exception):
                errors.append((i, str(result)))
            else:
                results.append(result)
    
    # Print summary
    print("\n" + "=" * 60)
    print("📊 LOAD TEST RESULTS")
    print("=" * 60)
    print(f"Total workflows:     {num_workflows}")
    print(f"Successful:          {len(results)}")
    print(f"Failed:              {len(errors)}")
    print(f"Total time:          {total_time:.2f}s")
    print(f"Throughput:          {num_workflows / total_time:.2f} workflows/sec")
    
    if results:
        durations = [r[1] for r in results]
        print(f"\nLatency (per workflow):")
        print(f"  Min:               {min(durations):.3f}s")
        print(f"  Max:               {max(durations):.3f}s")
        print(f"  Avg:               {sum(durations) / len(durations):.3f}s")
    
    if errors:
        print(f"\n❌ Errors ({len(errors)}):")
        for i, err in errors[:5]:  # Show first 5 errors
            print(f"  Workflow {i}: {err[:100]}")
        if len(errors) > 5:
            print(f"  ... and {len(errors) - 5} more")
    
    print("\n✅ Load test complete!")


if __name__ == "__main__":
    asyncio.run(main())
