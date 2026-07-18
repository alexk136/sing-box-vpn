#!/usr/bin/env bash
# Detailed test of every VPN profile via SOCKS.
# Output: verbose log -> logs/test-all-YYYY-MM-DDTHHMMSS.log
#         compact summary -> terminal stdout

set -uo pipefail

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
PROFILES_DIR="${PROFILES_DIR:-$PROJECT_DIR/profiles}"
RUNTIME_DIR="${RUNTIME_DIR:-/etc/sing-box}"
RUNTIME_PROFILES_DIR="${RUNTIME_PROFILES_DIR:-$RUNTIME_DIR/profiles}"
CLI="${CLI:-$PROJECT_DIR/vpn}"
SERVICE_NAME="${SERVICE_NAME:-sing-box}"
SOCKS="${SOCKS:-127.0.0.1:12334}"
TIMEOUT="${TIMEOUT:-10}"

LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"
mkdir -p "$LOG_DIR"
TS=$(date -u +%Y-%m-%dT%H%M%SZ)
LOG_FILE="$LOG_DIR/test-all-$TS.log"
exec 3> "$LOG_FILE"
LOGFD=3

# tee everything to both terminal (fd 1) and log file (fd $LOGFD)
# Per-profile detail goes only to log; summary prints to terminal.

C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
C_BLUE=$'\033[0;34m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'

if [[ ! -t 1 ]]; then C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_DIM=''; C_OFF=''; fi

log() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "${1:-LOG}" "${2:-}" >&"$LOGFD"; }
logok() { log "OK " "$*"; printf '  %s[ OK  ]%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
logwarn() { log "WARN" "$*"; printf '  %s[WARN ]%s %s\n' "$C_YELLOW" "$C_OFF" "$*"; }
logfail() { log "FAIL" "$*"; printf '  %s[FAIL ]%s %s\n' "$C_RED" "$C_OFF" "$*"; }
loginfo() { log "INFO" "$*"; }

printf '%s=== test-all: %s ===%s\n' "$C_BOLD" "$(date -u +%FT%TZ)" "$C_OFF"
printf 'log: %s\n' "$LOG_FILE"
log "===== test-all run start ====="
log "PROJECT_DIR=$PROJECT_DIR PROFILES_DIR=$PROFILES_DIR RUNTIME=$RUNTIME_PROFILES_DIR SOCKS=$SOCKS"

shopt -s nullglob
profiles=("$PROFILES_DIR"/*.json)
shopt -u nullglob
if [[ ${#profiles[@]} -eq 0 ]]; then
  logfail "no profiles in $PROFILES_DIR"
  exit 1
fi
log "source profiles: ${#profiles[@]}"
runtime_profiles=("$RUNTIME_PROFILES_DIR"/*.json)
log "runtime profiles: ${#runtime_profiles[@]}"

if ! command -v sing-box >/dev/null; then
  logfail "sing-box not in PATH"; exit 1
fi
sing-box version 2>&1 | head -1 | sed 's/^/sing-box: /' | tee -a "$LOG_FILE"
log "----- service health -----"
if systemctl is-active --quiet "$SERVICE_NAME"; then
  logok "$SERVICE_NAME active"
else
  logwarn "$SERVICE_NAME not active — starting"
  sudo systemctl start "$SERVICE_NAME" || { logfail "could not start"; exit 1; }
  sleep 3
fi

# Detect restart-loop: if PID changed > 3 times in last 60s, warn
recent_restarts=$(sudo journalctl -u "$SERVICE_NAME" --since "-60s" --no-pager 2>/dev/null | grep -c "Main process exited" || true)
if [[ "$recent_restarts" -gt 3 ]]; then
  logwarn "$SERVICE_NAME restarted $recent_restarts times in last 60s — restart-loop!"
fi
log "----- sing-box logs (last 30, before run) -----"
sudo journalctl -u "$SERVICE_NAME" -n 30 --no-pager 2>&1 | tail -30 >&"$LOGFD"

active_now=$(sudo "$CLI" current 2>/dev/null | tr -d '[:space:]')
loginfo "active profile (before run): ${active_now:-(unknown)}"

# Wait for SOCKS port to actually be listening (sing-box may be restarting)
for i in 1 2 3 4 5 6 7 8 9 10; do
  if ss -tln "( sport = :12334 )" 2>/dev/null | grep -q 12334; then
    logok "SOCKS listening on $SOCKS"
    break
  fi
  loginfo "waiting for SOCKS port 12334 ($i/10)"
  sleep 2
done

log "----- direct (no VPN) baseline -----"
direct_ip=$(timeout "$TIMEOUT" curl -sS --max-time "$TIMEOUT" https://ifconfig.me 2>/dev/null | tr -d '[:space:]')
direct_trace=$(timeout "$TIMEOUT" curl -sS --max-time "$TIMEOUT" https://cloudflare.com/cdn-cgi/trace 2>/dev/null)
loginfo "direct ip  = ${direct_ip:-n/a}"
loginfo "direct loc = $(grep -E '^(ip|colo|loc)=' <<<"$direct_trace" | tr '\n' ' ')"

probe_https() {
  local prof="$1" label="$2" url="$3" expect="$4"
  local out code size time
  out=$(curl -sS -o /dev/null -L \
    -w '%{http_code} %{size_download} %{time_total}' \
    --max-time 12 --socks5-hostname "$SOCKS" "$url" 2>&1)
  code=$(awk '{print $1}' <<<"$out")
  size=$(awk '{print $2}' <<<"$out")
  time=$(awk '{print $3}' <<<"$out")
  local pass=1
  if [[ "$expect" == "2xx" ]]; then
    [[ "${code:0:1}" == "2" ]] && pass=1 || pass=0
  else
    [[ "$code" == "$expect" ]] && pass=1 || pass=0
  fi
  if [[ $pass -eq 1 ]]; then
    log "  PROBE $prof https $label code=$code size=${size}B time=${time}s"
    return 0
  else
    log "  PROBE $prof https $label FAIL code=$code (expected $expect) size=${size}B"
    return 1
  fi
}

probe_content() {
  local prof="$1" label="$2" url="$3" needle="$4"
  local body
  body=$(timeout 12 curl -sS -L --max-time 10 --socks5-hostname "$SOCKS" "$url" 2>/dev/null | head -c 4000)
  if grep -q -- "$needle" <<<"$body"; then
    log "  PROBE $prof content $label MATCH needle='$needle'"
    return 0
  else
    log "  PROBE $prof content $label FAIL needle='$needle' not in first 4KB"
    return 1
  fi
}

probe_dns() {
  local prof="$1" qname="$2"
  local body
  body=$(timeout 10 curl -sS --max-time 8 --socks5-hostname "$SOCKS" \
    "https://dns.google/resolve?name=${qname}&type=A" 2>/dev/null)
  if grep -q '"Answer"' <<<"$body"; then
    log "  PROBE $prof dns $qname OK (DoH)"
    return 0
  else
    log "  PROBE $prof dns $qname FAIL body=${body:0:120}"
    return 1
  fi
}

probe_speed() {
  local prof="$1"
  local speed
  speed=$(curl -sS -o /dev/null -L \
    -w '%{speed_download}' --max-time 20 --socks5-hostname "$SOCKS" \
    "https://speed.cloudflare.com/__down?bytes=1000000" 2>/dev/null)
  if [[ -n "$speed" && "$speed" != "0.000" ]]; then
    local mbps
    mbps=$(awk -v b="$speed" 'BEGIN{printf "%.2f", b*8/1e6}')
    log "  PROBE $prof speed 1MB download=${mbps} Mbps"
    awk -v b="$speed" 'BEGIN{ exit !(b < 100000) }' && {
      log "  PROBE $prof speed FAIL <100kbps"
      return 1
    }
    return 0
  else
    log "  PROBE $prof speed FAIL empty"
    return 1
  fi
}

results_ok=()
results_fail=()
results_skip=()

probe_one() {
  local prof="$1"
  log ""
  log "==================== profile: $prof ===================="
  printf '\n%s--- %s ---%s\n' "$C_DIM" "$prof" "$C_OFF"

  if [[ ! -f "$RUNTIME_PROFILES_DIR/$prof.json" ]]; then
    logwarn "  not in runtime — sudo $PROJECT_DIR/apply-profiles.sh"
    results_skip+=("$prof"); return
  fi

  local desc
  desc=$(jq -r '.description // "n/a"' "$PROFILES_DIR/$prof.json" 2>/dev/null)
  loginfo "desc: $desc"

  if ! sudo "$CLI" use "$prof" >/dev/null 2>&1; then
    logfail "  use failed (config invalid for this sing-box version?)"
    results_fail+=("$prof"); return
  fi
  # wait for SOCKS ready (avoid restart-loop race)
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if ss -tln "( sport = :12334 )" 2>/dev/null | grep -q 12334; then break; fi
    sleep 1
  done
  sleep 1

  local start end latency_ms trace ip_line colo_line loc_line
  start=$(date +%s%N)
  trace=$(timeout "$TIMEOUT" curl -sS --max-time "$TIMEOUT" --socks5-hostname "$SOCKS" https://cloudflare.com/cdn-cgi/trace 2>&1)
  local rc=$?
  end=$(date +%s%N)
  latency_ms=$(( (end - start) / 1000000 ))

  if [[ $rc -ne 0 ]]; then
    logfail "  curl rc=$rc (latency=${latency_ms}ms) — body=${trace:0:200}"
    results_fail+=("$prof"); return
  fi

  ip_line=$(grep '^ip=' <<<"$trace" | head -1)
  colo_line=$(grep '^colo=' <<<"$trace" | head -1)
  loc_line=$(grep '^loc=' <<<"$trace" | head -1)
  log "  exit  : $ip_line  $colo_line  $loc_line"
  log "  latency: ${latency_ms}ms"

  if [[ -z "$ip_line" ]]; then
    logfail "  empty SOCKS response"
    results_fail+=("$prof"); return
  fi

  if [[ -n "$direct_ip" && "$ip_line" == "ip=$direct_ip" ]]; then
    logwarn "  exit IP == direct IP — VPN NOT effective!"
    results_fail+=("$prof"); return
  fi

  printf '  %s%s%s  exit: %s%s%s  latency=%sms\n' "$C_DIM" "$ip_line $colo_line $loc_line" "$C_OFF" \
    "$C_BOLD" "$ip_line" "$C_OFF" "${latency_ms}ms"

  local nf=0
  probe_https      "$prof" "google"   "https://www.google.com/generate_204"   "204" || nf=$((nf+1))
  probe_https      "$prof" "gstatic"  "https://www.gstatic.com/generate_204" "204" || nf=$((nf+1))
  probe_https      "$prof" "github"   "https://github.com/"                  "2xx" || nf=$((nf+1))
  probe_https      "$prof" "wiki"     "https://en.wikipedia.org/wiki/Main_Page" "2xx" || nf=$((nf+1))
  probe_content    "$prof" "wiki-html" "https://en.wikipedia.org/wiki/Main_Page" "Wikipedia" || nf=$((nf+1))
  probe_dns        "$prof" "google.com" || nf=$((nf+1))
  probe_dns        "$prof" "github.com" || nf=$((nf+1))
  probe_speed      "$prof"                                                || nf=$((nf+1))
  # httpbin is informational only (often 503 / rate-limited)
  probe_https      "$prof" "httpbin"  "https://httpbin.org/get"               "2xx" || true

  # Tolerate 1 transient probe failure (httpbin/cloudflare flaps)
  if [[ $nf -gt 1 ]]; then
    logwarn "  real-internet: $nf probe(s) failed"
    printf '  %s[FAIL]%s %s real-internet probes failed\n' "$C_RED" "$C_OFF" "$nf"
    results_fail+=("$prof")
  elif [[ $nf -eq 1 ]]; then
    logwarn "  real-internet: 1 probe failed (tolerated, see log)"
    printf '  %s[WARN ]%s 1 real-internet probe failed (tolerated)\n' "$C_YELLOW" "$C_OFF"
    results_ok+=("$prof")
  else
    logok "real-internet: all probes passed"
    printf '  %s[ OK ]%s all real-internet probes passed\n' "$C_GREEN" "$C_OFF"
    results_ok+=("$prof")
  fi
}

log "==================== per-profile probe loop ===================="
for prof_path in "${profiles[@]}"; do
  prof=$(basename "$prof_path" .json)
  probe_one "$prof"
done

log ""
log "==================== summary ===================="
log "OK   (${#results_ok[@]}): ${results_ok[*]:-(none)}"
log "FAIL (${#results_fail[@]}): ${results_fail[*]:-(none)}"
log "SKIP (${#results_skip[@]}): ${results_skip[*]:-(none)}"

printf '\n%s=========== SUMMARY ===========%s\n' "$C_BOLD" "$C_OFF"
printf '  %sOK  (%d)%s : %s\n' "$C_GREEN" "${#results_ok[@]}" "$C_OFF" "${results_ok[*]:-(none)}"
printf '  %sFAIL(%d)%s : %s\n' "$C_RED"   "${#results_fail[@]}" "$C_OFF" "${results_fail[*]:-(none)}"
printf '  %sSKIP(%d)%s : %s\n' "$C_YELLOW" "${#results_skip[@]}" "$C_OFF" "${results_skip[*]:-(none)}"
printf '  log file: %s\n' "$LOG_FILE"

if [[ ${#results_ok[@]} -gt 0 ]]; then
  printf '\n%srestoring active -> %s%s\n' "$C_DIM" "${results_ok[0]}" "$C_OFF"
  log "restoring active profile -> ${results_ok[0]}"
  sudo "$CLI" use "${results_ok[0]}" >/dev/null 2>&1 || true
fi

exec 3>&-