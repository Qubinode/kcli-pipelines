#!/bin/bash
# Step-CA Local Configuration Script
# https://smallstep.com/docs/step-ca
# 
# Usage: ./configure-step-ca-local.sh <domain> <dns_ip>
#
# This script:
# 1. Installs Step CLI and Step CA
# 2. Initializes the Certificate Authority
# 3. Adds ACME provisioner for automated certificate issuance
# 4. Configures systemd service
# 5. Updates DNS settings

export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
set -x

function check_dependencies() {
    echo "[INFO] Checking dependencies..."
    required_cmds="curl wget jq nmcli"
    missing_cmds=""
    
    for cmd in $required_cmds; do
        if ! command -v $cmd &> /dev/null; then
            missing_cmds="$missing_cmds $cmd"
        fi
    done
    
    if [ -n "$missing_cmds" ]; then
        echo "[INFO] Installing missing dependencies:$missing_cmds"
        sudo dnf install -y $missing_cmds
    fi
    
    echo "[OK] Dependencies check complete"
}

function install_step_tools() {
    echo "[INFO] Installing Step CLI and Step CA..."
    
    # Install Step CLI
    if ! command -v step &> /dev/null; then
        echo "[INFO] Installing Step CLI..."
        wget -q https://dl.smallstep.com/cli/docs-ca-install/latest/step-cli_amd64.rpm -O /tmp/step-cli_amd64.rpm
        sudo rpm -i /tmp/step-cli_amd64.rpm || sudo rpm -U /tmp/step-cli_amd64.rpm
    else
        echo "[OK] Step CLI already installed"
    fi
    
    # Install Step CA
    if ! command -v step-ca &> /dev/null; then
        echo "[INFO] Installing Step CA..."
        wget -q https://dl.smallstep.com/certificates/docs-ca-install/latest/step-ca_amd64.rpm -O /tmp/step-ca_amd64.rpm
        sudo rpm -i /tmp/step-ca_amd64.rpm || sudo rpm -U /tmp/step-ca_amd64.rpm
    else
        echo "[OK] Step CA already installed"
    fi
    
    # Verify installation
    step version
    step-ca version
    
    echo "[OK] Step tools installed"
}

function setup_certificate_authority() {
    echo "[INFO] Setting up Certificate Authority..."
    
    # Set hostname
    sudo hostnamectl set-hostname step-ca-server.${DOMAIN}
    
    # Get VM's IP address for DNS names
    VM_IP=$(hostname -I | awk '{print $1}')
    echo "[INFO] VM IP address: ${VM_IP}"
    
    # Check if CA is already initialized
    if [ -f "${HOME}/.step/config/ca.json" ]; then
        echo "[INFO] CA already initialized, skipping init"
    else
        echo "[INFO] Initializing CA..."
        step ca init \
            --dns=step-ca-server.${DOMAIN} \
            --dns=$(hostname -f) \
            --dns=$(hostname -s) \
            --dns=${VM_IP} \
            --dns=localhost \
            --dns=127.0.0.1 \
            --address=0.0.0.0:443 \
            --name="Internal CA for ${DOMAIN}" \
            --deployment-type=standalone \
            --provisioner="admin@${DOMAIN}" \
            --password-file=/etc/step/initial_password
    fi
    
    # Add ACME provisioner if not exists
    if ! step ca provisioner list 2>/dev/null | grep -q "acme"; then
        echo "[INFO] Adding ACME provisioner..."
        step ca provisioner add acme --type ACME
    else
        echo "[OK] ACME provisioner already exists"
    fi
    
    # Configure and start systemd service
    echo "[INFO] Configuring systemd service..."
    cd /tmp
    curl -OL https://raw.githubusercontent.com/Qubinode/qubinode-pipelines/main/scripts/step-ca-server/step-ca-service.sh
    chmod +x step-ca-service.sh
    sudo ./step-ca-service.sh
    
    # Wait for service to start
    sleep 5
    
    # Verify CA is running
    if curl -sk https://localhost:443/health | grep -q "ok"; then
        echo "[OK] Step CA is running and healthy"
    else
        echo "[WARN] Step CA health check failed - check logs: journalctl -u step-ca"
    fi
    
    # Display CA information
    echo ""
    echo "========================================"
    echo "Certificate Authority Information"
    echo "========================================"
    echo "CA URL: https://step-ca-server.${DOMAIN}:443"
    echo "Root CA: $(step path)/certs/root_ca.crt"
    echo "Fingerprint: $(step certificate fingerprint $(step path)/certs/root_ca.crt)"
    echo ""
    echo "Provisioners:"
    step ca provisioner list 2>/dev/null || echo "  (service may still be starting)"
    echo "========================================"
}

function update_dns_settings() {
    echo "[INFO] Updating DNS settings..."
    
    # Find the active connection
    CONN=$(nmcli -t -f NAME connection show --active | head -1)
    
    if [ -n "$CONN" ]; then
        echo "[INFO] Configuring DNS on connection: $CONN"
        sudo nmcli connection modify "$CONN" ipv4.dns "${DNS_IP},1.1.1.1"
        sudo nmcli connection down "$CONN" && sudo nmcli connection up "$CONN"
        echo "[OK] DNS configured"
    else
        echo "[WARN] No active connection found, skipping DNS configuration"
    fi
}

function main() {
    if [ $# -ne 2 ]; then
        echo "Usage: $0 <domain> <dns_ip>"
        echo "Example: $0 example.com 192.168.122.161"
        exit 1
    fi

    DOMAIN=$1
    DNS_IP=$2
    
    echo "========================================"
    echo "Step-CA Configuration"
    echo "========================================"
    echo "Domain: ${DOMAIN}"
    echo "DNS Server: ${DNS_IP}"
    echo "========================================"

    # Setup password file
    sudo mkdir -p /etc/step
    if [ -f /tmp/initial_password ]; then
        sudo cp /tmp/initial_password /etc/step/
        sudo chmod 600 /etc/step/initial_password
    else
        echo "[ERROR] /tmp/initial_password not found"
        echo "Please create the password file first"
        exit 1
    fi

    check_dependencies
    install_step_tools
    setup_certificate_authority
    update_dns_settings
    
    echo ""
    echo "[OK] Step-CA configuration complete!"
}

main "$@"
