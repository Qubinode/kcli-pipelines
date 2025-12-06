# Using Step-CA for Certificate Management

This guide covers how to use Step-CA after deployment for various scenarios.

## Important: Internal PKI Only

**Step-CA is a private/internal Certificate Authority.** Certificates issued by Step-CA are:

| Scenario | Trusted? | Notes |
|----------|----------|-------|
| Internal network VMs | ✅ Yes | After bootstrapping |
| VMs on VyOS isolated networks | ✅ Yes | After bootstrapping |
| Public internet browsers | ❌ No | Your root CA is not in browser trust stores |
| Mobile devices | ❌ No | Unless you install the root CA |

### For Public-Facing Services

If you need publicly trusted certificates:
- Use **Let's Encrypt** (free, publicly trusted)
- Use **AWS Certificate Manager** or similar cloud services
- Purchase certificates from a public CA

Step-CA is ideal for:
- Internal services (registries, APIs, databases)
- Disconnected/air-gapped environments
- Development and testing
- mTLS between services
- SSH certificate authentication

## Prerequisites

- Step-CA server deployed via `step_ca_deployment` DAG
- Step CLI installed on client machines
- CA URL and fingerprint available

---

## Deploying on VyOS Isolated Networks

Step-CA can be deployed on any VyOS-managed network for better isolation:

### Network Architecture

```
                    INTERNET
                        |
                +-------+-------+
                |   VyOS Router |
                | 192.168.122.2 |
                +-------+-------+
                        |
    +-------------------+-------------------+
    |                   |                   |
+---+---+          +----+----+         +----+----+
|default|          |isolated1|         |isolated2|
|network|          |192.168.50|        |192.168.51|
+---+---+          +----+----+         +----+----+
    |                   |                   |
+---+---+          +----+----+         +----+----+
|FreeIPA|          | Step-CA |         |OpenShift|
|  DNS  |          | Server  |         | Cluster |
+-------+          +---------+         +---------+
```

### Deploy Step-CA on Isolated Network

```bash
# Deploy Step-CA on isolated1 network (192.168.50.x)
airflow dags trigger step_ca_deployment --conf '{
    "action": "create",
    "domain": "example.com",
    "vm_name": "step-ca-server",
    "network": "isolated1",
    "static_ip": "192.168.50.10"
}'
```

### Ensure Host Routes

After VyOS is configured, ensure routes exist on the host:

```bash
# Add route to isolated network via VyOS
sudo ip route add 192.168.50.0/24 via 192.168.122.2

# Verify connectivity
ping 192.168.50.10
```

### Bootstrap VMs on Isolated Networks

VMs on isolated networks can bootstrap to trust the CA:

```bash
# From a VM on isolated1 network
step ca bootstrap \
  --ca-url https://192.168.50.10:443 \
  --fingerprint <FINGERPRINT> \
  --install
```

---

## Quick Start

### 1. Get CA Information

```bash
# SSH to Step-CA server to get fingerprint
ssh cloud-user@step-ca-server.example.com

# Get root CA fingerprint
step certificate fingerprint $(step path)/certs/root_ca.crt
# Output: 84a033e84196f73bd593fad7a63e509e57fd982f02084359c4e8c5c864efc27d
```

### 2. Bootstrap Client

On any machine that needs to use the CA:

```bash
# Install step CLI (RHEL/CentOS)
wget https://dl.smallstep.com/cli/docs-ca-install/latest/step-cli_amd64.rpm
sudo rpm -i step-cli_amd64.rpm

# Bootstrap (trust the CA)
step ca bootstrap \
  --ca-url https://step-ca-server.example.com:443 \
  --fingerprint 84a033e84196f73bd593fad7a63e509e57fd982f02084359c4e8c5c864efc27d

# Install root CA to system trust store
step certificate install $(step path)/certs/root_ca.crt
```

---

## Use Cases

### 1. Mirror Registry (Harbor/Quay)

Generate certificates for container registry:

```bash
# Request certificate for registry
step ca certificate registry.example.com registry.crt registry.key \
  --san registry.example.com \
  --san registry \
  --not-after 8760h  # 1 year

# Verify certificate
step certificate inspect registry.crt

# Copy to registry server
scp registry.crt registry.key registry-server:/etc/harbor/certs/
```

**Harbor Configuration** (`harbor.yml`):
```yaml
https:
  port: 443
  certificate: /etc/harbor/certs/registry.crt
  private_key: /etc/harbor/certs/registry.key
```

### 2. OpenShift Disconnected Install

Add CA to OpenShift install-config:

```bash
# Get root CA certificate
step ca root root_ca.crt

# Add to install-config.yaml
cat >> install-config.yaml << EOF
additionalTrustBundle: |
$(cat root_ca.crt | sed 's/^/  /')
EOF
```

**install-config.yaml**:
```yaml
apiVersion: v1
baseDomain: example.com
metadata:
  name: ocp4
additionalTrustBundle: |
  -----BEGIN CERTIFICATE-----
  MIIBkTCB+wIJAKHBfpegPjMCMA0GCSqGSIb3DQEBCwUAMBExDzANBgNVBAMMBnJv
  ...
  -----END CERTIFICATE-----
imageContentSources:
- mirrors:
  - registry.example.com:5000/ocp4/openshift4
  source: quay.io/openshift-release-dev/ocp-release
```

### 3. Kubernetes with cert-manager

Install cert-manager and configure Step-CA issuer:

```bash
# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Wait for cert-manager
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=300s
```

**ClusterIssuer for Step-CA (ACME)**:
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: step-ca-issuer
spec:
  acme:
    server: https://step-ca-server.example.com/acme/acme/directory
    privateKeySecretRef:
      name: step-ca-account-key
    solvers:
    - http01:
        ingress:
          class: nginx
```

**Request Certificate**:
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: myapp-tls
  namespace: default
spec:
  secretName: myapp-tls-secret
  issuerRef:
    name: step-ca-issuer
    kind: ClusterIssuer
  commonName: myapp.example.com
  dnsNames:
  - myapp.example.com
  - myapp.default.svc.cluster.local
```

### 4. NGINX/Apache Web Server

```bash
# Request certificate
step ca certificate webserver.example.com server.crt server.key

# NGINX configuration
cat > /etc/nginx/conf.d/ssl.conf << 'EOF'
server {
    listen 443 ssl;
    server_name webserver.example.com;
    
    ssl_certificate /etc/nginx/certs/server.crt;
    ssl_certificate_key /etc/nginx/certs/server.key;
    
    location / {
        root /var/www/html;
    }
}
EOF

# Restart NGINX
systemctl restart nginx
```

### 5. Automatic Certificate Renewal

Using `step` with systemd timer:

```bash
# Create renewal script
cat > /usr/local/bin/renew-cert.sh << 'EOF'
#!/bin/bash
CERT_PATH="/etc/certs"
HOSTNAME=$(hostname -f)

# Renew if expiring within 24 hours
step ca renew --force \
  ${CERT_PATH}/server.crt \
  ${CERT_PATH}/server.key

# Reload service
systemctl reload nginx
EOF

chmod +x /usr/local/bin/renew-cert.sh

# Create systemd timer
cat > /etc/systemd/system/cert-renew.timer << 'EOF'
[Unit]
Description=Certificate Renewal Timer

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/cert-renew.service << 'EOF'
[Unit]
Description=Certificate Renewal Service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/renew-cert.sh
EOF

systemctl enable --now cert-renew.timer
```

### 6. Using ACME with Certbot

```bash
# Install certbot
dnf install certbot

# Get certificate using ACME
certbot certonly \
  --standalone \
  --server https://step-ca-server.example.com/acme/acme/directory \
  --domain myservice.example.com \
  --non-interactive \
  --agree-tos \
  --email admin@example.com \
  --no-verify-ssl

# Certificates saved to:
# /etc/letsencrypt/live/myservice.example.com/fullchain.pem
# /etc/letsencrypt/live/myservice.example.com/privkey.pem
```

### 7. Using ACME with Caddy

Caddy automatically handles ACME:

```json
{
  "apps": {
    "http": {
      "servers": {
        "myserver": {
          "listen": [":443"],
          "routes": [{
            "match": [{"host": ["myservice.example.com"]}],
            "handle": [{
              "handler": "reverse_proxy",
              "upstreams": [{"dial": "localhost:8080"}]
            }]
          }]
        }
      }
    },
    "tls": {
      "automation": {
        "policies": [{
          "subjects": ["myservice.example.com"],
          "issuers": [{
            "module": "acme",
            "ca": "https://step-ca-server.example.com/acme/acme/directory",
            "ca_root": "/etc/caddy/root_ca.crt"
          }]
        }]
      }
    }
  }
}
```

---

## Certificate Types

### Server Certificate (TLS)
```bash
step ca certificate server.example.com server.crt server.key
```

### Client Certificate (mTLS)
```bash
step ca certificate client@example.com client.crt client.key
```

### Wildcard Certificate
```bash
step ca certificate "*.example.com" wildcard.crt wildcard.key \
  --san "*.example.com" \
  --san "example.com"
```

### Certificate with Multiple SANs
```bash
step ca certificate myservice.example.com cert.crt cert.key \
  --san myservice.example.com \
  --san myservice.internal \
  --san 192.168.122.100 \
  --san localhost
```

---

## Troubleshooting

### Check Certificate Details
```bash
step certificate inspect cert.crt
step certificate inspect --short cert.crt
```

### Verify Certificate Chain
```bash
step certificate verify cert.crt --roots root_ca.crt
```

### Check CA Health
```bash
curl -k https://step-ca-server.example.com/health
# {"status":"ok"}
```

### View CA Configuration
```bash
ssh cloud-user@step-ca-server.example.com
cat $(step path)/config/ca.json
```

### List Provisioners
```bash
step ca provisioner list --ca-url https://step-ca-server.example.com
```

---

## Integration with ocp4-disconnected-helper

The `ocp4-disconnected-helper` project uses Step-CA for:

1. **Registry TLS** - Certificates for mirror registry
2. **API Server** - Custom CA for cluster API
3. **Ingress** - Wildcard certificates for routes

See: [ocp4-disconnected-helper documentation](https://github.com/tosin2013/ocp4-disconnected-helper)

---

## Security Best Practices

1. **Short-lived certificates** - Use 24h-720h duration
2. **Automatic renewal** - Configure renewal before expiry
3. **Protect root key** - Store in HSM for production
4. **Audit logging** - Enable CA audit logs
5. **Network isolation** - Restrict CA access to internal networks
