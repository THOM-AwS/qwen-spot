#!/usr/bin/env bash
# Mount instance-store NVMe at /opt/qwen-spot/nvme. Instance store is wiped on
# stop/terminate, so it is formatted on every boot.
set -euo pipefail

# shellcheck source=common.sh
. /opt/qwen-spot/bin/common.sh

target="$NVME_ROOT"
mkdir -p "$target"

finish() {
  chown qwen:qwen "$target"
  log info mount-nvme "$1"
  exit 0
}

if mountpoint -q "$target"; then
  finish "$target already mounted"
fi

# The DLAMI mounts instance store at /opt/dlami/nvme on its own. Give it a minute,
# then reuse its mount instead of formatting the same disk twice.
if [ -d /opt/dlami ]; then
  for _ in $(seq 1 30); do
    if mountpoint -q /opt/dlami/nvme; then
      mount --bind /opt/dlami/nvme "$target"
      finish "bind-mounted DLAMI instance store /opt/dlami/nvme"
    fi
    sleep 2
  done
fi

mapfile -t devices < <(
  for link in /dev/disk/by-id/nvme-Amazon_EC2_NVMe_Instance_Storage_*; do
    [ -e "$link" ] || continue
    readlink -f "$link"
  done | grep -E '^/dev/nvme[0-9]+n[0-9]+$' | sort -u
)

if [ "${#devices[@]}" -eq 0 ]; then
  finish "no instance store found; using a directory on the root volume"
fi

if [ "${#devices[@]}" -eq 1 ]; then
  device="${devices[0]}"
else
  device=/dev/md/qwen-nvme
  mdadm --create "$device" --run --force --level=0 --raid-devices="${#devices[@]}" "${devices[@]}"
fi

mkfs.xfs -f -q "$device"
mount -o noatime "$device" "$target"
finish "formatted and mounted ${devices[*]} at $target"
