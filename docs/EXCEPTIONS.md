# Exception lists for SOCKS bypass

By default, all traffic that the SOCKS proxy receives is sent
through the active VPN profile (route.final: `proxy-out`). This
file documents the two mechanisms the project ships to let you
exclude destinations from the SOCKS proxy without editing JSON
templates.

## 1. `route_set: private-domains` (DNS suffix based)

File: **`/etc/sing-box/private-domains.txt`** (mode 0640, owner root).
This is a plain-text list of domain suffixes, one per line. Lines
starting with `#` are comments, blank lines are ignored. Suffix
matching is applied, so `example.com` matches `foo.example.com`,
`bar.example.com`, etc.

The file is referenced by `sing-box-config.json` as a local
`rule_set` provider:

```json
{
  "type": "local",
  "tag": "private-domains",
  "format": "source",
  "path": "/etc/sing-box/private-domains.txt"
}
```

and applied via the route rule

```json
{"rule_set": "private-domains", "outbound": "direct"}
```

so any SOCKS-traffic to a matching suffix goes `direct` (bypassing
the VPN).

### Default contents (created by `install.sh` if missing)

```
.local
localhost
```

- `.local` covers mDNS / link-local hostnames (Apple Bonjour, Linux
  Avahi, Windows Workgroup naming).
- `localhost` covers the bare hostname; the `127.0.0.0/8` and
  `::1/128` ranges are handled separately by the IP-CIDR rule.

### Adding your own

```bash
sudo -e /etc/sing-box/private-domains.txt
# add suffixes like:
#   internal.corp
#   lab.local
#   nas.home
# then
sudo systemctl restart sing-box
```

The file is **not clobbered by re-running `install.sh`** — operator
edits survive updates. Only when the file is missing entirely is a
default copy installed from `etc-sing-box-private-domains.txt` in
the project.

### Verifying

```
sudo /usr/bin/sing-box check -c /etc/sing-box/config.json
# (should print nothing = config valid; private-domains.txt is loaded
# at config-load time)
```

If `sing-box` cannot read the file (permissions wrong, file missing,
malformed), it falls back to denying matches — i.e. those domains go
through the proxy-out fallback instead of `direct`. This is
fail-secure: missing file = no bypass, not accidental direct.

## 2. Hardcoded IP-CIDR bypasses (template)

These are **not** operator-editable, they're part of the sing-box
template. They cover the well-known private / link-local ranges that
should never go through the VPN:

| Range | Meaning |
|---|---|
| `127.0.0.0/8` | loopback (rejected at SOCKS layer, see below) |
| `::1/128` | IPv6 loopback |
| `0.0.0.0/8` (via `ip_is_private`) | "this network" / unspecified |
| `10.0.0.0/8` | RFC 1918 private |
| `172.16.0.0/12` | RFC 1918 private |
| `192.168.0.0/16` | RFC 1918 private |
| `169.254.0.0/16` (via `ip_is_private`) | link-local |
| `fc00::/7` | IPv6 ULA |
| `fe80::/10` | IPv6 link-local |
| `100.64.0.0/10` (via `ip_is_private`) | carrier-grade NAT |
| `2001:db8::/32` | documentation (TEST-NET-3) |

## 3. The loopback reject (special case)

KDE apps via `kioslaverc` system proxy sometimes try to reach the
clash API endpoint (`127.0.0.1:9090`) through the SOCKS proxy.
Forwarding this to the upstream and then to local clash API would
loop and produce a broken 502.

The template has a dedicated rule

```json
{
  "ip_cidr": ["127.0.0.0/8", "::1/128"],
  "action": "reject"
}
```

so the SOCKS layer returns `connection refused`. SOCKS clients then
fall back to direct (without SOCKS) for loopback targets, which
works as expected. The `private-domains.txt` file in #1 is
additive — it does not replace this reject; it just adds more
suffix matches.

## 4. Other bypass vectors (not configurable)

- DNS-over-TCP via port 53 is hijacked into the proxy (`hijack-dns`
  rule). DNS for direct-bound domains (`.ru`, suffix matches,
  private IPs) goes through `dns-direct` resolver, not
  `dns-remote`.
- `clash_api.experimental.external_controller` at `127.0.0.1:9090`
  is the **control plane**, not a proxy. It is reachable only via
  direct (see #3).
