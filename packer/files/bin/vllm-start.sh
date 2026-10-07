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
# FlashInfer JIT-compiles kernels (GDN prefill, sampler) into this tree; it lives
# under VLLM_CACHE_ROOT so it is saved and restored with the compile cache.
export FLASHINFER_WORKSPACE_BASE="$VLLM_CACHE_ROOT/flashinfer"
# vLLM is started by path, not from an activated venv, so the venv's bin (ninja,
# which FlashInfer runs to JIT-compile kernels) must be on PATH explicitly.
export PATH="$VLLM_VENV/bin:$PATH"
if [ -d /usr/local/cuda/bin ]; then
  export CUDA_HOME=/usr/local/cuda PATH="/usr/local/cuda/bin:$PATH"
fi
mkdir -p "$VLLM_CACHE_ROOT" "$HF_HOME" "$XDG_CACHE_HOME" "$TMPDIR" "$FLASHINFER_WORKSPACE_BASE"

model_prefix=$(with_slash "$QWEN_MODEL_S3_URI")

# The uploader writes .complete last. Without it the prefix may hold a partial copy.
if ! s5cmd ls "${model_prefix}.complete" >/dev/null 2>&1; then
  log error vllm-start "no .complete marker at ${model_prefix}.complete; run scripts/upload-model first"
  exit 1
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
    # MTP speculative decoding with the model's own multi-token-prediction head.
    mtp="${QWEN_MTP_TOKENS:-0}"
    case "$mtp" in
      ''|*[!0-9]*) log error vllm-start "QWEN_MTP_TOKENS must be a whole number, got $mtp"; exit 1 ;;
    esac
    if [ "$mtp" -gt 0 ]; then
      args+=(--speculative-config "{\"method\":\"mtp\",\"num_speculative_tokens\":${mtp}}")
    fi
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

# Restore the compile caches for exactly this configuration.
fingerprint=$(printf '%s\n' "$QWEN_ENGINE" "$model" "${args[@]}" "${extra[@]}" | sha256sum | cut -c1-16)
printf '%s\n' "$fingerprint" >"$CACHE_FINGERPRINT_FILE"
if [ -n "${QWEN_COMPILE_CACHE_S3_URI:-}" ]; then
  cache_obj=$(cache_object "$fingerprint")
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

# The root volume is restored lazily from its snapshot, and vLLM's first import
# of torch and the CUDA libraries reads several GB one file at a time. Reading the
# venv in parallel in the background pulls those blocks in far faster while vLLM
# starts. Best effort: it never delays or fails the start.
if [ "$QWEN_ENGINE" = gpu ] && [ "${QWEN_PREFETCH_VENV:-1}" = 1 ]; then
  (
    start=$(date +%s)
    find "$VLLM_VENV" -type f \( -name '*.so*' -o -name '*.py' -o -name '*.pyc' \) -print0 \
      | xargs -0 -P 64 -n 32 cat >/dev/null 2>&1
    log info vllm-start "prefetched the vLLM venv in $(($(date +%s) - start))s"
  ) &
fi

log info vllm-start "starting vllm serve ($QWEN_ENGINE, $QWEN_WEIGHT_LOAD_MODE, cache key $fingerprint)"
exec "$VLLM_VENV/bin/vllm" serve "$model" "${args[@]}" "${extra[@]}"
