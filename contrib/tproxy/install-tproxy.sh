#!/bin/bash
# Install TPROXY subsystem for sing-box-vpn.
# Sets up:
#   - /etc/nftables.d/sing-box.nft
#   - /etc/systemd/system/sing-box-tproxy-routing.service
#   - /usr/local/libexec/sing-box-vpn/sing-box-tproxy-watchdog.sh
#   - /etc/systemd/system/sing-box-watchdog.{service,timer}
#   - /etc/NetworkManager/dispatcher.d/30-sing-box-tproxy
#
# Idempotent: safe to re-run.
# Requires sudo.

set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/home/alex/sing-box-vpn}"
TPROXY_DIR="$PROJECT_DIR/contrib/tproxy"

if [[ ! -d "$TPROXY_DIR" ]]; then
    echo "ERROR: $TPROXY_DIR not found. Run from sing-box-vpn repo root." >&2
    exit 1
fi

echo "==> [1/5] nft ruleset"
sudo mkdir -p /etc/nftables.d
sudo install -m 0644 "$TPROXY_DIR/nftables.d/sing-box.nft" /etc/nftables.d/sing-box.nft

echo "==> [2/5] systemd unit (sing-box-tproxy-routing.service)"
sudo install -m 0644 "$TPROXY_DIR/systemd/sing-box-tproxy-routing.service" \
                  /etc/systemd/system/sing-box-tproxy-routing.service

echo "==> [3/5] watchdog script + unit + timer"
sudo mkdir -p /usr/local/libexec/sing-box-vpn
sudo install -m 0755 "$TPROXY_DIR/systemd/sing-box-watchdog.sh" \
                  /usr/local/libexec/sing-box-vpn/sing-box-tproxy-watchdog.sh
sudo install -m 0644 "$TPROXY_DIR/systemd/sing-box-watchdog.service" \
                  /etc/systemd/system/sing-box-watchdog.service
sudo install -m 0644 "$TPROXY_DIR/systemd/sing-box-watchdog.timer" \
                  /etc/systemd/system/sing-box-watchdog.timer

echo "==> [4/5] NetworkManager dispatcher"
sudo mkdir -p /etc/NetworkManager/dispatcher.d
sudo install -m 0755 "$TPROXY_DIR/networkmanager/dispatcher.d/30-sing-box-tproxy" \
                  /etc/NetworkManager/dispatcher.d/30-sing-box-tproxy

echo "==> [5/5] reload systemd + activate"
sudo systemctl daemon-reload
sudo systemctl enable --now sing-box-tproxy-routing.service
sudo systemctl enable --now sing-box-watchdog.timer

echo
echo "==> [6/5] capture real (non-VPN) IP for watchdog baseline"
# Probe the public IP BEFORE TPROXY is in effect — temporarily disable
# tproxy-routing so the probe goes direct, then restore.
REAL_IP_FILE="/etc/sing-box/real_ip"
mkdir -p "$(dirname "$REAL_IP_FILE")"
sudo systemctl stop sing-box-tproxy-routing.service
sleep 1
REAL_IP="$(curl -sS --max-time 8 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')"
if [[ -n "$REAL_IP" && "$REAL_IP" =~ ^[0-9]+\. ]] || [[ -n "$REAL_IP" && "$REAL_IP" =~ : ]]; then
    echo "$REAL_IP" | sudo tee "$REAL_IP_FILE" >/dev/null
    sudo chmod 0644 "$REAL_IP_FILE"
    echo "    saved: $REAL_IP -> $REAL_IP_FILE"
else
    echo "    WARNING: could not detect real IP, watchdog will skip IP comparison"
    echo "            (re-run install later or set /etc/sing-box/real_ip manually)"
fi
sudo systemctl start sing-box-tproxy-routing.service

echo
echo "TPROXY subsystem installed. Verify with:"
echo "  systemctl status sing-box-tproxy-routing sing-box-watchdog.timer"
echo "  sudo /usr/local/libexec/sing-box-vpn/sing-box-tproxy-watchdog.sh"
echo "  curl https://api.ipify.org   # should NOT be your real IP ($REAL_IP)"