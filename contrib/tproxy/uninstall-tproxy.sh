#!/bin/bash
# Uninstall TPROXY subsystem (leaves the basic sing-box SOCKS proxy intact).

set -euo pipefail

echo "==> Stop + disable TPROXY services"
sudo systemctl disable --now sing-box-watchdog.timer 2>/dev/null || true
sudo systemctl stop sing-box-tproxy-routing.service 2>/dev/null || true
sudo systemctl disable sing-box-tproxy-routing.service 2>/dev/null || true

echo "==> Remove nft table + rules"
sudo nft delete table inet sing-box 2>/dev/null || true
sudo ip rule del fwmark 0x1 lookup 200 priority 50 2>/dev/null || true
sudo ip route flush table 200 2>/dev/null || true

echo "==> Remove unit files"
sudo rm -f /etc/systemd/system/sing-box-tproxy-routing.service
sudo rm -f /etc/systemd/system/sing-box-watchdog.service
sudo rm -f /etc/systemd/system/sing-box-watchdog.timer
sudo systemctl daemon-reload
sudo systemctl reset-failed sing-box-tproxy-routing 2>/dev/null || true
sudo systemctl reset-failed sing-box-watchdog 2>/dev/null || true

echo "==> Remove NM dispatcher"
sudo rm -f /etc/NetworkManager/dispatcher.d/30-sing-box-tproxy

echo "==> Remove files"
sudo rm -f /etc/nftables.d/sing-box.nft
sudo rm -f /usr/local/libexec/sing-box-vpn/sing-box-tproxy-watchdog.sh

echo
echo "TPROXY subsystem removed. The basic sing-box SOCKS proxy on"
echo "127.0.0.1:12334 is still running (use 'sudo vpn off' to stop it too)."