#!/usr/bin/env bash
# Generate <RUNTIME_DIR>/config.json from template + active profile.
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
TEMPLATE="${TEMPLATE:-$PROJECT_DIR/sing-box-config.json}"
RUNTIME_DIR="${RUNTIME_DIR:-/etc/sing-box}"
PROFILES_DIR="${PROFILES_DIR:-$RUNTIME_DIR/profiles}"
ACTIVE_FILE="${ACTIVE_FILE:-$RUNTIME_DIR/active_profile}"
OUT="${OUT:-$RUNTIME_DIR/config.json}"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: template not found: $TEMPLATE"
  exit 1
fi

if [[ ! -f "$ACTIVE_FILE" ]]; then
  echo "ERROR: no active profile (run: sudo $PROJECT_DIR/vpn use <name>)"
  exit 1
fi

active=$(cat "$ACTIVE_FILE")
profile="$PROFILES_DIR/$active.json"

if [[ ! -f "$profile" ]]; then
  echo "ERROR: profile not found: $profile"
  exit 1
fi

python3 - "$TEMPLATE" "$profile" "$OUT" <<'PYEOF'
import json, sys

template_path, profile_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(template_path) as f:
    cfg = json.load(f)
with open(profile_path) as f:
    profile = json.load(f)

proxy_out = {
    "type": profile["type"],
    "tag": "proxy-out",
    "server": profile["server"],
    "server_port": profile["server_port"],
}
for k, v in profile.items():
    if k in ("name", "description", "type", "tag", "server", "server_port"):
        continue
    proxy_out[k] = v

new_outbounds = []
inserted = False
for ob in cfg["outbounds"]:
    new_outbounds.append(ob)
    if ob.get("type") == "selector" and not inserted:
        new_outbounds.append(proxy_out)
        inserted = True
if not inserted:
    new_outbounds.append(proxy_out)
cfg["outbounds"] = new_outbounds

with open(out_path, "w") as f:
    json.dump(cfg, f, indent=2)
print(f"Generated: {out_path} (active profile: {profile.get('name','?')}, type: {profile['type']})")
PYEOF
