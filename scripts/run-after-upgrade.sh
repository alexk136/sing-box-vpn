#!/usr/bin/env bash
# run-after-upgrade.sh — fix the broken sing-box state after AUR upgrade.
#
# Run interactively (terminal with TTY, sudo password will be prompted):
#   sudo -v && sudo /home/alex/sing-box-vpn/scripts/run-after-upgrade.sh
#
# What it does:
#   1. swap /usr/local/bin/sing-box (stale 1.11.0) for symlink to
#      /usr/bin/sing-box (new 1.13.14 from AUR pkg sing-box-bin).
#   2. /home/alex/sing-box-vpn/apply-profiles.sh -- regenerate
#      /etc/sing-box/config.json from current profiles/* on disk.
#   3. validate runtime config via the new binary.
#   4. cycle through every hysteria2 profile + warp-client, print
#      whether SOCKS-trace returns ip/colo/loc lines (= working) or
#      fails (= needs operator/admin attention).
#   5. set warp-client as the active baseline again.
#   6. show vpn-failover.timer status.
#
# Idempotent: re-running it does no harm. Safe to abort at any sudo
# prompt -- nothing has been touched until you type the password.

set -euo pipefail

PROJECT_DIR="/home/alex/sing-box-vpn"

cleanup() { :; }
trap cleanup EXIT

say()  { printf "\n=== %s ===\n" "$*"; }
ok()   { printf "  ✅ %s\n" "$*"; }
fail() { printf "  ❌ %s\n" "$*"; }

say "0. prerequisites"
command -v sing-box >/dev/null 2>&1 || { fail "sing-box not on PATH"; exit 1; }
command -v sudo        >/dev/null 2>&1 || { fail "sudo not installed"; exit 1; }

say "1. point service unit at the new binary"

# Ensure drop-in dir exists with the legacy-DNS env var required by sing-box >= 1.12
# (allows the existing template format to keep working; proper template
# migration is tracked separately).
mkdir -p /etc/systemd/system/sing-box.service.d 2>/dev/null || true
if [[ ! -f /etc/systemd/system/sing-box.service.d/deprecated-dns.conf ]]; then
  cat > /etc/systemd/system/sing-box.service.d/deprecated-dns.conf <<'EOF_UNIT'
[Service]
Environment="ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true"
EOF_UNIT
  echo "  * created drop-in /etc/systemd/system/sing-box.service.d/deprecated-dns.conf"
fi
systemctl daemon-reload

# Force restart so the running process picks up the new env var
# and the binary symlink. apply-profiles.sh alone uses 'enable --now'
# which only starts a stopped service.
systemctl restart sing-box
ok "sing-box.service restarted, env var + binary swap both live"
if [[ -L /usr/local/bin/sing-box ]] && [[ "$(readlink -f /usr/local/bin/sing-box)" == "/usr/bin/sing-box" ]]; then
  ok "/usr/local/bin/sing-box already symlinks to /usr/bin/sing-box"
elif [[ -e /usr/local/bin/sing-box ]]; then
  printf "  * removing stale /usr/local/bin/sing-box (%s)\n" "$(/usr/local/bin/sing-box version 2>&1 | head -1 || echo unknown)"
  sudo rm -f /usr/local/bin/sing-box
  sudo ln -s /usr/bin/sing-box /usr/local/bin/sing-box
  ok "created symlink /usr/local/bin/sing-box -> /usr/bin/sing-box"
else
  sudo ln -s /usr/bin/sing-box /usr/local/bin/sing-box
  ok "created symlink /usr/local/bin/sing-box -> /usr/bin/sing-box"
fi
printf "  * version test: "; /usr/local/bin/sing-box version 2>&1 | head -2 | tr '\n' ' '; echo

say "2. clear any old blacklist"
sudo rm -rf /var/tmp/sing-box-vpn-broken || true
ok "/var/tmp/sing-box-vpn-broken/ cleared (failover will re-probe all)"

say "3. re-apply profiles + template (regenerates /etc/sing-box/config.json)"
sudo "$PROJECT_DIR/apply-profiles.sh"

say "4. validate runtime config"
if sudo /usr/bin/sing-box check -c /etc/sing-box/config.json; then
  ok "config valid"
else
  fail "config INVALID -- tail sing-box.log:"; tail -20 /var/log/sing-box.log; exit 1
fi

say "5. cycle every profile and probe"
results_ok=()
results_fail=()
for p in sa888f72b elrise-hy2 tmp-vps tmp-vps-v6 warp-client user1-no-flow; do
  printf "  ---- %s ----\n" "$p"
  if ! sudo "$PROJECT_DIR/vpn" use "$p" >/dev/null 2>&1; then
    fail "vpn use failed"; results_fail+=("$p"); continue
  fi
  sleep 2
  out=$(curl -sS --max-time 8 --socks5-hostname 127.0.0.1:12334 \
            https://1.1.1.1/cdn-cgi/trace 2>&1 \
         | grep -E '^(ip|colo|loc)=')
  if [[ -n "$out" ]]; then
    ok "$out"
    results_ok+=("$p")
  else
    fail "no SOCKS trace -- tail sing-box.log:"
    tail -8 /var/log/sing-box.log
    results_fail+=("$p")
  fi
  sleep 1
done

say "5b. summary"
echo "  ok:   ${results_ok[*]:-(none)}"
echo "  fail: ${results_fail[*]:-(none)}"

say "6. baseline active = warp-client"
sudo "$PROJECT_DIR/vpn" use warp-client
sleep 2
trace=$(curl -sS --max-time 8 --socks5-hostname 127.0.0.1:12334 https://1.1.1.1/cdn-cgi/trace 2>&1 | grep -E '^(ip|colo|loc)=')
echo "  warp-client trace: ${trace:-(inconclusive)}"

say "7. failover"
systemctl is-enabled vpn-failover.timer 2>/dev/null && echo "  vpn-failover.timer: enabled" || echo "  vpn-failover.timer: NOT enabled -- 'sudo systemctl enable --now vpn-failover.timer'"
systemctl list-timers vpn-failover.timer 2>/dev/null | head -3

say "done"
echo "  pass the full output to the sysadmin/operator if anything fails."
