from __future__ import annotations

import json
import logging

import pytest

from qwen_worker import logs, main
from qwen_worker.config import WorkerConfig

pytestmark = pytest.mark.unit


def test_json_formatter_includes_extra_fields() -> None:
    record = logging.LogRecord("qwen", logging.INFO, __file__, 1, "hello %s", ("world",), None)
    record.request_id = "abc"
    entry = json.loads(logs.JsonFormatter().format(record))
    assert entry["msg"] == "hello world"
    assert entry["request_id"] == "abc"
    assert entry["level"] == "INFO"


def test_main_exits_2_on_missing_config(monkeypatch: pytest.MonkeyPatch) -> None:
    for key in ("QWEN_REGION", "QWEN_QUEUE_URL", "QWEN_RESULTS_BUCKET", "QWEN_ASG_NAME", "QWEN_MODEL_NAME"):
        monkeypatch.delenv(key, raising=False)
    assert main.main() == 2


def test_build_worker_wires_clients() -> None:
    config = WorkerConfig(region="eu-north-1", queue_url="q", results_bucket="b", asg_name="g", model_name="m")
    worker = main.build_worker(config)
    assert worker.config is config
    assert worker.imds is not None
