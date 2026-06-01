# NanoMQ broker (standalone)

MQTT broker only, decoupled from **mqtt-publisher-lite**. Deploy this folder as **its own** Railway service (or any Docker host). Devices and the Node backend use the **same public broker URL** and **the same PKI Root CA**; each client (server + devices) uses its **own** client certificate signed by that CA.

## Layout

| File | Purpose |
|------|---------|
| `Dockerfile` | NanoMQ image; build context = **this directory** |
| `caddy-proxy/` | Caddy L4 TCP passthrough — public edge for `broker.withproof.io:8883` |
| `generate-broker-cert-openssl.sh` | Issue `certs/broker.{crt,key}` from shared Root CA (`BROKER_SAN_DNS`, optional legacy `BROKER_RAILWAY_PROXY_HOST`) |
| `print-railway-broker-env.sh` | Print raw PEM blocks for Railway `NANOMQ_TLS_*` variables |
| `nanomq.conf` | mTLS listener on **8883**, `verify_peer` + `fail_if_no_peer_cert` |
| `nanomq.plain.conf` | Plain MQTT **1883** (staging only) |
| `docker-entrypoint.sh` | Writes PEMs from `NANOMQ_TLS_*` or uses mounted `/etc/nanomq/certs/` |
| `railway.toml` / `railway.json` | Railway config-as-code |
| `env.railway.example` | Variable template |
| `docker-compose.yml` | Local stack: broker + Caddy on host `:8883` |
| `.env.compose.example` | Optional compose overrides (Root CA path, debug) |

## Migrate from Railway Compose (one service) to two services

If you currently run **both** NanoMQ and Caddy via [`docker-compose.yml`](docker-compose.yml) in a **single** Railway service, migrate as follows. Do **not** convert the bundled Compose service in place — create **new** services.

| Phase | Action |
|-------|--------|
| **0** | Push repo with production mTLS (`verify_peer = true` in [`nanomq.conf`](nanomq.conf)). |
| **1** | **New broker service** (e.g. `nanomq-broker-private`): Root Directory `.`, Dockerfile deploy, copy `NANOMQ_TLS_*` from old Compose service, **no** public TCP proxy or custom domain. Verify logs: `tls url: tls+nmq-tcp://0.0.0.0:8883`. |
| **2** | **New Caddy service** (`caddy-proxy`): Root Directory `caddy-proxy`, vars from [`caddy-proxy/env.railway.example`](caddy-proxy/env.railway.example), custom domain `broker.withproof.io:8883`. |
| **3** | On **old Compose service**, remove custom domain and TCP proxy (avoid split-brain). CNAME `broker.withproof.io` → Caddy Railway domain. Run smoke test below. |
| **4** | **Delete** old Compose service after tests pass. |
| **5** | Set Caddy `DEBUG` → `INFO` in [`caddy-proxy/Caddyfile`](caddy-proxy/Caddyfile), redeploy. Update mqtt-publisher-lite and devices. |

Keep the old Compose service running (without public domain) until Phase 4 for rollback.

## Architecture (production)

Public clients connect to **`broker.withproof.io:8883`**. A separate **Caddy L4 proxy** service forwards raw TCP over Railway private networking to the private broker. Caddy does **not** terminate TLS; NanoMQ handles mTLS end-to-end.

```
Client → broker.withproof.io:8883 → caddy-proxy → nanomq-broker-private.railway.internal:8883 → NanoMQ
```

See [`caddy-proxy/README.md`](caddy-proxy/README.md) for Caddy deploy steps.

## Railway — broker service (e.g. `nanomq-broker-private`)

1. **New service** → same GitHub repo (do not reuse the bundled Compose service).
2. **Settings → Root Directory:** `.` (repo root — folder containing this `Dockerfile`)
3. **Settings → Deploy:** **Dockerfile** only — **not** Compose.
4. **Config-as-code:** use this folder’s `railway.toml` (default).
5. **Variables:** see `env.railway.example` (production: three `NANOMQ_TLS_*` PEMs; no `NANOMQ_DISABLE_TLS`).
6. **Networking:** **no public TCP proxy** and **no custom domain** — private network only. Public access is via `caddy-proxy`.

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

### Broker certificate SANs

Clients validate the server cert against the **hostname they connect to**. Production clients use **`broker.withproof.io`** (included by default in `./generate-broker-cert-openssl.sh`).

```bash
./generate-broker-cert-openssl.sh
./print-railway-broker-env.sh   # paste into Railway Variables → Raw editor
```

Optional legacy SAN for old Railway TCP proxy hostnames:

```bash
BROKER_RAILWAY_PROXY_HOST=yamabiko.proxy.rlwy.net ./generate-broker-cert-openssl.sh
```

Regenerate and update **`NANOMQ_TLS_CERT`** + **`NANOMQ_TLS_KEY`** on Railway after any cert change. **`NANOMQ_TLS_CA_CERT`** stays the same unless you rotate the Root CA.

### External mTLS smoke test

After Caddy proxy and DNS are configured (all clients must present valid client certs — `verify_peer = true` in [`nanomq.conf`](nanomq.conf)):

```bash
openssl s_client -connect broker.withproof.io:8883 -servername broker.withproof.io \
  -CAfile ../statsmqtt/data/ca/root-ca.crt \
  -cert /path/to/client.crt -key /path/to/client.key
```

Connection **without** `-cert` / `-key` should fail (mTLS enforced).

## mqtt-publisher-lite (separate service)

Point the app at the public Caddy endpoint (not the broker internal hostname):

Set (names match `src/config/index.ts`):

- `MQTT_BROKER=broker.withproof.io` — hostname only (no `mqtts://` prefix in env; TLS is toggled separately)
- `MQTT_PORT=8883` — external TCP port mapped to **8883**
- `MQTT_TLS_ENABLED=true` (or `MQTT_TLS=true`)
- `MQTT_TLS_CA_PATH` — trust store for broker + chain (same Root CA)
- `MQTT_TLS_CLIENT_CERT_PATH` / `MQTT_TLS_CLIENT_KEY_PATH` — **backend’s** MQTT client cert/key (issued by same CA as devices)
- `MQTT_TLS_SERVERNAME` — if the TCP hostname does not match the CN/SAN on `broker.crt`

Issue a **dedicated** server client cert (do not reuse a device identity).

## Local build

```bash
docker build -t proof-nanomq .
docker build -t proof-caddy-proxy ./caddy-proxy
```

### Local stack (docker compose)

Run broker + Caddy together on a shared Docker network. Only **Caddy** binds host port **8883**; the broker is reachable as `nanomq-broker` inside the compose network.

**Prerequisites (fresh clone):** Compose volume mounts expect these host paths to exist before `docker compose up`:

- `./certs/broker.crt` and `./certs/broker.key` — run `./generate-broker-cert-openssl.sh` from the repo root (requires Root CA at `../statsmqtt/data/ca/root-ca.{crt,key}` by default).
- Root CA for the broker container — default mount is `../statsmqtt/data/ca/root-ca.crt`. Override in `.env` with `ROOT_CA_CRT`, or copy the CA into the repo, e.g. `cp ../statsmqtt/data/ca/root-ca.crt ./certs/root-ca.crt` and set `ROOT_CA_CRT=./certs/root-ca.crt`.

```bash
./generate-broker-cert-openssl.sh          # creates ./certs/broker.{crt,key}
cp .env.compose.example .env               # optional; set ROOT_CA_CRT if CA path differs
docker compose up --build
```

Test through the proxy:

```bash
openssl s_client -connect localhost:8883 -servername broker.withproof.io \
  -CAfile ../statsmqtt/data/ca/root-ca.crt \
  -cert /path/to/client.crt -key /path/to/client.key
```

PEM options for the broker container:

- **Volume mounts (default):** `./certs/broker.{crt,key}` plus `ROOT_CA_CRT` (default `../statsmqtt/data/ca/root-ca.crt`) — no entrypoint changes.
- **Environment variables:** paste `print-railway-broker-env.sh` output into `.env` as `NANOMQ_TLS_*`; entrypoint uses env when all three are set.

Railway production uses **two separate Dockerfile services** (private broker + public Caddy). [`docker-compose.yml`](docker-compose.yml) is **local validation only** — do not deploy it as a single Railway Compose service.

## Legacy `broker/` in monorepo

The older `broker/` path (repo-root Docker context) remains for local smoke tests and docs; **new Railway broker deploys should use this project.**
