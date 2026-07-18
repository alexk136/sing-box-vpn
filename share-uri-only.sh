#!/usr/bin/env bash
# Generate ONLY the share URIs (no comments) for easy import into clients
# Usage: ./share-uri-only.sh > uris.txt
set -euo pipefail
PROFILES_DIR="${PROFILES_DIR:-/home/alex/sing-box-vpn/profiles}"
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
/home/alex/sing-box-vpn/share-uri-generator.sh "$DIR/out.txt" >/dev/null
grep -E '^(hysteria|hysteria2|vless|ss|trojan|naive|vmess|hy2)://' "$DIR/out.txt"