"""Client settings: written once from `terraform output -json client_config`."""

from __future__ import annotations

import json
import os
import shutil
import subprocess  # nosec B404 - runs the local terraform binary only
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

DEFAULT_PATH = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "qwenq" / "config.json"


class SettingsError(RuntimeError):
    pass


@dataclass(frozen=True)
class Settings:
    region: str
    queue_url: str
    dlq_url: str
    results_bucket: str
    asg_name: str
    model_name: str
    instance_types: tuple[str, ...]

    @classmethod
    def from_mapping(cls, data: dict[str, Any]) -> Settings:
        try:
            return cls(
                region=data["region"],
                queue_url=data["queue_url"],
                dlq_url=data.get("dlq_url", ""),
                results_bucket=data["results_bucket"],
                asg_name=data["asg_name"],
                model_name=data.get("model_name", ""),
                instance_types=tuple(data.get("instance_types", ())),
            )
        except KeyError as exc:
            raise SettingsError(f"client config is missing {exc}") from exc

    def to_json(self) -> str:
        data = asdict(self)
        data["instance_types"] = list(self.instance_types)
        return json.dumps(data, indent=2)


def path() -> Path:
    return Path(os.environ["QWENQ_CONFIG"]) if os.environ.get("QWENQ_CONFIG") else DEFAULT_PATH


def load() -> Settings:
    config_path = path()
    if not config_path.exists():
        raise SettingsError(f"{config_path} not found; run `qwenq configure --terraform-dir terraform` first")
    return Settings.from_mapping(json.loads(config_path.read_text()))


def from_terraform(terraform_dir: Path) -> Settings:
    terraform = shutil.which("terraform")
    if not terraform:
        raise SettingsError("terraform not found on PATH")
    try:
        out = subprocess.run(  # noqa: S603  # nosec B603 - fixed argv, no shell
            [terraform, f"-chdir={terraform_dir}", "output", "-json", "client_config"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", "") or str(exc)
        raise SettingsError(f"terraform output failed: {detail.strip()}") from exc
    return Settings.from_mapping(json.loads(out))


def save(settings: Settings) -> Path:
    config_path = path()
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(settings.to_json() + "\n")
    config_path.chmod(0o600)
    return config_path
