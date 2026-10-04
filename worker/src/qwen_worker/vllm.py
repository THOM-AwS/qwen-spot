"""Thin client for the local vLLM OpenAI-compatible server."""

from __future__ import annotations

import logging
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

import httpx

log = logging.getLogger(__name__)


class VllmError(RuntimeError):
    """A failed call. ``retryable`` is False for client errors (4xx)."""

    def __init__(self, message: str, *, retryable: bool) -> None:
        super().__init__(message)
        self.retryable = retryable


@dataclass(frozen=True)
class Completion:
    output: str | None
    reasoning: str | None
    usage: dict[str, int]
    generation_s: float


class VllmClient:
    def __init__(self, base_url: str, *, timeout_s: float, transport: httpx.BaseTransport | None = None) -> None:
        self._http = httpx.Client(
            base_url=base_url,
            timeout=httpx.Timeout(timeout_s, connect=10.0),
            transport=transport,
        )

    def close(self) -> None:
        self._http.close()

    def healthy(self) -> bool:
        try:
            return self._http.get("/health", timeout=5.0).status_code == 200
        except httpx.HTTPError:
            return False

    def wait_healthy(
        self,
        timeout_s: float,
        *,
        should_stop: Callable[[], bool] = lambda: False,
        sleep: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.monotonic,
    ) -> bool:
        deadline = clock() + timeout_s
        while clock() < deadline:
            if should_stop():
                return False
            if self.healthy():
                return True
            sleep(2.0)
        return False

    def chat(self, payload: dict[str, Any]) -> Completion:
        started = time.monotonic()
        try:
            response = self._http.post("/v1/chat/completions", json=payload)
        except httpx.HTTPError as exc:
            raise VllmError(f"vLLM request failed: {exc!r}", retryable=True) from exc
        elapsed = time.monotonic() - started

        if response.status_code >= 400:
            # 4xx means the request itself is bad (context too long, bad params);
            # retrying it will fail the same way.
            raise VllmError(
                f"vLLM returned {response.status_code}: {response.text[:2000]}",
                retryable=response.status_code >= 500 or response.status_code == 429,
            )
        try:
            body = response.json()
            message = body["choices"][0]["message"]
        except (ValueError, KeyError, IndexError, TypeError) as exc:
            raise VllmError(f"unexpected vLLM response: {response.text[:2000]}", retryable=True) from exc

        usage = body.get("usage") or {}
        return Completion(
            output=message.get("content"),
            # vLLM's qwen3 reasoning parser puts the thinking block here.
            reasoning=message.get("reasoning_content") or message.get("reasoning"),
            usage={
                "prompt_tokens": int(usage.get("prompt_tokens", 0)),
                "completion_tokens": int(usage.get("completion_tokens", 0)),
            },
            generation_s=elapsed,
        )
