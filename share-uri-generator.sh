#!/usr/bin/env bash
# Generate hysteria2:// / vless:// / etc share URIs from sing-box-vpn profiles
# for import into hiddify / nekobox / clash / etc.
#
# Usage:
#   ./share-uri-generator.sh                 # writes to ~/sing-box-vpn/share-uri.txt
#   ./share-uri-generator.sh /path/out.txt   # custom output
#
# Reads from: /home/alex/sing-box-vpn/profiles/*.json
# Format spec:
#   hysteria2: https://v2.hysteria.network/docs/developers/uri/
#   vless:     https://github.com/XTLS/Xray-core (vless://UUID@host:port?params#name)

set -euo pipefail

PROFILES_DIR="${PROFILES_DIR:-/home/alex/sing-box-vpn/profiles}"
OUT="${1:-/home/alex/sing-box-vpn/share-uri.txt}"

# urlencode (lightweight)
urlencode() {
  python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

: > "$OUT"

for prof_path in "$PROFILES_DIR"/*.json; do
  prof=$(basename "$prof_path" .json)
  type=$(jq -r .type "$prof_path")
  server=$(jq -r .server "$prof_path")
  port=$(jq -r .server_port "$prof_path")
  desc=$(jq -r '.description // ""' "$prof_path")

  {
    echo "# ============================================================"
    echo "# Profile: $prof"
    echo "# Description: $desc"
    echo "# ============================================================"
  } >> "$OUT"

  case "$type" in
    hysteria2)
      password=$(jq -r '.password' "$prof_path")
      sni=$(jq -r '.tls.server_name // ""' "$prof_path")
      insecure=$(jq -r '.tls.insecure // false' "$prof_path")
      name_enc=$(urlencode "$prof")
      uri="hysteria2://${password}@${server}:${port}/"
      query=""
      [[ -n "$sni" ]] && query+="sni=${sni}"
      if [[ "$insecure" == "true" ]]; then
        [[ -n "$query" ]] && query+="&"
        query+="insecure=1"
      fi
      [[ -n "$query" ]] && uri+="?${query}"
      uri+="#${name_enc}"
      echo "$uri" >> "$OUT"
      ;;

    vless)
      uuid=$(jq -r '.uuid' "$prof_path")
      flow=$(jq -r '.flow // ""' "$prof_path")
      tls_enabled=$(jq -r '.tls.enabled // false' "$prof_path")
      security="none"
      extra=""
      if [[ "$tls_enabled" == "true" ]]; then
        sni=$(jq -r '.tls.server_name // ""' "$prof_path")
        reality_enabled=$(jq -r '.tls.reality.enabled // false' "$prof_path")
        if [[ "$reality_enabled" == "true" ]]; then
          security="reality"
          pbk=$(jq -r '.tls.reality.public_key // ""' "$prof_path")
          sid=$(jq -r '.tls.reality.short_id // ""' "$prof_path")
          fp=$(jq -r '.tls.utls.fingerprint // "chrome"' "$prof_path")
          extra="security=reality&pbk=$(urlencode "$pbk")&fp=$(urlencode "$fp")&sni=$(urlencode "$sni")&sid=$(urlencode "$sid")&flow=$(urlencode "$flow")&type=tcp"
        else
          security="tls"
          extra="security=tls&sni=$(urlencode "$sni")&type=tcp"
        fi
      else
        extra="security=none&type=tcp"
        [[ -n "$flow" ]] && extra+="&flow=$(urlencode "$flow")"
      fi
      name_enc=$(urlencode "$prof")
      uri="vless://${uuid}@${server}:${port}?${extra}#${name_enc}"
      echo "$uri" >> "$OUT"
      ;;

    ss)
      method=$(jq -r '.method // "chacha20-ietf-poly1305"' "$prof_path")
      password=$(jq -r '.password' "$prof_path")
      name_enc=$(urlencode "$prof")
      uri="ss://$(urlencode "$method"):$(urlencode "$password")@${server}:${port}#${name_enc}"
      echo "$uri" >> "$OUT"
      ;;

    trojan)
      password=$(jq -r '.password' "$prof_path")
      sni=$(jq -r '.tls.server_name // ""' "$prof_path")
      name_enc=$(urlencode "$prof")
      uri="trojan://${password}@${server}:${port}?security=tls&sni=$(urlencode "$sni")&type=tcp#${name_enc}"
      echo "$uri" >> "$OUT"
      ;;

    *)
      echo "# (unsupported type: $type - skipping)" >> "$OUT"
      ;;
  esac

  echo "" >> "$OUT"
done

echo "wrote $OUT"
ls -la "$OUT"