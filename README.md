# sing-box VPN

Client-side sing-box VPN profile manager. Auto-discovers `*.json` files
in `profiles/`, parses common share-link formats, and renders them as
sing-box outbounds. No code edits needed when adding or removing a
profile.

## Quick start

```bash
sudo vpn add my-vps 'hy2://PASSWORD@vpn.example:8443/?sni=vpn.example&insecure=1#my-vps'
sudo ./vpn list
sudo ./apply-profiles.sh
sudo ./vpn use my-vps
vpn test
```

## Optional: auto-failover

`failover.sh` + `contrib/systemd/vpn-failover.timer` probe the active
profile every 5 minutes; if SOCKS stops responding, the timer rotates
to the first working profile. Install:

```bash
sudo cp contrib/systemd/vpn-failover.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vpn-failover.timer
```

See [docs/FAILOVER.md](docs/FAILOVER.md) for the user-level unit,
environment overrides, and exit-code reference.

## TL;DR

| Action | Command |
|---|---|
| List profiles | `vpn list` |
| Show current | `vpn current` |
| Switch | `sudo vpn use <name>` |
| Add a profile from URL | `sudo vpn add <name> '<vless\|hy2\|ss\|vmess\|trojan://...>'` |
| Add a profile from JSON file | `sudo vpn add-json <name> <file.json>` |
| Apply all profiles from `profiles/*.json` to runtime | `sudo ./apply-profiles.sh` |
| Test every profile | `sudo ./test-all.sh` |
| Start VPN | `sudo vpn on` |
| Stop VPN | `sudo vpn off` |
| Status | `vpn status` |

A profile **auto-discovers** from `profiles/*.json` — drop a new
`<name>.json` in there and it is picked up by `apply-profiles.sh`,
`test-all.sh`, and `vpn list` with no further edits.

See [ARCHITECTURE.md](ARCHITECTURE.md) for how everything fits together
and [docs/PROFILES.md](docs/PROFILES.md) for the profile schema.

## Supported platforms

| Layer | Tested on | Notes |
|---|---|---|
| VPN **client** (this project) | Linux + systemd 245+ + POSIX shell | Tested on Arch-based and Debian; should run on any distribution with Python 3 |
| Server-side VPN | Linux + hysteria2 / xray-server binary | any distro the upstream supports |
| GUI clients | Nekoray, sing-box official, v2rayTun mobile, Shadowrocket/Stash mobile | TPROXY mode is off; SOCKS or per-app proxy |

Notes:

- `vpn` is bash + Python 3 (`#!` shebang, embedded Python heredoc).
- TPROXY is **off** by default (transparent redirect paths are not
  shipped in this project). The default mode is SOCKS-only.
- Mobile clients connect to SOCKS `127.0.0.1:12334` over SSH tunnel
  or per-device WireGuard; some clients can import `hysteria2://` /
  `vless://` share links directly.

## Requirements

### Hard (must be present)

| Dependency | Min version | Why |
|---|---|---|
| Linux kernel | 4.18+ | full feature support |
| `systemd` | 245+ | unit management |
| `sing-box` (binary) | 1.11.0 | client and runtime. v1.13 has breaking DNS API |
| `python3` | 3.8+ | URL parser in `vpn` |
| `curl` | any | connectivity tests |
| `bash` | 4.0+ | shell aliases (optional) |
| `sudo` | any | mutating commands (`on/off/use/add/add-json/del`, `apply-profiles.sh`, `install.sh`) |

### Soft (nice to have)

| Tool | Why |
|---|---|
| `inotify-tools` (`inotifywait`) | future hot-reload watcher |
| `pass` + GPG | for credentials outside the repo |
| KDE proxy settings tooling | automatic per-app SOCKS proxy for KDE apps |

### Network egress

The host needs either:

- IPv4 default route — typical for LAN/wired
- or IPv6 default route — for IPv6-only profiles to reach the server

Servers themselves do not need IPv6 unless a profile points at them.
Dual-stack inside sing-box covers both.

## What this is **not**

- Not a server-side installer. The server-side runbook lives
  separately (typically under a host-wide `docs/` directory).
- Not a tunnel-over-SSH. TPROXY is disabled.
- Not a full VPN client with a tap device. Use sing-box official
  client (CLI or GUI) for that — `vpn` here just manages profiles.
- Not anonymous by itself. DNS leak protection depends on every
  client-app honouring the SOCKS proxy. Verify per-app.

## Configuration reference

All scripts in this repo accept these environment overrides; default
values are shown.

| Variable | Default | Used by |
|---|---|---|
| `PROJECT_DIR` | auto (script's directory) | all 6 shell scripts |
| `RUNTIME_DIR` | `/etc/sing-box` | runtime config root |
| `RUNTIME_PROFILES_DIR` | `$RUNTIME_DIR/profiles` | runtime profile set |
| `ACTIVE_FILE` | `$RUNTIME_DIR/active_profile` | active profile marker |
| `CONFIG_TEMPLATE` | `$PROJECT_DIR/sing-box-config.json` | template read by `generate-config.sh` |
| `CONFIG_OUT` | `$RUNTIME_DIR/config.json` | rendered config |
| `SERVICE_NAME` | `sing-box` | systemd unit |
| `MIXED_PORT` | `12334` | SOCKS inbound |
| `SING_BOX` (or `SING_BOX_BIN`) | `/usr/local/bin/sing-box` | binary path |

To install into a non-default layout:

```bash
sudo RUNTIME_DIR=/opt/sing-box \
     SERVICE_NAME=sing-box-custom \
     SING_BOX_BIN=/usr/bin/sing-box \
     ./install.sh
```
