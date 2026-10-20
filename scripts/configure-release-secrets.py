#!/usr/bin/env python3
import argparse
import base64
import getpass
import os
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description="Store Apple signing credentials in a repository's encrypted GitHub Actions secrets.")
    parser.add_argument("--repo", required=True, help="GitHub owner/repository")
    parser.add_argument("--certificate", required=True, type=Path, help="Encrypted Developer ID Application .p12 backup")
    parser.add_argument("--apple-id", required=True)
    parser.add_argument("--team-id", required=True)
    args = parser.parse_args()
    if not sys.stdin.isatty():
        raise ValueError("Run this setup in an interactive terminal so password entry stays hidden.")
    subprocess.run(["gh", "auth", "status"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    certificate = args.certificate.expanduser().read_bytes()
    print(f"Destination: {args.repo} → GitHub Actions secrets")
    print("Uploads the signing certificate with its private key, backup password, Apple ID, app-specific password, and team ID.")
    print("These credentials let this repository's release workflow sign and notarize apps under your developer identity.")
    password = getpass.getpass("Certificate backup password: ")
    if not password:
        raise ValueError("The certificate backup password cannot be empty.")
    environment = os.environ.copy()
    environment["PRUMO_P12_PASSWORD"] = password
    result = subprocess.run(
        ["openssl", "pkcs12", "-in", str(args.certificate.expanduser()), "-passin", "env:PRUMO_P12_PASSWORD", "-noout"],
        env=environment, capture_output=True,
    )
    if result.returncode:
        raise ValueError("Cannot open the certificate backup. Check the file and its password.")
    app_password = getpass.getpass("Apple app-specific password for notarization: ")
    if not app_password:
        raise ValueError("The app-specific password cannot be empty.")
    if input(f"Upload these credentials to {args.repo}? [y/N] ").strip().lower() != "y":
        print("Cancelled. No secrets were uploaded.")
        return
    values = {
        "APPLE_CERTIFICATE": base64.b64encode(certificate).decode("ascii"),
        "APPLE_CERTIFICATE_PASSWORD": password,
        "APPLE_ID": args.apple_id,
        "APPLE_ID_PASSWORD": app_password,
        "APPLE_TEAM_ID": args.team_id,
    }
    for name, value in values.items():
        subprocess.run(["gh", "secret", "set", name, "--repo", args.repo], input=value.encode(), check=True)
        print(f"Configured {name}.")
    print("All five release secrets are configured. Secret values were not printed or written to repository files.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Setup failed: {error}", file=sys.stderr)
        sys.exit(1)
