#!/bin/bash
# EC2 mTLS Setup + Verification
# Tested on: Ubuntu 22.04 / Amazon Linux 2
# Run as: bash ec2-setup.sh

set -e

CERT_DIR="/etc/nginx/certs"
DOMAIN="localhost"

echo "=== Installing nginx ==="
if command -v apt-get &>/dev/null; then
  sudo apt-get update -y -q
  sudo apt-get install -y -q nginx openssl
else
  sudo yum install -y nginx openssl
fi

echo "=== Generating Certificates ==="
sudo mkdir -p $CERT_DIR
cd $CERT_DIR

# --- CA ---
sudo openssl genrsa -out ca.key 4096 2>/dev/null
sudo openssl req -new -x509 -days 365 -key ca.key -out ca.crt \
  -subj "/CN=MyCA/O=SRE" 2>/dev/null

# --- Server cert (signed by CA) ---
sudo openssl genrsa -out server.key 2048 2>/dev/null
sudo openssl req -new -key server.key -out server.csr \
  -subj "/CN=$DOMAIN" 2>/dev/null
sudo openssl x509 -req -days 365 \
  -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt 2>/dev/null

# --- Client cert (signed by CA) - goes into New Relic ---
sudo openssl genrsa -out client.key 2048 2>/dev/null
sudo openssl req -new -key client.key -out client.csr \
  -subj "/CN=newrelic-synthetic/O=SRE" 2>/dev/null
sudo openssl x509 -req -days 365 \
  -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out client.crt 2>/dev/null

# Fix permissions so nginx can read
sudo chmod 644 $CERT_DIR/*.crt $CERT_DIR/*.key

echo "=== Configuring nginx ==="
sudo tee /etc/nginx/sites-enabled/default > /dev/null <<'EOF'
server {
    listen 443 ssl;
    server_name localhost;

    ssl_certificate        /etc/nginx/certs/server.crt;
    ssl_certificate_key    /etc/nginx/certs/server.key;

    # mTLS - reject anyone without a cert signed by our CA
    ssl_client_certificate /etc/nginx/certs/ca.crt;
    ssl_verify_client      on;

    location /health {
        default_type application/json;
        return 200 '{"status":"ok","client":"$ssl_client_s_dn"}';
    }
}

# Port 80 - reject with 400 (no plain HTTP)
server {
    listen 80;
    return 400 "TLS required";
}
EOF

sudo nginx -t && sudo systemctl restart nginx
echo "✓ nginx running"

# Copy client certs to /tmp so current user can read them
sudo cp $CERT_DIR/client.crt /tmp/client.crt
sudo cp $CERT_DIR/client.key /tmp/client.key
sudo cp $CERT_DIR/ca.crt     /tmp/ca.crt
sudo chmod 644 /tmp/client.crt /tmp/client.key /tmp/ca.crt

echo ""
echo "=== Verification ==="
echo ""
echo "--- Test 1: WITH client cert (expect 200) ---"
curl -s \
  --cert /tmp/client.crt \
  --key  /tmp/client.key \
  --cacert /tmp/ca.crt \
  https://localhost/health
echo ""

echo ""
echo "--- Test 2: WITHOUT client cert (expect 400) ---"
curl -s \
  --cacert /tmp/ca.crt \
  https://localhost/health || echo "(connection rejected - expected)"
echo ""

echo ""
echo "=== New Relic Secure Credentials ==="
echo ""
echo "Key: NR_CLIENT_CERT"
base64 -w 0 /tmp/client.crt && echo ""
echo ""
echo "Key: NR_CLIENT_KEY"
base64 -w 0 /tmp/client.key && echo ""