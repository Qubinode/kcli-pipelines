"""
Airflow DAG: Generic VM Deployment
kcli-pipelines integration per ADR-0047

This DAG deploys VMs using kcli profiles. Supports:
- RHEL 8/9
- Fedora
- Ubuntu
- CentOS Stream 9
- OpenShift Jumpbox
- And other kcli profiles

Calls: /opt/kcli-pipelines/deploy-vm.sh
"""

from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import BranchPythonOperator

# Configuration
KCLI_PIPELINES_DIR = '/opt/kcli-pipelines'

default_args = {
    'owner': 'qubinode',
    'depends_on_past': False,
    'start_date': datetime(2025, 1, 1),
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 2,
    'retry_delay': timedelta(minutes=3),
}

dag = DAG(
    'generic_vm_deployment',
    default_args=default_args,
    description='Deploy VMs using kcli profiles (RHEL, Fedora, Ubuntu, etc.)',
    schedule=None,
    catchup=False,
    tags=['qubinode', 'kcli-pipelines', 'vm', 'infrastructure'],
    params={
        'action': 'create',  # create, delete, status
        'vm_profile': 'rhel9',  # VM profile to deploy
        'vm_name': '',  # VM name (auto-generated if empty)
        'community_version': 'false',  # Use community packages
        'target_server': 'localhost',  # Target server
    },
    doc_md="""
    # Generic VM Deployment DAG
    
    Deploy any VM type using kcli profiles.
    
    ## Supported VM Profiles
    - **rhel8, rhel9**: Red Hat Enterprise Linux
    - **fedora39**: Fedora
    - **ubuntu**: Ubuntu
    - **centos9stream**: CentOS Stream 9
    - **openshift-jumpbox**: OpenShift Jumpbox
    - **microshift-demos**: MicroShift demos
    - **device-edge-workshops**: Device Edge workshops
    - **ansible-aap**: Ansible Automation Platform
    
    ## Parameters
    - **action**: create, delete, or status
    - **vm_profile**: The kcli profile to use
    - **vm_name**: Custom VM name (auto-generated if empty)
    - **community_version**: Use community packages (true/false)
    
    ## Prerequisites
    - FreeIPA must be running for DNS registration
    - kcli must be configured with appropriate images
    - RHEL images downloaded: `kcli download image rhel8/rhel9`
    
    ## Usage
    ```bash
    airflow dags trigger generic_vm_deployment --conf '{
        "action": "create",
        "vm_profile": "rhel9",
        "vm_name": "my-test-vm"
    }'
    ```
    """,
)


def decide_action(**context):
    """Branch based on action parameter"""
    action = context['params'].get('action', 'create')
    if action == 'delete':
        return 'delete_vm'
    elif action == 'status':
        return 'check_status'
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
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Validating VM Deployment Environment"
    echo "========================================"
    
    VM_PROFILE="{{ params.vm_profile }}"
    echo "VM Profile: $VM_PROFILE"
    
    # Check kcli via SSH to host
    echo "Checking kcli..."
    if ! ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "which kcli" &>/dev/null; then
        echo "[ERROR] kcli not found on host"
        exit 1
    fi
    echo "[OK] kcli available"
    
    # Check for RHEL images
    echo "Checking for VM images..."
    if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "ls /var/lib/libvirt/images/rhel* 2>/dev/null" | grep -q rhel; then
        echo "[OK] RHEL images found"
    else
        echo "[WARN] RHEL images may not be downloaded"
        echo "Run: kcli download image rhel8 && kcli download image rhel9"
    fi
    
    # Check FreeIPA for DNS registration
    echo "Checking FreeIPA..."
    FREEIPA_IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli info vm freeipa 2>/dev/null | grep 'ip:' | awk '{print \$2}' | head -1")
    
    if [ -n "$FREEIPA_IP" ]; then
        echo "[OK] FreeIPA available at $FREEIPA_IP"
    else
        echo "[WARN] FreeIPA not found - DNS registration will be skipped"
    fi
    
    echo ""
    echo "[OK] Environment validation complete"
    ''',
    dag=dag,
)

# Task: Configure kcli profile
configure_profile = BashOperator(
    task_id='configure_kcli_profile',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Configuring kcli Profile"
    echo "========================================"
    
    VM_PROFILE="{{ params.vm_profile }}"
    COMMUNITY_VERSION="{{ params.community_version }}"
    TARGET_SERVER="{{ params.target_server }}"
    
    echo "VM Profile: $VM_PROFILE"
    echo "Community Version: $COMMUNITY_VERSION"
    
    # Check if profile-specific configuration exists
    PROFILE_CONFIG="/opt/kcli-pipelines/${VM_PROFILE}/configure-kcli-profile.sh"
    
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "if [ -f '$PROFILE_CONFIG' ]; then
            echo 'Running profile configuration...'
            export VM_PROFILE=$VM_PROFILE
            export COMMUNITY_VERSION=$COMMUNITY_VERSION
            export TARGET_SERVER=$TARGET_SERVER
            export CICD_PIPELINE=true
            cd /opt/kcli-pipelines
            source helper_scripts/default.env 2>/dev/null || true
            bash $PROFILE_CONFIG
        else
            echo 'No custom profile configuration found'
            echo 'Using default kcli profile: $VM_PROFILE'
        fi"
    
    echo "[OK] Profile configuration complete"
    ''',
    execution_timeout=timedelta(minutes=5),
    dag=dag,
)

# Task: Create VM
create_vm = BashOperator(
    task_id='create_vm',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Creating VM via kcli-pipelines"
    echo "========================================"
    
    VM_PROFILE="{{ params.vm_profile }}"
    VM_NAME="{{ params.vm_name }}"
    COMMUNITY_VERSION="{{ params.community_version }}"
    TARGET_SERVER="{{ params.target_server }}"
    
    # Generate VM name if not provided
    if [ -z "$VM_NAME" ]; then
        VM_NAME="${VM_PROFILE}-$(date +%s | md5sum | head -c 5)"
    fi
    
    echo "VM Profile: $VM_PROFILE"
    echo "VM Name: $VM_NAME"
    
    # Check if VM already exists
    if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli list vm | grep -q $VM_NAME"; then
        echo "[OK] VM $VM_NAME already exists"
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "kcli info vm $VM_NAME"
        exit 0
    fi
    
    # Execute deploy-vm.sh on host via SSH (ADR-0047)
    echo "Calling kcli-pipelines/deploy-vm.sh..."
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "export VM_NAME=$VM_NAME && \
         export VM_PROFILE=$VM_PROFILE && \
         export ACTION=create && \
         export COMMUNITY_VERSION=$COMMUNITY_VERSION && \
         export TARGET_SERVER=$TARGET_SERVER && \
         export CICD_PIPELINE=true && \
         cd /opt/kcli-pipelines && \
         ./deploy-vm.sh"
    
    echo ""
    echo "[OK] VM deployment initiated"
    ''',
    execution_timeout=timedelta(minutes=30),
    dag=dag,
)

# Task: Wait for VM to be ready
wait_for_vm = BashOperator(
    task_id='wait_for_vm',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Waiting for VM to be Ready"
    echo "========================================"
    
    VM_PROFILE="{{ params.vm_profile }}"
    VM_NAME="{{ params.vm_name }}"
    
    if [ -z "$VM_NAME" ]; then
        # Try to find the VM by profile
        VM_NAME=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "kcli list vm | grep $VM_PROFILE | tail -1 | awk '{print \$2}'" 2>/dev/null)
    fi
    
    if [ -z "$VM_NAME" ]; then
        echo "[WARN] Could not determine VM name"
        exit 0
    fi
    
    echo "Waiting for VM: $VM_NAME"
    
    MAX_ATTEMPTS=30
    ATTEMPT=0
    
    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        ATTEMPT=$((ATTEMPT + 1))
        echo "Check $ATTEMPT/$MAX_ATTEMPTS..."
        
        # Get VM IP
        IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "kcli info vm $VM_NAME 2>/dev/null | grep 'ip:' | awk '{print \$2}' | head -1")
        
        if [ -n "$IP" ] && [ "$IP" != "None" ]; then
            echo "VM IP: $IP"
            
            # Check SSH connectivity
            if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
                "nc -z -w5 $IP 22" 2>/dev/null; then
                echo ""
                echo "========================================"
                echo "[OK] VM is ready!"
                echo "========================================"
                echo "VM Name: $VM_NAME"
                echo "IP Address: $IP"
                exit 0
            fi
        fi
        
        sleep 20
    done
    
    echo "[WARN] Timeout waiting for VM - may still be provisioning"
    ''',
    execution_timeout=timedelta(minutes=15),
    dag=dag,
)

# Task: Validate deployment
validate_deployment = BashOperator(
    task_id='validate_deployment',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Validating VM Deployment"
    echo "========================================"
    
    VM_PROFILE="{{ params.vm_profile }}"
    VM_NAME="{{ params.vm_name }}"
    
    if [ -z "$VM_NAME" ]; then
        VM_NAME=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "kcli list vm | grep $VM_PROFILE | tail -1 | awk '{print \$2}'" 2>/dev/null)
    fi
    
    if [ -z "$VM_NAME" ]; then
        echo "[WARN] Could not find VM"
        exit 0
    fi
    
    # Get VM info
    echo "VM Details:"
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli info vm $VM_NAME"
    
    IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli info vm $VM_NAME 2>/dev/null | grep 'ip:' | awk '{print \$2}' | head -1")
    
    echo ""
    echo "========================================"
    echo "VM Deployment Complete"
    echo "========================================"
    echo "VM Name: $VM_NAME"
    echo "VM Profile: $VM_PROFILE"
    echo "IP Address: $IP"
    echo ""
    echo "Access:"
    echo "  SSH: ssh cloud-user@$IP"
    echo "  Console: kcli console $VM_NAME"
    ''',
    dag=dag,
)

# Task: Delete VM
delete_vm = BashOperator(
    task_id='delete_vm',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Deleting VM"
    echo "========================================"
    
    VM_PROFILE="{{ params.vm_profile }}"
    VM_NAME="{{ params.vm_name }}"
    TARGET_SERVER="{{ params.target_server }}"
    
    if [ -z "$VM_NAME" ]; then
        echo "[ERROR] VM name required for deletion"
        exit 1
    fi
    
    echo "Deleting VM: $VM_NAME"
    
    # Execute deploy-vm.sh with delete action
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "export VM_NAME=$VM_NAME && \
         export VM_PROFILE=$VM_PROFILE && \
         export ACTION=delete && \
         export TARGET_SERVER=$TARGET_SERVER && \
         export CICD_PIPELINE=true && \
         cd /opt/kcli-pipelines && \
         ./deploy-vm.sh"
    
    echo "[OK] VM deleted"
    ''',
    execution_timeout=timedelta(minutes=10),
    dag=dag,
)

# Task: Check status
check_status = BashOperator(
    task_id='check_status',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "VM Status"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    VM_PROFILE="{{ params.vm_profile }}"
    
    if [ -n "$VM_NAME" ]; then
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "kcli info vm $VM_NAME" 2>/dev/null || echo "VM not found: $VM_NAME"
    else
        echo "All VMs matching profile $VM_PROFILE:"
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "kcli list vm | grep -E '$VM_PROFILE|Name'" 2>/dev/null
    fi
    ''',
    dag=dag,
)

# Define task dependencies
decide_action_task >> validate_environment >> configure_profile >> create_vm >> wait_for_vm >> validate_deployment
decide_action_task >> delete_vm
decide_action_task >> check_status
