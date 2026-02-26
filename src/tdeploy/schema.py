"""Schema commands — DSQL schema setup and management."""

import os
import subprocess
from pathlib import Path
from typing import Annotated

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
