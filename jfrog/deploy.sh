#!/bin/bash
# JFrog Artifactory Deployment Script
# Usage: ./deploy.sh [create|delete|status|health]
#
# Environment Variables:
#   JFROG_VERSION       - JFrog Artifactory version (e.g., 7.77.5)
#   JFROG_EDITION       - Edition: oss (Open Source) or pro (default: oss)
#   CERT_MODE           - Certificate mode: step-ca or self-signed (default: step-ca)
#   CA_URL              - Step-CA URL (for step-ca mode)
#   FINGERPRINT         - Step-CA fingerprint (for step-ca mode)
#   VM_NAME             - Custom VM name (default: jfrog)
#   NET_NAME            - Primary network (default: default - has DHCP)
#   ISOLATED_NET_NAME   - Secondary isolated network (e.g., 1924)
#   ISOLATED_IP         - Static IP for isolated network (e.g., 192.168.49.30)
#   ISOLATED_GATEWAY    - Gateway for isolated network (e.g., 192.168.49.1)
#
# Dual-NIC Architecture:
#   eth0 - Primary network (default) with DHCP for management
#   eth1 - Isolated network (1924) with static IP for disconnected OpenShift
#
# This script deploys JFrog Artifactory container registry for:
# - Universal artifact repository
# - Docker, Maven, npm, PyPI, and more
# - Enterprise artifact management

set -euo pipefail
export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

# Preserve environment variables passed from caller BEFORE sourcing defaults
_PASSED_NET_NAME="${NET_NAME:-}"
_PASSED_DOMAIN="${DOMAIN:-}"
_PASSED_ISOLATED_NET="${ISOLATED_NET_NAME:-}"
_PASSED_ISOLATED_IP="${ISOLATED_IP:-}"
_PASSED_ISOLATED_GW="${ISOLATED_GATEWAY:-}"

# Default values
ACTION="${1:-create}"
VM_NAME="${VM_NAME:-jfrog}"
JFROG_VERSION="${JFROG_VERSION:-7.77.5}"
JFROG_EDITION="${JFROG_EDITION:-oss}"
CERT_MODE="${CERT_MODE:-step-ca}"

# Source environment
if [ -f /opt/kcli-pipelines/helper_scripts/default.env ]; then
    source /opt/kcli-pipelines/helper_scripts/default.env
elif [ -f helper_scripts/default.env ]; then
    source helper_scripts/default.env
else
    echo "[ERROR] default.env file not found"
    exit 1
fi

# Restore passed environment variables (override defaults)
[ -n "$_PASSED_NET_NAME" ] && NET_NAME="$_PASSED_NET_NAME"
[ -n "$_PASSED_DOMAIN" ] && DOMAIN="$_PASSED_DOMAIN"
[ -n "$_PASSED_ISOLATED_NET" ] && ISOLATED_NET_NAME="$_PASSED_ISOLATED_NET"
[ -n "$_PASSED_ISOLATED_IP" ] && ISOLATED_IP="$_PASSED_ISOLATED_IP"
[ -n "$_PASSED_ISOLATED_GW" ] && ISOLATED_GATEWAY="$_PASSED_ISOLATED_GW"

# Source helper functions if available
if [ -f /opt/kcli-pipelines/helper_scripts/helper_functions.sh ]; then
    source /opt/kcli-pipelines/helper_scripts/helper_functions.sh
elif [ -f helper_scripts/helper_functions.sh ]; then
    source helper_scripts/helper_functions.sh
fi

# Set defaults for networks
NET_NAME="${NET_NAME:-default}"
ISOLATED_NET_NAME="${ISOLATED_NET_NAME:-}"
ISOLATED_IP="${ISOLATED_IP:-}"
ISOLATED_GATEWAY="${ISOLATED_GATEWAY:-192.168.49.1}"

# Get domain from ansible variables
DOMAIN=$(yq eval '.domain' "${ANSIBLE_ALL_VARIABLES}" 2>/dev/null || echo "example.com")

echo "========================================"
echo "JFrog Artifactory Deployment"
echo "========================================"
echo "Action: ${ACTION}"
echo "VM Name: ${VM_NAME}"
echo "Domain: ${DOMAIN}"
echo "JFrog Version: ${JFROG_VERSION}"
echo "JFrog Edition: ${JFROG_EDITION}"
echo "Certificate Mode: ${CERT_MODE}"
echo "Primary Network: ${NET_NAME}"
if [ -n "${ISOLATED_NET_NAME}" ]; then
    echo "Isolated Network: ${ISOLATED_NET_NAME}"
    echo "Isolated IP: ${ISOLATED_IP:-auto}"
    echo "Isolated Gateway: ${ISOLATED_GATEWAY}"
fi
echo "========================================"

function check_prerequisites() {
    echo "[INFO] Checking prerequisites..."
    
    # Check kcli
    if ! command -v kcli &>/dev/null; then
        echo "[ERROR] kcli not found"
        exit 1
    fi
    echo "[OK] kcli available"
    
    # Check for RHEL9 image
    IMAGE="centos9stream"
    if ! kcli list image | grep -q "$IMAGE"; then
        echo "[WARN] Image $IMAGE not found"
        echo "Download with: kcli download image $IMAGE"
    else
        echo "[OK] RHEL9 image available"
    fi
    
    # Check certificate prerequisites
    if [ "$CERT_MODE" == "step-ca" ]; then
        # Check Step-CA server
        if [ -z "${CA_URL:-}" ] || [ -z "${FINGERPRINT:-}" ]; then
            STEP_CA_IP=$(kcli info vm step-ca-server 2>/dev/null | grep 'ip:' | awk '{print $2}' | head -1)
            if [ -n "$STEP_CA_IP" ]; then
                echo "[INFO] Found Step-CA server at ${STEP_CA_IP}"
                CA_URL="${CA_URL:-https://${STEP_CA_IP}:443}"
                if [ -z "${FINGERPRINT:-}" ]; then
                    FINGERPRINT=$(ssh -o StrictHostKeyChecking=no root@${STEP_CA_IP} \
                        "step certificate fingerprint /root/.step/certs/root_ca.crt 2>/dev/null" || true)
                fi
                echo "[OK] CA_URL: ${CA_URL}"
                echo "[OK] Fingerprint: ${FINGERPRINT:-NOT_FOUND}"
            else
                echo "[ERROR] Step-CA server not found and CA_URL/FINGERPRINT not set"
                echo "Deploy Step-CA first or use CERT_MODE=self-signed"
                exit 1
            fi
        fi
    fi
    
    echo "[OK] Prerequisites check complete"
}

function create_jfrog() {
    echo "[INFO] Creating JFrog Artifactory..."
    
    # Check if VM already exists
    if kcli list vm | grep -q "${VM_NAME}"; then
        echo "[INFO] VM ${VM_NAME} already exists"
        kcli info vm "${VM_NAME}"
        return 0
    fi
    
    IMAGE="centos9stream"
    LOGIN_USER="cloud-user"
    
    # Get FreeIPA DNS IP
    FREEIPA_IP=$(kcli info vm freeipa 2>/dev/null | grep 'ip:' | awk '{print $2}' | head -1)
    if [ -z "$FREEIPA_IP" ]; then
        FREEIPA_IP="8.8.8.8"
        echo "[WARN] FreeIPA not found, using ${FREEIPA_IP} for DNS"
    else
        echo "[INFO] Using FreeIPA DNS: ${FREEIPA_IP}"
    fi
    
    # Get password from vault or use default
    PASSWORD=$(yq eval '.admin_user_password' "${ANSIBLE_VAULT_FILE}" 2>/dev/null || echo "password")
    
    echo "[INFO] Creating VM ${VM_NAME}..."
    
    # Build network configuration - dual NIC if isolated network specified
    if [ -n "${ISOLATED_NET_NAME}" ] && [ -n "${ISOLATED_IP}" ]; then
        echo "[INFO] Configuring dual-NIC: ${NET_NAME} (DHCP) + ${ISOLATED_NET_NAME} (${ISOLATED_IP})"
        NETS_CONFIG="[{\"name\": \"${NET_NAME}\"}, {\"name\": \"${ISOLATED_NET_NAME}\", \"ip\": \"${ISOLATED_IP}\", \"mask\": \"255.255.255.0\", \"gateway\": \"${ISOLATED_GATEWAY}\"}]"
    else
        echo "[INFO] Configuring single NIC: ${NET_NAME}"
        NETS_CONFIG="[{\"name\": \"${NET_NAME}\"}]"
    fi
    
    # Create VM using kcli with dual-NIC support (minimal cmds - install packages after DNS fix)
    kcli create vm "${VM_NAME}" \
        -i "${IMAGE}" \
        -P numcpus=4 \
        -P memory=8192 \
        -P disks="[300]" \
        -P nets="${NETS_CONFIG}" \
        -P cmds="[\"echo ${PASSWORD} | passwd --stdin root\"]" \
        --wait
    
    # Wait for VM to get IP
    echo "[INFO] Waiting for VM to get IP..."
    sleep 30
    
    # Get VM IP (primary interface)
    IP=$(kcli info vm "${VM_NAME}" | grep 'ip:' | awk '{print $2}' | head -1)
    echo "[INFO] VM Primary IP: ${IP}"
    
    if [ -z "$IP" ] || [ "$IP" == "None" ]; then
        echo "[ERROR] VM did not get an IP address"
        return 1
    fi
    
    # Wait for SSH
    echo "[INFO] Waiting for SSH..."
    MAX_ATTEMPTS=30
    ATTEMPT=0
    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        ATTEMPT=$((ATTEMPT + 1))
        if nc -z -w5 "${IP}" 22 2>/dev/null; then
            echo "[OK] SSH is available"
            break
        fi
        echo "[INFO] Waiting for SSH... (${ATTEMPT}/${MAX_ATTEMPTS})"
        sleep 10
    done
    
    # Fix DNS to use external resolvers (avoid FreeIPA search domain issues)
    echo "[INFO] Configuring DNS resolvers..."
    ssh -o StrictHostKeyChecking=no root@${IP} bash -s <<'DNSEOF'
cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
echo "[OK] DNS configured"
DNSEOF
    
    # Install required packages
    echo "[INFO] Installing required packages..."
    ssh -o StrictHostKeyChecking=no root@${IP} \
        "dnf install -y curl wget git jq podman java-11-openjdk-headless firewalld" || \
        echo "[WARN] Some packages may have failed to install"
    
    # Configure second NIC if dual-NIC mode
    if [ -n "${ISOLATED_NET_NAME}" ] && [ -n "${ISOLATED_IP}" ]; then
        echo "[INFO] Configuring isolated network interface..."
        ssh -o StrictHostKeyChecking=no root@${IP} bash -s <<EOF
# Find second NIC
SECOND_NIC=\$(ip -o link show | awk -F': ' '{print \$2}' | grep -v lo | tail -1)
if [ -n "\$SECOND_NIC" ]; then
    echo "Configuring \$SECOND_NIC with IP ${ISOLATED_IP}"
    nmcli con add type ethernet con-name isolated ifname \$SECOND_NIC ip4 ${ISOLATED_IP}/24 gw4 ${ISOLATED_GATEWAY} || true
    nmcli con up isolated || true
    echo "[OK] Isolated network configured"
else
    echo "[WARN] Second NIC not found"
fi
EOF
    fi
    
    # Configure JFrog Artifactory
    echo "[INFO] Configuring JFrog Artifactory on VM..."
    
    # Install JFrog using Podman
    ssh -o StrictHostKeyChecking=no root@${IP} bash -s <<EOF
echo "[INFO] Setting up JFrog Artifactory ${JFROG_EDITION} v${JFROG_VERSION}..."

# Create directories
mkdir -p /opt/jfrog/artifactory/var/etc
mkdir -p /opt/jfrog/artifactory/var/data
mkdir -p /opt/jfrog/artifactory/var/logs
chmod -R 777 /opt/jfrog/artifactory/var

# Create system.yaml
cat > /opt/jfrog/artifactory/var/etc/system.yaml <<YAML
configVersion: 1
shared:
  database:
    type: derby
  node:
    id: jfrog-node-1
YAML

# Pull and run JFrog Artifactory
JFROG_IMAGE="releases-docker.jfrog.io/jfrog/artifactory-${JFROG_EDITION}:${JFROG_VERSION}"
echo "[INFO] Pulling \$JFROG_IMAGE..."
podman pull \$JFROG_IMAGE

echo "[INFO] Starting JFrog Artifactory container..."
podman run -d --name artifactory \
    -p 8081:8081 \
    -p 8082:8082 \
    -v /opt/jfrog/artifactory/var:/var/opt/jfrog/artifactory:Z \
    \$JFROG_IMAGE

# Enable firewall ports
firewall-cmd --permanent --add-port=8081/tcp || true
firewall-cmd --permanent --add-port=8082/tcp || true
firewall-cmd --reload || true

echo "[OK] JFrog Artifactory started"
EOF

    # Configure TLS certificates if step-ca mode
    if [ "$CERT_MODE" == "step-ca" ]; then
        echo "[INFO] Configuring Step-CA certificates..."
        STEP_CA_IP=$(echo $CA_URL | sed 's|https://||' | sed 's|:.*||')
        
        # Install step CLI and bootstrap on JFrog VM
        ssh -o StrictHostKeyChecking=no root@${IP} bash -s <<EOF
# Install step CLI
wget -q https://dl.smallstep.com/cli/docs-ca-install/latest/step-cli_amd64.rpm -O /tmp/step-cli.rpm
rpm -i /tmp/step-cli.rpm || rpm -U /tmp/step-cli.rpm || true

# Bootstrap step-ca
step ca bootstrap --ca-url ${CA_URL} --fingerprint ${FINGERPRINT} --install

# Create certs directory
mkdir -p /opt/jfrog/certs
EOF
        
        # Get certificate token from hypervisor (has SSH access to Step-CA)
        echo "[INFO] Requesting certificate token from Step-CA..."
        TOKEN=$(ssh -o StrictHostKeyChecking=no root@${STEP_CA_IP} \
            "step ca token jfrog.${DOMAIN} --ca-url https://localhost:443 --password-file /etc/step/initial_password --provisioner admin@example.com" | tail -1)
        
        if [ -z "$TOKEN" ]; then
            echo "[WARN] Failed to get certificate token from Step-CA"
        else
            # Request certificate on JFrog VM using the token
            echo "[INFO] Requesting certificate on JFrog VM..."
            ssh -o StrictHostKeyChecking=no root@${IP} \
                "step ca certificate jfrog.${DOMAIN} /opt/jfrog/certs/jfrog.crt /opt/jfrog/certs/jfrog.key --ca-url ${CA_URL} --token '${TOKEN}' --force && \
                 echo '[OK] Step-CA certificates configured'"
        fi
    fi
    
    echo ""
    echo "========================================"
    echo "JFrog Artifactory Deployment Complete"
    echo "========================================"
    echo "VM Name: ${VM_NAME}"
    echo "Primary IP (management): ${IP}"
    if [ -n "${ISOLATED_NET_NAME}" ] && [ -n "${ISOLATED_IP}" ]; then
        echo "Isolated IP (disconnected): ${ISOLATED_IP}"
    fi
    echo "JFrog URL: http://${IP}:8082"
    echo "JFrog Edition: ${JFROG_EDITION}"
    echo ""
    echo "Default credentials:"
    echo "  User: admin"
    echo "  Password: password"
    echo ""
    echo "To verify: curl http://${IP}:8082/artifactory/api/system/ping"
    echo "========================================"
}

function delete_jfrog() {
    echo "[INFO] Deleting JFrog Artifactory..."
    
    if ! kcli list vm | grep -q "${VM_NAME}"; then
        echo "[INFO] VM ${VM_NAME} does not exist"
        return 0
    fi
    
    # Delete VM
    kcli delete vm "${VM_NAME}" -y
    
    echo "[OK] JFrog Artifactory deleted"
}

function check_health() {
    echo "[INFO] Checking JFrog Artifactory Health..."
    
    if ! kcli list vm | grep -q "${VM_NAME}"; then
        echo "[ERROR] VM ${VM_NAME} does not exist"
        return 1
    fi
    
    IP=$(kcli info vm "${VM_NAME}" | grep 'ip:' | awk '{print $2}' | head -1)
    
    if [ -z "$IP" ]; then
        echo "[ERROR] Could not get VM IP"
        return 1
    fi
    
    echo "VM IP: ${IP}"
    
    # Check JFrog health endpoint
    echo ""
    echo "JFrog Artifactory Health Check:"
    HEALTH=$(curl -s "http://${IP}:8082/artifactory/api/system/ping" 2>/dev/null)
    
    if echo "$HEALTH" | grep -qi "OK"; then
        echo "[OK] JFrog Artifactory is HEALTHY"
        echo "Response: $HEALTH"
        return 0
    else
        echo "[WARN] JFrog Artifactory may not be healthy"
        echo "Response: $HEALTH"
        
        # Check if container is running
        echo ""
        echo "Checking container status..."
        ssh -o StrictHostKeyChecking=no root@${IP} \
            "podman ps --filter name=artifactory 2>/dev/null" || true
        return 1
    fi
}

function show_status() {
    echo "[INFO] JFrog Artifactory Status"
    
    echo ""
    echo "JFrog VMs:"
    kcli list vm | grep -E "jfrog|Name" || echo "No JFrog VMs found"
    
    if kcli list vm | grep -q "${VM_NAME}"; then
        echo ""
        echo "VM Details:"
        kcli info vm "${VM_NAME}"
        
        IP=$(kcli info vm "${VM_NAME}" | grep 'ip:' | awk '{print $2}' | head -1)
        if [ -n "$IP" ]; then
            echo ""
            check_health
        fi
    fi
}

# Main
case "${ACTION}" in
    create)
        check_prerequisites
        create_jfrog
        ;;
    delete|destroy)
        delete_jfrog
        ;;
    status)
        show_status
        ;;
    health)
        check_health
        ;;
    *)
        echo "Usage: $0 [create|delete|status|health]"
        exit 1
        ;;
esac
