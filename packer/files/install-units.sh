#!/usr/bin/env bash
# Helper scripts and systemd units. Units are enabled but gated on
# /etc/qwen-spot/config.env, so nothing starts until user data writes it.
set -euo pipefail

: "${FILES_DIR:?}"

install -m 0755 "$FILES_DIR"/bin/*.sh /opt/qwen-spot/bin/
install -m 0644 "$FILES_DIR"/systemd/*.service /etc/systemd/system/

systemctl daemon-reload
systemctl enable \
  qwen-nvme.service \
  qwen-cwagent.service \
  vllm.service \
  qwen-worker.service

# The CloudWatch agent is started by qwen-cwagent.service once the log group is known.
systemctl disable amazon-cloudwatch-agent.service >/dev/null 2>&1 || true
