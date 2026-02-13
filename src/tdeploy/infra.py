"""Infrastructure commands — provision and manage AWS resources."""

from typing import Annotated

import typer
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

from tdeploy.paths import terraform_dir
from tdeploy.terraform import has_state, tf_apply, tf_destroy, tf_init, tf_output

app = typer.Typer(no_args_is_help=True)
console = Console()


@app.command()
def apply_shared(
    project_name: Annotated[str, typer.Option("--project", "-p", help="Project name prefix for AWS resources")],
    region: Annotated[str, typer.Option("--region", "-r", help="AWS region")] = "eu-west-1",
    dynamodb: Annotated[bool, typer.Option("--dynamodb", help="Create DynamoDB tables for distributed rate limiting and connection leasing")] = False,
    auto_approve: Annotated[bool, typer.Option("--yes", "-y", help="Skip confirmation prompt")] = False,
) -> None:
    """Provision long-lived shared infrastructure (DSQL cluster, optional DynamoDB tables).

    These resources persist across profile switches and service restarts.
    Run once, then forget about it.
    """
    console.print(Panel.fit("Provisioning Shared Infrastructure", style="bold blue"))

    cwd = terraform_dir("shared")
    if not cwd.exists():
        console.print(f"[red]Error:[/red] Terraform directory not found: {cwd}")
        raise typer.Exit(1)

    var_args = [
        f"-var=project_name={project_name}",
        f"-var=region={region}",
        f"-var=create_dynamodb_tables={str(dynamodb).lower()}",
    ]

    console.print(f"  Project:  [cyan]{project_name}[/cyan]")
    console.print(f"  Region:   [cyan]{region}[/cyan]")
    console.print(f"  DynamoDB: [cyan]{'yes' if dynamodb else 'no'}[/cyan]")
    console.print()

    tf_init(cwd)
    tf_apply(cwd, var_args, auto_approve=auto_approve)

    console.print()
    _show_shared_outputs(cwd)


@app.command()
def apply_copilot(
    project_name: Annotated[str, typer.Option("--project", "-p", help="Project name prefix")] = "",
    region: Annotated[str, typer.Option("--region", "-r", help="AWS region")] = "eu-west-1",
    auto_approve: Annotated[bool, typer.Option("--yes", "-y", help="Skip confirmation prompt")] = False,
) -> None:
    """Provision ephemeral Copilot infrastructure (separate DSQL cluster).

    Create when working on the Copilot, destroy when done.
    """
    console.print(Panel.fit("Provisioning Copilot Infrastructure", style="bold blue"))

    # Try to inherit project name from shared infra
    if not project_name:
        shared_dir = terraform_dir("shared")
        if has_state(shared_dir):
            try:
                outputs = tf_output(shared_dir)
                project_name = outputs.get("project_name", "")
                region = outputs.get("region", region)
                if project_name:
                    console.print(f"  [dim]Inherited project name from shared infra: {project_name}[/dim]")
            except SystemExit:
                pass

    if not project_name:
        console.print("[red]Error:[/red] --project is required (no shared infra state found to inherit from)")
        raise typer.Exit(1)

    cwd = terraform_dir("copilot")
    var_args = [
        f"-var=project_name={project_name}",
        f"-var=region={region}",
    ]

    console.print(f"  Project: [cyan]{project_name}[/cyan]")
    console.print(f"  Region:  [cyan]{region}[/cyan]")
    console.print()

    tf_init(cwd)
    tf_apply(cwd, var_args, auto_approve=auto_approve)

    console.print()
    _show_copilot_outputs(cwd)


@app.command()
def destroy_copilot(
    project_name: Annotated[str, typer.Option("--project", "-p", help="Project name prefix")] = "",
    region: Annotated[str, typer.Option("--region", "-r", help="AWS region")] = "eu-west-1",
    auto_approve: Annotated[bool, typer.Option("--yes", "-y", help="Skip confirmation prompt")] = False,
) -> None:
    """Destroy ephemeral Copilot infrastructure.

    Tears down the Copilot DSQL cluster. Shared infrastructure is not affected.
    """
    console.print(Panel.fit("Destroying Copilot Infrastructure", style="bold yellow"))

    cwd = terraform_dir("copilot")

    # Try to get project name from existing state
    if not project_name and has_state(cwd):
        try:
            outputs = tf_output(cwd)
            project_name = outputs.get("project_name", project_name)
            region = outputs.get("region", region)
        except SystemExit:
            pass

    if not project_name:
        console.print("[red]Error:[/red] --project is required (no state found)")
        raise typer.Exit(1)

    var_args = [
        f"-var=project_name={project_name}",
        f"-var=region={region}",
    ]

    tf_init(cwd)
    tf_destroy(cwd, var_args, auto_approve=auto_approve)

    console.print("[green]✓[/green] Copilot infrastructure destroyed.")


@app.command()
def status() -> None:
    """Show the current state of provisioned infrastructure."""
    console.print(Panel.fit("Infrastructure Status", style="bold blue"))

    # Shared
    shared_dir = terraform_dir("shared")
    console.print("\n[bold]Shared (long-lived):[/bold]")
    if has_state(shared_dir):
        try:
            _show_shared_outputs(shared_dir)
        except SystemExit:
            console.print("  [yellow]State exists but outputs unavailable (run terraform init?)[/yellow]")
    else:
        console.print("  [dim]Not provisioned[/dim]")

    # Copilot
    copilot_dir = terraform_dir("copilot")
    console.print("\n[bold]Copilot (ephemeral):[/bold]")
    if has_state(copilot_dir):
        try:
            _show_copilot_outputs(copilot_dir)
        except SystemExit:
            console.print("  [yellow]State exists but outputs unavailable (run terraform init?)[/yellow]")
    else:
        console.print("  [dim]Not provisioned[/dim]")


def _show_shared_outputs(cwd) -> None:
    """Display shared infrastructure outputs."""
    outputs = tf_output(cwd)
    table = Table(show_header=False, box=None, padding=(0, 2))
    table.add_row("DSQL endpoint", f"[green]{outputs.get('dsql_endpoint', 'n/a')}[/green]")
    table.add_row("Region", outputs.get("region", "n/a"))
    table.add_row("Project", outputs.get("project_name", "n/a"))
    rate_table = outputs.get("rate_limiter_table", "")
    if rate_table:
        table.add_row("Rate limiter table", rate_table)
    conn_table = outputs.get("conn_lease_table", "")
    if conn_table:
        table.add_row("Conn lease table", conn_table)
    console.print(table)


def _show_copilot_outputs(cwd) -> None:
    """Display copilot infrastructure outputs."""
    outputs = tf_output(cwd)
    table = Table(show_header=False, box=None, padding=(0, 2))
    table.add_row("Copilot DSQL endpoint", f"[green]{outputs.get('copilot_dsql_endpoint', 'n/a')}[/green]")
    table.add_row("Region", outputs.get("region", "n/a"))
    console.print(table)
