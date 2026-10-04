"""EC2 instance metadata (IMDSv2): spot interruption and ASG termination notices."""

from __future__ import annotations

import logging
import time

import httpx

log = logging.getLogger(__name__)

IMDS_URL = "http://169.254.169.254"
TOKEN_TTL_S = 21600


class Imds:
    def __init__(self, base_url: str = IMDS_URL, transport: httpx.BaseTransport | None = None) -> None:
        self._http = httpx.Client(base_url=base_url, timeout=2.0, transport=transport)
        self._token: str | None = None
        self._token_expiry = 0.0

    def close(self) -> None:
        self._http.close()

    def _get(self, path: str) -> httpx.Response | None:
        try:
            if self._token is None or time.monotonic() > self._token_expiry:
                response = self._http.put(
                    "/latest/api/token",
                    headers={"X-aws-ec2-metadata-token-ttl-seconds": str(TOKEN_TTL_S)},
                )
                response.raise_for_status()
                self._token = response.text
                self._token_expiry = time.monotonic() + TOKEN_TTL_S - 60
            return self._http.get(path, headers={"X-aws-ec2-metadata-token": self._token})
        except httpx.HTTPError as exc:
            log.debug("imds request failed", extra={"path": path, "error": repr(exc)})
            return None

    def instance_id(self) -> str | None:
        response = self._get("/latest/meta-data/instance-id")
        return response.text if response is not None and response.status_code == 200 else None

    def termination_notice(self) -> str | None:
        """Return a reason string when this instance is about to go away, else None.

        Two signals: the two-minute spot interruption notice, and the ASG target
        lifecycle state flipping to Terminated (scale-in, including our own).
        """
        response = self._get("/latest/meta-data/spot/instance-action")
        if response is not None and response.status_code == 200:
            return f"spot interruption: {response.text}"
        response = self._get("/latest/meta-data/autoscaling/target-lifecycle-state")
        if response is not None and response.status_code == 200 and response.text.strip() == "Terminated":
            return "autoscaling target lifecycle state is Terminated"
        return None
