"""Path resolution for the temporal-dsql-deploy project."""

from pathlib import Path


def repo_root() -> Path:
    """Return the repository root (parent of src/tdeploy/)."""
    return Path(__file__).resolve().parent.parent.parent


def terraform_dir(module: str) -> Path:
    """Return path to a terraform module directory."""
    return repo_root() / "terraform" / module


def profiles_dir(profile: str) -> Path:
    """Return path to a profile directory."""
    return repo_root() / "profiles" / profile


def docker_config_dir() -> Path:
    """Return path to shared Docker config."""
    return repo_root() / "docker" / "config"
