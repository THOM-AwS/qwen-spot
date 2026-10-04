"""Client against moto, plus a round trip through the worker's parser."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from qwen_worker import schema
from qwenq import api, cli
from qwenq.settings import Settings
from tests.conftest import REGION, Aws

pytestmark = pytest.mark.integration


def make_settings(aws: Aws) -> Settings:
    return Settings(
        region=REGION,
        queue_url=aws.queue_url,
        dlq_url=aws.dlq_url,
        results_bucket=aws.bucket,
        asg_name=aws.asg_name,
        model_name="qwen-test",
        instance_types=("p5.4xlarge",),
    )


def make_queue(aws: Aws) -> api.QwenQueue:
    return api.QwenQueue(make_settings(aws), sqs=aws.sqs, s3=aws.s3, autoscaling=aws.autoscaling, ec2=aws.ec2)


def receive_body(aws: Aws) -> dict[str, Any]:
    message = aws.sqs.receive_message(QueueUrl=aws.queue_url)["Messages"][0]
    return json.loads(message["Body"])


def test_submit_inline_wakes_group(aws: Aws) -> None:
    queue = make_queue(aws)
    submitted = queue.submit(api.build_request([{"role": "user", "content": "hi"}], {"max_tokens": 8}))
    assert submitted.woke and not submitted.via_s3
    assert aws.desired() == 1
    body = receive_body(aws)
    parsed = schema.parse_body(body)  # the worker accepts what the client sends
    assert isinstance(parsed, schema.Request)
    assert parsed.request_id == submitted.request_id


def test_submit_does_not_rewake_running_group(aws: Aws) -> None:
    aws.autoscaling.set_desired_capacity(AutoScalingGroupName=aws.asg_name, DesiredCapacity=1)
    submitted = make_queue(aws).submit(api.build_request([{"role": "user", "content": "hi"}]))
    assert submitted.woke is False


def test_large_prompt_goes_via_s3_pointer(aws: Aws) -> None:
    big = "x" * (api.INLINE_LIMIT_BYTES + 10)
    submitted = make_queue(aws).submit(api.build_request([{"role": "user", "content": big}]))
    assert submitted.via_s3
    body = receive_body(aws)
    pointer = schema.parse_body(body)
    assert isinstance(pointer, schema.Pointer)
    stored = json.loads(aws.s3.get_object(Bucket=aws.bucket, Key=pointer.payload_key)["Body"].read())
    assert stored["messages"][0]["content"] == big


def put_result(aws: Aws, request_id: str, **fields: Any) -> None:
    result = schema.make_result(request_id, **fields)
    aws.s3.put_object(Bucket=aws.bucket, Key=f"results/{request_id}.json", Body=json.dumps(result).encode())


def test_wait_returns_final_result_and_skips_retryable(aws: Aws) -> None:
    queue = make_queue(aws)
    rid = api.build_request([{"role": "user", "content": "x"}])["request_id"]
    progress: list[str] = []
    calls = {"n": 0}

    def sleep(_s: float) -> None:
        calls["n"] += 1
        if calls["n"] == 1:
            put_result(aws, rid, status="error", error="oom", attempt=1, final=False)
        elif calls["n"] == 2:
            put_result(aws, rid, status="ok", output="done")

    result = queue.wait(rid, on_progress=progress.append, sleep=sleep)
    assert result["output"] == "done"
    assert any("attempt 1 failed" in p for p in progress)


def test_wait_times_out(aws: Aws) -> None:
    clock = iter(range(0, 10_000, 100))
    with pytest.raises(api.ResultTimeout):
        make_queue(aws).wait("nope", timeout_s=250, sleep=lambda _s: None, clock=lambda: next(clock))


def test_wait_rewakes_group_that_scaled_in(aws: Aws) -> None:
    queue = make_queue(aws)
    rid = "11111111-1111-4111-8111-111111111111"
    ticks = iter(range(0, 10_000, 30))

    def sleep(_s: float) -> None:
        if aws.desired() == 1:
            put_result(aws, rid, status="ok", output="late")

    result = queue.wait(rid, sleep=sleep, clock=lambda: next(ticks), rewake_every_s=60)
    assert result["output"] == "late"


def test_up_down_and_status(aws: Aws, tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: Any) -> None:
    config_path = tmp_path / "config.json"
    config_path.write_text(make_settings(aws).to_json())
    monkeypatch.setenv("QWENQ_CONFIG", str(config_path))

    assert cli.main(["up"]) == 0
    assert aws.desired() == 1
    assert cli.main(["down"]) == 0
    assert aws.desired() == 0
    assert cli.main(["status"]) == 0
    status = json.loads(capsys.readouterr().out)
    assert status["desired"] == 0
    assert status["queue"] == {"visible": 0, "in_flight": 0, "dead_letter": 0}


def test_cli_submit_then_wait(aws: Aws, tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: Any) -> None:
    config_path = tmp_path / "config.json"
    config_path.write_text(make_settings(aws).to_json())
    monkeypatch.setenv("QWENQ_CONFIG", str(config_path))
    prompt = tmp_path / "prompt.json"
    prompt.write_text(json.dumps({"messages": [{"role": "user", "content": "hi"}], "params": {"max_tokens": 4}}))

    assert cli.main(["submit", "-f", str(prompt)]) == 0
    rid = capsys.readouterr().out.strip()
    put_result(aws, rid, status="ok", output="answer")
    assert cli.main(["wait", rid]) == 0
    assert capsys.readouterr().out.strip() == "answer"


def test_cli_reports_missing_config(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("QWENQ_CONFIG", str(tmp_path / "missing.json"))
    assert cli.main(["status"]) == cli.EXIT_USAGE


def test_cli_ask_prints_output(aws: Aws, tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: Any) -> None:
    config_path = tmp_path / "config.json"
    config_path.write_text(make_settings(aws).to_json())
    monkeypatch.setenv("QWENQ_CONFIG", str(config_path))
    rid = "22222222-2222-4222-8222-222222222222"
    monkeypatch.setattr(api.uuid, "uuid4", lambda: rid)
    put_result(aws, rid, status="ok", output="forty-two", reasoning="hmm")

    assert cli.main(["ask", "meaning?", "--system", "be brief", "--no-think", "--show-reasoning"]) == 0
    captured = capsys.readouterr()
    assert captured.out.strip() == "forty-two"
    assert "hmm" in captured.err
    sent = receive_body(aws)
    assert sent["messages"][0] == {"role": "system", "content": "be brief"}
    assert sent["params"]["chat_template_kwargs"] == {"enable_thinking": False}
    assert aws.desired() == 1


def test_cli_wait_error_result_exit_code(aws: Aws, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    config_path = tmp_path / "config.json"
    config_path.write_text(make_settings(aws).to_json())
    monkeypatch.setenv("QWENQ_CONFIG", str(config_path))
    rid = "33333333-3333-4333-8333-333333333333"
    put_result(aws, rid, status="error", error="context too long", final=True)
    assert cli.main(["wait", rid, "--json"]) == cli.EXIT_RESULT_ERROR


def test_tunnel_without_instance(aws: Aws, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    config_path = tmp_path / "config.json"
    config_path.write_text(make_settings(aws).to_json())
    monkeypatch.setenv("QWENQ_CONFIG", str(config_path))
    assert cli.main(["tunnel"]) == cli.EXIT_USAGE


def test_settings_roundtrip(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, aws: Aws) -> None:
    from qwenq import settings

    monkeypatch.setenv("QWENQ_CONFIG", str(tmp_path / "sub" / "c.json"))
    written = settings.save(make_settings(aws))
    assert oct(written.stat().st_mode & 0o777) == "0o600"
    assert settings.load() == make_settings(aws)
    with pytest.raises(settings.SettingsError):
        settings.Settings.from_mapping({"region": "x"})


@pytest.mark.unit
def test_build_request_rejects_non_uuid_ids() -> None:
    with pytest.raises(ValueError):
        api.build_request([{"role": "user", "content": "x"}], request_id="my-job")
    assert api.is_request_id(api.build_request([{"role": "user", "content": "x"}])["request_id"])


def test_cli_wait_rejects_bad_id(capsys: Any) -> None:
    with pytest.raises(SystemExit):
        cli.main(["wait", "not-a-uuid"])
