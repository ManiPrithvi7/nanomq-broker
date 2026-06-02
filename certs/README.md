# Certificates (not stored in this repo)

Broker TLS material lives in the **proofmqtt** PKI tree:

| File | Path |
|------|------|
| Root CA | `../proofmqtt/data/ca/root-ca.crt` |
| NanoMQ-compatible CA | `../proofmqtt/data/ca/root-ca-nanomq.crt` (or `root-ca-openssl.crt`) |
| Broker leaf | `../proofmqtt/broker/certs/broker.{crt,key}` |
| MQTT client (tests) | `../proofmqtt/data/mqtt-client/client.{crt,key}` |

Generate or refresh:

```bash
cd ../proofmqtt
./scripts/pki/generate-broker-cert.sh
npm run pki -- app-client
openssl x509 -in data/ca/root-ca.crt -signkey data/ca/root-ca.key -sha256 -days 3650 -out data/ca/root-ca-nanomq.crt
```

Do not commit private keys here.
