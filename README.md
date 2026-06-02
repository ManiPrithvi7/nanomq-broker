# NanoMQ broker — OCI (standalone)

Native **NanoMQ 0.24.13** on Oracle Cloud with **mTLS on 8883**. Plain MQTT listens on **127.0.0.1:1883** only (not exposed in the VCN).

PKI is managed in **[proofmqtt](../proofmqtt)** (`data/ca/`, `broker/certs/`). This repo contains deploy scripts and `nanomq.conf` only.

## Layout

| File | Purpose |
|------|---------|
| `nanomq.conf` | Native SSL :8883, localhost :1883, mTLS `verify_peer` |
| `setup-broker.sh` | Install NanoMQ 0.24.13 (apt/deb or dnf/rpm), systemd, host firewall :8883 |
| `deploy-certs.sh` | SCP PROOF-CA + broker leaf to VM, restart `nanomq` |
| `deploy-oci.sh` | OCI CLI: network, SSH bootstrap, setup + certs |
| `deploy-oci.env` | Instance OCID, IP, SSH key, `CA_DIR` (local; gitignored pattern via `.env`) |
| `deploy-oci.env.example` | Template |
| `.cursor/skills/oci-nanomq-deploy/` | Agent skill for OCI deploy troubleshooting |

## Prerequisites

- OCI CLI (`oci`) — `oci session authenticate --profile-name DEFAULT`
- `jq` (security-list updates)
- SSH key matching instance launch pubkey (`OCI_SSH_KEY`)
- **Ubuntu 24.04+** or **Oracle Linux 9** (NanoMQ 0.24.13 needs GLIBC ≥ 2.36)
- proofmqtt PKI: `root-ca-nanomq.crt`, `broker/certs/broker.{crt,key}`

## One-shot deploy

```bash
cp deploy-oci.env.example deploy-oci.env   # edit OCID, IP, SSH key
./deploy-oci.sh
```

`deploy-oci.sh` will:

1. Resolve the VM (by `OCI_INSTANCE_ID` or `OCI_INSTANCE_NAME`)
2. Ensure IGW route and ingress **TCP 22** + **8883**
3. Run `setup-broker.sh` on the VM
4. Run `deploy-certs.sh` with `CA_DIR` and `BROKER_CERT_DIR` from env

Set `SKIP_NETWORK=1` after the first successful network pass.

### Environment (`deploy-oci.env`)

```bash
export OCI_COMPARTMENT_ID="ocid1.tenancy.oc1..xxxx"
export OCI_INSTANCE_NAME="Proof-v3"
export OCI_INSTANCE_ID="ocid1.instance...."   # optional if name is unique
export OCI_PUBLIC_IP="x.x.x.x"                # optional; auto-discovered
export OCI_SSH_KEY="${HOME}/Downloads/ssh-key-2026-06-02.key"
export OCI_SSH_USER=ubuntu                    # opc on Oracle Linux
export CA_DIR="${HOME}/Desktop/proofmqtt/data/ca"
export BROKER_CERT_DIR="${HOME}/Desktop/proofmqtt/broker/certs"
```

## Manual deploy

```bash
scp -i "$OCI_SSH_KEY" setup-broker.sh nanomq.conf ubuntu@<ip>:/tmp/
ssh -i "$OCI_SSH_KEY" ubuntu@<ip> 'sudo bash /tmp/setup-broker.sh'

CA_DIR=~/Desktop/proofmqtt/data/ca \
  SSH_KEY=~/Downloads/ssh-key-2026-06-02.key \
  ./deploy-certs.sh ubuntu@<ip> ~/Desktop/proofmqtt/broker/certs
```

Point **DNS** `broker.withproof.io` → instance public IP.

## NanoMQ packages (0.24.13)

| VM arch | RPM | `.deb` fallback |
|---------|-----|-----------------|
| `aarch64` | `linux-arm64.rpm` | `linux-arm64.deb` |
| `x86_64` | `linux-x86_64.rpm` | `linux-amd64.deb` |

## Verification

```bash
ssh -i "$OCI_SSH_KEY" ubuntu@<ip> 'sudo systemctl status nanomq; sudo ss -tlnp | grep -E "1883|8883"'

CA=~/Desktop/proofmqtt/data/ca/root-ca-nanomq.crt
CLIENT=~/Desktop/proofmqtt/data/mqtt-client

openssl s_client -connect <ip>:8883 -servername broker.withproof.io \
  -CAfile "$CA" -cert "$CLIENT/client.crt" -key "$CLIENT/client.key"
# Expect: Verify return code: 0 (ok)

mosquitto_pub -h <ip> -p 8883 --cafile "$CA" \
  --cert "$CLIENT/client.crt" --key "$CLIENT/client.key" \
  -t "test/hello" -m "ok"
```

### mbedTLS `-9568` on CA

NanoMQ may reject CAService-generated `root-ca.crt`. Re-sign with OpenSSL (same key):

```bash
cd ~/Desktop/proofmqtt/data/ca
openssl x509 -in root-ca.crt -signkey root-ca.key -sha256 -days 3650 -out root-ca-nanomq.crt
```

Redeploy certs and restart `nanomq`.

## mqtt-publisher-lite / devices

- `MQTT_BROKER=broker.withproof.io`
- `MQTT_PORT=8883`
- Trust anchor: proofmqtt `root-ca-nanomq.crt` (or current PROOF-CA)
- Per-client cert/key from your provisioning flow (same CA)
