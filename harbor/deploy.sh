#!/bin/bash
# Harbor Registry Deployment Script
# Usage: ./deploy.sh [create|delete|status|health]
#
# Environment Variables:
#   HARBOR_VERSION    - Harbor version (e.g., v2.10.1)
#   CERT_MODE         - Certificate mode: step-ca or letsencrypt (default: step-ca)
#   CA_URL            - Step-CA URL (for step-ca mode)
#   FINGERPRINT       - Step-CA fingerprint (for step-ca mode)
#   AWS_ACCESS_KEY_ID - AWS access key (for letsencrypt mode)
#   AWS_SECRET_ACCESS_KEY - AWS secret key (for letsencrypt mode)
#   EMAIL             - Email for Let's Encrypt (for letsencrypt mode)
#   VM_NAME           - Custom VM name (default: harbor)
#   NET_NAME          - Network to deploy on
#
# This script deploys Harbor container registry for:
# - Enterprise container image management
# - Image scanning and signing
# - Multi-tenant registry

set -euo pipefail
export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

# Default values
ACTION="${1:-create}"
VM_NAME="${VM_NAME:-harbor}"
HARBOR_VERSION="${HARBOR_VERSION:-v2.10.1}"
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
echo "Harbor Registry Deployment"
echo "========================================"
echo "Action: ${ACTION}"
echo "VM Name: ${VM_NAME}"
echo "Domain: ${DOMAIN}"
echo "Harbor Version: ${HARBOR_VERSION}"
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
    
    # Check for Ubuntu image (Harbor uses Docker which works better on Ubuntu)
    IMAGE="ubuntu2204"
    if ! kcli list image | grep -q "$IMAGE"; then
        echo "[WARN] Image $IMAGE not found"
        echo "Download with: kcli download image $IMAGE"
    else
        echo "[OK] Ubuntu 22.04 image available"
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
                    FINGERPRINT=$(ssh -o StrictHostKeyChecking=no cloud-user@${STEP_CA_IP} \
                        "sudo step certificate fingerprint /root/.step/certs/root_ca.crt 2>/dev/null" || true)
                fi
                echo "[OK] CA_URL: ${CA_URL}"
                echo "[OK] Fingerprint: ${FINGERPRINT:-NOT_FOUND}"
            else
                echo "[ERROR] Step-CA server not found and CA_URL/FINGERPRINT not set"
                echo "Deploy Step-CA first or use CERT_MODE=letsencrypt"
                exit 1
            fi
        fi
    elif [ "$CERT_MODE" == "letsencrypt" ]; then
        if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ] || [ -z "${EMAIL:-}" ]; then
            echo "[ERROR] Let's Encrypt mode requires AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and EMAIL"
            exit 1
        fi
        echo "[OK] Let's Encrypt credentials provided"
    fi
    
    echo "[OK] Prerequisites check complete"
}

function create_harbor() {
    echo "[INFO] Creating Harbor registry..."
    
    # Check if VM already exists
    if kcli list vm | grep -q "${VM_NAME}"; then
        echo "[INFO] VM ${VM_NAME} already exists"
        kcli info vm "${VM_NAME}"
        return 0
    fi
    
    IMAGE="ubuntu2204"
    LOGIN_USER="ubuntu"
    
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
        -P disks="[300]" \
        -P nets="[{\"name\": \"${NET_NAME:-qubinet}\"}]" \
        -P dns="${FREEIPA_IP}" \
        -P cmds="[\"apt-get update\", \"apt-get install -y curl wget git jq\"]" \
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
    
    # Copy and run configuration script
    echo "[INFO] Configuring Harbor on VM..."
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    scp -o StrictHostKeyChecking=no "${SCRIPT_DIR}/harbor.sh" ${LOGIN_USER}@${IP}:/tmp/
    
    # Prepare configuration based on certificate mode
    if [ "$CERT_MODE" == "step-ca" ]; then
        echo "[INFO] Configuring Harbor with Step-CA certificates..."
        
        # First bootstrap step-ca on the Harbor VM
        ssh -o StrictHostKeyChecking=no ${LOGIN_USER}@${IP} \
            "wget -q https://dl.smallstep.com/cli/docs-ca-install/latest/step-cli_amd64.deb && \
             sudo dpkg -i step-cli_amd64.deb && \
             step ca bootstrap --ca-url ${CA_URL} --fingerprint ${FINGERPRINT} --install"
        
        # Request certificate for Harbor
        STEP_CA_IP=$(echo $CA_URL | sed 's|https://||' | sed 's|:.*||')
        ssh -o StrictHostKeyChecking=no ${LOGIN_USER}@${IP} \
            "sudo mkdir -p /etc/harbor/certs && \
             TOKEN=\$(ssh -o StrictHostKeyChecking=no cloud-user@${STEP_CA_IP} \
                'sudo step ca token harbor.${DOMAIN} --ca-url https://localhost:443 --password-file /etc/step/initial_password --provisioner admin@example.com' | tail -1) && \
             step ca certificate harbor.${DOMAIN} /tmp/harbor.crt /tmp/harbor.key --ca-url ${CA_URL} --token \"\$TOKEN\" --force && \
             sudo mv /tmp/harbor.crt /etc/harbor/certs/ && \
             sudo mv /tmp/harbor.key /etc/harbor/certs/"
        
        # Install Harbor with step-ca certs
        ssh -o StrictHostKeyChecking=no ${LOGIN_USER}@${IP} \
            "chmod +x /tmp/harbor.sh && \
             export CERT_MODE=step-ca && \
             export HARBOR_VERSION=${HARBOR_VERSION} && \
             export DOMAIN=${DOMAIN} && \
             sudo -E /tmp/harbor-install-stepca.sh ${DOMAIN} ${HARBOR_VERSION}" || \
            echo "[WARN] Harbor configuration may need manual completion"
    else
        # Let's Encrypt mode
        echo "[INFO] Configuring Harbor with Let's Encrypt certificates..."
        ssh -o StrictHostKeyChecking=no ${LOGIN_USER}@${IP} \
            "chmod +x /tmp/harbor.sh && \
             sudo /tmp/harbor.sh ${DOMAIN} ${HARBOR_VERSION} ${AWS_ACCESS_KEY_ID} ${AWS_SECRET_ACCESS_KEY} ${EMAIL} ${GUID:-harbor}" || \
            echo "[WARN] Harbor configuration may need manual completion"
    fi
    
    echo ""
    echo "========================================"
    echo "Harbor Deployment Complete"
    echo "========================================"
    echo "VM Name: ${VM_NAME}"
    echo "IP Address: ${IP}"
    echo "Harbor URL: https://harbor.${DOMAIN}"
    echo ""
    echo "Default credentials:"
    echo "  User: admin"
    echo "  Password: Harbor12345"
    echo ""
    echo "To verify: curl -k https://${IP}/api/v2.0/health"
    echo "========================================"
}

function delete_harbor() {
    echo "[INFO] Deleting Harbor registry..."
    
    if ! kcli list vm | grep -q "${VM_NAME}"; then
        echo "[INFO] VM ${VM_NAME} does not exist"
        return 0
    fi
    
    # Delete VM
    kcli delete vm "${VM_NAME}" -y
    
    echo "[OK] Harbor registry deleted"
}

function check_health() {
    echo "[INFO] Checking Harbor Health..."
    
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
    
    # Check Harbor health endpoint
    echo ""
    echo "Harbor Health Check:"
    HEALTH=$(curl -sk "https://${IP}/api/v2.0/health" 2>/dev/null)
    
    if echo "$HEALTH" | grep -qi "healthy"; then
        echo "[OK] Harbor is HEALTHY"
        echo "$HEALTH" | jq . 2>/dev/null || echo "$HEALTH"
        return 0
    else
        echo "[WARN] Harbor may not be healthy"
        echo "Response: $HEALTH"
        
        # Check if Docker is running
        echo ""
        echo "Checking container status..."
        ssh -o StrictHostKeyChecking=no ubuntu@${IP} \
            "sudo docker ps --filter name=harbor 2>/dev/null" || true
        return 1
    fi
}

function show_status() {
    echo "[INFO] Harbor Status"
    
    echo ""
    echo "Harbor VMs:"
    kcli list vm | grep -E "harbor|Name" || echo "No Harbor VMs found"
    
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
        create_harbor
        ;;
    delete|destroy)
        delete_harbor
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

