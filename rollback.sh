#!/usr/bin/env bash
# sing-box VPN rollback. Auto-detects PROJECT_DIR.

set -euo pipefail

resolve_project_dir() {
  local source="${BASH_SOURCE[0]}"
  while [ -L "$source" ]; do
    local dir
    dir=$(dirname "$source")
    source=$(readlink "$source")
    [[ "$source" != /* ]] && source="$dir/$source"
  done
  (cd "$(dirname "$source")" && pwd -P)
}

PROJECT_DIR="${PROJECT_DIR:-$(resolve_project_dir)}"
RUNTIME_DIR="${RUNTIME_DIR:-/etc/sing-box}"
SERVICE_NAME="${SERVICE_NAME:-sing-box}"
LOG="${LOG:-/tmp/sing-box-rollback.log}"

exec > >(tee -a "$LOG") 2>&1
echo "[rollback] $(date -Iseconds) starting"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root (sudo $0)"
  exit 1
fi

systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
echo "[rollback] $SERVICE_NAME disabled"

if command -v nft >/dev/null; then
  nft delete table inet sing-box 2>/dev/null || true
  sed -i '/sing-box/d' /etc/nftables.conf 2>/dev/null || true
  echo "[rollback] nftables rules removed"
fi

ip rule del fwmark 0x1 lookup 100 2>/dev/null || true
ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true

iptables -t mangle -D PREROUTING -j SINGBOX 2>/dev/null || true
iptables -t mangle -F SINGBOX 2>/dev/null || true
iptables -t mangle -X SINGBOX 2>/dev/null || true

if [[ -f /home/*/.config/systemd/user/hiddify.service || -f /home/*/.config/systemd/user/HiddifyCli.service ]]; then
  local hid_user
  hid_user="$(stat -c '%U' /home/*/.config/systemd/user/hiddify.service 2>/dev/null || stat -c '%U' /home/*/.config/systemd/user/HiddifyCli.service 2>/dev/null || echo root)"
  sudo -u "$hid_user" XDG_RUNTIME_DIR="/run/user/$(id -u "$hid_user")" systemctl --user enable hiddify.service 2>/dev/null || \
    sudo -u "$hid_user" XDG_RUNTIME_DIR="/run/user/$(id -u "$hid_user")" systemctl --user enable HiddifyCli.service 2>/dev/null || true
  echo "[rollback] prior VPN user service re-enabled"
fi

echo "[rollback] DONE. Reboot to ensure clean state."
