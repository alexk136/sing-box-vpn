#!/usr/bin/env bash
# Start sing-box, then test every profile (glob) via SOCKS.
# Paths: auto-detect PROJECT_DIR.

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
PROFILES_DIR="${PROFILES_DIR:-$PROJECT_DIR/profiles}"
RUNTIME_DIR="${RUNTIME_DIR:-/etc/sing-box}"
RUNTIME_PROFILES_DIR="${RUNTIME_PROFILES_DIR:-$RUNTIME_DIR/profiles}"
CLI="${CLI:-$PROJECT_DIR/vpn}"
SERVICE_NAME="${SERVICE_NAME:-sing-box}"

shopt -s nullglob
profiles=("$PROFILES_DIR"/*.json)
shopt -u nullglob
if [[ ${#profiles[@]} -eq 0 ]]; then
  echo "ERROR: no profiles found in $PROFILES_DIR"
  exit 1
fi

echo "=== 1. Start $SERVICE_NAME (if not running) ==="
sudo systemctl start "$SERVICE_NAME"
sleep 3
systemctl is-active "$SERVICE_NAME"

echo
echo "=== 2. Test every profile via SOCKS ==="
results_ok=()
results_fail=()
for prof_path in "${profiles[@]}"; do
  prof=$(basename "$prof_path" .json)
  if [[ ! -f "$RUNTIME_PROFILES_DIR/$prof.json" ]]; then
    echo "--- $prof ---"
    echo "  SKIP: not in runtime (run: sudo $PROJECT_DIR/apply-profiles.sh)"
    results_fail+=("$prof")
    continue
  fi
  echo "--- $prof ---"
  sudo "$CLI" use "$prof" >/dev/null 2>&1 || { echo "  use failed"; results_fail+=("$prof"); continue; }
  sleep 3
  result=$(curl -sS --max-time 8 --socks5-hostname 127.0.0.1:12334 https://cloudflare.com/cdn-cgi/trace 2>&1 | grep -E '^(ip|colo|loc)=')
  if [[ -n "$result" ]]; then
    echo "$result"
    results_ok+=("$prof")
  else
    echo "  FAILED (no response)"
    results_fail+=("$prof")
  fi
done

echo
echo "=== 3. List profiles (with current marker) ==="
sudo "$CLI" list

echo
echo "=== 4. $SERVICE_NAME logs (last 10) ==="
sudo journalctl -u "$SERVICE_NAME" -n 10 --no-pager 2>&1 | tail -10

echo
echo "=== Summary ==="
echo "  ok:   ${results_ok[*]:-(none)}"
echo "  fail: ${results_fail[*]:-(none)}"
