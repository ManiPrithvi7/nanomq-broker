#!/usr/bin/env bash
# Print raw PEM blocks for Railway Variables (NANOMQ_TLS_*).
# This broker expects raw PEM text, not base64 — use Railway Raw editor (</>).
#
# Usage: ./print-railway-broker-env.sh [certs_dir] [ca_crt_path]

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CERT_DIR="${1:-${HERE}/certs}"
CA_CRT="${2:-${HERE}/../statsmqtt/data/ca/root-ca.crt}"

for f in "$CA_CRT" "${CERT_DIR}/broker.crt" "${CERT_DIR}/broker.key"; do
  if [[ ! -f "$f" ]]; then
    echo "Missing: $f" >&2
    exit 1
  fi
done

echo "# Paste each block into Railway → nanomq-broker-private → Variables → Raw editor."
echo "# Unset NANOMQ_DISABLE_TLS. Do not set NANOMQ_TLS_ENABLE (unused)."
echo "# Optional one deploy:"
echo "#   NANOMQ_DEBUG_CERTS=1"
echo "#   NANOMQ_EXPECTED_CA_FINGERPRINT=9B:12:06:56:04:B4:28:73:C3:CF:1B:36:42:07:9A:CD:53:33:2D:8F"
echo ""
echo "========== NANOMQ_TLS_CA_CERT =========="
cat "$CA_CRT"
echo ""
echo "========== NANOMQ_TLS_CERT =========="
cat "${CERT_DIR}/broker.crt"
echo ""
echo "========== NANOMQ_TLS_KEY =========="
cat "${CERT_DIR}/broker.key"
echo ""
echo "# Local checksums (compare after deploy with NANOMQ_DEBUG_CERTS=1):"
sha256sum "$CA_CRT" "${CERT_DIR}/broker.crt" "${CERT_DIR}/broker.key"
