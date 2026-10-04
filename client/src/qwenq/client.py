"""One call for scripts: use the tunnel when a session is open, else the queue.

    from qwenq.client import chat
    result = chat([{"role": "user", "content": "hi"}], params={"max_tokens": 64})
    print(result["output"], result["via"])

The result has the same shape either way (see the README's result schema), plus
``via``: "tunnel" or "queue".
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from typing import Any

import boto3

from qwenq import api, settings
from qwenq.session import DEFAULT_PORT, tunnel_healthy


def chat(
    messages: list[dict[str, Any]],
    *,
    params: dict[str, Any] | None = None,
    prefer: str = "auto",
    port: int = DEFAULT_PORT,
    profile: str | None = None,
    timeout_s: float = 3600.0,
) -> dict[str, Any]:
    """Chat completion through the fastest available path.

    ``prefer``: "auto" (tunnel if healthy, else queue), "tunnel" or "queue".
    The queue path wakes the GPU if it is at 0 and waits for the result.
    """
    if prefer not in {"auto", "tunnel", "queue"}:
        raise ValueError("prefer must be auto, tunnel or queue")
    config = settings.load()
    use_tunnel = prefer == "tunnel" or (prefer == "auto" and tunnel_healthy(port))
    if use_tunnel:
        return _chat_tunnel(messages, params or {}, config.model_name, port, timeout_s)
    queue = api.QwenQueue.from_session(config, boto3.session.Session(profile_name=profile))
    submitted = queue.submit(api.build_request(messages, params))
    return {**queue.wait(submitted.request_id, timeout_s=timeout_s), "via": "queue"}


def _chat_tunnel(
    messages: list[dict[str, Any]], params: dict[str, Any], model: str, port: int, timeout_s: float
) -> dict[str, Any]:
    body = json.dumps({"model": model, "messages": messages, **params, "stream": False}).encode()
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/chat/completions",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=timeout_s) as response:  # noqa: S310  # nosec B310
            payload = json.loads(response.read())
    except urllib.error.HTTPError as exc:
        return _result("error", error=f"vLLM returned {exc.code}: {exc.read()[:2000].decode(errors='replace')}")
    except (urllib.error.URLError, OSError) as exc:
        return _result("error", error=f"tunnel request failed: {exc}")
    message = payload["choices"][0]["message"]
    usage = payload.get("usage") or {}
    return _result(
        "ok",
        output=message.get("content"),
        reasoning=message.get("reasoning_content") or message.get("reasoning"),
        usage={
            "prompt_tokens": int(usage.get("prompt_tokens", 0)),
            "completion_tokens": int(usage.get("completion_tokens", 0)),
        },
        generation_s=time.monotonic() - started,
        model=model,
    )


def _result(status: str, **fields: Any) -> dict[str, Any]:
    generation_s = fields.pop("generation_s", 0.0)
    return {
        "request_id": None,
        "status": status,
        "output": fields.get("output"),
        "reasoning": fields.get("reasoning"),
        "usage": fields.get("usage") or {"prompt_tokens": 0, "completion_tokens": 0},
        "timings": {"queued_s": 0.0, "generation_s": round(generation_s, 3)},
        "error": fields.get("error"),
        "attempt": 1,
        "final": True,
        "model": fields.get("model"),
        "metadata": {},
        "via": "tunnel",
    }
