"""
Airflow DAG: VyOS Router Deployment
ADR-0039: FreeIPA and VyOS Airflow DAG Integration
ADR-0041: VyOS Version Pinning and Upgrade Strategy

This DAG automates the deployment of VyOS router for network segmentation
and routing in the Qubinode environment.

Features:
- Create isolated libvirt networks
- Deploy VyOS router with multiple NICs
- Configure routing, NAT, and DHCP
- Support for VyOS 1.4 LTS and 1.5 rolling releases
"""

from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import BranchPythonOperator, PythonOperator
from airflow.models import Variable
from airflow.sensors.base import BaseSensorOperator
from airflow.utils.decorators import apply_defaults

# Default arguments
default_args = {
    'owner': 'qubinode',
    'depends_on_past': False,
    'start_date': datetime(2025, 11, 27),
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 2,
    'retry_delay': timedelta(minutes=3),
}

# DAG definition
dag = DAG(
    'vyos_router_deployment',
    default_args=default_args,
    description='Deploy VyOS Router for network segmentation via kcli/virsh',
    schedule=None,  # Manual trigger only
    catchup=False,
    tags=['qubinode', 'vyos', 'router', 'networking', 'infrastructure', 'kcli-pipelines'],
    params={
        'action': 'create',  # create or destroy
        'vyos_version': '2025.11.24-0021-rolling',  # VyOS version (check https://vyos.net/get/nightly-builds/)
        'vyos_channel': 'stable',  # stable, lts, or rolling
        'configure_router': 'true',  # Run configuration script
        'add_host_routes': 'true',  # Add routes to host
    },
)

# Environment setup
KCLI_PIPELINES_DIR = Variable.get('KCLI_PIPELINES_DIR', default_var='/opt/kcli-pipelines')
DEMO_VIRT_DIR = Variable.get('DEMO_VIRT_DIR', default_var='/opt/demo-virt')


def decide_action(**context):
    """Branch based on action parameter (create or destroy)."""
    action = context['params'].get('action', 'create')
    if action == 'destroy':
        return 'destroy_vyos'
    return 'validate_environment'


# Task: Decide action
decide_action_task = BranchPythonOperator(
    task_id='decide_action',
    python_callable=decide_action,
    dag=dag,
)

# Task: Validate environment
validate_environment = BashOperator(
    task_id='validate_environment',
    bash_command='''
    echo "========================================"
    echo "Validating VyOS Deployment Environment"
    echo "========================================"
    
    # Check virsh connectivity
    if ! virsh -c qemu:///system list &>/dev/null; then
        echo "[ERROR] Cannot connect to libvirt"
        exit 1
    fi
    echo "[OK] virsh connected to libvirt"
    
    # Check default network
    if ! virsh -c qemu:///system net-info default &>/dev/null; then
        echo "[WARN] Default network not found"
        echo "Creating default network..."
        virsh -c qemu:///system net-define /usr/share/libvirt/networks/default.xml 2>/dev/null || true
        virsh -c qemu:///system net-start default 2>/dev/null || true
        virsh -c qemu:///system net-autostart default 2>/dev/null || true
    fi
    echo "[OK] Default network available"
    
    # List current VMs
    echo ""
    echo "Current VMs:"
    virsh -c qemu:///system list --all
    
    echo ""
    echo "[OK] Environment validation complete"
    ''',
    dag=dag,
)

# Task: Create libvirt networks
create_networks = BashOperator(
    task_id='create_libvirt_networks',
    bash_command='''
    echo "========================================"
    echo "Creating Isolated Libvirt Networks"
    echo "========================================"
    
    # Network definitions for VyOS interfaces
    # These create isolated networks for different purposes:
    # 1924 - Lab network
    # 1925 - Disco (disconnected) network
    # 1926 - Reserved
    # 1927 - Metal (bare metal) network
    # 1928 - Provisioning network
    
    NETWORKS=("1924" "1925" "1926" "1927" "1928")
    
    for NET in "${NETWORKS[@]}"; do
        echo "Checking network: $NET"
        
        if virsh -c qemu:///system net-info "$NET" &>/dev/null; then
            STATE=$(virsh -c qemu:///system net-info "$NET" | grep "Active:" | awk '{print $2}')
            if [ "$STATE" == "yes" ]; then
                echo "  [OK] Network $NET already exists and is active"
                continue
            else
                echo "  Starting network $NET..."
                virsh -c qemu:///system net-start "$NET"
            fi
        else
            echo "  Creating network $NET..."
            
            # Get last digit for bridge naming
            LAST_DIGIT="${NET: -1}"
            
            cat > /tmp/net-$NET.xml <<EOF
<network>
  <name>$NET</name>
  <bridge name='virbr$LAST_DIGIT' stp='on' delay='0'/>
  <domain name='$NET' localOnly='yes'/>
</network>
EOF
            
            virsh -c qemu:///system net-define /tmp/net-$NET.xml
            virsh -c qemu:///system net-start "$NET"
            virsh -c qemu:///system net-autostart "$NET"
            rm /tmp/net-$NET.xml
            
            echo "  [OK] Network $NET created"
        fi
    done
    
    echo ""
    echo "Current networks:"
    virsh -c qemu:///system net-list --all
    ''',
    dag=dag,
)

# Task: Download VyOS ISO
# ADR-0046: Download on host via SSH
download_vyos = BashOperator(
    task_id='download_vyos_iso',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Downloading VyOS ISO"
    echo "========================================"
    
    VYOS_VERSION="{{ params.vyos_version }}"
    
    echo "VyOS Version: $VYOS_VERSION"
    
    # The ISO name format is: vyos-<version>-generic-amd64.iso
    # where version already includes -rolling suffix (e.g., 2025.11.24-0021-rolling)
    ISO_NAME="vyos-${VYOS_VERSION}-generic-amd64.iso"
    ISO_PATH="/root/${ISO_NAME}"
    ISO_URL="https://github.com/vyos/vyos-nightly-build/releases/download/${VYOS_VERSION}/${ISO_NAME}"
    
    echo "ISO Name: $ISO_NAME"
    echo "ISO Path: $ISO_PATH"
    echo "ISO URL: $ISO_URL"
    
    # Check if ISO already exists on host
    if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost "test -f $ISO_PATH"; then
        echo "[OK] VyOS ISO already exists on host: $ISO_PATH"
        SIZE=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost "stat -c%s $ISO_PATH")
        echo "ISO Size: $((SIZE / 1024 / 1024)) MB"
    else
        echo "Downloading VyOS ISO to host..."
        echo "This may take several minutes..."
        
        # Download on host via SSH
        if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "curl -L -o $ISO_PATH '$ISO_URL'"; then
            echo "[OK] VyOS ISO downloaded successfully"
            
            # Verify size
            SIZE=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost "stat -c%s $ISO_PATH")
            echo "ISO Size: $((SIZE / 1024 / 1024)) MB"
            
            if [ "$SIZE" -lt 100000000 ]; then
                echo "[WARN] ISO seems too small, may be corrupted or download failed"
                echo "Please download manually from: https://vyos.net/get/nightly-builds/"
                exit 1
            fi
        else
            echo "[ERROR] Failed to download VyOS ISO"
            echo ""
            echo "Please download manually on the host:"
            echo "  curl -L -o $ISO_PATH '$ISO_URL'"
            echo ""
            echo "Or visit: https://vyos.net/get/nightly-builds/"
            exit 1
        fi
    fi
    ''',
    execution_timeout=timedelta(minutes=20),
    dag=dag,
)

# Task: Create VyOS VM
# ADR-0047: Call kcli-pipelines deploy.sh via SSH to host
create_vyos_vm = BashOperator(
    task_id='create_vyos_vm',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    set -e
    echo "========================================"
    echo "Creating VyOS Router VM via kcli-pipelines"
    echo "========================================"
    
    VM_NAME="vyos-router"
    VYOS_VERSION="{{ params.vyos_version }}"
    
    # Check if VM already exists via SSH to host
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@localhost \
        "virsh dominfo $VM_NAME" &>/dev/null; then
        echo "[OK] VM $VM_NAME already exists"
        
        STATE=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "virsh domstate $VM_NAME")
        echo "Current state: $STATE"
        
        if [ "$STATE" != "running" ]; then
            echo "Starting existing VM..."
            ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
                "virsh start $VM_NAME"
        fi
        exit 0
    fi
    
    # Execute kcli-pipelines deploy.sh on host via SSH (ADR-0047)
    echo "Calling kcli-pipelines/vyos-router/deploy.sh..."
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "export ACTION=create && \
         export VYOS_VERSION=$VYOS_VERSION && \
         cd /opt/kcli-pipelines/vyos-router && \
         ./deploy.sh"
    
    echo ""
    echo "The DAG will now wait for you to complete the manual installation steps."
    echo "Check the output above for instructions."
    ''',
    execution_timeout=timedelta(minutes=15),
    dag=dag,
)

# Task: Wait for VyOS Router to be accessible (192.168.122.2)
# Pattern from OneDev: Wait for Vyos Router Configuration
# Polls until the router's external interface is pingable
wait_for_install = BashOperator(
    task_id='wait_for_vyos_install',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Waiting for VyOS Router Configuration"
    echo "========================================"
    echo ""
    echo "This task polls every 5 minutes until VyOS router is accessible at 192.168.122.2"
    echo ""
    echo "MANUAL STEPS REQUIRED:"
    echo "  Please access this page to manually configure the router:"
    echo "  https://github.com/tosin2013/demo-virt/blob/rhpds/demo.redhat.com/docs/step1.md"
    echo ""
    echo "Quick steps:"
    echo "  1. virsh console vyos-router"
    echo "  2. Login: vyos / vyos"
    echo "  3. Run: install image (follow prompts)"
    echo "  4. Reboot after installation"
    echo "  5. Configure external interface:"
    echo "     configure"
    echo "     set interfaces ethernet eth0 address 192.168.122.2/24"
    echo "     set protocols static route 0.0.0.0/0 next-hop 192.168.122.1"
    echo "     set service ssh"
    echo "     commit"
    echo "     save"
    echo "     exit"
    echo "  6. Copy and run config script:"
    echo "     scp /root/vyos-config.sh vyos@192.168.122.2:/tmp/"
    echo "     ssh vyos@192.168.122.2 'vbash /tmp/vyos-config.sh'"
    echo ""
    
    IP_ADDRESS="192.168.122.2"
    MAX_WAIT_TIME=1800  # 30 minutes in seconds
    WAIT_INTERVAL=300   # 5 minutes in seconds
    
    start_time=$(date +%s)
    end_time=$((start_time + MAX_WAIT_TIME))
    
    echo "Waiting for $IP_ADDRESS to be accessible..."
    
    while true; do
        # Check if the IP is accessible via ping from host
        if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "ping -c 1 $IP_ADDRESS" &>/dev/null; then
            echo ""
            echo "========================================"
            echo "[OK] Router is accessible at $IP_ADDRESS"
            echo "========================================"
            echo "Continuing to next step..."
            exit 0
        else
            current_time=$(date +%s)
            remaining_time=$((end_time - current_time))
            
            if [ $remaining_time -gt 0 ]; then
                echo "----------------------------------------"
                echo "$(date): Router is not accessible yet."
                echo "Please configure the router manually:"
                echo "  https://github.com/tosin2013/demo-virt/blob/rhpds/demo.redhat.com/docs/step1.md"
                echo "Remaining time: $((remaining_time / 60)) minutes"
                sleep $WAIT_INTERVAL
            else
                echo ""
                echo "[ERROR] Timeout reached. Router is still not accessible."
                echo "Please check: virsh console vyos-router"
                exit 1
            fi
        fi
    done
    ''',
    execution_timeout=timedelta(minutes=35),
    dag=dag,
)

# Task: Wait for VyOS internal network (192.168.50.1)
# Pattern from OneDev: Wait for Vyos Route 192.168.50.1
# This confirms the VyOS config script has been applied
wait_for_boot = BashOperator(
    task_id='wait_for_vyos_boot',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Waiting for VyOS Internal Network"
    echo "========================================"
    echo ""
    echo "This task polls until 192.168.50.1 is accessible."
    echo "This confirms the VyOS configuration script has been applied."
    echo ""
    echo "If not done yet, run the config script on VyOS:"
    echo "  scp /root/vyos-config.sh vyos@192.168.122.2:/tmp/"
    echo "  ssh vyos@192.168.122.2 'vbash /tmp/vyos-config.sh'"
    echo ""
    
    IP_ADDRESS="192.168.50.1"
    MAX_WAIT_TIME=1800  # 30 minutes in seconds
    WAIT_INTERVAL=300   # 5 minutes in seconds
    
    start_time=$(date +%s)
    end_time=$((start_time + MAX_WAIT_TIME))
    
    echo "Waiting for $IP_ADDRESS to be accessible..."
    
    while true; do
        # Check if the internal IP is accessible via ping from host
        if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "ping -c 1 $IP_ADDRESS" &>/dev/null; then
            echo ""
            echo "========================================"
            echo "[OK] VyOS internal network is accessible!"
            echo "========================================"
            echo "192.168.50.1 is reachable - VyOS configuration complete"
            echo ""
            echo "VyOS Router Ready:"
            echo "  External: ssh vyos@192.168.122.2"
            echo "  Console:  virsh console vyos-router"
            exit 0
        else
            current_time=$(date +%s)
            remaining_time=$((end_time - current_time))
            
            if [ $remaining_time -gt 0 ]; then
                echo "----------------------------------------"
                echo "$(date): Internal network not accessible yet."
                echo "Please run the VyOS config script:"
                echo "  scp /root/vyos-config.sh vyos@192.168.122.2:/tmp/"
                echo "  ssh vyos@192.168.122.2 'vbash /tmp/vyos-config.sh'"
                echo "Remaining time: $((remaining_time / 60)) minutes"
                sleep $WAIT_INTERVAL
            else
                echo ""
                echo "[ERROR] Timeout reached. Internal network still not accessible."
                echo "Please verify VyOS configuration manually."
                exit 1
            fi
        fi
    done
    ''',
    execution_timeout=timedelta(minutes=35),
    dag=dag,
)

# Task: Configure VyOS (optional)
configure_vyos = BashOperator(
    task_id='configure_vyos',
    bash_command=f'''
    echo "========================================"
    echo "VyOS Configuration Instructions"
    echo "========================================"
    
    CONFIGURE="{{{{ params.configure_router }}}}"
    
    if [ "$CONFIGURE" != "true" ]; then
        echo "Skipping automatic configuration (configure_router=false)"
        exit 0
    fi
    
    # Check for configuration script
    CONFIG_SCRIPT="{KCLI_PIPELINES_DIR}/vyos-router/vyos-config.sh"
    DEMO_VIRT_SCRIPT="{DEMO_VIRT_DIR}/demo.redhat.com/vyos-config-1.5.sh"
    
    if [ -f "$CONFIG_SCRIPT" ]; then
        echo "Found configuration script: $CONFIG_SCRIPT"
    elif [ -f "$DEMO_VIRT_SCRIPT" ]; then
        echo "Found configuration script: $DEMO_VIRT_SCRIPT"
        CONFIG_SCRIPT="$DEMO_VIRT_SCRIPT"
    else
        echo "[WARN]  No configuration script found"
        echo ""
        echo "Manual configuration required. Connect to VyOS:"
        echo "  ssh vyos@<vyos-ip>"
        echo ""
        echo "Or use console:"
        echo "  virsh console vyos-router"
        exit 0
    fi
    
    # Get VyOS IP
    VM_NAME="vyos-router"
    VYOS_IP=$(virsh domifaddr "$VM_NAME" 2>/dev/null | grep -oP '\\d+\\.\\d+\\.\\d+\\.\\d+' | head -1)
    
    if [ -z "$VYOS_IP" ]; then
        VYOS_IP=$(virsh net-dhcp-leases default 2>/dev/null | grep vyos | awk '{{print $5}}' | sed 's/\\/24//g' | tail -1)
    fi
    
    if [ -z "$VYOS_IP" ]; then
        echo "[ERROR] Could not determine VyOS IP"
        echo "Manual configuration required"
        exit 0
    fi
    
    echo "VyOS IP: $VYOS_IP"
    echo ""
    echo "To configure VyOS, copy and run the configuration script:"
    echo ""
    echo "  scp $CONFIG_SCRIPT vyos@$VYOS_IP:/tmp/"
    echo "  ssh vyos@$VYOS_IP 'vbash /tmp/vyos-config.sh'"
    echo ""
    echo "Default VyOS credentials:"
    echo "  Username: vyos"
    echo "  Password: vyos"
    ''',
    dag=dag,
)

# Task: Add host routes
add_host_routes = BashOperator(
    task_id='add_host_routes',
    bash_command='''
    echo "========================================"
    echo "Adding Host Routes"
    echo "========================================"
    
    ADD_ROUTES="{{ params.add_host_routes }}"
    
    if [ "$ADD_ROUTES" != "true" ]; then
        echo "Skipping host routes (add_host_routes=false)"
        exit 0
    fi
    
    # Get VyOS IP (gateway)
    VM_NAME="vyos-router"
    GATEWAY=$(virsh domifaddr "$VM_NAME" 2>/dev/null | grep -oP '\\d+\\.\\d+\\.\\d+\\.\\d+' | head -1)
    
    if [ -z "$GATEWAY" ]; then
        GATEWAY=$(virsh net-dhcp-leases default 2>/dev/null | grep vyos | awk '{print $5}' | sed 's/\\/24//g' | tail -1)
    fi
    
    if [ -z "$GATEWAY" ]; then
        echo "[WARN]  Could not determine VyOS gateway IP"
        echo "Routes not added"
        exit 0
    fi
    
    echo "VyOS Gateway: $GATEWAY"
    echo ""
    
    # Define routes for VyOS networks
    ROUTES=(
        "192.168.49.0/24"
        "192.168.50.0/24"
        "192.168.51.0/24"
        "192.168.52.0/24"
        "192.168.53.0/24"
        "192.168.54.0/24"
        "192.168.55.0/24"
        "192.168.56.0/24"
        "192.168.57.0/24"
        "192.168.58.0/24"
    )
    
    echo "Adding routes via $GATEWAY..."
    for ROUTE in "${ROUTES[@]}"; do
        if ip route show | grep -q "$ROUTE"; then
            echo "  [WARN]  Route $ROUTE already exists"
        else
            if ip route add "$ROUTE" via "$GATEWAY" 2>/dev/null; then
                echo "  [OK] Added route: $ROUTE via $GATEWAY"
            else
                echo "  [ERROR] Failed to add route: $ROUTE"
            fi
        fi
    done
    
    echo ""
    echo "Current routes to VyOS networks:"
    ip route show | grep "$GATEWAY" || echo "No routes found"
    ''',
    dag=dag,
)

# Task: Validate deployment
validate_deployment = BashOperator(
    task_id='validate_deployment',
    bash_command='''
    echo "========================================"
    echo "Validating VyOS Deployment"
    echo "========================================"
    
    VM_NAME="vyos-router"
    
    # Check VM status
    echo "VM Status:"
    virsh domstate "$VM_NAME"
    
    # Get IP
    VYOS_IP=$(virsh domifaddr "$VM_NAME" 2>/dev/null | grep -oP '\\d+\\.\\d+\\.\\d+\\.\\d+' | head -1)
    
    if [ -z "$VYOS_IP" ]; then
        VYOS_IP=$(virsh net-dhcp-leases default 2>/dev/null | grep vyos | awk '{print $5}' | sed 's/\\/24//g' | tail -1)
    fi
    
    echo ""
    echo "Network Interfaces:"
    virsh domifaddr "$VM_NAME" 2>/dev/null || echo "Could not get interface addresses"
    
    echo ""
    echo "Isolated Networks:"
    for NET in 1924 1925 1926 1927 1928; do
        STATE=$(virsh net-info "$NET" 2>/dev/null | grep "Active:" | awk '{print $2}')
        if [ "$STATE" == "yes" ]; then
            echo "  [OK] Network $NET: Active"
        else
            echo "  [WARN]  Network $NET: Inactive or missing"
        fi
    done
    
    echo ""
    echo "========================================"
    echo "[OK] VyOS Router Deployment Complete!"
    echo "========================================"
    echo ""
    echo "Access Information:"
    if [ -n "$VYOS_IP" ]; then
        echo "  SSH: ssh vyos@$VYOS_IP"
    fi
    echo "  Console: virsh console vyos-router"
    echo ""
    echo "Default Credentials:"
    echo "  Username: vyos"
    echo "  Password: vyos"
    echo ""
    ''',
    dag=dag,
)

# Task: Destroy VyOS
destroy_vyos = BashOperator(
    task_id='destroy_vyos',
    bash_command='''
    echo "========================================"
    echo "Destroying VyOS Router"
    echo "========================================"
    
    VM_NAME="vyos-router"
    
    # Stop VM if running
    if virsh domstate "$VM_NAME" 2>/dev/null | grep -q "running"; then
        echo "Stopping VM..."
        virsh destroy "$VM_NAME"
    fi
    
    # Undefine VM
    if virsh dominfo "$VM_NAME" &>/dev/null; then
        echo "Removing VM definition..."
        virsh undefine "$VM_NAME" --remove-all-storage
    fi
    
    # Cleanup files
    rm -f /var/lib/libvirt/images/${VM_NAME}.qcow2
    rm -f /var/lib/libvirt/images/seed.iso
    
    # Optionally remove networks (commented out to preserve for other VMs)
    # for NET in 1924 1925 1926 1927 1928; do
    #     virsh net-destroy "$NET" 2>/dev/null
    #     virsh net-undefine "$NET" 2>/dev/null
    # done
    
    echo "[OK] VyOS Router destroyed successfully"
    echo ""
    echo "Note: Isolated networks (1924-1928) were preserved."
    echo "To remove them, run:"
    echo "  for NET in 1924 1925 1926 1927 1928; do virsh net-destroy \\$NET; virsh net-undefine \\$NET; done"
    ''',
    dag=dag,
)

# Define task dependencies
decide_action_task >> validate_environment
validate_environment >> create_networks >> download_vyos >> create_vyos_vm
# wait_for_install polls until VyOS is installed (user completes manual steps)
create_vyos_vm >> wait_for_install >> wait_for_boot >> configure_vyos >> add_host_routes >> validate_deployment

decide_action_task >> destroy_vyos

# DAG documentation
dag.doc_md = """
# VyOS Router Deployment DAG

Automates the deployment of VyOS router for network segmentation in Qubinode environments.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `action` | `create` | Action: `create` or `destroy` |
| `vyos_version` | `1.5-rolling-202411250007` | VyOS version to deploy |
| `vyos_channel` | `stable` | Version channel: `stable`, `lts`, or `rolling` |
| `configure_router` | `true` | Run configuration script |
| `add_host_routes` | `true` | Add routes to host machine |

## Network Architecture

```
+------------------------------------------------------------------+
|                        VyOS Router                                |
+------------------------------------------------------------------+
|  eth0 (default)  | 192.168.122.x | Internet-facing               |
|  eth1 (1924)     | 192.168.49.1  | Lab network                   |
|  eth2 (1925)     | 192.168.51.1  | Disco network                 |
|  eth3 (1926)     | 192.168.53.1  | Reserved                      |
|  eth4 (1927)     | 192.168.55.1  | Metal network                 |
|  eth5 (1928)     | 192.168.57.1  | Provisioning network          |
+------------------------------------------------------------------+
```

## Workflow

### Create Action
1. **Validate Environment** - Check virsh, virt-install, libvirt
2. **Create Networks** - Create isolated libvirt networks (1924-1928)
3. **Download VyOS** - Download VyOS ISO if not present
4. **Create VM** - Deploy VyOS with 6 NICs
5. **Wait for Boot** - Wait for VyOS to obtain IP
6. **Configure VyOS** - Provide configuration instructions
7. **Add Host Routes** - Add routes to host for VyOS networks
8. **Validate** - Verify deployment

### Destroy Action
1. **Destroy VyOS** - Remove VM (preserves networks)

## Usage

### Via Airflow UI
1. Navigate to DAGs → vyos_router_deployment
2. Click "Trigger DAG w/ config"
3. Set parameters as needed
4. Click "Trigger"

### Via CLI
```bash
airflow dags trigger vyos_router_deployment --conf '{"action": "create"}'
```

## Post-Deployment Configuration

After deployment, configure VyOS via SSH or console:

```bash
# Connect to VyOS
ssh vyos@<vyos-ip>

# Or via console
virsh console vyos-router

# Run configuration script
vbash /tmp/vyos-config.sh
```

## Related ADRs
- ADR-0039: FreeIPA and VyOS Airflow DAG Integration
- ADR-0041: VyOS Version Pinning and Upgrade Strategy
"""
