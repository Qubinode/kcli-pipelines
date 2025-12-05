#!/bin/bash
# VyOS Router Deployment Script
# Part of Qubinode Base Infrastructure (FreeIPA + VyOS)
#
# Usage:
#   ACTION=create ./deploy.sh
#   ACTION=destroy ./deploy.sh
#   ACTION=create VYOS_VERSION=2025.11.24-0021-rolling ./deploy.sh
#
# This script can run either:
#   1. Via Ansible playbook (recommended, handles permissions properly)
#   2. Via direct shell commands (legacy mode)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source environment if available
if [ -f /opt/qubinode-pipelines/helper_scripts/default.env ]; then
    source /opt/qubinode-pipelines/helper_scripts/default.env
fi

# Configuration
export ACTION="${ACTION:-create}"
export VYOS_VERSION="${VYOS_VERSION:-2025.11.24-0021-rolling}"
export DOMAIN="${DOMAIN:-example.com}"

# Handle ZONE_NAME for RHPDS environments
if [ -n "${ZONE_NAME:-}" ]; then
    DOMAIN="${GUID}.${ZONE_NAME}"
    export DOMAIN
fi

# Sudo handling
if [ "$EUID" -ne 0 ]; then
    export USE_SUDO="sudo"
else
    export USE_SUDO=""
fi

if [ -n "${CICD_PIPELINE:-}" ]; then
    export USE_SUDO="sudo"
fi

function create_livirt_networks(){
    array=( "1924" "1925" "1926" "1927"  "1928" )
    for i in "${array[@]}"
    do
        echo "$i"

        tmp=$(sudo virsh net-list | grep "$i" | awk '{ print $3}')
        if ([ "x$tmp" == "x" ] || [ "x$tmp" != "xyes" ])
        then
            echo "$i network does not exist creating it"
            # Try additional commands here...

            cat << EOF > /tmp/$i.xml
<network>
<name>$i</name>
<bridge name='virbr$(echo "${i:0-1}")' stp='on' delay='0'/>
<domain name='$i' localOnly='yes'/>
</network>
EOF

            sudo virsh net-define /tmp/$i.xml
            sudo virsh net-start $i
            sudo virsh net-autostart  $i
    else
            echo "$i network already exists"
        fi
    done
}

function create(){
    create_livirt_networks
    
    # VyOS nightly builds - https://vyos.net/get/nightly-builds/
    # Update this version periodically or use VYOS_VERSION env var
    VYOS_VERSION=${VYOS_VERSION:-"2025.11.24-0021-rolling"}
    
    VM_NAME=vyos-router
    ISO_NAME="vyos-${VYOS_VERSION}-generic-amd64.iso"
    ISO_PATH="$HOME/${ISO_NAME}"
    ISO_URL="https://github.com/vyos/vyos-nightly-build/releases/download/${VYOS_VERSION}/${ISO_NAME}"
    
    echo "========================================"
    echo "VyOS Router Deployment"
    echo "========================================"
    echo "VyOS Version: $VYOS_VERSION"
    echo "ISO Path: $ISO_PATH"
    
    # Download VyOS ISO if not present
    if [ ! -f "$ISO_PATH" ]; then
        echo "Downloading VyOS ISO..."
        echo "URL: $ISO_URL"
        cd $HOME
        if curl -L -o "$ISO_PATH" "$ISO_URL"; then
            echo "[OK] VyOS ISO downloaded successfully"
        else
            echo "[ERROR] Failed to download VyOS ISO"
            echo "Please download manually from: https://vyos.net/get/nightly-builds/"
            exit 1
        fi
    else
        echo "[OK] VyOS ISO already exists: $ISO_PATH"
    fi
    
    # Verify ISO size
    ISO_SIZE=$(stat -c%s "$ISO_PATH" 2>/dev/null || stat -f%z "$ISO_PATH")
    echo "ISO Size: $((ISO_SIZE / 1024 / 1024)) MB"
    if [ "$ISO_SIZE" -lt 100000000 ]; then
        echo "[ERROR] ISO seems too small, may be corrupted"
        exit 1
    fi

    # Create disk image if not exists
    if [ ! -f /var/lib/libvirt/images/${VM_NAME}.qcow2 ]; then
        echo "Creating disk image..."
        ${USE_SUDO} qemu-img create -f qcow2 /var/lib/libvirt/images/${VM_NAME}.qcow2 20G
    fi

    # Create VM
    echo "Creating VyOS VM..."
    ${USE_SUDO} virt-install -n ${VM_NAME} \
       --ram 4096 \
       --vcpus 2 \
       --cdrom "$ISO_PATH" \
       --os-variant debian10 \
       --network network=default,model=e1000e \
       --network network=1924,model=e1000e \
       --network network=1925,model=e1000e \
       --network network=1926,model=e1000e \
       --network network=1927,model=e1000e \
       --network network=1928,model=e1000e \
       --graphics vnc \
       --hvm \
       --virt-type kvm \
       --disk path=/var/lib/libvirt/images/${VM_NAME}.qcow2,bus=virtio \
       --noautoconsole

    echo ""
    echo "========================================"
    echo "MANUAL STEPS REQUIRED"
    echo "========================================"
    echo ""
    echo "1. Access VyOS console:"
    echo "   virsh console ${VM_NAME}"
    echo ""
    echo "2. Login with default credentials:"
    echo "   Username: vyos"
    echo "   Password: vyos"
    echo ""
    echo "3. Install VyOS to disk:"
    echo "   install image"
    echo ""
    echo "4. Reboot after installation:"
    echo "   reboot"
    echo ""
    
    # Download configuration script
    if [ ! -f $HOME/vyos-config.sh ]; then
        echo "Downloading VyOS configuration script..."
        cd $HOME
        curl -OL https://raw.githubusercontent.com/tosin2013/demo-virt/rhpds/demo.redhat.com/vyos-config-1.5.sh
        mv vyos-config-1.5.sh vyos-config.sh
        chmod +x vyos-config.sh
        
        # Get FreeIPA IP for DNS configuration
        export vm_name="freeipa"
        export ip_address=$(${USE_SUDO} kcli info vm "$vm_name" 2>/dev/null | grep "^ip:" | awk '{print $2}' | head -1)
        if [ -n "$ip_address" ]; then
            echo "FreeIPA IP: $ip_address"
            sed -i "s/1.1.1.1/${ip_address}/g" vyos-config.sh
        fi
        sed -i "s/example.com/${DOMAIN}/g" vyos-config.sh
        echo "[OK] Configuration script ready: $HOME/vyos-config.sh"
    fi
    
    echo ""
    echo "5. After VyOS is installed and rebooted, run the config script:"
    echo "   scp $HOME/vyos-config.sh vyos@<VYOS_IP>:/tmp/"
    echo "   ssh vyos@<VYOS_IP> 'vbash /tmp/vyos-config.sh'"
}

function destroy(){
    VM_NAME=vyos-router
    ${USE_SUDO} virsh destroy ${VM_NAME} 2>/dev/null || true
    ${USE_SUDO} virsh undefine ${VM_NAME} --remove-all-storage 2>/dev/null || true
    ${USE_SUDO} rm -rf /var/lib/libvirt/images/$VM_NAME.qcow2
    echo "[OK] VyOS Router destroyed"
}

function run_ansible(){
    echo "========================================"
    echo "Running VyOS Deployment via Ansible"
    echo "========================================"
    
    PLAYBOOK="${SCRIPT_DIR}/ansible/deploy_vyos.yaml"
    
    if [ ! -f "$PLAYBOOK" ]; then
        echo "[WARN] Ansible playbook not found: $PLAYBOOK"
        echo "Falling back to shell-based deployment..."
        return 1
    fi
    
    # Run Ansible playbook
    ansible-playbook "$PLAYBOOK" \
        -e "action=${ACTION}" \
        -e "vyos_version=${VYOS_VERSION}" \
        -e "domain=${DOMAIN}"
    
    return 0
}

function show_help(){
    echo "VyOS Router Deployment Script"
    echo ""
    echo "Usage:"
    echo "  ACTION=create ./deploy.sh     # Create VyOS router"
    echo "  ACTION=destroy ./deploy.sh    # Destroy VyOS router"
    echo "  ACTION=status ./deploy.sh     # Show VyOS status"
    echo ""
    echo "Environment Variables:"
    echo "  ACTION         - create, destroy, or status (default: create)"
    echo "  VYOS_VERSION   - VyOS version (default: 2025.11.24-0021-rolling)"
    echo "  DOMAIN         - Domain name (default: example.com)"
    echo "  USE_ANSIBLE    - Set to 'true' to use Ansible (default: true)"
    echo ""
    echo "Examples:"
    echo "  ACTION=create VYOS_VERSION=2025.11.24-0021-rolling ./deploy.sh"
    echo "  ACTION=destroy ./deploy.sh"
}

function status(){
    VM_NAME=vyos-router
    echo "========================================"
    echo "VyOS Router Status"
    echo "========================================"
    
    if ${USE_SUDO} virsh dominfo ${VM_NAME} &>/dev/null; then
        ${USE_SUDO} virsh dominfo ${VM_NAME}
        echo ""
        echo "IP Address:"
        ${USE_SUDO} virsh domifaddr ${VM_NAME} 2>/dev/null || \
            ${USE_SUDO} virsh net-dhcp-leases default 2>/dev/null | grep -i vyos || \
            echo "  Not available yet"
    else
        echo "VyOS Router VM does not exist"
    fi
    
    echo ""
    echo "Networks:"
    for NET in 1924 1925 1926 1927 1928; do
        STATE=$(${USE_SUDO} virsh net-info "$NET" 2>/dev/null | grep "Active:" | awk '{print $2}')
        if [ "$STATE" == "yes" ]; then
            echo "  $NET: Active"
        else
            echo "  $NET: Inactive or missing"
        fi
    done
}

# Main execution
USE_ANSIBLE="${USE_ANSIBLE:-true}"

case "${ACTION}" in
    create)
        if [ "$USE_ANSIBLE" == "true" ] && run_ansible; then
            echo "[OK] VyOS deployment completed via Ansible"
        else
            echo "Running shell-based deployment..."
            create
        fi
        ;;
    destroy|delete)
        if [ "$USE_ANSIBLE" == "true" ]; then
            run_ansible || destroy
        else
            destroy
        fi
        ;;
    status)
        status
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Unknown action: ${ACTION}"
        show_help
        exit 1
        ;;
esac

