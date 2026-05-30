#!/usr/bin/env bash
# Regenerate NanoMQ broker TLS cert (CN + SAN). Use same Root CA as mqtt-publisher-lite / devices.
#
# Default CA paths (monorepo layout): ../statsmqtt/data/ca/root-ca.{crt,key}
# Override:
#   CA_CRT=/path/to/root-ca.crt CA_KEY=/path/to/root-ca.key ./generate-broker-cert-openssl.sh
#
# Railway TCP proxy hostname (required for TLS when clients connect via *.proxy.rlwy.net):
#   BROKER_RAILWAY_PROXY_HOST=yamabiko.proxy.rlwy.net ./generate-broker-cert-openssl.sh
#
# Extra DNS SANs (comma-separated):
#   BROKER_SAN_DNS="foo.example.com,bar.example.com" ./generate-broker-cert-openssl.sh
#
# Optional IP SANs (no "any IP" in x509 — list each IP clients use):
#   BROKER_SAN_IPS="203.0.113.1,198.51.100.2" ./generate-broker-cert-openssl.sh
#
# Output: ./certs/broker.key, ./certs/broker.crt, ./certs/broker-fullchain.crt
# Railway: NANOMQ_TLS_CA_CERT, NANOMQ_TLS_CERT (broker.crt), NANOMQ_TLS_KEY

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

OUT_DIR="${HERE}/certs"
mkdir -p "$OUT_DIR"

CA_CRT="${CA_CRT:-${HERE}/../statsmqtt/data/ca/root-ca.crt}"
CA_KEY="${CA_KEY:-${HERE}/../statsmqtt/data/ca/root-ca.key}"
BROKER_RAILWAY_PROXY_HOST="${BROKER_RAILWAY_PROXY_HOST:-yamabiko.proxy.rlwy.net}"

if [[ ! -f "$CA_CRT" || ! -f "$CA_KEY" ]]; then
  echo "Set CA_CRT and CA_KEY to your Root CA PEM paths (defaults: ${CA_CRT}, ${CA_KEY})."
  exit 1
fi

openssl genrsa -out "${OUT_DIR}/broker.key" 2048

openssl req -new \
  -key "${OUT_DIR}/broker.key" \
  -out "${OUT_DIR}/broker.csr" \
  -subj "/CN=PROOF-nanomq-broker/O=Proof"

EXT="$(mktemp)"
trap 'rm -f "$EXT"' EXIT

{
  echo '[v3_req]'
  echo 'basicConstraints = CA:FALSE'
  echo 'keyUsage = digitalSignature, keyEncipherment'
  echo 'extendedKeyUsage = serverAuth'
  echo 'subjectAltName = @alt_names'
  echo '[alt_names]'
  echo 'DNS.1 = PROOF-nanomq-broker'
  echo 'DNS.2 = broker.withproof.io'
  echo 'DNS.3 = localhost'
} > "$EXT"

dns_idx=4
if [[ -n "$BROKER_RAILWAY_PROXY_HOST" ]]; then
  echo "DNS.${dns_idx} = ${BROKER_RAILWAY_PROXY_HOST}" >> "$EXT"
  dns_idx=$((dns_idx + 1))
fi

if [[ -n "${BROKER_SAN_DNS:-}" ]]; then
  _norm=$(echo "$BROKER_SAN_DNS" | tr ',' ' ')
  for _raw in $_norm; do
    _dns="${_raw//[[:space:]]/}"
    [[ -z "$_dns" ]] && continue
    echo "DNS.${dns_idx} = ${_dns}" >> "$EXT"
    dns_idx=$((dns_idx + 1))
  done
fi

ip_idx=1
if [[ -n "${BROKER_SAN_IPS:-}" ]]; then
  _norm=$(echo "$BROKER_SAN_IPS" | tr ',' ' ')
  for _raw in $_norm; do
    _ip="${_raw//[[:space:]]/}"
    [[ -z "$_ip" ]] && continue
    echo "IP.${ip_idx} = ${_ip}" >> "$EXT"
    ip_idx=$((ip_idx + 1))
  done
fi

openssl x509 -req \
  -in "${OUT_DIR}/broker.csr" \
  -CA "$CA_CRT" \
  -CAkey "$CA_KEY" \
  -CAcreateserial \
  -out "${OUT_DIR}/broker.crt" \
  -days 825 \
  -sha256 \
  -extfile "$EXT" \
  -extensions v3_req

openssl verify -CAfile "$CA_CRT" "${OUT_DIR}/broker.crt"
cat "${OUT_DIR}/broker.crt" "$CA_CRT" > "${OUT_DIR}/broker-fullchain.crt"

echo "OK: ${OUT_DIR}/broker.{key,crt}"
echo "SANs:"
openssl x509 -in "${OUT_DIR}/broker.crt" -noout -ext subjectAltName
echo "Next: ./print-railway-broker-env.sh  (paste PEMs into Railway Variables → Raw editor)"
