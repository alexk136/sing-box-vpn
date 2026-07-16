# IPv4 + IPv6

sing-box is dual-stack by default. The template (`sing-box-config.json`)
binds `mixed` inbound to `::` (IPv6-wildcard, accepts IPv4 too) and
the `direct` outbound handles both families transparently. The
generated config therefore already works for IPv4-only and IPv6-only
egress.

## DNS

`sing-box-config.json` ships with two `dns-remote` resolvers:

| Server | Address |
|---|---|
| `1.1.1.1` | `https://1.1.1.1/dns-query` (DoH over IPv4) |
| `[2606:4700:4700::1111]` | `https://[2606:4700:4700::1111]/dns-query` (DoH over IPv6) |

sing-box picks the resolver based on which interface can reach it, so
the same `dns-remote` tag works for IPv4-only and IPv6-only hosts.

## Routing

`route.rules` includes:

- `port: 53` → `hijack-dns` (force TCP DNS to sing-box, prevents DNS leaks)
- `domain_suffix: .ru` → `direct` (no proxy for `.ru`)
- `ip_is_private: true` → `direct`
- `ip6_is_private: true` → `direct` — covers `fc00::/7`, `fe80::/10`,
  `::1/128`, `64:ff9b::/96`, etc. (LAN-only traffic exits directly)

Egress `final` is `proxy-out`, so public traffic goes via the active
profile outbound, regardless of family.

## Host check (example)

| Check | Result | Notes |
|---|---|---|
| IPv4 default route | up | wifi `wlp14s0f3u2` |
| IPv6 default route | **down** at the time of this redesign | `enp7s0` DOWN; `wlp*` interfaces have no `inet6` route to upstream |
| `ping 2a03:f480:1:c::1b` | `Network is unreachable` | expected given the missing default route |
| `tcp46` to a profile server | works (default-route over IPv4) | normal traffic |
| `tcp6` to `[2a03:f480:1:c::1b]` | only works **through VPN** (tun0), not directly | see below |

If the host has IPv6 to upstream, no config change is needed — sing-box
will use it automatically. If not, traffic falls back to IPv4 and that
is fine for the design.

## When you want to test IPv6 properly

```bash
# confirm the host has an inet6 default route
ip -6 route show default
# expect: default via fe80::... dev wlp14s0f3u2 metric 601

# then sing-box will pick IPv6 for outbound by default
sudo /usr/local/bin/sing-box check -c /etc/sing-box/config.json
```

If the route is missing, the easiest fix is to enable IPv6 on the wifi
connection (`nmcli connection modify "Grandma net" ipv6.method auto`).
This is **out of scope** of the sing-box redesign — it is a NetworkManager
issue.

## Outbound IPv6-only servers

For VPSes reachable only over IPv6, use bracketed form:

```json
{
  "type": "hysteria2",
  "server": "[2a03:f480:1:c::1b]",
  "server_port": 8443,
  "password": "...",
  "tls": { "enabled": true, "server_name": "vps.example.com", "insecure": true }
}
```

`sing-box` parses the bracket form natively. The `[hostname]`
notation only applies to JSON; `vpn add` will convert URLs in that
form automatically.
