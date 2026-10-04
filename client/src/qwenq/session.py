"""Interactive sessions: wake the GPU, open an SSM tunnel to vLLM, keep it up.

While a session is open, requests go straight to vLLM's OpenAI-compatible API
on localhost. The worker counts that traffic as activity, so the instance stays
up; once the session ends it scales in after the normal idle timeout.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess  # nosec B404 - runs the local aws CLI only
import time
import urllib.error
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from qwenq import settings
from qwenq.api import QwenQueue

DEFAULT_PORT = 8000
VLLM_PORT = 8000


class SessionError(RuntimeError):
    pass


def state_path() -> Path:
    return settings.path().with_name("session.json")


def write_state(port: int, tunnel_pid: int, instance_id: str) -> Path:
    """Record the open session so chat() only trusts a tunnel we opened."""
    path = state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"port": port, "pid": tunnel_pid, "instance_id": instance_id}))
    path.chmod(0o600)
    return path


def clear_state() -> None:
    state_path().unlink(missing_ok=True)


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def serves_model(port: int, model: str, timeout_s: float = 2.0) -> bool:
    """True when the endpoint on localhost:port is vLLM serving our model."""
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/v1/models", timeout=timeout_s) as response:  # nosec B310 - fixed localhost URL
            models = json.loads(response.read()).get("data", [])
    except (urllib.error.URLError, OSError, ValueError):
        return False
    return any(isinstance(m, dict) and m.get("id") == model for m in models)


def trusted_tunnel(port: int, model: str) -> bool:
    """Use the tunnel only if a live `qwenq session` opened it on this port and
    the endpoint serves our model. Otherwise any local process listening on
    the port (an unrelated dev server, a stale forward) would get the prompt.
    """
    try:
        state = json.loads(state_path().read_text())
    except (OSError, ValueError):
        return False
    if state.get("port") != port or not _pid_alive(int(state.get("pid", 0))):
        return False
    return serves_model(port, model)


def tunnel_healthy(port: int = DEFAULT_PORT, timeout_s: float = 2.0) -> bool:
    """True when vLLM answers /health on localhost:port (a tunnel is open)."""
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=timeout_s) as response:  # nosec B310 - fixed localhost URL
            return response.status == 200
    except (urllib.error.URLError, OSError, ValueError):
        return False


@dataclass(frozen=True)
class Ready:
    instance_id: str
    waited_s: float


def wait_for_worker(
    queue: QwenQueue,
    ssm: object,
    *,
    timeout_s: float = 1200.0,
    on_progress: Callable[[str], None] = lambda _m: None,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> Ready:
    """Wake the group if needed and wait for an InService worker that SSM can reach."""
    start = clock()
    if queue.wake():
        on_progress("group was at 0; woke it (cold start takes a few minutes)")
    last = ""
    while clock() - start < timeout_s:
        instance_id = queue.worker_instance_id()
        state = "waiting for an instance"
        if instance_id:
            info = ssm.describe_instance_information(  # type: ignore[attr-defined]
                Filters=[{"Key": "InstanceIds", "Values": [instance_id]}]
            )["InstanceInformationList"]
            if info and info[0].get("PingStatus") == "Online":
                return Ready(instance_id=instance_id, waited_s=clock() - start)
            state = f"{instance_id} in service, waiting for SSM"
        if state != last:
            on_progress(state)
            last = state
        sleep(5.0)
    raise SessionError(f"no reachable worker after {timeout_s:.0f}s")


def tunnel_command(aws: str, region: str, instance_id: str, local_port: int, profile: str | None) -> list[str]:
    command = [
        aws, "ssm", "start-session",
        "--region", region,
        "--target", instance_id,
        "--document-name", "AWS-StartPortForwardingSession",
        "--parameters", json.dumps({"portNumber": [str(VLLM_PORT)], "localPortNumber": [str(local_port)]}),
    ]  # fmt: skip
    if profile:
        command += ["--profile", profile]
    return command


def aws_cli() -> str:
    aws = os.environ.get("QWENQ_AWS_CLI") or shutil.which("aws")
    if not aws:
        raise SessionError("aws CLI not found (set QWENQ_AWS_CLI); the session-manager-plugin is also required")
    return aws


def open_tunnel(command: list[str]) -> subprocess.Popen[bytes]:
    return subprocess.Popen(  # noqa: S603  # nosec B603 - argv built by tunnel_command, no shell
        command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE
    )


def wait_for_vllm(
    port: int,
    tunnel: subprocess.Popen[bytes],
    *,
    timeout_s: float = 1200.0,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> float:
    """Wait until vLLM answers through the tunnel. Returns seconds waited."""
    start = clock()
    while clock() - start < timeout_s:
        if tunnel.poll() is not None:
            err = tunnel.stderr.read().decode(errors="replace").strip() if tunnel.stderr else ""
            raise SessionError(f"tunnel exited: {err[-500:] or 'no output'}")
        if tunnel_healthy(port):
            return clock() - start
        sleep(3.0)
    raise SessionError(f"vLLM not healthy through the tunnel after {timeout_s:.0f}s (still loading?)")
