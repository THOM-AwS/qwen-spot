"""AWS-facing operations behind the CLI. No printing here."""

from __future__ import annotations

import json
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from botocore.exceptions import ClientError

from qwenq.settings import Settings

# SQS accepts 1 MiB since 2025, but 256 KiB keeps us inside the limit every SDK
# and region has used; anything larger goes to S3 with a pointer in the message.
INLINE_LIMIT_BYTES = 256 * 1024


class ResultTimeout(TimeoutError):
    pass


def result_key(request_id: str) -> str:
    return f"results/{request_id}.json"


def request_key(request_id: str) -> str:
    return f"requests/{request_id}.json"


def is_request_id(value: str) -> bool:
    try:
        return str(uuid.UUID(value)) == value
    except (ValueError, TypeError, AttributeError):
        return False


def build_request(
    messages: list[dict[str, Any]],
    params: dict[str, Any] | None = None,
    metadata: dict[str, Any] | None = None,
    request_id: str | None = None,
) -> dict[str, Any]:
    if request_id is None:
        request_id = str(uuid.uuid4())
    elif not is_request_id(request_id):
        # The worker drops non-UUID ids (they become S3 keys), and the client
        # would then wait forever for a result that is never written.
        raise ValueError(f"request_id {request_id!r} must be a canonical lowercase UUID")
    return {
        "request_id": request_id,
        "messages": messages,
        "params": params or {},
        "metadata": metadata or {},
    }


@dataclass(frozen=True)
class Submitted:
    request_id: str
    via_s3: bool
    woke: bool


@dataclass(frozen=True)
class GroupState:
    desired: int
    instances: tuple[dict[str, Any], ...]


class QwenQueue:
    def __init__(self, settings: Settings, *, sqs: Any, s3: Any, autoscaling: Any, ec2: Any) -> None:
        self.settings = settings
        self.sqs = sqs
        self.s3 = s3
        self.autoscaling = autoscaling
        self.ec2 = ec2

    @classmethod
    def from_session(cls, settings: Settings, session: Any) -> QwenQueue:
        return cls(
            settings,
            sqs=session.client("sqs", region_name=settings.region),
            s3=session.client("s3", region_name=settings.region),
            autoscaling=session.client("autoscaling", region_name=settings.region),
            ec2=session.client("ec2", region_name=settings.region),
        )

    # ---- submit ----------------------------------------------------------

    def submit(self, request: dict[str, Any], *, wake: bool = True) -> Submitted:
        request_id = request["request_id"]
        body = json.dumps(request)
        via_s3 = len(body.encode()) > INLINE_LIMIT_BYTES
        if via_s3:
            self.s3.put_object(
                Bucket=self.settings.results_bucket,
                Key=request_key(request_id),
                Body=body.encode(),
                ContentType="application/json",
            )
            body = json.dumps({"request_id": request_id, "payload_key": request_key(request_id)})
        self.sqs.send_message(QueueUrl=self.settings.queue_url, MessageBody=body)
        woke = self.wake() if wake else False
        return Submitted(request_id=request_id, via_s3=via_s3, woke=woke)

    # ---- capacity --------------------------------------------------------

    def group(self) -> GroupState:
        groups = self.autoscaling.describe_auto_scaling_groups(AutoScalingGroupNames=[self.settings.asg_name])
        if not groups["AutoScalingGroups"]:
            raise RuntimeError(f"auto scaling group {self.settings.asg_name} not found")
        group = groups["AutoScalingGroups"][0]
        return GroupState(desired=group["DesiredCapacity"], instances=tuple(group.get("Instances", [])))

    def set_capacity(self, desired: int) -> None:
        self.autoscaling.set_desired_capacity(
            AutoScalingGroupName=self.settings.asg_name, DesiredCapacity=desired, HonorCooldown=False
        )

    def wake(self) -> bool:
        """Set capacity to 1 if the group is at 0. Returns True if it did."""
        if self.group().desired >= 1:
            return False
        self.set_capacity(1)
        return True

    # ---- results ---------------------------------------------------------

    def get_result(self, request_id: str) -> dict[str, Any] | None:
        try:
            obj = self.s3.get_object(Bucket=self.settings.results_bucket, Key=result_key(request_id))
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") in {"NoSuchKey", "404"}:
                return None
            raise
        return json.loads(obj["Body"].read())

    def wait(
        self,
        request_id: str,
        *,
        timeout_s: float = 3600.0,
        on_progress: Callable[[str], None] = lambda _msg: None,
        sleep: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.monotonic,
    ) -> dict[str, Any]:
        """Poll S3 with backoff until a final result exists.

        Retryable errors (``final: false``) are reported and waiting continues.
        It never changes capacity: re-waking here overrode a deliberate
        ``qwenq down``. A submit that races the worker's scale-in is covered by
        the worker (it re-checks the queue after scaling in) and by the
        scale-out alarm.
        """
        deadline = clock() + timeout_s
        delay = 2.0
        reported_attempt = 0
        while True:
            result = self.get_result(request_id)
            if result is not None:
                if result.get("status") == "ok" or result.get("final", True):
                    return result
                attempt = int(result.get("attempt", 0))
                if attempt > reported_attempt:
                    reported_attempt = attempt
                    on_progress(f"attempt {attempt} failed, retrying: {result.get('error')}")
            if clock() >= deadline:
                raise ResultTimeout(f"no result for {request_id} after {timeout_s:.0f}s")
            sleep(delay)
            delay = min(delay * 1.5, 15.0)

    # ---- status ----------------------------------------------------------

    def queue_depth(self) -> dict[str, int]:
        names = ["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"]
        attrs = self.sqs.get_queue_attributes(QueueUrl=self.settings.queue_url, AttributeNames=names)["Attributes"]
        depth = {"visible": int(attrs[names[0]]), "in_flight": int(attrs[names[1]])}
        if self.settings.dlq_url:
            dlq = self.sqs.get_queue_attributes(QueueUrl=self.settings.dlq_url, AttributeNames=[names[0]])
            depth["dead_letter"] = int(dlq["Attributes"][names[0]])
        return depth

    def instance_details(self, instance_ids: list[str]) -> list[dict[str, Any]]:
        if not instance_ids:
            return []
        reservations = self.ec2.describe_instances(InstanceIds=instance_ids)["Reservations"]
        now = datetime.now(UTC)
        details = []
        for reservation in reservations:
            for instance in reservation["Instances"]:
                launched = instance["LaunchTime"]
                details.append(
                    {
                        "instance_id": instance["InstanceId"],
                        "type": instance["InstanceType"],
                        "az": instance["Placement"]["AvailabilityZone"],
                        "state": instance["State"]["Name"],
                        "lifecycle": instance.get("InstanceLifecycle", "on-demand"),
                        "uptime": str(timedelta(seconds=int((now - launched).total_seconds()))),
                    }
                )
        return details

    def spot_prices(self) -> list[tuple[str, str, float]]:
        if not self.settings.instance_types:
            return []
        history = self.ec2.describe_spot_price_history(
            InstanceTypes=list(self.settings.instance_types),
            ProductDescriptions=["Linux/UNIX"],
            StartTime=datetime.now(UTC),
        )["SpotPriceHistory"]
        latest: dict[tuple[str, str], float] = {}
        for entry in history:
            latest.setdefault((entry["InstanceType"], entry["AvailabilityZone"]), float(entry["SpotPrice"]))
        return sorted(((t, az, p) for (t, az), p in latest.items()), key=lambda row: row[2])

    def worker_instance_id(self) -> str | None:
        for instance in self.group().instances:
            if instance.get("LifecycleState") == "InService":
                return instance["InstanceId"]
        return None
