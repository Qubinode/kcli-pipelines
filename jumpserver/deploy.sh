#!/bin/bash
# Jumpserver Deployment Script
# Deploys a jumpserver/bastion host with GUI desktop
#
# Usage:
#   ./deploy.sh create    - Create jumpserver VM
#   ./deploy.sh delete    - Delete jumpserver VM
#   ./deploy.sh status    - Check jumpserver status
#
# Environment Variables:
#   VM_NAME           - Name of the VM (default: jumpserver)
#   COMMUNITY_VERSION - Use CentOS instead of RHEL (default: false)
#   NET_NAME          - Network to use (default: 1924 for VyOS Lab network)
#   STATIC_IP         - Static IP address (required for isolated networks)
#   GATEWAY           - Gateway IP (default: 192.168.24.1 for 1924 network)

set -euo pipefail
export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

# Default values
ACTION="${1:-create}"
COMMUNITY_VERSION="${COMMUNITY_VERSION:-false}"

# Source environment (but don't override NET_NAME if already set)
SAVED_NET_NAME="${NET_NAME:-}"
if [ -f /opt/kcli-pipelines/helper_scripts/default.env ]; then
    source /opt/kcli-pipelines/helper_scripts/default.env
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
# Default to '1924' (VyOS Lab network) if not set
NET_NAME="${NET_NAME:-1924}"

# Static IP and Gateway for isolated networks (will be set by case statement below)
STATIC_IP="${STATIC_IP:-}"
GATEWAY="${GATEWAY:-}"

# Network configuration based on VyOS network layout
# IMPORTANT: kcli networks map to VyOS BASE interfaces, NOT VLANs!
# Reference: https://raw.githubusercontent.com/tosin2013/demo-virt/refs/heads/rhpds/demo.redhat.com/vyos-config-1.5.sh
case "${NET_NAME}" in
    1924) # Lab network - VyOS eth1 base interface
        GATEWAY="${GATEWAY:-192.168.49.1}"
        STATIC_IP="${STATIC_IP:-192.168.49.10}"
        NETWORK_DESC="Lab (192.168.49.0/24)"
        ;;
    1925) # Disco (Disconnected) network - VyOS eth2 base interface
        GATEWAY="${GATEWAY:-192.168.51.1}"
        STATIC_IP="${STATIC_IP:-192.168.51.10}"
        NETWORK_DESC="Disco (192.168.51.0/24)"
        ;;
    1926) # Trans-Proxy network - VyOS eth3 base interface
        GATEWAY="${GATEWAY:-192.168.53.1}"
        STATIC_IP="${STATIC_IP:-192.168.53.10}"
        NETWORK_DESC="Trans-Proxy (192.168.53.0/24)"
        ;;
    1927) # Metal network - VyOS eth4 base interface
        GATEWAY="${GATEWAY:-192.168.55.1}"
        STATIC_IP="${STATIC_IP:-192.168.55.10}"
        NETWORK_DESC="Metal (192.168.55.0/24)"
        ;;
    1928) # Provisioning network - VyOS eth5 base interface
        GATEWAY="${GATEWAY:-192.168.57.1}"
        STATIC_IP="${STATIC_IP:-192.168.57.10}"
        NETWORK_DESC="Provisioning (192.168.57.0/24)"
        ;;
    default) # DHCP for default network
        STATIC_IP=""
        GATEWAY=""
        NETWORK_DESC="Default (DHCP)"
        ;;
esac

# Source helper functions if available
if [ -f helper_scripts/helper_functions.sh ]; then
    source helper_scripts/helper_functions.sh
fi

# Get domain from ansible variables
DOMAIN=$(yq eval '.domain' "${ANSIBLE_ALL_VARIABLES}" 2>/dev/null || echo "example.com")

# Generate VM name if not set
VM_NAME="${VM_NAME:-jumpserver}"

# Get password from vault
PASSWORD=$(yq eval '.admin_user_password' "${ANSIBLE_VAULT_FILE}" 2>/dev/null || echo "password")

function show_help() {
    echo "Jumpserver Deployment Script"
    echo ""
    echo "Usage: $0 [create|delete|status]"
    echo ""
    echo "Actions:"
    echo "  create  - Create a new jumpserver VM with GUI"
    echo "  delete  - Delete the jumpserver VM"
    echo "  status  - Show jumpserver status"
    echo ""
    echo "Environment Variables:"
    echo "  VM_NAME           - Name of the VM (default: jumpserver)"
    echo "  COMMUNITY_VERSION - Use CentOS instead of RHEL (default: false)"
    echo "  NET_NAME          - Network to use (default: default)"
    echo ""
    echo "Examples:"
    echo "  ./deploy.sh create"
    echo "  VM_NAME=my-jumpbox COMMUNITY_VERSION=true ./deploy.sh create"
}

function check_prerequisites() {
    echo "[INFO] Checking prerequisites..."
    
    if ! command -v kcli &> /dev/null; then
        echo "[ERROR] kcli is not installed"
        exit 1
    fi
    
    if ! command -v yq &> /dev/null; then
        echo "[ERROR] yq is not installed"
        exit 1
    fi
    
    echo "[OK] Prerequisites check complete"
}

function create_jumpserver() {
    echo "[INFO] Creating Jumpserver..."
    
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
    echo "[INFO] Using network: ${NET_NAME}"
    
    # Get FreeIPA DNS IP
    FREEIPA_IP=$(kcli info vm freeipa 2>/dev/null | grep 'ip:' | awk '{print $2}' | head -1)
    if [ -z "$FREEIPA_IP" ]; then
        FREEIPA_IP="8.8.8.8"
        echo "[WARN] FreeIPA not found, using ${FREEIPA_IP} for DNS"
    else
        echo "[INFO] Using FreeIPA DNS: ${FREEIPA_IP}"
    fi
    
    # Create VM with GUI - needs more resources
    echo "[INFO] Creating VM ${VM_NAME} with GUI desktop..."
    echo "[INFO] This will take several minutes to install the desktop environment..."
    
    # Build network configuration
    # For isolated networks, use dual NICs: default (for cloud-init) + isolated (with static IP)
    if [ -n "$STATIC_IP" ] && [ -n "$GATEWAY" ] && [ "${NET_NAME}" != "default" ]; then
        echo "[INFO] Using dual NICs: default (DHCP) + ${NET_NAME} (static: ${STATIC_IP})"
        NET_CONFIG="[{\"name\": \"default\"}, {\"name\": \"${NET_NAME}\", \"nic\": \"eth1\", \"ip\": \"${STATIC_IP}\", \"mask\": \"255.255.255.0\", \"gateway\": \"${GATEWAY}\"}]"
    else
        echo "[INFO] Using single NIC with DHCP on network: ${NET_NAME}"
        NET_CONFIG="[{\"name\": \"${NET_NAME}\"}]"
    fi
    
    kcli create vm "${VM_NAME}" \
        -i "${IMAGE}" \
        -P numcpus=4 \
        -P memory=16384 \
        -P disks="[100]" \
        -P nets="${NET_CONFIG}" \
        -P dns="${FREEIPA_IP}" \
        -P cmds="[\"dnf install -y git vim wget curl\"]" \
        --wait
    
    # Wait for VM to be ready
    echo "[INFO] Waiting for VM to be ready..."
    sleep 30
    
    # Get VM IP - use static IP if configured, otherwise get from kcli
    if [ -n "$STATIC_IP" ]; then
        IP="${STATIC_IP}"
        echo "[INFO] Using static IP: ${IP}"
    else
        IP=$(kcli info vm "${VM_NAME}" | grep 'ip:' | awk '{print $2}' | head -1)
        echo "[INFO] VM IP from DHCP: ${IP}"
    fi
    
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
    
    # Copy and run configuration script
    echo "[INFO] Configuring Jumpserver with GUI..."
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    scp -o StrictHostKeyChecking=no "${SCRIPT_DIR}/configure-jumpserver.sh" ${LOGIN_USER}@${IP}:/tmp/
    
    ssh -o StrictHostKeyChecking=no ${LOGIN_USER}@${IP} \
        "chmod +x /tmp/configure-jumpserver.sh && \
         sudo /tmp/configure-jumpserver.sh ${DOMAIN} ${FREEIPA_IP} ${PASSWORD}" || echo "[WARN] Configuration may need manual completion"
    
    # Display connection info
    echo ""
    echo "========================================"
    echo "Jumpserver Deployment Complete"
    echo "========================================"
    echo "VM Name: ${VM_NAME}"
    echo "IP Address: ${IP}"
    echo "User: ${LOGIN_USER}"
    echo ""
    echo "Access Methods:"
    echo "  SSH:  ssh ${LOGIN_USER}@${IP}"
    echo "  VNC:  ${IP}:5901 (after starting VNC)"
    echo "  RDP:  ${IP}:3389 (if xrdp installed)"
    echo ""
    echo "To start VNC server:"
    echo "  ssh ${LOGIN_USER}@${IP} 'vncserver :1 -geometry 1920x1080'"
    echo ""
    echo "Note: GUI installation takes 10-15 minutes."
    echo "      Reboot the VM after installation completes."
    echo "========================================"
}

function delete_jumpserver() {
    echo "[INFO] Deleting Jumpserver..."
    
    if ! kcli list vm | grep -q "${VM_NAME}"; then
        echo "[INFO] VM ${VM_NAME} does not exist"
        return 0
    fi
    
    kcli delete vm "${VM_NAME}" -y
    echo "[OK] Jumpserver deleted"
}

function show_status() {
    echo "[INFO] Jumpserver Status"
    echo "========================================"
    
    if ! kcli list vm | grep -q "${VM_NAME}"; then
        echo "VM ${VM_NAME} does not exist"
        return 0
    fi
    
    kcli info vm "${VM_NAME}"
    
    IP=$(kcli info vm "${VM_NAME}" | grep 'ip:' | awk '{print $2}' | head -1)
    if [ -n "$IP" ] && [ "$IP" != "None" ]; then
        echo ""
        echo "Connection Info:"
        echo "  SSH: ssh cloud-user@${IP}"
        echo "  VNC: ${IP}:5901"
        echo "  RDP: ${IP}:3389"
    fi
}

# Main
echo "========================================"
echo "Jumpserver Deployment"
echo "========================================"
echo "Action: ${ACTION}"
echo "VM Name: ${VM_NAME}"
echo "Community Version: ${COMMUNITY_VERSION}"
echo "Network: ${NET_NAME} (${NETWORK_DESC:-Unknown})"
if [ -n "$STATIC_IP" ]; then
    echo "Static IP: ${STATIC_IP}"
    echo "Gateway: ${GATEWAY}"
fi
echo "========================================"

case "${ACTION}" in
    create)
        check_prerequisites
        create_jumpserver
        ;;
    delete)
        delete_jumpserver
        ;;
    status)
        show_status
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "[ERROR] Unknown action: ${ACTION}"
        show_help
        exit 1
        ;;
esac
