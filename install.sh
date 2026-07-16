#!/usr/bin/env bash
# sing-box TPROXY VPN installer (TPROXY off by default since 2026-07-09).
# Paths: auto-detect PROJECT_DIR; RUNTIME_DIR override possible.

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
RUNTIME_PROFILES_DIR="${RUNTIME_PROFILES_DIR:-$RUNTIME_DIR/profiles}"
SERVICE_NAME="${SERVICE_NAME:-sing-box}"
SING_BOX_BIN="${SING_BOX_BIN:-/usr/local/bin/sing-box}"
LOG="${LOG:-/tmp/sing-box-install.log}"

exec > >(tee -a "$LOG") 2>&1
echo "[install] $(date -Iseconds) starting"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root (sudo $0)"
  exit 1
fi

echo "[install] uname: $(uname -r)"

install_sing_box() {
  if command -v sing-box >/dev/null 2>&1; then
    echo "[install] sing-box already installed: $(sing-box version 2>&1 | head -1)"
    return 0
  fi
  echo "[install] trying paru (AUR)..."
  if command -v paru >/dev/null 2>&1; then
    sudo -u "${SUDO_USER:-root}" paru -S --noconfirm --sudoloop sing-box-ref1nd-bin 2>&1 | tail -10 && return 0 || echo "paru failed, trying direct download"
  fi
  echo "[install] downloading sing-box v1.11.x from GitHub (1.13 has breaking DNS API)..."
  local ver="v1.11.0"
  local url="https://github.com/SagerNet/sing-box/releases/download/${ver}/sing-box-${ver#v}-linux-amd64.tar.gz"
  local tmp=$(mktemp -d)
  if curl -fsSL --max-time 180 -o "$tmp/sb.tgz" "$url"; then
    tar -xzf "$tmp/sb.tgz" -C "$tmp"
    local bin=$(find "$tmp" -name 'sing-box' -type f -executable | head -1)
    if [[ -n "$bin" ]]; then
      install -m 0755 "$bin" "$SING_BOX_BIN"
      echo "[install] installed: $("$SING_BOX_BIN" version 2>&1 | head -1)"
      return 0
    fi
  fi
  echo "ERROR: failed to download sing-box from $url"
  return 1
  echo "ERROR: cannot install sing-box. Try manually: pacman -S sing-box or paru -S sing-box-ref1nd-bin"
  return 1
}
install_sing_box || exit 2

mkdir -p /var/lib/sing-box /var/log
chown -R root:root /var/lib/sing-box

mkdir -p "$RUNTIME_PROFILES_DIR"
install -m 0640 "$PROJECT_DIR/sing-box-config.json" "$RUNTIME_DIR/config.json"
shopt -s nullglob
project_profiles=("$PROJECT_DIR/profiles/"*.json)
shopt -u nullglob
if [[ ${#project_profiles[@]} -gt 0 ]]; then
  cp "${project_profiles[@]}" "$RUNTIME_PROFILES_DIR/"
  chmod 0640 "$RUNTIME_PROFILES_DIR"/*.json
fi
[[ -f "$RUNTIME_DIR/active_profile" ]] || echo "warp-client" > "$RUNTIME_DIR/active_profile"
echo "[install] config installed: $RUNTIME_DIR/config.json"
echo "[install] profiles: $(ls "$RUNTIME_PROFILES_DIR/" | tr '\n' ' ')"
echo "[install] active: $(cat "$RUNTIME_DIR/active_profile")"

echo "[install] generating config from active profile..."
"$PROJECT_DIR/generate-config.sh"
echo "[install] validating config..."
if ! "$SING_BOX_BIN" check -c "$RUNTIME_DIR/config.json"; then
  echo "ERROR: config validation failed"
  exit 3
fi

if [[ -f /home/*/.config/systemd/user/hiddify.service ]] || [[ -f /root/.config/systemd/user/hiddify.service ]] || [[ -f /home/*/.config/systemd/user/HiddifyCli.service ]]; then
  local alt_unit
  alt_unit="${SUDO_USER:-root}"
  for svc in hiddify.service HiddifyCli.service nekoray-bin.service; do
    sudo -u "$alt_unit" XDG_RUNTIME_DIR="/run/user/$(id -u "$alt_unit")" systemctl --user disable "$svc" 2>/dev/null || true
  done
  echo "[install] hiddify-family user services disabled"
fi

echo "[install] nftables: no TPROXY rules applied (mode = SOCKS-only since 2026-07-09)"

install -m 0644 "$PROJECT_DIR/sing-box.service" "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
echo "[install] ${SERVICE_NAME}.service enabled and started"

# private-domains.txt — operator-editable list of domain suffixes
# that should bypass the SOCKS proxy (loopback, mDNS, internal LAN
# domains, etc.). See docs/EXCEPTIONS.md. install.sh creates the file
# with sane defaults if it does not exist; existing files are kept
# (no clobber) so operator edits survive re-installs.
PRIVATE_DOMAINS_FILE="$RUNTIME_DIR/private-domains.txt"
if [[ ! -f "$PRIVATE_DOMAINS_FILE" ]]; then
  install -m 0640 "$PROJECT_DIR/etc-sing-box-private-domains.txt" "$PRIVATE_DOMAINS_FILE"
  echo "[install] created $PRIVATE_DOMAINS_FILE (edit to add bypasses)"
else
  echo "[install] keeping existing $PRIVATE_DOMAINS_FILE"
fi

if [[ "${SKIP_FAILOVER:-0}" != "1" ]]; then
  install -d -m 0755 /usr/local/libexec/sing-box-vpn
  install -m 0755 "$PROJECT_DIR/failover.sh" /usr/local/libexec/sing-box-vpn/failover.sh
  install -m 0755 "$PROJECT_DIR/vpn"          /usr/local/libexec/sing-box-vpn/vpn
  install -d -m 0755 /usr/local/bin
  ln -sf /usr/local/libexec/sing-box-vpn/failover.sh /usr/local/bin/vpn-failover
  if [[ ! -e /usr/local/bin/vpn ]]; then
    ln -sf /usr/local/libexec/sing-box-vpn/vpn /usr/local/bin/vpn
  fi
  install -m 0644 "$PROJECT_DIR/contrib/systemd/vpn-failover.service" /etc/systemd/system/vpn-failover.service
  install -m 0644 "$PROJECT_DIR/contrib/systemd/vpn-failover.timer"   /etc/systemd/system/vpn-failover.timer
  systemctl daemon-reload
  systemctl enable --now vpn-failover.timer
  echo "[install] vpn-failover.timer enabled and started (every 5 min)"
fi

systemctl enable nftables 2>/dev/null || true
if command -v nft >/dev/null; then
  nft list ruleset > /etc/nftables.conf
  echo "[install] nftables state saved to /etc/nftables.conf (may be empty of sing-box rules)"
fi

sleep 3
if ! systemctl is-active --quiet "$SERVICE_NAME"; then
  echo "ERROR: $SERVICE_NAME failed to start"
  journalctl -u "$SERVICE_NAME" -n 50 --no-pager
  exit 4
fi

echo "[install] $SERVICE_NAME: ACTIVE"
systemctl status "$SERVICE_NAME" --no-pager | head -10

echo
echo "[install] testing VPN connectivity..."
for i in 1 2 3; do
  sleep 2
  echo "--- attempt $i ---"
  if curl -sS --max-time 8 https://cloudflare.com/cdn-cgi/trace 2>&1 | grep -E '^(ip|colo|loc)='; then
    echo "VPN OK"
    break
  fi
  if [[ $i -eq 3 ]]; then
    echo "WARN: VPN test failed. Check journalctl -u $SERVICE_NAME"
  fi
done

echo
echo "=== INSTALL COMPLETE ==="
echo "VPN status:"
echo "  - $SERVICE_NAME.service: $(systemctl is-active "$SERVICE_NAME")"
echo "  - clash API:        http://127.0.0.1:9090  (for GUI / web dashboard)"
echo "  - SOCKS:            127.0.0.1:12334      (for explicit proxy)"
echo
echo "Management CLI: $PROJECT_DIR/vpn"
echo "  vpn on|off|status|list|use <name>|add <name> <vless-url>|del <name>"
echo
echo "Test:  curl https://cloudflare.com/cdn-cgi/trace"
echo "Stop:  sudo $PROJECT_DIR/vpn off"
echo "Logs:  journalctl -u $SERVICE_NAME -f"
echo "Rollback: sudo $PROJECT_DIR/rollback.sh"
