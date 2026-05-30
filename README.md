# NanoMQ broker (standalone)

MQTT broker only, decoupled from **mqtt-publisher-lite**. Deploy this folder as **its own** Railway service (or any Docker host). Devices and the Node backend use the **same public broker URL** and **the same PKI Root CA**; each client (server + devices) uses its **own** client certificate signed by that CA.

## Layout

| File | Purpose |
|------|---------|
| `Dockerfile` | NanoMQ image; build context = **this directory** |
| `generate-broker-cert-openssl.sh` | Issue `certs/broker.{crt,key}` from shared Root CA (`BROKER_RAILWAY_PROXY_HOST`, `BROKER_SAN_DNS`, `BROKER_SAN_IPS`) |
| `print-railway-broker-env.sh` | Print raw PEM blocks for Railway `NANOMQ_TLS_*` variables |
| `nanomq.conf` | mTLS listener on **8883**, `verify_peer` + `fail_if_no_peer_cert` |
| `nanomq.plain.conf` | Plain MQTT **1883** (staging only) |
| `docker-entrypoint.sh` | Writes PEMs from `NANOMQ_TLS_*` or uses mounted `/etc/nanomq/certs/` |
| `railway.toml` / `railway.json` | Railway config-as-code |
| `env.railway.example` | Variable template |

## Railway

1. New service → same GitHub repo as the app.
2. **Settings → Root Directory:** `.` (repo root / `proof_broker` — folder containing this `Dockerfile`)
3. **Config-as-code:** use this folder’s `railway.toml` (default).
4. **Variables:** see `env.railway.example` (production: three `NANOMQ_TLS_*` PEMs; no `NANOMQ_DISABLE_TLS`).
5. **Networking → Public TCP Proxy:** map a public port to container **8883** (mTLS).

### PEMs in Railway (newlines)

- Prefer **Variables → Raw editor** (`</>`) and paste PEMs with **real line breaks** (`-----BEGIN` on its own line).
- If the UI stores PEMs as **one line** with literal `\n` sequences, `docker-entrypoint.sh` normalizes them with `sed 's/\\n/\n/g'` before NanoMQ reads the files.

### One-off PEM validation in logs

Set **`NANOMQ_DEBUG_CERTS=1`** on the broker service (then redeploy). On startup the entrypoint logs PEM SHA256 sums, **CA SHA1/SHA256 fingerprints**, SAN list, chain verify, and cert/key modulus match. Debug mode also sets **`NANOMQ_LOG_LEVEL=info`** so logs show `tls url: tls+nmq-tcp://0.0.0.0:8883`. Remove after debugging.

Set **`NANOMQ_EXPECTED_CA_FINGERPRINT`** to your Root CA SHA1 (e.g. `9B:12:06:56:04:B4:28:73:C3:CF:1B:36:42:07:9A:CD:53:33:2D:8F`) to get an explicit **MISMATCH** warning if Railway has the wrong `NANOMQ_TLS_CA_CERT`.

A **`Serving HTTP Server on http://(null):8081`** WARN is normal on NanoMQ 0.24 even when only TLS MQTT is used — look for **`tls url: tls+nmq-tcp://0.0.0.0:8883`** at info level instead.

**Update stale Railway PEMs** after regenerating certs locally:

```bash
./generate-broker-cert-openssl.sh
./print-railway-broker-env.sh   # paste all three blocks into Railway Raw editor
```

### Broker certificate SANs (Railway TCP proxy)

Clients validate the server cert against the **hostname they connect to**. If using Railway’s public TCP proxy (`*.proxy.rlwy.net`), that hostname must be in the broker cert SANs.

```bash
# Default includes yamabiko.proxy.rlwy.net; override if Railway assigns a new proxy host:
BROKER_RAILWAY_PROXY_HOST=your-host.proxy.rlwy.net ./generate-broker-cert-openssl.sh
./print-railway-broker-env.sh   # paste into Railway Variables → Raw editor
```

Regenerate and update **`NANOMQ_TLS_CERT`** + **`NANOMQ_TLS_KEY`** on Railway after any cert change. **`NANOMQ_TLS_CA_CERT`** stays the same unless you rotate the Root CA.

**Temporary workaround (no cert regen):** set `MQTT_TLS_SERVERNAME=PROOF-nanomq-broker` on clients — only helps when SNI is overridden; connecting to the proxy hostname still fails hostname verify without the SAN.

### External mTLS smoke test

```bash
openssl s_client -connect yamabiko.proxy.rlwy.net:43439 -servername yamabiko.proxy.rlwy.net \
  -CAfile ../statsmqtt/data/ca/root-ca.crt \
  -cert /path/to/client.crt -key /path/to/client.key
```

```bash
openssl s_client -connect broker.withproof.io:43439 -servername broker.withproof.io \
  -CAfile ../statsmqtt/data/ca/root-ca.crt \
  -cert /path/to/client.crt -key /path/to/client.key
```

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
