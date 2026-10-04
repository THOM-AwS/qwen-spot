#!/usr/bin/env bash
# Worker package into its own virtualenv.
set -euo pipefail

: "${WORKER_SRC:?}"

if [ ! -f "$WORKER_SRC/pyproject.toml" ]; then
  echo "worker source missing at $WORKER_SRC (expected pyproject.toml)" >&2
  exit 1
fi

VENV=/opt/qwen-spot/worker-venv
export UV_CACHE_DIR=/var/tmp/uv-cache
export UV_PYTHON_DOWNLOADS=never

uv venv --python /usr/bin/python3.12 "$VENV"
uv pip install --python "$VENV/bin/python" "$WORKER_SRC"
test -x "$VENV/bin/qwen-worker"

rm -rf "$UV_CACHE_DIR" "$WORKER_SRC"
