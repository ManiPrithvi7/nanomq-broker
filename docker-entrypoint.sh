#!/bin/sh
# Railway / cloud: PEMs from env (no file mounts). Local: mount files under /etc/nanomq/certs/.
# NANOMQ_DISABLE_TLS=1 → plain MQTT on 1883 (staging only; no certs required).
#
# Always pass --conf so NanoMQ does not search a wrong default path.
# Optional overrides: NANOMQ_PLAIN_CONF, NANOMQ_TLS_CONF (default paths below).
# Railway: NANOMQ_TLS_* env vars are rewritten on every start (stale PEMs under $CERT_DIR removed first).
# Startup always logs Root CA SHA256 fingerprint + subject (openssl required).
# Debug: NANOMQ_DEBUG_CERTS=1 adds PEM SHA256, SANs, chain verify; sets log level to info unless set.
# Optional: NANOMQ_EXPECTED_CA_FINGERPRINT (SHA1), NANOMQ_EXPECTED_CA_FINGERPRINT_SHA256.
# When PEMs come from NANOMQ_TLS_* env, startup exits 1 if Root CA SHA256 does not match expected.
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

# Normalize fingerprint for comparison: uppercase, strip label prefix and separators.
_fp_norm() {
  echo "$1" | tr '[:lower:]' '[:upper:]' | tr -d ' :' | sed 's/^SHA1FINGERPRINT=//; s/^SHA256FINGERPRINT=//'
}

write_pem_from_env() {
  _var="$1"
  _path="$2"
  _mode="$3"
  printf '%s' "$_var" | sed 's/\\n/\n/g' > "$_path"
  chmod "$_mode" "$_path"
}

wipe_cert_dir() {
  rm -f "$CERT_DIR/root_ca.crt" "$CERT_DIR/broker.crt" "$CERT_DIR/broker.key"
}

# POSIX-safe prefix of a string (no bash ${var:0:N}).
_str_prefix() {
  printf '%s' "$1" | head -c "${2:-100}"
}

log_env_pem_sources() {
  _ca_len="$(printf '%s' "${NANOMQ_TLS_CA_CERT:-}" | wc -c | tr -d ' ')"
  _cert_len="$(printf '%s' "${NANOMQ_TLS_CERT:-}" | wc -c | tr -d ' ')"
  _key_len="$(printf '%s' "${NANOMQ_TLS_KEY:-}" | wc -c | tr -d ' ')"
  echo "[nanomq] NANOMQ_TLS_CA_CERT: ${_ca_len} bytes"
  echo "[nanomq] NANOMQ_TLS_CERT: ${_cert_len} bytes"
  echo "[nanomq] NANOMQ_TLS_KEY: ${_key_len} bytes"
  if [ "$_ca_len" -gt 0 ]; then
    echo "[nanomq] NANOMQ_TLS_CA_CERT first 100 chars: $(_str_prefix "$NANOMQ_TLS_CA_CERT" 100)"
  else
    echo "[nanomq] WARN: NANOMQ_TLS_CA_CERT is empty — will not overwrite from env." >&2
  fi
}

verify_pem_files_written() {
  for _f in root_ca.crt broker.crt broker.key; do
    if [ ! -s "$CERT_DIR/$_f" ]; then
      echo "[nanomq] ERROR: Failed to write $CERT_DIR/$_f (missing or empty after env write)." >&2
      exit 1
    fi
  done
  echo "[nanomq] PEM files on disk: root_ca.crt broker.crt broker.key (all non-empty)."
}

# _strict=1 → exit 1 on SHA256 mismatch (Railway / env-sourced PEMs).
verify_root_ca_fingerprint() {
  _strict="${1:-0}"

  if ! command -v openssl >/dev/null 2>&1; then
    echo "[nanomq] WARN: openssl not in PATH; skipping Root CA fingerprint check." >&2
    return 0
  fi
  if [ ! -s "$CERT_DIR/root_ca.crt" ]; then
    echo "[nanomq] ERROR: root_ca.crt missing or empty after write." >&2
    exit 1
  fi

  echo "[nanomq] === ROOT CA FINGERPRINT (SHA256) ==="
  _ca_fp_sha256="$(openssl x509 -in "$CERT_DIR/root_ca.crt" -noout -fingerprint -sha256 2>/dev/null || true)"
  echo "$_ca_fp_sha256"
  echo "[nanomq] === ROOT CA SUBJECT ==="
  openssl x509 -in "$CERT_DIR/root_ca.crt" -noout -subject
  _ca_fp_sha1="$(openssl x509 -in "$CERT_DIR/root_ca.crt" -noout -fingerprint 2>/dev/null || true)"

  _expected_sha256="${NANOMQ_EXPECTED_CA_FINGERPRINT_SHA256:-4D2B8A685F7EDBF1CD8890461DBD6666DCBC1654FA7AD5266FAE4BBB5BFF17A8}"
  _expected_sha1="${NANOMQ_EXPECTED_CA_FINGERPRINT:-9B:12:06:56:04:B4:28:73:C3:CF:1B:36:42:07:9A:CD:53:33:2D:8F}"
  echo "[nanomq] === EXPECTED FINGERPRINT (correct Root CA) ==="
  echo "[nanomq] SHA256: ${_expected_sha256}"
  echo "[nanomq] SHA1: ${_expected_sha1}"

  _actual_sha256="$(_fp_norm "$_ca_fp_sha256")"
  _actual_sha1="$(_fp_norm "$_ca_fp_sha1")"
  _norm_expected_sha256="$(_fp_norm "$_expected_sha256")"
  _norm_expected_sha1="$(_fp_norm "$_expected_sha1")"

  if [ "$_actual_sha256" = "$_norm_expected_sha256" ]; then
    echo "[nanomq] Root CA SHA256 matches expected (CORRECT)"
  else
    echo "[nanomq] ERROR: Root CA SHA256 MISMATCH!" >&2
    echo "[nanomq]   Expected: ${_norm_expected_sha256}" >&2
    echo "[nanomq]   Actual:   ${_actual_sha256}" >&2
    echo "[nanomq]   Check NANOMQ_TLS_CA_CERT on Railway (Variables → Raw editor, full PEM)." >&2
    if [ "$_strict" = 1 ]; then
      exit 1
    fi
  fi

  if [ "$_actual_sha1" = "$_norm_expected_sha1" ]; then
    echo "[nanomq] Root CA SHA1 matches expected (CORRECT)"
  else
    echo "[nanomq] ERROR: Root CA SHA1 MISMATCH!" >&2
    echo "[nanomq]   Expected: ${_norm_expected_sha1}" >&2
    echo "[nanomq]   Actual:   ${_actual_sha1}" >&2
    echo "[nanomq]   The env var likely still contains the old CA — update NANOMQ_TLS_CA_CERT." >&2
    if [ "$_strict" = 1 ]; then
      exit 1
    fi
  fi
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

# Railway / cloud: always refresh PEMs from env on each start (never reuse stale files on disk).
if [ -n "${NANOMQ_TLS_CA_CERT:-}" ] || [ -n "${NANOMQ_TLS_CERT:-}" ] || [ -n "${NANOMQ_TLS_KEY:-}" ]; then
  if [ -z "${NANOMQ_TLS_CA_CERT:-}" ] || [ -z "${NANOMQ_TLS_CERT:-}" ] || [ -z "${NANOMQ_TLS_KEY:-}" ]; then
    echo "[nanomq] ERROR: Partial NANOMQ_TLS_* env — set all three: CA_CERT, CERT, KEY." >&2
    exit 1
  fi
  log_env_pem_sources
  wipe_cert_dir
  echo "[nanomq] Removed stale PEMs under $CERT_DIR before env write."
  write_pem_from_env "$NANOMQ_TLS_CA_CERT" "$CERT_DIR/root_ca.crt" 644
  write_pem_from_env "$NANOMQ_TLS_CERT" "$CERT_DIR/broker.crt" 644
  write_pem_from_env "$NANOMQ_TLS_KEY" "$CERT_DIR/broker.key" 600
  echo "[nanomq] Wrote TLS PEMs from environment variables (newlines normalized, stale files removed)."
  verify_pem_files_written
  verify_root_ca_fingerprint 1
elif [ -f "$CERT_DIR/root_ca.crt" ] && [ -f "$CERT_DIR/broker.crt" ] && [ -f "$CERT_DIR/broker.key" ]; then
  echo "[nanomq] WARN: NANOMQ_TLS_* env not set — using existing files under $CERT_DIR." >&2
  echo "[nanomq]   On Railway, set NANOMQ_TLS_CA_CERT, NANOMQ_TLS_CERT, NANOMQ_TLS_KEY so stale PEMs are not reused." >&2
  chmod 644 "$CERT_DIR/root_ca.crt" "$CERT_DIR/broker.crt" 2>/dev/null || true
  chmod 600 "$CERT_DIR/broker.key" 2>/dev/null || true
  verify_root_ca_fingerprint 0
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
