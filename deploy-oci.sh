#!/bin/bash
# deploy-oci.sh — discover OCI VM, open :8883, bootstrap NanoMQ + certs
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

if [[ -f "$HERE/deploy-oci.env" ]]; then
  # shellcheck source=/dev/null
  source "$HERE/deploy-oci.env"
fi

OCI_CLI_PROFILE="${OCI_CLI_PROFILE:-DEFAULT}"
export OCI_CLI_PROFILE

OCI_COMPARTMENT_ID="${OCI_COMPARTMENT_ID:-}"
OCI_INSTANCE_NAME="${OCI_INSTANCE_NAME:-Proof}"
OCI_INSTANCE_ID="${OCI_INSTANCE_ID:-}"
OCI_SSH_KEY="${OCI_SSH_KEY:-${HOME}/.ssh/oci_nanomq_key}"
OCI_SSH_USER="${OCI_SSH_USER:-ubuntu}"
SKIP_NETWORK="${SKIP_NETWORK:-}"
OCI_ASSIGN_PUBLIC_IP="${OCI_ASSIGN_PUBLIC_IP:-}"
OCI_ENSURE_IGW_ROUTE="${OCI_ENSURE_IGW_ROUTE:-1}"
OCI_PUBLIC_IP="${OCI_PUBLIC_IP:-}"
CA_DIR="${CA_DIR:-${HERE}/../statsmqtt/data/ca}"
export CA_DIR

die() { echo "ERROR: $*" >&2; exit 1; }

ensure_vcn_internet_route() {
  local subnet_id="$1"
  local vcn_id
  vcn_id=$(oci network subnet get --subnet-id "$subnet_id" --query 'data."vcn-id"' --raw-output)
  local rt_id
  rt_id=$(oci network subnet get --subnet-id "$subnet_id" --query 'data."route-table-id"' --raw-output)
  local rules
  rules=$(oci network route-table get --rt-id "$rt_id" --query 'data."route-rules"' --output json)
  if echo "$rules" | jq -e '.[] | select(.destination=="0.0.0.0/0")' >/dev/null 2>&1; then
    echo "Default route 0.0.0.0/0 already present"
    return 0
  fi
  echo "WARN: No default internet route on subnet — fixing VCN routing..."
  local igw_id
  igw_id=$(oci network internet-gateway list --compartment-id "$OCI_COMPARTMENT_ID" --vcn-id "$vcn_id" \
    --query 'data[0].id' --raw-output 2>/dev/null || true)
  if [[ -z "$igw_id" || "$igw_id" == "null" ]]; then
    igw_id=$(oci network internet-gateway create \
      --compartment-id "$OCI_COMPARTMENT_ID" --vcn-id "$vcn_id" --is-enabled true \
      --display-name "proof-internet-gateway" --query 'data.id' --raw-output)
    echo "Created Internet Gateway: $igw_id"
  fi
  local new_rules
  new_rules=$(jq -n --arg igw "$igw_id" '[{
    "description": "Default route to Internet Gateway",
    "destination": "0.0.0.0/0",
    "destinationType": "CIDR_BLOCK",
    "networkEntityId": $igw,
    "routeType": "STATIC"
  }]')
  oci network route-table update --rt-id "$rt_id" --route-rules "$new_rules" --force \
    --wait-for-state AVAILABLE >/dev/null
  echo "Route table updated (0.0.0.0/0 -> IGW)"
}

command -v oci >/dev/null || die "oci CLI not found"
command -v jq >/dev/null || die "jq required for security-list updates"

[[ -n "$OCI_COMPARTMENT_ID" ]] || die "Set OCI_COMPARTMENT_ID (tenancy or compartment OCID)"

if [[ -n "$OCI_INSTANCE_ID" ]]; then
  INSTANCE_ID="$OCI_INSTANCE_ID"
  echo "=== OCI NanoMQ deploy (profile=$OCI_CLI_PROFILE, instance-id=$INSTANCE_ID) ==="
else
  [[ -n "$OCI_INSTANCE_NAME" ]] || die "Set OCI_INSTANCE_NAME or OCI_INSTANCE_ID"
  echo "=== OCI NanoMQ deploy (profile=$OCI_CLI_PROFILE, instance=$OCI_INSTANCE_NAME) ==="
  INSTANCE_ID=$(oci compute instance list \
    --compartment-id "$OCI_COMPARTMENT_ID" \
    --all \
    --query "data[?\"display-name\"=='${OCI_INSTANCE_NAME}' && \"lifecycle-state\"=='RUNNING'].id | [0]" \
    --raw-output 2>/dev/null || true)
  [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "null" && "$INSTANCE_ID" != "None" ]] \
    || die "No RUNNING instance named: $OCI_INSTANCE_NAME"
fi

INSTANCE_STATE=$(oci compute instance get --instance-id "$INSTANCE_ID" \
  --query 'data."lifecycle-state"' --raw-output)
[[ "$INSTANCE_STATE" == "RUNNING" ]] || die "Instance not RUNNING (state=$INSTANCE_STATE)"
INSTANCE_NAME=$(oci compute instance get --instance-id "$INSTANCE_ID" \
  --query 'data."display-name"' --raw-output)
echo "Target: $INSTANCE_NAME ($INSTANCE_ID)"

INSTANCE_SHAPE=$(oci compute instance get --instance-id "$INSTANCE_ID" \
  --query 'data.shape' --raw-output)
echo "Instance: $INSTANCE_ID (shape: $INSTANCE_SHAPE)"

VNIC_JSON=$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" --output json | jq '.data[0]')
SUBNET_ID=$(echo "$VNIC_JSON" | jq -r '.["subnet-id"]')
VNIC_ID=$(echo "$VNIC_JSON" | jq -r '.id')
PRIVATE_IP=$(echo "$VNIC_JSON" | jq -r '.["private-ip"]')
echo "VNIC: $VNIC_ID private=$PRIVATE_IP"

if [[ -n "$OCI_ENSURE_IGW_ROUTE" && -z "$SKIP_NETWORK" ]]; then
  ensure_vcn_internet_route "$SUBNET_ID"
fi

PUBLIC_IP="${OCI_PUBLIC_IP:-}"
if [[ -z "$PUBLIC_IP" ]]; then
  PUBLIC_REF=$(echo "$VNIC_JSON" | jq -r '.["public-ip"] // empty')
  if [[ -n "$PUBLIC_REF" && "$PUBLIC_REF" != "null" ]]; then
    if [[ "$PUBLIC_REF" == ocid* ]]; then
      PUBLIC_IP=$(oci network public-ip get --public-ip-id "$PUBLIC_REF" \
        --query 'data."ip-address"' --raw-output 2>/dev/null || true)
    else
      PUBLIC_IP="$PUBLIC_REF"
    fi
  fi
  if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP=$(oci network vnic get --vnic-id "$VNIC_ID" \
      --query 'data."public-ip"' --raw-output 2>/dev/null || true)
    if [[ -n "$PUBLIC_IP" && "$PUBLIC_IP" == ocid* ]]; then
      PUBLIC_IP=$(oci network public-ip get --public-ip-id "$PUBLIC_IP" \
        --query 'data."ip-address"' --raw-output 2>/dev/null || true)
    fi
  fi
fi

if [[ -z "$PUBLIC_IP" || "$PUBLIC_IP" == "null" ]]; then
  if [[ -n "$OCI_ASSIGN_PUBLIC_IP" ]]; then
    PRIVATE_IP_ID=$(oci network private-ip list --vnic-id "$VNIC_ID" \
      --query 'data[0].id' --raw-output)
    echo "No public IP — creating ephemeral public IP on $PRIVATE_IP_ID ..."
    PUBLIC_IP=$(oci network public-ip create \
      --compartment-id "$OCI_COMPARTMENT_ID" \
      --lifetime EPHEMERAL \
      --private-ip-id "$PRIVATE_IP_ID" \
      --query 'data."ip-address"' --raw-output)
    echo "Assigned public IP: $PUBLIC_IP"
  else
    die "No public IP on VNIC. Set OCI_ASSIGN_PUBLIC_IP=1 in deploy-oci.env or assign one in OCI Console."
  fi
fi
echo "Public IP: $PUBLIC_IP (private $PRIVATE_IP)"

if [[ -z "$SKIP_NETWORK" ]]; then
  SL_ID=$(oci network subnet get --subnet-id "$SUBNET_ID" --query 'data."security-list-ids"[0]' --raw-output)
  echo "Security list: $SL_ID"

  BACKUP="/tmp/nanomq-sl-${SL_ID##*.}-$(date +%Y%m%d%H%M%S).json"
  oci network security-list get --security-list-id "$SL_ID" >"$BACKUP"
  echo "Backed up security list to $BACKUP"

  CURRENT_RULES=$(jq '.data."ingress-security-rules"' "$BACKUP")
  SSH_CIDR="${OCI_SSH_INGRESS_CIDR:-0.0.0.0/0}"
  NEW_RULES="$CURRENT_RULES"
  CHANGED=0

  sl_has_port() {
    local port="$1"
    echo "$NEW_RULES" | jq -e --argjson p "$port" \
      '.[] | select(.protocol=="6") | .tcpOptions.destinationPortRange | select(.min==$p and .max==$p)' >/dev/null
  }

  if ! sl_has_port 22; then
    echo "Adding ingress TCP 22 (source $SSH_CIDR)..."
    NEW_RULES=$(echo "$NEW_RULES" | jq --arg cidr "$SSH_CIDR" '. + [{
      "protocol": "6",
      "source": $cidr,
      "isStateless": false,
      "description": "SSH admin",
      "tcpOptions": { "destinationPortRange": { "min": 22, "max": 22 } }
    }]')
    CHANGED=1
  else
    echo "Ingress TCP 22 already present"
  fi

  if ! sl_has_port 8883; then
    echo "Adding ingress TCP 8883..."
    NEW_RULES=$(echo "$NEW_RULES" | jq '. + [{
      "protocol": "6",
      "source": "0.0.0.0/0",
      "isStateless": false,
      "description": "MQTT mTLS (NanoMQ)",
      "tcpOptions": { "destinationPortRange": { "min": 8883, "max": 8883 } }
    }]')
    CHANGED=1
  else
    echo "Ingress TCP 8883 already present"
  fi

  if [[ "$CHANGED" -eq 1 ]]; then
    oci network security-list update \
      --security-list-id "$SL_ID" \
      --ingress-security-rules "$NEW_RULES" \
      --force \
      --wait-for-state AVAILABLE >/dev/null
    echo "Security list updated"
  fi
else
  echo "SKIP_NETWORK=1 — not modifying security list"
fi

SSH_OPTS=(-o StrictHostKeyChecking=accept-new)
SCP_OPTS=()
if [[ -f "$OCI_SSH_KEY" ]]; then
  SSH_OPTS+=(-i "$OCI_SSH_KEY")
  SCP_OPTS+=(-i "$OCI_SSH_KEY")
else
  echo "WARN: SSH key not found at $OCI_SSH_KEY — using ssh-agent/default keys"
fi

REMOTE="${OCI_SSH_USER}@${PUBLIC_IP}"

echo "=== SSH preflight ==="
if nc -z -w 5 "$PUBLIC_IP" 22 2>/dev/null; then
  echo "TCP 22 reachable on $PUBLIC_IP (security list OK)"
else
  echo "WARN: TCP 22 not reachable — check security list or OCI_SSH_INGRESS_CIDR in deploy-oci.env"
fi

if ! ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=15 "$REMOTE" 'true' 2>/dev/null; then
  PUBKEY_FILE="${OCI_SSH_KEY}.pub"
  die "SSH auth failed for $REMOTE (port 22 is up; wrong key or user).

Use the private key that matches the instance launch pubkey (e.g. ~/Downloads/ssh-key-2026-06-02.key).
Proof-v2 uses user ubuntu (not opc). Set OCI_SSH_USER and OCI_SSH_KEY in deploy-oci.env.

  3) Test: ssh -i \$OCI_SSH_KEY \$OCI_SSH_USER@$PUBLIC_IP \"echo OK\"
  4) Re-run: SKIP_NETWORK=1 ./deploy-oci.sh

Public IP: $PUBLIC_IP | Private: $PRIVATE_IP"
fi

echo "=== Uploading setup-broker.sh and nanomq.conf ==="
scp "${SCP_OPTS[@]}" setup-broker.sh nanomq.conf "$REMOTE:/tmp/"

echo "=== Running setup-broker.sh on VM ==="
ssh "${SSH_OPTS[@]}" "$REMOTE" 'sudo bash /tmp/setup-broker.sh'

echo "=== Deploying certs (CA_DIR=$CA_DIR) ==="
SSH_KEY="$OCI_SSH_KEY" CA_DIR="$CA_DIR" ./deploy-certs.sh "$REMOTE"

echo ""
echo "=== Deploy complete ==="
echo "  Host:     broker.withproof.io (point DNS A record to $PUBLIC_IP)"
echo "  mTLS:     ${PUBLIC_IP}:8883"
echo "  SSH:      ssh ${SSH_OPTS[*]} $REMOTE"
echo ""
echo "Smoke test:"
echo "  openssl s_client -connect ${PUBLIC_IP}:8883 -servername broker.withproof.io \\"
echo "    -CAfile ../statsmqtt/data/ca/root-ca.crt -cert <client.crt> -key <client.key>"
