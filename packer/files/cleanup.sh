#!/usr/bin/env bash
# Leave no keys, logs or caches in the image.
set -euo pipefail

: "${FILES_DIR:?}"

export DEBIAN_FRONTEND=noninteractive
apt-get clean
rm -rf /var/lib/apt/lists/* "$FILES_DIR" /var/tmp/uv-cache

# No SSH key may survive into the AMI. Instances are reached through SSM only.
find /home /root -name authorized_keys -type f -exec truncate -s 0 {} +
rm -f /etc/ssh/ssh_host_*

rm -f /etc/qwen-spot/config.env
find /var/log/qwen-spot -type f -delete
journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-time=1s >/dev/null 2>&1 || true

cloud-init clean --logs --machine-id
sync
