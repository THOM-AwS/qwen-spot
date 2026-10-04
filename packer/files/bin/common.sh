#!/usr/bin/env bash
# Shared helpers for the qwen-spot runtime scripts. Sourced, not executed.

# shellcheck disable=SC2034 # used by the scripts that source this file
NVME_ROOT=/opt/qwen-spot/nvme
# shellcheck disable=SC2034
VLLM_VENV=/opt/qwen-spot/vllm-venv

# One JSON object per line so CloudWatch Logs Insights can parse it.
log() {
  local level=$1 component=$2
  shift 2
  jq -cn --arg level "$level" --arg component "$component" --arg msg "$*" \
    '{ts: (now | todate), level: $level, component: $component, msg: $msg}'
}

require_env() {
  local name missing=0
  for name in "$@"; do
    if [ -z "${!name:-}" ]; then
      log error config "missing required setting $name in /etc/qwen-spot/config.env"
      missing=1
    fi
  done
  return "$missing"
}

# Normalise an S3 prefix to have exactly one trailing slash.
with_slash() {
  printf '%s/' "${1%/}"
}
