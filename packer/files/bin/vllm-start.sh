#!/usr/bin/env bash
# Start vLLM from the settings in /etc/qwen-spot/config.env (passed in by systemd).
set -euo pipefail

# shellcheck source=common.sh
. /opt/qwen-spot/bin/common.sh

require_env QWEN_REGION QWEN_MODEL_S3_URI QWEN_MODEL_NAME QWEN_WEIGHT_LOAD_MODE QWEN_ENGINE

export AWS_REGION="$QWEN_REGION" AWS_DEFAULT_REGION="$QWEN_REGION"
export VLLM_CACHE_ROOT="$NVME_ROOT/vllm-cache"
export HF_HOME="$NVME_ROOT/hf"
export XDG_CACHE_HOME="$NVME_ROOT/cache"
export TMPDIR="$NVME_ROOT/tmp"
mkdir -p "$VLLM_CACHE_ROOT" "$HF_HOME" "$XDG_CACHE_HOME" "$TMPDIR"

model_prefix=$(with_slash "$QWEN_MODEL_S3_URI")

# The uploader writes .complete last. Without it the prefix may hold a partial copy.
if ! s5cmd ls "${model_prefix}.complete" >/dev/null 2>&1; then
  log error vllm-start "no .complete marker at ${model_prefix}.complete; run scripts/upload-model first"
  exit 1
fi

# Restore the torch.compile cache so warm-up skips compilation.
if [ -n "${QWEN_COMPILE_CACHE_S3_URI:-}" ]; then
  cache_obj="$(with_slash "$QWEN_COMPILE_CACHE_S3_URI")cache.tar"
  if s5cmd ls "$cache_obj" >/dev/null 2>&1; then
    if s5cmd cat "$cache_obj" | tar -x -C "$VLLM_CACHE_ROOT"; then
      log info vllm-start "restored compile cache from $cache_obj"
    else
      log warn vllm-start "compile cache restore failed; vLLM will compile from scratch"
    fi
  else
    log info vllm-start "no compile cache at $cache_obj yet"
  fi
fi

args=(
  --served-model-name "$QWEN_MODEL_NAME"
  --host 127.0.0.1
  --port 8000
  --max-model-len "${QWEN_MAX_MODEL_LEN:-32768}"
  --reasoning-parser qwen3
)

case "$QWEN_WEIGHT_LOAD_MODE" in
  stream)
    model="${model_prefix%/}"
    concurrency="${QWEN_STREAMER_CONCURRENCY:-32}"
    args+=(--load-format runai_streamer --model-loader-extra-config "{\"concurrency\":${concurrency}}")
    log info vllm-start "streaming weights from $model with concurrency $concurrency"
    ;;
  copy)
    model="$NVME_ROOT/model"
    mkdir -p "$model"
    log info vllm-start "copying weights from $model_prefix to $model"
    start=$(date +%s)
    s5cmd --numworkers 64 cp --exclude ".complete" "${model_prefix}*" "$model/"
    log info vllm-start "copy finished in $(($(date +%s) - start))s"
    ;;
  *)
    log error vllm-start "QWEN_WEIGHT_LOAD_MODE must be stream or copy, got $QWEN_WEIGHT_LOAD_MODE"
    exit 1
    ;;
esac

case "$QWEN_ENGINE" in
  gpu)
    args+=(--gpu-memory-utilization "${QWEN_GPU_MEMORY_UTILIZATION:-0.92}")
    ;;
  cpu)
    export VLLM_CPU_KVCACHE_SPACE="${QWEN_CPU_KVCACHE_GB:-4}"
    preload=$(cpu_ld_preload "$VLLM_VENV") || { log error vllm-start "CPU runtime libraries missing"; exit 1; }
    export LD_PRELOAD="$preload${LD_PRELOAD:+:$LD_PRELOAD}"
    ;;
  *)
    log error vllm-start "QWEN_ENGINE must be gpu or cpu, got $QWEN_ENGINE"
    exit 1
    ;;
esac

extra=()
if [ -n "${QWEN_VLLM_EXTRA_ARGS:-}" ]; then
  read -r -a extra <<<"$QWEN_VLLM_EXTRA_ARGS"
fi

log info vllm-start "starting vllm serve ($QWEN_ENGINE, $QWEN_WEIGHT_LOAD_MODE)"
exec "$VLLM_VENV/bin/vllm" serve "$model" "${args[@]}" "${extra[@]}"
