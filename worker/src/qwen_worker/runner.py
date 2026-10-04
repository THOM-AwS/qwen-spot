"""The queue loop: receive, generate, write result, delete; scale to zero when idle.

Retry accounting: SQS's receive count also goes up when a message is handed back
on a spot interruption, so it cannot tell a failing request from an unlucky one.
The worker counts real generation attempts itself (``attempt`` in the result
object) and gives up after ``max_attempts``. The queue's ``maxReceiveCount`` is a
looser backstop for messages that keep killing the worker.
"""

from __future__ import annotations

import json
import logging
import threading
import time
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from typing import Any

from botocore.exceptions import BotoCoreError, ClientError

from qwen_worker import schema
from qwen_worker.config import WorkerConfig
from qwen_worker.imds import Imds
from qwen_worker.vllm import VllmClient, VllmError

log = logging.getLogger(__name__)

SQS_BATCH_MAX = 10
RETRY_BACKOFF_S = 30
SCALE_IN_RECHECK_S = 15.0
BACKLOG_ATTRIBUTES = (
    "ApproximateNumberOfMessages",
    "ApproximateNumberOfMessagesNotVisible",
    "ApproximateNumberOfMessagesDelayed",
)


class InFlight:
    """Receipt handles of messages this worker currently owns. Thread-safe.

    Keyed by receipt handle, not message id: after a release the same message can
    come back with a new handle while the old job is still running.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._handles: set[str] = set()

    def add(self, handle: str) -> None:
        with self._lock:
            self._handles.add(handle)

    def remove(self, handle: str) -> None:
        with self._lock:
            self._handles.discard(handle)

    def owns(self, handle: str) -> bool:
        with self._lock:
            return handle in self._handles

    def snapshot(self) -> list[str]:
        with self._lock:
            return list(self._handles)

    def pop_all(self) -> list[str]:
        with self._lock:
            handles = list(self._handles)
            self._handles.clear()
            return handles

    def __len__(self) -> int:
        with self._lock:
            return len(self._handles)


class Worker:
    def __init__(
        self,
        config: WorkerConfig,
        *,
        sqs: Any,
        s3: Any,
        autoscaling: Any,
        vllm: VllmClient,
        imds: Imds | None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.config = config
        self.sqs = sqs
        self.s3 = s3
        self.autoscaling = autoscaling
        self.vllm = vllm
        self.imds = imds
        self.clock = clock
        self.in_flight = InFlight()
        # stop: no new receives. terminate: the process is being killed.
        self.stop = threading.Event()
        self.terminate = threading.Event()
        self.interrupted = threading.Event()
        self.stop_reason: str | None = None
        self.scaled_in = False
        self._last_busy = clock()
        # Serialises visibility changes so a heartbeat cannot re-hide a message
        # that release_in_flight has just handed back.
        self._visibility_lock = threading.Lock()
        self._stop_lock = threading.Lock()
        self._pool = ThreadPoolExecutor(max_workers=config.concurrency, thread_name_prefix="job")

    # ---- lifecycle -------------------------------------------------------

    def request_stop(self, reason: str) -> None:
        """Stop receiving new messages. In-flight jobs keep running."""
        with self._stop_lock:
            if self.stop.is_set():
                return
            self.stop_reason = reason
            self.stop.set()
        log.warning("stopping", extra={"reason": reason, "in_flight": len(self.in_flight)})

    def request_terminate(self, reason: str) -> None:
        """The process is being killed (SIGTERM): stop, release work, exit."""
        self.request_stop(reason)
        self.terminate.set()

    def run(self) -> int:
        log.info("waiting for vLLM health", extra={"url": self.config.vllm_url})
        if not self.vllm.wait_healthy(self.config.health_timeout_s, should_stop=self.terminate.is_set):
            if self.terminate.is_set():
                log.info("terminated before vLLM became healthy")
                return 0
            log.error("vLLM never became healthy", extra={"timeout_s": self.config.health_timeout_s})
            return 1
        log.info("vLLM healthy, polling queue", extra={"queue_url": self.config.queue_url})
        self._last_busy = self.clock()

        threads = [threading.Thread(target=self._heartbeat_loop, name="heartbeat", daemon=True)]
        if self.imds is not None:
            threads.append(threading.Thread(target=self._interruption_loop, name="imds", daemon=True))
        for thread in threads:
            thread.start()

        while True:
            while not self.stop.is_set():
                if self.poll_once() == 0:
                    self.maybe_scale_in()
            self.release_in_flight()
            if not (self.scaled_in and self.wait_for_scale_in()):
                break

        # Interrupted or scaled in: stay alive without polling until the instance
        # goes away, so systemd does not restart us into a dying instance. Jobs
        # still running may finish and write their result, which is harmless.
        self.terminate.wait()
        self._pool.shutdown(wait=False, cancel_futures=True)
        return 0

    def wait_for_scale_in(self, grace_s: float = 600.0, recheck_s: float = SCALE_IN_RECHECK_S) -> bool:
        """After setting capacity to 0, wait to be terminated.

        Returns True to resume polling, in two cases:
        - a message arrived just as we scaled in (the approximate queue counts
          lag); we set capacity back to 1 ourselves rather than strand it;
        - someone else set capacity back to 1 before the ASG terminated us.
        Never resumes after an interruption notice or SIGTERM.
        """
        if self.terminate.wait(recheck_s):
            return False
        if not self.interrupted.is_set() and self.backlog() > 0:
            log.info("work arrived during scale-in, waking the group again")
            self._set_capacity(1)
            return self._resume()
        if self.terminate.wait(grace_s):
            return False
        if self.interrupted.is_set():
            return False
        groups = self.autoscaling.describe_auto_scaling_groups(AutoScalingGroupNames=[self.config.asg_name])
        desired = groups["AutoScalingGroups"][0]["DesiredCapacity"] if groups["AutoScalingGroups"] else 0
        if desired < 1:
            log.warning("scaled in but still running after grace period", extra={"grace_s": grace_s})
            return False
        log.info("group woken again before termination", extra={"desired": desired})
        return self._resume()

    def _resume(self) -> bool:
        with self._stop_lock:
            if self.interrupted.is_set() or self.terminate.is_set():
                return False
            self.scaled_in = False
            self.stop_reason = None
            self._last_busy = self.clock()
            self.stop.clear()
        log.info("resuming")
        return True

    # ---- queue -----------------------------------------------------------

    def poll_once(self) -> int:
        free = self.config.concurrency - len(self.in_flight)
        if free <= 0:
            self.stop.wait(0.5)
            return -1
        try:
            response = self.sqs.receive_message(
                QueueUrl=self.config.queue_url,
                MaxNumberOfMessages=min(SQS_BATCH_MAX, free),
                WaitTimeSeconds=self.config.poll_wait_s,
                VisibilityTimeout=self.config.visibility_timeout,
                MessageSystemAttributeNames=["ApproximateReceiveCount", "SentTimestamp"],
            )
        except (ClientError, BotoCoreError) as exc:
            log.warning("receive failed, backing off", extra={"error": str(exc)})
            self.stop.wait(5.0)
            return -1
        messages = response.get("Messages", [])
        for message in messages:
            self.in_flight.add(message["ReceiptHandle"])
        if messages:
            self._last_busy = self.clock()
        if self.stop.is_set():
            # Stopped during the long poll: hand these straight back.
            self.release_in_flight()
            return len(messages)
        for message in messages:
            self._pool.submit(self._run_job, message)
        return len(messages)

    def _run_job(self, message: dict[str, Any]) -> None:
        receipt = message["ReceiptHandle"]
        try:
            self.handle(message)
        except Exception as exc:
            # Leave the message alone; it reappears after the visibility timeout.
            log.exception("job failed unexpectedly", extra={"message_id": message.get("MessageId")})
            self._fail_unexpected(message, exc)
        finally:
            self.in_flight.remove(receipt)
            self._last_busy = self.clock()

    def _fail_unexpected(self, message: dict[str, Any], exc: Exception) -> None:
        """On the receive SQS will dead-letter next, leave a final result behind."""
        receive_count = int(message.get("Attributes", {}).get("ApproximateReceiveCount", "1"))
        request_id = _peek_request_id(message["Body"])
        if request_id is None or receive_count < self.config.max_receive_count:
            return
        try:
            self._write_error(
                schema.make_result(
                    request_id, status="error", error=f"worker error: {exc!r}", attempt=receive_count, final=True
                )
            )
        except Exception:
            log.exception("could not write final error result", extra={"request_id": request_id})

    def handle(self, message: dict[str, Any]) -> None:
        attributes = message.get("Attributes", {})
        sent_at = int(attributes.get("SentTimestamp", "0")) / 1000 or time.time()
        queued_s = max(time.time() - sent_at, 0.0)
        receipt = message["ReceiptHandle"]

        try:
            request = self._load_request(message["Body"])
        except schema.InvalidRequest as exc:
            request_id = _peek_request_id(message["Body"])
            log.warning("invalid request", extra={"request_id": request_id, "error": str(exc)})
            if request_id:
                self._write_error(schema.make_result(request_id, status="error", error=f"invalid request: {exc}"))
            self._delete(receipt)
            return

        previous = self._existing_result(request.request_id)
        if previous is not None and previous.get("status") == "ok":
            log.info("duplicate delivery, result exists", extra={"request_id": request.request_id})
            self._delete(receipt)
            return
        attempt = int(previous.get("attempt", 0)) + 1 if previous else 1

        log.info(
            "generating",
            extra={"request_id": request.request_id, "attempt": attempt, "queued_s": round(queued_s, 1)},
        )
        try:
            completion = self.vllm.chat(request.chat_payload(self.config.model_name))
        except VllmError as exc:
            final = not exc.retryable or attempt >= self.config.max_attempts
            log.error(
                "generation failed",
                extra={"request_id": request.request_id, "attempt": attempt, "final": final, "error": str(exc)},
            )
            self._write_error(
                schema.make_result(
                    request.request_id,
                    status="error",
                    error=str(exc),
                    queued_s=queued_s,
                    attempt=attempt,
                    final=final,
                    model=self.config.model_name,
                    metadata=dict(request.metadata),
                )
            )
            if final:
                self._delete(receipt)
            else:
                self._change_visibility(receipt, min(RETRY_BACKOFF_S * attempt, self.config.visibility_timeout))
            return

        self._write_result(
            schema.make_result(
                request.request_id,
                status="ok",
                output=completion.output,
                reasoning=completion.reasoning,
                usage=completion.usage,
                queued_s=queued_s,
                generation_s=completion.generation_s,
                attempt=attempt,
                model=self.config.model_name,
                metadata=dict(request.metadata),
            )
        )
        self._delete(receipt)
        log.info(
            "done",
            extra={
                "request_id": request.request_id,
                "generation_s": round(completion.generation_s, 2),
                "completion_tokens": completion.usage["completion_tokens"],
            },
        )

    def _load_request(self, raw_body: str) -> schema.Request:
        try:
            body = json.loads(raw_body)
        except json.JSONDecodeError as exc:
            raise schema.InvalidRequest(f"body is not JSON: {exc}") from exc
        parsed = schema.parse_body(body)
        if isinstance(parsed, schema.Request):
            return parsed
        try:
            obj = self.s3.get_object(Bucket=self.config.results_bucket, Key=parsed.payload_key)
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") in {"NoSuchKey", "404"}:
                raise schema.InvalidRequest(f"payload {parsed.payload_key} not found") from exc
            raise
        try:
            payload = json.loads(obj["Body"].read())
        except json.JSONDecodeError as exc:
            raise schema.InvalidRequest(f"payload is not JSON: {exc}") from exc
        if not isinstance(payload, dict):
            raise schema.InvalidRequest("payload must be a JSON object")
        request = schema.parse_request(payload)
        if request.request_id != parsed.request_id:
            raise schema.InvalidRequest("payload request_id does not match the message")
        return request

    def _existing_result(self, request_id: str) -> dict[str, Any] | None:
        try:
            obj = self.s3.get_object(Bucket=self.config.results_bucket, Key=schema.result_key(request_id))
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") in {"NoSuchKey", "404"}:
                return None
            raise
        try:
            result = json.loads(obj["Body"].read())
        except json.JSONDecodeError:
            return None
        return result if isinstance(result, dict) else None

    def _write_result(self, result: dict[str, Any]) -> None:
        self.s3.put_object(
            Bucket=self.config.results_bucket,
            Key=schema.result_key(result["request_id"]),
            Body=json.dumps(result).encode(),
            ContentType="application/json",
        )

    def _write_error(self, result: dict[str, Any]) -> None:
        """Write an error result unless a successful one is already there.

        A job and its redelivered twin can overlap after a release; the twin's
        failure must not replace the other's success.
        """
        existing = self._existing_result(result["request_id"])
        if existing is not None and existing.get("status") == "ok":
            log.info("keeping existing ok result", extra={"request_id": result["request_id"]})
            return
        self._write_result(result)

    def _delete(self, receipt: str) -> None:
        self.sqs.delete_message(QueueUrl=self.config.queue_url, ReceiptHandle=receipt)

    def _change_visibility(self, receipt: str, seconds: int) -> None:
        with self._visibility_lock:
            if not self.in_flight.owns(receipt):
                return  # already released to the next instance
            try:
                self.sqs.change_message_visibility(
                    QueueUrl=self.config.queue_url, ReceiptHandle=receipt, VisibilityTimeout=seconds
                )
            except ClientError as exc:
                log.warning("change visibility failed", extra={"error": str(exc)})

    def _set_capacity(self, desired: int) -> None:
        self.autoscaling.set_desired_capacity(
            AutoScalingGroupName=self.config.asg_name, DesiredCapacity=desired, HonorCooldown=False
        )

    def backlog(self) -> int:
        attrs = self.sqs.get_queue_attributes(QueueUrl=self.config.queue_url, AttributeNames=list(BACKLOG_ATTRIBUTES))[
            "Attributes"
        ]
        return sum(int(v) for v in attrs.values())

    # ---- visibility ------------------------------------------------------

    def heartbeat_once(self) -> None:
        with self._visibility_lock:
            # After a stop, in-flight messages were released; extending them
            # again would hide them from the next instance.
            if not self.stop.is_set():
                self._set_visibility(self.in_flight.snapshot(), self.config.visibility_timeout)

    def release_in_flight(self) -> None:
        """Make every owned message visible again so the next instance retries it now."""
        with self._visibility_lock:
            handles = self.in_flight.pop_all()
            if handles:
                log.warning("releasing in-flight messages", extra={"count": len(handles)})
                self._set_visibility(handles, 0)

    def _set_visibility(self, handles: list[str], seconds: int) -> None:
        for start in range(0, len(handles), SQS_BATCH_MAX):
            entries = [
                {"Id": f"m{index}", "ReceiptHandle": handle, "VisibilityTimeout": seconds}
                for index, handle in enumerate(handles[start : start + SQS_BATCH_MAX])
            ]
            try:
                response = self.sqs.change_message_visibility_batch(QueueUrl=self.config.queue_url, Entries=entries)
            except ClientError as exc:
                log.warning("visibility batch failed", extra={"error": str(exc), "seconds": seconds})
                continue
            for failure in response.get("Failed", []):
                # Usually the job just finished and deleted its message.
                log.info("visibility change skipped", extra={"failure": failure})

    def _heartbeat_loop(self) -> None:
        while not self.terminate.wait(self.config.heartbeat_interval_s):
            self.heartbeat_once()

    # ---- interruption and idle ------------------------------------------

    def check_interruption_once(self) -> bool:
        notice = self.imds.termination_notice() if self.imds is not None else None
        if notice:
            self.interrupted.set()
            self.request_stop(notice)
            self.release_in_flight()
            return True
        return False

    def _interruption_loop(self) -> None:
        while not self.terminate.is_set():
            if self.check_interruption_once():
                return
            self.terminate.wait(self.config.interruption_poll_s)

    def idle_for_s(self) -> float:
        return self.clock() - self._last_busy

    def maybe_scale_in(self) -> bool:
        """Set desired capacity to 0 once the queue has been empty for idle_minutes."""
        if len(self.in_flight) or self.idle_for_s() < self.config.idle_minutes * 60:
            return False
        backlog = self.backlog()
        if backlog:
            log.info("idle timer expired but queue not empty", extra={"backlog": backlog})
            self._last_busy = self.clock()
            return False
        log.info("idle, scaling in", extra={"idle_s": round(self.idle_for_s()), "asg": self.config.asg_name})
        try:
            self._set_capacity(0)
        except ClientError as exc:
            log.error("scale-in failed, will retry", extra={"error": str(exc)})
            self._last_busy = self.clock() - self.config.idle_minutes * 60 + 60
            return False
        self.scaled_in = True
        self.request_stop("idle scale-in")
        return True


def _peek_request_id(raw_body: str) -> str | None:
    try:
        return schema.validate_request_id(json.loads(raw_body).get("request_id"))
    except (json.JSONDecodeError, AttributeError, schema.InvalidRequest):
        return None
