"""Interactive session helpers and the tunnel-or-queue chat() helper."""

from __future__ import annotations

import json
import os
import threading
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

import pytest

from qwenq import api, client, session
from tests.client.test_client import make_queue, make_settings, put_result
from tests.conftest import Aws


class FakeVllmHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args: Any) -> None:
        pass

    model = "qwen-test"

    def do_GET(self) -> None:
        if self.path == "/v1/models":
            data = json.dumps({"data": [{"id": self.model}]}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_response(200 if self.path == "/health" else 404)
        self.end_headers()

    def do_POST(self) -> None:
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        reply = {
            "choices": [{"message": {"content": f"echo {body['messages'][-1]['content']}"}}],
            "usage": {"prompt_tokens": 3, "completion_tokens": 2},
        }
        data = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


@pytest.fixture
def fake_tunnel() -> Iterator[int]:
    server = ThreadingHTTPServer(("127.0.0.1", 0), FakeVllmHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield server.server_address[1]
    server.shutdown()


@pytest.mark.unit
def test_tunnel_healthy(fake_tunnel: int) -> None:
    assert session.tunnel_healthy(fake_tunnel) is True
    assert session.tunnel_healthy(1) is False


def write_config(aws: Aws, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    config_path = tmp_path / "config.json"
    config_path.write_text(make_settings(aws).to_json())
    monkeypatch.setenv("QWENQ_CONFIG", str(config_path))


def test_chat_prefers_open_tunnel(aws: Aws, fake_tunnel: int, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    write_config(aws, tmp_path, monkeypatch)
    session.write_state(fake_tunnel, os.getpid(), "i-1")  # as `qwenq session` does
    result = client.chat([{"role": "user", "content": "hi"}], port=fake_tunnel)
    assert (result["via"], result["status"], result["output"]) == ("tunnel", "ok", "echo hi")
    assert aws.queue_counts() == (0, 0)  # nothing went through SQS
    assert aws.desired() == 0  # and the GPU was not woken


def test_chat_falls_back_to_queue(aws: Aws, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    write_config(aws, tmp_path, monkeypatch)
    queue_result(aws, monkeypatch)
    result = client.chat([{"role": "user", "content": "hi"}], port=1)  # no tunnel on port 1
    assert (result["via"], result["output"]) == ("queue", "from queue")
    assert aws.desired() == 1  # the queue path wakes the GPU


def queue_result(aws: Aws, monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_wait(self: api.QwenQueue, request_id: str, **_kw: Any) -> dict[str, Any]:
        put_result(aws, request_id, status="ok", output="from queue")
        return self.get_result(request_id)  # type: ignore[return-value]

    monkeypatch.setattr(api.QwenQueue, "wait", fake_wait)


def test_listener_without_session_is_not_trusted(
    aws: Aws, fake_tunnel: int, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A healthy endpoint on the port is not enough: no session file, so the queue."""
    write_config(aws, tmp_path, monkeypatch)
    queue_result(aws, monkeypatch)
    result = client.chat([{"role": "user", "content": "secret"}], port=fake_tunnel)
    assert result["via"] == "queue"


def test_dead_session_is_not_trusted(
    aws: Aws, fake_tunnel: int, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    write_config(aws, tmp_path, monkeypatch)
    queue_result(aws, monkeypatch)
    session.write_state(fake_tunnel, 2**22 + 12345, "i-1")  # no such pid
    assert client.chat([{"role": "user", "content": "x"}], port=fake_tunnel)["via"] == "queue"


def test_wrong_model_is_not_trusted(
    aws: Aws, fake_tunnel: int, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    write_config(aws, tmp_path, monkeypatch)
    session.write_state(fake_tunnel, os.getpid(), "i-1")
    monkeypatch.setattr(FakeVllmHandler, "model", "someone-elses-model")
    assert session.trusted_tunnel(fake_tunnel, "qwen-test") is False
    with pytest.raises(RuntimeError):
        client.chat([{"role": "user", "content": "x"}], prefer="tunnel", port=fake_tunnel)


def test_clear_state(aws: Aws, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    write_config(aws, tmp_path, monkeypatch)
    path = session.write_state(8000, os.getpid(), "i-1")
    assert oct(path.stat().st_mode & 0o777) == "0o600"
    session.clear_state()
    assert not path.exists()


@pytest.mark.unit
def test_chat_rejects_bad_prefer() -> None:
    with pytest.raises(ValueError):
        client.chat([], prefer="fast")


class FakeSsm:
    def __init__(self, online_after: int) -> None:
        self.calls = 0
        self.online_after = online_after

    def describe_instance_information(self, **_kw: Any) -> dict[str, Any]:
        self.calls += 1
        status = "Online" if self.calls >= self.online_after else "ConnectionLost"
        return {"InstanceInformationList": [{"PingStatus": status}]}


def test_wait_for_worker_wakes_then_waits_for_ssm(aws: Aws, monkeypatch: pytest.MonkeyPatch) -> None:
    queue = make_queue(aws)
    monkeypatch.setattr(api.QwenQueue, "worker_instance_id", lambda self: "i-0123456789abcdef0")
    progress: list[str] = []
    ticks = iter(range(0, 10_000, 5))
    ready = session.wait_for_worker(
        queue, FakeSsm(online_after=3), on_progress=progress.append, sleep=lambda _s: None, clock=lambda: next(ticks)
    )
    assert ready.instance_id == "i-0123456789abcdef0"
    assert aws.desired() == 1
    assert any("woke it" in p for p in progress)
    assert any("waiting for SSM" in p for p in progress)


def test_wait_for_worker_times_out(aws: Aws, monkeypatch: pytest.MonkeyPatch) -> None:
    queue = make_queue(aws)
    monkeypatch.setattr(api.QwenQueue, "worker_instance_id", lambda self: None)
    ticks = iter(range(0, 10_000, 100))
    with pytest.raises(session.SessionError):
        session.wait_for_worker(queue, FakeSsm(1), timeout_s=300, sleep=lambda _s: None, clock=lambda: next(ticks))


@pytest.mark.unit
def test_tunnel_command_forwards_vllm_port() -> None:
    command = session.tunnel_command("/usr/bin/aws", "eu-north-1", "i-1", 8001, "qwen-spot")
    params = json.loads(command[command.index("--parameters") + 1])
    assert params == {"portNumber": ["8000"], "localPortNumber": ["8001"]}
    assert command[-2:] == ["--profile", "qwen-spot"]
    assert "AWS-StartPortForwardingSession" in command
