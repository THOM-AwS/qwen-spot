"""Helpers shared by the scripts that run on the operator's machine."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
TERRAFORM_DIR = REPO_ROOT / "terraform"


def terraform_outputs() -> dict[str, Any]:
    """Return `terraform output -json` as {name: value}, or {} if unavailable."""
    terraform = shutil.which("terraform")
    if terraform is None or not (TERRAFORM_DIR / ".terraform").exists():
        return {}
    try:
        proc = subprocess.run(  # noqa: S603 - fixed argv, no shell
            [terraform, f"-chdir={TERRAFORM_DIR}", "output", "-json"],
            capture_output=True,
            text=True,
            check=True,
            timeout=120,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        print(f"warning: terraform output failed: {exc}", file=sys.stderr)
        return {}
    raw = json.loads(proc.stdout or "{}")
    return {name: entry.get("value") for name, entry in raw.items()}


def require_profile() -> str:
    """Refuse to act on whatever credentials happen to be ambient."""
    profile = os.environ.get("AWS_PROFILE", "").strip()
    if not profile:
        sys.exit("error: set AWS_PROFILE explicitly (for example AWS_PROFILE=my-profile)")
    return profile


def confirm(prompt: str, assume_yes: bool) -> None:
    if assume_yes:
        return
    if not sys.stdin.isatty():
        sys.exit("error: not a terminal; pass --yes to confirm")
    answer = input(f"{prompt} [y/N] ").strip().lower()
    if answer not in {"y", "yes"}:
        sys.exit("aborted")
