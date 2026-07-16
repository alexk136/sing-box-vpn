# Failover

Optional: rotate to the next working profile when the active one stops
responding. Triggered by `contrib/systemd/vpn-failover.timer` (system-level)
or `contrib/systemd/vpn-failover-user.timer` (user-level).

## What it does

Every 5 minutes (configurable), `failover.sh`:

1. Probes the current active profile via SOCKS at
   `127.0.0.1:12334` → `https://cloudflare.com/cdn-cgi/trace`
2. If the probe returns a `colo=`/`ip=`/`loc=` line, exits `0` (healthy).
3. If the probe times out or returns no trace line, lists every
   profile from `./vpn list`, and tries each one with
   `sudo ./vpn use <name>` followed by another probe.
4. The first profile that responds becomes the new active profile.
   Original profile is left intact for manual inspection.
5. If every candidate fails, exits `1` and emits
   `ALL profiles failed`.

Every event goes to systemd journal (`journalctl -t vpn-failover -n 50`)
and to stderr.

## Install (system-wide, requires root)

```bash
sudo cp contrib/systemd/vpn-failover.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vpn-failover.timer
systemctl list-timers vpn-failover.timer
journalctl -u vpn-failover -n 20 --no-pager   # observe
```

## Install (per-user, no sudo)

```bash
mkdir -p ~/.config/systemd/user
cp contrib/systemd/vpn-failover-user.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now vpn-failover-user.timer
systemctl --user list-timers vpn-failover-user.timer
journalctl --user -u vpn-failover-user -n 20 --no-pager
```

Note: per-user units run as your user — `failover.sh` still uses
`sudo` to flip profiles, so NOPASSWD for `/home/alex/sing-box-vpn/vpn`
must be configured in sudoers, otherwise each rotate prompts for a
password.

## Environment variables

| Var | Default | Meaning |
|---|---|---|
| `PROJECT_DIR` | auto (failover.sh directory) | source repo |
| `VPN` | `$PROJECT_DIR/vpn` | path to `vpn` |
| `TRACE_HOST` | `https://cloudflare.com/cdn-cgi/trace` | probe URL |
| `PROBE_TIMEOUT` | `8` | seconds for the SOCKS probe |
| `MIXED_PORT` | `12334` | SOCKS port |
| `DRY_RUN` | `0` | `1` to probe without rotating |
| `LOG_TAG` | `[vpn-failover]` | log prefix |

Override per-environment via `EnvironmentFile`:

- system-wide: `/etc/default/vpn-failover`
- per-user: `~/.config/vpn-failover.env`

Format (`KEY=VALUE` per line, comments with `#`).

## Manual / one-shot use

```bash
# probe-and-rotate now
sudo ./failover.sh

# probe-only (do not rotate) for diagnostics
DRY_RUN=1 ./failover.sh

# detect: every rotate from journal
journalctl -t vpn-failover --since '6 hours ago'
```

Exit codes:

| Code | Meaning |
|---|---|
| `0` | OK; either current is healthy or rotation succeeded |
| `1` | every profile failed |
| `2` | configuration error (missing `vpn`, no sudo) |

## Tuning

- Faster checks: `OnUnitActiveSec=1min` (more journal noise)
- Slower checks: `OnUnitActiveSec=15min` (less load)
- Local probe host: `TRACE_HOST=https://example.net/diagnostics` in
  `/etc/default/vpn-failover`
