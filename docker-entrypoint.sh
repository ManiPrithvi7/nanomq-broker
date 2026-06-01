#!/bin/sh
# PEMs always loaded from NANOMQ_TLS_*_BASE64 env on every start — no file fallback.
# Stale files under /etc/nanomq/certs/ are removed before write.
# Exits on missing env, failed write, cert parse error, or chain mismatch.
# NANOMQ_DISABLE_TLS=1 → plain MQTT on 1883 (staging only).
set -e

NANOMQ_BIN="${NANOMQ_BIN:-/usr/local/bin/nanomq}"
CONF_PLAIN="${NANOMQ_PLAIN_CONF:-/etc/nanomq.plain.conf}"
CONF_TLS="${NANOMQ_TLS_CONF:-/etc/nanomq.conf}"
CERT_DIR="/etc/nanomq/certs"

mkdir -p "$CERT_DIR"

if [ -z "${NANOMQ_CONF_PATH:-}" ]; then
  unset NANOMQ_CONF_PATH
fi

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

# Decode Base64 to PEM, strip carriage returns (mbedTLS requirement)
write_pem_from_base64() {
  _b64_var="$1"
  _path="$2"
  _mode="$3"
  printf '%s' "$_b64_var" | base64 -d | tr -d '\r' > "$_path"
  chmod "$_mode" "$_path"
}

_hex_dump() {
  if command -v xxd >/dev/null 2>&1; then
    xxd
  else
    od -An -tx1
  fi
}

log_pem_file_encoding() {
  _file="$1"
  _path="$CERT_DIR/$_file"
  _lines="$(wc -l < "$_path" | tr -d ' ')"
  _chars="$(wc -c < "$_path" | tr -d ' ')"
  echo "[nanomq] $_file line count: $_lines"
  echo "[nanomq] $_file char count: $_chars"
  echo "[nanomq] $_file first line: $(head -1 "$_path")"
  echo "[nanomq] $_file last line:  $(tail -1 "$_path")"
  echo "[nanomq] $_file hex tail:   $(tail -c 20 "$_path" | _hex_dump)"
  if [ "$_lines" -lt 3 ]; then
    echo "[nanomq] ERROR: $_file has less than 3 lines — invalid PEM" >&2
    exit 1
  fi
}

# ── TLS disabled branch ────────────────────────────────────────────────────────
case "${NANOMQ_DISABLE_TLS:-}" in
  1|true|TRUE|yes|YES)
    echo "[nanomq] NANOMQ_DISABLE_TLS set — plain MQTT (config: $CONF_PLAIN)."
    start_broker "$CONF_PLAIN"
    ;;
esac

# ── Always wipe stale certs ────────────────────────────────────────────────────
rm -f "$CERT_DIR/root_ca.crt" "$CERT_DIR/broker.crt" "$CERT_DIR/broker.key"
echo "[nanomq] Removed all existing PEM files — reloading from environment"

# ── Require all three Base64 env vars ──────────────────────────────────────────
if [ -z "${NANOMQ_TLS_CA_CERT_BASE64:-}" ] || [ -z "${NANOMQ_TLS_CERT_BASE64:-}" ] || [ -z "${NANOMQ_TLS_KEY_BASE64:-}" ]; then
  echo "[nanomq] ERROR: Missing required env vars. Set NANOMQ_TLS_CA_CERT_BASE64, NANOMQ_TLS_CERT_BASE64, NANOMQ_TLS_KEY_BASE64" >&2
  exit 1
fi

# ── Decode Base64 to PEM files (mbedTLS-safe: strip CR) ────────────────────────
write_pem_from_base64 "$NANOMQ_TLS_CA_CERT_BASE64" "$CERT_DIR/root_ca.crt" 644
write_pem_from_base64 "$NANOMQ_TLS_CERT_BASE64"    "$CERT_DIR/broker.crt" 644
write_pem_from_base64 "$NANOMQ_TLS_KEY_BASE64"     "$CERT_DIR/broker.key" 600
echo "[nanomq] Decoded TLS PEMs from Base64 environment variables"

# ── PEM encoding diagnostics (written files) ─────────────────────────────────
log_pem_file_encoding "root_ca.crt"
log_pem_file_encoding "broker.crt"
log_pem_file_encoding "broker.key"

# ── Verify files are non-empty ─────────────────────────────────────────────────
for _f in root_ca.crt broker.crt broker.key; do
  if [ ! -s "$CERT_DIR/$_f" ]; then
    echo "[nanomq] ERROR: $CERT_DIR/$_f is empty after decode — check Base64 env var" >&2
    exit 1
  fi
done

# ── Validate that written certs are parseable by openssl ──────────────────────
if ! command -v openssl >/dev/null 2>&1; then
  echo "[nanomq] ERROR: openssl not found — cannot validate certs" >&2
  exit 1
fi

for _pair in "root_ca.crt:Root CA" "broker.crt:Broker cert"; do
  _file="${_pair%%:*}"
  _label="${_pair##*:}"
  if ! openssl x509 -in "$CERT_DIR/$_file" -noout 2>/dev/null; then
    echo "[nanomq] ERROR: $_label ($CERT_DIR/$_file) is not a valid X.509 cert" >&2
    echo "[nanomq]   Check that NANOMQ_TLS_CA_CERT_BASE64 / NANOMQ_TLS_CERT_BASE64 contain valid Base64" >&2
    exit 1
  fi
  _fp="$(openssl x509 -in "$CERT_DIR/$_file" -noout -fingerprint -sha256 2>/dev/null)"
  echo "[nanomq] $_label fingerprint: $_fp"
done

# ── Validate private key (supports both RSA and EC) ───────────────────────────
if ! openssl pkey -in "$CERT_DIR/broker.key" -check -noout 2>/dev/null; then
  echo "[nanomq] ERROR: broker.key is not a valid private key (RSA or EC)" >&2
  exit 1
fi
echo "[nanomq] broker.key is valid"

# ── Verify private key matches broker cert ────────────────────────────────────
_cert_pubkey="$(openssl x509 -in "$CERT_DIR/broker.crt" -noout -pubkey 2>/dev/null)"
_key_pubkey="$(openssl pkey -in "$CERT_DIR/broker.key" -pubout 2>/dev/null)"
if [ "$_cert_pubkey" != "$_key_pubkey" ]; then
  echo "[nanomq] FATAL: broker.key does NOT match broker.crt public key" >&2
  echo "[nanomq]   NANOMQ_TLS_CERT_BASE64 and NANOMQ_TLS_KEY_BASE64 are from different keypairs" >&2
  exit 1
fi
echo "[nanomq] broker.key matches broker.crt"

# ── Verify broker cert is signed by the env-sourced Root CA ───────────────────
if ! openssl verify -CAfile "$CERT_DIR/root_ca.crt" "$CERT_DIR/broker.crt" >/dev/null 2>&1; then
  echo "[nanomq] FATAL: broker.crt is NOT signed by the Root CA in NANOMQ_TLS_CA_CERT_BASE64" >&2
  echo "[nanomq]   Your env vars may have a mismatched CA/cert pair — check Railway Variables" >&2
  exit 1
fi
echo "[nanomq] broker.crt verified against Root CA from env"

# ── Confirm nanomq.conf TLS paths match where we write ───────────────────────
echo "[nanomq] nanomq.conf TLS section:"
grep -A 5 'tls' "$CONF_TLS" 2>/dev/null || echo "[nanomq] (no tls block found — ensure config points to $CERT_DIR)"

start_broker "$CONF_TLS"