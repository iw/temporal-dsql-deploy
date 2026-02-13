"""Temporal DSQL Deploy CLI — manage infrastructure, services, and schemas."""

import typer

from tdeploy.infra import app as infra_app
from tdeploy.build import app as build_app
from tdeploy.kb import app as kb_app
from tdeploy.schema import app as schema_app
from tdeploy.services import app as services_app

app = typer.Typer(
    name="tdeploy",
    help="Temporal DSQL Deploy — manage local Temporal development environments.",
    no_args_is_help=True,
)

app.add_typer(infra_app, name="infra", help="Provision and manage AWS infrastructure")
app.add_typer(build_app, name="build", help="Build Docker images")
app.add_typer(kb_app, name="kb", help="Knowledge Base — sync RAG docs and trigger ingestion")
app.add_typer(schema_app, name="schema", help="Setup and manage DSQL schemas")
app.add_typer(services_app, name="services", help="Start, stop, and manage Docker services")


@app.callback()
def main() -> None:
    """Temporal DSQL Deploy CLI."""


if __name__ == "__main__":
    app()
