#!/usr/bin/env bash
# failover.sh - probe current active profile, rotate to first working one on failure
#
# Reads PROJECT_DIR / RUNTIME_DIR / MIXED_PORT / TRACE_HOST / PROBE_TIMEOUT from
# env, or auto-detects. Exits:
#   0 = current profile is healthy, or successfully rotated to a working one
#   1 = every profile failed
#   2 = configuration error (no vpn binary, sudo fails, etc.)
#
# Examples:
#   ./failover.sh              # one-shot probe + rotate
#   DRY_RUN=1 ./failover.sh   # probe only, never rotate
#   TRACE_HOST=https://example.net ./failover.sh

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
VPN="${VPN:-$PROJECT_DIR/vpn}"
TRACE_HOST="${TRACE_HOST:-https://cloudflare.com/cdn-cgi/trace}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-8}"
MIXED_PORT="${MIXED_PORT:-12334}"
LOG_TAG="${LOG_TAG:-[vpn-failover]}"
DRY_RUN="${DRY_RUN:-0}"

log() { echo "$(date -u +%FT%TZ) $LOG_TAG $*"; }

probe_socks() {
  curl -sS --max-time "$PROBE_TIMEOUT" \
    --socks5-hostname "127.0.0.1:$MIXED_PORT" \
    "$TRACE_HOST" 2>/dev/null | grep -E '^(ip|colo|loc)='
}

probe_active() {
  local trace
  trace=$(probe_socks || true)
  [[ -n "$trace" ]]
}

list_candidates() {
  sudo "$VPN" list 2>/dev/null \
    | awk '/^[[:space:]]/ {gsub(/^[[:space:]]+\*?[[:space:]]*/, ""); split($0, a, /[[:space:]]/); print a[1]}' \
    | grep -v '^$'
}

rotate_and_probe() {
  local candidates current
  current=$(sudo "$VPN" current 2>/dev/null || echo "")
  candidates=$(list_candidates)

  for cand in $candidates; do
    [[ -z "$cand" ]] && continue
    [[ "$cand" == "$current" ]] && { log "skip: $cand is current"; continue; }
    log "trying: $cand"
    if [[ "$DRY_RUN" == "1" ]]; then
      log "dry-run: would sudo $VPN use $cand"
      continue
    fi
    if ! sudo "$VPN" use "$cand" >/dev/null 2>&1; then
      log "  $cand: use failed"
      continue
    fi
    sleep 2
    local trace
    trace=$(probe_socks || true)
    if [[ -n "$trace" ]]; then
      log "  $cand: OK ($(echo "$trace" | tr '\n' ' '))"
      return 0
    fi
    log "  $cand: probe failed"
  done
  return 1
}

main() {
  if ! command -v sudo >/dev/null 2>&1; then
    log "sudo not available; failover requires root for 'vpn use'"
    exit 2
  fi
  if [[ ! -x "$VPN" ]]; then
    log "vpn not found at $VPN (set VPN env var or PROJECT_DIR)"
    exit 2
  fi

  local current trace
  current=$(sudo "$VPN" current 2>/dev/null || echo "")
  if [[ -z "$current" || "$current" == "(none)" ]]; then
    log "no active profile, attempting rotation"
    if rotate_and_probe; then exit 0; else exit 1; fi
  fi

  trace=$(probe_socks || true)
  if [[ -n "$trace" ]]; then
    log "OK: $current ($(echo "$trace" | tr '\n' ' '))"
    exit 0
  fi

  log "FAIL: $current, rotating"
  if rotate_and_probe; then
    log "recovered; new active profile is logged above"
    exit 0
  fi
  log "ALL profiles failed"
  exit 1
}

main "$@"
