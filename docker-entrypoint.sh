#!/bin/sh
# PEMs always loaded from NANOMQ_TLS_* env on every start — no file fallback.
# Stale files under /etc/nanomq/certs/ are removed before write.
# Exits on missing env, failed write, or cert parse error.
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

# Railway may store PEMs as one line with literal \n and/or CRLF — mbedTLS needs real LF + headers.
write_pem_from_env() {
  _var="$1"
  _path="$2"
  _mode="$3"
  printf '%s\n' "$_var" | sed 's/\\n/\n/g' | tr -d '\r' > "$_path"
  chmod "$_mode" "$_path"
}

_hex_dump() {
  if command -v xxd >/dev/null 2>&1; then
    xxd
  else
    od -An -tx1
  fi
}

log_ca_env_encoding() {
  _env_len="$(printf '%s' "$NANOMQ_TLS_CA_CERT" | wc -c | tr -d ' ')"
  echo "[nanomq] NANOMQ_TLS_CA_CERT env byte count: $_env_len"
  echo "[nanomq] CA env first 200 bytes hex: $(printf '%s' "$NANOMQ_TLS_CA_CERT" | head -c 200 | _hex_dump)"
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
    echo "[nanomq] ERROR: $_file looks like a single-line PEM — newline substitution failed." >&2
    echo "[nanomq]   Use Railway Variables → Raw editor with real line breaks, or literal \\n sequences." >&2
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

# ── Require all three env vars ─────────────────────────────────────────────────
if [ -z "${NANOMQ_TLS_CA_CERT:-}" ] || [ -z "${NANOMQ_TLS_CERT:-}" ] || [ -z "${NANOMQ_TLS_KEY:-}" ]; then
  echo "[nanomq] ERROR: Missing required env vars. Set NANOMQ_TLS_CA_CERT, NANOMQ_TLS_CERT, NANOMQ_TLS_KEY" >&2
  exit 1
fi

# ── Env encoding (before write — raw bytes from Railway) ───────────────────────
log_ca_env_encoding

# ── Write PEMs from env (mbedTLS-safe: expand \\n, strip CR, trailing newline) ─
write_pem_from_env "$NANOMQ_TLS_CA_CERT" "$CERT_DIR/root_ca.crt" 644
write_pem_from_env "$NANOMQ_TLS_CERT"    "$CERT_DIR/broker.crt" 644
write_pem_from_env "$NANOMQ_TLS_KEY"     "$CERT_DIR/broker.key" 600
echo "[nanomq] Wrote TLS PEMs from environment variables"

# ── PEM encoding diagnostics (written files) ─────────────────────────────────
log_pem_file_encoding "root_ca.crt"
log_pem_file_encoding "broker.crt"
log_pem_file_encoding "broker.key"

# ── Verify files are non-empty ─────────────────────────────────────────────────
for _f in root_ca.crt broker.crt broker.key; do
  if [ ! -s "$CERT_DIR/$_f" ]; then
    echo "[nanomq] ERROR: $CERT_DIR/$_f is empty after write — check env var encoding" >&2
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
    echo "[nanomq]   Check that NANOMQ_TLS_CA_CERT / NANOMQ_TLS_CERT contain proper PEM with real newlines" >&2
    exit 1
  fi
  _fp="$(openssl x509 -in "$CERT_DIR/$_file" -noout -fingerprint -sha256 2>/dev/null)"
  echo "[nanomq] $_label fingerprint: $_fp"
done

if ! openssl rsa -in "$CERT_DIR/broker.key" -check -noout 2>/dev/null; then
  echo "[nanomq] ERROR: broker.key is not a valid RSA private key" >&2
  exit 1
fi
echo "[nanomq] broker.key is valid"

# ── Verify broker cert is signed by the env-sourced Root CA ───────────────────
if ! openssl verify -CAfile "$CERT_DIR/root_ca.crt" "$CERT_DIR/broker.crt" >/dev/null 2>&1; then
  echo "[nanomq] FATAL: broker.crt is NOT signed by the Root CA in NANOMQ_TLS_CA_CERT" >&2
  echo "[nanomq]   Your env vars may have a mismatched CA/cert pair — check Railway Variables" >&2
  exit 1
fi
echo "[nanomq] broker.crt verified against Root CA from env"

start_broker "$CONF_TLS"
