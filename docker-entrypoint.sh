#!/bin/sh
set -e

echo "[nanomq] ENTRYPOINT VERSION: 2026-06-01-v9"

NANOMQ_BIN="${NANOMQ_BIN:-/usr/local/bin/nanomq}"
CONF_PLAIN="${NANOMQ_PLAIN_CONF:-/etc/nanomq.plain.conf}"
CONF_TLS="${NANOMQ_TLS_CONF:-/etc/nanomq.conf}"
CERT_DIR="/etc/nanomq/certs"

mkdir -p "$CERT_DIR"
[ -z "${NANOMQ_CONF_PATH:-}" ] && unset NANOMQ_CONF_PATH

# ============================================================================
# CRITICAL: Block until base-image NanoMQ is fully dead
# ============================================================================
echo "[nanomq] Waiting for base-image nanomq to terminate..."
for _i in 1 2 3 4 5; do
  _count="$(ps aux | grep -c '[n]anomq' || true)"
  if [ "$_count" -eq 0 ]; then
    break
  fi
  echo "[nanomq] Killing $_count nanomq processes (attempt $_i)..."
  pkill -9 -f nanomq 2>/dev/null || true
  sleep 1
done

# Verify port 8883 is free
if command -v ss >/dev/null 2>&1; then
  while ss -tlnp 2>/dev/null | grep -q ':8883'; do
    echo "[nanomq] Waiting for port 8883 to release..."
    sleep 1
  done
fi

start_broker() {
  _conf="$1"
  [ ! -s "$_conf" ] && { echo "[nanomq] ERROR: Config empty: $_conf" >&2; exit 1; }
  _bin="$NANOMQ_BIN"
  [ ! -x "$_bin" ] && _bin="nanomq"
  echo "[nanomq] Starting broker: $_bin start --conf $_conf"
  exec "$_bin" start --conf "$_conf"
}

write_pem_from_base64() {
  printf '%s' "$1" | base64 -d | tr -d '\r' > "$2"
  chmod "$3" "$2"
}

# ── TLS disabled ──
case "${NANOMQ_DISABLE_TLS:-}" in
  1|true|TRUE|yes|YES)
    echo "[nanomq] Plain MQTT mode"
    start_broker "$CONF_PLAIN"
    ;;
esac

# ── Wipe & write certs ──
rm -f "$CERT_DIR"/*
echo "[nanomq] Loading certs from env..."

[ -z "${NANOMQ_TLS_CA_CERT_BASE64:-}" ] || [ -z "${NANOMQ_TLS_CERT_BASE64:-}" ] || [ -z "${NANOMQ_TLS_KEY_BASE64:-}" ] && {
  echo "[nanomq] ERROR: Missing NANOMQ_TLS_*_BASE64 vars" >&2
  exit 1
}

write_pem_from_base64 "$NANOMQ_TLS_CA_CERT_BASE64" "$CERT_DIR/root_ca.crt" 644
write_pem_from_base64 "$NANOMQ_TLS_CERT_BASE64"    "$CERT_DIR/broker.crt" 644
write_pem_from_base64 "$NANOMQ_TLS_KEY_BASE64"     "$CERT_DIR/broker.key" 600

# ── Validate with OpenSSL ──
for _f in root_ca.crt broker.crt; do
  openssl x509 -in "$CERT_DIR/$_f" -noout >/dev/null 2>&1 || {
    echo "[nanomq] ERROR: $_f invalid" >&2; exit 1; }
done

openssl pkey -in "$CERT_DIR/broker.key" -check -noout >/dev/null 2>&1 || {
  echo "[nanomq] ERROR: broker.key invalid" >&2; exit 1; }

_cert_pk="$(openssl x509 -in "$CERT_DIR/broker.crt" -noout -pubkey 2>/dev/null)"
_key_pk="$(openssl pkey -in "$CERT_DIR/broker.key" -pubout 2>/dev/null)"
[ "$_cert_pk" != "$_key_pk" ] && {
  echo "[nanomq] ERROR: cert/key mismatch" >&2; exit 1; }

openssl verify -CAfile "$CERT_DIR/root_ca.crt" "$CERT_DIR/broker.crt" >/dev/null 2>&1 || {
  echo "[nanomq] ERROR: cert not signed by CA" >&2; exit 1; }

# ── Config validation ──
echo "[nanomq] Config validation..."
[ ! -f "$CONF_TLS" ] && { echo "[nanomq] ERROR: $CONF_TLS missing" >&2; exit 1; }

# CRITICAL: Verify nested tls block exists
if ! grep -q 'tls[[:space:]]*{' "$CONF_TLS" || ! grep -A 5 'tls[[:space:]]*{' "$CONF_TLS" | grep -q 'cacertfile'; then
  echo "[nanomq] FATAL: nanomq.conf missing nested tls { ... } block" >&2
  echo "[nanomq] NanoMQ 0.24.x requires: listeners.ssl { bind = \"...\" tls { cacertfile = \"...\" } }" >&2
  exit 1
fi

echo "[nanomq] Full nanomq.conf:"
cat "$CONF_TLS"

# ── Test handshake locally before exposing ──
echo "[nanomq] Testing TLS handshake locally..."
if ! timeout 5 openssl s_server -cert "$CERT_DIR/broker.crt" -key "$CERT_DIR/broker.key" -CAfile "$CERT_DIR/root_ca.crt" -Verify 1 -accept 9999 >/dev/null 2>&1 & then
  echo "[nanomq] WARNING: openssl s_server test failed to start" >&2
else
  _srv_pid=$!
  sleep 1
  if echo "Q" | timeout 3 openssl s_client -connect localhost:9999 -CAfile "$CERT_DIR/root_ca.crt" -verify_return_error </dev/null >/dev/null 2>&1; then
    echo "[nanomq] Local TLS handshake: OK"
  else
    echo "[nanomq] ERROR: Local TLS handshake failed — cert/key incompatible with OpenSSL" >&2
    kill $_srv_pid 2>/dev/null || true
    exit 1
  fi
  kill $_srv_pid 2>/dev/null || true
fi

echo "[nanomq] All checks passed. Starting broker..."
start_broker "$CONF_TLS"