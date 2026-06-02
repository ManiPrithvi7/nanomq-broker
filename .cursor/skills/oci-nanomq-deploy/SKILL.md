---
name: oci-nanomq-deploy
description: >-
  Deploy NanoMQ 0.24.13 with native mTLS on Oracle Cloud using deploy-oci.sh
  and proofmqtt PKI. Use when deploying or debugging nanomq-broker on OCI,
  SSH/GLIBC/security-list issues, mbedtls -9568, or broker.withproof.io cutover.
---

# OCI NanoMQ broker deploy (nanomq-broker)

## Architecture

- Native `listeners.ssl` on `0.0.0.0:8883`, plain MQTT on `127.0.0.1:1883` only
- PKI in **proofmqtt**: `data/ca/`, `broker/certs/` — not committed in nanomq-broker
- DNS: `broker.withproof.io` → instance public IP, port **8883**

## Instance requirements

| Requirement | Detail |
|-------------|--------|
| OS | **Ubuntu 24.04+** or **Oracle Linux 9** (GLIBC ≥ 2.36 for NanoMQ 0.24.13) |
| Shape | `VM.Standard.E2.1.Micro` → x86_64 RPM or amd64 deb |
| SSH user | `ubuntu` (Ubuntu) / `opc` (Oracle Linux) |
| SSH key | Must match launch pubkey in instance metadata |

## Repo files

| File | Role |
|------|------|
| `deploy-oci.env` | `OCI_*`, `CA_DIR`, `BROKER_CERT_DIR` |
| `deploy-oci.sh` | Network, setup, certs |
| `setup-broker.sh` | Install 0.24.13, systemd, iptables :8883 |
| `deploy-certs.sh` | SCP CA + broker leaf, restart nanomq |
| `nanomq.conf` | `bind = "0.0.0.0:8883"` (host:port, not URI scheme) |

## deploy-oci.env

```bash
export OCI_COMPARTMENT_ID=ocid1.tenancy.oc1..xxxx
export OCI_INSTANCE_NAME=Proof-v3
export OCI_SSH_KEY="${HOME}/Downloads/ssh-key-2026-06-02.key"
export OCI_SSH_USER=ubuntu
export CA_DIR="${HOME}/Desktop/proofmqtt/data/ca"
export BROKER_CERT_DIR="${HOME}/Desktop/proofmqtt/broker/certs"
```

## Deploy

```bash
./deploy-oci.sh
SKIP_NETWORK=1 ./deploy-oci.sh   # after first network pass
```

## PKI / mbedtls -9568

CAService `root-ca.crt` may fail NanoMQ parse. Use:

```bash
openssl x509 -in root-ca.crt -signkey root-ca.key -sha256 -days 3650 -out root-ca-nanomq.crt
```

`deploy-certs.sh` prefers `root-ca-nanomq.crt` or auto re-signs.

## Pitfalls

- **iptables** on Ubuntu images: allow TCP 8883 before REJECT rule (`setup-broker.sh` handles this)
- **CRLF**: `sed 's/\r//g'` on PEMs in `deploy-certs.sh` — never `tr -d '\r'` in SSH heredocs
- **VCN**: IGW + `0.0.0.0/0` route; security list :22 and :8883

## Verification

```bash
CA=$CA_DIR/root-ca-nanomq.crt
CLIENT=../proofmqtt/data/mqtt-client
openssl s_client -connect $IP:8883 -servername broker.withproof.io \
  -CAfile $CA -cert $CLIENT/client.crt -key $CLIENT/client.key
```

See [reference.md](reference.md) for OCI CLI snippets.
