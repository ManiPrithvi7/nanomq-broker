#!/bin/sh
set -e

echo "[nanomq] ENTRYPOINT VERSION: 2026-06-01-stunnel-v1"

NANOMQ_BIN="${NANOMQ_BIN:-/usr/local/bin/nanomq}"
CONF_PLAIN="${NANOMQ_PLAIN_CONF:-/etc/nanomq.plain.conf}"
CONF_TLS="${NANOMQ_TLS_CONF:-/etc/nanomq.conf}"
CERT_DIR="/etc/nanomq/certs"

mkdir -p "$CERT_DIR"
[ -z "${NANOMQ_CONF_PATH:-}" ] && unset NANOMQ_CONF_PATH

# Kill base-image nanomq
for _i in 1 2 3; do
  _count="$(ps aux | grep -c '[n]anomq' || true)"
  [ "$_count" -eq 0 ] && break
  pkill -9 -f nanomq 2>/dev/null || true
  sleep 1
done

# ── TLS disabled: plain mode ──
case "${NANOMQ_DISABLE_TLS:-}" in
  1|true|TRUE|yes|YES)
    echo "[nanomq] Plain MQTT mode"
    exec "$NANOMQ_BIN" start --conf "$CONF_PLAIN"
    ;;
esac

# ── Require env vars ──
[ -z "${NANOMQ_TLS_CA_CERT_BASE64:-}" ] || [ -z "${NANOMQ_TLS_CERT_BASE64:-}" ] || [ -z "${NANOMQ_TLS_KEY_BASE64:-}" ] && {
  echo "[nanomq] ERROR: Missing NANOMQ_TLS_*_BASE64 vars" >&2
  exit 1
}

# ── Decode certs ──
rm -f "$CERT_DIR"/*
echo "[nanomq] Decoding certs..."

printf '%s' "$NANOMQ_TLS_CA_CERT_BASE64" | base64 -d | tr -d '\r' > "$CERT_DIR/root_ca.crt"
printf '%s' "$NANOMQ_TLS_CERT_BASE64"    | base64 -d | tr -d '\r' > "$CERT_DIR/broker.crt"
printf '%s' "$NANOMQ_TLS_KEY_BASE64"     | base64 -d | tr -d '\r' > "$CERT_DIR/broker.key"

chmod 644 "$CERT_DIR/root_ca.crt" "$CERT_DIR/broker.crt"
chmod 600 "$CERT_DIR/broker.key"

# ── Validate ──
for _f in root_ca.crt broker.crt; do
  openssl x509 -in "$CERT_DIR/$_f" -noout >/dev/null 2>&1 || {
    echo "[nanomq] ERROR: $_f invalid" >&2; exit 1; }
done

openssl pkey -in "$CERT_DIR/broker.key" -check -noout >/dev/null 2>&1 || {
  echo "[nanomq] ERROR: broker.key invalid" >&2; exit 1; }

# ── Start NanoMQ in background ──
echo "[nanomq] Starting NanoMQ on plain TCP 1883..."
"$NANOMQ_BIN" start --conf "$CONF_TLS" &
NANOMQ_PID=$!

sleep 3
if ! kill -0 $NANOMQ_PID 2>/dev/null; then
  echo "[nanomq] ERROR: NanoMQ failed to start" >&2
  exit 1
fi

# ── Start stunnel in foreground ──
echo "[nanomq] Starting stunnel on mTLS 8883..."
echo "[nanomq] CA fingerprint: $(openssl x509 -in $CERT_DIR/root_ca.crt -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')"
exec stunnel /etc/stunnel/stunnel.conf