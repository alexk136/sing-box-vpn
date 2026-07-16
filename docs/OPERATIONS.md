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
