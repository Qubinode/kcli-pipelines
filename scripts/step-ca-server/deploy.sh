#!/bin/bash
# Step-CA Server Deployment Script
# Usage: ./deploy.sh [create|delete]
#
# Environment Variables:
#   COMMUNITY_VERSION - true for CentOS, false for RHEL (default: false)
#   INITIAL_PASSWORD  - Password for Step-CA (default: password)
#   VM_NAME           - Custom VM name (default: auto-generated)
#   NET_NAME          - Network to deploy on (default: from default.env)
#
# This script deploys a Step-CA certificate authority server for:
# - Disconnected OpenShift installs
# - Internal PKI infrastructure
# - Harbor/Mirror Registry certificates
# - Service mesh certificates

set -euo pipefail
export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

# Default values
ACTION="${1:-create}"
COMMUNITY_VERSION="${COMMUNITY_VERSION:-false}"
INITIAL_PASSWORD="${INITIAL_PASSWORD:-password}"

# Source environment (but don't override NET_NAME if already set)
SAVED_NET_NAME="${NET_NAME:-}"
if [ -f /opt/qubinode-pipelines/helper_scripts/default.env ]; then
    source /opt/qubinode-pipelines/helper_scripts/default.env
elif [ -f helper_scripts/default.env ]; then
    source helper_scripts/default.env
else
    echo "[ERROR] default.env file not found"
    exit 1
fi
# Restore NET_NAME if it was set before sourcing
if [ -n "$SAVED_NET_NAME" ]; then
    NET_NAME="$SAVED_NET_NAME"
fi
# Default to 'default' network if not set
NET_NAME="${NET_NAME:-default}"

# Source helper functions if available
if [ -f helper_scripts/helper_functions.sh ]; then
    source helper_scripts/helper_functions.sh
fi

# Get domain from ansible variables
DOMAIN=$(yq eval '.domain' "${ANSIBLE_ALL_VARIABLES}" 2>/dev/null || echo "example.com")

# Generate VM name if not set
if [ -z "${VM_NAME:-}" ]; then
    VM_NAME="step-ca-$(echo $RANDOM | md5sum | head -c 5)"
fi

echo "========================================"
echo "Step-CA Server Deployment"
echo "========================================"
echo "Action: ${ACTION}"
echo "VM Name: ${VM_NAME}"
echo "Domain: ${DOMAIN}"
echo "Community Version: ${COMMUNITY_VERSION}"
echo "Network: ${NET_NAME:-default}"
echo "========================================"

function check_prerequisites() {
    echo "[INFO] Checking prerequisites..."
    
    # Check kcli
    if ! command -v kcli &>/dev/null; then
        echo "[ERROR] kcli not found"
        exit 1
    fi
    
    # Check for required images
    if [ "$COMMUNITY_VERSION" == "true" ]; then
        IMAGE="centos9stream"
    else
        IMAGE="rhel9"
    fi
    
    if ! kcli list image | grep -q "$IMAGE"; then
        echo "[WARN] Image $IMAGE not found"
        echo "Download with: kcli download image $IMAGE"
    fi
    
    echo "[OK] Prerequisites check complete"
}

function create_step_ca() {
    echo "[INFO] Creating Step-CA server..."
    
    # Check if VM already exists
    if kcli list vm | grep -q "${VM_NAME}"; then
        echo "[INFO] VM ${VM_NAME} already exists"
        kcli info vm "${VM_NAME}"
        return 0
    fi
    
    # Determine image based on community version
    if [ "$COMMUNITY_VERSION" == "true" ]; then
        IMAGE="centos9stream"
        LOGIN_USER="cloud-user"
    else
        IMAGE="rhel9"
        LOGIN_USER="cloud-user"
    fi
    
    echo "[INFO] Using image: ${IMAGE}"
    echo "[INFO] Using network: ${NET_NAME:-default}"
    
    # Get FreeIPA DNS IP
    FREEIPA_IP=$(kcli info vm freeipa 2>/dev/null | grep 'ip:' | awk '{print $2}' | head -1)
    if [ -z "$FREEIPA_IP" ]; then
        FREEIPA_IP="8.8.8.8"
        echo "[WARN] FreeIPA not found, using ${FREEIPA_IP} for DNS"
    else
        echo "[INFO] Using FreeIPA DNS: ${FREEIPA_IP}"
    fi
    
    # Create VM directly with kcli
    echo "[INFO] Creating VM ${VM_NAME}..."
    kcli create vm "${VM_NAME}" \
        -i "${IMAGE}" \
        -P numcpus=4 \
        -P memory=8192 \
        -P disks="[50]" \
        -P nets="[{\"name\": \"${NET_NAME:-default}\"}]" \
        -P dns="${FREEIPA_IP}" \
        -P cmds="[\"dnf install -y git vim wget curl jq firewalld\", \"systemctl enable --now firewalld\", \"firewall-cmd --permanent --add-port=443/tcp\", \"firewall-cmd --reload\"]" \
        --wait
    
    # Wait for VM to be ready
    echo "[INFO] Waiting for VM to get IP..."
    sleep 30
    
    # Get VM IP
    IP=$(kcli info vm "${VM_NAME}" | grep 'ip:' | awk '{print $2}' | head -1)
    echo "[INFO] VM IP: ${IP}"
    
    if [ -z "$IP" ] || [ "$IP" == "None" ]; then
        echo "[ERROR] VM did not get an IP address"
        return 1
    fi
    
    # Wait for SSH to be available
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
    
    # Copy and run Step-CA configuration script
    echo "[INFO] Configuring Step-CA on VM..."
    
    # Create initial password file
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 ${LOGIN_USER}@${IP} \
        "echo '${INITIAL_PASSWORD}' | sudo tee /tmp/initial_password > /dev/null"
    
    # Copy local configuration script to VM (instead of downloading from GitHub)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    scp -o StrictHostKeyChecking=no "${SCRIPT_DIR}/configure-step-ca-local.sh" ${LOGIN_USER}@${IP}:/tmp/
    
    # Run configuration script
    ssh -o StrictHostKeyChecking=no ${LOGIN_USER}@${IP} \
        "chmod +x /tmp/configure-step-ca-local.sh && \
         sudo /tmp/configure-step-ca-local.sh ${DOMAIN} ${FREEIPA_IP}" || echo "[WARN] Step-CA configuration may need manual completion"
    
    # Wait for Step-CA to be ready
    echo "[INFO] Waiting for Step-CA service..."
    MAX_ATTEMPTS=30
    ATTEMPT=0
    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        ATTEMPT=$((ATTEMPT + 1))
        if curl -sk "https://${IP}:443/health" 2>/dev/null | grep -q "ok"; then
            echo "[OK] Step-CA is healthy"
            break
        fi
        echo "[INFO] Waiting for Step-CA... (${ATTEMPT}/${MAX_ATTEMPTS})"
        sleep 10
    done
    
    # Get CA fingerprint
    echo ""
    echo "========================================"
    echo "Step-CA Deployment Complete"
    echo "========================================"
    echo "VM Name: ${VM_NAME}"
    echo "IP Address: ${IP}"
    echo "CA URL: https://${IP}:443"
    echo ""
    echo "To get the CA fingerprint, run:"
    echo "  ssh ${LOGIN_USER}@${IP} 'step certificate fingerprint \$(step path)/certs/root_ca.crt'"
    echo ""
    echo "To bootstrap a client:"
    echo "  step ca bootstrap --ca-url https://${IP}:443 --fingerprint <FINGERPRINT> --install"
    echo ""
    echo "To request a certificate:"
    echo "  step ca certificate <hostname> cert.crt key.key"
    echo "========================================"
}

function delete_step_ca() {
    echo "[INFO] Deleting Step-CA server..."
    
    if ! kcli list vm | grep -q "${VM_NAME}"; then
        echo "[INFO] VM ${VM_NAME} does not exist"
        return 0
    fi
    
    # Delete VM
    kcli delete vm "${VM_NAME}" -y
    
    echo "[OK] Step-CA server deleted"
}

function show_status() {
    echo "[INFO] Step-CA Status"
    
    # Find step-ca VMs
    echo ""
    echo "Step-CA VMs:"
    kcli list vm | grep -E "step-ca|Name" || echo "No Step-CA VMs found"
    
    # If VM_NAME is set, show details
    if kcli list vm | grep -q "${VM_NAME}"; then
        echo ""
        echo "VM Details:"
        kcli info vm "${VM_NAME}"
        
        IP=$(kcli info vm "${VM_NAME}" | grep 'ip:' | awk '{print $2}' | head -1)
        if [ -n "$IP" ]; then
            echo ""
            echo "Health Check:"
            curl -sk "https://${IP}:443/health" 2>/dev/null || echo "Health check failed"
        fi
    fi
}

# Main
case "${ACTION}" in
    create)
        check_prerequisites
        create_step_ca
        ;;
    delete|destroy)
        delete_step_ca
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: $0 [create|delete|status]"
        exit 1
        ;;
esac
