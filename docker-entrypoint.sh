#!/bin/sh
# Railway / cloud: PEMs from env (no file mounts). Local: mount files under /etc/nanomq/certs/.
# NANOMQ_DISABLE_TLS=1 → plain MQTT on 1883 (staging only; no certs required).
#
# Always pass --conf so NanoMQ does not search a wrong default path.
# Optional overrides: NANOMQ_PLAIN_CONF, NANOMQ_TLS_CONF (default paths below).
# Debug: NANOMQ_DEBUG_CERTS=1 logs PEM SHA256, CA fingerprint, SANs, chain verify.
#   Also sets log level to info unless NANOMQ_LOG_LEVEL is already set.
# Optional: NANOMQ_EXPECTED_CA_FINGERPRINT=9B:12:06:56:... (SHA1) — WARN if CA mismatch.
set -e

NANOMQ_BIN="${NANOMQ_BIN:-/usr/local/bin/nanomq}"
CONF_PLAIN="${NANOMQ_PLAIN_CONF:-/etc/nanomq.plain.conf}"
CONF_TLS="${NANOMQ_TLS_CONF:-/etc/nanomq.conf}"

CERT_DIR="/etc/nanomq/certs"
mkdir -p "$CERT_DIR"

# Empty NANOMQ_CONF_PATH causes "Set new conf path from env: (null)" noise; drop it.
if [ -z "${NANOMQ_CONF_PATH:-}" ]; then
  unset NANOMQ_CONF_PATH
fi

# Normalize fingerprint for comparison: uppercase, strip "SHA1 Fingerprint=" prefix and spaces.
_fp_norm() {
  echo "$1" | tr '[:lower:]' '[:upper:]' | tr -d ' ' | sed 's/^SHA1FINGERPRINT=//'
}

verify_config() {
  _conf="$1"
  if [ ! -f "$_conf" ] || [ ! -s "$_conf" ]; then
    echo "[nanomq] ERROR: Config not found or empty: $_conf" >&2
    echo "[nanomq]   Check Railway Root Directory includes nanomq.conf in the Docker build context." >&2
    exit 1
  fi
  echo "[nanomq] Config OK: $_conf ($(wc -c < "$_conf" | tr -d ' ') bytes)"
  if grep -q '0.0.0.0:8883' "$_conf" 2>/dev/null; then
    echo "[nanomq] Config declares SSL listener on 0.0.0.0:8883"
  else
    echo "[nanomq] WARN: Config missing bind 0.0.0.0:8883" >&2
  fi
}

validate_certs() {
  if [ "${NANOMQ_DEBUG_CERTS:-}" != 1 ] && [ "${NANOMQ_DEBUG_CERTS:-}" != true ]; then
    return 0
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    echo "[nanomq] NANOMQ_DEBUG_CERTS: PEM SHA256:"
    sha256sum "$CERT_DIR"/* 2>/dev/null || true
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    echo "[nanomq] NANOMQ_DEBUG_CERTS set but openssl not in PATH; skipping PEM checks." >&2
    return 0
  fi

  echo "[nanomq] NANOMQ_DEBUG_CERTS: validating written PEMs..."
  openssl x509 -in "$CERT_DIR/root_ca.crt" -noout -subject && echo "[nanomq] CA cert OK" || echo "[nanomq] WARN: CA cert parse failed" >&2
  openssl x509 -in "$CERT_DIR/broker.crt" -noout -subject && echo "[nanomq] Broker cert OK" || echo "[nanomq] WARN: Broker cert parse failed" >&2

  _ca_fp="$(openssl x509 -in "$CERT_DIR/root_ca.crt" -fingerprint -noout 2>/dev/null || true)"
  _ca_fp_sha256="$(openssl x509 -in "$CERT_DIR/root_ca.crt" -fingerprint -sha256 -noout 2>/dev/null || true)"
  _broker_fp="$(openssl x509 -in "$CERT_DIR/broker.crt" -fingerprint -noout 2>/dev/null || true)"
  echo "[nanomq] CA fingerprint (SHA1): ${_ca_fp}"
  echo "[nanomq] CA fingerprint (SHA256): ${_ca_fp_sha256}"
  echo "[nanomq] Broker cert fingerprint (SHA1): ${_broker_fp}"

  if [ -n "${NANOMQ_EXPECTED_CA_FINGERPRINT:-}" ]; then
    _expected="$(_fp_norm "$NANOMQ_EXPECTED_CA_FINGERPRINT")"
    _actual="$(_fp_norm "$_ca_fp")"
    if [ "$_actual" = "$_expected" ]; then
      echo "[nanomq] CA fingerprint matches NANOMQ_EXPECTED_CA_FINGERPRINT OK"
    else
      echo "[nanomq] WARN: CA fingerprint MISMATCH — broker may be using the wrong Root CA." >&2
      echo "[nanomq]   expected: SHA1 Fingerprint=${NANOMQ_EXPECTED_CA_FINGERPRINT}" >&2
      echo "[nanomq]   actual:   ${_ca_fp}" >&2
      echo "[nanomq]   Fix NANOMQ_TLS_CA_CERT on Railway (Raw editor, full PEM, no truncation)." >&2
    fi
  else
    echo "[nanomq] Tip: set NANOMQ_EXPECTED_CA_FINGERPRINT to auto-detect wrong CA on deploy."
  fi

  openssl verify -CAfile "$CERT_DIR/root_ca.crt" "$CERT_DIR/broker.crt" && echo "[nanomq] Broker chain OK" || echo "[nanomq] WARN: Broker chain verify failed" >&2

  _crt_mod="$(openssl x509 -noout -modulus -in "$CERT_DIR/broker.crt" 2>/dev/null | openssl md5 2>/dev/null || true)"
  _key_mod="$(openssl rsa -noout -modulus -in "$CERT_DIR/broker.key" 2>/dev/null | openssl md5 2>/dev/null || openssl ec -noout -modulus -in "$CERT_DIR/broker.key" 2>/dev/null | openssl md5 2>/dev/null || true)"
  if [ -n "$_crt_mod" ] && [ "$_crt_mod" = "$_key_mod" ]; then
    echo "[nanomq] Broker cert/key modulus match OK"
  else
    echo "[nanomq] WARN: Broker cert/key modulus mismatch" >&2
  fi

  if openssl rsa -in "$CERT_DIR/broker.key" -check -noout 2>/dev/null; then
    echo "[nanomq] Broker key OK"
  elif openssl ec -in "$CERT_DIR/broker.key" -check -noout 2>/dev/null; then
    echo "[nanomq] Broker key OK (EC)"
  else
    echo "[nanomq] WARN: Broker key check failed" >&2
  fi

  echo "[nanomq] Broker cert SANs:"
  openssl x509 -in "$CERT_DIR/broker.crt" -noout -ext subjectAltName 2>/dev/null || true
}

start_broker() {
  _conf="$1"
  verify_config "$_conf"
  if [ ! -x "$NANOMQ_BIN" ] && ! command -v nanomq >/dev/null 2>&1; then
    echo "[nanomq] ERROR: nanomq binary not found at $NANOMQ_BIN" >&2
    exit 1
  fi
  _bin="$NANOMQ_BIN"
  if [ ! -x "$_bin" ]; then
    _bin="nanomq"
  fi
  echo "[nanomq] Starting broker: $_bin start --conf $_conf"
  echo "[nanomq] Note: HTTP :8081 WARN may appear even when only TLS :8883 is used (NanoMQ REST API)."
  exec "$_bin" start --conf "$_conf"
}

disable_tls=false
case "${NANOMQ_DISABLE_TLS:-}" in
  1|true|TRUE|yes|YES) disable_tls=true ;;
esac

if [ "$disable_tls" = true ]; then
  echo "[nanomq] NANOMQ_DISABLE_TLS set — starting plain MQTT (config: $CONF_PLAIN)."
  start_broker "$CONF_PLAIN"
fi

# Prefer env vars when all three are set (Railway secrets).
if [ -n "$NANOMQ_TLS_CA_CERT" ] && [ -n "$NANOMQ_TLS_CERT" ] && [ -n "$NANOMQ_TLS_KEY" ]; then
  printf '%s' "$NANOMQ_TLS_CA_CERT" | sed 's/\\n/\n/g' > "$CERT_DIR/root_ca.crt"
  chmod 644 "$CERT_DIR/root_ca.crt"
  printf '%s' "$NANOMQ_TLS_CERT" | sed 's/\\n/\n/g' > "$CERT_DIR/broker.crt"
  chmod 644 "$CERT_DIR/broker.crt"
  printf '%s' "$NANOMQ_TLS_KEY" | sed 's/\\n/\n/g' > "$CERT_DIR/broker.key"
  chmod 600 "$CERT_DIR/broker.key"
  echo "[nanomq] Wrote TLS PEMs from environment variables (newlines normalized)."
elif [ -f "$CERT_DIR/root_ca.crt" ] && [ -f "$CERT_DIR/broker.crt" ] && [ -f "$CERT_DIR/broker.key" ]; then
  chmod 644 "$CERT_DIR/root_ca.crt" "$CERT_DIR/broker.crt" 2>/dev/null || true
  chmod 600 "$CERT_DIR/broker.key" 2>/dev/null || true
  echo "[nanomq] Using TLS PEM files already present under $CERT_DIR."
else
  echo "[nanomq] ERROR: Missing TLS material." >&2
  echo "  Set NANOMQ_TLS_CA_CERT, NANOMQ_TLS_CERT, NANOMQ_TLS_KEY (full PEM text), or" >&2
  echo "  mount root_ca.crt, broker.crt, broker.key under $CERT_DIR." >&2
  echo "  For staging without mTLS, set NANOMQ_DISABLE_TLS=1 (plain MQTT on 1883)." >&2
  exit 1
fi

validate_certs

CONF_RUN="$CONF_TLS"
if [ -n "${NANOMQ_LOG_LEVEL:-}" ]; then
  :
elif [ "${NANOMQ_DEBUG_CERTS:-}" = 1 ] || [ "${NANOMQ_DEBUG_CERTS:-}" = true ]; then
  NANOMQ_LOG_LEVEL=info
fi

if [ -n "${NANOMQ_LOG_LEVEL:-}" ]; then
  CONF_RUN="/tmp/nanomq.runtime.conf"
  sed "s/^  level = .*/  level = ${NANOMQ_LOG_LEVEL}/" "$CONF_TLS" > "$CONF_RUN"
  echo "[nanomq] Log level override: ${NANOMQ_LOG_LEVEL} (runtime config: $CONF_RUN)."
fi

start_broker "$CONF_RUN"
