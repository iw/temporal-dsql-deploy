"""Service commands — Docker Compose lifecycle management."""

import subprocess
from typing import Annotated

import typer
from rich.console import Console
from rich.panel import Panel

from tdeploy.paths import profiles_dir

app = typer.Typer(no_args_is_help=True)
console = Console()

PROFILES = ["dsql", "copilot"]


def _compose(profile: str, args: list[str]) -> None:
    """Run docker compose for a profile."""
    profile_dir = profiles_dir(profile)
    compose_file = profile_dir / "docker-compose.yml"

    if not compose_file.exists():
        console.print(f"[red]Error:[/red] {compose_file} not found")
        raise typer.Exit(1)

    env_file = profile_dir / ".env"
    if not env_file.exists():
        console.print(f"[red]Error:[/red] {env_file} not found")
        console.print(f"Copy .env.example to .env and configure it:")
        console.print(f"  [cyan]cp {profile_dir}/.env.example {env_file}[/cyan]")
        raise typer.Exit(1)

    cmd = ["docker", "compose", "-f", str(compose_file), *args]
    try:
        subprocess.run(cmd, check=True)
    except FileNotFoundError:
        console.print("[red]Error:[/red] docker not found")
        raise typer.Exit(1)
    except subprocess.CalledProcessError as e:
        raise typer.Exit(e.returncode)


@app.command()
def up(
    profile: Annotated[str, typer.Option("--profile", "-p", help="Profile to start")] = "dsql",
    detach: Annotated[bool, typer.Option("--detach", "-d", help="Run in background")] = False,
) -> None:
    """Start services for a profile."""
    if profile not in PROFILES:
        console.print(f"[red]Error:[/red] Unknown profile '{profile}'. Choose from: {', '.join(PROFILES)}")
        raise typer.Exit(1)

    console.print(Panel.fit(f"Starting {profile} profile", style="bold blue"))

    args = ["up"]
    if detach:
        args.append("-d")
    _compose(profile, args)


@app.command()
def down(
    profile: Annotated[str, typer.Option("--profile", "-p", help="Profile to stop")] = "dsql",
    volumes: Annotated[bool, typer.Option("--volumes", "-v", help="Remove volumes")] = False,
) -> None:
    """Stop services for a profile."""
    if profile not in PROFILES:
        console.print(f"[red]Error:[/red] Unknown profile '{profile}'. Choose from: {', '.join(PROFILES)}")
        raise typer.Exit(1)

    console.print(Panel.fit(f"Stopping {profile} profile", style="bold blue"))

    args = ["down"]
    if volumes:
        args.append("-v")
    _compose(profile, args)


@app.command()
def restart(
    profile: Annotated[str, typer.Option("--profile", "-p", help="Profile to restart")] = "dsql",
    service: Annotated[list[str] | None, typer.Argument(help="Specific services to restart")] = None,
) -> None:
    """Restart services (or specific services) for a profile."""
    args = ["restart"]
    if service:
        args.extend(service)
    _compose(profile, args)


@app.command()
def logs(
    profile: Annotated[str, typer.Option("--profile", "-p", help="Profile")] = "dsql",
    service: Annotated[str | None, typer.Argument(help="Specific service")] = None,
    follow: Annotated[bool, typer.Option("--follow", "-f", help="Follow log output")] = False,
    tail: Annotated[int, typer.Option("--tail", "-n", help="Number of lines")] = 100,
) -> None:
    """View service logs."""
    args = ["logs", f"--tail={tail}"]
    if follow:
        args.append("-f")
    if service:
        args.append(service)
    _compose(profile, args)


@app.command()
def ps(
    profile: Annotated[str, typer.Option("--profile", "-p", help="Profile")] = "dsql",
) -> None:
    """Show running services for a profile."""
    _compose(profile, ["ps"])
