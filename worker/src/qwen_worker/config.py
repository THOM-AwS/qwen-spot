"""Worker configuration, read from the environment (/etc/qwen-spot/config.env)."""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass

DEFAULT_VLLM_URL = "http://127.0.0.1:8000"


class ConfigError(ValueError):
    """Raised when a required setting is missing or invalid."""


@dataclass(frozen=True)
class WorkerConfig:
    region: str
    queue_url: str
    results_bucket: str
    asg_name: str
    model_name: str
    idle_minutes: float = 5.0
    concurrency: int = 8
    visibility_timeout: int = 900
    max_receive_count: int = 5
    max_attempts: int = 3
    vllm_url: str = DEFAULT_VLLM_URL
    health_timeout_s: float = 1800.0
    request_timeout_s: float = 3600.0
    interruption_poll_s: float = 5.0
    poll_wait_s: int = 20

    @property
    def heartbeat_interval_s(self) -> float:
        """Extend visibility well before it lapses: a third of the timeout."""
        return max(self.visibility_timeout / 3, 5.0)

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> WorkerConfig:
        env = os.environ if env is None else env

        def required(key: str) -> str:
            value = env.get(key, "").strip()
            if not value:
                raise ConfigError(f"{key} is required")
            return value

        def number(key: str, default: float, minimum: float) -> float:
            raw = env.get(key, "").strip()
            if not raw:
                return default
            try:
                value = float(raw)
            except ValueError as exc:
                raise ConfigError(f"{key}={raw!r} is not a number") from exc
            if value < minimum:
                raise ConfigError(f"{key}={raw!r} must be >= {minimum}")
            return value

        return cls(
            region=required("QWEN_REGION"),
            queue_url=required("QWEN_QUEUE_URL"),
            results_bucket=required("QWEN_RESULTS_BUCKET"),
            asg_name=required("QWEN_ASG_NAME"),
            model_name=required("QWEN_MODEL_NAME"),
            idle_minutes=number("QWEN_IDLE_MINUTES", 5.0, 0.0),
            concurrency=int(number("QWEN_WORKER_CONCURRENCY", 8, 1)),
            visibility_timeout=int(number("QWEN_VISIBILITY_TIMEOUT", 900, 30)),
            max_receive_count=int(number("QWEN_MAX_RECEIVE_COUNT", 5, 1)),
            max_attempts=int(number("QWEN_MAX_ATTEMPTS", 3, 1)),
            vllm_url=env.get("QWEN_VLLM_URL", "").strip() or DEFAULT_VLLM_URL,
            health_timeout_s=number("QWEN_HEALTH_TIMEOUT_S", 1800.0, 1.0),
            request_timeout_s=number("QWEN_REQUEST_TIMEOUT_S", 3600.0, 1.0),
        )
