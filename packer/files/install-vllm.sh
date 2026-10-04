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
    uv pip install --python "$VENV/bin/python" \
      --index-url https://download.pytorch.org/whl/cpu \
      "$torch_req"
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
for pkg in ("vllm", "torch", "runai-model-streamer"):
    print(pkg, m.version(pkg))
EOF

rm -rf "$UV_CACHE_DIR"
