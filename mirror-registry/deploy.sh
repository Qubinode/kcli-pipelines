#!/bin/bash
# Mirror-Registry (Quay) Deployment Script
# Usage: ./deploy.sh [create|delete|status|health]
#
# Environment Variables:
#   QUAY_VERSION      - Quay mirror-registry version (e.g., v1.3.11)
#   CA_URL            - Step-CA URL for certificates
#   FINGERPRINT       - Step-CA fingerprint
#   STEP_CA_PASSWORD  - Step-CA password
#   VM_NAME           - Custom VM name (default: mirror-registry)
#   NET_NAME          - Network to deploy on (default: from default.env)
#
# This script deploys a Quay mirror-registry for:
# - Disconnected OpenShift installs
# - Container image mirroring
# - Air-gapped environments

set -euo pipefail
export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

# Default values
ACTION="${1:-create}"
VM_NAME="${VM_NAME:-mirror-registry}"
QUAY_VERSION="${QUAY_VERSION:-v1.3.11}"

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
echo "Mirror-Registry Deployment"
echo "========================================"
echo "Action: ${ACTION}"
echo "VM Name: ${VM_NAME}"
echo "Domain: ${DOMAIN}"
echo "Quay Version: ${QUAY_VERSION}"
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
    
    # Check for RHEL image
    IMAGE="rhel8"
    if ! kcli list image | grep -q "$IMAGE"; then
        echo "[WARN] Image $IMAGE not found"
        echo "Download with: kcli download image $IMAGE"
    else
        echo "[OK] RHEL8 image available"
    fi
    
    # Check Step-CA server
    if [ -z "${CA_URL:-}" ] || [ -z "${FINGERPRINT:-}" ]; then
        # Try to auto-detect from step-ca-server VM
        STEP_CA_IP=$(kcli info vm step-ca-server 2>/dev/null | grep 'ip:' | awk '{print $2}' | head -1)
        if [ -n "$STEP_CA_IP" ]; then
            echo "[INFO] Found Step-CA server at ${STEP_CA_IP}"
            CA_URL="${CA_URL:-https://${STEP_CA_IP}:443}"
            # Get fingerprint
            if [ -z "${FINGERPRINT:-}" ]; then
                FINGERPRINT=$(ssh -o StrictHostKeyChecking=no cloud-user@${STEP_CA_IP} \
                    "sudo step certificate fingerprint /root/.step/certs/root_ca.crt 2>/dev/null" || true)
            fi
            echo "[OK] CA_URL: ${CA_URL}"
            echo "[OK] Fingerprint: ${FINGERPRINT:-NOT_FOUND}"
        else
            echo "[ERROR] Step-CA server not found and CA_URL/FINGERPRINT not set"
            echo "Deploy Step-CA first: airflow dags trigger step_ca_deployment"
            exit 1
        fi
    fi
    
    echo "[OK] Prerequisites check complete"
}

function create_mirror_registry() {
    echo "[INFO] Creating Mirror-Registry..."
    
    # Check if VM already exists
    if kcli list vm | grep -q "${VM_NAME}"; then
        echo "[INFO] VM ${VM_NAME} already exists"
        kcli info vm "${VM_NAME}"
        return 0
    fi
    
    IMAGE="rhel8"
    LOGIN_USER="cloud-user"
    
    # Get FreeIPA DNS IP
    FREEIPA_IP=$(kcli info vm freeipa 2>/dev/null | grep 'ip:' | awk '{print $2}' | head -1)
    if [ -z "$FREEIPA_IP" ]; then
        FREEIPA_IP="8.8.8.8"
        echo "[WARN] FreeIPA not found, using ${FREEIPA_IP} for DNS"
    else
        echo "[INFO] Using FreeIPA DNS: ${FREEIPA_IP}"
    fi
    
    # Get Step-CA IP for CA_URL if not set
    if [ -z "${CA_URL:-}" ]; then
        STEP_CA_IP=$(kcli info vm step-ca-server 2>/dev/null | grep 'ip:' | awk '{print $2}' | head -1)
        CA_URL="https://${STEP_CA_IP}:443"
    fi
    
    # Get password from vault or use default
    PASSWORD=$(yq eval '.admin_user_password' "${ANSIBLE_VAULT_FILE}" 2>/dev/null || echo "password")
    STEP_CA_PASSWORD="${STEP_CA_PASSWORD:-password}"
    
    echo "[INFO] Creating VM ${VM_NAME}..."
    
    # Create VM using kcli
    kcli create vm "${VM_NAME}" \
        -i "${IMAGE}" \
        -P numcpus=4 \
        -P memory=8192 \
        -P disks="[300]" \
        -P nets="[{\"name\": \"${NET_NAME:-qubinet}\"}]" \
        -P dns="${FREEIPA_IP}" \
        -P cmds="[\"echo ${PASSWORD} | passwd --stdin root\", \"dnf install -y git vim wget curl jq podman skopeo\"]" \
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
    echo "[INFO] Configuring Mirror-Registry on VM..."
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    scp -o StrictHostKeyChecking=no "${SCRIPT_DIR}/configure-quay.sh" root@${IP}:/tmp/
    
    # Run configuration script
    echo "[INFO] Running Quay configuration (this may take 10-15 minutes)..."
    ssh -o StrictHostKeyChecking=no root@${IP} \
        "chmod +x /tmp/configure-quay.sh && \
         /tmp/configure-quay.sh ${DOMAIN} ${QUAY_VERSION} ${CA_URL} ${FINGERPRINT} ${PASSWORD}" || \
        echo "[WARN] Configuration may need manual completion"
    
    echo ""
    echo "========================================"
    echo "Mirror-Registry Deployment Complete"
    echo "========================================"
    echo "VM Name: ${VM_NAME}"
    echo "IP Address: ${IP}"
    echo "Registry URL: https://mirror-registry.${DOMAIN}:8443"
    echo ""
    echo "Login credentials:"
    echo "  User: init"
    echo "  Password: (check /root/mirror-registry-offline.log on VM)"
    echo ""
    echo "To verify: curl -k https://${IP}:8443/health/instance"
    echo "========================================"
}

function delete_mirror_registry() {
    echo "[INFO] Deleting Mirror-Registry..."
    
    if ! kcli list vm | grep -q "${VM_NAME}"; then
        echo "[INFO] VM ${VM_NAME} does not exist"
        return 0
    fi
    
    # Delete VM
    kcli delete vm "${VM_NAME}" -y
    
    echo "[OK] Mirror-Registry deleted"
}

function check_health() {
    echo "[INFO] Checking Mirror-Registry Health..."
    
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
    
    # Check registry health endpoint
    echo ""
    echo "Registry Health Check:"
    HEALTH=$(curl -sk "https://${IP}:8443/health/instance" 2>/dev/null)
    
    if echo "$HEALTH" | grep -q "healthy"; then
        echo "[OK] Registry is HEALTHY"
        echo "$HEALTH" | jq . 2>/dev/null || echo "$HEALTH"
        return 0
    else
        echo "[WARN] Registry may not be healthy"
        echo "Response: $HEALTH"
        
        # Check if container is running
        echo ""
        echo "Checking container status..."
        ssh -o StrictHostKeyChecking=no root@${IP} \
            "podman ps --filter name=quay 2>/dev/null || systemctl status quay-app 2>/dev/null" || true
        return 1
    fi
}

function show_status() {
    echo "[INFO] Mirror-Registry Status"
    
    echo ""
    echo "Mirror-Registry VMs:"
    kcli list vm | grep -E "mirror-registry|registry|Name" || echo "No registry VMs found"
    
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
        create_mirror_registry
        ;;
    delete|destroy)
        delete_mirror_registry
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

