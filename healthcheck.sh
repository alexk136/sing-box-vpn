#!/usr/bin/env bash
# sing-box-vpn auto-failover: switch profile, restart, test, log.
# Runs every 60s; tries profile list in order until test succeeds.
set -u

LOG=/home/alex/.local/share/sing-box/health.log
PROFILES=(tmp-vps-sb tmp-vps-tls warp-client elrise-hy2)
PROFILES_DIR=/home/alex/sing-box-vpn/profiles
mkdir -p "$(dirname "$LOG")"

log() {
    local ts; ts=$(date -u +%FT%TZ)
    printf '%s | %s\n' "$ts" "$*" | tee -a "$LOG"
}

rotate_profile() {
    local prof=$1
    log "switch -> $prof"
    sudo /home/alex/sing-box-vpn/vpn use "$prof" >/dev/null 2>&1 || {
        log "  use failed"; return 1
    }
    sudo systemctl restart sing-box.service >/dev/null 2>&1 || {
        log "  restart failed"; return 1
    }
    sleep 3
    return 0
}

test_vpn() {
    local ip
    ip=$(timeout 12 curl -sS --max-time 8 --socks5-hostname 127.0.0.1:12334 \
        https://api.ipify.org 2>/dev/null | tr -d '[:space:]')
    [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$|[0-9a-fA-F:]+$ ]]
}

current_profile() {
    cat /etc/sing-box/active_profile 2>/dev/null
}

# Initial check
cur=$(current_profile)
ip=$(timeout 12 curl -sS --max-time 8 --socks5-hostname 127.0.0.1:12334 \
    https://api.ipify.org 2>/dev/null | tr -d '[:space:]')

if [[ -n "$ip" ]]; then
    log "OK active=$cur ip=$ip"
    exit 0
fi

log "FAIL active=$cur — trying fallbacks"
for p in "${PROFILES[@]}"; do
    [[ "$p" == "$cur" ]] && continue
    [[ ! -f "$PROFILES_DIR/$p.json" ]] && { log "skip $p (no source)"; continue; }
    rotate_profile "$p" || continue
    if test_vpn; then
        ip=$(timeout 8 curl -sS --max-time 6 --socks5-hostname 127.0.0.1:12334 \
            https://api.ipify.org 2>/dev/null | tr -d '[:space:]')
        log "RECOVERED -> $p ip=$ip"
        exit 0
    fi
done

log "ALL FAIL — leaving profile $cur"
exit 1