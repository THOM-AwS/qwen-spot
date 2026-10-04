"""Entry point for the qwen-worker systemd unit."""

from __future__ import annotations

import logging
import os
import signal
import sys
from types import FrameType

import boto3
from botocore.config import Config

from qwen_worker import logs
from qwen_worker.config import ConfigError, WorkerConfig
from qwen_worker.imds import Imds
from qwen_worker.runner import Worker
from qwen_worker.vllm import VllmClient

log = logging.getLogger("qwen_worker")


def build_worker(config: WorkerConfig) -> Worker:
    session = boto3.session.Session(region_name=config.region)
    # Enough pooled connections for every job thread plus heartbeat and poller.
    boto_config = Config(max_pool_connections=config.concurrency + 4, retries={"mode": "standard"})
    return Worker(
        config,
        sqs=session.client("sqs", config=boto_config),
        s3=session.client("s3", config=boto_config),
        autoscaling=session.client("autoscaling", config=boto_config),
        vllm=VllmClient(config.vllm_url, timeout_s=config.request_timeout_s),
        imds=Imds(),
        cloudwatch=session.client("cloudwatch", config=boto_config),
    )


def main() -> int:
    logs.configure()
    try:
        config = WorkerConfig.from_env()
    except ConfigError as exc:
        log.error("bad configuration", extra={"error": str(exc)})
        return 2

    worker = build_worker(config)

    def on_sigterm(signum: int, _frame: FrameType | None) -> None:
        worker.request_terminate(f"signal {signal.Signals(signum).name}")

    signal.signal(signal.SIGTERM, on_sigterm)
    signal.signal(signal.SIGINT, on_sigterm)
    log.info(
        "starting",
        extra={
            "queue_url": config.queue_url,
            "asg": config.asg_name,
            "concurrency": config.concurrency,
            "idle_minutes": config.idle_minutes,
        },
    )
    return worker.run()


def run() -> None:
    """Console-script entry point.

    Exits hard: by the time run() returns, in-flight messages have been handed
    back, and a normal exit would block joining job threads still waiting on vLLM.
    """
    code = main()
    logging.shutdown()
    sys.stdout.flush()
    os._exit(code)


if __name__ == "__main__":
    run()
