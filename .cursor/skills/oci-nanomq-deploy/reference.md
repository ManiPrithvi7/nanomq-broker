# OCI NanoMQ deploy — reference

## Find instance

```bash
oci compute instance list \
  --compartment-id "$OCI_COMPARTMENT_ID" \
  --all \
  --query "data[?\"display-name\"=='Proof-v2'].{id:id, state:\"lifecycle-state\"}" \
  --output table
```

## Public IP

```bash
oci compute instance list-vnics --instance-id "$INSTANCE_ID" \
  --query 'data[0]."public-ip"' --raw-output
```

If value is an OCID, resolve:

```bash
oci network public-ip get --public-ip-id "$OCID" --query 'data."ip-address"' --raw-output
```

## Security list TCP rules (inspect)

```bash
SL_ID=$(oci network subnet get --subnet-id "$SUBNET_ID" \
  --query 'data."security-list-ids"[0]' --raw-output)
oci network security-list get --security-list-id "$SL_ID" --output json | \
  jq '.data."ingress-security-rules"[] | select(.protocol=="6") | {source, min: ."tcp-options"."destination-port-range".min}'
```

## Proof-v2 lesson (2026-06-02)

- Launch key: `ssh-key-2026-06-02` (SHA256:PQWyIGGDV7nShQlUISfzPCQNLF9Dexi0X0XZzyGnYr0)
- `oci_nanomq_key` (SHA256:J92w92cHS3Tj5Os1jYvfsNcVA1ekCe62aJdcK2Ig6V0) does **not** match Proof-v2
- Image was Ubuntu 20.04 focal (GLIBC 2.31) — broker install succeeded but binary won't execute
