# DSQL Locking Patch Plan

## Purpose

This document defines an **incremental, loss-resilient patch plan** for making
Temporal’s SQL persistence layer correct and safe when backed by **Aurora DSQL**.

The goal is to eliminate unsupported locking semantics, enforce explicit fencing,
and correctly handle Aurora DSQL’s optimistic concurrency control (OCC) model,
without relying on fragile, large one-shot refactors.

This file is the **authoritative checklist and progress tracker** for the work.

---

## Core Constraints (Non-Negotiable)

These constraints must hold at all times:

1. **No unsupported SQL may be executed**
   - `FOR SHARE` and `LOCK IN SHARE MODE` must never be emitted
   - Any SQLSTATE `0A000` indicates a plugin bug and must fail fast

2. **Transaction conflicts must be retried at the transaction boundary**
   - Retry only on SQLSTATE `40001`
   - Retry must replay the *entire* transaction body
   - Retrying individual statements is insufficient

3. **CAS / fencing failures must never be retried**
   - `RowsAffected == 0` ⇒ `ConditionFailedError`
   - Condition failures are a *valid outcome*, not an error

4. **Error classification must preserve SQLSTATE**
   - Do not convert or wrap errors in a way that hides SQLSTATE before retry logic runs

5. **No assumptions about implicit increments**
   - Do not infer `expectedRangeID = newRangeID - 1`
   - Expected fencing tokens must be explicit and correct

---

## Checklist of Required Fixes

This checklist is intentionally small and ordered by risk.

### 🔴 A. Transaction-Boundary Retry (Highest Priority)

**Problem**
- Aurora DSQL raises conflicts at `COMMIT` time
- Current plugin retries only individual statements or only when `pdb.tx == nil`
- This leaves multi-statement persistence transactions unsafe

**Requirement**
- Identify the persistence transaction entrypoint(s)
- Wrap `BeginTx → body → Commit` in `RetryManager.RunTx(...)`
- Replay the entire transaction on SQLSTATE `40001`

**Status**
- [ ] Not started
- [ ] In progress
- [ ] Completed

---

### 🔴 B. Remove `range_id - 1` Inference

**Problem**
- Code assumes `row.RangeID` is always `prev + 1`
- This assumption is not guaranteed across Temporal call paths
- Leads to false `ConditionFailedError` under legitimate updates

**Requirement**
- Eliminate all implicit `expected = new - 1` logic
- Require explicit expected fencing tokens
- Or refactor update paths to read + CAS correctly

**Status**
- [ ] Not started
- [ ] In progress
- [ ] Completed

---

### 🔴 C. Enforce CAS in Primary Update Methods

**Problem**
- Core methods (`UpdateShards`, `UpdateTaskQueues`, etc.) still perform unconditional updates
- CAS helpers exist but are not universally used

**Requirement**
- Either:
  - make primary update methods fenced (preferred), or
  - ensure all call sites route through fenced helpers
- Convert `RowsAffected == 0` into `ConditionFailedError`

**Status**
- [ ] Not started
- [ ] In progress
- [ ] Completed

---

### 🟠 D. Eliminate All `FOR SHARE` Code Paths

**Problem**
- Some `FOR SHARE` queries still exist as constants or unused helpers
- Even unused code can regress silently on future upgrades

**Requirement**
- Remove `FOR SHARE` queries entirely, or
- Add tests asserting no executed SQL contains `FOR SHARE`

**Status**
- [ ] Not started
- [ ] In progress
- [ ] Completed

---

### 🟠 E. Execution Fencing Validation

**Problem**
- `ReadLockExecutions` previously relied on `FOR SHARE`
- Removing it is safe *only if* all mutation paths are properly fenced

**Requirement**
- Audit all execution mutation paths
- Verify fencing on:
  - `db_record_version`
  - `next_event_id`
  - cross-table updates (`executions` + `current_executions`)
- If uncertain, retain `FOR UPDATE` conservatively

**Status**
- [ ] Not started
- [ ] In progress
- [ ] Completed / Proven safe
- [ ] Deferred (kept conservative)

---

## Incremental Execution Strategy

To avoid loss of work and reasoning:

- Each checklist item is handled in **one focused patch**
- Each patch:
  - touches only the files required for that item
  - is reviewable in isolation
  - results in a concrete diff or zip artifact
- This document is updated after each completed item

---

## Current Plan of Attack

**Next task to execute:**  
👉 **A. Transaction-Boundary Retry**

Rationale:
- This is the single most critical correctness issue under DSQL
- Without this, no other fixes can guarantee safety under contention

---

## Notes / Open Questions

- Execution fencing may be partially unused in the current codebase
  - If confirmed unused, implement safely anyway and add a guard
- Error conversion (`ConvertError`) must be reviewed to ensure it does not
  hide SQLSTATE from retry classification
- Metrics are optional for correctness but strongly recommended for operability

---

## Change Log

| Date | Change |
|-----|-------|
| (add) | Initial patch plan created |

---

## Definition of “Done”

This patch plan is complete when:

- All checklist items A–E are marked **Completed**
- No persistence operation can fail due to:
  - unhandled SQLSTATE `40001`
  - hidden SQLSTATE due to premature conversion
  - unsupported locking clauses
- CAS failures are consistently surfaced and never retried

---

End of document.