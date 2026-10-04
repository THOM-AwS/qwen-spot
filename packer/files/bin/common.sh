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

# vLLM's CPU wheel must run with Intel OpenMP and tcmalloc preloaded, as the
# official CPU image does (docker/Dockerfile.cpu). Without it the engine core
# process never comes up. Prints the LD_PRELOAD value; fails if a library is
# missing so the caller does not start a vLLM that will hang.
cpu_ld_preload() {
  local venv=${1:-$VLLM_VENV} iomp tcmalloc=/usr/lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4
  iomp=$(find "$venv" -name 'libiomp5.so' -print -quit)
  if [ -z "$iomp" ] || [ ! -e "$tcmalloc" ]; then
    echo "missing libiomp5.so ($iomp) or $tcmalloc" >&2
    return 1
  fi
  printf '%s:%s' "$tcmalloc" "$iomp"
}

# Normalise an S3 prefix to have exactly one trailing slash.
with_slash() {
  printf '%s/' "${1%/}"
}
