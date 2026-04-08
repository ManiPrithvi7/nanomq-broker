# NanoMQ broker (standalone)

MQTT broker only, decoupled from **mqtt-publisher-lite**. Deploy this folder as **its own** Railway service (or any Docker host). Devices and the Node backend use the **same public broker URL** and **the same PKI Root CA**; each client (server + devices) uses its **own** client certificate signed by that CA.

## Layout

| File | Purpose |
|------|---------|
| `Dockerfile` | NanoMQ image; build context = **this directory** |
| `generate-broker-cert-openssl.sh` | Issue `certs/broker.{crt,key}` from shared Root CA (optional `BROKER_SAN_IPS`) |
| `nanomq.conf` | mTLS listener on **8883**, `verify_peer` + `fail_if_no_peer_cert` |
| `nanomq.plain.conf` | Plain MQTT **1883** (staging only) |
| `docker-entrypoint.sh` | Writes PEMs from `NANOMQ_TLS_*` or uses mounted `/etc/nanomq/certs/` |
| `railway.toml` / `railway.json` | Railway config-as-code |
| `env.railway.example` | Variable template |

## Railway

1. New service → same GitHub repo as the app.
2. **Settings → Root Directory:** `nanomq-broker`
3. **Config-as-code:** use this folder’s `railway.toml` (default).
4. **Variables:** see `env.railway.example` (production: three `NANOMQ_TLS_*` PEMs; no `NANOMQ_DISABLE_TLS`).
5. **Networking → Public TCP Proxy:** map a public port to container **8883** (mTLS).

### PEMs in Railway (newlines)

- Prefer **Variables → Raw editor** (`</>`) and paste PEMs with **real line breaks** (`-----BEGIN` on its own line).
- If the UI stores PEMs as **one line** with literal `\n` sequences, `docker-entrypoint.sh` normalizes them with `sed 's/\\n/\n/g'` before NanoMQ reads the files.

### One-off PEM validation in logs

Set **`NANOMQ_DEBUG_CERTS=1`** on the broker service (then redeploy). On startup, if `openssl` is available in the image, the entrypoint logs CA/broker cert subjects and checks the broker private key. Remove or unset after debugging.

## mqtt-publisher-lite (separate service)

Point the app at the **public TCP host and port** Railway shows for the broker (not the internal hostname, unless you only use private networking).

Set (names match mqtt-publisher-lite `src/config/index.ts`):

- `MQTT_BROKER` — hostname only (no `mqtts://` prefix in env; TLS is toggled separately)
- `MQTT_PORT` — external TCP port mapped to **8883**
- `MQTT_TLS_ENABLED=true` (or `MQTT_TLS=true`)
- `MQTT_TLS_CA_BASE64` / `MQTT_TLS_CLIENT_CERT_BASE64` / `MQTT_TLS_CLIENT_KEY_BASE64` — PEM material (same Root CA as broker/devices)
- `MQTT_TLS_SERVERNAME` or `MQTT_TLS_VERIFY_HOST` — if the TCP hostname does not match the CN/SAN on `broker.crt` (e.g. `PROOF-nanomq-broker`)

Issue a **dedicated** server client cert (do not reuse a device identity).

## Local build

```bash
cd nanomq-broker
docker build -t proof-nanomq .
```

## Legacy `broker/` in monorepo

The older `broker/` path (repo-root Docker context) remains for local smoke tests and docs; **new Railway broker deploys should use this `nanomq-broker/` project.**
