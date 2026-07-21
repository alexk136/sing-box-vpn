# Changelog

## 2026-07-21 — `contrib/tproxy/` subsystem added + container bypass fix

Adds an optional, opt-in transparent-proxy layer so every TCP/UDP packet
from user processes is redirected through sing-box without per-app SOCKS
configuration.

**Important:** Container traffic (Docker bridge subnets, 172.16.0.0/12) is
**excluded** from TPROXY. Reason: sing-box accepts the packet and sends
it through the VPN, but the response back to the container
(src=public_ip, dst=container_ip) traverses the host's FORWARD chain
where the default `-P FORWARD DROP` policy (and the lack of an explicit
ACCEPT for `src=public_ip → br-*` direction) silently kills the return
packet. Net result without the exclusion: TCP from containers times
out. With the exclusion: containers go direct via Docker MASQUERADE,
host still goes via VPN. To put containers behind the VPN, route them
via SOCKS (`127.0.0.1:12334`) or set up per-network policy routing.

- `contrib/tproxy/nftables.d/sing-box.nft` — `chain prerouting` (TPROXY)
  + `chain output` (mark + ip rule fwmark 0x1 → table 200 → lo).
- `contrib/tproxy/systemd/sing-box-tproxy-routing.service` — loads nft
  + sets ip rule + route in table 200. Table **200** is used (NOT 100,
  which `NetworkManager`'s `99-ecmp-wifi.sh` flushes on every WiFi
  `up` event).
- `contrib/tproxy/systemd/sing-box-watchdog.{service,timer,sh}` —
  every 1 minute: verifies TPROXY chain + rule + table 200, auto-fixes
  if missing. Probes external IP as user `alex` (via `runuser`) so the
  probe goes through TPROXY instead of bypassing it via the
  `meta skuid root return` loop-prevention rule.
- `contrib/tproxy/networkmanager/dispatcher.d/30-sing-box-tproxy` —
  re-applies `default dev lo table 200` and `ip rule add fwmark 0x1
  lookup 200` on `up`/`dhcp4-change`/`hostname` events.
- `contrib/tproxy/install-tproxy.sh` — idempotent installer; also
  auto-runs from `install.sh` when `INSTALL_TPROXY=1` is set.
- `contrib/tproxy/uninstall-tproxy.sh` — full rollback.

`install.sh` learned `INSTALL_TPROXY=1` and an interactive prompt at
the end of install. TPROXY stays **off by default** — SOCKS-only mode
is preserved.

See [docs/TPROXY.md](docs/TPROXY.md).

## 2026-07-16 — sing-box 1.13.14 migration (commits 8ae0d24, 77c6850, ade9048)

### Required sing-box version: 1.13.0 or newer

The host now runs `sing-box-bin 1.13.14` (AUR pkg, previously
binary install at 1.11.0). Two breaking schema changes from
`sing-box 1.12.0` and `1.13.0` affect this project:

#### 1. Legacy inbound fields removed in 1.13.0

Before (worked on 1.11.0, rejected on 1.13.0):

```json
{
  "type": "tproxy",
  "tag": "tproxy-in",
  "listen": "::",
  "listen_port": 12335,
  "network": "tcp",
  "sniff": true,
  "sniff_override_destination": true
}
```

After:

```json
{
  "type": "tproxy",
  "tag": "tproxy-in",
  "listen": "::",
  "listen_port": 12335
}
```

with the rule moved to `route.rules`:

```json
{"action": "sniff"}
```

Migration reference:
<https://sing-box.sangernet.org/migration/#migrate-legacy-inbound-fields-to-rule-actions>

#### 2. `default_domain_resolver` requirement (1.12+)

Sing-box 1.12+ requires every outbound to either declare
`domain_resolver` explicitly or have a global
`route.default_domain_resolver` setting. Otherwise:

```
ERROR missing `route.default_domain_resolver` or `domain_resolver` in
       dial fields is deprecated in sing-box 1.12.0 and will be
       removed in sing-box 1.14.0
FATAL to continuing using this feature, set environment variable
      ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true
```

(no such env var exists; this is migration-required, not bypass-able)

Fix: add `route.default_domain_resolver: "dns-direct"` to template.

Migration reference:
<https://sing-box.sangernet.org/migration/#migrate-outbound-dns-rule-items-to-domain-resolver>

#### 3. Legacy DNS server format (1.12+, removed in 1.14+)

Currently bypassed with systemd drop-in
`/etc/systemd/system/sing-box.service.d/deprecated-dns.conf`:

```ini
[Service]
Environment="ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true"
Environment="ENABLE_DEPRECATED_LEGACY_INBOUND_FIELDS=true"
Environment="ENABLE_DEPRECATED_LEGACY_OUTBOUND_FIELDS=true"
```

When upgrading to `sing-box 1.14+`, the DNS server schema must also
be migrated to the new format:

```json
// legacy (works through 1.13 with the env vars above):
{"tag": "dns-remote", "address": "https://1.1.1.1/dns-query", ...}

// new (1.12+ preferred, mandatory 1.14+):
{"type": "https", "tag": "dns-remote", "server": "1.1.1.1", "server_port": 443, "path": "/dns-query", "domain_resolver": "dns-direct", ...}
```

Migration reference:
<https://sing-box.sangernet.org/migration/#migrate-to-new-dns-server-formats>

### Profiles cleaned

- All three hysteria2 profiles: removed unsupported fields
  (`congestion_control`, `alpn`, `hop_interval`) — these were added
  in 1.12+ and silently rejected as `unknown field` by 1.11.0
- One USA hysteria2 profile: added `tls.insecure: true` (cert SAN not
  validated against SNI for this profile)
- Other profiles retain `tls.insecure: true` per their original
  cert/SNI mismatch

(Note: profile filenames are local labels and may differ per host.
This changelog uses generic descriptions to avoid leaking host-specific
profile names.)

### 2026-07-15 — failover feature (commit 420b305)

Auto-failover probe + systemd timer + `contrib/systemd/` units.
Default-on via `install.sh`. Blacklists failed profiles for
`BROKEN_TTL_SEC=1800` (30 min).

### 2026-07-15 — auto-discovery + multi-protocol URL parser (commit c756de4)

- `vpn.sh` URL parser supports `vless://`, `hy2://`, `hysteria2://`,
  `ss://`, `vmess://`, `trojan://`
- `apply-profiles.sh` + `test-all.sh` glob `profiles/*.json` instead of
  hardcoded profile list

### 2026-07-15 — no hardcoded paths (commit c756de4 + 8ae0d24)

- `PROJECT_DIR` auto-detected via `BASH_SOURCE` + `readlink -f`
- `RUNTIME_DIR` env-overridable (default `/etc/sing-box`)
- All 6 shell scripts honor overrides; no hardcoded `/home/...` paths

### 2026-07-15 — production readiness checklist (commit 7fceb54, removed at 5465df5)

Checklist was added then removed at user's request. The verified state
serves the same purpose (see "Verified state" section above).

### 2026-07-09..14 — pre-redesign history

Archived in git reflog (commits 8730a02 → bc726a1 → 80501a5 →
11686c3 → 8730a02 / d19f58d / 601531c). The final redesign under
commit `601531c Init VPN` was later squashed to `d19f58d` and
re-rewritten with the failover feature on top.
