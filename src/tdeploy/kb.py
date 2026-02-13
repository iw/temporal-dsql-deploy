"""Knowledge Base commands — sync RAG corpus and trigger ingestion."""

import os
import time
from pathlib import Path
from typing import Annotated

import boto3
import typer
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

from tdeploy.paths import repo_root, terraform_dir
from tdeploy.terraform import has_state, tf_output

app = typer.Typer(no_args_is_help=True)
console = Console()

DEFAULT_RAG_SOURCE = "../temporal-sre-copilot/docs/rag"


def _get_copilot_outputs() -> dict:
    """Get terraform outputs from the copilot module."""
    copilot_dir = terraform_dir("copilot")
    if not has_state(copilot_dir):
        console.print("[red]Error:[/red] No copilot terraform state found.")
        console.print("Run [cyan]uv run tdeploy infra apply-copilot[/cyan] first.")
        raise typer.Exit(1)
    return tf_output(copilot_dir)


def _region() -> str:
    return os.environ.get("AWS_REGION", "eu-west-1")


def _resolve_source(source: str) -> Path:
    """Resolve source directory path."""
    p = Path(source)
    return p.resolve() if p.is_absolute() else (repo_root() / source).resolve()


def _resolve_outputs(kb_id: str = "", ds_id: str = "", bucket: str = "") -> dict:
    """Resolve KB/DS/bucket from args or terraform outputs."""
    if kb_id and ds_id and bucket:
        return {"knowledge_base_id": kb_id, "data_source_id": ds_id, "kb_source_bucket": bucket}
    outputs = _get_copilot_outputs()
    return {
        "knowledge_base_id": kb_id or outputs.get("knowledge_base_id", ""),
        "data_source_id": ds_id or outputs.get("data_source_id", ""),
        "kb_source_bucket": bucket or outputs.get("kb_source_bucket", ""),
    }


def _sync_docs(bucket: str, source: Path, region: str) -> None:
    """Upload markdown files from source directory to S3."""
    if not source.exists():
        console.print(f"[red]Error:[/red] Source directory not found: {source}")
        raise typer.Exit(1)

    md_files = list(source.rglob("*.md"))
    if not md_files:
        console.print(f"[yellow]No markdown files found in {source}[/yellow]")
        return

    console.print(f"  Bucket: [cyan]{bucket}[/cyan]")
    console.print(f"  Source: [cyan]{source}[/cyan]")
    console.print(f"  Files:  [cyan]{len(md_files)}[/cyan]")
    console.print()

    s3 = boto3.client("s3", region_name=region)
    uploaded = 0
    for md_file in md_files:
        key = str(md_file.relative_to(source))
        try:
            s3.upload_file(str(md_file), bucket, key)
            uploaded += 1
            console.print(f"  [green]✓[/green] {key}")
        except Exception as e:
            console.print(f"  [red]✗[/red] {key}: {e}")

    console.print()
    console.print(f"[green]✓[/green] Uploaded {uploaded}/{len(md_files)} files to s3://{bucket}")


def _start_ingestion(kb_id: str, ds_id: str, region: str) -> str:
    """Start an ingestion job and return the job ID."""
    console.print(f"  Knowledge Base: [cyan]{kb_id}[/cyan]")
    console.print(f"  Data Source:    [cyan]{ds_id}[/cyan]")
    console.print()

    bedrock = boto3.client("bedrock-agent", region_name=region)
    with console.status("[bold green]Starting ingestion..."):
        try:
            resp = bedrock.start_ingestion_job(
                knowledgeBaseId=kb_id, dataSourceId=ds_id,
            )
            job_id = resp["ingestionJob"]["ingestionJobId"]
        except Exception as e:
            console.print(f"[red]Error:[/red] {e}")
            raise typer.Exit(1)

    console.print(f"[green]✓[/green] Ingestion job started: [cyan]{job_id}[/cyan]")
    return job_id


def _wait_for_ingestion(kb_id: str, ds_id: str, job_id: str, region: str) -> None:
    """Poll until ingestion completes."""
    bedrock = boto3.client("bedrock-agent", region_name=region)
    with console.status("[bold green]Waiting for ingestion to complete..."):
        while True:
            time.sleep(5)
            try:
                resp = bedrock.get_ingestion_job(
                    knowledgeBaseId=kb_id, dataSourceId=ds_id, ingestionJobId=job_id,
                )
                job = resp["ingestionJob"]
                st = job["status"]

                if st == "COMPLETE":
                    stats = job.get("statistics", {})
                    scanned = stats.get("numberOfDocumentsScanned", 0)
                    new_indexed = stats.get("numberOfNewDocumentsIndexed", 0)
                    modified = stats.get("numberOfModifiedDocumentsIndexed", 0)
                    deleted = stats.get("numberOfDocumentsDeleted", 0)
                    failed = stats.get("numberOfDocumentsFailed", 0)
                    total_indexed = new_indexed + modified

                    console.print()
                    console.print(f"[green]✓[/green] Ingestion complete")
                    console.print(f"  Scanned:    {scanned}")
                    console.print(f"  New:        {new_indexed}")
                    console.print(f"  Modified:   {modified}")
                    if deleted:
                        console.print(f"  Deleted:    {deleted}")
                    console.print(f"  Failed:     {failed}")

                    if scanned > 0 and total_indexed == 0 and failed == 0:
                        console.print(
                            "\n  [dim]All documents unchanged since last ingestion — nothing to re-index.[/dim]"
                        )
                    return

                if st == "FAILED":
                    console.print()
                    console.print(f"[red]✗[/red] Ingestion failed")
                    for reason in job.get("failureReasons", ["Unknown"]):
                        console.print(f"  {reason}")
                    raise typer.Exit(1)

            except typer.Exit:
                raise
            except Exception as e:
                console.print(f"\n[red]Error polling status:[/red] {e}")
                raise typer.Exit(1)


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


@app.command()
def populate(
    source: Annotated[
        str, typer.Option("--source", "-s", help="Path to RAG docs directory")
    ] = DEFAULT_RAG_SOURCE,
    bucket: Annotated[
        str, typer.Option("--bucket", "-b", help="S3 bucket (default: from terraform)")
    ] = "",
    kb_id: Annotated[
        str, typer.Option("--kb-id", "-k", help="Knowledge Base ID (default: from terraform)")
    ] = "",
    ds_id: Annotated[
        str, typer.Option("--ds-id", "-d", help="Data Source ID (default: from terraform)")
    ] = "",
    region: Annotated[str, typer.Option("--region", "-r", help="AWS region")] = "",
) -> None:
    """One-shot: sync docs to S3, trigger ingestion, wait for completion."""
    console.print(Panel.fit("Knowledge Base \u2014 Populate", style="bold blue"))

    aws_region = region or _region()
    resolved = _resolve_outputs(kb_id, ds_id, bucket)
    target_bucket = resolved["kb_source_bucket"]
    knowledge_base_id = resolved["knowledge_base_id"]
    data_source_id = resolved["data_source_id"]

    if not target_bucket:
        console.print("[red]Error:[/red] No bucket. Use --bucket or run apply-copilot first.")
        raise typer.Exit(1)
    if not knowledge_base_id or not data_source_id:
        console.print("[red]Error:[/red] Missing KB or data source ID. Use --kb-id/--ds-id or run apply-copilot.")
        raise typer.Exit(1)

    source_dir = _resolve_source(source)

    console.print("[bold]Step 1/3:[/bold] Syncing documents to S3\n")
    _sync_docs(target_bucket, source_dir, aws_region)

    console.print("\n[bold]Step 2/3:[/bold] Starting ingestion\n")
    job_id = _start_ingestion(knowledge_base_id, data_source_id, aws_region)

    console.print("\n[bold]Step 3/3:[/bold] Waiting for ingestion\n")
    _wait_for_ingestion(knowledge_base_id, data_source_id, job_id, aws_region)


@app.command()
def sync(
    source: Annotated[
        str, typer.Option("--source", "-s", help="Path to RAG docs directory")
    ] = DEFAULT_RAG_SOURCE,
    bucket: Annotated[
        str, typer.Option("--bucket", "-b", help="S3 bucket (default: from terraform)")
    ] = "",
    region: Annotated[str, typer.Option("--region", "-r", help="AWS region")] = "",
) -> None:
    """Upload RAG corpus to the Knowledge Base source bucket."""
    console.print(Panel.fit("Knowledge Base \u2014 Sync Documents", style="bold blue"))

    aws_region = region or _region()
    target_bucket = bucket or _resolve_outputs(bucket=bucket)["kb_source_bucket"]
    if not target_bucket:
        console.print("[red]Error:[/red] No bucket. Use --bucket or run apply-copilot first.")
        raise typer.Exit(1)

    _sync_docs(target_bucket, _resolve_source(source), aws_region)


@app.command()
def ingest(
    kb_id: Annotated[
        str, typer.Option("--kb-id", "-k", help="Knowledge Base ID (default: from terraform)")
    ] = "",
    ds_id: Annotated[
        str, typer.Option("--ds-id", "-d", help="Data Source ID (default: from terraform)")
    ] = "",
    region: Annotated[str, typer.Option("--region", "-r", help="AWS region")] = "",
) -> None:
    """Trigger Knowledge Base ingestion (indexes documents into S3 Vectors)."""
    console.print(Panel.fit("Knowledge Base \u2014 Start Ingestion", style="bold blue"))

    aws_region = region or _region()
    resolved = _resolve_outputs(kb_id, ds_id)
    knowledge_base_id = resolved["knowledge_base_id"]
    data_source_id = resolved["data_source_id"]

    if not knowledge_base_id or not data_source_id:
        console.print("[red]Error:[/red] Missing KB or data source ID. Use --kb-id/--ds-id or run apply-copilot.")
        raise typer.Exit(1)

    _start_ingestion(knowledge_base_id, data_source_id, aws_region)
    console.print("\nCheck status with: [cyan]uv run tdeploy kb status[/cyan]")


@app.command()
def status(
    kb_id: Annotated[
        str, typer.Option("--kb-id", "-k", help="Knowledge Base ID (default: from terraform)")
    ] = "",
    region: Annotated[str, typer.Option("--region", "-r", help="AWS region")] = "",
) -> None:
    """Check Knowledge Base status and recent ingestion jobs."""
    console.print(Panel.fit("Knowledge Base \u2014 Status", style="bold blue"))

    aws_region = region or _region()
    resolved = _resolve_outputs(kb_id)
    knowledge_base_id = resolved["knowledge_base_id"]
    data_source_id = resolved["data_source_id"]

    if not knowledge_base_id:
        console.print("[red]Error:[/red] No KB ID. Use --kb-id or run apply-copilot first.")
        raise typer.Exit(1)

    bedrock = boto3.client("bedrock-agent", region_name=aws_region)

    try:
        resp = bedrock.get_knowledge_base(knowledgeBaseId=knowledge_base_id)
        kb = resp["knowledgeBase"]
        console.print(f"  Name:   [cyan]{kb['name']}[/cyan]")
        console.print(f"  Status: [cyan]{kb['status']}[/cyan]")
        console.print(f"  ID:     {knowledge_base_id}")
    except Exception as e:
        console.print(f"[red]Error getting KB status:[/red] {e}")
        raise typer.Exit(1)

    if data_source_id:
        console.print()
        try:
            resp = bedrock.list_ingestion_jobs(
                knowledgeBaseId=knowledge_base_id,
                dataSourceId=data_source_id,
                maxResults=5,
            )
            job_list = resp.get("ingestionJobSummaries", [])
            if job_list:
                table = Table(title="Recent Ingestion Jobs")
                table.add_column("Job ID", style="cyan")
                table.add_column("Status")
                table.add_column("Started")
                for job in job_list:
                    st = {"COMPLETE": "green", "IN_PROGRESS": "yellow", "FAILED": "red"}.get(
                        job["status"], "white"
                    )
                    table.add_row(
                        job["ingestionJobId"],
                        f"[{st}]{job['status']}[/{st}]",
                        str(job.get("startedAt", "")),
                    )
                console.print(table)
            else:
                console.print("  [yellow]No ingestion jobs yet.[/yellow]")
        except Exception as e:
            console.print(f"  [dim]Could not list jobs: {e}[/dim]")


@app.command()
def jobs(
    kb_id: Annotated[str, typer.Option("--kb-id", "-k", help="Knowledge Base ID")] = "",
    ds_id: Annotated[str, typer.Option("--ds-id", "-d", help="Data Source ID")] = "",
    region: Annotated[str, typer.Option("--region", "-r", help="AWS region")] = "",
    limit: Annotated[int, typer.Option("--limit", "-l", help="Max jobs to show")] = 10,
) -> None:
    """List recent ingestion jobs."""
    console.print(Panel.fit("Recent Ingestion Jobs", style="bold blue"))

    aws_region = region or _region()
    resolved = _resolve_outputs(kb_id, ds_id)
    knowledge_base_id = resolved["knowledge_base_id"]
    data_source_id = resolved["data_source_id"]

    if not knowledge_base_id or not data_source_id:
        console.print("[red]Error:[/red] Missing KB or data source ID. Use --kb-id/--ds-id or run apply-copilot.")
        raise typer.Exit(1)

    bedrock = boto3.client("bedrock-agent", region_name=aws_region)
    try:
        resp = bedrock.list_ingestion_jobs(
            knowledgeBaseId=knowledge_base_id,
            dataSourceId=data_source_id,
            maxResults=limit,
        )
        job_list = resp.get("ingestionJobSummaries", [])
    except Exception as e:
        console.print(f"[red]Error:[/red] {e}")
        raise typer.Exit(1)

    if not job_list:
        console.print("[yellow]No ingestion jobs found.[/yellow]")
        return

    table = Table()
    table.add_column("Job ID", style="cyan")
    table.add_column("Status")
    table.add_column("Started")
    for job in job_list:
        st = {"COMPLETE": "green", "IN_PROGRESS": "yellow", "FAILED": "red"}.get(
            job["status"], "white"
        )
        table.add_row(
            job["ingestionJobId"],
            f"[{st}]{job['status']}[/{st}]",
            str(job.get("startedAt", "")),
        )
    console.print(table)
