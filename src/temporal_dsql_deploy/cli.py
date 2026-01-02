from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path
from typing import Optional

import typer
from pydantic_settings import BaseSettings, SettingsConfigDict

app = typer.Typer(no_args_is_help=True, add_completion=False)


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    # AWS
    aws_region: str = "eu-west-1"
    aws_profile: str = ""

    # Paths
    vpn_workdir: str = "."
    vpn_clientdir: str = "clients"
    vpn_acmdir: str = ".acm"

    # Subjects
    vpn_ca_subj: str = "/C=GB/O=Prototypical/OU=VPN/CN=Explore DSQL VPN Root CA"
    vpn_server_subj: str = "/C=GB/O=Prototypical/OU=VPN/CN=client-vpn-server"
    vpn_client_subj_prefix: str = "/C=GB/O=Prototypical/OU=VPN/CN="

    # Server SAN
    vpn_server_san_dns1: str = "client-vpn-server"

    # Validity / keys
    vpn_ca_days: int = 3650
    vpn_leaf_days: int = 825
    vpn_ca_key_bits: int = 2048  # AWS Client VPN supports max 2048-bit keys
    vpn_leaf_key_bits: int = 2048


def _s() -> Settings:
    return Settings()


def _run(
    cmd: list[str], cwd: Path, *, check: bool = True
) -> subprocess.CompletedProcess[str]:
    # Print command in a readable way
    typer.echo(f"+ {' '.join(cmd)}")
    return subprocess.run(
        cmd,
        cwd=str(cwd),
        text=True,
        capture_output=False,
        check=check,
    )


def _aws_base_args(cfg: Settings) -> list[str]:
    args = ["--region", cfg.aws_region]
    if cfg.aws_profile.strip():
        args += ["--profile", cfg.aws_profile.strip()]
    return args


def _paths(cfg: Settings) -> dict[str, Path]:
    wd = Path(cfg.vpn_workdir).resolve()
    certs = wd / "certs"
    server = wd / "server"
    return {
        "wd": wd,
        "certs": certs,
        "server": server,
        "clients": wd / cfg.vpn_clientdir,
        "acm": wd / cfg.vpn_acmdir,
        "ca_key": certs / "ca.key",
        "ca_crt": certs / "ca.crt",
        "server_key": server / "server.key",
        "server_crt": server / "server.crt",
        "server_chain": server / "server.chain.crt",
        "server_ext": server / "server.ext",
        "client_ext": wd / "client.ext",
        "acm_server_json": wd / cfg.vpn_acmdir / "server-import.json",
        "acm_root_json": wd / cfg.vpn_acmdir / "root-import.json",
    }


@app.command("init")
def init_workspace() -> None:
    """Create workspace directories (certs/, server/, clients/, .acm/)."""
    cfg = _s()
    p = _paths(cfg)
    
    # Create directories
    p["certs"].mkdir(parents=True, exist_ok=True)
    p["server"].mkdir(parents=True, exist_ok=True)
    p["clients"].mkdir(parents=True, exist_ok=True)
    p["acm"].mkdir(parents=True, exist_ok=True)
    
    # Move existing server files to server/ directory if they exist in root
    old_server_files = [
        (p["wd"] / "server.key", p["server_key"]),
        (p["wd"] / "server.crt", p["server_crt"]),
        (p["wd"] / "server.chain.crt", p["server_chain"]),
        (p["wd"] / "server.ext", p["server_ext"]),
    ]
    
    moved_files = []
    for old_path, new_path in old_server_files:
        if old_path.exists() and not new_path.exists():
            old_path.rename(new_path)
            moved_files.append(f"  - {old_path} → {new_path}")
    
    if moved_files:
        typer.echo("Moved existing server files:")
        for moved in moved_files:
            typer.echo(moved)
    
    typer.echo(
        f"Workspace ready:\n  - {p['certs']}\n  - {p['server']}\n  - {p['clients']}\n  - {p['acm']}"
    )


@app.command("create-root-ca")
def create_root_ca(
    force: bool = typer.Option(False, help="Overwrite existing CA files."),
) -> None:
    """Create the root CA (ca.key/ca.crt)."""
    cfg = _s()
    p = _paths(cfg)
    init_workspace()

    if not force and (p["ca_key"].exists() or p["ca_crt"].exists()):
        typer.echo("Root CA already exists (ca.key/ca.crt). Use --force to overwrite.")
        raise typer.Exit(code=0)

    # Remove old to avoid mixed state
    for f in (p["ca_key"], p["ca_crt"], p["wd"] / "ca.srl"):
        if f.exists():
            f.unlink()

    _run(
        ["openssl", "genrsa", "-out", str(p["ca_key"]), str(cfg.vpn_ca_key_bits)],
        cwd=p["wd"],
    )
    _run(
        [
            "openssl",
            "req",
            "-x509",
            "-new",
            "-nodes",
            "-key",
            str(p["ca_key"]),
            "-sha256",
            "-days",
            str(cfg.vpn_ca_days),
            "-out",
            str(p["ca_crt"]),
            "-subj",
            cfg.vpn_ca_subj,
        ],
        cwd=p["wd"],
    )
    typer.echo("Created root CA: ca.key, ca.crt")


@app.command("write-ext")
def write_extensions() -> None:
    """Write server.ext and client.ext extension files."""
    cfg = _s()
    p = _paths(cfg)
    init_workspace()

    server_ext_content = "\n".join(
        [
            "basicConstraints=CA:FALSE",
            "keyUsage = digitalSignature, keyEncipherment",
            "extendedKeyUsage = serverAuth",
            "subjectAltName = @alt_names",
            "",
            "[alt_names]",
            f"DNS.1 = {cfg.vpn_server_san_dns1}",
            "",
        ]
    )

    client_ext_content = "\n".join(
        [
            "basicConstraints=CA:FALSE",
            "keyUsage = digitalSignature",
            "extendedKeyUsage = clientAuth",
            "",
        ]
    )

    try:
        p["server_ext"].write_text(server_ext_content, encoding="utf-8")
        p["client_ext"].write_text(client_ext_content, encoding="utf-8")
    except OSError as e:
        typer.echo(f"Failed to write extension files: {e}")
        raise typer.Exit(code=1)

    # Verify files were written successfully
    if not p["server_ext"].exists() or not p["client_ext"].exists():
        typer.echo("Extension files were not created successfully")
        raise typer.Exit(code=1)

    typer.echo(f"Wrote:\n  - {p['server_ext']}\n  - {p['client_ext']}")


@app.command("create-server")
def create_server_cert(
    force: bool = typer.Option(False, help="Overwrite existing server cert files."),
) -> None:
    """Create the server certificate (server.key/server.crt) signed by the root CA."""
    cfg = _s()
    p = _paths(cfg)
    init_workspace()
    if not p["ca_key"].exists() or not p["ca_crt"].exists():
        typer.echo("Missing CA. Run: create-root-ca")
        raise typer.Exit(code=2)

    write_extensions()

    if not force and (p["server_key"].exists() or p["server_crt"].exists()):
        typer.echo(
            "Server cert already exists (server/server.key, server/server.crt). Use --force to overwrite."
        )
        raise typer.Exit(code=0)

    for f in (
        p["server_key"],
        p["server_crt"],
        p["server_chain"],
        p["server"] / "server.csr",
    ):
        if f.exists():
            f.unlink()

    _run(
        ["openssl", "genrsa", "-out", str(p["server_key"]), str(cfg.vpn_leaf_key_bits)],
        cwd=p["wd"],
    )
    _run(
        [
            "openssl",
            "req",
            "-new",
            "-key",
            str(p["server_key"]),
            "-out",
            str(p["server"] / "server.csr"),
            "-subj",
            cfg.vpn_server_subj,
        ],
        cwd=p["wd"],
    )
    _run(
        [
            "openssl",
            "x509",
            "-req",
            "-in",
            str(p["server"] / "server.csr"),
            "-CA",
            str(p["ca_crt"]),
            "-CAkey",
            str(p["ca_key"]),
            "-CAcreateserial",
            "-out",
            str(p["server_crt"]),
            "-days",
            str(cfg.vpn_leaf_days),
            "-sha256",
            "-extfile",
            str(p["server_ext"]),
        ],
        cwd=p["wd"],
    )

    # For ACM import convenience: chain = CA cert (self-signed root).
    shutil.copyfile(p["ca_crt"], p["server_chain"])
    (p["server"] / "server.csr").unlink(missing_ok=True)

    typer.echo("Created server cert: server/server.key, server/server.crt, server/server.chain.crt")


@app.command("create-client")
def create_client_cert(
    name: str = typer.Argument(
        ..., help="Client name (becomes CN suffix and filename)."
    ),
    force: bool = typer.Option(False, help="Overwrite existing client cert files."),
) -> None:
    """Create a client certificate clients/<name>.crt signed by the root CA."""
    cfg = _s()
    p = _paths(cfg)
    init_workspace()
    if not p["ca_key"].exists() or not p["ca_crt"].exists():
        typer.echo("Missing CA. Run: create-root-ca")
        raise typer.Exit(code=2)

    write_extensions()

    key = p["clients"] / f"{name}.key"
    crt = p["clients"] / f"{name}.crt"
    csr = p["clients"] / f"{name}.csr"

    if not force and (key.exists() or crt.exists()):
        typer.echo(f"Client '{name}' already exists. Use --force to overwrite.")
        raise typer.Exit(code=0)

    for f in (key, crt, csr):
        if f.exists():
            f.unlink()

    _run(
        ["openssl", "genrsa", "-out", str(key), str(cfg.vpn_leaf_key_bits)], cwd=p["wd"]
    )
    _run(
        [
            "openssl",
            "req",
            "-new",
            "-key",
            str(key),
            "-out",
            str(csr),
            "-subj",
            f"{cfg.vpn_client_subj_prefix}{name}",
        ],
        cwd=p["wd"],
    )
    _run(
        [
            "openssl",
            "x509",
            "-req",
            "-in",
            str(csr),
            "-CA",
            str(p["ca_crt"]),
            "-CAkey",
            str(p["ca_key"]),
            "-CAcreateserial",
            "-out",
            str(crt),
            "-days",
            str(cfg.vpn_leaf_days),
            "-sha256",
            "-extfile",
            str(p["client_ext"]),
        ],
        cwd=p["wd"],
    )
    csr.unlink(missing_ok=True)

    typer.echo(f"Created client cert:\n  - {crt}\n  - {key}")


@app.command("verify")
def verify() -> None:
    """Verify server + client certs against ca.crt."""
    cfg = _s()
    p = _paths(cfg)
    if not p["ca_crt"].exists():
        typer.echo("Missing ca.crt. Run: create-root-ca")
        raise typer.Exit(code=2)

    typer.echo("Verifying server certificate:")
    if p["server_crt"].exists():
        _run(
            ["openssl", "verify", "-CAfile", str(p["ca_crt"]), str(p["server_crt"])],
            cwd=p["wd"],
        )
    else:
        typer.echo("  server/server.crt missing (run: create-server)")

    typer.echo("\nVerifying client certificates:")
    client_crts = sorted(p["clients"].glob("*.crt"))
    if not client_crts:
        typer.echo(
            f"  (no client certs found in {p['clients']} — run: create-client <name>)"
        )
        return

    for crt in client_crts:
        typer.echo(f"  - {crt}")
        _run(["openssl", "verify", "-CAfile", str(p["ca_crt"]), str(crt)], cwd=p["wd"])


@app.command("acm-import-server")
def acm_import_server() -> None:
    """Import server cert into ACM; writes .acm/server-import.json."""
    cfg = _s()
    p = _paths(cfg)
    if (
        not p["server_crt"].exists()
        or not p["server_key"].exists()
        or not p["server_chain"].exists()
    ):
        typer.echo("Missing server cert files. Run: create-server")
        raise typer.Exit(code=2)

    args = ["aws", "acm", "import-certificate", *_aws_base_args(cfg)]
    args += [
        "--certificate",
        f"fileb://{p['server_crt']}",
        "--private-key",
        f"fileb://{p['server_key']}",
        "--certificate-chain",
        f"fileb://{p['server_chain']}",
    ]

    # Capture JSON output
    typer.echo("Importing server cert into ACM...")
    cp = subprocess.run(args, cwd=str(p["wd"]), text=True, capture_output=True)
    if cp.returncode != 0:
        typer.echo(cp.stderr)
        raise typer.Exit(code=cp.returncode)

    p["acm_server_json"].write_text(cp.stdout, encoding="utf-8")
    typer.echo(f"Wrote {p['acm_server_json']}")


@app.command("acm-import-root")
def acm_import_root() -> None:
    """Import root CA cert into ACM; writes .acm/root-import.json."""
    cfg = _s()
    p = _paths(cfg)
    if not p["ca_crt"].exists() or not p["ca_key"].exists():
        typer.echo("Missing ca.crt/ca.key. Run: create-root-ca")
        raise typer.Exit(code=2)

    args = ["aws", "acm", "import-certificate", *_aws_base_args(cfg)]
    args += [
        "--certificate",
        f"fileb://{p['ca_crt']}",
        "--private-key",
        f"fileb://{p['ca_key']}",
    ]

    typer.echo("Importing root CA cert into ACM...")
    cp = subprocess.run(args, cwd=str(p["wd"]), text=True, capture_output=True)
    if cp.returncode != 0:
        typer.echo(cp.stderr)
        raise typer.Exit(code=cp.returncode)

    p["acm_root_json"].write_text(cp.stdout, encoding="utf-8")
    typer.echo(f"Wrote {p['acm_root_json']}")
    typer.echo(
        "Use this ARN as root_certificate_chain_arn for Client VPN certificate-authentication."
    )


def _print_arn(json_path: Path) -> Optional[str]:
    if not json_path.exists():
        return None
    data = json.loads(json_path.read_text(encoding="utf-8"))
    return data.get("CertificateArn")


@app.command("print-acm-arns")
def print_acm_arns() -> None:
    """Print the two ARNs you need for Terraform."""
    cfg = _s()
    p = _paths(cfg)
    server_arn = _print_arn(p["acm_server_json"])
    root_arn = _print_arn(p["acm_root_json"])

    if server_arn:
        typer.echo(f"client_vpn_server_certificate_arn = {server_arn}")
    else:
        typer.echo(
            "client_vpn_server_certificate_arn = (missing; run: acm-import-server)"
        )

    if root_arn:
        typer.echo(f"root_certificate_chain_arn      = {root_arn}")
    else:
        typer.echo("root_certificate_chain_arn      = (missing; run: acm-import-root)")


@app.command("ovpn-inline")
def ovpn_inline(
    name: str = typer.Argument(..., help="Client name created via create-client"),
) -> None:
    """Print <cert> and <key> blocks for embedding into an .ovpn file."""
    cfg = _s()
    p = _paths(cfg)
    crt = p["clients"] / f"{name}.crt"
    key = p["clients"] / f"{name}.key"
    if not crt.exists() or not key.exists():
        typer.echo(f"Missing {crt} or {key}. Run: create-client {name}")
        raise typer.Exit(code=2)

    typer.echo("<cert>")
    typer.echo(crt.read_text(encoding="utf-8").rstrip())
    typer.echo("</cert>\n")
    typer.echo("<key>")
    typer.echo(key.read_text(encoding="utf-8").rstrip())
    typer.echo("</key>")


@app.command("clean")
def clean() -> None:
    """Remove generated certs and metadata (clients/, .acm/, ca.*, server.*, *.ext)."""
    cfg = _s()
    p = _paths(cfg)

    # Directories
    for d in (p["certs"], p["server"], p["clients"], p["acm"]):
        if d.exists():
            shutil.rmtree(d)

    # Files
    for f in (
        p["wd"] / "ca.srl",
        p["wd"] / "client.ext",
    ):
        f.unlink(missing_ok=True)

    typer.echo("Cleaned generated files.")


if __name__ == "__main__":
    app()
