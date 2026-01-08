# Implementation Plan: DSQL Locking Compatibility

## Overview

This implementation plan addresses the critical DSQL locking compatibility issue by implementing method-level overrides for unsupported locking patterns, transaction retry logic for DSQL's optimistic concurrency control, and comprehensive error handling. The approach focuses on replacing `FOR SHARE` read locks with optimistic concurrency patterns while maintaining data consistency through conditional updates and proper fencing.

## Tasks

- [x] 1. Complete DSQL plugin infrastructure setup
  - ✅ DSQL plugin directory structure already exists
  - ✅ Plugin registration and initialization already implemented
  - ✅ Basic error handling for DSQL-specific errors already implemented
  - Add RetryManager and metrics types for DSQL-specific operations
  - _Requirements: 1.1, 2.1_

- [x] 2. Implement transaction retry framework
  - [x] 2.1 Create RetryManager with configuration support
    - Implement RetryConfig struct with configurable retry parameters
    - Add exponential backoff with jitter calculation
    - Include metrics collection for retry operations
    - _Requirements: 9.1, 10.1_

  - [ ]* 2.2 Write property test for retry framework
    - **Property 3: Serialization Conflict Retry**
    - **Validates: Requirements 9.1**

  - [x] 2.3 Implement RunTxWithRetry generic wrapper
    - Create generic retry wrapper supporting return values
    - Implement RunTxWithRetryVoid for operations without return values
    - Add proper context cancellation handling
    - _Requirements: 9.1, 9.5_

  - [ ]* 2.4 Write unit tests for retry wrapper
    - Test retry behavior with SQLSTATE 40001
    - Test context cancellation during retries
    - Test retry exhaustion scenarios
    - _Requirements: 9.1, 9.3_

- [x] 3. Implement error classification system
  - [x] 3.1 Create DSQL error types and classification
    - Implement ConditionFailedError type
    - Create error classification function for DSQL-specific errors
    - Add IsConditionFailedError helper function
    - _Requirements: 9.2, 9.4_

  - [x] 3.2 Implement error handling utilities
    - Create isRetryableError function with SQLSTATE detection
    - Add error conversion to Temporal error types
    - Implement proper error logging and metrics
    - _Requirements: 9.2, 9.3_

  - [ ]* 3.3 Write property test for error classification
    - **Property 5: Error Handling Robustness**
    - **Validates: Requirements 9.2, 9.4**

- [x] 4. Checkpoint - Verify retry framework functionality
  - Ensure all retry framework tests pass, ask the user if questions arise.

- [x] 5. Implement safe method overrides (ReadLockShards)
  - [x] 5.1 Override ReadLockShards method
    - Remove FOR SHARE clause from shard read operations
    - Implement simple SELECT without locking
    - Wrap in RunTxWithRetry for consistency
    - _Requirements: 2.1, 3.1_

  - [ ]* 5.2 Write property test for ReadLockShards override
    - **Property 1: DSQL Locking Compatibility**
    - **Validates: Requirements 2.1, 3.1**

  - [ ]* 5.3 Write unit tests for ReadLockShards
    - Test successful range_id retrieval
    - Test error handling and retry behavior
    - Verify no FOR SHARE clause in generated SQL
    - _Requirements: 3.1_

- [x] 6. Investigate execution fencing patterns
  - [x] 6.1 Analyze ReadLockExecutions call sites
    - Review all usages of ReadLockExecutions in codebase
    - Identify subsequent UPDATE operations and their fencing tokens
    - Document which operations use db_record_version and next_event_id fencing
    - _Requirements: 6.1, 6.2_

  - [x] 6.2 Create execution fencing analysis report
    - Document findings on execution state fencing adequacy
    - Determine if ReadLockExecutions can safely remove FOR SHARE
    - Provide recommendations for implementation approach
    - _Requirements: 6.1, 6.4_

- [x] 7. Implement execution method overrides (conditional)
  - [x] 7.1 Implement ReadLockExecutions override (if safe)
    - Remove FOR SHARE clause if adequate fencing exists
    - Keep FOR UPDATE if fencing is inadequate
    - Document decision rationale in code comments
    - _Requirements: 6.1, 6.2_

  - [ ]* 7.2 Write property test for ReadLockExecutions (if implemented)
    - **Property 1: DSQL Locking Compatibility**
    - **Validates: Requirements 6.1, 6.2**

- [x] 8. Implement write lock method wrappers
  - [x] 8.1 Wrap WriteLockShards with retry logic
    - Keep FOR UPDATE syntax (supported by DSQL)
    - Wrap entire operation in RunTxWithRetry
    - Ensure proper SQLSTATE 40001 handling
    - _Requirements: 3.2, 3.3_

  - [x] 8.2 Wrap LockTaskQueue with retry logic
    - Keep FOR UPDATE syntax for task queue locking
    - Add retry wrapper for serialization conflicts
    - Ensure range_id fencing in subsequent updates
    - _Requirements: 5.1, 5.3_

  - [x] 8.3 Wrap LockNamespaceMetadata with retry logic
    - Keep FOR UPDATE syntax for namespace locking
    - Add retry wrapper for conflict handling
    - Ensure notification_version fencing in updates
    - _Requirements: 4.1, 4.3_

  - [ ]* 8.4 Write property tests for write lock wrappers
    - **Property 3: Serialization Conflict Retry**
    - **Validates: Requirements 3.3, 4.3, 5.3**

- [x] 9. Implement conditional update patterns
  - [x] 9.1 Create CAS update helpers
    - Implement UpdateShardWithCAS function
    - Create generic conditional update utilities
    - Add proper rowsAffected validation
    - _Requirements: 3.2, 3.4_

  - [x] 9.2 Implement namespace CAS updates
    - Create conditional update for namespace metadata
    - Use notification_version as fencing token
    - Handle condition failures appropriately
    - _Requirements: 4.2, 4.4_

  - [x] 9.3 Implement task queue CAS updates
    - Create conditional update for task queue metadata
    - Use existing range_id fencing (no new columns)
    - Ensure atomic range_id increments
    - _Requirements: 5.2, 5.4_

  - [ ]* 9.4 Write property test for conditional updates
    - **Property 2: Conditional Update Atomicity**
    - **Validates: Requirements 3.2, 4.2, 5.2**

- [x] 10. Checkpoint - Verify core functionality
  - ✅ **CRITICAL FIX APPLIED**: Made primary update methods fenced to prevent lost updates
  - ✅ **UpdateShards**: Now requires fencing token (expectedRangeID) and uses CAS pattern
  - ✅ **UpdateTaskQueues**: Now requires fencing token (expectedRangeID) and uses CAS pattern  
  - ✅ **UpdateNamespace**: Now requires fencing token (expectedNotificationVersion) and uses CAS pattern
  - ✅ **FOR SHARE SAFETY**: Removed all FOR SHARE query constants to prevent accidental usage
  - ✅ **ERROR HANDLING CONSISTENCY**: Fixed error conversion architecture
    - Removed unused `ConvertError` function (was never called)
    - Kept only `ClassifyError` for retry logic (preserves SQLSTATE 40001 for retry detection)
    - Uses Temporal's standard `handle.ConvertError()` for actual error conversion
    - Prevents signal destruction that would break retry logic
  - ✅ **Safety Tests**: Added comprehensive tests to prevent FOR SHARE regressions
  - ✅ All method overrides and CAS updates work correctly with proper fencing
  - ✅ Backward compatibility maintained through automatic fencing token detection
  - ✅ All tests passing (26 passed, 3 skipped optional tests)

- [ ] 11. Implement DSQL plugin registration
  - [ ] 11.1 Create DSQL plugin struct
    - Embed PostgreSQL plugin for base functionality
    - Add DSQL-specific method overrides
    - Include retry manager and metrics
    - _Requirements: 1.1, 2.1_

  - [ ] 11.2 Implement plugin factory and registration
    - Register DSQL plugin with SQL plugin system
    - Handle configuration and initialization
    - Set up proper plugin lifecycle management
    - _Requirements: 1.1_

  - [ ]* 11.3 Write integration tests for plugin registration
    - Test plugin initialization with DSQL configuration
    - Verify method override registration
    - Test plugin lifecycle and cleanup
    - _Requirements: 1.1_

- [ ] 12. Implement observability and metrics
  - [ ] 12.1 Create DSQL-specific metrics
    - Implement retry counters and conflict metrics
    - Add operation duration histograms
    - Create error classification metrics
    - _Requirements: 10.1, 10.2_

  - [ ] 12.2 Add metrics collection to operations
    - Instrument retry operations with metrics
    - Track conflict rates and retry attempts
    - Monitor operation latencies and success rates
    - _Requirements: 10.1, 10.3_

  - [ ]* 12.3 Write unit tests for metrics collection
    - Test metric increments during operations
    - Verify proper metric labeling
    - Test metrics under various error conditions
    - _Requirements: 10.1_

- [ ] 13. Implement comprehensive testing
  - [ ]* 13.1 Write concurrency safety tests
    - **Property 4: Concurrency Safety**
    - **Validates: Requirements 3.4, 4.4, 5.4, 6.4**

  - [ ]* 13.2 Write data integrity tests
    - **Property 6: Data Integrity Under Failures**
    - **Validates: Requirements 3.5, 4.5, 5.5, 6.5**

  - [ ]* 13.3 Write service initialization tests
    - **Property 8: Service Initialization**
    - **Validates: Requirements 1.1**

  - [ ]* 13.4 Write metrics and observability tests
    - **Property 7: Metrics and Observability**
    - **Validates: Requirements 10.1, 10.2**

- [ ] 14. Integration and validation
  - [ ] 14.1 Wire DSQL plugin into Temporal services
    - Update service configuration to use DSQL plugin
    - Ensure proper plugin selection based on database type
    - Test end-to-end service startup with DSQL
    - _Requirements: 1.1, 1.2_

  - [ ] 14.2 Validate against original DSQL locking issue
    - Test that original DSQL-LOCK-001 error is resolved
    - Verify all Temporal services start successfully with DSQL
    - Confirm no unsupported locking clauses reach DSQL
    - _Requirements: 1.1, 1.2, 2.2_

  - [ ]* 14.3 Write end-to-end integration tests
    - Test complete workflow execution with DSQL
    - Verify shard coordination across multiple services
    - Test namespace and task queue operations under load
    - _Requirements: 1.1, 3.4, 4.4, 5.4_

- [ ] 15. Final checkpoint - Complete system validation
  - Ensure all tests pass and DSQL locking compatibility is fully resolved, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Investigation task (6.1-6.2) must be completed before execution method implementation (7.1-7.2)
- Checkpoints ensure incremental validation and user feedback
- Property tests validate universal correctness properties using Go's testing/quick package
- Unit tests validate specific examples and edge cases
- Start with ReadLockShards (proven safe) before investigating execution patterns
- Never retry ConditionFailedError - only retry SQLSTATE 40001
- Use existing fencing tokens (range_id, notification_version) rather than adding new columns