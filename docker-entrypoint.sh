#!/bin/sh
set -e

echo "[nanomq] ENTRYPOINT VERSION: 2026-06-01-v10"

NANOMQ_BIN="${NANOMQ_BIN:-/usr/local/bin/nanomq}"
CONF_PLAIN="${NANOMQ_PLAIN_CONF:-/etc/nanomq.plain.conf}"
CONF_TLS="${NANOMQ_TLS_CONF:-/etc/nanomq.conf}"
CERT_DIR="/etc/nanomq/certs"

mkdir -p "$CERT_DIR"
[ -z "${NANOMQ_CONF_PATH:-}" ] && unset NANOMQ_CONF_PATH

# ============================================================================
# Kill any pre-started NanoMQ from base image
# ============================================================================
echo "[nanomq] Checking for existing nanomq processes..."
for _i in 1 2 3 4 5; do
  _count="$(ps aux | grep -c '[n]anomq' || true)"
  if [ "$_count" -eq 0 ]; then
    break
  fi
  echo "[nanomq] Killing $_count nanomq processes (attempt $_i)..."
  pkill -9 -f nanomq 2>/dev/null || true
  sleep 1
done

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

echo "[nanomq] Full nanomq.conf:"
cat "$CONF_TLS"

# Verify flat format (cacertfile at listeners.ssl level, not nested)
if ! grep -q 'cacertfile[[:space:]]*=' "$CONF_TLS"; then
  echo "[nanomq] FATAL: No cacertfile in nanomq.conf" >&2
  exit 1
fi

# CRITICAL: Ensure no nested tls block exists (NanoMQ 0.24.x doesn't support it)
if grep -q 'tls[[:space:]]*{' "$CONF_TLS"; then
  echo "[nanomq] FATAL: nanomq.conf has nested tls { } block — NanoMQ 0.24.x uses flat format" >&2
  echo "[nanomq] Remove 'tls {' and put cacertfile/certfile/keyfile directly under listeners.ssl" >&2
  exit 1
fi

echo "[nanomq] All checks passed. Starting broker..."
start_broker "$CONF_TLS"