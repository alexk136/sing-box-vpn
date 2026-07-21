#!/bin/bash
# /usr/local/libexec/sing-box-vpn/sing-box-tproxy-watchdog.sh
#
# Verifies the sing-box TPROXY subsystem and auto-fixes common failures.
# Runs every 1 minute via `sing-box-watchdog.timer`.
#
# Checks:
#   1. sing-box.service active
#   2. sing-box-tproxy-routing.service active
#   3. nft table inet sing-box loaded with both chains and tproxy rule
#   4. ip rule 'fwmark 0x1 lookup 200' present
#   5. table 200 has route via lo
#   6. External IP (probed as user alex, so the probe goes through TPROXY
#      instead of bypassing it via the `meta skuid root return` rule)
#      differs from the saved real IP.
#
# Auto-fixes with 10-60s cooldowns per key (in /run) to avoid thrashing.

set -u

LOG_TAG="sing-box-watchdog"
REAL_IP_FILE="/etc/sing-box/real_ip"
IP_PROBE_URL="${SING_BOX_IP_PROBE_URL:-https://api.ipify.org}"
PROBE_TIMEOUT="${SING_BOX_PROBE_TIMEOUT:-8}"
STATE_DIR="/run/sing-box-watchdog"
mkdir -p "$STATE_DIR"

fail=0
fixed=0

log()  { logger -t "$LOG_TAG" -p "user.$1" -- "$2"; }
note() {
    if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && command -v notify-send >/dev/null; then
        notify-send -u critical "sing-box: $1" "$2" 2>/dev/null || true
    fi
}

# Run a command as user alex (so the curl probe traverses TPROXY;
# root traffic is excluded by `meta skuid root return` in chain output).
run_as_alex() {
    if command -v runuser >/dev/null; then
        runuser -u alex -- "$@"
    elif command -v su >/dev/null; then
        su alex -s /bin/bash -c "$(printf '%q ' "$@")"
    else
        "$@"
    fi
}

cooldown() {
    local key="$1" secs="${2:-10}"
    local now last_file="$STATE_DIR/lastfix.$key"
    now="$(date +%s)"
    if [[ -f "$last_file" ]]; then
        local last; last="$(cat "$last_file")"
        if (( now - last < secs )); then
            return 1
        fi
    fi
    echo "$now" > "$last_file"
    return 0
}

# 1. sing-box.service active
if ! systemctl is-active --quiet sing-box.service; then
    log err "sing-box.service is NOT active"
    if cooldown sing-box 60; then
        systemctl start sing-box.service || true
        sleep 2
        fixed=1
    fi
    systemctl is-active --quiet sing-box.service || fail=1
fi

# 2. sing-box-tproxy-routing.service active
if ! systemctl is-active --quiet sing-box-tproxy-routing.service; then
    log err "sing-box-tproxy-routing.service is NOT active"
    if cooldown tproxy-svc 60; then
        systemctl restart sing-box-tproxy-routing || true
        sleep 2
        fixed=1
    fi
    systemctl is-active --quiet sing-box-tproxy-routing.service || fail=1
fi

# 3. nft table inet sing-box loaded with both chains and tproxy rule
if ! nft list table inet sing-box >/dev/null 2>&1; then
    log warning "nft table inet sing-box is NOT loaded"
    if cooldown nft-table 30; then
        systemctl restart sing-box-tproxy-routing || true
        sleep 2
        fixed=1
    fi
    nft list table inet sing-box >/dev/null 2>&1 || fail=1
fi

if ! nft list table inet sing-box 2>/dev/null | grep -q "chain prerouting"; then
    log err "nft table inet sing-box is missing chain prerouting"
    fail=1
fi
if ! nft list table inet sing-box 2>/dev/null | grep -q "chain output"; then
    log err "nft table inet sing-box is missing chain output"
    fail=1
fi
if ! nft list table inet sing-box 2>/dev/null | grep -q "tproxy to :12335"; then
    log err "nft table is missing the tproxy to :12335 rule"
    fail=1
fi

# 4. ip rule for fwmark 0x1 -> table 200
if ! ip rule show | grep -q "fwmark 0x1 lookup 200"; then
    log warning "ip rule 'fwmark 0x1 lookup 200' missing"
    if cooldown ip-rule 10; then
        /sbin/ip rule add fwmark 0x1 lookup 200 priority 50 || true
        fixed=1
    fi
    ip rule show | grep -q "fwmark 0x1 lookup 200" || fail=1
fi

# 5. table 200 has default dev lo route (NM doesn't manage table 200)
if ! ip route show table 200 | grep -q "dev lo"; then
    log warning "table 200 has no route via lo"
    if cooldown table200 10; then
        /sbin/ip route replace default dev lo table 200 || true
        fixed=1
        log info "auto-fix: re-added 'default dev lo table 200'"
    fi
    ip route show table 200 | grep -q "dev lo" || fail=1
fi

# 6. External IP must differ from real IP. Probe as alex via TPROXY.
ext_ip="$(run_as_alex curl -sS --max-time "$PROBE_TIMEOUT" "$IP_PROBE_URL" 2>/dev/null || true)"
if [[ -z "$ext_ip" ]]; then
    log warning "could not determine external IP from $IP_PROBE_URL"
    fail=1
elif [[ -f "$REAL_IP_FILE" ]]; then
    real_ip="$(cat "$REAL_IP_FILE")"
    if [[ "$ext_ip" == "$real_ip" ]]; then
        log err "external IP ($ext_ip) equals real IP -> VPN NOT effective"
        note "WATCHDOG FAILED" "external=$ext_ip == real=$real_ip; journalctl -t $LOG_TAG -n 30"
        fail=1
    else
        log info "VPN OK: external=$ext_ip real=$real_ip"
    fi
else
    log warning "$REAL_IP_FILE missing, skipping IP comparison"
fi

if [[ $fail -ne 0 ]]; then
    log err "WATCHDOG FAILED"
    exit 1
fi

if [[ $fixed -ne 0 ]]; then
    log info "WATCHDOG OK (auto-fix applied this run)"
else
    log info "WATCHDOG OK"
fi
exit 0