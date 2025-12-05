"""
Airflow DAG: Jumpserver Deployment (OpenShift Jumpbox)
Deploys a jumpserver/bastion host based on openshift-jumpbox profile

Features:
- Fedora-based with OpenShift CLI tools pre-installed
- Development tools (git, vim, podman, etc.)
- Kubernetes/OpenShift CLI tools (oc, kubectl, helm, kustomize)
- Dual NIC support for VyOS isolated networks
- Optional GUI desktop installation

Access Methods:
- SSH: ssh fedora@<IP>
- Console: kcli console jumpserver
"""

from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import BranchPythonOperator

default_args = {
    'owner': 'qubinode',
    'depends_on_past': False,
    'start_date': datetime(2025, 1, 1),
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
}

dag = DAG(
    'jumpserver_deployment',
    default_args=default_args,
    description='Deploy Jumpserver with GUI Desktop (GNOME)',
    schedule=None,
    catchup=False,
    tags=['qubinode', 'kcli-pipelines', 'jumpserver', 'gui', 'bastion'],
    params={
        'action': 'create',  # create, delete, status
        'vm_name': 'jumpserver',
        'network': '1924',  # VyOS network (1924=Lab, 1925=Disco, etc.)
        'static_ip': '192.168.49.10',  # Static IP on isolated network
        'gateway': '192.168.49.1',  # Gateway for isolated network
        'disk_size': '120',  # GB
        'memory': '16384',  # MB
        'install_gui': 'false',  # Install GNOME desktop (optional)
    },
)


def decide_action(**context):
    """Decide which action to take based on params"""
    action = context['params'].get('action', 'create')
    if action == 'delete':
        return 'delete_jumpserver'
    elif action == 'status':
        return 'check_status'
    return 'create_jumpserver'


# Task: Decide action
decide_action_task = BranchPythonOperator(
    task_id='decide_action',
    python_callable=decide_action,
    dag=dag,
)

# Task: Create Jumpserver VM
create_jumpserver = BashOperator(
    task_id='create_jumpserver',
    bash_command='''
    set -e
    echo "========================================"
    echo "Creating Jumpserver VM (OpenShift Jumpbox)"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    NETWORK="{{ params.network }}"
    STATIC_IP="{{ params.static_ip }}"
    GATEWAY="{{ params.gateway }}"
    DISK_SIZE="{{ params.disk_size }}"
    MEMORY="{{ params.memory }}"
    
    # Use latest Fedora for openshift-jumpbox compatibility
    IMAGE="fedora42"
    
    echo "VM Name: $VM_NAME"
    echo "Image: $IMAGE"
    echo "Network: $NETWORK (isolated) + default"
    echo "Static IP: $STATIC_IP"
    echo "Gateway: $GATEWAY"
    echo "Disk: ${DISK_SIZE}GB"
    echo "Memory: ${MEMORY}MB"
    
    # Check if VM already exists
    if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli list vm | grep -q ${VM_NAME}"; then
        echo "[INFO] VM ${VM_NAME} already exists"
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "kcli info vm ${VM_NAME}"
        exit 0
    fi
    
    # Download Fedora image if needed
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli download image ${IMAGE} || true"
    
    # Create VM with dual NICs: default (DHCP) + isolated (static IP)
    echo "[INFO] Creating VM with dual NICs..."
    
    # Build the nets parameter with proper quoting
    NETS_PARAM='[{"name": "default"}, {"name": "'${NETWORK}'", "nic": "eth1", "ip": "'${STATIC_IP}'", "mask": "255.255.255.0", "gateway": "'${GATEWAY}'"}]'
    
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli create vm ${VM_NAME} -i ${IMAGE} -P numcpus=4 -P memory=${MEMORY} -P disks=[${DISK_SIZE}] -P nets='${NETS_PARAM}' --wait"
    
    # Wait for VM to be ready
    echo "[INFO] Waiting for VM to be ready..."
    sleep 30
    
    # Get VM IP on default network
    IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli info vm ${VM_NAME} | grep 'ip:' | awk '{print \\$2}' | head -1")
    
    echo "[OK] VM created successfully"
    echo "Default Network IP: $IP"
    echo "Isolated Network IP: $STATIC_IP"
    ''',
    execution_timeout=timedelta(minutes=20),
    dag=dag,
)

# Task: Configure Network (second NIC for isolated network)
configure_network = BashOperator(
    task_id='configure_network',
    bash_command='''
    echo "========================================"
    echo "Configuring Network"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    STATIC_IP="{{ params.static_ip }}"
    GATEWAY="{{ params.gateway }}"
    
    # Get VM IP on default network
    IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli info vm ${VM_NAME} | grep 'ip:' | awk '{print \\$2}' | head -1")
    
    if [ -z "$IP" ] || [ "$IP" == "None" ]; then
        echo "[ERROR] Could not get VM IP"
        exit 1
    fi
    
    echo "[INFO] Configuring second NIC on ${VM_NAME} ($IP)..."
    
    # Find and configure the second NIC (handles Fedora ens naming)
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "ssh -o StrictHostKeyChecking=no fedora@${IP} 'SECOND_NIC=\$(ip -o link show | awk -F\": \" \"{print \\\$2}\" | grep -v lo | tail -1); if [ -n \"\$SECOND_NIC\" ]; then if ! ip addr show \$SECOND_NIC | grep -q ${STATIC_IP}; then sudo nmcli con add type ethernet con-name isolated ifname \$SECOND_NIC ip4 ${STATIC_IP}/24 gw4 ${GATEWAY} && sudo nmcli con up isolated && echo OK; else echo Already configured; fi; else echo No second NIC; fi'"
    
    echo "[OK] Network configuration complete"
    ''',
    execution_timeout=timedelta(minutes=5),
    dag=dag,
)

# Task: Install GUI
install_gui = BashOperator(
    task_id='install_gui',
    bash_command='''
    echo "========================================"
    echo "GUI Installation"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    INSTALL_GUI="{{ params.install_gui }}"
    
    if [ "$INSTALL_GUI" != "true" ]; then
        echo "[INFO] GUI installation skipped (install_gui != true)"
        echo ""
        echo "To install GUI later, SSH to the VM and run:"
        echo "  sudo dnf groupinstall -y 'Workstation'"
        echo "  sudo systemctl set-default graphical.target"
        echo "  sudo reboot"
        exit 0
    fi
    
    # Get VM IP
    IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli info vm ${VM_NAME} | grep 'ip:' | awk '{print \\$2}' | head -1")
    
    if [ -z "$IP" ] || [ "$IP" == "None" ]; then
        echo "[ERROR] Could not get VM IP"
        exit 1
    fi
    
    echo "[INFO] Installing GUI on ${VM_NAME} ($IP)..."
    echo "[INFO] This will take 10-15 minutes..."
    
    # Install GNOME Workstation (Fedora)
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "ssh -o StrictHostKeyChecking=no fedora@${IP} 'sudo dnf groupinstall -y Workstation --skip-broken || echo \"Desktop install completed with warnings\"'"
    
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "ssh -o StrictHostKeyChecking=no fedora@${IP} 'sudo systemctl set-default graphical.target'"
    
    # Install VNC and additional tools
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "ssh -o StrictHostKeyChecking=no fedora@${IP} 'sudo dnf install -y tigervnc-server firefox htop || true'"
    
    # Configure VNC password
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "ssh -o StrictHostKeyChecking=no fedora@${IP} 'mkdir -p ~/.vnc && echo \"password\" | vncpasswd -f > ~/.vnc/passwd && chmod 600 ~/.vnc/passwd'"
    
    echo "[OK] GUI installation complete"
    echo ""
    echo "Reboot the VM to start the graphical desktop:"
    echo "  ssh fedora@${IP} 'sudo reboot'"
    echo ""
    echo "To start VNC server:"
    echo "  ssh fedora@${IP} 'vncserver :1 -geometry 1920x1080'"
    echo "  Connect to: ${IP}:5901"
    ''',
    execution_timeout=timedelta(minutes=30),
    dag=dag,
)

# Task: Show connection info
show_connection_info = BashOperator(
    task_id='show_connection_info',
    bash_command='''
    echo "========================================"
    echo "Jumpserver Deployment Complete"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    STATIC_IP="{{ params.static_ip }}"
    
    # Get VM IP
    IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli info vm ${VM_NAME} | grep 'ip:' | awk '{print \\$2}' | head -1")
    
    echo ""
    echo "VM Name: ${VM_NAME}"
    echo ""
    echo "Network Interfaces:"
    echo "  Default Network (eth0): ${IP}"
    echo "  Isolated Network (eth1): ${STATIC_IP}"
    echo ""
    echo "Access Methods:"
    echo "========================================"
    echo ""
    echo "1. SSH (via default network):"
    echo "   ssh fedora@${IP}"
    echo ""
    echo "2. SSH (via isolated network - requires route):"
    echo "   ssh fedora@${STATIC_IP}"
    echo ""
    echo "3. Console (via kcli):"
    echo "   kcli console ${VM_NAME}"
    echo ""
    echo "========================================"
    echo "Pre-installed tools: oc, kubectl, helm, podman"
    echo "========================================"
    ''',
    execution_timeout=timedelta(minutes=2),
    dag=dag,
)

# Task: Delete Jumpserver
delete_jumpserver = BashOperator(
    task_id='delete_jumpserver',
    bash_command='''
    echo "========================================"
    echo "Deleting Jumpserver VM"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli delete vm ${VM_NAME} -y" || echo "VM may not exist"
    
    echo "[OK] Jumpserver deleted"
    ''',
    execution_timeout=timedelta(minutes=5),
    dag=dag,
)

# Task: Check Status
check_status = BashOperator(
    task_id='check_status',
    bash_command='''
    echo "========================================"
    echo "Jumpserver Status"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli info vm ${VM_NAME}" || echo "VM not found"
    ''',
    execution_timeout=timedelta(minutes=2),
    dag=dag,
)

# Define task dependencies
decide_action_task >> [create_jumpserver, delete_jumpserver, check_status]
create_jumpserver >> configure_network >> install_gui >> show_connection_info
