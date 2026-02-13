"""
CHASM (V2) Scheduler test for Temporal with Aurora DSQL persistence.

Tests that schedules created via the CHASM engine work correctly on DSQL,
including create, pause, unpause, trigger, describe, and delete.

Prerequisites:
  - DSQL profile running with the following dynamic config enabled:

      # Master switch — real CHASM tree instead of noop
      history.enableChasm: true

      # Create new schedules via CHASM (V2) engine
      history.enableCHASMSchedulerCreation: true

      # CHASM callbacks — required so the scheduler can attach completion
      # callbacks when starting workflows (checked by frontend)
      history.enableCHASMCallbacks: true

      # Nexus APIs — the frontend's validateWorkflowCompletionCallbacks
      # gate checks system.enableNexus; without it every StartWorkflow
      # with callbacks returns "attaching workflow callbacks is disabled
      # for this namespace"
      system.enableNexus: true

      # Allow the chasm-scheduler experiment header from clients
      frontend.allowedExperiments: ["chasm-scheduler"]

  - Schema v1.1+ (includes current_chasm_executions table)

Note:
  If Nexus is disabled to reduce noise (endpoint registry queries, etc.)
  the CHASM scheduler will fail to start workflows. You can keep the
  endpoint registry off while still enabling the API gate:

      system.enableNexus: true
      system.nexusEndpointRegistryEnabled: false

Usage:
  cd profiles/dsql && docker compose up -d
  uv run python ../../dsql-tests/dsql_chasm_scheduler_test.py
"""

import asyncio
import time
import uuid
from datetime import timedelta
from temporalio import activity, workflow
from temporalio.client import Client, Schedule, ScheduleActionStartWorkflow, \
    ScheduleIntervalSpec, ScheduleSpec, ScheduleState
from temporalio.worker import Worker


# ---------------------------------------------------------------------------
# Workflow and activity used by the scheduled action
# ---------------------------------------------------------------------------

@activity.defn
async def scheduled_activity(run_id: str) -> str:
    return f"completed-{run_id}"


@workflow.defn
class ScheduledWorkflow:
    """Minimal workflow triggered by the scheduler."""

    @workflow.run
    async def run(self) -> str:
        return await workflow.execute_activity(
            scheduled_activity,
            f"{workflow.info().workflow_id}",
            start_to_close_timeout=timedelta(seconds=30),
        )


# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

async def wait_for_schedule_action(
    client: Client,
    schedule_id: str,
    *,
    min_actions: int = 1,
    timeout: float = 60.0,
    verbose: bool = False,
) -> int:
    """Poll schedule description until at least min_actions have run."""
    handle = client.get_schedule_handle(schedule_id)
    deadline = time.time() + timeout
    poll_count = 0
    while time.time() < deadline:
        desc = await handle.describe()
        count = desc.info.num_actions
        paused = desc.schedule.state.paused
        poll_count += 1
        if verbose and poll_count % 5 == 0:
            elapsed = timeout - (deadline - time.time())
            print(f"    … {elapsed:.0f}s elapsed, actions={count}, paused={paused}")
        if count >= min_actions:
            return count
        await asyncio.sleep(2)
    # Final state for diagnostics
    desc = await handle.describe()
    raise TimeoutError(
        f"Schedule {schedule_id} did not reach {min_actions} actions within {timeout}s "
        f"(actions={desc.info.num_actions}, paused={desc.schedule.state.paused})"
    )


# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

async def test_create_and_trigger(client: Client) -> bool:
    """Create a CHASM schedule, let it fire, verify the workflow ran."""
    schedule_id = f"chasm-test-{uuid.uuid4().hex[:8]}"
    handle = await client.create_schedule(
        schedule_id,
        Schedule(
            action=ScheduleActionStartWorkflow(
                ScheduledWorkflow.run,
                id=f"chasm-wf-{schedule_id}",
                task_queue="chasm-scheduler-queue",
            ),
            spec=ScheduleSpec(
                intervals=[ScheduleIntervalSpec(every=timedelta(seconds=5))],
            ),
        ),
    )

    try:
        actions = await wait_for_schedule_action(client, schedule_id, min_actions=1)
        print(f"  ✅ Schedule fired {actions} action(s)")
        return True
    finally:
        await handle.delete()


async def test_pause_unpause(client: Client) -> bool:
    """Create a running schedule, let it fire, pause, verify no new actions, unpause, verify it fires again.

    Known CHASM bug: generator_tasks.go returns early when Paused=true
    without scheduling the next generator task, and Patch() (unpause)
    doesn't create one. So a schedule created-as-paused never gets its
    first timer and will never fire after unpause.

    Workaround: create the schedule unpaused so the generator task chain
    is established before pausing.
    """
    schedule_id = f"chasm-pause-{uuid.uuid4().hex[:8]}"
    handle = await client.create_schedule(
        schedule_id,
        Schedule(
            action=ScheduleActionStartWorkflow(
                ScheduledWorkflow.run,
                id=f"chasm-wf-{schedule_id}",
                task_queue="chasm-scheduler-queue",
            ),
            spec=ScheduleSpec(
                intervals=[ScheduleIntervalSpec(every=timedelta(seconds=5))],
            ),
        ),
    )

    try:
        # Wait for at least one action to confirm the schedule is working
        actions_before = await wait_for_schedule_action(
            client, schedule_id, min_actions=1, timeout=30,
        )
        print(f"  ✅ Schedule fired {actions_before} action(s) before pause")

        # Pause
        await handle.pause(note="pausing for test")
        await asyncio.sleep(1)
        desc = await handle.describe()
        if not desc.schedule.state.paused:
            print("  ❌ Schedule not paused after pause call")
            return False

        # Record action count, wait, verify no new actions
        snapshot = desc.info.num_actions
        await asyncio.sleep(12)  # > 2 intervals
        desc = await handle.describe()
        if desc.info.num_actions != snapshot:
            print(f"  ❌ Schedule fired while paused ({desc.info.num_actions - snapshot} new actions)")
            return False
        print("  ✅ No actions while paused")

        # Unpause
        await handle.unpause(note="resuming for test")
        await asyncio.sleep(1)
        desc = await handle.describe()
        if desc.schedule.state.paused:
            print("  ❌ Schedule still paused after unpause call")
            return False
        print("  ✅ Schedule unpaused")

        if desc.info.next_action_times:
            for t in desc.info.next_action_times[:3]:
                print(f"    next action: {t.isoformat()}")
        else:
            print("    ⚠ no next_action_times reported")

        # Wait for a new action after unpause
        # Known CHASM bug: the generator task chain breaks after
        # pause→unpause. The generator returns early when paused without
        # scheduling the next task, and Patch (unpause) doesn't re-arm it.
        # describe() reports next_action_times (computed from spec) but
        # no actual timer task exists to fire them.
        try:
            actions = await wait_for_schedule_action(
                client, schedule_id, min_actions=snapshot + 1, timeout=30, verbose=True,
            )
            print(f"  ✅ Schedule fired after unpause (total {actions} actions)")
        except TimeoutError:
            print("  ⚠ Schedule did not fire after unpause (known CHASM generator re-arm bug)")
            print("    See generator_tasks.go: returns nil when Paused without scheduling next task")
            return False
        return True
    finally:
        await handle.delete()


async def test_trigger_immediate(client: Client) -> bool:
    """Create a paused schedule, trigger it manually, verify it fires once."""
    schedule_id = f"chasm-trigger-{uuid.uuid4().hex[:8]}"
    handle = await client.create_schedule(
        schedule_id,
        Schedule(
            action=ScheduleActionStartWorkflow(
                ScheduledWorkflow.run,
                id=f"chasm-wf-{schedule_id}",
                task_queue="chasm-scheduler-queue",
            ),
            spec=ScheduleSpec(
                intervals=[ScheduleIntervalSpec(every=timedelta(hours=1))],
            ),
            state=ScheduleState(paused=True, note="paused — manual trigger only"),
        ),
    )

    try:
        await handle.trigger()
        actions = await wait_for_schedule_action(client, schedule_id, min_actions=1, timeout=30)
        print(f"  ✅ Manual trigger produced {actions} action(s)")
        return True
    finally:
        await handle.delete()


async def test_describe(client: Client) -> bool:
    """Create a schedule and verify describe returns expected fields."""
    schedule_id = f"chasm-desc-{uuid.uuid4().hex[:8]}"
    handle = await client.create_schedule(
        schedule_id,
        Schedule(
            action=ScheduleActionStartWorkflow(
                ScheduledWorkflow.run,
                id=f"chasm-wf-{schedule_id}",
                task_queue="chasm-scheduler-queue",
            ),
            spec=ScheduleSpec(
                intervals=[ScheduleIntervalSpec(every=timedelta(minutes=10))],
            ),
            state=ScheduleState(note="describe test"),
        ),
    )

    try:
        desc = await handle.describe()
        assert desc.id == schedule_id, f"Expected id={schedule_id}, got {desc.id}"
        assert desc.schedule.state.note == "describe test"
        print(f"  ✅ Describe returned correct id and note")
        return True
    finally:
        await handle.delete()


async def test_list_schedules(client: Client) -> bool:
    """Create a schedule and verify it appears in list.

    Known CHASM limitation: CHASM executions live in
    current_chasm_executions (not the regular executions table) and may
    not be indexed into visibility/ES, causing list_schedules to return
    empty results even though the schedule exists in DSQL.
    """
    schedule_id = f"chasm-list-{uuid.uuid4().hex[:8]}"
    handle = await client.create_schedule(
        schedule_id,
        Schedule(
            action=ScheduleActionStartWorkflow(
                ScheduledWorkflow.run,
                id=f"chasm-wf-{schedule_id}",
                task_queue="chasm-scheduler-queue",
            ),
            spec=ScheduleSpec(
                intervals=[ScheduleIntervalSpec(every=timedelta(hours=1))],
            ),
        ),
    )

    try:
        # Visibility is eventually consistent — retry a few times
        found = False
        for _ in range(10):
            async for entry in await client.list_schedules():
                if entry.id == schedule_id:
                    found = True
                    break
            if found:
                break
            await asyncio.sleep(2)

        if found:
            print("  ✅ Schedule found in list")
        else:
            print("  ⚠ Schedule not found in list (CHASM executions may not be indexed into ES visibility)")
        return found
    finally:
        await handle.delete()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

async def main():
    import sys

    print("=" * 70)
    print("🗓️  DSQL CHASM (V2) SCHEDULER TEST")
    print("=" * 70)
    print()
    print("Requires:")
    print("  history.enableChasm: true")
    print("  history.enableCHASMSchedulerCreation: true")
    print("  history.enableCHASMCallbacks: true")
    print("  system.enableNexus: true  (frontend callback gate)")
    print("  frontend.allowedExperiments: [chasm-scheduler]")
    print("  Schema v1.1+ (current_chasm_executions table)")
    print()

    client = await Client.connect("localhost:7233")

    all_tests = [
        ("Create and trigger", test_create_and_trigger),
        ("Pause / unpause", test_pause_unpause),
        ("Manual trigger", test_trigger_immediate),
        ("Describe", test_describe),
        ("List schedules", test_list_schedules),
    ]

    # Optional filter: pass test name substrings as CLI args
    filters = sys.argv[1:]
    if filters:
        tests = [
            (name, fn) for name, fn in all_tests
            if any(f.lower() in name.lower() for f in filters)
        ]
        print(f"Running {len(tests)} of {len(all_tests)} tests (filter: {filters})")
    else:
        tests = all_tests

    passed = 0
    failed = 0

    async with Worker(
        client,
        task_queue="chasm-scheduler-queue",
        workflows=[ScheduledWorkflow],
        activities=[scheduled_activity],
    ):
        for name, test_fn in tests:
            print(f"\n▶ {name}")
            try:
                ok = await test_fn(client)
                if ok:
                    passed += 1
                else:
                    failed += 1
            except Exception as e:
                print(f"  ❌ {e}")
                failed += 1

    print("\n" + "=" * 70)
    print(f"Results: {passed} passed, {failed} failed out of {len(tests)}")
    if failed == 0:
        print("✅ All CHASM scheduler tests passed on DSQL!")
    else:
        print("⚠️  Some tests failed — check output above")
    print("=" * 70)


if __name__ == "__main__":
    asyncio.run(main())
