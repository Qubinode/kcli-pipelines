#!/bin/bash
# JFrog Artifactory Deployment Script
# Usage: ./deploy.sh [create|delete|status|health]
#
# Environment Variables:
#   JFROG_VERSION     - JFrog Artifactory version (e.g., 7.77.5)
#   JFROG_EDITION     - Edition: oss (Open Source) or pro (default: oss)
#   CERT_MODE         - Certificate mode: step-ca or self-signed (default: step-ca)
#   CA_URL            - Step-CA URL (for step-ca mode)
#   FINGERPRINT       - Step-CA fingerprint (for step-ca mode)
#   VM_NAME           - Custom VM name (default: jfrog)
#   NET_NAME          - Network to deploy on
#
# This script deploys JFrog Artifactory container registry for:
# - Universal artifact repository
# - Docker, Maven, npm, PyPI, and more
# - Enterprise artifact management

set -euo pipefail
export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

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

# Source helper functions if available
if [ -f /opt/kcli-pipelines/helper_scripts/helper_functions.sh ]; then
    source /opt/kcli-pipelines/helper_scripts/helper_functions.sh
elif [ -f helper_scripts/helper_functions.sh ]; then
    source helper_scripts/helper_functions.sh
fi

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
echo "Network: ${NET_NAME:-qubinet}"
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
    IMAGE="rhel9"
    if ! kcli list image | grep -q "$IMAGE"; then
        echo "[WARN] Image $IMAGE not found"
        echo "Download with: kcli download image $IMAGE"
    else
        echo "[OK] RHEL9 image available"
    fi
    
    # Check certificate prerequisites
    if [ "$CERT_MODE" == "step-ca" ]; then
        if [ -z "${CA_URL:-}" ] || [ -z "${FINGERPRINT:-}" ]; then
            STEP_CA_IP=$(kcli info vm step-ca-server 2>/dev/null | grep 'ip:' | awk '{print $2}' | head -1)
            if [ -n "$STEP_CA_IP" ]; then
                echo "[INFO] Found Step-CA server at ${STEP_CA_IP}"
                CA_URL="${CA_URL:-https://${STEP_CA_IP}:443}"
                if [ -z "${FINGERPRINT:-}" ]; then
                    FINGERPRINT=$(ssh -o StrictHostKeyChecking=no cloud-user@${STEP_CA_IP} \
                        "sudo step certificate fingerprint /root/.step/certs/root_ca.crt 2>/dev/null" || true)
                fi
                echo "[OK] CA_URL: ${CA_URL}"
                echo "[OK] Fingerprint: ${FINGERPRINT:-NOT_FOUND}"
            else
                echo "[WARN] Step-CA server not found, will use self-signed certificates"
                CERT_MODE="self-signed"
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
    
    IMAGE="rhel9"
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
    
    # Create VM using kcli
    kcli create vm "${VM_NAME}" \
        -i "${IMAGE}" \
        -P numcpus=4 \
        -P memory=8192 \
        -P disks="[100]" \
        -P nets="[{\"name\": \"${NET_NAME:-qubinet}\"}]" \
        -P dns="${FREEIPA_IP}" \
        -P cmds="[\"echo ${PASSWORD} | passwd --stdin root\", \"dnf install -y podman podman-docker curl wget git jq firewalld\", \"systemctl enable --now firewalld podman\", \"firewall-cmd --permanent --add-port=8081/tcp --add-port=8082/tcp --add-port=443/tcp\", \"firewall-cmd --reload\"]" \
        --wait
    
    # Wait for VM to get IP
    echo "[INFO] Waiting for VM to get IP..."
    sleep 30
    
    # Get VM IP
    IP=$(kcli info vm "${VM_NAME}" | grep 'ip:' | awk '{print $2}' | head -1)
    echo "[INFO] VM IP: ${IP}"
    
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
    
    # Configure JFrog Artifactory
    echo "[INFO] Configuring JFrog Artifactory..."
    
    # Set hostname
    ssh -o StrictHostKeyChecking=no ${LOGIN_USER}@${IP} \
        "sudo hostnamectl set-hostname jfrog.${DOMAIN}"
    
    # Create directories
    ssh -o StrictHostKeyChecking=no ${LOGIN_USER}@${IP} \
        "sudo mkdir -p /opt/jfrog/artifactory/var/{etc,data,backup} && \
         sudo chown -R 1030:1030 /opt/jfrog"
    
    # Configure certificates
    if [ "$CERT_MODE" == "step-ca" ]; then
        echo "[INFO] Configuring Step-CA certificates..."
        
        # Bootstrap Step-CA on JFrog VM
        STEP_CA_IP=$(echo $CA_URL | sed 's|https://||' | sed 's|:.*||')
        ssh -o StrictHostKeyChecking=no ${LOGIN_USER}@${IP} \
            "wget -q https://dl.smallstep.com/cli/docs-ca-install/latest/step-cli_amd64.rpm && \
             sudo rpm -i step-cli_amd64.rpm && \
             step ca bootstrap --ca-url ${CA_URL} --fingerprint ${FINGERPRINT} --install"
        
        # Request certificate
        ssh -o StrictHostKeyChecking=no ${LOGIN_USER}@${IP} \
            "sudo mkdir -p /opt/jfrog/artifactory/var/etc/security && \
             TOKEN=\$(ssh -o StrictHostKeyChecking=no cloud-user@${STEP_CA_IP} \
                'sudo step ca token jfrog.${DOMAIN} --ca-url https://localhost:443 --password-file /etc/step/initial_password --provisioner admin@example.com' | tail -1) && \
             step ca certificate jfrog.${DOMAIN} /tmp/jfrog.crt /tmp/jfrog.key --ca-url ${CA_URL} --token \"\$TOKEN\" --force && \
             sudo mv /tmp/jfrog.crt /opt/jfrog/artifactory/var/etc/security/ && \
             sudo mv /tmp/jfrog.key /opt/jfrog/artifactory/var/etc/security/ && \
             sudo chown 1030:1030 /opt/jfrog/artifactory/var/etc/security/*"
    else
        echo "[INFO] Generating self-signed certificate..."
        ssh -o StrictHostKeyChecking=no ${LOGIN_USER}@${IP} \
            "sudo mkdir -p /opt/jfrog/artifactory/var/etc/security && \
             sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout /opt/jfrog/artifactory/var/etc/security/jfrog.key \
                -out /opt/jfrog/artifactory/var/etc/security/jfrog.crt \
                -subj '/CN=jfrog.${DOMAIN}' && \
             sudo chown 1030:1030 /opt/jfrog/artifactory/var/etc/security/*"
    fi
    
    # Create system.yaml for Artifactory
    ssh -o StrictHostKeyChecking=no ${LOGIN_USER}@${IP} \
        "cat << 'EOF' | sudo tee /opt/jfrog/artifactory/var/etc/system.yaml
configVersion: 1
shared:
  security:
    joinKey: \"your-join-key-here\"
  node:
    id: \"jfrog-node\"
router:
  entryPoints:
    internalPort: 8046
access:
  database:
    type: derby
artifactory:
  database:
    type: derby
EOF
sudo chown 1030:1030 /opt/jfrog/artifactory/var/etc/system.yaml"
    
    # Run Artifactory container
    echo "[INFO] Starting JFrog Artifactory container..."
    if [ "$JFROG_EDITION" == "oss" ]; then
        JFROG_IMAGE="releases-docker.jfrog.io/jfrog/artifactory-oss:${JFROG_VERSION}"
    else
        JFROG_IMAGE="releases-docker.jfrog.io/jfrog/artifactory-pro:${JFROG_VERSION}"
    fi
    
    ssh -o StrictHostKeyChecking=no ${LOGIN_USER}@${IP} \
        "sudo podman run -d --name artifactory \
            -p 8081:8081 -p 8082:8082 \
            -v /opt/jfrog/artifactory/var:/var/opt/jfrog/artifactory:Z \
            --restart=always \
            ${JFROG_IMAGE}" || \
        echo "[WARN] Container may need manual configuration"
    
    # Wait for Artifactory to start
    echo "[INFO] Waiting for Artifactory to start (this may take 2-3 minutes)..."
    sleep 120
    
    echo ""
    echo "========================================"
    echo "JFrog Artifactory Deployment Complete"
    echo "========================================"
    echo "VM Name: ${VM_NAME}"
    echo "IP Address: ${IP}"
    echo "Artifactory URL: http://${IP}:8082/artifactory"
    echo "UI URL: http://${IP}:8082/ui"
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
    
    # Check Artifactory ping endpoint
    echo ""
    echo "Artifactory Health Check:"
    PING=$(curl -s "http://${IP}:8082/artifactory/api/system/ping" 2>/dev/null)
    
    if echo "$PING" | grep -qi "OK"; then
        echo "[OK] Artifactory is HEALTHY"
        echo "Ping: $PING"
        
        # Get system info
        echo ""
        echo "System Info:"
        curl -s "http://${IP}:8082/artifactory/api/system/version" 2>/dev/null | jq . || true
        return 0
    else
        echo "[WARN] Artifactory may not be healthy"
        echo "Response: $PING"
        
        # Check if container is running
        echo ""
        echo "Checking container status..."
        ssh -o StrictHostKeyChecking=no cloud-user@${IP} \
            "sudo podman ps --filter name=artifactory 2>/dev/null" || true
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

