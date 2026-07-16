#!/usr/bin/env bash
# Copy every profile in profiles/*.json to runtime, validate via
# sing-box check, then test connectivity via SOCKS.
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
PROFILES_DIR="${PROFILES_DIR:-$PROJECT_DIR/profiles}"
RUNTIME_DIR="${RUNTIME_DIR:-/etc/sing-box}"
RUNTIME_PROFILES_DIR="${RUNTIME_PROFILES_DIR:-$RUNTIME_DIR/profiles}"
ACTIVE_FILE="${ACTIVE_FILE:-$RUNTIME_DIR/active_profile}"
CLI="${CLI:-$PROJECT_DIR/vpn}"
SERVICE_NAME="${SERVICE_NAME:-sing-box}"
SING_BOX="${SING_BOX:-/usr/local/bin/sing-box}"

shopt -s nullglob
profiles=("$PROFILES_DIR"/*.json)
shopt -u nullglob
if [[ ${#profiles[@]} -eq 0 ]]; then
  echo "ERROR: no profiles found in $PROFILES_DIR"
  exit 1
fi

default_profile="$(cat "$ACTIVE_FILE" 2>/dev/null || echo "")"

echo "=== 1. Copy profiles to runtime ==="
sudo install -d -m 0755 "$RUNTIME_PROFILES_DIR"
sudo cp "${profiles[@]}" "$RUNTIME_PROFILES_DIR/"
sudo chmod 0640 "$RUNTIME_PROFILES_DIR"/*.json
echo "  copied: $(basename -a "${profiles[@]}" | tr '\n' ' ')"

echo
echo "=== 2. Validate every profile via generate + sing-box check ==="
for prof_path in "${profiles[@]}"; do
  prof=$(basename "$prof_path" .json)
  echo "--- $prof ---"
  echo "$prof" | sudo tee "$ACTIVE_FILE" >/dev/null
  sudo "$PROJECT_DIR/generate-config.sh"
  sudo "$SING_BOX" check -c "$RUNTIME_DIR/config.json" 2>&1 | head -3
done

echo
echo "=== 3. Test every profile via SOCKS ==="
results_ok=()
results_fail=()
for prof_path in "${profiles[@]}"; do
  prof=$(basename "$prof_path" .json)
  echo "--- $prof ---"
  sudo "$CLI" use "$prof" >/dev/null 2>&1 || { echo "  use failed"; results_fail+=("$prof"); continue; }
  sleep 2
  result=$(curl -sS --max-time 8 --socks5-hostname 127.0.0.1:12334 https://cloudflare.com/cdn-cgi/trace 2>&1 | grep -E '^(ip|colo|loc)=')
  if [[ -n "$result" ]]; then
    echo "$result"
    results_ok+=("$prof")
  else
    echo "  FAILED"
    results_fail+=("$prof")
  fi
done

echo
echo "=== 4. Switch back to default profile (${default_profile:-warp-client}) ==="
if [[ -n "$default_profile" ]] && [[ -f "$RUNTIME_PROFILES_DIR/$default_profile.json" ]]; then
  sudo "$CLI" use "$default_profile"
else
  sudo "$CLI" use warp-client
fi

echo
echo "=== 5. List profiles ==="
sudo "$CLI" list

echo
echo "=== Summary ==="
echo "  ok:    ${results_ok[*]:-(none)}"
echo "  fail:  ${results_fail[*]:-(none)}"
