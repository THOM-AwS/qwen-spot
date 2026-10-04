#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "boto3==1.43.108",
#   "huggingface_hub==2.1.1",
# ]
# # Freezes transitive resolution too: nothing published after this date is used.
# [tool.uv]
# exclude-newer = "2026-10-04T00:00:00Z"
# ///
"""Download a pinned Hugging Face model and copy it to the weights bucket.

Runs on the uploader instance (in the same region as the bucket), not on a home
connection. Settings come from the environment, normally /etc/qwen-spot/uploader.env:

  QWEN_REGION, QWEN_WEIGHTS_BUCKET, QWEN_MODEL_REPO, QWEN_MODEL_REVISION (40-hex sha),
  QWEN_MODEL_NAME, optional QWEN_HF_TOKEN_PARAM (SSM SecureString name),
  optional QWEN_UPLOADER_ASG (set to 0 on exit), optional QWEN_WORK_DIR.

Only safetensors, config and tokenizer files are fetched. Pickle-format weights are
never downloaded, and a repo that ships only pickle weights is refused.
`--dry-run` lists and checks the repo without downloading; it needs no AWS access.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
PICKLE_SUFFIXES = (".bin", ".pt", ".pth", ".ckpt", ".pkl", ".pickle")
ALLOW_PATTERNS = [
    "*.safetensors",
    "*.json",
    "*.jinja",
    "*.txt",
    "tokenizer*",
    "*.model",
    "LICENSE*",
    "README.md",
]
IGNORE_PATTERNS = [f"*{suffix}" for suffix in PICKLE_SUFFIXES] + ["*.msgpack", "*.h5", "*.onnx"]
NVME_MOUNT = Path("/mnt/qwen-upload")
MARKER = ".complete"


def log(level: str, msg: str, **fields: Any) -> None:
    record = {"ts": datetime.now(UTC).isoformat(), "level": level, "component": "upload-model", "msg": msg}
    record.update(fields)
    print(json.dumps(record), flush=True)


@dataclass(frozen=True)
class Settings:
    region: str
    bucket: str
    repo: str
    revision: str
    model_name: str
    hf_token_param: str
    asg_name: str
    upload_dir: str

    @property
    def prefix(self) -> str:
        return f"models/{self.model_name}/{self.revision}/"


def load_settings(dry_run: bool) -> Settings:
    env = os.environ
    settings = Settings(
        region=env.get("QWEN_REGION", ""),
        bucket=env.get("QWEN_WEIGHTS_BUCKET", ""),
        repo=env.get("QWEN_MODEL_REPO", ""),
        revision=env.get("QWEN_MODEL_REVISION", "").lower(),
        model_name=env.get("QWEN_MODEL_NAME", ""),
        hf_token_param=env.get("QWEN_HF_TOKEN_PARAM", ""),
        asg_name=env.get("QWEN_UPLOADER_ASG", ""),
        upload_dir=env.get("QWEN_WORK_DIR", ""),
    )
    required = {"QWEN_MODEL_REPO": settings.repo, "QWEN_MODEL_REVISION": settings.revision}
    if not dry_run:
        required |= {
            "QWEN_REGION": settings.region,
            "QWEN_WEIGHTS_BUCKET": settings.bucket,
            "QWEN_MODEL_NAME": settings.model_name,
        }
    missing = [name for name, value in required.items() if not value]
    if missing:
        raise SystemExit(f"missing settings: {', '.join(missing)}")
    if not SHA_RE.match(settings.revision):
        raise SystemExit(
            f"QWEN_MODEL_REVISION must be a full 40-hex commit sha, got {settings.revision!r}; "
            "branch names and tags can move"
        )
    if settings.model_name and not re.match(r"^[A-Za-z0-9._-]+$", settings.model_name):
        raise SystemExit(f"QWEN_MODEL_NAME has unsafe characters: {settings.model_name!r}")
    return settings


def hf_token(settings: Settings) -> str | None:
    if not settings.hf_token_param:
        return None
    import boto3

    ssm = boto3.client("ssm", region_name=settings.region)
    return ssm.get_parameter(Name=settings.hf_token_param, WithDecryption=True)["Parameter"]["Value"]


def check_repo(settings: Settings, token: str | None) -> dict[str, dict[str, Any]]:
    """Return {path: {size, sha256}} for the files we will fetch. Refuse pickle-only repos."""
    from huggingface_hub import HfApi

    api = HfApi(token=token)
    info = api.model_info(settings.repo, revision=settings.revision, files_metadata=True)
    if info.sha != settings.revision:
        raise SystemExit(f"revision resolved to {info.sha}, expected {settings.revision}")
    siblings = info.siblings or []
    names = [s.rfilename for s in siblings]
    pickles = [n for n in names if n.endswith(PICKLE_SUFFIXES)]
    safetensors = [n for n in names if n.endswith(".safetensors")]
    if not safetensors:
        raise SystemExit(f"refusing {settings.repo}: no safetensors weights (pickle files: {pickles})")
    if pickles:
        log("warn", "repo also ships pickle-format files; they will not be downloaded", files=pickles)

    wanted: dict[str, dict[str, Any]] = {}
    for sib in siblings:
        name = sib.rfilename
        if name.endswith(PICKLE_SUFFIXES) or not _allowed(name):
            continue
        lfs = sib.lfs
        sha = getattr(lfs, "sha256", None) if lfs is not None else None
        if isinstance(lfs, dict):
            sha = lfs.get("sha256")
        wanted[name] = {"size": sib.size, "sha256": sha}
    return wanted


def _allowed(name: str) -> bool:
    from fnmatch import fnmatch

    base = name.rsplit("/", 1)[-1]
    if any(fnmatch(name, pat) or fnmatch(base, pat) for pat in IGNORE_PATTERNS):
        return False
    return any(fnmatch(name, pat) or fnmatch(base, pat) for pat in ALLOW_PATTERNS)


def work_dir(settings: Settings) -> Path:
    if settings.upload_dir:
        path = Path(settings.upload_dir)
    elif _mount_instance_store():
        path = NVME_MOUNT / "hf"
    else:
        path = Path("/var/tmp/qwen-upload")  # noqa: S108 - single-tenant job instance
    path.mkdir(parents=True, exist_ok=True)
    return path


def _mount_instance_store() -> bool:
    """Format and mount the first instance-store NVMe disk, if there is one."""
    if os.path.ismount(NVME_MOUNT):
        return True
    by_id = Path("/dev/disk/by-id")
    devices = (
        sorted(
            {
                str(p.resolve())
                for p in by_id.glob("nvme-Amazon_EC2_NVMe_Instance_Storage_*")
                if re.match(r"^/dev/nvme\d+n\d+$", str(p.resolve()))
            }
        )
        if by_id.exists()
        else []
    )
    if not devices:
        log("info", "no instance store; downloading to the root volume")
        return False
    NVME_MOUNT.mkdir(parents=True, exist_ok=True)
    subprocess.run(["mkfs.xfs", "-f", "-q", devices[0]], check=True)  # noqa: S603,S607
    subprocess.run(["mount", "-o", "noatime", devices[0], str(NVME_MOUNT)], check=True)  # noqa: S603,S607
    log("info", "mounted instance store", device=devices[0], path=str(NVME_MOUNT))
    return True


def download(settings: Settings, token: str | None, dest: Path) -> Path:
    from huggingface_hub import snapshot_download

    start = time.monotonic()
    local = snapshot_download(
        repo_id=settings.repo,
        revision=settings.revision,
        allow_patterns=ALLOW_PATTERNS,
        ignore_patterns=IGNORE_PATTERNS,
        local_dir=dest / settings.revision,
        token=token,
        max_workers=16,
    )
    log("info", "download finished", seconds=round(time.monotonic() - start, 1))
    return Path(local)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        while chunk := fh.read(16 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def verify(local: Path, wanted: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    """Check pickle absence, shard completeness, sizes and LFS sha256. Return file manifest."""
    files = sorted(p for p in local.rglob("*") if p.is_file() and ".cache" not in p.relative_to(local).parts)
    rel = {str(p.relative_to(local)): p for p in files}

    stray = [name for name in rel if name.endswith(PICKLE_SUFFIXES)]
    if stray:
        raise SystemExit(f"pickle-format files present after download: {stray}")

    index_path = local / "model.safetensors.index.json"
    if index_path.exists():
        shards = set(json.loads(index_path.read_text())["weight_map"].values())
    else:
        shards = {"model.safetensors"}
    missing = sorted(shards - rel.keys())
    if missing:
        raise SystemExit(f"safetensors shards missing: {missing}")

    for name, meta in wanted.items():
        if name not in rel:
            raise SystemExit(f"expected file not downloaded: {name}")
        size = rel[name].stat().st_size
        if meta["size"] is not None and size != meta["size"]:
            raise SystemExit(f"size mismatch for {name}: {size} != {meta['size']}")

    to_hash = {name: rel[name] for name, meta in wanted.items() if meta.get("sha256")}
    with ThreadPoolExecutor(max_workers=8) as pool:
        digests = dict(zip(to_hash, pool.map(sha256_file, to_hash.values()), strict=True))
    for name, digest in digests.items():
        if digest != wanted[name]["sha256"]:
            raise SystemExit(f"sha256 mismatch for {name}: {digest} != {wanted[name]['sha256']}")
    log("info", "verified files", files=len(rel), hashed=len(digests))

    return [
        {"path": name, "size": path.stat().st_size, "sha256": digests.get(name)} for name, path in sorted(rel.items())
    ]


def upload(settings: Settings, local: Path, manifest: list[dict[str, Any]]) -> None:
    import boto3
    from boto3.s3.transfer import TransferConfig

    s3 = boto3.client("s3", region_name=settings.region)
    config = TransferConfig(
        multipart_threshold=64 * 1024 * 1024,
        multipart_chunksize=64 * 1024 * 1024,
        max_concurrency=32,
    )
    start = time.monotonic()
    total = 0
    for entry in manifest:
        key = settings.prefix + entry["path"]
        s3.upload_file(str(local / entry["path"]), settings.bucket, key, Config=config)
        total += entry["size"]
        log("info", "uploaded", key=key, bytes=entry["size"])
    seconds = time.monotonic() - start
    log(
        "info",
        "upload finished",
        bytes=total,
        seconds=round(seconds, 1),
        mb_per_s=round(total / 1e6 / max(seconds, 1), 1),
    )

    marker = {
        "repo": settings.repo,
        "revision": settings.revision,
        "model_name": settings.model_name,
        "uploaded_at": datetime.now(UTC).isoformat(),
        "total_bytes": total,
        "files": manifest,
    }
    s3.put_object(
        Bucket=settings.bucket,
        Key=settings.prefix + MARKER,
        Body=json.dumps(marker, indent=2).encode(),
        ContentType="application/json",
    )
    log("info", "wrote completion marker", key=settings.prefix + MARKER)


def already_uploaded(settings: Settings) -> bool:
    import boto3
    from botocore.exceptions import ClientError

    s3 = boto3.client("s3", region_name=settings.region)
    try:
        s3.head_object(Bucket=settings.bucket, Key=settings.prefix + MARKER)
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") in {"404", "NoSuchKey", "NotFound"}:
            return False
        raise
    return True


def scale_uploader_to_zero(settings: Settings) -> None:
    if not settings.asg_name:
        return
    import boto3

    try:
        boto3.client("autoscaling", region_name=settings.region).set_desired_capacity(
            AutoScalingGroupName=settings.asg_name, DesiredCapacity=0, HonorCooldown=False
        )
        log("info", "set uploader group to 0", asg=settings.asg_name)
    except Exception as exc:
        log("error", "could not scale uploader group to 0", asg=settings.asg_name, error=str(exc))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="list and check the repo only")
    parser.add_argument("--force", action="store_true", help="upload even if the marker exists")
    args = parser.parse_args()

    settings = load_settings(args.dry_run)
    try:
        token = hf_token(settings) if not args.dry_run else os.environ.get("HF_TOKEN")
        wanted = check_repo(settings, token)
        total = sum(meta["size"] or 0 for meta in wanted.values())
        log("info", "repo checked", repo=settings.repo, revision=settings.revision, files=sorted(wanted), bytes=total)
        if args.dry_run:
            return 0
        if already_uploaded(settings) and not args.force:
            log("info", "already uploaded; nothing to do", prefix=settings.prefix)
            return 0
        local = download(settings, token, work_dir(settings))
        manifest = verify(local, wanted)
        upload(settings, local, manifest)
        return 0
    except SystemExit as exc:
        log("error", str(exc))
        return 1
    except Exception as exc:
        log("error", "upload failed", error=repr(exc))
        raise
    finally:
        if not args.dry_run:
            scale_uploader_to_zero(settings)


if __name__ == "__main__":
    sys.exit(main())
