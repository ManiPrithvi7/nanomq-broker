#!/bin/sh
# PEMs always loaded from NANOMQ_TLS_* env on every start — no file fallback.
# Stale files under /etc/nanomq/certs/ are removed before write. Exits on missing env or CA mismatch.
# NANOMQ_DISABLE_TLS=1 → plain MQTT on 1883 (staging only; skips cert env requirement).
set -e

NANOMQ_BIN="${NANOMQ_BIN:-/usr/local/bin/nanomq}"
CONF_PLAIN="${NANOMQ_PLAIN_CONF:-/etc/nanomq.plain.conf}"
CONF_TLS="${NANOMQ_TLS_CONF:-/etc/nanomq.conf}"
CERT_DIR="/etc/nanomq/certs"

mkdir -p "$CERT_DIR"

if [ -z "${NANOMQ_CONF_PATH:-}" ]; then
  unset NANOMQ_CONF_PATH
fi

_fp_norm() {
  echo "$1" | tr '[:lower:]' '[:upper:]' | tr -d ' :' | sed 's/^SHA1FINGERPRINT=//; s/^SHA256FINGERPRINT=//'
}

start_broker() {
  _conf="$1"
  if [ ! -f "$_conf" ] || [ ! -s "$_conf" ]; then
    echo "[nanomq] ERROR: Config not found or empty: $_conf" >&2
    exit 1
  fi
  _bin="$NANOMQ_BIN"
  if [ ! -x "$_bin" ]; then
    _bin="nanomq"
  fi
  echo "[nanomq] Starting broker: $_bin start --conf $_conf"
  exec "$_bin" start --conf "$_conf"
}

case "${NANOMQ_DISABLE_TLS:-}" in
  1|true|TRUE|yes|YES)
    echo "[nanomq] NANOMQ_DISABLE_TLS set — plain MQTT (config: $CONF_PLAIN)."
    start_broker "$CONF_PLAIN"
    ;;
esac

rm -f "$CERT_DIR/root_ca.crt" "$CERT_DIR/broker.crt" "$CERT_DIR/broker.key"
echo "[nanomq] Removed all existing PEM files — will reload from environment"

if [ -z "${NANOMQ_TLS_CA_CERT:-}" ] || [ -z "${NANOMQ_TLS_CERT:-}" ] || [ -z "${NANOMQ_TLS_KEY:-}" ]; then
  echo "[nanomq] ERROR: Missing required env vars. Set NANOMQ_TLS_CA_CERT, NANOMQ_TLS_CERT, NANOMQ_TLS_KEY" >&2
  exit 1
fi

_ca_preview="$(printf '%s' "$NANOMQ_TLS_CA_CERT" | head -c 100)"
echo "[nanomq] NANOMQ_TLS_CA_CERT first 100 chars: ${_ca_preview}"

printf '%s' "$NANOMQ_TLS_CA_CERT" | sed 's/\\n/\n/g' > "$CERT_DIR/root_ca.crt"
chmod 644 "$CERT_DIR/root_ca.crt"
printf '%s' "$NANOMQ_TLS_CERT" | sed 's/\\n/\n/g' > "$CERT_DIR/broker.crt"
chmod 644 "$CERT_DIR/broker.crt"
printf '%s' "$NANOMQ_TLS_KEY" | sed 's/\\n/\n/g' > "$CERT_DIR/broker.key"
chmod 600 "$CERT_DIR/broker.key"
echo "[nanomq] Wrote TLS PEMs from environment variables"

for _f in root_ca.crt broker.crt broker.key; do
  if [ ! -s "$CERT_DIR/$_f" ]; then
    echo "[nanomq] ERROR: Failed to write $CERT_DIR/$_f" >&2
    exit 1
  fi
done

if command -v openssl >/dev/null 2>&1; then
  _actual_fp_sha256="$(_fp_norm "$(openssl x509 -in "$CERT_DIR/root_ca.crt" -noout -fingerprint -sha256 2>/dev/null || true)")"
  _expected_fp_sha256="$(_fp_norm "${NANOMQ_EXPECTED_CA_FINGERPRINT_SHA256:-4D2B8A685F7EDBF1CD8890461DBD6666DCBC1654FA7AD5266FAE4BBB5BFF17A8}")"

  if [ "$_actual_fp_sha256" != "$_expected_fp_sha256" ]; then
    echo "[nanomq] FATAL: Root CA fingerprint mismatch!" >&2
    echo "[nanomq]   Expected: ${_expected_fp_sha256}" >&2
    echo "[nanomq]   Actual:   ${_actual_fp_sha256}" >&2
    echo "[nanomq]   Update NANOMQ_TLS_CA_CERT environment variable (Railway → Variables → Raw editor)." >&2
    exit 1
  fi
  echo "[nanomq] Root CA fingerprint verified"
else
  echo "[nanomq] ERROR: openssl not found — cannot verify Root CA fingerprint." >&2
  exit 1
fi

start_broker "$CONF_TLS"
