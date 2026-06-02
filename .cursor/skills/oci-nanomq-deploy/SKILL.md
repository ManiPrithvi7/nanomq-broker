---
name: oci-nanomq-deploy
description: >-
  Deploy NanoMQ 0.24.13 with native mTLS on Oracle Cloud (ap-hyderabad-1) using
  deploy-oci.sh, PROOF-CA certs, and OCI CLI. Use when deploying or debugging
  nanomq-broker on OCI, Proof/Proof-v2 instances, SSH key issues, GLIBC errors,
  security lists, or broker.withproof.io cutover.
---

# OCI NanoMQ broker deploy (nanomq-broker)

## Architecture

- **OCI**: NanoMQ native `listeners.ssl` on `0.0.0.0:8883`, plain TCP on `127.0.0.1:1883` only
- **No stunnel** on OCI (stunnel stays in Docker/Railway only)
- **Certs**: existing PROOF-CA — `certs/broker.{crt,key}` + `../statsmqtt/data/ca/root-ca.crt` (or `CA_DIR` in env)
- **DNS**: `broker.withproof.io` → instance public IP, port **8883** only (not 1883)

## Instance requirements (critical)

| Requirement | Detail |
|-------------|--------|
| OS image | **Ubuntu 24.04** (deb) or **Oracle Linux 9** (rpm) |
| Wrong image | Ubuntu 20.04/22.04: binary needs **GLIBC ≥ 2.36** (22.04 has 2.35) |
| Shape | `VM.Standard.E2.1.Micro` → x86_64 → `nanomq-0.24.13-linux-x86_64.rpm` or `linux-amd64.deb` |
| ARM | `VM.Standard.A1.*` → `linux-arm64.rpm` / `linux-arm64.deb` |
| SSH user | `opc` on Oracle Linux; `ubuntu` on Ubuntu images |
| SSH key | Must match **launch** pubkey — verify with `oci compute instance get --query 'data.metadata."ssh_authorized_keys"'` |

OCI Console often generates `~/Downloads/ssh-key-YYYY-MM-DD.{key,pub}` — use **that** private key, not `oci_nanomq_key`, unless fingerprints match.

```bash
ssh-keygen -lf ~/Downloads/ssh-key-2026-06-02.key.pub
# Compare to instance metadata key
```

## Config files (repo root)

| File | Role |
|------|------|
| `deploy-oci.env` | `OCI_INSTANCE_ID`, `OCI_PUBLIC_IP`, `OCI_SSH_KEY`, `OCI_SSH_USER`, `CA_DIR` |
| `deploy-oci.sh` | Discover VM, IGW route, SL :22/:8883, scp, `setup-broker.sh`, `deploy-certs.sh` |
| `setup-broker.sh` | Install 0.24.13 (RPM/deb), `/etc/nanomq/nanomq.conf`, systemd |
| `deploy-certs.sh` | SCP PEMs, `tr -d '\r'`, `systemctl restart nanomq` |
| `nanomq.conf` | URI binds: `tls+nmq-tcp://0.0.0.0:8883`, `nmq-tcp://127.0.0.1:1883` |

## deploy-oci.env template

```bash
export OCI_CLI_PROFILE=DEFAULT
export OCI_COMPARTMENT_ID=ocid1.tenancy.oc1..aaaaaaaaewvfhp2zsnrelgtosfrob63q24urtghb624ehgweteoowpmgt5xa
export OCI_INSTANCE_NAME=Proof-v2
export OCI_INSTANCE_ID=ocid1.instance.oc1.ap-hyderabad-1.xxx
export OCI_PUBLIC_IP=<public-ip>
export OCI_SSH_KEY="${HOME}/Downloads/ssh-key-2026-06-02.key"
export OCI_SSH_USER=opc   # or ubuntu
export CA_DIR="/path/to/statsmqtt/data/ca"
export OCI_ASSIGN_PUBLIC_IP=1
export OCI_ENSURE_IGW_ROUTE=1
```

## Deploy workflow

```bash
oci session authenticate --profile-name DEFAULT   # if CLI expired
cd nanomq-broker
./deploy-oci.sh          # full: network + bootstrap + certs
# or after network done:
SKIP_NETWORK=1 ./deploy-oci.sh
```

**SSH preflight** (script does this):

```bash
ssh -i "$OCI_SSH_KEY" "$OCI_SSH_USER@$OCI_PUBLIC_IP" "echo OK"
```

## OCI networking checklist

1. **Internet Gateway** on VCN + route `0.0.0.0/0` → IGW (empty route table = SSH timeout)
2. **Security list** ingress: TCP **22** (SSH), TCP **8883** (mTLS) — `deploy-oci.sh` adds idempotently
3. **Public IP** on VNIC — set `OCI_ASSIGN_PUBLIC_IP=1` if missing

`ssh_authorized_keys` **cannot** be added via API after launch — use launch-time key or serial console.

## NanoMQ 0.24.13 packages

| Arch | RPM | DEB fallback |
|------|-----|--------------|
| x86_64 | `nanomq-0.24.13-linux-x86_64.rpm` | `nanomq-0.24.13-linux-amd64.deb` |
| aarch64 | `nanomq-0.24.13-linux-arm64.rpm` | `nanomq-0.24.13-linux-arm64.deb` |

Do **not** use `linux-amd64.rpm` for x86_64 (404).

## deploy-certs.sh pitfalls

- Remote `sudo` required for `tr` and `openssl` on `/etc/nanomq/certs/`
- Rename `root-ca.crt` → `root_ca.crt` on VM
- CRLF: `tr -d '\r'` on all three PEMs (mbedTLS `-9568` if skipped)

## Post-deploy verification

```bash
ssh -i "$OCI_SSH_KEY" "$OCI_SSH_USER@$PUBLIC_IP"
sudo systemctl status nanomq
sudo ss -tlnp | grep -E '1883|8883'   # both nanomq
sudo journalctl -u nanomq -n 50 | grep -i tls

openssl s_client -connect $PUBLIC_IP:8883 -servername broker.withproof.io \
  -CAfile .../root-ca.crt -cert <client.crt> -key <client.key>
```

## Bind syntax

Use host:port only (`bind = "0.0.0.0:8883"`). URI forms (`tls+nmq-tcp://`) cause `nng_listen: Entry not found` on 0.24.13.

## deploy-certs CRLF

Use `sed -i 's/\r$//'` per file. Do **not** use `tr -d '\r'` inside SSH single-quoted scripts (breaks quoting and can strip all `r` from PEM).

## Known instances (ap-hyderabad-1)

| Name | Notes |
|------|-------|
| Proof | No launch SSH key; use serial console or replace |
| Proof-v2 | Terminated (Ubuntu 20.04 / GLIBC) |
| Proof-v3 | Ubuntu 24.04 — `129.154.36.219`, OCID in `deploy-oci.env` |

## Cutover

1. Verify mTLS on public IP
2. DNS `broker.withproof.io` → new IP
3. Retire Railway public endpoint (avoid split-brain)
4. Devices/backend: same CA + client certs, host `broker.withproof.io:8883`
