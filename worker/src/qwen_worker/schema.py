"""Request and result schemas shared with the client (see README).

A queue message is either a full request or a pointer to one stored in the
results bucket under ``requests/`` (used when the prompt exceeds the SQS limit).
"""

from __future__ import annotations

import time
import uuid
from dataclasses import dataclass, field
from types import MappingProxyType
from typing import Any

RESULTS_PREFIX = "results/"
REQUESTS_PREFIX = "requests/"

ALLOWED_ROLES = frozenset({"system", "user", "assistant", "tool"})

# Sampling parameters passed through to vLLM. Anything else is rejected so a
# request cannot override the model or other server-side settings.
ALLOWED_PARAMS = frozenset(
    {
        "max_tokens",
        "temperature",
        "top_p",
        "top_k",
        "min_p",
        "presence_penalty",
        "frequency_penalty",
        "repetition_penalty",
        "stop",
        "seed",
        "n",
        "response_format",
        "chat_template_kwargs",
    }
)


class InvalidRequest(ValueError):
    """The message can never succeed; it should not be retried."""


def result_key(request_id: str) -> str:
    return f"{RESULTS_PREFIX}{request_id}.json"


def request_key(request_id: str) -> str:
    return f"{REQUESTS_PREFIX}{request_id}.json"


def validate_request_id(value: Any) -> str:
    """Request ids become S3 keys, so only canonical UUIDs are accepted."""
    if not isinstance(value, str):
        raise InvalidRequest("request_id must be a string")
    try:
        parsed = uuid.UUID(value)
    except ValueError as exc:
        raise InvalidRequest(f"request_id {value!r} is not a UUID") from exc
    if str(parsed) != value.lower():
        raise InvalidRequest(f"request_id {value!r} is not canonical")
    return value.lower()


@dataclass(frozen=True)
class Pointer:
    request_id: str
    payload_key: str


@dataclass(frozen=True)
class Request:
    request_id: str
    messages: tuple[MappingProxyType[str, Any], ...]
    params: MappingProxyType[str, Any] = field(default_factory=lambda: MappingProxyType({}))
    metadata: MappingProxyType[str, Any] = field(default_factory=lambda: MappingProxyType({}))

    def chat_payload(self, model: str) -> dict[str, Any]:
        return {
            "model": model,
            "messages": [dict(m) for m in self.messages],
            **dict(self.params),
            "stream": False,
        }


def parse_body(body: Any) -> Request | Pointer:
    """Parse a decoded queue message body. Raises InvalidRequest."""
    if not isinstance(body, dict):
        raise InvalidRequest("message body must be a JSON object")
    request_id = validate_request_id(body.get("request_id"))
    if "payload_key" in body:
        key = body["payload_key"]
        if key != request_key(request_id):
            raise InvalidRequest(f"payload_key must be {request_key(request_id)!r}")
        return Pointer(request_id=request_id, payload_key=key)
    return parse_request(body)


def parse_request(body: dict[str, Any]) -> Request:
    request_id = validate_request_id(body.get("request_id"))
    raw_messages = body.get("messages")
    if not isinstance(raw_messages, list) or not raw_messages:
        raise InvalidRequest("messages must be a non-empty list")
    messages = []
    for index, message in enumerate(raw_messages):
        if not isinstance(message, dict):
            raise InvalidRequest(f"messages[{index}] must be an object")
        if message.get("role") not in ALLOWED_ROLES:
            raise InvalidRequest(f"messages[{index}].role must be one of {sorted(ALLOWED_ROLES)}")
        if not isinstance(message.get("content"), (str, list)):
            raise InvalidRequest(f"messages[{index}].content must be a string or list")
        messages.append(MappingProxyType(dict(message)))

    params = body.get("params") or {}
    if not isinstance(params, dict):
        raise InvalidRequest("params must be an object")
    unknown = set(params) - ALLOWED_PARAMS
    if unknown:
        raise InvalidRequest(f"unsupported params: {sorted(unknown)}")

    metadata = body.get("metadata") or {}
    if not isinstance(metadata, dict):
        raise InvalidRequest("metadata must be an object")

    return Request(
        request_id=request_id,
        messages=tuple(messages),
        params=MappingProxyType(dict(params)),
        metadata=MappingProxyType(dict(metadata)),
    )


def make_result(
    request_id: str,
    *,
    status: str,
    output: str | None = None,
    reasoning: str | None = None,
    usage: dict[str, int] | None = None,
    queued_s: float = 0.0,
    generation_s: float = 0.0,
    error: str | None = None,
    attempt: int = 1,
    final: bool = True,
    model: str | None = None,
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build the result object written to results/<request_id>.json.

    ``final`` is False for an error that will be retried; clients keep waiting.
    """
    return {
        "request_id": request_id,
        "status": status,
        "output": output,
        "reasoning": reasoning,
        "usage": usage or {"prompt_tokens": 0, "completion_tokens": 0},
        "timings": {"queued_s": round(queued_s, 3), "generation_s": round(generation_s, 3)},
        "error": error,
        "attempt": attempt,
        "final": final,
        "model": model,
        "metadata": metadata or {},
        "finished_at": round(time.time(), 3),
    }
