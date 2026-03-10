# wg2vless

Docker bridge that accepts WireGuard connections and forwards traffic through a VLESS proxy. Connect any WireGuard client to route traffic via your Xray server. Ideal for routers that only support WireGuard.

## Features

- Standard WireGuard protocol on client side
- VLESS outbound with REALITY or TLS
- Auto-generates WireGuard keypairs
- Config via URL or individual variables
- Multi-arch support (amd64, arm64, armv7)

## Configuration

Pass VLESS URL via environment variable or use individual variables (see below):

```bash
VLESS_URL="vless://uuid@host:443?type=tcp&security=reality&pbk=...&sni=example.com&sid=abc&fp=chrome&flow=xtls-rprx-vision"
```

## Usage

```bash
docker run -d \
  -p 51820:51820/udp \
  -v ./data:/data \
  -e VLESS_URL="vless://..." \
  -e WG_ENDPOINT="your-server-ip" \
  spinogrizz/wg2vless:latest
```

Or with docker-compose — edit `docker-compose.yml` and run:

```bash
docker-compose up -d
```

Client config is generated at `./data/client.conf` — import it into any WireGuard app.

## Environment

#### VLESS

| Variable | Example | Description |
|----------|---------|-------------|
| `VLESS_URL` | `vless://uuid@host:443?...` | Full URL (alternative to individual vars) |
| `VLESS_HOST` | `1.2.3.4` | Server address |
| `VLESS_PORT` | `443` | Server port |
| `VLESS_UUID` | `a1b2c3d4-...` | Client UUID |
| `VLESS_SECURITY` | `reality` | `reality`, `tls`, or `none` |
| `VLESS_SNI` | `yahoo.com` | Server name for TLS/REALITY |
| `VLESS_PBK` | `abc123...` | REALITY public key |
| `VLESS_SID` | `aabbcc` | REALITY short ID |
| `VLESS_FP` | `chrome` | Browser fingerprint |
| `VLESS_FLOW` | `xtls-rprx-vision` | Flow control |
| `VLESS_TRANSPORT` | `tcp` | Transport type |

#### WireGuard

| Variable | Example | Description |
|----------|---------|-------------|
| `WG_PORT` | `51820` | Listen port |
| `WG_ENDPOINT` | `vpn.example.com` | Server address for client config |
| `WG_SERVER_IP` | `10.66.66.1` | Server tunnel IP |
| `WG_CLIENT_IP` | `10.66.66.2` | Client tunnel IP |
| `WG_MTU` | `1420` | MTU size |
| `WG_DNS` | `1.1.1.1,8.8.8.8` | DNS servers |
| `WG_ALLOWED_IPS` | `0.0.0.0/0,::/0` | Client routing |

#### Other

| Variable | Example | Description |
|----------|---------|-------------|
| `XRAY_LOGLEVEL` | `warning` | `debug`, `info`, `warning`, `error` |
| `DATA_DIR` | `/data` | Keys storage path |


## License

MIT