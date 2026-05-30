# Caddy L4 TCP proxy

Raw TCP passthrough from `broker.withproof.io:8883` to the private NanoMQ broker. Caddy does **not** terminate TLS; mTLS is handled entirely by NanoMQ.

## Layout

| File | Purpose |
|------|---------|
| `Dockerfile` | Custom Caddy with [caddy-l4](https://github.com/mholt/caddy-l4) |
| `Caddyfile` | Listen `:8883`, forward to broker private host |
| `railway.toml` | Railway config-as-code |
| `env.railway.example` | Variable template |

## Railway deploy

1. **Privatize broker** (`adequate-appreciation`): Networking → remove TCP Proxy and any `broker.withproof.io` domain on the broker service.
2. **New service** → same GitHub repo → **Root Directory:** `caddy-proxy`.
3. **Variables** (see `env.railway.example`):

   | Variable | Value |
   |----------|-------|
   | `PORT` | `8883` |
   | `BROKER_INTERNAL_HOST` | `${{adequate-appreciation.RAILWAY_PRIVATE_DOMAIN}}` |
   | `BROKER_INTERNAL_PORT` | `8883` |

4. **Networking → Custom Domains:** add `broker.withproof.io`, specify custom port **8883**.

## DNS

- CNAME (or ALIAS/ANAME at apex) `broker.withproof.io` → this service’s Railway domain (e.g. `caddy-proxy.up.railway.app`).
- **DNS only** — disable Cloudflare orange-cloud if applicable.
- Do **not** use a static A record; Railway has no stable edge IP for custom domains.

## Log level

`Caddyfile` defaults to `DEBUG` for initial bring-up. After validation, change `level DEBUG` to `INFO` or `WARN` and redeploy.

## Local build and validate

Uses `caddy:builder` (not `2.8-builder`) because caddy-l4 v0.1.1 requires Go 1.25+.

```bash
docker build -t proof-caddy-proxy ./caddy-proxy

docker run --rm \
  -v "$(pwd)/caddy-proxy/Caddyfile:/etc/caddy/Caddyfile" \
  -e BROKER_INTERNAL_HOST=adequate-appreciation.railway.internal \
  -e BROKER_INTERNAL_PORT=8883 \
  proof-caddy-proxy caddy validate --config /etc/caddy/Caddyfile
```

## Smoke test (after DNS propagates)

```bash
openssl s_client -connect broker.withproof.io:8883 -servername broker.withproof.io \
  -CAfile ../statsmqtt/data/ca/root-ca.crt \
  -cert /path/to/client.crt -key /path/to/client.key
```

## Troubleshooting

| Symptom | Check |
|---------|--------|
| Connection timeout | DNS CNAME, Cloudflare proxy off, `PORT=8883`, broker listening on `0.0.0.0:8883` |
| Caddy crash loop | Deploy logs; run `caddy validate` with custom image |
| Upstream dial failures | `BROKER_INTERNAL_HOST` resolves to broker private domain |
| Cert hostname mismatch | Broker cert must include `broker.withproof.io` SAN — see root `generate-broker-cert-openssl.sh` |
