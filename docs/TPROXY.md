# TPROXY (transparent proxy) for sing-box-vpn

By default, `sing-box-vpn` runs as a **SOCKS/HTTP proxy** on
`127.0.0.1:12334`. Apps that respect `http_proxy`/`all_proxy` or have
explicit SOCKS configuration get tunneled; everything else goes direct.

`contrib/tproxy/` adds an optional **system-wide transparent
interception** layer using nftables TPROXY + policy routing. With it
enabled, every TCP/UDP packet from user processes is redirected through
sing-box automatically — no per-app config needed.

## When to use it

Use TPROXY when you want:

- All browser tabs / system apps tunneled without configuring each one
- DNS queries (port 53 to non-LAN) intercepted by sing-box's DoH
- A "VPN-like" experience where the whole user session is inside the tunnel

Do **not** use TPROXY if:

- You only need specific apps to go through the tunnel (use SOCKS instead)
- The host runs services (containers, daemons) that must NOT be intercepted
- You're on a multi-user host — TPROXY affects ALL user traffic

## What gets installed

| File | Purpose |
|---|---|
| `/etc/nftables.d/sing-box.nft` | TPROXY ruleset: chain prerouting + chain output |
| `/etc/systemd/system/sing-box-tproxy-routing.service` | loads nft + sets ip rule + table 200 route |
| `/usr/local/libexec/sing-box-vpn/sing-box-tproxy-watchdog.sh` | verifies VPN + auto-fixes table 200 |
| `/etc/systemd/system/sing-box-watchdog.{service,timer}` | runs watchdog every 1 minute |
| `/etc/NetworkManager/dispatcher.d/30-sing-box-tproxy` | re-applies route on WiFi/Ethernet up events |

## Install

```bash
sudo contrib/tproxy/install-tproxy.sh
```

Idempotent. Re-run any time.

## Uninstall

```bash
sudo contrib/tproxy/uninstall-tproxy.sh
```

## Verify

```bash
curl https://api.ipify.org
```

Should return the VPN egress IP, NOT your real IP.

```bash
systemctl status sing-box-tproxy-routing sing-box-watchdog.timer
ip rule show | grep fwmark
ip route show table 200
sudo nft list table inet sing-box | head -20
```

## Implementation notes

### Why table 200 (and not 100)?

NetworkManager on this system uses `table 100` for its own rules (see
`/etc/NetworkManager/dispatcher.d/99-ecmp-wifi.sh`). NM flushes that
table on every WiFi `up` event, which would wipe our route within ~1
second of reconnect. `table 200` is unused by NM and stays put.

### Why `meta skuid root return` in chain output?

The kernel needs `IP_TRANSPARENT` for the TPROXY socket to receive
packets destined for non-local addresses. sing-box sets this via
`CAP_NET_ADMIN`. To prevent sing-box's own outbound traffic (DNS
queries, Hysteria2 tunnel handshake) from being re-TPROXY'd and
creating an infinite loop, we exclude UID 0 (root) traffic in the
output chain. This means **root processes bypass the VPN** — by
design. The watchdog's external-IP probe explicitly runs as the
unprivileged user `alex` so the probe still sees the VPN egress.

### Why the NM dispatcher?

Even though table 200 isn't managed by NM, the rest of the network
stack can shift on WiFi/Ethernet events. The dispatcher re-applies the
route and `fwmark` rule immediately on `up`/`dhcp4-change`, reducing
the recovery window from "next watchdog tick" (~1 min) to "next NM
event" (~seconds).

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| VPN tunnel up but app traffic goes direct | watchdog not running: `systemctl status sing-box-watchdog.timer` |
| VPN works for ~30 s after WiFi reconnect, then dies | NM dispatcher missing: re-run `install-tproxy.sh` |
| External IP is always real IP even though tunnel works | rule 50 missing: `ip rule add fwmark 0x1 lookup 200 priority 50` |
| Sing-box logs show zero tproxy connections | nft table not loaded: `nft list table inet sing-box` |
| `nft -c -f /etc/nftables.d/sing-box.nft` errors | rare — usually a copy-paste mistake; reinstall from repo |

Full rollback:

```bash
sudo contrib/tproxy/uninstall-tproxy.sh
# SOCKS-only mode is preserved; basic sing-box service keeps running
```