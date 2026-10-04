from __future__ import annotations

import uuid

import pytest

from qwen_worker import schema

pytestmark = pytest.mark.unit

RID = str(uuid.uuid4())


def test_parses_full_request() -> None:
    parsed = schema.parse_body(
        {"request_id": RID, "messages": [{"role": "user", "content": "hi"}], "params": {"temperature": 0.1}}
    )
    assert isinstance(parsed, schema.Request)
    payload = parsed.chat_payload("m")
    expected = {"model": "m", "messages": [{"role": "user", "content": "hi"}], "temperature": 0.1, "stream": False}
    assert payload == expected


def test_request_cannot_override_model_via_params() -> None:
    with pytest.raises(schema.InvalidRequest):
        schema.parse_body({"request_id": RID, "messages": [{"role": "user", "content": "x"}], "params": {"model": "y"}})


@pytest.mark.parametrize("bad_id", ["../../etc", "", None, 5, RID.upper() + "x", "not-a-uuid"])
def test_rejects_non_uuid_ids(bad_id: object) -> None:
    with pytest.raises(schema.InvalidRequest):
        schema.parse_body({"request_id": bad_id, "messages": [{"role": "user", "content": "x"}]})


@pytest.mark.parametrize(
    "messages",
    [[], "hi", [{"role": "root", "content": "x"}], [{"role": "user"}], ["x"]],
)
def test_rejects_bad_messages(messages: object) -> None:
    with pytest.raises(schema.InvalidRequest):
        schema.parse_body({"request_id": RID, "messages": messages})


def test_pointer_must_reference_own_key() -> None:
    assert isinstance(schema.parse_body({"request_id": RID, "payload_key": f"requests/{RID}.json"}), schema.Pointer)
    with pytest.raises(schema.InvalidRequest):
        schema.parse_body({"request_id": RID, "payload_key": "results/other.json"})


def test_make_result_shape() -> None:
    result = schema.make_result(RID, status="ok", output="x", queued_s=1.23456)
    assert set(result) >= {"request_id", "status", "output", "usage", "timings", "error"}
    assert result["timings"]["queued_s"] == 1.235
