#!/usr/bin/env bash
# Base packages, uv, s5cmd, CloudWatch agent, qwen user and directories.
set -euo pipefail

: "${UV_VERSION:?}" "${UV_SHA256:?}" "${S5CMD_VERSION:?}" "${S5CMD_SHA256:?}" "${CWAGENT_GPG_FINGERPRINT:?}"

export DEBIAN_FRONTEND=noninteractive
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "waiting for cloud-init to finish"
cloud-init status --wait >/dev/null || true

# First boot runs unattended-upgrades; wait for the dpkg lock rather than racing it.
apt_get() {
  local tries=0
  until apt-get -o DPkg::Lock::Timeout=600 "$@"; do
    tries=$((tries + 1))
    if [ "$tries" -ge 3 ]; then
      echo "apt-get $* failed after $tries attempts" >&2
      return 1
    fi
    sleep 20
  done
}

apt_get update -q
apt_get install -y -q --no-install-recommends \
  ca-certificates curl gnupg jq tar xfsprogs nvme-cli mdadm python3.12 python3.12-venv

# uv: pinned release tarball, checksum verified.
curl -fsSL -o "$WORK/uv.tar.gz" \
  "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz"
echo "${UV_SHA256}  $WORK/uv.tar.gz" | sha256sum -c -
tar -xzf "$WORK/uv.tar.gz" -C "$WORK"
install -m 0755 "$WORK/uv-x86_64-unknown-linux-gnu/uv" /usr/local/bin/uv
install -m 0755 "$WORK/uv-x86_64-unknown-linux-gnu/uvx" /usr/local/bin/uvx
uv --version

# s5cmd: pinned release tarball, checksum verified.
curl -fsSL -o "$WORK/s5cmd.tar.gz" \
  "https://github.com/peak/s5cmd/releases/download/v${S5CMD_VERSION}/s5cmd_${S5CMD_VERSION}_Linux-64bit.tar.gz"
echo "${S5CMD_SHA256}  $WORK/s5cmd.tar.gz" | sha256sum -c -
tar -xzf "$WORK/s5cmd.tar.gz" -C "$WORK" s5cmd
install -m 0755 "$WORK/s5cmd" /usr/local/bin/s5cmd
s5cmd version

# CloudWatch agent. AWS publishes only a "latest" path (versioned paths return 403),
# so the integrity check is the detached GPG signature against the pinned key fingerprint.
CWA=https://amazoncloudwatch-agent.s3.amazonaws.com
curl -fsSL -o "$WORK/cwagent.gpg" "$CWA/assets/amazon-cloudwatch-agent.gpg"
curl -fsSL -o "$WORK/cwagent.deb" "$CWA/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb"
curl -fsSL -o "$WORK/cwagent.deb.sig" "$CWA/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb.sig"
export GNUPGHOME="$WORK/gnupg"
mkdir -m 0700 "$GNUPGHOME"
gpg --batch --quiet --import "$WORK/cwagent.gpg"
# Export only the pinned key (by full fingerprint) into its own keyring and
# verify with gpgv against that keyring alone, so a signature from any other
# key in the downloaded file cannot pass.
gpg --batch --export "$CWAGENT_GPG_FINGERPRINT" > "$WORK/cwagent-keyring.gpg"
if [ ! -s "$WORK/cwagent-keyring.gpg" ]; then
  echo "CloudWatch agent key $CWAGENT_GPG_FINGERPRINT not found in the downloaded key file" >&2
  exit 1
fi
gpgv --keyring "$WORK/cwagent-keyring.gpg" "$WORK/cwagent.deb.sig" "$WORK/cwagent.deb"
dpkg -i "$WORK/cwagent.deb"
unset GNUPGHOME

# Service account for vLLM and the worker.
if ! id qwen >/dev/null 2>&1; then
  useradd --system --create-home --home-dir /var/lib/qwen --shell /usr/sbin/nologin qwen
fi

install -d -m 0755 /opt/qwen-spot /opt/qwen-spot/bin
install -d -m 0755 -o qwen -g qwen /opt/qwen-spot/nvme
install -d -m 0750 /etc/qwen-spot
install -d -m 0755 -o qwen -g qwen /var/log/qwen-spot
