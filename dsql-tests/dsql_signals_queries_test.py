"""
Concurrent test for Temporal with Aurora DSQL persistence.
Exercises signals, queries, and activities under load.
"""

import asyncio
import random
import time
import uuid
from dataclasses import dataclass
from datetime import timedelta
from temporalio import activity, workflow
from temporalio.client import Client, WorkflowHandle
from temporalio.worker import Worker


@dataclass
class OrderItem:
    name: str
    quantity: int
    price: float


@activity.defn
async def process_payment(order_id: str, amount: float) -> str:
    """Simulate payment processing."""
    await asyncio.sleep(random.uniform(0.05, 0.15))
    return f"Payment of ${amount:.2f} processed for order {order_id}"


@activity.defn
async def ship_order(order_id: str, items: list[str]) -> str:
    """Simulate order shipping."""
    await asyncio.sleep(random.uniform(0.05, 0.15))
    return f"Order {order_id} shipped with {len(items)} items"


@activity.defn
async def send_notification(order_id: str, message: str) -> str:
    """Simulate sending notification."""
    await asyncio.sleep(random.uniform(0.02, 0.08))
    return f"Notification sent for {order_id}: {message}"


@workflow.defn
class OrderWorkflow:
    """
    Order processing workflow that demonstrates:
    - Signals: add items, cancel order
    - Queries: get status, get items
    - Activities: payment, shipping, notifications
    """

    def __init__(self):
        self.items: list[OrderItem] = []
        self.status = "pending"
        self.total = 0.0
        self.cancelled = False
        self.completed = False
        self.messages: list[str] = []

    @workflow.run
    async def run(self, order_id: str) -> dict:
        # Wait for items to be added or cancellation
        await workflow.wait_condition(
            lambda: len(self.items) > 0 or self.cancelled,
            timeout=timedelta(seconds=30),
        )

        if self.cancelled:
            self.status = "cancelled"
            return {"order_id": order_id, "status": self.status, "items": 0}

        # Calculate total
        self.total = sum(item.price * item.quantity for item in self.items)
        self.status = "processing"

        # Process payment
        payment_result = await workflow.execute_activity(
            process_payment,
            args=[order_id, self.total],
            start_to_close_timeout=timedelta(seconds=30),
        )
        self.messages.append(payment_result)
        self.status = "paid"

        # Ship order
        item_names = [item.name for item in self.items]
        ship_result = await workflow.execute_activity(
            ship_order,
            args=[order_id, item_names],
            start_to_close_timeout=timedelta(seconds=30),
        )
        self.messages.append(ship_result)
        self.status = "shipped"

        # Send notification
        notify_result = await workflow.execute_activity(
            send_notification,
            args=[order_id, f"Your order with {len(self.items)} items has been shipped!"],
            start_to_close_timeout=timedelta(seconds=30),
        )
        self.messages.append(notify_result)

        self.status = "completed"
        self.completed = True

        return {
            "order_id": order_id,
            "status": self.status,
            "items": len(self.items),
            "total": self.total,
        }

    @workflow.signal
    async def add_item(self, name: str, quantity: int, price: float):
        """Signal to add an item to the order."""
        self.items.append(OrderItem(name=name, quantity=quantity, price=price))

    @workflow.signal
    async def cancel_order(self):
        """Signal to cancel the order."""
        if self.status == "pending":
            self.cancelled = True

    @workflow.query
    def get_status(self) -> str:
        """Query current order status."""
        return self.status

    @workflow.query
    def get_items(self) -> list[dict]:
        """Query current items in order."""
        return [{"name": i.name, "quantity": i.quantity, "price": i.price} for i in self.items]

    @workflow.query
    def get_total(self) -> float:
        """Query current order total."""
        return self.total


async def run_order_workflow(
    client: Client, 
    workflow_num: int,
    num_items: int,
    num_queries: int,
) -> dict:
    """Run a single order workflow with signals and queries."""
    order_id = f"order-{uuid.uuid4().hex[:8]}"
    start_time = time.time()
    
    # Start workflow
    handle: WorkflowHandle = await client.start_workflow(
        OrderWorkflow.run,
        order_id,
        id=f"order-workflow-{workflow_num}-{order_id}",
        task_queue="orders-queue",
    )
    
    # Send signals to add items
    for i in range(num_items):
        await handle.signal(
            OrderWorkflow.add_item,
            args=[f"Item-{i}", random.randint(1, 5), round(random.uniform(10, 100), 2)],
        )
    
    # Query status multiple times during execution
    query_results = []
    for _ in range(num_queries):
        status = await handle.query(OrderWorkflow.get_status)
        query_results.append(status)
        await asyncio.sleep(0.05)
    
    # Wait for completion
    result = await handle.result()
    
    # Final queries
    final_status = await handle.query(OrderWorkflow.get_status)
    final_items = await handle.query(OrderWorkflow.get_items)
    final_total = await handle.query(OrderWorkflow.get_total)
    
    duration = time.time() - start_time
    
    return {
        "workflow_num": workflow_num,
        "order_id": order_id,
        "duration": duration,
        "result": result,
        "query_count": len(query_results) + 3,
        "signal_count": num_items,
        "final_status": final_status,
        "item_count": len(final_items),
        "total": final_total,
    }


async def run_cancelled_workflow(client: Client, workflow_num: int) -> dict:
    """Run a workflow that gets cancelled via signal."""
    order_id = f"cancelled-{uuid.uuid4().hex[:8]}"
    start_time = time.time()
    
    handle = await client.start_workflow(
        OrderWorkflow.run,
        order_id,
        id=f"cancel-workflow-{workflow_num}-{order_id}",
        task_queue="orders-queue",
    )
    
    # Query initial status
    initial_status = await handle.query(OrderWorkflow.get_status)
    
    # Cancel the order
    await handle.signal(OrderWorkflow.cancel_order)
    
    # Wait for completion
    result = await handle.result()
    
    duration = time.time() - start_time
    
    return {
        "workflow_num": workflow_num,
        "order_id": order_id,
        "duration": duration,
        "result": result,
        "cancelled": True,
        "initial_status": initial_status,
    }


async def main():
    # Configuration
    num_order_workflows = 30
    num_cancel_workflows = 10
    items_per_order = 3
    queries_per_workflow = 5
    concurrency = 10
    
    total_workflows = num_order_workflows + num_cancel_workflows
    
    print("=" * 70)
    print("🚀 DSQL SIGNALS & QUERIES LOAD TEST")
    print("=" * 70)
    print(f"Order workflows:      {num_order_workflows}")
    print(f"Cancel workflows:     {num_cancel_workflows}")
    print(f"Items per order:      {items_per_order}")
    print(f"Queries per workflow: {queries_per_workflow}")
    print(f"Concurrency:          {concurrency}")
    print("=" * 70)
    
    client = await Client.connect("localhost:7233")
    
    results = []
    errors = []
    
    async with Worker(
        client,
        task_queue="orders-queue",
        workflows=[OrderWorkflow],
        activities=[process_payment, ship_order, send_notification],
        max_concurrent_activities=concurrency * 3,
        max_concurrent_workflow_tasks=concurrency * 2,
    ):
        start_time = time.time()
        
        # Create tasks
        tasks = []
        
        # Order workflows
        for i in range(num_order_workflows):
            tasks.append(run_order_workflow(client, i, items_per_order, queries_per_workflow))
        
        # Cancel workflows
        for i in range(num_cancel_workflows):
            tasks.append(run_cancelled_workflow(client, i))
        
        # Run with bounded concurrency
        semaphore = asyncio.Semaphore(concurrency)
        
        async def bounded_run(task):
            async with semaphore:
                return await task
        
        completed = await asyncio.gather(
            *[bounded_run(t) for t in tasks],
            return_exceptions=True,
        )
        
        total_time = time.time() - start_time
        
        for result in completed:
            if isinstance(result, Exception):
                errors.append(str(result))
            else:
                results.append(result)
    
    # Analyze results
    order_results = [r for r in results if not r.get("cancelled")]
    cancel_results = [r for r in results if r.get("cancelled")]
    
    total_signals = sum(r.get("signal_count", 1) for r in results)
    total_queries = sum(r.get("query_count", 2) for r in results)
    
    print("\n" + "=" * 70)
    print("📊 LOAD TEST RESULTS")
    print("=" * 70)
    
    print(f"\n📦 WORKFLOWS")
    print(f"  Total:              {total_workflows}")
    print(f"  Successful:         {len(results)}")
    print(f"  Failed:             {len(errors)}")
    print(f"  Order completed:    {len(order_results)}")
    print(f"  Cancelled:          {len(cancel_results)}")
    
    print(f"\n📡 SIGNALS & QUERIES")
    print(f"  Total signals:      {total_signals}")
    print(f"  Total queries:      {total_queries}")
    print(f"  Signals/sec:        {total_signals / total_time:.2f}")
    print(f"  Queries/sec:        {total_queries / total_time:.2f}")
    
    print(f"\n⏱️  PERFORMANCE")
    print(f"  Total time:         {total_time:.2f}s")
    print(f"  Throughput:         {len(results) / total_time:.2f} workflows/sec")
    
    if order_results:
        durations = [r["duration"] for r in order_results]
        print(f"\n  Order workflow latency:")
        print(f"    Min:              {min(durations):.3f}s")
        print(f"    Max:              {max(durations):.3f}s")
        print(f"    Avg:              {sum(durations) / len(durations):.3f}s")
    
    if cancel_results:
        durations = [r["duration"] for r in cancel_results]
        print(f"\n  Cancel workflow latency:")
        print(f"    Min:              {min(durations):.3f}s")
        print(f"    Max:              {max(durations):.3f}s")
        print(f"    Avg:              {sum(durations) / len(durations):.3f}s")
    
    if errors:
        print(f"\n❌ ERRORS ({len(errors)}):")
        for err in errors[:5]:
            print(f"  {err[:100]}")
        if len(errors) > 5:
            print(f"  ... and {len(errors) - 5} more")
    
    # Verify results
    print("\n" + "=" * 70)
    print("✅ VERIFICATION")
    print("=" * 70)
    
    all_completed = all(r["result"]["status"] == "completed" for r in order_results)
    all_cancelled = all(r["result"]["status"] == "cancelled" for r in cancel_results)
    
    print(f"  All orders completed:  {'✅' if all_completed else '❌'}")
    print(f"  All cancels worked:    {'✅' if all_cancelled else '❌'}")
    print(f"  No errors:             {'✅' if not errors else '❌'}")
    
    if all_completed and all_cancelled and not errors:
        print("\n🎉 All tests passed! DSQL persistence working correctly.")
    else:
        print("\n⚠️  Some tests failed. Check errors above.")


if __name__ == "__main__":
    asyncio.run(main())
