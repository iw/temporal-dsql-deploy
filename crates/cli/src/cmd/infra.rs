use std::collections::HashMap;
use std::io::{self, Write};
use std::time::Duration;

use aws_sdk_dsql::client::Waiters;
use clap::Subcommand;
use eyre::{Result, bail};
use toml_edit::value;

use crate::paths;

#[derive(Debug, Subcommand)]
pub enum InfraAction {
    /// Provision DSQL cluster and DynamoDB tables
    Apply,
    /// Destroy provisioned resources
    Destroy,
    /// Show status of provisioned resources
    Status,
}

pub fn infra(action: InfraAction) -> Result<()> {
    let rt = tokio::runtime::Runtime::new()?;
    rt.block_on(async {
        match action {
            InfraAction::Apply => apply().await,
            InfraAction::Destroy => destroy().await,
            InfraAction::Status => status().await,
        }
    })
}

// ─── Resource naming ────────────────────────────────────────────────────────

/// Derive the DSQL cluster name from the project name.
pub fn cluster_name(project: &str) -> String {
    format!("{project}-dsql")
}

/// Derive the rate limiter DynamoDB table name from the project name.
pub fn rate_limiter_table_name(project: &str) -> String {
    format!("{project}-dsql-rate-limiter")
}

/// Derive the conn lease DynamoDB table name from the project name.
pub fn conn_lease_table_name(project: &str) -> String {
    format!("{project}-dsql-conn-lease")
}

/// Build standard resource tags.
fn resource_tags(project: &str) -> HashMap<String, String> {
    HashMap::from([
        ("Name".into(), cluster_name(project)),
        ("Project".into(), project.into()),
        ("ManagedBy".into(), "dsqld-cli".into()),
    ])
}

// ─── Apply ──────────────────────────────────────────────────────────────────

async fn apply() -> Result<()> {
    let config = dsqld_config::load_config(&paths::config_file())?;
    let project = &config.project.name;
    let region = &config.project.region;

    let sdk_config = aws_config::defaults(aws_config::BehaviorVersion::latest())
        .region(aws_config::Region::new(region.clone()))
        .load()
        .await;

    let dsql_client = aws_sdk_dsql::Client::new(&sdk_config);
    let ddb_client = aws_sdk_dynamodb::Client::new(&sdk_config);

    // 1. Resolve DSQL cluster
    let derived_name = cluster_name(project);
    let cluster_id = if !config.dsql.identifier.is_empty() {
        // Identifier already in config — verify the cluster exists and its Name tag matches.
        let id = &config.dsql.identifier;
        eprintln!("▸ DSQL cluster in config: {id}");
        let detail = client_get_cluster(&dsql_client, id).await?;
        let tag_name = detail
            .tags()
            .and_then(|t| t.get("Name"))
            .cloned()
            .unwrap_or_default();
        if tag_name != derived_name {
            eprintln!("  warning: cluster Name tag is '{tag_name}', expected '{derived_name}'");
        }
        eprintln!("  verified: {} ({})", id, detail.status().as_str());
        id.clone()
    } else {
        // No identifier in config — try to discover by Name tag, else create
        match find_cluster_by_name(&dsql_client, &derived_name).await? {
            Some(id) => {
                eprintln!("▸ discovered existing DSQL cluster '{id}' (Name={derived_name})");
                id
            }
            None => {
                eprintln!("▸ creating DSQL cluster '{derived_name}'…");
                create_dsql_cluster(&dsql_client, project).await?
            }
        }
    };

    let detail = client_get_cluster(&dsql_client, &cluster_id).await?;
    let endpoint = detail.endpoint().unwrap_or_default();
    eprintln!("  endpoint: {endpoint}");

    // 2. Create DynamoDB tables (idempotent — adopts existing)
    let rate_table = rate_limiter_table_name(project);
    let lease_table = conn_lease_table_name(project);

    eprintln!("▸ creating DynamoDB table '{rate_table}'…");
    create_dynamodb_table(&ddb_client, &rate_table, project).await?;

    eprintln!("▸ creating DynamoDB table '{lease_table}'…");
    create_dynamodb_table(&ddb_client, &lease_table, project).await?;

    // 3. Write provisioned identifiers back to config.toml
    write_infra_to_config(&cluster_id, &rate_table, &lease_table)?;
    eprintln!(
        "▸ wrote dsql.identifier + DynamoDB table names to {}",
        paths::config_file().display()
    );

    eprintln!("\n✓ infrastructure provisioned");
    Ok(())
}

/// Create a DSQL cluster with deletion protection and tags, wait for ACTIVE
/// using the SDK waiter, return the cluster identifier.
async fn create_dsql_cluster(client: &aws_sdk_dsql::Client, project: &str) -> Result<String> {
    let tags = resource_tags(project);

    let create_output = client
        .create_cluster()
        .set_tags(Some(tags))
        .deletion_protection_enabled(true)
        .send()
        .await
        .map_err(|e| classify_aws_error("dsql:CreateCluster", e.into_service_error()))?;

    let cluster_id = create_output.identifier().to_string();
    eprintln!("  cluster id: {cluster_id}");
    eprintln!("  waiting for cluster to become ACTIVE…");

    // Use SDK waiter — polls GetCluster until status is ACTIVE (up to 10 min)
    client
        .wait_until_cluster_active()
        .identifier(&cluster_id)
        .wait(Duration::from_secs(600))
        .await
        .map_err(|e| eyre::eyre!("waiting for DSQL cluster to become ACTIVE: {e}"))?
        .into_result()
        .map_err(|e| eyre::eyre!("DSQL cluster did not reach ACTIVE state: {e}"))?;

    Ok(cluster_id)
}

/// Create a DynamoDB table with pk (String HASH), on-demand billing, and TTL
/// on `ttl_epoch`. Idempotent — adopts existing tables gracefully.
async fn create_dynamodb_table(
    client: &aws_sdk_dynamodb::Client,
    table_name: &str,
    project: &str,
) -> Result<()> {
    let table_arn = match client
        .create_table()
        .table_name(table_name)
        .key_schema(
            aws_sdk_dynamodb::types::KeySchemaElement::builder()
                .attribute_name("pk")
                .key_type(aws_sdk_dynamodb::types::KeyType::Hash)
                .build()
                .expect("key schema is valid"),
        )
        .attribute_definitions(
            aws_sdk_dynamodb::types::AttributeDefinition::builder()
                .attribute_name("pk")
                .attribute_type(aws_sdk_dynamodb::types::ScalarAttributeType::S)
                .build()
                .expect("attribute definition is valid"),
        )
        .billing_mode(aws_sdk_dynamodb::types::BillingMode::PayPerRequest)
        .send()
        .await
    {
        Ok(output) => {
            let arn = output
                .table_description()
                .and_then(|t| t.table_arn())
                .unwrap_or_default()
                .to_string();
            eprintln!("  created: {arn}");
            arn
        }
        Err(e) => {
            let svc_err = e.into_service_error();
            if svc_err.is_resource_in_use_exception() {
                eprintln!("  table already exists, adopting");
                let desc = client
                    .describe_table()
                    .table_name(table_name)
                    .send()
                    .await
                    .map_err(|e| {
                        classify_aws_error("dynamodb:DescribeTable", e.into_service_error())
                    })?;
                desc.table()
                    .and_then(|t| t.table_arn())
                    .unwrap_or_default()
                    .to_string()
            } else {
                return Err(classify_aws_error("dynamodb:CreateTable", svc_err));
            }
        }
    };

    // Wait for table to become ACTIVE before enabling TTL.
    // DynamoDB returns from CreateTable before the table is fully ready.
    wait_for_table_active(client, table_name).await?;

    // Enable TTL on ttl_epoch. Check current status first to avoid
    // ValidationException when adopting a table that already has TTL enabled.
    if should_enable_ttl(client, table_name).await? {
        enable_ttl(client, table_name).await?;
    } else {
        eprintln!("  TTL already enabled");
    }

    // Tag the table
    let tags: Vec<aws_sdk_dynamodb::types::Tag> = resource_tags(project)
        .into_iter()
        .map(|(k, v)| {
            aws_sdk_dynamodb::types::Tag::builder()
                .key(k)
                .value(v)
                .build()
                .expect("tag is valid")
        })
        .collect();

    client
        .tag_resource()
        .resource_arn(&table_arn)
        .set_tags(Some(tags))
        .send()
        .await
        .map_err(|e| classify_aws_error("dynamodb:TagResource", e.into_service_error()))?;

    Ok(())
}

/// Poll DescribeTable until the table status is ACTIVE (up to 60s).
/// Tolerates ResourceNotFoundException right after CreateTable (eventual consistency).
async fn wait_for_table_active(client: &aws_sdk_dynamodb::Client, table_name: &str) -> Result<()> {
    for _ in 0..30 {
        match client.describe_table().table_name(table_name).send().await {
            Ok(resp) => {
                let status = resp
                    .table()
                    .and_then(|t| t.table_status())
                    .map(|s| s.as_str().to_string())
                    .unwrap_or_default();

                if status == "ACTIVE" {
                    return Ok(());
                }
            }
            Err(e) => {
                let svc_err = e.into_service_error();
                if svc_err.is_resource_not_found_exception() {
                    // Table not yet visible — retry
                } else {
                    return Err(classify_aws_error("dynamodb:DescribeTable", svc_err));
                }
            }
        }

        tokio::time::sleep(Duration::from_secs(2)).await;
    }
    bail!("DynamoDB table '{table_name}' did not become ACTIVE within 60s");
}

/// Check whether TTL needs to be enabled on a table. Returns `true` if TTL is
/// `Disabled` or not yet configured. Retries on `ResourceNotFoundException`
/// (eventual consistency after table creation).
async fn should_enable_ttl(client: &aws_sdk_dynamodb::Client, table_name: &str) -> Result<bool> {
    for attempt in 0..10 {
        match client
            .describe_time_to_live()
            .table_name(table_name)
            .send()
            .await
        {
            Ok(resp) => {
                let status = resp
                    .time_to_live_description()
                    .and_then(|d| d.time_to_live_status());
                return Ok(!matches!(
                    status,
                    Some(
                        aws_sdk_dynamodb::types::TimeToLiveStatus::Enabled
                            | aws_sdk_dynamodb::types::TimeToLiveStatus::Enabling
                    )
                ));
            }
            Err(e) => {
                let svc_err = e.into_service_error();
                if svc_err.is_resource_not_found_exception() && attempt < 9 {
                    tokio::time::sleep(Duration::from_secs(2)).await;
                    continue;
                }
                return Err(classify_aws_error("dynamodb:DescribeTimeToLive", svc_err));
            }
        }
    }
    // Unreachable — loop always returns or errors on last attempt
    bail!("failed to describe TTL for '{table_name}' after retries");
}

/// Enable TTL on `ttl_epoch`. Retries on `ResourceNotFoundException`.
async fn enable_ttl(client: &aws_sdk_dynamodb::Client, table_name: &str) -> Result<()> {
    for attempt in 0..10 {
        match client
            .update_time_to_live()
            .table_name(table_name)
            .time_to_live_specification(
                aws_sdk_dynamodb::types::TimeToLiveSpecification::builder()
                    .attribute_name("ttl_epoch")
                    .enabled(true)
                    .build()
                    .expect("ttl spec is valid"),
            )
            .send()
            .await
        {
            Ok(_) => return Ok(()),
            Err(e) => {
                let svc_err = e.into_service_error();
                if svc_err.is_resource_not_found_exception() && attempt < 9 {
                    tokio::time::sleep(Duration::from_secs(2)).await;
                    continue;
                }
                return Err(classify_aws_error("dynamodb:UpdateTimeToLive", svc_err));
            }
        }
    }
    bail!("failed to enable TTL for '{table_name}' after retries");
}

/// Write provisioned resource identifiers back into config.toml:
/// - `dsql.identifier` — the DSQL cluster ID
/// - `dsql.rate_coordination.table_name` — rate limiter DynamoDB table
/// - `dsql.conn_lease.table_name` — connection lease DynamoDB table
/// - `dynamodb.rate_limiter_table` / `dynamodb.conn_lease_table` — mirrors
fn write_infra_to_config(identifier: &str, rate_table: &str, lease_table: &str) -> Result<()> {
    let path = paths::config_file();
    let contents = std::fs::read_to_string(&path)
        .map_err(|_| eyre::eyre!("could not read {}", path.display()))?;

    let updated = update_infra_config_toml(&contents, identifier, rate_table, lease_table)?;
    std::fs::write(&path, updated)?;
    Ok(())
}

fn update_infra_config_toml(
    contents: &str,
    identifier: &str,
    rate_table: &str,
    lease_table: &str,
) -> Result<String> {
    let mut doc = contents
        .parse::<toml_edit::DocumentMut>()
        .map_err(|e| eyre::eyre!("failed to parse config.toml as TOML document: {e}"))?;

    doc["dsql"]["identifier"] = value(identifier);
    doc["dsql"]["rate_coordination"]["table_name"] = value(rate_table);
    doc["dsql"]["conn_lease"]["table_name"] = value(lease_table);
    doc["dynamodb"]["rate_limiter_table"] = value(rate_table);
    doc["dynamodb"]["conn_lease_table"] = value(lease_table);

    Ok(doc.to_string())
}

// ─── Destroy ────────────────────────────────────────────────────────────────

async fn destroy() -> Result<()> {
    let config = dsqld_config::load_config(&paths::config_file())?;
    let project = &config.project.name;
    let region = &config.project.region;

    // Require explicit confirmation
    eprint!(
        "This will destroy all infrastructure for project '{project}'.\n\
         Type the project name to confirm: "
    );
    io::stderr().flush()?;

    let mut input = String::new();
    io::stdin().read_line(&mut input)?;
    let input = input.trim();

    if input != project.as_str() {
        bail!("confirmation failed — expected '{project}', got '{input}'");
    }

    let sdk_config = aws_config::defaults(aws_config::BehaviorVersion::latest())
        .region(aws_config::Region::new(region.clone()))
        .load()
        .await;

    let dsql_client = aws_sdk_dsql::Client::new(&sdk_config);
    let ddb_client = aws_sdk_dynamodb::Client::new(&sdk_config);

    // 1. Delete DynamoDB tables
    let rate_table = table_name_for_destroy(
        &config.dsql.rate_coordination.table_name,
        &config.dynamodb.rate_limiter_table,
        &rate_limiter_table_name(project),
    );
    let lease_table = table_name_for_destroy(
        &config.dsql.conn_lease.table_name,
        &config.dynamodb.conn_lease_table,
        &conn_lease_table_name(project),
    );

    eprintln!("▸ deleting DynamoDB table '{rate_table}'…");
    delete_dynamodb_table(&ddb_client, &rate_table).await?;

    eprintln!("▸ deleting DynamoDB table '{lease_table}'…");
    delete_dynamodb_table(&ddb_client, &lease_table).await?;

    // 2. Find and delete DSQL cluster
    let cluster_id = if !config.dsql.identifier.is_empty() {
        eprintln!("▸ DSQL cluster from config: {}", config.dsql.identifier);
        Some(config.dsql.identifier.clone())
    } else {
        let derived_name = cluster_name(project);
        eprintln!("▸ looking up DSQL cluster by Name tag '{derived_name}'…");
        find_cluster_by_name(&dsql_client, &derived_name).await?
    };

    match cluster_id {
        Some(cluster_id) => {
            // Disable deletion protection before deleting
            eprintln!("▸ disabling deletion protection on cluster '{cluster_id}'…");
            dsql_client
                .update_cluster()
                .identifier(&cluster_id)
                .deletion_protection_enabled(false)
                .send()
                .await
                .map_err(|e| classify_aws_error("dsql:UpdateCluster", e.into_service_error()))?;

            eprintln!("▸ deleting DSQL cluster '{cluster_id}'…");
            dsql_client
                .delete_cluster()
                .identifier(&cluster_id)
                .send()
                .await
                .map_err(|e| classify_aws_error("dsql:DeleteCluster", e.into_service_error()))?;

            // Use SDK waiter for deletion polling
            eprintln!("  waiting for cluster deletion…");
            dsql_client
                .wait_until_cluster_not_exists()
                .identifier(&cluster_id)
                .wait(Duration::from_secs(600))
                .await
                .map_err(|e| eyre::eyre!("waiting for DSQL cluster deletion: {e}"))?;
        }
        None => {
            eprintln!("  no matching cluster found — may have been deleted already");
        }
    }

    eprintln!("\n✓ infrastructure destroyed");
    Ok(())
}

fn table_name_for_destroy(dsql_table: &str, dynamodb_table: &str, derived_table: &str) -> String {
    if !dsql_table.is_empty() {
        return dsql_table.to_string();
    }
    if !dynamodb_table.is_empty() {
        return dynamodb_table.to_string();
    }
    derived_table.to_string()
}

/// Delete a DynamoDB table, handling not-found gracefully.
async fn delete_dynamodb_table(client: &aws_sdk_dynamodb::Client, table_name: &str) -> Result<()> {
    match client.delete_table().table_name(table_name).send().await {
        Ok(_) => {
            eprintln!("  deleted");
            Ok(())
        }
        Err(e) => {
            let svc_err = e.into_service_error();
            if svc_err.is_resource_not_found_exception() {
                eprintln!("  table not found, skipping");
                Ok(())
            } else {
                Err(classify_aws_error("dynamodb:DeleteTable", svc_err))
            }
        }
    }
}

/// Call GetCluster by identifier, returning the full output.
async fn client_get_cluster(
    client: &aws_sdk_dsql::Client,
    identifier: &str,
) -> Result<aws_sdk_dsql::operation::get_cluster::GetClusterOutput> {
    client
        .get_cluster()
        .identifier(identifier)
        .send()
        .await
        .map_err(|e| classify_aws_error("dsql:GetCluster", e.into_service_error()))
}

/// Find an ACTIVE DSQL cluster by its `Name` tag. Lists all clusters, calls
/// GetCluster on each to inspect tags (ClusterSummary doesn't include tags).
/// Returns the cluster identifier if found.
async fn find_cluster_by_name(client: &aws_sdk_dsql::Client, name: &str) -> Result<Option<String>> {
    let mut paginator = client.list_clusters().into_paginator().send();

    while let Some(page) = paginator.next().await {
        let page =
            page.map_err(|e| classify_aws_error("dsql:ListClusters", e.into_service_error()))?;
        for summary in page.clusters() {
            let cluster_id = summary.identifier.as_str();
            match client.get_cluster().identifier(cluster_id).send().await {
                Ok(detail) => {
                    // Only adopt ACTIVE clusters
                    if detail.status() != &aws_sdk_dsql::types::ClusterStatus::Active {
                        continue;
                    }
                    let matches = detail
                        .tags()
                        .and_then(|tags| tags.get("Name"))
                        .is_some_and(|v| v == name);
                    if matches {
                        return Ok(Some(cluster_id.to_string()));
                    }
                }
                Err(e) => {
                    let svc_err = e.into_service_error();
                    // Skip clusters that vanish between list and get
                    if !svc_err.is_resource_not_found_exception() {
                        return Err(classify_aws_error("dsql:GetCluster", svc_err));
                    }
                }
            }
        }
    }

    Ok(None)
}

// ─── Status ─────────────────────────────────────────────────────────────────

async fn status() -> Result<()> {
    let config = dsqld_config::load_config(&paths::config_file())?;
    let project = &config.project.name;
    let region = &config.project.region;

    let sdk_config = aws_config::defaults(aws_config::BehaviorVersion::latest())
        .region(aws_config::Region::new(region.clone()))
        .load()
        .await;

    let dsql_client = aws_sdk_dsql::Client::new(&sdk_config);
    let ddb_client = aws_sdk_dynamodb::Client::new(&sdk_config);

    eprintln!("project: {project}");
    eprintln!("region:  {region}\n");

    // DSQL cluster status
    if !config.dsql.identifier.is_empty() {
        let id = &config.dsql.identifier;
        match client_get_cluster(&dsql_client, id).await {
            Ok(detail) => {
                let endpoint = detail.endpoint().unwrap_or_default();
                eprintln!("dsql cluster:  {id} ({})", detail.status().as_str());
                eprintln!("dsql endpoint: {endpoint}");
            }
            Err(e) => {
                eprintln!("dsql cluster:  {id} (error: {e})");
            }
        }
    } else {
        let derived_name = cluster_name(project);
        match find_cluster_by_name(&dsql_client, &derived_name).await? {
            Some(id) => {
                let detail = client_get_cluster(&dsql_client, &id).await?;
                let endpoint = detail.endpoint().unwrap_or_default();
                eprintln!("dsql cluster:  {id} (ACTIVE, endpoint: {endpoint})");
                eprintln!(
                    "  hint: run `dsqld infra apply` to populate dsql.identifier in config.toml"
                );
            }
            None => {
                eprintln!(
                    "dsql cluster: not provisioned (no identifier in config, no cluster with Name={derived_name})"
                );
            }
        }
    }

    // DynamoDB table status
    eprintln!();
    describe_dynamodb_table(&ddb_client, &rate_limiter_table_name(project)).await?;
    describe_dynamodb_table(&ddb_client, &conn_lease_table_name(project)).await?;

    Ok(())
}

/// Print the status of a DynamoDB table.
async fn describe_dynamodb_table(
    client: &aws_sdk_dynamodb::Client,
    table_name: &str,
) -> Result<()> {
    match client.describe_table().table_name(table_name).send().await {
        Ok(resp) => {
            let status = resp
                .table()
                .and_then(|t| t.table_status())
                .map(|s| s.as_str().to_string())
                .unwrap_or_else(|| "UNKNOWN".into());
            let item_count = resp.table().and_then(|t| t.item_count()).unwrap_or(0);
            eprintln!("dynamodb table: {table_name} ({status}, {item_count} items)");
        }
        Err(e) => {
            let svc_err = e.into_service_error();
            if svc_err.is_resource_not_found_exception() {
                eprintln!("dynamodb table: {table_name} (not found)");
            } else {
                return Err(classify_aws_error("dynamodb:DescribeTable", svc_err));
            }
        }
    }
    Ok(())
}

// ─── Error classification ───────────────────────────────────────────────────

/// Classify an AWS SDK service error into a user-friendly eyre error.
/// Provides remediation hints for permission errors.
fn classify_aws_error<E: std::fmt::Display>(operation: &str, err: E) -> eyre::Report {
    let msg = err.to_string();

    if msg.contains("AccessDenied")
        || msg.contains("UnauthorizedAccess")
        || msg.contains("not authorized")
        || msg.contains("AccessDeniedException")
    {
        eyre::eyre!(
            "{operation} failed: {msg}\n\n\
             hint: check that your AWS credentials have the required permissions.\n\
             For DSQL: dsql:CreateCluster, dsql:GetCluster, dsql:DeleteCluster, \
             dsql:UpdateCluster, dsql:ListClusters\n\
             For DynamoDB: dynamodb:CreateTable, dynamodb:DeleteTable, \
             dynamodb:DescribeTable, dynamodb:UpdateTimeToLive, dynamodb:TagResource"
        )
    } else {
        eyre::eyre!("{operation} failed: {msg}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn destroy_prefers_dsql_table_name_from_config() {
        let selected = table_name_for_destroy("configured-dsql", "configured-ddb", "derived");
        assert_eq!(selected, "configured-dsql");
    }

    #[test]
    fn destroy_falls_back_to_dynamodb_then_derived() {
        let selected = table_name_for_destroy("", "configured-ddb", "derived");
        assert_eq!(selected, "configured-ddb");

        let selected = table_name_for_destroy("", "", "derived");
        assert_eq!(selected, "derived");
    }

    #[test]
    fn infra_config_update_preserves_comments_and_unknown_fields() {
        let original = r#"# keep this comment
[project]
name = "dev"
region = "eu-west-1"

[dsql]
identifier = ""

[dsql.rate_coordination]
table_name = ""

[dsql.conn_lease]
table_name = ""

[dynamodb]
rate_limiter_table = ""
conn_lease_table = ""

[custom]
flag = true
"#;

        let updated = update_infra_config_toml(original, "cluster-1", "rate-1", "lease-1")
            .expect("update should succeed");

        assert!(updated.contains("# keep this comment"));
        assert!(updated.contains("[custom]"));
        assert!(updated.contains("flag = true"));

        let parsed: dsqld_config::ProjectConfig =
            toml::from_str(&updated).expect("updated config should parse");
        assert_eq!(parsed.dsql.identifier, "cluster-1");
        assert_eq!(parsed.dsql.rate_coordination.table_name, "rate-1");
        assert_eq!(parsed.dsql.conn_lease.table_name, "lease-1");
        assert_eq!(parsed.dynamodb.rate_limiter_table, "rate-1");
        assert_eq!(parsed.dynamodb.conn_lease_table, "lease-1");
    }
}
