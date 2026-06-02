#!/bin/bash
# setup-broker.sh — OCI VM (NanoMQ 0.24.13, native mTLS) — Oracle Linux or Ubuntu
set -euo pipefail

echo "=== 1. Dependencies ==="
if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y openssl curl ca-certificates
elif command -v dnf >/dev/null 2>&1; then
  sudo dnf update -y
  sudo dnf install -y openssl curl
else
  echo "Unsupported OS (need apt or dnf)"; exit 1
fi

echo "=== 2. Directories ==="
sudo mkdir -p /etc/nanomq/certs /var/log/nanomq
sudo chmod 700 /etc/nanomq/certs

echo "=== 3. Install NanoMQ ==="
NANOMQ_VERSION="0.24.13"
ARCH=$(uname -m)
case "$ARCH" in
  aarch64) RPM_PKG="nanomq-${NANOMQ_VERSION}-linux-arm64.rpm";  DEB_PKG="nanomq-${NANOMQ_VERSION}-linux-arm64.deb" ;;
  x86_64)  RPM_PKG="nanomq-${NANOMQ_VERSION}-linux-x86_64.rpm"; DEB_PKG="nanomq-${NANOMQ_VERSION}-linux-amd64.deb" ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

install_deb() {
  local deb_pkg="$1"
  local deb_url="https://github.com/nanomq/nanomq/releases/download/${NANOMQ_VERSION}/${deb_pkg}"
  curl -fsSL -o /tmp/nanomq.deb "$deb_url"
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y /tmp/nanomq.deb || {
      sudo dpkg -i /tmp/nanomq.deb || true
      sudo apt-get install -f -y
    }
  else
    sudo dnf install -y dpkg
    sudo rm -rf /tmp/nanomq-extract
    sudo dpkg-deb -x /tmp/nanomq.deb /tmp/nanomq-extract
    sudo install -m 755 /tmp/nanomq-extract/usr/local/bin/nanomq /usr/local/bin/nanomq
  fi
}

if command -v apt-get >/dev/null 2>&1; then
  echo "Installing .deb: $DEB_PKG"
  install_deb "$DEB_PKG"
else
  RPM_URL="https://github.com/nanomq/nanomq/releases/download/${NANOMQ_VERSION}/${RPM_PKG}"
  if curl -fsSL -o /tmp/nanomq.pkg "$RPM_URL"; then
    echo "Installing RPM: $RPM_PKG"
    sudo rpm -Uvh /tmp/nanomq.pkg
  else
    echo "RPM not found, falling back to .deb: $DEB_PKG"
    install_deb "$DEB_PKG"
  fi
fi

NANOMQ_BIN=$(command -v nanomq || echo "/usr/local/bin/nanomq")
test -x "$NANOMQ_BIN" || { echo "nanomq binary missing"; exit 1; }
NANOMQ_VER=$("$NANOMQ_BIN" --version 2>&1 || true)
if ! echo "$NANOMQ_VER" | grep -qE '0\.24'; then
  if ldd "$NANOMQ_BIN" 2>&1 | grep -q 'not found'; then
    echo "ERROR: nanomq binary missing GLIBC (use Ubuntu 24.04+ or Oracle Linux 9+)."
    exit 1
  fi
  echo "ERROR: nanomq installed but version check failed"; exit 1
fi
echo "NanoMQ binary: $NANOMQ_BIN ($("$NANOMQ_BIN" --version 2>/dev/null || true))"

echo "=== 4. Config ==="
if [[ -f /tmp/nanomq.conf ]]; then
  echo "Using /tmp/nanomq.conf from deploy bundle"
  sudo install -m 644 /tmp/nanomq.conf /etc/nanomq/nanomq.conf
else
  sudo tee /etc/nanomq/nanomq.conf > /dev/null <<'EOF'
listeners.tcp {
  bind = "127.0.0.1:1883"
}

listeners.ssl {
  bind                 = "0.0.0.0:8883"
  keyfile              = "/etc/nanomq/certs/broker.key"
  certfile             = "/etc/nanomq/certs/broker.crt"
  cacertfile           = "/etc/nanomq/certs/root_ca.crt"
  verify_peer          = true
  fail_if_no_peer_cert = true
}

listeners.ws {
  enable = false
}

http_server {
  enable = false
}

log {
  level = warn
  to    = [console]
}
EOF
fi

echo "=== 5. Systemd ==="
sudo tee /etc/systemd/system/nanomq.service > /dev/null <<EOF
[Unit]
Description=NanoMQ Broker
After=network-online.target

[Service]
Type=simple
ExecStart=${NANOMQ_BIN} start --conf /etc/nanomq/nanomq.conf
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

echo "=== 6. Host firewall (Ubuntu/OCI images often allow only :22) ==="
if sudo iptables -L INPUT -n 2>/dev/null | grep -q "reject-with icmp-host-prohibited"; then
  if ! sudo iptables -C INPUT -p tcp --dport 8883 -j ACCEPT 2>/dev/null; then
    sudo iptables -I INPUT 5 -p tcp --dport 8883 -j ACCEPT
    echo "Opened INPUT tcp/8883 (before REJECT rule)"
  fi
  if command -v netfilter-persistent >/dev/null 2>&1; then
    sudo netfilter-persistent save 2>/dev/null || true
  fi
fi

echo "=== 7. Enable (certs required before healthy start) ==="
sudo systemctl daemon-reload
sudo systemctl enable nanomq
echo "=== Setup complete ==="
echo "Next: run deploy-certs.sh from your laptop, then nanomq will start/restart with mTLS on :8883"
