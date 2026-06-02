#!/bin/bash
# deploy-certs.sh — copy PROOF-CA certs to OCI broker and restart nanomq
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OCI_HOST="${1:-ubuntu@broker.withproof.io}"
DEFAULT_BROKER_CERTS="${HERE}/../proofmqtt/broker/certs"
CERT_DIR="${2:-${BROKER_CERT_DIR:-$DEFAULT_BROKER_CERTS}}"
CA_DIR="${CA_DIR:-${3:-${HERE}/../proofmqtt/data/ca}}"
SSH_KEY="${SSH_KEY:-${OCI_SSH_KEY:-${HOME}/Downloads/ssh-key-2026-06-02.key}}"

# CA priority: root-ca-nanomq.crt → root-ca-openssl.crt → auto re-sign from root-ca.key
if [[ -f "$CA_DIR/root-ca-nanomq.crt" ]]; then
  ROOT_CA_FILE="$CA_DIR/root-ca-nanomq.crt"
elif [[ -f "$CA_DIR/root-ca-openssl.crt" ]]; then
  ROOT_CA_FILE="$CA_DIR/root-ca-openssl.crt"
elif [[ -f "$CA_DIR/root-ca.crt" ]]; then
  # CAService PEM may need openssl re-sign for NanoMQ mbedtls (see root-ca-openssl.crt)
  ROOT_CA_FILE="$(mktemp)"
  openssl x509 -in "$CA_DIR/root-ca.crt" -signkey "$CA_DIR/root-ca.key" -sha256 -days 3650 -out "$ROOT_CA_FILE" 2>/dev/null \
    || openssl x509 -in "$CA_DIR/root-ca.crt" -out "$ROOT_CA_FILE" -outform PEM
  trap 'rm -f "$ROOT_CA_FILE"' EXIT
else
  ROOT_CA_FILE=""
fi

for f in "$ROOT_CA_FILE" "${CERT_DIR}/broker.crt" "${CERT_DIR}/broker.key"; do
  if [[ ! -f "$f" ]]; then
    echo "Missing: $f" >&2
    exit 1
  fi
done

SCP_OPTS=()
SSH_OPTS=()
if [[ -f "$SSH_KEY" ]]; then
  SCP_OPTS=(-i "$SSH_KEY")
  SSH_OPTS=(-i "$SSH_KEY")
fi

echo "=== Deploying certs to $OCI_HOST ==="
scp "${SCP_OPTS[@]}" "$ROOT_CA_FILE" "$OCI_HOST:/tmp/root-ca.crt"
scp "${SCP_OPTS[@]}" "${CERT_DIR}/broker.crt" "${CERT_DIR}/broker.key" "$OCI_HOST:/tmp/"

ssh "${SSH_OPTS[@]}" "$OCI_HOST" 'set -euo pipefail
  sudo mkdir -p /etc/nanomq/certs
  sudo mv /tmp/root-ca.crt /tmp/broker.crt /tmp/broker.key /etc/nanomq/certs/
  sudo mv /etc/nanomq/certs/root-ca.crt /etc/nanomq/certs/root_ca.crt

  for f in root_ca.crt broker.crt broker.key; do
    sudo sed -i "s/\r//g" "/etc/nanomq/certs/$f"
  done

  sudo chmod 644 /etc/nanomq/certs/root_ca.crt /etc/nanomq/certs/broker.crt
  sudo chmod 600 /etc/nanomq/certs/broker.key

  sudo openssl x509 -in /etc/nanomq/certs/broker.crt -noout >/dev/null
  sudo openssl pkey -in /etc/nanomq/certs/broker.key -check -noout >/dev/null

  sudo systemctl enable nanomq 2>/dev/null || true
  sudo systemctl restart nanomq
  sleep 2
  sudo systemctl status nanomq --no-pager || true
  sudo ss -tlnp | grep -E ":8883|:1883" || true
  echo "CA fingerprint: $(sudo openssl x509 -in /etc/nanomq/certs/root_ca.crt -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ":")"
'

echo "=== Certs deployed, nanomq restarted ==="
