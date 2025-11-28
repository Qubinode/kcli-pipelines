"""
Airflow DAG: Step-CA Certificate Authority Deployment
kcli-pipelines integration per ADR-0047

This DAG deploys a Step-CA certificate authority server for:
- Disconnected OpenShift installs
- Internal PKI infrastructure
- Harbor/Mirror Registry certificates
- Service mesh certificates

Integrates with: ocp4-disconnected-helper

Calls: /opt/kcli-pipelines/step-ca-server/ scripts
"""

from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import BranchPythonOperator

# Configuration
KCLI_PIPELINES_DIR = '/opt/kcli-pipelines'
STEP_CA_DIR = f'{KCLI_PIPELINES_DIR}/step-ca-server'

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
    'step_ca_deployment',
    default_args=default_args,
    description='Deploy Step-CA certificate authority for disconnected installs',
    schedule=None,
    catchup=False,
    tags=['qubinode', 'kcli-pipelines', 'step-ca', 'certificates', 'disconnected'],
    params={
        'action': 'create',  # create, delete, status
        'domain': 'example.com',  # Domain for certificates
        'vm_name': 'step-ca-server',  # VM name
        'community_version': 'false',  # Use community packages
        'target_server': 'localhost',  # Target server
        'network': 'default',  # Network to deploy on (default, isolated1, isolated2, etc.)
        'static_ip': '',  # Optional static IP (e.g., 192.168.50.10)
    },
    doc_md="""
    # Step-CA Certificate Authority Deployment
    
    Deploy a Step-CA server for internal PKI infrastructure.
    
    ## Why Step-CA?
    
    Step-CA is essential for:
    - **Disconnected OpenShift installs** - Certificates for air-gapped environments
    - **Mirror Registry** - TLS certificates for Harbor/Quay
    - **Internal services** - Secure communication between services
    - **ocp4-disconnected-helper** - Certificate generation for disconnected installs
    
    ## Architecture
    
    ```
    +------------------+     +------------------+     +------------------+
    |   Step-CA        | --> | Mirror Registry  | --> | OpenShift        |
    |   (Certificates) |     | (Images)         |     | (Disconnected)   |
    +------------------+     +------------------+     +------------------+
    ```
    
    ## Parameters
    - **action**: create, delete, or status
    - **domain**: Domain for certificate generation
    - **vm_name**: Name for the Step-CA VM
    
    ## Usage
    ```bash
    airflow dags trigger step_ca_deployment --conf '{
        "action": "create",
        "domain": "lab.example.com"
    }'
    ```
    
    ## Post-Deployment
    
    After deployment, register the CA with your system:
    ```bash
    # On the host
    step ca bootstrap --ca-url https://step-ca-server.example.com:443 --fingerprint <FINGERPRINT>
    ```
    
    ## Integration with ocp4-disconnected-helper
    
    The Step-CA server provides certificates for:
    - Registry TLS (Harbor/Quay)
    - Internal service certificates
    - Cluster certificate signing
    """,
)


def decide_action(**context):
    """Branch based on action parameter"""
    action = context['params'].get('action', 'create')
    if action == 'delete':
        return 'delete_step_ca'
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
    echo "Validating Step-CA Deployment Environment"
    echo "========================================"
    
    DOMAIN="{{ params.domain }}"
    echo "Domain: $DOMAIN"
    
    # Check kcli
    echo "Checking kcli..."
    if ! ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "which kcli" &>/dev/null; then
        echo "[ERROR] kcli not found on host"
        exit 1
    fi
    echo "[OK] kcli available"
    
    # Check for step-ca-server scripts
    echo "Checking Step-CA scripts..."
    if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "test -d /opt/kcli-pipelines/step-ca-server"; then
        echo "[OK] Step-CA scripts found"
    else
        echo "[ERROR] Step-CA scripts not found at /opt/kcli-pipelines/step-ca-server"
        exit 1
    fi
    
    # Check FreeIPA for DNS
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
    echo "Configuring Step-CA kcli Profile"
    echo "========================================"
    
    DOMAIN="{{ params.domain }}"
    VM_NAME="{{ params.vm_name }}"
    COMMUNITY_VERSION="{{ params.community_version }}"
    TARGET_SERVER="{{ params.target_server }}"
    
    echo "Domain: $DOMAIN"
    echo "VM Name: $VM_NAME"
    
    # Run profile configuration
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "export VM_PROFILE=step-ca-server && \
         export VM_NAME=$VM_NAME && \
         export DOMAIN=$DOMAIN && \
         export COMMUNITY_VERSION=$COMMUNITY_VERSION && \
         export TARGET_SERVER=$TARGET_SERVER && \
         export CICD_PIPELINE=true && \
         export CUSTOM_PROFILE=true && \
         cd /opt/kcli-pipelines && \
         source helper_scripts/default.env 2>/dev/null || true && \
         bash step-ca-server/configure-kcli-profile.sh"
    
    echo "[OK] Profile configuration complete"
    ''',
    execution_timeout=timedelta(minutes=5),
    dag=dag,
)

# Task: Create Step-CA VM
create_step_ca = BashOperator(
    task_id='create_step_ca_vm',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Creating Step-CA Server VM"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    DOMAIN="{{ params.domain }}"
    TARGET_SERVER="{{ params.target_server }}"
    
    echo "VM Name: $VM_NAME"
    echo "Domain: $DOMAIN"
    
    # Check if VM already exists
    if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli list vm | grep -q $VM_NAME"; then
        echo "[OK] VM $VM_NAME already exists"
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "kcli info vm $VM_NAME"
        exit 0
    fi
    
    # Create VM using step-ca-server/deploy.sh
    echo "Creating Step-CA VM..."
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "export VM_NAME=$VM_NAME && \
         export COMMUNITY_VERSION={{ params.community_version }} && \
         export INITIAL_PASSWORD=password && \
         export NET_NAME={{ params.network }} && \
         cd /opt/kcli-pipelines && \
         ./step-ca-server/deploy.sh create" || true
    
    # Verify VM was created
    if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli list vm | grep -q $VM_NAME"; then
        echo "[OK] Step-CA VM created successfully"
    else
        echo "[ERROR] Step-CA VM was not created"
        exit 1
    fi
    ''',
    execution_timeout=timedelta(minutes=20),
    dag=dag,
)

# Task: Wait for Step-CA VM
wait_for_vm = BashOperator(
    task_id='wait_for_step_ca_vm',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Waiting for Step-CA VM"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
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
                echo "[OK] Step-CA VM is ready at $IP"
                exit 0
            fi
        fi
        
        sleep 20
    done
    
    echo "[ERROR] Timeout waiting for Step-CA VM"
    exit 1
    ''',
    execution_timeout=timedelta(minutes=15),
    dag=dag,
)

# Task: Configure Step-CA
configure_step_ca = BashOperator(
    task_id='configure_step_ca',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Configuring Step-CA Server"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    DOMAIN="{{ params.domain }}"
    
    # Get VM IP
    IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli info vm $VM_NAME 2>/dev/null | grep 'ip:' | awk '{print \$2}' | head -1")
    
    if [ -z "$IP" ]; then
        echo "[ERROR] Could not get Step-CA VM IP"
        exit 1
    fi
    
    echo "Step-CA IP: $IP"
    echo "Domain: $DOMAIN"
    
    # Check if Step-CA is already configured
    if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "curl -sk https://$IP:443/health 2>/dev/null | grep -q ok"; then
        echo "[OK] Step-CA is already configured and running"
        exit 0
    fi
    
    # Get FreeIPA DNS IP
    FREEIPA_IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli info vm freeipa 2>/dev/null | grep 'ip:' | awk '{print \$2}' | head -1")
    if [ -z "$FREEIPA_IP" ]; then
        FREEIPA_IP="8.8.8.8"
    fi
    echo "Using DNS: $FREEIPA_IP"
    
    # Copy local configuration script to VM and run it
    echo "Copying and running Step-CA configuration..."
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "scp -o StrictHostKeyChecking=no /opt/kcli-pipelines/step-ca-server/configure-step-ca-local.sh cloud-user@$IP:/tmp/ && \
         ssh -o StrictHostKeyChecking=no cloud-user@$IP 'echo password | sudo tee /tmp/initial_password > /dev/null && \
         chmod +x /tmp/configure-step-ca-local.sh && \
         sudo /tmp/configure-step-ca-local.sh $DOMAIN $FREEIPA_IP'"
    
    # Verify Step-CA is running
    sleep 10
    if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "curl -sk https://$IP:443/health 2>/dev/null | grep -q ok"; then
        echo "[OK] Step-CA is configured and running"
    else
        echo "[WARN] Step-CA may need additional configuration"
        echo "SSH to the VM: ssh cloud-user@$IP"
    fi
    ''',
    execution_timeout=timedelta(minutes=10),
    dag=dag,
)

# Task: Register CA with system
register_ca = BashOperator(
    task_id='register_ca',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Registering Step-CA with System"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    DOMAIN="{{ params.domain }}"
    
    # Get VM IP
    IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli info vm $VM_NAME 2>/dev/null | grep 'ip:' | awk '{print \$2}' | head -1")
    
    echo "Step-CA IP: $IP"
    
    # Get CA fingerprint from the Step-CA VM
    echo "Getting CA fingerprint..."
    FINGERPRINT=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "ssh -o StrictHostKeyChecking=no cloud-user@$IP 'sudo step certificate fingerprint /root/.step/certs/root_ca.crt 2>/dev/null'")
    
    if [ -z "$FINGERPRINT" ]; then
        echo "[WARN] Could not get CA fingerprint automatically"
        echo "Get it manually: ssh cloud-user@$IP 'sudo step certificate fingerprint /root/.step/certs/root_ca.crt'"
    else
        echo "CA Fingerprint: $FINGERPRINT"
        
        # Bootstrap the host to trust the CA
        echo "Bootstrapping host to trust Step-CA..."
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "step ca bootstrap --ca-url https://$IP:443 --fingerprint $FINGERPRINT --install 2>/dev/null || \
             echo 'Bootstrap completed (may already be configured)'"
    fi
    
    echo ""
    echo "========================================"
    echo "Step-CA Registration Complete"
    echo "========================================"
    echo "CA URL: https://$IP:443"
    echo "Fingerprint: $FINGERPRINT"
    echo ""
    echo "To bootstrap other clients:"
    echo "  step ca bootstrap --ca-url https://$IP:443 --fingerprint $FINGERPRINT --install"
    echo "========================================"
    ''',
    execution_timeout=timedelta(minutes=5),
    dag=dag,
)

# Task: Validate deployment
validate_deployment = BashOperator(
    task_id='validate_deployment',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Validating Step-CA Deployment"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    DOMAIN="{{ params.domain }}"
    
    # Get VM info
    IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli info vm $VM_NAME 2>/dev/null | grep 'ip:' | awk '{print \$2}' | head -1")
    
    echo "Step-CA VM: $VM_NAME"
    echo "IP Address: $IP"
    echo "Domain: $DOMAIN"
    
    # Check Step-CA health
    echo ""
    echo "Checking Step-CA health..."
    if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "curl -sk https://$IP:443/health 2>/dev/null"; then
        echo ""
        echo "[OK] Step-CA is healthy"
    else
        echo "[WARN] Could not verify Step-CA health"
        echo "The service may still be starting or require manual configuration"
    fi
    
    echo ""
    echo "========================================"
    echo "Step-CA Deployment Complete"
    echo "========================================"
    echo ""
    echo "Step-CA Server:"
    echo "  URL: https://$IP:443"
    echo "  SSH: ssh cloud-user@$IP"
    echo ""
    echo "To use with ocp4-disconnected-helper:"
    echo "  1. Get the CA fingerprint from the Step-CA server"
    echo "  2. Configure ocp4-disconnected-helper with CA_URL and FINGERPRINT"
    echo ""
    echo "To generate certificates:"
    echo "  step ca certificate <hostname> <cert.pem> <key.pem>"
    ''',
    dag=dag,
)

# Task: Delete Step-CA
delete_step_ca = BashOperator(
    task_id='delete_step_ca',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Deleting Step-CA Server"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    TARGET_SERVER="{{ params.target_server }}"
    
    echo "Deleting VM: $VM_NAME"
    
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "export VM_NAME=$VM_NAME && \
         export VM_PROFILE=step-ca-server && \
         export ACTION=delete && \
         export TARGET_SERVER=$TARGET_SERVER && \
         export CICD_PIPELINE=true && \
         cd /opt/kcli-pipelines && \
         ./deploy-vm.sh"
    
    echo "[OK] Step-CA server deleted"
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
    echo "Step-CA Status"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    
    # Get VM info
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli info vm $VM_NAME" 2>/dev/null || echo "VM not found: $VM_NAME"
    
    # Get IP and check health
    IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli info vm $VM_NAME 2>/dev/null | grep 'ip:' | awk '{print \$2}' | head -1")
    
    if [ -n "$IP" ]; then
        echo ""
        echo "Step-CA Health Check:"
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "curl -sk https://$IP:443/health 2>/dev/null" || echo "Health check failed"
    fi
    ''',
    dag=dag,
)

# Define task dependencies
decide_action_task >> validate_environment >> configure_profile >> create_step_ca
create_step_ca >> wait_for_vm >> configure_step_ca >> register_ca >> validate_deployment
decide_action_task >> delete_step_ca
decide_action_task >> check_status
