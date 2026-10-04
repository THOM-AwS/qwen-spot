#!/usr/bin/env bash
# Block until vLLM answers /health, or give up after 30 minutes.
set -euo pipefail

# shellcheck source=common.sh
. /opt/qwen-spot/bin/common.sh

timeout_s="${QWEN_HEALTH_TIMEOUT_S:-1800}"
deadline=$(($(date +%s) + timeout_s))

while [ "$(date +%s)" -lt "$deadline" ]; do
  if curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:8000/health; then
    log info wait-vllm-health "vLLM healthy"
    exit 0
  fi
  sleep 5
done

log error wait-vllm-health "vLLM not healthy after ${timeout_s}s"
exit 1
