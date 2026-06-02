# OCI NanoMQ deploy — reference

## Find instance

```bash
oci compute instance list \
  --compartment-id "$OCI_COMPARTMENT_ID" \
  --all \
  --query "data[?\"display-name\"=='Proof-v3'].{id:id, state:\"lifecycle-state\"}" \
  --output table
```

## Public IP

```bash
oci compute instance list-vnics --instance-id "$INSTANCE_ID" \
  --query 'data[0]."public-ip"' --raw-output
```

## Proof-v3 (ap-hyderabad-1)

- Ubuntu 24.04, `129.154.36.219`
- PKI: `proofmqtt/data/ca/root-ca-nanomq.crt` + `proofmqtt/broker/certs/`

## Re-sign CA for NanoMQ

```bash
cd proofmqtt/data/ca
openssl x509 -in root-ca.crt -signkey root-ca.key -sha256 -days 3650 -out root-ca-nanomq.crt
```
