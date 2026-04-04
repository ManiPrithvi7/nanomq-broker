#!/bin/sh
# Railway / cloud: PEMs from env (no file mounts). Local: mount files under /etc/nanomq/certs/.
# NANOMQ_DISABLE_TLS=1 → plain MQTT on 1883 (staging only; no certs required).
#
# Always pass --conf so NanoMQ does not search a wrong default path.
# Optional overrides: NANOMQ_PLAIN_CONF, NANOMQ_TLS_CONF (default paths below).
set -e

CONF_PLAIN="${NANOMQ_PLAIN_CONF:-/etc/nanomq.plain.conf}"
CONF_TLS="${NANOMQ_TLS_CONF:-/etc/nanomq.conf}"

CERT_DIR="/etc/nanomq/certs"
mkdir -p "$CERT_DIR"

disable_tls=false
case "${NANOMQ_DISABLE_TLS:-}" in
  1|true|TRUE|yes|YES) disable_tls=true ;;
esac

if [ "$disable_tls" = true ]; then
  echo "[nanomq] NANOMQ_DISABLE_TLS set — starting plain MQTT (config: $CONF_PLAIN)."
  exec nanomq start --conf "$CONF_PLAIN"
fi

# Prefer env vars when all three are set (Railway secrets).
# Railway/UI often stores multiline PEMs as one line with literal "\n" — restore real newlines for mbedTLS.
if [ -n "$NANOMQ_TLS_CA_CERT" ] && [ -n "$NANOMQ_TLS_CERT" ] && [ -n "$NANOMQ_TLS_KEY" ]; then
  printf '%s' "$NANOMQ_TLS_CA_CERT" | sed 's/\\n/\n/g' > "$CERT_DIR/root_ca.crt"
  chmod 644 "$CERT_DIR/root_ca.crt"
  printf '%s' "$NANOMQ_TLS_CERT" | sed 's/\\n/\n/g' > "$CERT_DIR/broker.crt"
  chmod 644 "$CERT_DIR/broker.crt"
  printf '%s' "$NANOMQ_TLS_KEY" | sed 's/\\n/\n/g' > "$CERT_DIR/broker.key"
  chmod 600 "$CERT_DIR/broker.key"
  echo "[nanomq] Wrote TLS PEMs from environment variables (newlines normalized)."

  if [ "${NANOMQ_DEBUG_CERTS:-}" = 1 ] || [ "${NANOMQ_DEBUG_CERTS:-}" = true ]; then
    if command -v openssl >/dev/null 2>&1; then
      echo "[nanomq] NANOMQ_DEBUG_CERTS: validating written PEMs..."
      openssl x509 -in "$CERT_DIR/root_ca.crt" -noout -subject && echo "[nanomq] CA cert OK" || echo "[nanomq] WARN: CA cert parse failed" >&2
      openssl x509 -in "$CERT_DIR/broker.crt" -noout -subject && echo "[nanomq] Broker cert OK" || echo "[nanomq] WARN: Broker cert parse failed" >&2
      openssl rsa -in "$CERT_DIR/broker.key" -check -noout 2>/dev/null && echo "[nanomq] Broker key OK" || openssl ec -in "$CERT_DIR/broker.key" -check -noout 2>/dev/null && echo "[nanomq] Broker key OK (EC)" || echo "[nanomq] WARN: Broker key check failed" >&2
    else
      echo "[nanomq] NANOMQ_DEBUG_CERTS set but openssl not in PATH; skipping PEM checks."
    fi
  fi
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

echo "[nanomq] Starting mTLS broker (config: $CONF_TLS)."
exec nanomq start --conf "$CONF_TLS"
