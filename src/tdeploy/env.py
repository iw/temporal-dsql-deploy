"""Environment file helpers."""

from rich.console import Console

from tdeploy.paths import profiles_dir

console = Console()


def load_profile_env(profile: str) -> dict[str, str]:
    """Load key=value pairs from a profile's .env file.

    Returns an empty dict (with a warning) if the file doesn't exist.
    """
    env_file = profiles_dir(profile) / ".env"
    if not env_file.exists():
        console.print(f"[yellow]Warning:[/yellow] {env_file} not found — using defaults")
        return {}

    env: dict[str, str] = {}
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            key, _, value = line.partition("=")
            env[key.strip()] = value.strip()
    return env
