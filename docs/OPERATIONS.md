# Operations

## Start / stop / status

```bash
sudo vpnon                    # start sing-box.service
sudo vpnoff                   # stop sing-box.service
vpnstatus                     # service + active profile + colo via SOCKS
vpntest                       # independent connectivity test
```

These are aliases — actual commands:

```bash
sudo systemctl start sing-box
sudo systemctl stop sing-box
sudo $PROJECT_DIR/vpn status
```

## Switch profile

```bash
vpnlist                       # see available
sudo vpnuse <name>            # switch active + regenerate config + restart
vpncurrent                    # show current
```

## Apply profile set

```bash
sudo ./apply-profiles.sh      # copy profiles/*.json -> /etc/sing-box/profiles/
                              # validate, test every one via SOCKS
                              # leave active profile at the last successful one
```

This is what you run after editing or adding a profile. It is safe to
re-run; idempotent on file content, only `sing-box check` runs may print
extra diagnostics.

## Test every profile

```bash
sudo ./test-all.sh
```

Loops over every profile in `profiles/`, switches each, runs SOCKS test
through `cloudflare.com/cdn-cgi/trace`, prints `ip=`, `colo=`, `loc=`.

## Add a profile

```bash
# from URL (vless, hy2, ss, vmess, trojan):
sudo vpnadd my-vps 'hy2://PASSWORD@host:8443/?sni=host.example&insecure=1#my-vps'

# from JSON file:
sudo ./vpn add-json my-vps ./my-vps.json

# by hand:
$EDITOR profiles/my-vps.json    # then apply
```

## Remove a profile

```bash
sudo vpndel my-vps              # deletes $PROJECT_DIR/profiles/my-vps.json
                                # AND /etc/sing-box/profiles/my-vps.json
```

Cannot delete the currently active profile — switch first with
`sudo vpnuse <other>`.

## Rolling back to defaults (escape hatch)

```bash
sudo $PROJECT_DIR/rollback.sh
```

Removes the sing-box runtime config and disables the systemd unit.
The host returns to a direct-internet state. **Reversible in
principle** — see `rollback.sh` itself for what files are touched.

## Logs

```bash
sudo journalctl -u sing-box -f             # follow
sudo journalctl -u sing-box -n 200         # last 200 lines
tail -f /var/log/sing-box.log              # if output path is set
```

## Regenerate config without restarting

`generate-config.sh` only rebuilds the JSON. Use `vpn restart` (alias
`vpnrestart`) to restart the service after generation.

```bash
sudo $PROJECT_DIR/generate-config.sh
sudo systemctl restart sing-box
```

## Known state (as of last commit on master)

Run `vpn list` on the host to see actual profile filenames and their
descriptions. The summary below describes a typical state where most
profiles are working and a couple are not.

| Type | Count | Status |
|---|---|---|
| Working | typical: 4–6 | ✅ |
| Server-side issue | 0–2 | ❌ needs VPS admin |
| Network setup needed | 0–1 | ❌ needs IPv6 on host |

The actual server endpoints, ports, and credentials live in
`profiles/<name>.json` (gitignored). Use `vpn list` to inspect them
locally; the public repo does not contain real endpoint metadata.

Non-working profiles are kept on disk for documentation but are
skipped by `failover.sh` until underlying issues are resolved.

## sing-box 1.12+ compatibility

Since the 2026-07-16 upgrade to `sing-box-bin 1.13.14`, the project
ships with `/etc/systemd/system/sing-box.service.d/deprecated-dns.conf`
which sets these env vars:

- `ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true`
- `ENABLE_DEPRECATED_LEGACY_INBOUND_FIELDS=true`
- `ENABLE_DEPRECATED_LEGACY_OUTBOUND_FIELDS=true`

These are temporary bypasses for legacy schema fields. When
`sing-box-bin` jumps to 1.14+, this drop-in must be replaced by a full
template migration to the new DNS server / outbound / inbound schema,
otherwise the service will refuse to start.
