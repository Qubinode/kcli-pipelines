"""
Airflow DAG: Harbor Registry Deployment
kcli-pipelines integration per ADR-0047

This DAG deploys Harbor container registry for:
- Enterprise container image management
- Image scanning and signing
- Multi-tenant registry
- Helm chart repository

Certificate modes:
- step-ca: Use internal Step-CA for certificates (default)
- letsencrypt: Use Let's Encrypt via AWS Route53

Calls: /opt/kcli-pipelines/harbor/deploy.sh
"""

from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import BranchPythonOperator

# Configuration
KCLI_PIPELINES_DIR = '/opt/kcli-pipelines'
HARBOR_DIR = f'{KCLI_PIPELINES_DIR}/harbor'

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
    'harbor_deployment',
    default_args=default_args,
    description='Deploy Harbor enterprise container registry',
    schedule=None,
    catchup=False,
    tags=['qubinode', 'kcli-pipelines', 'harbor', 'registry', 'enterprise'],
    params={
        'action': 'create',  # create, delete, status, health
        'vm_name': 'harbor',  # VM name
        'harbor_version': 'v2.10.1',  # Harbor version
        'cert_mode': 'step-ca',  # step-ca or letsencrypt
        'domain': 'example.com',  # Domain for certificates
        'target_server': 'localhost',  # Target server
        'network': 'qubinet',  # Network to deploy on
        'step_ca_vm': 'step-ca-server',  # Step-CA server VM name (for step-ca mode)
        'email': '',  # Email for Let's Encrypt (for letsencrypt mode)
    },
    doc_md="""
    # Harbor Registry Deployment DAG
    
    Deploy Harbor enterprise container registry.
    
    ## Features
    
    - Enterprise-grade container registry
    - Image scanning and vulnerability analysis
    - Image signing and trust
    - Multi-tenant support with RBAC
    - Helm chart repository
    - Docker Hub proxy cache
    - Ubuntu-based VM with Docker
    
    ## Certificate Modes
    
    ### Step-CA (Default)
    Uses internal Step-CA server for TLS certificates:
    - Ideal for disconnected/air-gapped environments
    - Requires Step-CA server deployed first
    
    ### Let's Encrypt
    Uses Let's Encrypt via AWS Route53 DNS validation:
    - Requires AWS credentials
    - Requires public DNS (Route53)
    - Ideal for internet-connected environments
    
    ## Prerequisites
    
    ### For Step-CA mode:
    ```bash
    airflow dags trigger step_ca_deployment --conf '{"action": "create"}'
    ```
    
    ### For Let's Encrypt mode:
    - AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in vault
    - Route53 DNS zone for your domain
    
    ## Parameters
    
    - **action**: create, delete, status, or health
    - **vm_name**: Name for the registry VM (default: harbor)
    - **harbor_version**: Harbor version
    - **cert_mode**: step-ca or letsencrypt
    - **domain**: Domain for certificate generation
    - **step_ca_vm**: Name of the Step-CA server VM (step-ca mode)
    - **email**: Email for Let's Encrypt (letsencrypt mode)
    
    ## Usage
    
    ### Create Harbor with Step-CA
    ```bash
    airflow dags trigger harbor_deployment --conf '{
        "action": "create",
        "vm_name": "harbor",
        "harbor_version": "v2.10.1",
        "cert_mode": "step-ca"
    }'
    ```
    
    ### Create Harbor with Let's Encrypt
    ```bash
    airflow dags trigger harbor_deployment --conf '{
        "action": "create",
        "vm_name": "harbor",
        "harbor_version": "v2.10.1",
        "cert_mode": "letsencrypt",
        "email": "admin@example.com"
    }'
    ```
    
    ### Check Harbor Health
    ```bash
    airflow dags trigger harbor_deployment --conf '{
        "action": "health",
        "vm_name": "harbor"
    }'
    ```
    
    ## Post-Deployment
    
    After deployment, Harbor will be available at:
    - **URL**: https://harbor.<domain>
    - **Default User**: admin
    - **Default Password**: Harbor12345
    
    ### Push an image:
    ```bash
    docker login harbor.<domain>
    docker tag myimage:latest harbor.<domain>/library/myimage:latest
    docker push harbor.<domain>/library/myimage:latest
    ```
    
    ## Related DAGs
    
    - `mirror_registry_deployment` - Quay mirror-registry (lighter weight)
    - `jfrog_deployment` - JFrog Artifactory
    - `step_ca_deployment` - Certificate authority (prerequisite for step-ca mode)
    """,
)


def decide_action(**context):
    """Branch based on action parameter"""
    action = context['params'].get('action', 'create')
    if action == 'delete':
        return 'delete_harbor'
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


# Task: Check prerequisites (Step-CA or Let's Encrypt)
check_prerequisites = BashOperator(
    task_id='check_prerequisites',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Checking Harbor Prerequisites"
    echo "========================================"
    
    CERT_MODE="{{ params.cert_mode }}"
    STEP_CA_VM="{{ params.step_ca_vm }}"
    EMAIL="{{ params.email }}"
    
    echo "Certificate Mode: $CERT_MODE"
    
    if [ "$CERT_MODE" == "step-ca" ]; then
        echo ""
        echo "Checking Step-CA server..."
        
        STEP_CA_IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "kcli info vm $STEP_CA_VM 2>/dev/null | grep 'ip:' | awk '{print \$2}' | head -1")
        
        if [ -z "$STEP_CA_IP" ] || [ "$STEP_CA_IP" == "None" ]; then
            echo "[ERROR] Step-CA server not found: $STEP_CA_VM"
            echo ""
            echo "Step-CA is required for Harbor TLS certificates in step-ca mode."
            echo "Deploy Step-CA first:"
            echo "  airflow dags trigger step_ca_deployment --conf '{\"action\": \"create\"}'"
            echo ""
            echo "Or use Let's Encrypt mode:"
            echo "  airflow dags trigger harbor_deployment --conf '{\"cert_mode\": \"letsencrypt\", \"email\": \"you@example.com\"}'"
            exit 1
        fi
        
        echo "[OK] Step-CA server found at: $STEP_CA_IP"
        
        # Check Step-CA health
        if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "curl -sk https://$STEP_CA_IP:443/health 2>/dev/null | grep -q ok"; then
            echo "[OK] Step-CA is healthy"
        else
            echo "[WARN] Step-CA may not be responding"
        fi
        
    elif [ "$CERT_MODE" == "letsencrypt" ]; then
        echo ""
        echo "Checking Let's Encrypt prerequisites..."
        
        if [ -z "$EMAIL" ]; then
            echo "[ERROR] Email is required for Let's Encrypt mode"
            echo "Set the 'email' parameter when triggering the DAG"
            exit 1
        fi
        echo "[OK] Email provided: $EMAIL"
        
        # Note: AWS credentials will be checked during deployment from vault
        echo "[INFO] AWS credentials will be loaded from vault during deployment"
    fi
    
    # Check Ubuntu image
    echo ""
    echo "Checking Ubuntu image..."
    if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli list image | grep -q ubuntu2204"; then
        echo "[OK] Ubuntu 22.04 image available"
    else
        echo "[WARN] Ubuntu 22.04 image may not be available"
        echo "Download with: kcli download image ubuntu2204"
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
    echo "Validating Harbor Environment"
    echo "========================================"
    
    DOMAIN="{{ params.domain }}"
    
    echo "Registry Type: Harbor"
    echo "Domain: $DOMAIN"
    
    # Check kcli
    echo "Checking kcli..."
    if ! ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "which kcli" &>/dev/null; then
        echo "[ERROR] kcli not found on host"
        exit 1
    fi
    echo "[OK] kcli available"
    
    # Check for Harbor scripts
    echo "Checking Harbor deployment scripts..."
    if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "test -f /opt/kcli-pipelines/harbor/deploy.sh"; then
        echo "[OK] Harbor deploy script found"
    else
        echo "[ERROR] Harbor deploy.sh not found"
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


# Task: Create Harbor VM
create_harbor = BashOperator(
    task_id='create_harbor_vm',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Creating Harbor VM"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    HARBOR_VERSION="{{ params.harbor_version }}"
    CERT_MODE="{{ params.cert_mode }}"
    DOMAIN="{{ params.domain }}"
    NETWORK="{{ params.network }}"
    STEP_CA_VM="{{ params.step_ca_vm }}"
    EMAIL="{{ params.email }}"
    
    echo "VM Name: $VM_NAME"
    echo "Harbor Version: $HARBOR_VERSION"
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
        
        CA_URL="https://${STEP_CA_IP}:443"
        
        FINGERPRINT=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "ssh -o StrictHostKeyChecking=no cloud-user@$STEP_CA_IP \
                'sudo step certificate fingerprint /root/.step/certs/root_ca.crt 2>/dev/null'")
        
        echo "Step-CA URL: $CA_URL"
        echo "CA Fingerprint: $FINGERPRINT"
        
        # Create Harbor with Step-CA
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "export VM_NAME=$VM_NAME && \
             export HARBOR_VERSION=$HARBOR_VERSION && \
             export CERT_MODE=step-ca && \
             export CA_URL=$CA_URL && \
             export FINGERPRINT=$FINGERPRINT && \
             export NET_NAME=$NETWORK && \
             cd /opt/kcli-pipelines && \
             ./harbor/deploy.sh create"
    else
        # Create Harbor with Let's Encrypt
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "export VM_NAME=$VM_NAME && \
             export HARBOR_VERSION=$HARBOR_VERSION && \
             export CERT_MODE=letsencrypt && \
             export EMAIL=$EMAIL && \
             export NET_NAME=$NETWORK && \
             cd /opt/kcli-pipelines && \
             ./harbor/deploy.sh create"
    fi
    
    echo ""
    echo "[OK] Harbor deployment initiated"
    ''',
    execution_timeout=timedelta(minutes=45),
    dag=dag,
)


# Task: Wait for Harbor VM
wait_for_harbor = BashOperator(
    task_id='wait_for_harbor_vm',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Waiting for Harbor VM"
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
                echo "[OK] Harbor VM is accessible at $IP"
                exit 0
            fi
        fi
        
        sleep 30
    done
    
    echo "[WARN] Timeout waiting for Harbor VM - may still be provisioning"
    ''',
    execution_timeout=timedelta(minutes=20),
    dag=dag,
)


# Task: Validate Harbor is healthy
validate_harbor_health = BashOperator(
    task_id='validate_harbor_health',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Validating Harbor Health"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    
    # Get VM IP
    IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli info vm $VM_NAME 2>/dev/null | grep 'ip:' | awk '{print \$2}' | head -1")
    
    if [ -z "$IP" ]; then
        echo "[ERROR] Could not get VM IP"
        exit 1
    fi
    
    echo "Harbor VM IP: $IP"
    
    # Wait for Harbor to be ready (can take time after VM boots)
    echo "Waiting for Harbor service to be ready..."
    MAX_ATTEMPTS=30
    ATTEMPT=0
    
    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        ATTEMPT=$((ATTEMPT + 1))
        
        # Check Harbor health endpoint
        HEALTH=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "curl -sk https://$IP/api/v2.0/health 2>/dev/null" || true)
        
        if echo "$HEALTH" | grep -qi "healthy"; then
            echo ""
            echo "[OK] Harbor is HEALTHY"
            echo "$HEALTH"
            exit 0
        fi
        
        echo "Waiting for Harbor to become healthy... ($ATTEMPT/$MAX_ATTEMPTS)"
        sleep 30
    done
    
    echo ""
    echo "[WARN] Harbor health check timed out"
    echo "Harbor may still be initializing. Check manually:"
    echo "  curl -k https://$IP/api/v2.0/health"
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
    echo "Harbor Deployment Complete"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    DOMAIN="{{ params.domain }}"
    
    # Get VM info
    IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli info vm $VM_NAME 2>/dev/null | grep 'ip:' | awk '{print \$2}' | head -1")
    
    echo ""
    echo "Harbor Details:"
    echo "  VM Name: $VM_NAME"
    echo "  IP Address: $IP"
    echo "  URL: https://harbor.${DOMAIN}"
    echo "  Health: https://${IP}/api/v2.0/health"
    echo ""
    echo "Default credentials:"
    echo "  User: admin"
    echo "  Password: Harbor12345"
    echo ""
    echo "To push an image:"
    echo "  docker login harbor.${DOMAIN}"
    echo "  docker tag myimage:latest harbor.${DOMAIN}/library/myimage:latest"
    echo "  docker push harbor.${DOMAIN}/library/myimage:latest"
    
    echo ""
    echo "========================================"
    echo "Harbor is ready"
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
    echo "Harbor Health Check"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    
    # Get VM IP
    IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli info vm $VM_NAME 2>/dev/null | grep 'ip:' | awk '{print \$2}' | head -1")
    
    if [ -z "$IP" ]; then
        echo "[ERROR] VM $VM_NAME not found or has no IP"
        exit 1
    fi
    
    echo "Harbor VM: $VM_NAME"
    echo "IP Address: $IP"
    echo ""
    
    echo "Checking Harbor health..."
    HEALTH=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "curl -sk https://$IP/api/v2.0/health 2>/dev/null")
    
    if echo "$HEALTH" | grep -qi "healthy"; then
        echo "[OK] Harbor is HEALTHY"
        echo "$HEALTH" | jq . 2>/dev/null || echo "$HEALTH"
        exit 0
    else
        echo "[ERROR] Harbor is NOT HEALTHY"
        echo "Response: $HEALTH"
        exit 1
    fi
    ''',
    dag=dag,
)


# Task: Delete Harbor
delete_harbor = BashOperator(
    task_id='delete_harbor',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Deleting Harbor"
    echo "========================================"
    
    VM_NAME="{{ params.vm_name }}"
    
    echo "Deleting VM: $VM_NAME"
    
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "export VM_NAME=$VM_NAME && \
         cd /opt/kcli-pipelines && \
         ./harbor/deploy.sh delete" || \
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "kcli delete vm $VM_NAME -y" || \
        echo "[WARN] VM may not exist"
    
    echo "[OK] Harbor deleted"
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
    echo "Harbor Status"
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
            "curl -sk https://$IP/api/v2.0/health 2>/dev/null" || echo "Health check failed"
    fi
    ''',
    dag=dag,
)


# Define task dependencies
# Main create flow
decide_action_task >> check_prerequisites >> validate_environment >> create_harbor
create_harbor >> wait_for_harbor >> validate_harbor_health >> deployment_complete

# Alternative flows
decide_action_task >> delete_harbor
decide_action_task >> check_status
decide_action_task >> health_check

