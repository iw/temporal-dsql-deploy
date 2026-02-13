"""Terraform execution helpers."""

import json
import subprocess
from pathlib import Path

from rich.console import Console

console = Console()


def run_terraform(
    args: list[str],
    cwd: Path,
    *,
    capture: bool = False,
) -> subprocess.CompletedProcess[str]:
    """Run a terraform command, streaming output unless capture=True."""
    cmd = ["terraform", *args]
    try:
        return subprocess.run(
            cmd,
            cwd=cwd,
            capture_output=capture,
            text=True,
            check=True,
        )
    except FileNotFoundError:
        console.print("[red]Error:[/red] terraform not found. Install from https://www.terraform.io/downloads")
        raise SystemExit(1)
    except subprocess.CalledProcessError as e:
        if capture and e.stderr:
            console.print(f"[red]Terraform error:[/red]\n{e.stderr}")
        raise SystemExit(e.returncode)


def tf_init(cwd: Path) -> None:
    """Initialize terraform in the given directory."""
    run_terraform(["init", "-input=false"], cwd=cwd)


def tf_apply(cwd: Path, var_args: list[str], *, auto_approve: bool = False) -> None:
    """Plan and apply terraform changes."""
    plan_args = ["plan", "-input=false", "-out=tfplan", *var_args]
    run_terraform(plan_args, cwd=cwd)

    console.print()
    if not auto_approve:
        if not console.input("[bold]Apply these changes? (y/N):[/bold] ").strip().lower().startswith("y"):
            console.print("Cancelled.")
            raise SystemExit(0)

    run_terraform(["apply", "tfplan"], cwd=cwd)


def tf_destroy(cwd: Path, var_args: list[str], *, auto_approve: bool = False) -> None:
    """Destroy terraform-managed resources."""
    args = ["destroy", "-input=false", *var_args]
    if auto_approve:
        args.append("-auto-approve")
    run_terraform(args, cwd=cwd)


def tf_output(cwd: Path) -> dict:
    """Get terraform outputs as a dict."""
    result = run_terraform(["output", "-json"], cwd=cwd, capture=True)
    raw = json.loads(result.stdout)
    return {k: v["value"] for k, v in raw.items()}


def tf_output_value(cwd: Path, name: str) -> str:
    """Get a single terraform output value."""
    result = run_terraform(["output", "-raw", name], cwd=cwd, capture=True)
    return result.stdout.strip()


def has_state(cwd: Path) -> bool:
    """Check if terraform state exists in the given directory."""
    state_file = cwd / "terraform.tfstate"
    if not state_file.exists():
        return False
    try:
        data = json.loads(state_file.read_text())
        resources = data.get("resources", [])
        return len(resources) > 0
    except (json.JSONDecodeError, KeyError):
        return False
