#!/usr/bin/env bash
# vLLM virtualenv. gpu: PyPI wheel (CUDA 13 torch). cpu: official CPU wheel from the
# vllm-project GitHub release, never the third-party "vllm-cpu" PyPI package.
set -euo pipefail

: "${ENGINE:?}" "${VLLM_VERSION:?}"

VENV=/opt/qwen-spot/vllm-venv
export UV_CACHE_DIR=/var/tmp/uv-cache
export UV_PYTHON_DOWNLOADS=never

uv venv --python /usr/bin/python3.12 "$VENV"

case "$ENGINE" in
  gpu)
    # No --torch-backend flag: the build host has no GPU, so "auto" would pick CPU torch.
    # The default PyPI torch for this vLLM pin is the CUDA 13 build.
    uv pip install --python "$VENV/bin/python" "vllm[runai]==${VLLM_VERSION}"
    ;;
  cpu)
    : "${VLLM_CPU_WHEEL_SHA256:?}"
    # Runtime libraries the CPU wheel expects (see docker/Dockerfile.cpu): tcmalloc
    # and libiomp5 are preloaded at start, libnuma backs thread binding, and g++
    # plus the Python headers are what torch.compile needs to build CPU kernels.
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
      libtcmalloc-minimal4 libnuma1 numactl g++ python3.12-dev
    wheel="vllm-${VLLM_VERSION}+cpu-cp38-abi3-manylinux_2_39_x86_64.whl"
    work=$(mktemp -d)
    curl -fsSL -o "$work/$wheel" \
      "https://github.com/vllm-project/vllm/releases/download/v${VLLM_VERSION}/vllm-${VLLM_VERSION}%2Bcpu-cp38-abi3-manylinux_2_39_x86_64.whl"
    echo "${VLLM_CPU_WHEEL_SHA256}  $work/$wheel" | sha256sum -c -
    # The wheel pins torch==<ver>+cpu, which only exists on the PyTorch CPU index.
    # Install torch alone from that index first (single index, so nothing else
    # can be substituted from it), then vLLM from PyPI with torch already
    # satisfied. No --extra-index-url / unsafe-best-match: that mix allows
    # dependency confusion between the two indexes.
    torch_req=$(python3 - "$work/$wheel" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as wheel:
    meta = next(n for n in wheel.namelist() if n.endswith(".dist-info/METADATA"))
    for line in wheel.read(meta).decode().splitlines():
        if line.startswith("Requires-Dist: torch=="):
            print(line.split(":", 1)[1].split(";")[0].strip())
            break
PY
)
    case "$torch_req" in
      torch==*+cpu) ;;
      *) echo "unexpected torch requirement in $wheel: '$torch_req'" >&2; exit 1 ;;
    esac
    # torchvision, torchaudio and torchcodec come from the same index in the same resolve:
    # their wheels pin an exact torch, so only the +cpu builds for this torch
    # satisfy it. Left to PyPI they arrive built against a different torch and
    # vLLM dies at start with "operator torchvision::nms does not exist", and the
    # PyPI torchcodec is a CUDA build that needs libnvrtc.so.13.
    uv pip install --python "$VENV/bin/python" \
      --index-url https://download.pytorch.org/whl/cpu \
      "$torch_req" torchvision torchaudio "torchcodec>=0.14"
    uv pip install --python "$VENV/bin/python" \
      "vllm[runai] @ file://$work/$wheel"
    rm -rf "$work"
    ;;
  *)
    echo "unknown ENGINE: $ENGINE" >&2
    exit 1
    ;;
esac

"$VENV/bin/python" - <<'EOF'
import importlib.metadata as m
for pkg in ("vllm", "torch", "torchvision", "torchaudio", "torchcodec", "runai-model-streamer"):
    print(pkg, m.version(pkg))

# Fail the build, not the first boot, on a torch/torchvision mismatch: importing
# vLLM registers torchvision ops and raises if the builds do not match.
import torch
import torchvision  # noqa: F401
assert hasattr(torch.ops.torchvision, "nms"), "torchvision ops not registered for this torch"
import torchcodec.decoders  # noqa: F401  loads the native libraries vllm serve needs
import vllm  # noqa: F401
import vllm.entrypoints.openai.api_server  # noqa: F401
print("vllm imports ok")
EOF

# CPU only: a real start. Imports passing has not been enough twice; this runs
# vllm serve on a tiny pinned model, waits for /health, generates, and stops.
# The GPU image cannot do this on a CPU build host.
if [ "$ENGINE" = cpu ]; then
  smoke=$(mktemp -d)
  "$VENV/bin/python" - "$smoke/model" <<'PY'
import sys
from huggingface_hub import snapshot_download
snapshot_download("Qwen/Qwen3-0.6B", revision="c1899de289a04d12100db370d81485cdf75e47ca",
                  local_dir=sys.argv[1], allow_patterns=["*.json", "*.safetensors", "*.txt", "*.jinja"])
PY
  # Packer uploads files/ to /tmp/qwen-files before the scripts run.
  # shellcheck source=bin/common.sh
  . /tmp/qwen-files/bin/common.sh
  preload=$(cpu_ld_preload "$VENV")
  LD_PRELOAD="$preload" VLLM_CPU_KVCACHE_SPACE=2 "$VENV/bin/vllm" serve "$smoke/model" --host 127.0.0.1 --port 8000 \
    --max-model-len 1024 --served-model-name smoke >"$smoke/serve.log" 2>&1 &
  pid=$!
  ok=0
  for _ in $(seq 1 120); do
    if curl -fsS http://127.0.0.1:8000/health >/dev/null 2>&1; then ok=1; break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 5
  done
  if [ "$ok" = 1 ]; then
    curl -fsS http://127.0.0.1:8000/v1/chat/completions -H 'Content-Type: application/json' \
      -d '{"model":"smoke","messages":[{"role":"user","content":"Say ok"}],"max_tokens":8}' \
      | grep -q '"choices"' || ok=0
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if [ "$ok" != 1 ]; then
    echo "vllm smoke test failed; last log lines:" >&2
    grep -E "ERROR|Error|Traceback|Killed|EngineCore" "$smoke/serve.log" | tail -40 >&2
    tail -60 "$smoke/serve.log" >&2
    exit 1
  fi
  echo "vllm smoke test ok"
  rm -rf "$smoke"
fi

rm -rf "$UV_CACHE_DIR"
