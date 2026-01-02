# DSQL Locking Limitation Issue

**Issue ID:** DSQL-LOCK-001  
**Created:** 2024-12-30  
**Status:** Open  
**Priority:** High  
**Component:** Persistence Layer / Shard Management  

## Problem Statement

Aurora DSQL only supports `FOR UPDATE` locking clauses, but Temporal's shard management system attempts to use other locking mechanisms that are not supported by DSQL.

## Error Details

**Error Message:**
```
ERROR: locking clauses other than FOR UPDATE are not supported (SQLSTATE 0A000)
```

**Stack Trace Location:**
- `service/history/shard/context_impl.go` - Shard locking operations
- `common/persistence/sql/sqlplugin/dsql/` - DSQL plugin layer

**Affected Operations:**
- Shard acquisition and locking
- Workflow execution creation
- System workflow initialization (temporal-sys-tq-scanner, temporal-sys-history-scanner)

## Root Cause Analysis

### DSQL Limitations
1. **Supported:** `SELECT ... FOR UPDATE` 
2. **Not Supported:** Other locking clauses like `FOR SHARE`, `FOR KEY SHARE`, `FOR NO KEY UPDATE`
3. **Impact:** Temporal's shard management relies on PostgreSQL-compatible locking semantics

### Current Implementation Issues
- Temporal uses PostgreSQL-style locking for shard coordination
- DSQL plugin currently delegates to PostgreSQL implementation without handling locking differences
- Shard locking is critical for Temporal's distributed architecture

## Investigation Findings

### Successful Fixes Applied
✅ **Nexus Endpoints Binary Field Issue** - Resolved with safe UUID string conversion
- Fixed `bytesToUUIDString()` helper function
- Handles empty and short byte slices properly
- All containers now run without crashes

### Current Blocking Issue
🔍 **DSQL Locking Compatibility** - Active investigation required
- Services start successfully but fail on shard operations
- System workflows cannot initialize due to locking failures
- Frontend/History services encounter repeated locking errors

## Technical Analysis

### Affected Code Paths
1. **Shard Context Implementation**
   - File: `service/history/shard/context_impl.go`
   - Function: Shard acquisition and range updates
   - Issue: Uses unsupported locking clauses

2. **DSQL Plugin Layer**
   - File: `common/persistence/sql/sqlplugin/dsql/`
   - Issue: Inherits PostgreSQL locking behavior without DSQL adaptations

3. **Workflow Transaction Layer**
   - File: `service/history/workflow/transaction_impl.go`
   - Issue: Shard locking failures cascade to workflow operations

### DSQL Constraints
- **Optimistic Concurrency Control (OCC)** instead of pessimistic locking
- **Limited Locking Support** - only `FOR UPDATE` clause
- **Serialization Conflicts** - different retry semantics than PostgreSQL

## Proposed Solutions

### Option 1: DSQL-Specific Shard Locking (Recommended)
**Approach:** Implement DSQL-compatible shard locking mechanism
- Replace unsupported locking clauses with `FOR UPDATE` where possible
- Implement retry logic for DSQL's optimistic concurrency model
- Add DSQL-specific error handling for serialization conflicts

**Implementation Steps:**
1. Create DSQL-specific shard management queries
2. Implement optimistic locking patterns for shard operations
3. Add retry mechanisms for serialization conflicts
4. Update DSQL plugin to override PostgreSQL locking behavior

**Pros:** 
- Maintains Temporal's distributed shard model
- Leverages DSQL's supported locking mechanism
- Preserves existing architecture patterns

**Cons:**
- Requires significant changes to shard management
- May impact performance due to retry overhead
- Complex testing requirements

### Option 2: Alternative Coordination Mechanism
**Approach:** Replace database-level locking with application-level coordination
- Use DSQL's optimistic concurrency with application-level conflict resolution
- Implement distributed coordination using supported DSQL features
- Leverage unique constraints and conditional updates

**Implementation Steps:**
1. Design application-level shard coordination protocol
2. Replace locking queries with conditional update patterns
3. Implement conflict detection and resolution logic
4. Add comprehensive testing for race conditions

**Pros:**
- Works within DSQL's limitations
- Potentially better performance with OCC model
- More portable across different databases

**Cons:**
- Major architectural changes required
- Higher complexity in conflict resolution
- Extensive testing needed for correctness

### Option 3: Hybrid Approach
**Approach:** Combine `FOR UPDATE` with optimistic patterns
- Use `FOR UPDATE` where supported
- Fall back to optimistic patterns for unsupported cases
- Implement adaptive locking strategy

## Implementation Plan

### Phase 1: Investigation and Design (1-2 days)
- [ ] Analyze all locking usage in Temporal codebase
- [ ] Identify specific unsupported locking clauses
- [ ] Design DSQL-compatible locking strategy
- [ ] Create detailed implementation specification

### Phase 2: Core Implementation (3-5 days)
- [ ] Implement DSQL-specific shard locking queries
- [ ] Add optimistic concurrency handling
- [ ] Update DSQL plugin with locking overrides
- [ ] Implement retry mechanisms for serialization conflicts

### Phase 3: Testing and Validation (2-3 days)
- [ ] Unit tests for DSQL locking mechanisms
- [ ] Integration tests with multi-service setup
- [ ] Performance testing under concurrent load
- [ ] Validation of shard coordination correctness

### Phase 4: Documentation and Deployment (1 day)
- [ ] Update DSQL compatibility documentation
- [ ] Add operational notes for DSQL-specific behavior
- [ ] Update deployment guides and troubleshooting

## Testing Strategy

### Unit Tests
- DSQL plugin locking behavior
- Shard acquisition and release cycles
- Serialization conflict handling
- Retry mechanism validation

### Integration Tests
- Multi-service shard coordination
- Concurrent workflow execution
- System workflow initialization
- Failover and recovery scenarios

### Performance Tests
- Shard locking throughput
- Serialization conflict frequency
- Retry overhead measurement
- Comparison with PostgreSQL baseline

## Success Criteria

### Functional Requirements
- [ ] All Temporal services start without locking errors
- [ ] System workflows initialize successfully
- [ ] User workflows execute without shard-related failures
- [ ] Multi-service coordination works correctly

### Performance Requirements
- [ ] Shard operations complete within acceptable latency
- [ ] Serialization conflict rate remains manageable
- [ ] Overall system throughput comparable to PostgreSQL

### Reliability Requirements
- [ ] No data corruption under concurrent access
- [ ] Proper failover behavior during conflicts
- [ ] Consistent shard state across service restarts

## Dependencies

### External Dependencies
- Aurora DSQL service availability and behavior
- DSQL documentation for locking semantics
- AWS support for DSQL-specific issues

### Internal Dependencies
- Temporal shard management architecture
- DSQL plugin implementation
- Multi-service deployment configuration

## Risk Assessment

### High Risk
- **Data Consistency:** Incorrect locking implementation could cause data corruption
- **Performance Impact:** Retry overhead may significantly impact throughput
- **Compatibility:** Changes may affect other database backends

### Medium Risk
- **Testing Complexity:** Concurrent scenarios are difficult to test comprehensively
- **Deployment Impact:** Changes require careful rollout strategy
- **Maintenance Overhead:** DSQL-specific code paths increase complexity

### Mitigation Strategies
- Comprehensive testing with concurrent workloads
- Gradual rollout with monitoring and rollback capability
- Clear documentation and operational procedures
- Regular validation against DSQL service updates

## Related Issues

### Resolved Issues
- ✅ **DSQL-BIN-001:** Nexus Endpoints Binary Field Panic - Fixed with safe UUID conversion

### Future Considerations
- **DSQL-PERF-001:** Performance optimization for DSQL-specific patterns
- **DSQL-SCALE-001:** Scaling considerations for optimistic concurrency model
- **DSQL-MONITOR-001:** Monitoring and alerting for DSQL-specific metrics

## References

### Documentation
- [Aurora DSQL Documentation](https://docs.aws.amazon.com/aurora-dsql/)
- [Temporal Shard Management](https://docs.temporal.io/)
- [PostgreSQL Locking Documentation](https://www.postgresql.org/docs/current/explicit-locking.html)

### Code References
- `service/history/shard/context_impl.go` - Shard management implementation
- `common/persistence/sql/sqlplugin/dsql/` - DSQL plugin layer
- `common/persistence/sql/sqlplugin/postgresql/` - PostgreSQL reference implementation

### Error Logs
```
Failed to lock shard with ID: 4. Error: ERROR: locking clauses other than FOR UPDATE are not supported (SQLSTATE 0A000)
```

---

**Next Actions:**
1. Assign to development team for Phase 1 investigation
2. Schedule design review session
3. Create tracking branch for implementation work
4. Set up monitoring for DSQL locking behavior

**Contact:** Development Team  
**Last Updated:** 2024-12-30