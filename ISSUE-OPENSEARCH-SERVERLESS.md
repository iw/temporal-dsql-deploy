# OpenSearch Serverless Compatibility Issue

**Issue ID:** OPENSEARCH-001  
**Created:** 2024-12-30  
**Status:** Open  
**Priority:** Medium  
**Component:** Visibility Store / OpenSearch Integration  

## Problem Statement

AWS OpenSearch Serverless is not compatible with Temporal's visibility store requirements, but AWS OpenSearch Provisioned clusters are compatible. The current Terraform configuration provisions OpenSearch Serverless, which needs to be replaced with a provisioned OpenSearch cluster.

## Background

### Current Implementation
- **Service**: AWS OpenSearch Serverless collection
- **Provisioning**: Terraform module creates serverless collection
- **Configuration**: IAM-based data access policies
- **Access**: Public HTTPS with optional aws-sigv4-proxy

### Compatibility Issues
- **Temporal Requirements**: Specific OpenSearch/Elasticsearch features and APIs
- **Serverless Limitations**: Reduced feature set compared to provisioned clusters
- **API Differences**: Serverless may not support all required operations
- **Index Management**: Different behavior for index lifecycle management

## Impact Assessment

### Current Status
- ✅ Infrastructure provisioning works
- ✅ Basic connectivity established
- ❌ Temporal visibility operations may fail
- ❌ Advanced search features unavailable
- ❌ Index management operations unsupported

### Affected Components
1. **Temporal Visibility Store**
   - Workflow search and filtering
   - Advanced visibility queries
   - Workflow history indexing
   - Performance metrics and dashboards

2. **Terraform Infrastructure**
   - OpenSearch resource definitions
   - Security group configurations
   - IAM policies and access controls
   - Network connectivity setup

3. **Application Configuration**
   - OpenSearch endpoint configuration
   - Authentication and authorization
   - Index templates and mappings
   - Connection pooling and timeouts

## Technical Requirements

### OpenSearch Provisioned Specifications
- **Instance Type**: `t3.small.search` (as requested)
- **Version**: Latest compatible with Temporal (7.x recommended)
- **Storage**: EBS-backed with appropriate IOPS
- **Availability**: Single-AZ for development, Multi-AZ for production
- **Security**: VPC-based with security groups

### Temporal Compatibility Requirements
- **Elasticsearch/OpenSearch Version**: 7.x or 8.x compatibility
- **Required APIs**: Full search, aggregation, and index management APIs
- **Index Operations**: Create, delete, update index templates
- **Query Features**: Complex queries, sorting, pagination
- **Bulk Operations**: Bulk indexing for high throughput

## Proposed Solution

### Terraform Configuration Changes
Replace OpenSearch Serverless with provisioned cluster configuration:

```hcl
# Replace serverless collection with provisioned cluster
resource "aws_opensearch_domain" "temporal_visibility" {
  domain_name    = "temporal-visibility-${var.environment}"
  engine_version = "OpenSearch_2.3"

  cluster_config {
    instance_type  = "t3.small.search"
    instance_count = 1
    
    # For production, consider:
    # instance_count = 3
    # dedicated_master_enabled = true
    # master_instance_type = "t3.small.search"
    # master_instance_count = 3
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = 20
    iops        = 3000
  }

  vpc_options {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.opensearch.id]
  }

  encrypt_at_rest {
    enabled = true
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action   = "es:*"
        Resource = "arn:aws:es:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:domain/temporal-visibility-${var.environment}/*"
        Condition = {
          IpAddress = {
            "aws:sourceIp" = var.allowed_cidr_blocks
          }
        }
      }
    ]
  })

  tags = var.tags
}

# Security group for OpenSearch
resource "aws_security_group" "opensearch" {
  name_prefix = "temporal-opensearch-${var.environment}"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "temporal-opensearch-${var.environment}"
  })
}

# Output the domain endpoint
output "opensearch_domain_endpoint" {
  description = "OpenSearch domain endpoint"
  value       = "https://${aws_opensearch_domain.temporal_visibility.endpoint}"
}

output "opensearch_domain_arn" {
  description = "OpenSearch domain ARN"
  value       = aws_opensearch_domain.temporal_visibility.arn
}
```

### Configuration Updates Required

1. **Terraform Variables**
   ```hcl
   variable "opensearch_instance_type" {
     description = "OpenSearch instance type"
     type        = string
     default     = "t3.small.search"
   }

   variable "opensearch_instance_count" {
     description = "Number of OpenSearch instances"
     type        = number
     default     = 1
   }

   variable "opensearch_volume_size" {
     description = "EBS volume size for OpenSearch instances"
     type        = number
     default     = 20
   }
   ```

2. **Environment Configuration**
   - Update `.env.integration` with new endpoint format
   - Modify authentication method if needed
   - Update connection timeouts and retry settings

3. **Docker Configuration**
   - Update OpenSearch endpoint environment variables
   - Modify authentication configuration
   - Test connectivity with provisioned cluster

## Implementation Plan

### Phase 1: Terraform Updates (Tomorrow - 1 day)
- [ ] **Morning**: Update Terraform configuration files
  - Replace serverless collection with provisioned domain
  - Add security group and VPC configuration
  - Update outputs and variables
- [ ] **Afternoon**: Test Terraform plan and apply
  - Validate configuration syntax
  - Review resource changes
  - Apply changes to development environment

### Phase 2: Configuration and Testing (1-2 days)
- [ ] Update application configuration for new endpoint
- [ ] Test OpenSearch connectivity and authentication
- [ ] Validate Temporal visibility operations
- [ ] Verify index creation and search functionality
- [ ] Performance testing with t3.small.search instances

### Phase 3: Documentation and Cleanup (0.5 days)
- [ ] Update documentation with new configuration
- [ ] Remove serverless-specific configuration
- [ ] Update deployment guides and troubleshooting
- [ ] Clean up unused IAM policies and resources

## Testing Strategy

### Connectivity Testing
- [ ] Basic HTTPS connectivity to OpenSearch endpoint
- [ ] Authentication and authorization validation
- [ ] Network security group and VPC access verification

### Temporal Integration Testing
- [ ] Visibility store initialization
- [ ] Workflow indexing and search operations
- [ ] Advanced query functionality
- [ ] Index template creation and management

### Performance Testing
- [ ] Indexing throughput with t3.small.search
- [ ] Query response times and latency
- [ ] Resource utilization monitoring
- [ ] Scaling behavior under load

## Cost Considerations

### OpenSearch Serverless vs Provisioned
- **Serverless**: Pay-per-use model, automatic scaling
- **Provisioned**: Fixed instance costs, predictable billing
- **t3.small.search**: ~$24-30/month per instance (development)

### Development Environment
- **Single Instance**: t3.small.search for cost optimization
- **Storage**: 20GB EBS gp3 volume (~$2/month)
- **Data Transfer**: Minimal for development workloads

### Production Considerations
- **Multi-AZ**: 3 instances for high availability
- **Dedicated Masters**: Additional instances for cluster management
- **Enhanced Storage**: Higher IOPS and larger volumes
- **Estimated Cost**: $100-200/month for production setup

## Risk Assessment

### Low Risk
- **Configuration Changes**: Well-documented Terraform patterns
- **Instance Type**: t3.small.search is proven and cost-effective
- **Compatibility**: OpenSearch provisioned has full Temporal support

### Medium Risk
- **Migration Timing**: Requires coordination with development work
- **Data Migration**: May need to recreate indices and data
- **Network Configuration**: VPC and security group setup complexity

### Mitigation Strategies
- **Backup Current Config**: Save serverless configuration before changes
- **Staged Deployment**: Test in development before production
- **Rollback Plan**: Keep ability to revert to serverless if needed
- **Documentation**: Clear migration steps and troubleshooting guide

## Dependencies

### External Dependencies
- AWS OpenSearch service availability in target region
- VPC and subnet configuration from main infrastructure
- Security group and network ACL permissions

### Internal Dependencies
- Terraform state management and deployment pipeline
- Application configuration management
- Docker container and environment variable updates

## Success Criteria

### Functional Requirements
- [ ] OpenSearch provisioned cluster deploys successfully
- [ ] Temporal visibility store connects without errors
- [ ] All visibility operations work correctly
- [ ] Search and query functionality performs adequately

### Performance Requirements
- [ ] Query response times under 1 second for typical operations
- [ ] Indexing keeps up with workflow execution rate
- [ ] Resource utilization stays within acceptable limits

### Operational Requirements
- [ ] Monitoring and alerting configured
- [ ] Backup and recovery procedures documented
- [ ] Cost tracking and optimization measures in place

## Related Issues

### Blocking Issues
- **DSQL-LOCK-001**: DSQL locking limitation (higher priority)

### Related Enhancements
- **Future**: Multi-AZ deployment for production
- **Future**: Enhanced monitoring and alerting
- **Future**: Index lifecycle management optimization

## References

### Documentation
- [AWS OpenSearch Service](https://docs.aws.amazon.com/opensearch-service/)
- [Temporal Visibility Store Configuration](https://docs.temporal.io/visibility)
- [OpenSearch Instance Types](https://aws.amazon.com/opensearch-service/pricing/)

### Code References
- `terraform/` - Infrastructure configuration
- `docker/config/` - Application configuration templates
- `.env.integration` - Environment variable configuration

---

**Next Actions:**
1. **Tomorrow Morning**: Update Terraform configuration for provisioned OpenSearch
2. **Tomorrow Afternoon**: Test deployment and validate connectivity
3. **Follow-up**: Integration testing with Temporal visibility operations

**Assigned To:** Infrastructure Team  
**Dependencies:** Complete after DSQL locking issue resolution  
**Last Updated:** 2024-12-30