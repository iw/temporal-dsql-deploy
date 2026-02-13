"""Schema commands — DSQL schema setup and management."""

import os
import subprocess
from pathlib import Path
from typing import Annotated

import boto3
import typer
from rich.console import Console
from rich.panel import Panel

from tdeploy.env import load_profile_env

app = typer.Typer(no_args_is_help=True)
console = Console()

DEFAULT_TOOL_PATH = "../temporal-dsql/temporal-dsql-tool"
SCHEMA_NAME = "dsql/temporal"


def _find_tool(tool_path: str) -> Path:
    """Locate the temporal-dsql-tool binary."""
    p = Path(tool_path).resolve()
    if p.exists():
        return p
    console.print(f"[red]Error:[/red] temporal-dsql-tool not found at {p}")
    console.print("Build it with: [cyan]uv run tdeploy build temporal[/cyan]")
    raise typer.Exit(1)


@app.command()
def setup(
    profile: Annotated[str, typer.Option("--profile", "-p", help="Profile to read .env from")] = "dsql",
    version: Annotated[str, typer.Option("--version", "-v", help="Schema version")] = "1.1",
    overwrite: Annotated[bool, typer.Option("--overwrite", help="Drop and recreate existing tables")] = False,
    tool: Annotated[str, typer.Option("--tool", help="Path to temporal-dsql-tool")] = DEFAULT_TOOL_PATH,
    endpoint: Annotated[str, typer.Option("--endpoint", "-e", help="DSQL endpoint (overrides .env)")] = "",
    region: Annotated[str, typer.Option("--region", "-r", help="AWS region (overrides .env)")] = "",
) -> None:
    """Setup DSQL schema using temporal-dsql-tool.

    Reads connection details from the profile's .env file unless overridden.
    """
    console.print(Panel.fit(f"DSQL Schema Setup ({profile})", style="bold blue"))

    tool_path = _find_tool(tool)
    env = load_profile_env(profile)

    host = endpoint or env.get("TEMPORAL_SQL_HOST", "")
    aws_region = region or env.get("AWS_REGION", env.get("TEMPORAL_SQL_AWS_REGION", "eu-west-1"))
    port = env.get("TEMPORAL_SQL_PORT", "5432")
    user = env.get("TEMPORAL_SQL_USER", "admin")
    database = env.get("TEMPORAL_SQL_DATABASE", "postgres")

    if not host:
        console.print("[red]Error:[/red] No DSQL endpoint. Set TEMPORAL_SQL_HOST in .env or use --endpoint")
        raise typer.Exit(1)

    console.print(f"  Endpoint: [cyan]{host}[/cyan]")
    console.print(f"  Database: [cyan]{database}[/cyan]")
    console.print(f"  Region:   [cyan]{aws_region}[/cyan]")
    console.print(f"  Version:  [cyan]{version}[/cyan]")
    if overwrite:
        console.print("  [yellow]Overwrite: yes (existing tables will be dropped)[/yellow]")
    console.print()

    cmd = [
        str(tool_path),
        "--endpoint", host,
        "--port", port,
        "--user", user,
        "--database", database,
        "--region", aws_region,
        "setup-schema",
        "--schema-name", SCHEMA_NAME,
        "--version", version,
    ]
    if overwrite:
        cmd.append("--overwrite")

    run_env = os.environ.copy()
    run_env["AWS_REGION"] = aws_region

    try:
        subprocess.run(cmd, check=True, env=run_env)
    except subprocess.CalledProcessError as e:
        console.print(f"[red]Schema setup failed[/red] (exit code {e.returncode})")
        raise typer.Exit(e.returncode)

    console.print()
    console.print(f"[green]✓[/green] Schema v{version} applied to {host}")


@app.command()
def setup_copilot(
    endpoint: Annotated[str, typer.Option("--endpoint", "-e", help="Copilot DSQL endpoint (overrides .env)")] = "",
    database: Annotated[str, typer.Option("--database", "-d", help="Database name")] = "",
    region: Annotated[str, typer.Option("--region", "-r", help="AWS region")] = "",
    version: Annotated[str, typer.Option("--version", "-v", help="Schema version")] = "1.1",
    overwrite: Annotated[bool, typer.Option("--overwrite", help="Drop and recreate existing tables")] = False,
    tool: Annotated[str, typer.Option("--tool", help="Path to temporal-dsql-tool")] = DEFAULT_TOOL_PATH,
) -> None:
    """Setup Temporal persistence schema on the Copilot's DSQL cluster.

    Same schema as the monitored cluster, but applied to the Copilot's
    separate DSQL cluster (COPILOT_DSQL_HOST).
    """
    console.print(Panel.fit("Copilot Schema Setup", style="bold blue"))

    tool_path = _find_tool(tool)
    env = load_profile_env("copilot")

    host = endpoint or env.get("COPILOT_DSQL_HOST", "")
    db = database or env.get("COPILOT_DSQL_DATABASE", "postgres")
    aws_region = region or env.get("AWS_REGION", "eu-west-1")

    if not host:
        console.print("[red]Error:[/red] No Copilot DSQL endpoint. Set COPILOT_DSQL_HOST in .env or use --endpoint")
        raise typer.Exit(1)

    console.print(f"  Endpoint: [cyan]{host}[/cyan]")
    console.print(f"  Database: [cyan]{db}[/cyan]")
    console.print(f"  Region:   [cyan]{aws_region}[/cyan]")
    console.print(f"  Version:  [cyan]{version}[/cyan]")
    if overwrite:
        console.print("  [yellow]Overwrite: yes (existing tables will be dropped)[/yellow]")
    console.print()

    cmd = [
        str(tool_path),
        "--endpoint", host,
        "--port", "5432",
        "--user", "admin",
        "--database", db,
        "--region", aws_region,
        "setup-schema",
        "--schema-name", SCHEMA_NAME,
        "--version", version,
    ]
    if overwrite:
        cmd.append("--overwrite")

    run_env = os.environ.copy()
    run_env["AWS_REGION"] = aws_region

    try:
        subprocess.run(cmd, check=True, env=run_env)
    except subprocess.CalledProcessError as e:
        console.print(f"[red]Schema setup failed[/red] (exit code {e.returncode})")
        raise typer.Exit(e.returncode)

    console.print()
    console.print(f"[green]✓[/green] Temporal schema v{version} applied to copilot cluster {host}")

DEFAULT_COPILOT_SCHEMA = "../temporal-sre-copilot/src/copilot/db/schema.sql"


def _dsql_connect_uri(host: str, database: str, region: str) -> str:
    """Build a psycopg connection URI with a fresh IAM token."""
    import urllib.parse

    token = boto3.client("dsql", region_name=region).generate_db_connect_admin_auth_token(host, region)
    return (
        f"postgresql://admin:{urllib.parse.quote(token, safe='')}"
        f"@{host}:5432/{database}?sslmode=require"
    )


def _resolve_schema_path(schema: str) -> Path:
    """Resolve schema SQL file path relative to repo root."""
    from tdeploy.paths import repo_root

    p = Path(schema)
    return p.resolve() if p.is_absolute() else (repo_root() / schema).resolve()


@app.command()
def setup_copilot_app(
    endpoint: Annotated[str, typer.Option("--endpoint", "-e", help="Copilot DSQL endpoint (overrides .env)")] = "",
    database: Annotated[str, typer.Option("--database", "-d", help="Database name")] = "",
    region: Annotated[str, typer.Option("--region", "-r", help="AWS region")] = "",
    schema: Annotated[str, typer.Option("--schema", "-s", help="Path to schema SQL file")] = DEFAULT_COPILOT_SCHEMA,
) -> None:
    """Setup the Copilot application schema (assessments, issues, metrics).

    Connects directly to the Copilot DSQL cluster and applies the schema SQL.
    No Docker or external tools required.
    """
    import psycopg

    console.print(Panel.fit("Copilot App Schema Setup", style="bold blue"))

    env = load_profile_env("copilot")

    host = endpoint or env.get("COPILOT_DSQL_HOST", "")
    db = database or env.get("COPILOT_DSQL_DATABASE", "postgres")
    aws_region = region or env.get("AWS_REGION", "eu-west-1")

    if not host:
        console.print("[red]Error:[/red] No Copilot DSQL endpoint. Set COPILOT_DSQL_HOST in .env or use --endpoint")
        raise typer.Exit(1)

    schema_path = _resolve_schema_path(schema)
    if not schema_path.exists():
        console.print(f"[red]Error:[/red] Schema file not found: {schema_path}")
        raise typer.Exit(1)

    schema_sql = schema_path.read_text()

    console.print(f"  Endpoint: [cyan]{host}[/cyan]")
    console.print(f"  Database: [cyan]{db}[/cyan]")
    console.print(f"  Region:   [cyan]{aws_region}[/cyan]")
    console.print(f"  Schema:   [cyan]{schema_path.name}[/cyan]")
    console.print()

    with console.status("[bold green]Applying schema..."):
        try:
            uri = _dsql_connect_uri(host, db, aws_region)
            # DSQL only allows one DDL statement per transaction,
            # so we split on semicolons and execute each separately.
            # Strip SQL comments before splitting.
            lines = [
                line for line in schema_sql.splitlines()
                if line.strip() and not line.strip().startswith("--")
            ]
            clean_sql = "\n".join(lines)
            statements = [s.strip() for s in clean_sql.split(";") if s.strip()]
            with psycopg.connect(uri, autocommit=True) as conn:
                for stmt in statements:
                    first_words = " ".join(stmt.split()[:4])
                    conn.execute(stmt)
                    console.print(f"  [green]✓[/green] {first_words}")
        except Exception as e:
            console.print(f"[red]Error:[/red] {e}")
            raise typer.Exit(1)

    console.print(f"[green]✓[/green] Copilot app schema applied to {host}")

