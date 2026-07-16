# Profile schema

Each file in `profiles/` is one sing-box outbound in JSON. Name MUST
equal the filename stem: `profiles/my-vps.json` has `"name": "my-vps"`.

## Minimum required fields

```json
{
  "type": "<sing-box outbound type>",
  "server": "<host or IP>",
  "server_port": <int>,
  "name": "<must match filename without .json>",
  "description": "<human-readable, optional>"
}
```

The rest is protocol-specific. See `sing-box` docs at
<https://sing-box.sagernet.org/configuration/outbound/> for the full
schema per type.

## Supported types in `vpn add`

`vpn add <name> <url>` understands these URL schemes:

| Scheme | Parses to | Example |
|---|---|---|
| `vless://` | VLESS (xudp) | `vless://UUID@host:443?security=reality&sni=yahoo.com&pbk=...&sid=...&fp=chrome#client1` |
| `hy2://` / `hysteria2://` | Hysteria2 | `hy2://PASSWORD@host:8443/?sni=host.example&insecure=1#my-vps` |
| `ss://` | Shadowsocks (2022 + legacy) | `ss://BASE64(method:password)@host:8388#name` |
| `vmess://` | VMess (v2rayN-style base64 JSON) | `vmess://BASE64JSON#name` |
| `trojan://` | Trojan | `trojan://PASSWORD@host:443?sni=host.example#name` |

For protocols not in the list, or for full control over the outbound
JSON, use `vpn add-json <name> <file.json>` or write the JSON
directly to `profiles/<name>.json`.

## Existing files in `profiles/`

The real profiles on this host are gitignored. Run `./vpn list` from the
project root to see the actual filenames and their descriptions. Each
existing file in this directory is one of the supported protocols
(`vless`, `hysteria2`, `shadowsocks`, `vmess`, `trojan`); see
`docs/examples/<protocol>.json` for canonical templates.

## IPv6 servers

`sing-box` resolves `server` as a hostname. To force a specific family,
use the literal IPv6 form (note the brackets where applicable):

```json
{
  "type": "hysteria2",
  "server": "[2a03:f480:1:c::1b]",
  "server_port": 8443,
  ...
}
```

The brackets are NOT part of the address — they are removed when used
in the JSON value. (sing-box parses the literal form natively, no shell
quirks involved.)

## Validation

`sing-box check -c /etc/sing-box/config.json` is the source-of-truth
validator. `apply-profiles.sh` runs it on every profile before testing.
If you write a profile by hand, sanity-check with:

```bash
# activate the new profile in runtime to validate it
echo my-vps | sudo tee /etc/sing-box/active_profile
sudo $PROJECT_DIR/generate-config.sh
sudo /usr/local/bin/sing-box check -c /etc/sing-box/config.json
```

## Adding a profile from a share link

```bash
sudo ./vpn add client42 'vless://<uuid>@<host>:443?security=reality&sni=yahoo.com&pbk=<pbk>&sid=<sid>&fp=chrome#client42'
sudo ./apply-profiles.sh
sudo ./vpn use client42
```

## Templates

`docs/examples/` ships git-tracked templates for every supported
protocol. They contain placeholder values and will NOT work as live
profiles. To use one:

```bash
cp docs/examples/hysteria2.json profiles/my-vps.json
$EDITOR profiles/my-vps.json      # fill in real values
sudo ./apply-profiles.sh
sudo ./vpn use my-vps
```

Templates available:

| File | Use as starting point for |
|---|---|
| `docs/examples/hysteria2.json` | Hysteria2 (UDP, QUIC-based, anti-DPI) |
| `docs/examples/vless.json` | VLESS+Reality (TCP, anti-DPI) |
| `docs/examples/shadowsocks.json` | Shadowsocks (TCP/UDP, classic) |
| `docs/examples/vmess.json` | VMess (older, AEAD-only) |
| `docs/examples/trojan.json` | Trojan (TLS-wrapped) |

The entire `profiles/` directory is gitignored (`.gitignore`: `profiles/`
and `profiles/**`) — real profiles never appear in any commit.

## Workflow

| Step | Command | Writes |
|---|---|---|
| Add profile | `sudo ./vpn add <name> <url>` | `profiles/<name>.json` |
| Validate+cet | `sudo ./apply-profiles.sh` | `/etc/sing-box/profiles/<name>.json`, validates, tests |
| Activate | `sudo ./vpn use <name>` | `/etc/sing-box/active_profile`, regenerates `config.json`, restarts sing-box |
| Remove | `sudo ./vpn del <name>` | removes from both source and runtime |

Drop a new profile into `profiles/` — **everything is auto-discovered**
by `apply-profiles.sh`, `vpn list`, and `test-all.sh`. No edit to
any script needed.
