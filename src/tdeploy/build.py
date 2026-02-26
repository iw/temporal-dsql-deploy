"""Build commands — Docker image construction using Dagger."""

from datetime import datetime
import sys
from pathlib import Path
from typing import Annotated

import anyio
import dagger
from dagger import dag
import typer
from rich.console import Console
from rich.panel import Panel

from tdeploy.paths import repo_root

app = typer.Typer(no_args_is_help=True)
console = Console()


async def _build_temporal_async(source_path: Path, arch: str) -> None:
    """Build temporal-dsql base image and runtime image using Dagger."""
    config = dagger.Config(log_output=sys.stderr)

    async with dagger.connection(config):
        # --- Stage 1: Build Go binaries ---
        console.print("[bold]Building Go binaries...[/bold]")

        source_dir = dag.host().directory(
            str(source_path),
            exclude=[".git", ".venv", "**/__pycache__"],
        )

        go_builder = (
            dag.container(platform=dagger.Platform(f"linux/{arch}"))
            .from_("golang:1.25-alpine")
            .with_exec(["apk", "add", "--no-cache", "make", "git", "gcc", "musl-dev"])
            .with_directory("/src", source_dir)
            .with_workdir("/src")
            .with_env_variable("CGO_ENABLED", "0")
            .with_env_variable("GOOS", "linux")
            .with_env_variable("GOARCH", arch)
        )

        # See https://docs.dagger.io/cookbook?sdk=python#invalidate-cache
        go_builder = go_builder.with_env_variable("CACHEBUSTER", str(datetime.now()))

        # Build temporal-server
        go_builder = go_builder.with_exec([
            "go", "build",
            "-tags", "disable_grpc_modules",
            "-o", "temporal-server",
            "./cmd/server",
        ])

        # Build temporal-dsql-tool
        go_builder = go_builder.with_exec([
            "go", "build",
            "-tags", "disable_grpc_modules",
            "-o", "temporal-dsql-tool",
            "./cmd/tools/dsql",
        ])

        temporal_server = go_builder.file("/src/temporal-server")
        dsql_tool = go_builder.file("/src/temporal-dsql-tool")

        # --- Stage 2: Build temporal-dsql:latest base image ---
        console.print("[bold]Building temporal-dsql:latest...[/bold]")

        base = (
            dag.container(platform=dagger.Platform(f"linux/{arch}"))
            .from_("alpine:3.22")
            .with_exec([
                "sh", "-c",
                "apk add --no-cache ca-certificates tzdata curl python3 bash aws-cli"
                " && addgroup -g 1000 temporal"
                " && adduser -u 1000 -G temporal -D temporal",
            ])
            .with_workdir("/etc/temporal")
            .with_env_variable("TEMPORAL_HOME", "/etc/temporal")
            .with_exec(["mkdir", "-p", "/etc/temporal/config/dynamicconfig"])
            .with_exec(["chown", "-R", "temporal:temporal", "/etc/temporal"])
            .with_file("/usr/local/bin/temporal-server", temporal_server, permissions=0o755)
            .with_file("/usr/local/bin/temporal-dsql-tool", dsql_tool, permissions=0o755)
            .with_new_file(
                "/etc/temporal/entrypoint.sh",
                "#!/bin/sh\nset -eu\nexec /usr/local/bin/temporal-server \"$@\"\n",
                permissions=0o755,
            )
            .with_user("temporal")
            .with_entrypoint(["/etc/temporal/entrypoint.sh"])
            .with_default_args([
                "--config-file", "/etc/temporal/config/development-dsql.yaml",
                "--allow-no-auth", "start",
            ])
        )

        # Export to local Docker daemon
        await base.export_image.__wrapped__(base, "temporal-dsql:latest")

        # --- Stage 3: Build temporal-dsql-runtime:test ---
        console.print("[bold]Building temporal-dsql-runtime:test...[/bold]")

        deploy_dir = dag.host().directory(
            str(repo_root()),
            include=[
                "docker/config/persistence-dsql-elasticsearch.template.yaml",
                "docker/config/persistence-dsql.template.yaml",
                "docker/render-and-start.sh",
                "Dockerfile",
            ],
        )

        runtime = (
            base
            .with_user("root")
            .with_file(
                "/etc/temporal/config/persistence-dsql-elasticsearch.template.yaml",
                deploy_dir.file("docker/config/persistence-dsql-elasticsearch.template.yaml"),
            )
            .with_file(
                "/etc/temporal/config/persistence-dsql.template.yaml",
                deploy_dir.file("docker/config/persistence-dsql.template.yaml"),
            )
            .with_file(
                "/usr/local/bin/render-and-start.sh",
                deploy_dir.file("docker/render-and-start.sh"),
                permissions=0o755,
            )
            .with_user("temporal")
            .with_entrypoint(["/usr/local/bin/render-and-start.sh"])
            .with_default_args([])
        )

        await runtime.export_image.__wrapped__(runtime, "temporal-dsql-runtime:test")

    console.print()
    console.print("[green]✓[/green] Images built:")
    console.print(f"  temporal-dsql:latest         (linux/{arch})")
    console.print(f"  temporal-dsql-runtime:test    (linux/{arch})")


@app.command()
def temporal(
    source: Annotated[str, typer.Argument(help="Path to temporal-dsql repository")] = "../temporal-dsql",
    arch: Annotated[str, typer.Option("--arch", "-a", help="Target architecture")] = "arm64",
) -> None:
    """Build temporal-dsql base image and runtime image.

    Compiles the temporal-server and temporal-dsql-tool binaries, builds the
    base image, then layers on the runtime config templates.
    """
    console.print(Panel.fit("Building Temporal DSQL Images", style="bold blue"))

    source_path = Path(source).resolve()
    if not source_path.exists():
        console.print(f"[red]Error:[/red] temporal-dsql directory not found: {source_path}")
        raise typer.Exit(1)

    console.print(f"  Source: [cyan]{source_path}[/cyan]")
    console.print(f"  Arch:   [cyan]{arch}[/cyan]")
    console.print()

    anyio.run(_build_temporal_async, source_path, arch)
