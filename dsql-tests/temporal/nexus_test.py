"""
Nexus endpoint test for Temporal with Aurora DSQL persistence.

Tests that Nexus endpoint CRUD operations work correctly on DSQL,
specifically validating that the UUID handling for the nexus_endpoints
table works with DSQL's strict UUID type (which rejects empty strings
unlike PostgreSQL's BYTEA).

The key bug this validates:
  ListNexusEndpoints uses "WHERE id > $1" for pagination. On the first
  page (no cursor), LastID is empty. The DSQL plugin must substitute
  the nil UUID (00000000-...) instead of passing an empty string, which
  DSQL rejects with SQLSTATE 22P02.

Prerequisites:
  - DSQL profile running with:
      system.enableNexus: true

Usage:
  cd profiles/dsql && docker compose up -d
  uv run python ../../dsql-tests/dsql_nexus_test.py
"""

import asyncio
import uuid

from temporalio.client import Client
from temporalio.api.operatorservice.v1 import (
    CreateNexusEndpointRequest,
    DeleteNexusEndpointRequest,
    GetNexusEndpointRequest,
    ListNexusEndpointsRequest,
)
from temporalio.api.nexus.v1 import EndpointSpec, EndpointTarget


# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

async def test_list_endpoints_empty(client: Client) -> bool:
    """List Nexus endpoints when none exist — validates empty-cursor UUID handling."""
    resp = await client.operator_service.list_nexus_endpoints(
        ListNexusEndpointsRequest()
    )
    count = len(resp.endpoints)
    print(f"  ✅ Listed endpoints (count={count}) — no UUID parse error")
    return True


async def test_create_and_list_endpoint(client: Client) -> bool:
    """Create a Nexus endpoint, list to verify it appears, then delete it."""
    endpoint_name = f"dsql-test-{uuid.uuid4().hex[:8]}"

    target = EndpointTarget()
    target.worker.namespace = "default"
    target.worker.task_queue = "nexus-test-queue"

    spec = EndpointSpec(name=endpoint_name, target=target)

    # Create
    create_resp = await client.operator_service.create_nexus_endpoint(
        CreateNexusEndpointRequest(spec=spec)
    )
    endpoint_id = create_resp.endpoint.id
    print(f"  ✅ Created endpoint: {endpoint_name} (id={endpoint_id})")

    # List — should include our endpoint
    list_resp = await client.operator_service.list_nexus_endpoints(
        ListNexusEndpointsRequest()
    )
    found = any(ep.id == endpoint_id for ep in list_resp.endpoints)
    if not found:
        print(f"  ❌ Endpoint {endpoint_id} not found in list")
        return False
    print(f"  ✅ Endpoint found in list")

    # Get by ID
    get_resp = await client.operator_service.get_nexus_endpoint(
        GetNexusEndpointRequest(id=endpoint_id)
    )
    if get_resp.endpoint.spec.name != endpoint_name:
        print(f"  ❌ Get returned wrong name: {get_resp.endpoint.spec.name}")
        return False
    print(f"  ✅ Get by ID returned correct endpoint")

    # Delete
    await client.operator_service.delete_nexus_endpoint(
        DeleteNexusEndpointRequest(
            id=endpoint_id,
            version=get_resp.endpoint.version,
        )
    )
    print(f"  ✅ Deleted endpoint")

    # Verify deletion
    list_resp2 = await client.operator_service.list_nexus_endpoints(
        ListNexusEndpointsRequest()
    )
    still_exists = any(ep.id == endpoint_id for ep in list_resp2.endpoints)
    if still_exists:
        print(f"  ❌ Endpoint still exists after deletion")
        return False
    print(f"  ✅ Endpoint confirmed deleted")

    return True


async def test_list_pagination(client: Client) -> bool:
    """Create multiple endpoints and verify paginated listing works."""
    endpoint_ids = []
    prefix = f"dsql-page-{uuid.uuid4().hex[:6]}"

    try:
        # Create 3 endpoints
        for i in range(3):
            target = EndpointTarget()
            target.worker.namespace = "default"
            target.worker.task_queue = "nexus-test-queue"

            resp = await client.operator_service.create_nexus_endpoint(
                CreateNexusEndpointRequest(
                    spec=EndpointSpec(name=f"{prefix}-{i}", target=target)
                )
            )
            endpoint_ids.append(resp.endpoint.id)

        print(f"  ✅ Created {len(endpoint_ids)} endpoints")

        # List with page size 2 to force pagination
        page1 = await client.operator_service.list_nexus_endpoints(
            ListNexusEndpointsRequest(page_size=2)
        )
        if not page1.endpoints:
            print("  ❌ First page returned no endpoints")
            return False
        print(f"  ✅ Page 1: {len(page1.endpoints)} endpoints")

        if page1.next_page_token:
            page2 = await client.operator_service.list_nexus_endpoints(
                ListNexusEndpointsRequest(
                    page_size=2,
                    next_page_token=page1.next_page_token,
                )
            )
            page2_count = len(page2.endpoints)
            print(f"  ✅ Page 2: {page2_count} endpoints")
        else:
            print(f"  ✅ All endpoints fit in one page (no pagination needed)")

        return True

    finally:
        # Cleanup — need to get versions for delete
        for eid in endpoint_ids:
            try:
                get_resp = await client.operator_service.get_nexus_endpoint(
                    GetNexusEndpointRequest(id=eid)
                )
                await client.operator_service.delete_nexus_endpoint(
                    DeleteNexusEndpointRequest(
                        id=eid,
                        version=get_resp.endpoint.version,
                    )
                )
            except Exception:
                pass  # Best-effort cleanup


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

async def main():
    import sys

    print("=" * 70)
    print("🔗 DSQL NEXUS ENDPOINT TEST")
    print("=" * 70)
    print()
    print("Requires:")
    print("  system.enableNexus: true")
    print()

    client = await Client.connect("localhost:7233")

    all_tests = [
        ("List endpoints (empty)", test_list_endpoints_empty),
        ("Create, list, get, delete", test_create_and_list_endpoint),
        ("Pagination", test_list_pagination),
    ]

    # Optional filter
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
        print("✅ All Nexus endpoint tests passed on DSQL!")
    else:
        print("⚠️  Some tests failed — check output above")
    print("=" * 70)


if __name__ == "__main__":
    asyncio.run(main())
