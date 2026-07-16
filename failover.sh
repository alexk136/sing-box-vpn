#!/usr/bin/env bash
# failover.sh - probe current active profile, rotate to first working one on failure.
# Broken profiles (failed recently, within BROKEN_TTL_SEC) are skipped.
# State file: /var/tmp/sing-box-vpn-broken/<profile>

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
if [[ -z "${VPN:-}" ]]; then
  if command -v vpn >/dev/null 2>&1; then
    VPN="$(command -v vpn)"
  else
    VPN="$PROJECT_DIR/vpn"
  fi
fi
TRACE_HOST="${TRACE_HOST:-https://cloudflare.com/cdn-cgi/trace}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-8}"
MIXED_PORT="${MIXED_PORT:-12334}"
LOG_TAG="${LOG_TAG:-[vpn-failover]}"
DRY_RUN="${DRY_RUN:-0}"
BROKEN_DIR="${BROKEN_DIR:-/var/tmp/sing-box-vpn-broken}"
BROKEN_TTL_SEC="${BROKEN_TTL_SEC:-1800}"

log() { echo "$(date -u +%FT%TZ) $LOG_TAG $*"; }

mark_broken() {
  local prof="$1"
  [[ -d "$BROKEN_DIR" ]] || mkdir -p "$BROKEN_DIR" 2>/dev/null || true
  [[ -d "$BROKEN_DIR" ]] && date +%s > "$BROKEN_DIR/$prof" 2>/dev/null || true
}

mark_healthy() {
  local prof="$1"
  rm -f "$BROKEN_DIR/$prof" 2>/dev/null || true
}

is_recently_broken() {
  local prof="$1"
  local f="$BROKEN_DIR/$prof"
  [[ -f "$f" ]] || return 1
  local mark
  mark=$(cat "$f" 2>/dev/null || echo 0)
  local now
  now=$(date +%s)
  (( now - mark < BROKEN_TTL_SEC ))
}

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
  local candidates current skipped
  current=$(sudo "$VPN" current 2>/dev/null || echo "")
  candidates=$(list_candidates)

  for cand in $candidates; do
    [[ -z "$cand" ]] && continue
    [[ "$cand" == "$current" ]] && { log "skip: $cand is current"; continue; }
    if is_recently_broken "$cand"; then
      log "skip: $cand recently broken (TTL ${BROKEN_TTL_SEC}s)"
      skipped=1
      continue
    fi
    log "trying: $cand"
    if [[ "$DRY_RUN" == "1" ]]; then
      log "dry-run: would sudo $VPN use $cand"
      continue
    fi
    if ! sudo "$VPN" use "$cand" >/dev/null 2>&1; then
      log "  $cand: use failed"
      mark_broken "$cand"
      continue
    fi
    sleep 2
    local trace
    trace=$(probe_socks || true)
    if [[ -n "$trace" ]]; then
      log "  $cand: OK ($(echo "$trace" | tr '\n' ' '))"
      mark_healthy "$cand"
      return 0
    fi
    log "  $cand: probe failed"
    mark_broken "$cand"
  done
  if [[ -n "${skipped:-}" ]] && (( skipped )); then
    log "hint: ${BROKEN_TTL_SEC}s blacklist active at $BROKEN_DIR"
  fi
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

  log "FAIL: $current, marking as broken, rotating"
  mark_broken "$current"
  if rotate_and_probe; then
    log "recovered; new active profile is logged above"
    exit 0
  fi
  log "ALL profiles failed or blacklisted"
  exit 1
}

main "$@"
