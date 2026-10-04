"""Worker behaviour against moto SQS/S3/ASG and a fake vLLM."""

from __future__ import annotations

import json
import threading
import time
import uuid
from dataclasses import replace
from typing import Any

import httpx
import pytest

from qwen_worker import schema
from qwen_worker.config import ConfigError, WorkerConfig
from qwen_worker.imds import Imds
from qwen_worker.runner import Worker
from qwen_worker.vllm import VllmClient
from tests.conftest import Aws, FakeVllm

pytestmark = pytest.mark.integration


class FakeClock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


def make_config(aws: Aws, **overrides: Any) -> WorkerConfig:
    config = WorkerConfig(
        region="eu-north-1",
        queue_url=aws.queue_url,
        results_bucket=aws.bucket,
        asg_name=aws.asg_name,
        model_name="qwen-test",
        concurrency=2,
        poll_wait_s=0,
    )
    return replace(config, **overrides)


def make_worker(aws: Aws, vllm: FakeVllm, *, imds: Imds | None = None, clock: Any = None, **overrides: Any) -> Worker:
    return Worker(
        make_config(aws, **overrides),
        sqs=aws.sqs,
        s3=aws.s3,
        autoscaling=aws.autoscaling,
        vllm=VllmClient("http://vllm", timeout_s=5, transport=vllm.transport()),
        imds=imds,
        clock=clock or FakeClock(),
    )


def send(aws: Aws, body: dict[str, Any] | str) -> None:
    aws.sqs.send_message(QueueUrl=aws.queue_url, MessageBody=body if isinstance(body, str) else json.dumps(body))


def request(prompt: str = "hi", **extra: Any) -> dict[str, Any]:
    return {
        "request_id": str(uuid.uuid4()),
        "messages": [{"role": "user", "content": prompt}],
        "params": {"max_tokens": 16},
        "metadata": {"tag": "t"},
        **extra,
    }


def put_result(aws: Aws, request_id: str, **fields: Any) -> None:
    result = schema.make_result(request_id, **fields)
    aws.s3.put_object(Bucket=aws.bucket, Key=f"results/{request_id}.json", Body=json.dumps(result).encode())


def receive(aws: Aws, visibility: int = 900) -> dict[str, Any]:
    messages = aws.sqs.receive_message(
        QueueUrl=aws.queue_url,
        VisibilityTimeout=visibility,
        MessageSystemAttributeNames=["ApproximateReceiveCount", "SentTimestamp"],
    )["Messages"]
    assert len(messages) == 1
    return messages[0]


# ---- config ---------------------------------------------------------------


@pytest.mark.unit
def test_config_from_env_reads_contract_keys() -> None:
    env = {
        "QWEN_REGION": "eu-north-1",
        "QWEN_QUEUE_URL": "https://sqs/q",
        "QWEN_RESULTS_BUCKET": "b",
        "QWEN_ASG_NAME": "g",
        "QWEN_MODEL_NAME": "m",
        "QWEN_IDLE_MINUTES": "7",
        "QWEN_WORKER_CONCURRENCY": "4",
        "QWEN_VISIBILITY_TIMEOUT": "600",
    }
    config = WorkerConfig.from_env(env)
    assert (config.idle_minutes, config.concurrency, config.visibility_timeout) == (7.0, 4, 600)
    assert config.heartbeat_interval_s == 200


@pytest.mark.unit
@pytest.mark.parametrize(("key", "value"), [("QWEN_QUEUE_URL", ""), ("QWEN_WORKER_CONCURRENCY", "zero")])
def test_config_rejects_bad_values(key: str, value: str) -> None:
    env = {
        "QWEN_REGION": "r",
        "QWEN_QUEUE_URL": "q",
        "QWEN_RESULTS_BUCKET": "b",
        "QWEN_ASG_NAME": "g",
        "QWEN_MODEL_NAME": "m",
        key: value,
    }
    with pytest.raises(ConfigError):
        WorkerConfig.from_env(env)


# ---- one message ----------------------------------------------------------


def test_success_writes_result_and_deletes(aws: Aws, fake_vllm: FakeVllm) -> None:
    req = request()
    send(aws, req)
    make_worker(aws, fake_vllm).handle(receive(aws))

    result = aws.result(req["request_id"])
    assert result is not None
    assert result["status"] == "ok"
    assert result["output"] == "hello from fake vllm"
    assert result["reasoning"] == "thinking..."
    assert result["usage"] == {"prompt_tokens": 11, "completion_tokens": 7}
    assert result["metadata"] == {"tag": "t"}
    assert aws.queue_counts() == (0, 0)
    sent = fake_vllm.requests[0]
    assert sent["model"] == "qwen-test"
    assert sent["max_tokens"] == 16
    assert sent["stream"] is False


def test_retryable_error_writes_non_final_result_and_keeps_message(aws: Aws, fake_vllm: FakeVllm) -> None:
    fake_vllm.status_code = 503
    req = request()
    send(aws, req)
    make_worker(aws, fake_vllm).handle(receive(aws))

    result = aws.result(req["request_id"])
    assert result is not None
    assert (result["status"], result["final"], result["attempt"]) == ("error", False, 1)
    assert aws.queue_counts() == (0, 1)  # hidden for the retry backoff, not deleted


def test_last_attempt_error_is_final_and_deleted(aws: Aws, fake_vllm: FakeVllm) -> None:
    fake_vllm.status_code = 500
    req = request()
    put_result(aws, req["request_id"], status="error", error="earlier", attempt=2, final=False)
    send(aws, req)
    make_worker(aws, fake_vllm, max_attempts=3).handle(receive(aws))
    result = aws.result(req["request_id"])
    assert result is not None
    assert (result["attempt"], result["final"]) == (3, True)
    assert aws.queue_counts() == (0, 0)  # final: deleted, not left for the DLQ


def test_receive_count_does_not_burn_attempts(aws: Aws, fake_vllm: FakeVllm) -> None:
    """A message handed back by interruptions has a high receive count but no failed attempts."""
    fake_vllm.status_code = 503
    req = request()
    send(aws, req)
    message = receive(aws)
    message["Attributes"]["ApproximateReceiveCount"] = "4"
    make_worker(aws, fake_vllm, max_attempts=3).handle(message)
    result = aws.result(req["request_id"])
    assert result is not None
    assert (result["attempt"], result["final"]) == (1, False)


def test_error_never_overwrites_ok(aws: Aws, fake_vllm: FakeVllm) -> None:
    req = request()
    send(aws, req)
    worker = make_worker(aws, fake_vllm)
    message = receive(aws)
    put_result(aws, req["request_id"], status="ok", output="twin finished first")
    fake_vllm.status_code = 503
    worker._write_error(schema.make_result(req["request_id"], status="error", error="late"))
    assert aws.result(req["request_id"])["output"] == "twin finished first"  # type: ignore[index]
    worker.handle(message)  # duplicate path: deletes without generating
    assert fake_vllm.requests == []


def test_unexpected_failure_on_last_receive_writes_final_result(aws: Aws, fake_vllm: FakeVllm) -> None:
    req = request()
    send(aws, req)
    message = receive(aws)
    message["Attributes"]["ApproximateReceiveCount"] = "5"
    worker = make_worker(aws, fake_vllm, max_receive_count=5)
    worker.in_flight.add(message["ReceiptHandle"])

    def boom(_message: dict[str, Any]) -> None:
        raise RuntimeError("s3 down")

    worker.handle = boom  # type: ignore[method-assign]
    worker._run_job(message)
    result = aws.result(req["request_id"])
    assert result is not None
    assert result["final"] is True and "s3 down" in result["error"]
    assert len(worker.in_flight) == 0


def test_client_error_is_final_and_deleted(aws: Aws, fake_vllm: FakeVllm) -> None:
    fake_vllm.status_code = 400
    req = request()
    send(aws, req)
    make_worker(aws, fake_vllm).handle(receive(aws))
    result = aws.result(req["request_id"])
    assert result is not None
    assert (result["status"], result["final"]) == ("error", True)
    assert aws.queue_counts() == (0, 0)


def test_invalid_message_is_deleted_with_error_result(aws: Aws, fake_vllm: FakeVllm) -> None:
    req = request()
    req["params"] = {"model": "something-else"}
    send(aws, req)
    make_worker(aws, fake_vllm).handle(receive(aws))
    result = aws.result(req["request_id"])
    assert result is not None
    assert "unsupported params" in result["error"]
    assert aws.queue_counts() == (0, 0)
    assert fake_vllm.requests == []


def test_garbage_body_is_dropped(aws: Aws, fake_vllm: FakeVllm) -> None:
    send(aws, "not json")
    make_worker(aws, fake_vllm).handle(receive(aws))
    assert aws.queue_counts() == (0, 0)


def test_pointer_message_loads_payload_from_s3(aws: Aws, fake_vllm: FakeVllm) -> None:
    req = request("x" * 1000)
    key = f"requests/{req['request_id']}.json"
    aws.s3.put_object(Bucket=aws.bucket, Key=key, Body=json.dumps(req).encode())
    send(aws, {"request_id": req["request_id"], "payload_key": key})
    make_worker(aws, fake_vllm).handle(receive(aws))
    assert aws.result(req["request_id"])["status"] == "ok"  # type: ignore[index]
    assert fake_vllm.requests[0]["messages"][0]["content"] == "x" * 1000


def test_duplicate_delivery_skips_generation(aws: Aws, fake_vllm: FakeVllm) -> None:
    req = request()
    send(aws, req)
    worker = make_worker(aws, fake_vllm)
    worker.handle(receive(aws))
    send(aws, req)
    worker.handle(receive(aws))
    assert len(fake_vllm.requests) == 1
    assert aws.queue_counts() == (0, 0)


# ---- concurrency, visibility, interruption --------------------------------


def test_poll_once_processes_in_parallel(aws: Aws, fake_vllm: FakeVllm) -> None:
    barrier = threading.Barrier(2, timeout=5)
    fake_vllm.on_chat = lambda _payload: barrier.wait()  # both must be in flight at once
    reqs = [request(), request()]
    for req in reqs:
        send(aws, req)
    worker = make_worker(aws, fake_vllm)
    received = 0
    while received < 2:
        received += max(worker.poll_once(), 0)
    worker._pool.shutdown(wait=True)
    assert all(aws.result(r["request_id"])["status"] == "ok" for r in reqs)  # type: ignore[index]
    assert len(worker.in_flight) == 0


def test_release_in_flight_makes_messages_visible(aws: Aws, fake_vllm: FakeVllm) -> None:
    send(aws, request())
    message = receive(aws)
    worker = make_worker(aws, fake_vllm)
    worker.in_flight.add(message["ReceiptHandle"])
    assert aws.queue_counts() == (0, 1)
    worker.release_in_flight()
    assert aws.queue_counts() == (1, 0)


def test_heartbeat_keeps_message_hidden(aws: Aws, fake_vllm: FakeVllm) -> None:
    send(aws, request())
    message = receive(aws, visibility=1)
    worker = make_worker(aws, fake_vllm)
    worker.in_flight.add(message["ReceiptHandle"])
    worker.heartbeat_once()
    time.sleep(1.5)  # past the original 1 s visibility
    assert aws.queue_counts() == (0, 1)


def test_heartbeat_after_release_does_not_rehide(aws: Aws, fake_vllm: FakeVllm) -> None:
    send(aws, request())
    message = receive(aws)
    worker = make_worker(aws, fake_vllm)
    worker.in_flight.add(message["ReceiptHandle"])
    worker.request_stop("test")
    worker.release_in_flight()
    worker.heartbeat_once()
    assert aws.queue_counts() == (1, 0)
    assert not worker.in_flight.owns(message["ReceiptHandle"])


def test_retry_backoff_skipped_after_release(aws: Aws, fake_vllm: FakeVllm) -> None:
    send(aws, request())
    message = receive(aws)
    worker = make_worker(aws, fake_vllm)
    worker.in_flight.add(message["ReceiptHandle"])
    worker.release_in_flight()
    worker._change_visibility(message["ReceiptHandle"], 600)
    assert aws.queue_counts() == (1, 0)


def imds_with(notice_path: str | None, body: str = "") -> Imds:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "PUT":
            return httpx.Response(200, text="token")
        assert request.headers["X-aws-ec2-metadata-token"] == "token"
        if notice_path and request.url.path == notice_path:
            return httpx.Response(200, text=body)
        return httpx.Response(404)

    return Imds(base_url="http://imds", transport=httpx.MockTransport(handler))


def test_spot_notice_stops_and_releases(aws: Aws, fake_vllm: FakeVllm) -> None:
    send(aws, request())
    message = receive(aws)
    imds = imds_with("/latest/meta-data/spot/instance-action", '{"action": "terminate"}')
    worker = make_worker(aws, fake_vllm, imds=imds)
    worker.in_flight.add(message["ReceiptHandle"])
    assert worker.check_interruption_once() is True
    assert worker.stop.is_set()
    assert "spot interruption" in (worker.stop_reason or "")
    assert aws.queue_counts() == (1, 0)


def test_asg_termination_state_counts_as_notice(aws: Aws, fake_vllm: FakeVllm) -> None:
    imds = imds_with("/latest/meta-data/autoscaling/target-lifecycle-state", "Terminated")
    worker = make_worker(aws, fake_vllm, imds=imds)
    assert worker.check_interruption_once() is True


def test_no_notice(aws: Aws, fake_vllm: FakeVllm) -> None:
    worker = make_worker(aws, fake_vllm, imds=imds_with(None))
    assert worker.check_interruption_once() is False
    assert not worker.stop.is_set()


# ---- idle scale-in ----------------------------------------------------------


def test_scale_in_after_idle_minutes(aws: Aws, fake_vllm: FakeVllm) -> None:
    aws.autoscaling.set_desired_capacity(AutoScalingGroupName=aws.asg_name, DesiredCapacity=1)
    clock = FakeClock()
    worker = make_worker(aws, fake_vllm, clock=clock, idle_minutes=5)
    clock.now += 299
    assert worker.maybe_scale_in() is False
    clock.now += 2
    assert worker.maybe_scale_in() is True
    assert aws.desired() == 0
    assert worker.scaled_in and worker.stop.is_set()


def test_no_scale_in_with_backlog(aws: Aws, fake_vllm: FakeVllm) -> None:
    aws.autoscaling.set_desired_capacity(AutoScalingGroupName=aws.asg_name, DesiredCapacity=1)
    send(aws, request())
    clock = FakeClock()
    worker = make_worker(aws, fake_vllm, clock=clock, idle_minutes=5)
    clock.now += 600
    assert worker.maybe_scale_in() is False
    assert aws.desired() == 1


def test_no_scale_in_with_work_in_flight(aws: Aws, fake_vllm: FakeVllm) -> None:
    clock = FakeClock()
    worker = make_worker(aws, fake_vllm, clock=clock, idle_minutes=0)
    worker.in_flight.add("r")
    clock.now += 600
    assert worker.maybe_scale_in() is False


def test_resume_when_woken_before_termination(aws: Aws, fake_vllm: FakeVllm) -> None:
    worker = make_worker(aws, fake_vllm, idle_minutes=0)
    assert worker.maybe_scale_in() is True
    aws.autoscaling.set_desired_capacity(AutoScalingGroupName=aws.asg_name, DesiredCapacity=1)
    assert worker.wait_for_scale_in(grace_s=0, recheck_s=0) is True
    assert not worker.stop.is_set() and not worker.scaled_in


def test_message_racing_scale_in_rewakes_group(aws: Aws, fake_vllm: FakeVllm) -> None:
    worker = make_worker(aws, fake_vllm, idle_minutes=0)
    assert worker.maybe_scale_in() is True
    assert aws.desired() == 0
    send(aws, request())  # client saw desired=1 and skipped its wake
    assert worker.wait_for_scale_in(grace_s=0, recheck_s=0) is True
    assert aws.desired() == 1


def test_interruption_during_scale_in_never_resumes(aws: Aws, fake_vllm: FakeVllm) -> None:
    worker = make_worker(aws, fake_vllm, idle_minutes=0, imds=imds_with("/latest/meta-data/spot/instance-action", "{}"))
    assert worker.maybe_scale_in() is True
    send(aws, request())
    assert worker.check_interruption_once() is True
    assert worker.wait_for_scale_in(grace_s=0, recheck_s=0) is False
    assert worker.stop.is_set()


def test_stay_down_when_terminating(aws: Aws, fake_vllm: FakeVllm) -> None:
    worker = make_worker(aws, fake_vllm, idle_minutes=0)
    assert worker.maybe_scale_in() is True
    worker.request_terminate("SIGTERM")
    assert worker.wait_for_scale_in(grace_s=5, recheck_s=5) is False


def test_run_end_to_end_drains_then_scales_in(aws: Aws, fake_vllm: FakeVllm) -> None:
    """Full loop: health wait, drain two messages, go idle, scale in, exit on SIGTERM."""
    aws.autoscaling.set_desired_capacity(AutoScalingGroupName=aws.asg_name, DesiredCapacity=1)
    reqs = [request(), request()]
    for req in reqs:
        send(aws, req)
    worker = make_worker(aws, fake_vllm, idle_minutes=0.001, clock=time.monotonic)
    exit_code: list[int] = []
    thread = threading.Thread(target=lambda: exit_code.append(worker.run()))
    thread.start()
    assert worker.stop.wait(10), "worker never went idle"
    assert worker.scaled_in
    worker.request_terminate("SIGTERM")
    thread.join(10)
    assert exit_code == [0]
    assert aws.desired() == 0
    assert all(aws.result(r["request_id"])["status"] == "ok" for r in reqs)  # type: ignore[index]


def test_sigterm_before_healthy_exits_cleanly(aws: Aws, fake_vllm: FakeVllm) -> None:
    fake_vllm.healthy = False
    worker = make_worker(aws, fake_vllm, health_timeout_s=30)
    worker.request_terminate("SIGTERM")
    assert worker.run() == 0


def test_run_fails_when_vllm_never_healthy(aws: Aws, fake_vllm: FakeVllm) -> None:
    fake_vllm.healthy = False
    worker = make_worker(aws, fake_vllm, health_timeout_s=0.01)
    assert worker.run() == 1


# ---- direct (tunnel) traffic ---------------------------------------------------

METRICS_IDLE = """# HELP vllm:num_requests_running Number of requests running
vllm:num_requests_running{model_name="m"} 0.0
vllm:num_requests_waiting{model_name="m"} 0.0
vllm:request_success_total{finished_reason="stop",model_name="m"} 3.0
vllm:request_success_total{finished_reason="length",model_name="m"} 1.0
"""


@pytest.mark.unit
def test_parse_activity_sums_labels() -> None:
    from qwen_worker.vllm import parse_activity

    activity = parse_activity(METRICS_IDLE.replace('running{model_name="m"} 0.0', 'running{model_name="m"} 2.0'))
    assert activity.in_progress == 2
    assert activity.finished_total == 4.0


def test_tunnel_traffic_defers_scale_in(aws: Aws, fake_vllm: FakeVllm) -> None:
    clock = FakeClock()
    worker = make_worker(aws, fake_vllm, clock=clock, idle_minutes=5)
    fake_vllm.metrics = METRICS_IDLE
    worker.observe_vllm_activity()  # baseline
    clock.now += 400
    # A request finished over the tunnel since the last look: not idle.
    fake_vllm.metrics = METRICS_IDLE.replace("} 3.0", "} 9.0")
    assert worker.maybe_scale_in() is False
    assert worker.idle_for_s() == 0
    clock.now += 400
    assert worker.maybe_scale_in() is True  # nothing new since: idle again


def test_running_request_counts_as_busy(aws: Aws, fake_vllm: FakeVllm) -> None:
    worker = make_worker(aws, fake_vllm)
    fake_vllm.metrics = METRICS_IDLE.replace('waiting{model_name="m"} 0.0', 'waiting{model_name="m"} 1.0')
    assert worker.observe_vllm_activity() is True


def test_no_metrics_endpoint_is_not_busy(aws: Aws, fake_vllm: FakeVllm) -> None:
    worker = make_worker(aws, fake_vllm)
    assert worker.observe_vllm_activity() is False


def test_publish_activity_metric(aws: Aws, fake_vllm: FakeVllm) -> None:
    import boto3

    cloudwatch = boto3.client("cloudwatch", region_name="eu-north-1")
    clock = FakeClock()
    worker = make_worker(aws, fake_vllm, clock=clock)
    worker.cloudwatch = cloudwatch
    assert worker.publish_activity_once() == 1  # just started: recent activity
    clock.now += 300
    assert worker.publish_activity_once() == 0
    metrics = cloudwatch.list_metrics(Namespace="QwenSpot")["Metrics"]
    assert {m["MetricName"] for m in metrics} == {"Busy"}
    assert metrics[0]["Dimensions"] == [{"Name": "AutoScalingGroupName", "Value": aws.asg_name}]
