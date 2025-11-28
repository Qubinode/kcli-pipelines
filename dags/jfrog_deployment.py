"""
Airflow DAG: JFrog Artifactory Deployment
kcli-pipelines integration per ADR-0047

This DAG deploys JFrog Artifactory for:
- Universal artifact repository
- Docker, Maven, npm, PyPI, and more
- Enterprise artifact management

Editions:
- oss: Open Source (Docker registry only)
- pro: Professional (All package types)

Calls: /opt/kcli-pipelines/jfrog/deploy.sh
"""

from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import BranchPythonOperator

# Configuration
KCLI_PIPELINES_DIR = '/opt/kcli-pipelines'
JFROG_DIR = f'{KCLI_PIPELINES_DIR}/jfrog'

default_args = {
    'owner': 'qubinode',
    'depends_on_past': False,
    'start_date': datetime(2025, 1, 1),
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 2,
    'retry_delay': timedelta(minutes=5),
}

dag = DAG(
    'jfrog_deployment',
    default_args=default_args,
    description='Deploy JFrog Artifactory universal artifact repository',
    schedule=None,
    catchup=False,
    tags=['qubinode', 'kcli-pipelines', 'jfrog', 'artifactory', 'registry'],
    params={
        'action': 'create',  # create, delete, status, health
        'vm_name': 'jfrog',  # VM name
        'jfrog_version': '7.77.5',  # JFrog Artifactory version
        'jfrog_edition': 'oss',  # oss or pro
        'cert_mode': 'step-ca',  # step-ca or self-signed
        'domain': 'example.com',  # Domain for certificates
        'target_server': 'localhost',  # Target server
        'network': 'qubinet',  # Network to deploy on
        'step_ca_vm': 'step-ca-server',  # Step-CA server VM name (for step-ca mode)
    },
    doc_md="""
    # JFrog Artifactory Deployment DAG
    
    Deploy JFrog Artifactory universal artifact repository.
    
    ## Features
    
    - Universal artifact repository (Docker, Maven, npm, PyPI, etc.)
    - Build integration (CI/CD)
    - Artifact lifecycle management
    - Security scanning (Pro edition)
    - RHEL9-based VM with Podman
    
    ## Editions
    
    ### OSS (Open Source)
    - Docker registry
    - Generic repository
    - Free to use
    
    ### Pro (Professional)
    - All package types (Maven, npm, PyPI, Go, etc.)
    - Advanced security features
    - Requires license
    
    ## Certificate Modes
    
    ### Step-CA (Default)
    Uses internal Step-CA server for TLS certificates.
    
    ### Self-Signed
    Generates self-signed certificates (not recommended for production).
    
    ## Prerequisites
    
    For Step-CA mode:
    ```bash
    airflow dags trigger step_ca_deployment --conf '{"action": "create"}'
    ```
    
    ## Parameters
    
    - **action**: create, delete, status, or health
    - **vm_name**: Name for the VM (default: jfrog)
    - **jfrog_version**: JFrog Artifactory version
    - **jfrog_edition**: oss or pro
    - **cert_mode**: step-ca or self-signed
    - **domain**: Domain for certificate generation
    - **step_ca_vm**: Name of the Step-CA server VM
    
    ## Usage
    
    ### Create JFrog OSS
    ```bash
    airflow dags trigger jfrog_deployment --conf '{
        "action": "create",
        "vm_name": "jfrog",
        "jfrog_version": "7.77.5",
        "jfrog_edition": "oss"
    }'
    ```
    
    ### Create JFrog Pro
    ```bash
    airflow dags trigger jfrog_deployment --conf '{
        "action": "create",
        "vm_name": "jfrog-pro",
        "jfrog_version": "7.77.5",
        "jfrog_edition": "pro"
    }'
    ```
    
    ### Check JFrog Health
    ```bash
    airflow dags trigger jfrog_deployment --conf '{
        "action": "health",
        "vm_name": "jfrog"
    }'
    ```
    
    ## Post-Deployment
    
    After deployment, JFrog will be available at:
    - **UI**: http://<ip>:8082/ui
    - **API**: http://<ip>:8082/artifactory
    - **Default User**: admin
    - **Default Password**: password
    
    ### Configure Docker registry:
    ```bash
    # Add to /etc/containers/registries.conf
    [[registry]]
    location = "jfrog.<domain>:8082"
    insecure = true
    
    # Login
    podman login jfrog.<domain>:8082
    
    # Push image
    podman push myimage:latest jfrog.<domain>:8082/docker-local/myimage:latest
    ```
    
    ## Related DAGs
    
    - `mirror_registry_deployment` - Quay mirror-registry (lighter weight)
    - `harbor_deployment` - Harbor enterprise registry
    - `step_ca_deployment` - Certificate authority
    """,
)


def decide_action(**context):
    """Branch based on action parameter"""
    action = context['params'].get('action', 'create')
    if action == 'delete':
        return 'delete_jfrog'
    elif action == 'status':
        return 'check_status'
    elif action == 'health':
        return 'health_check'
    return 'check_prerequisites'


# Task: Decide action
decide_action_task = BranchPythonOperator(
    task_id='decide_action',
    python_callable=decide_action,
    dag=dag,
)


# Task: Check prerequisites
check_prerequisites = BashOperator(
    task_id='check_prerequisites',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Checking JFrog Prerequisites"
    echo "========================================"
    
    CERT_MODE="{{ params.cert_mode }}"
    STEP_CA_VM="{{ params.step_ca_vm }}"
    JFROG_EDITION="{{ params.jfrog_edition }}"
    
    echo "Certificate Mode: $CERT_MODE"
    echo "JFrog Edition: $JFROG_EDITION"
    
    if [ "$CERT_MODE" == "step-ca" ]; then
        echo ""
        echo "Checking Step-CA server..."
        
        STEP_CA_IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "kcli info vm $STEP_CA_VM 2>/dev/null | grep 'ip:' | awk '{print \$2}' | head -1")
        
        if [ -z "$STEP_CA_IP" ] || [ "$STEP_CA_IP" == "None" ]; then
            echo "[WARN] Step-CA server not found: $STEP_CA_VM"
            echo "Will use self-signed certificates instead."
        else
            echo "[OK] Step-CA server found at: $STEP_CA_IP"
            
            # Check Step-CA health
            if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
                "curl -sk https://$STEP_CA_IP:443/health 2>/dev/null | grep -q ok"; then
                echo "[OK] Step-CA is healthy"
            else
                echo "[WARN] Step-CA may not be responding"
            fi
        fi
    fi
    
    # Check RHEL9 image
    echo ""
    echo "Checking RHEL9 image..."
    if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli list image | grep -q rhel9"; then
        echo "[OK] RHEL9 image available"
    else
        echo "[WARN] RHEL9 image may not be available"
        echo "Download with: kcli download image rhel9"
    fi
    
    echo ""
    echo "[OK] Prerequisites check complete"
    ''',
    dag=dag,
)


# Task: Validate environment
validate_environment = BashOperator(
    task_id='validate_environment',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Validating JFrog Environment"
    echo "========================================"
    
    DOMAIN="{{ params.domain }}"
    
    echo "Registry Type: JFrog Artifactory"
    echo "Domain: $DOMAIN"
    
    # Check kcli
    echo "Checking kcli..."
    if ! ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "which kcli" &>/dev/null; then
        echo "[ERROR] kcli not found on host"
        exit 1
    fi
    echo "[OK] kcli available"
    
    # Check for JFrog scripts
    echo "Checking JFrog deployment scripts..."
    if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "test -f /opt/kcli-pipelines/jfrog/deploy.sh"; then
        echo "[OK] JFrog deploy script found"
    else
        echo "[ERROR] JFrog deploy.sh not found"
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


# Task: Create JFrog VM
create_jfrog = BashOperator(
    task_id='create_jfrog_vm',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Creating JFrog Artifactory VM"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    JFROG_VERSION="{{ params.jfrog_version }}"
    JFROG_EDITION="{{ params.jfrog_edition }}"
    CERT_MODE="{{ params.cert_mode }}"
    DOMAIN="{{ params.domain }}"
    NETWORK="{{ params.network }}"
    STEP_CA_VM="{{ params.step_ca_vm }}"
    
    echo "VM Name: $VM_NAME"
    echo "JFrog Version: $JFROG_VERSION"
    echo "JFrog Edition: $JFROG_EDITION"
    echo "Certificate Mode: $CERT_MODE"
    
    # Check if VM already exists
    if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli list vm | grep -q $VM_NAME"; then
        echo "[OK] VM $VM_NAME already exists"
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "kcli info vm $VM_NAME"
        exit 0
    fi
    
    # Prepare environment variables based on cert mode
    if [ "$CERT_MODE" == "step-ca" ]; then
        STEP_CA_IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "kcli info vm $STEP_CA_VM 2>/dev/null | grep 'ip:' | awk '{print \$2}' | head -1")
        
        if [ -n "$STEP_CA_IP" ] && [ "$STEP_CA_IP" != "None" ]; then
            CA_URL="https://${STEP_CA_IP}:443"
            
            FINGERPRINT=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
                "ssh -o StrictHostKeyChecking=no cloud-user@$STEP_CA_IP \
                    'sudo step certificate fingerprint /root/.step/certs/root_ca.crt 2>/dev/null'")
            
            echo "Step-CA URL: $CA_URL"
            echo "CA Fingerprint: $FINGERPRINT"
            
            # Create JFrog with Step-CA
            ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
                "export VM_NAME=$VM_NAME && \
                 export JFROG_VERSION=$JFROG_VERSION && \
                 export JFROG_EDITION=$JFROG_EDITION && \
                 export CERT_MODE=step-ca && \
                 export CA_URL=$CA_URL && \
                 export FINGERPRINT=$FINGERPRINT && \
                 export NET_NAME=$NETWORK && \
                 cd /opt/kcli-pipelines && \
                 ./jfrog/deploy.sh create"
        else
            echo "[WARN] Step-CA not available, using self-signed"
            CERT_MODE="self-signed"
        fi
    fi
    
    if [ "$CERT_MODE" == "self-signed" ]; then
        # Create JFrog with self-signed certs
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "export VM_NAME=$VM_NAME && \
             export JFROG_VERSION=$JFROG_VERSION && \
             export JFROG_EDITION=$JFROG_EDITION && \
             export CERT_MODE=self-signed && \
             export NET_NAME=$NETWORK && \
             cd /opt/kcli-pipelines && \
             ./jfrog/deploy.sh create"
    fi
    
    echo ""
    echo "[OK] JFrog deployment initiated"
    ''',
    execution_timeout=timedelta(minutes=45),
    dag=dag,
)


# Task: Wait for JFrog VM
wait_for_jfrog = BashOperator(
    task_id='wait_for_jfrog_vm',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Waiting for JFrog VM"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    MAX_ATTEMPTS=40
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
                echo "[OK] JFrog VM is accessible at $IP"
                exit 0
            fi
        fi
        
        sleep 30
    done
    
    echo "[WARN] Timeout waiting for JFrog VM - may still be provisioning"
    ''',
    execution_timeout=timedelta(minutes=20),
    dag=dag,
)


# Task: Validate JFrog is healthy
validate_jfrog_health = BashOperator(
    task_id='validate_jfrog_health',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Validating JFrog Health"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    
    # Get VM IP
    IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli info vm $VM_NAME 2>/dev/null | grep 'ip:' | awk '{print \$2}' | head -1")
    
    if [ -z "$IP" ]; then
        echo "[ERROR] Could not get VM IP"
        exit 1
    fi
    
    echo "JFrog VM IP: $IP"
    
    # Wait for Artifactory to be ready (can take 2-3 minutes after VM boots)
    echo "Waiting for Artifactory service to be ready..."
    MAX_ATTEMPTS=30
    ATTEMPT=0
    
    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        ATTEMPT=$((ATTEMPT + 1))
        
        # Check Artifactory ping endpoint
        PING=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "curl -s http://$IP:8082/artifactory/api/system/ping 2>/dev/null" || true)
        
        if echo "$PING" | grep -qi "OK"; then
            echo ""
            echo "[OK] JFrog Artifactory is HEALTHY"
            echo "Ping: $PING"
            exit 0
        fi
        
        echo "Waiting for Artifactory to become healthy... ($ATTEMPT/$MAX_ATTEMPTS)"
        sleep 30
    done
    
    echo ""
    echo "[WARN] Artifactory health check timed out"
    echo "Artifactory may still be initializing. Check manually:"
    echo "  curl http://$IP:8082/artifactory/api/system/ping"
    ''',
    execution_timeout=timedelta(minutes=20),
    dag=dag,
)


# Task: Complete deployment
deployment_complete = BashOperator(
    task_id='deployment_complete',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "JFrog Artifactory Deployment Complete"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    DOMAIN="{{ params.domain }}"
    JFROG_EDITION="{{ params.jfrog_edition }}"
    
    # Get VM info
    IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli info vm $VM_NAME 2>/dev/null | grep 'ip:' | awk '{print \$2}' | head -1")
    
    echo ""
    echo "JFrog Artifactory Details:"
    echo "  VM Name: $VM_NAME"
    echo "  IP Address: $IP"
    echo "  Edition: $JFROG_EDITION"
    echo "  UI URL: http://${IP}:8082/ui"
    echo "  API URL: http://${IP}:8082/artifactory"
    echo ""
    echo "Default credentials:"
    echo "  User: admin"
    echo "  Password: password"
    echo ""
    echo "To configure as Docker registry:"
    echo "  podman login ${IP}:8082"
    echo "  podman push myimage:latest ${IP}:8082/docker-local/myimage:latest"
    
    echo ""
    echo "========================================"
    echo "JFrog Artifactory is ready"
    echo "========================================"
    ''',
    dag=dag,
)


# Task: Health check (standalone)
health_check = BashOperator(
    task_id='health_check',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "JFrog Artifactory Health Check"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    
    # Get VM IP
    IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli info vm $VM_NAME 2>/dev/null | grep 'ip:' | awk '{print \$2}' | head -1")
    
    if [ -z "$IP" ]; then
        echo "[ERROR] VM $VM_NAME not found or has no IP"
        exit 1
    fi
    
    echo "JFrog VM: $VM_NAME"
    echo "IP Address: $IP"
    echo ""
    
    echo "Checking JFrog Artifactory health..."
    PING=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "curl -s http://$IP:8082/artifactory/api/system/ping 2>/dev/null")
    
    if echo "$PING" | grep -qi "OK"; then
        echo "[OK] JFrog Artifactory is HEALTHY"
        echo "Ping: $PING"
        
        # Get version info
        echo ""
        echo "Version Info:"
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "curl -s http://$IP:8082/artifactory/api/system/version 2>/dev/null" | jq . || true
        exit 0
    else
        echo "[ERROR] JFrog Artifactory is NOT HEALTHY"
        echo "Response: $PING"
        exit 1
    fi
    ''',
    dag=dag,
)


# Task: Delete JFrog
delete_jfrog = BashOperator(
    task_id='delete_jfrog',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Deleting JFrog Artifactory"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    
    echo "Deleting VM: $VM_NAME"
    
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "export VM_NAME=$VM_NAME && \
         cd /opt/kcli-pipelines && \
         ./jfrog/deploy.sh delete" || \
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "kcli delete vm $VM_NAME -y" || \
        echo "[WARN] VM may not exist"
    
    echo "[OK] JFrog Artifactory deleted"
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
    echo "JFrog Artifactory Status"
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
        echo "Health Check:"
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "curl -s http://$IP:8082/artifactory/api/system/ping 2>/dev/null" || echo "Health check failed"
    fi
    ''',
    dag=dag,
)


# Define task dependencies
# Main create flow
decide_action_task >> check_prerequisites >> validate_environment >> create_jfrog
create_jfrog >> wait_for_jfrog >> validate_jfrog_health >> deployment_complete

# Alternative flows
decide_action_task >> delete_jfrog
decide_action_task >> check_status
decide_action_task >> health_check

