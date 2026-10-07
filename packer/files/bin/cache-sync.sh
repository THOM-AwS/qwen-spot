#!/usr/bin/env bash
# After vLLM is healthy, upload its compile caches (torch.compile and FlashInfer
# JIT kernels) once per configuration, so the next cold start skips compiling.
# Never fails the boot.
set -uo pipefail

# shellcheck source=common.sh
. /opt/qwen-spot/bin/common.sh

if [ -z "${QWEN_COMPILE_CACHE_S3_URI:-}" ]; then
  log info cache-sync "compile cache disabled"
  exit 0
fi

export AWS_REGION="${QWEN_REGION:-}" AWS_DEFAULT_REGION="${QWEN_REGION:-}"
cache_root="$NVME_ROOT/vllm-cache"
if [ ! -s "$CACHE_FINGERPRINT_FILE" ]; then
  log warn cache-sync "no cache fingerprint from vllm-start; skipping"
  exit 0
fi
cache_obj=$(cache_object "$(cat "$CACHE_FINGERPRINT_FILE")")

if s5cmd ls "$cache_obj" >/dev/null 2>&1; then
  log info cache-sync "compile cache already in S3"
  exit 0
fi

dirs=()
for d in torch_compile_cache flashinfer; do
  [ -d "$cache_root/$d" ] && dirs+=("$d")
done
if [ "${#dirs[@]}" -eq 0 ]; then
  log info cache-sync "no compile cache to upload"
  exit 0
fi

tmp="$NVME_ROOT/tmp/cache.tar"
mkdir -p "$(dirname "$tmp")"
if tar -C "$cache_root" -cf "$tmp" "${dirs[@]}" && s5cmd cp "$tmp" "$cache_obj"; then
  log info cache-sync "uploaded compile cache (${dirs[*]}) to $cache_obj"
else
  log warn cache-sync "compile cache upload failed"
fi
rm -f "$tmp"
exit 0
