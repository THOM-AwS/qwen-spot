"""Shared fixtures: moto-backed AWS resources and a fake vLLM server."""

from __future__ import annotations

import json
from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from typing import Any

import boto3
import httpx
import pytest
from moto import mock_aws

REGION = "eu-north-1"
ASG_NAME = "qwen-spot-workers"


@pytest.fixture(autouse=True)
def _aws_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for key in ("AWS_PROFILE", "AWS_DEFAULT_PROFILE"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_DEFAULT_REGION", REGION)


@dataclass
class Aws:
    sqs: Any
    s3: Any
    autoscaling: Any
    ec2: Any
    queue_url: str
    dlq_url: str
    bucket: str
    asg_name: str

    def desired(self) -> int:
        group = self.autoscaling.describe_auto_scaling_groups(AutoScalingGroupNames=[self.asg_name])
        return group["AutoScalingGroups"][0]["DesiredCapacity"]

    def result(self, request_id: str) -> dict[str, Any] | None:
        try:
            obj = self.s3.get_object(Bucket=self.bucket, Key=f"results/{request_id}.json")
        except self.s3.exceptions.NoSuchKey:
            return None
        return json.loads(obj["Body"].read())

    def queue_counts(self) -> tuple[int, int]:
        attrs = self.sqs.get_queue_attributes(
            QueueUrl=self.queue_url,
            AttributeNames=["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"],
        )["Attributes"]
        return int(attrs["ApproximateNumberOfMessages"]), int(attrs["ApproximateNumberOfMessagesNotVisible"])


@pytest.fixture
def aws() -> Iterator[Aws]:
    with mock_aws():
        sqs = boto3.client("sqs", region_name=REGION)
        s3 = boto3.client("s3", region_name=REGION)
        autoscaling = boto3.client("autoscaling", region_name=REGION)
        ec2 = boto3.client("ec2", region_name=REGION)

        dlq_url = sqs.create_queue(QueueName="qwen-spot-requests-dlq")["QueueUrl"]
        dlq_arn = sqs.get_queue_attributes(QueueUrl=dlq_url, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
        queue_url = sqs.create_queue(
            QueueName="qwen-spot-requests",
            Attributes={
                "VisibilityTimeout": "900",
                "RedrivePolicy": json.dumps({"deadLetterTargetArn": dlq_arn, "maxReceiveCount": "3"}),
            },
        )["QueueUrl"]

        bucket = "qwen-spot-results-test"
        s3.create_bucket(Bucket=bucket, CreateBucketConfiguration={"LocationConstraint": REGION})

        image_id = ec2.describe_images()["Images"][0]["ImageId"]
        autoscaling.create_launch_configuration(
            LaunchConfigurationName="qwen-spot-test", ImageId=image_id, InstanceType="t3.micro"
        )
        autoscaling.create_auto_scaling_group(
            AutoScalingGroupName=ASG_NAME,
            LaunchConfigurationName="qwen-spot-test",
            MinSize=0,
            MaxSize=1,
            DesiredCapacity=0,
            AvailabilityZones=[f"{REGION}a"],
        )
        yield Aws(sqs, s3, autoscaling, ec2, queue_url, dlq_url, bucket, ASG_NAME)


@dataclass
class FakeVllm:
    """httpx transport standing in for vLLM's OpenAI-compatible API."""

    healthy: bool = True
    status_code: int = 200
    content: str = "hello from fake vllm"
    reasoning: str | None = "thinking..."
    requests: list[dict[str, Any]] = field(default_factory=list)
    on_chat: Callable[[dict[str, Any]], None] | None = None
    metrics: str | None = None  # Prometheus text served on /metrics; None means 404

    def handler(self, request: httpx.Request) -> httpx.Response:
        if request.url.path == "/health":
            return httpx.Response(200 if self.healthy else 503)
        if request.url.path == "/metrics":
            return httpx.Response(200, text=self.metrics) if self.metrics is not None else httpx.Response(404)
        if request.url.path == "/v1/chat/completions":
            payload = json.loads(request.content)
            self.requests.append(payload)
            if self.on_chat:
                self.on_chat(payload)
            if self.status_code != 200:
                return httpx.Response(self.status_code, text="boom")
            return httpx.Response(
                200,
                json={
                    "choices": [
                        {"message": {"role": "assistant", "content": self.content, "reasoning_content": self.reasoning}}
                    ],
                    "usage": {"prompt_tokens": 11, "completion_tokens": 7},
                },
            )
        return httpx.Response(404)

    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self.handler)


@pytest.fixture
def fake_vllm() -> FakeVllm:
    return FakeVllm()
