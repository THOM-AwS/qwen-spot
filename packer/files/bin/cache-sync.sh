#!/usr/bin/env bash
# After vLLM is healthy, upload its torch.compile cache once so the next cold
# start can skip compilation. Never fails the boot.
set -uo pipefail

# shellcheck source=common.sh
. /opt/qwen-spot/bin/common.sh

if [ -z "${QWEN_COMPILE_CACHE_S3_URI:-}" ]; then
  log info cache-sync "compile cache disabled"
  exit 0
fi

export AWS_REGION="${QWEN_REGION:-}" AWS_DEFAULT_REGION="${QWEN_REGION:-}"
cache_root="$NVME_ROOT/vllm-cache"
cache_obj="$(with_slash "$QWEN_COMPILE_CACHE_S3_URI")cache.tar"

if s5cmd ls "$cache_obj" >/dev/null 2>&1; then
  log info cache-sync "compile cache already in S3"
  exit 0
fi

if [ ! -d "$cache_root/torch_compile_cache" ]; then
  log info cache-sync "no torch_compile_cache to upload"
  exit 0
fi

tmp="$NVME_ROOT/tmp/cache.tar"
mkdir -p "$(dirname "$tmp")"
if tar -C "$cache_root" -cf "$tmp" torch_compile_cache && s5cmd cp "$tmp" "$cache_obj"; then
  log info cache-sync "uploaded compile cache to $cache_obj"
else
  log warn cache-sync "compile cache upload failed"
fi
rm -f "$tmp"
exit 0
