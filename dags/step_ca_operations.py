"""
Airflow DAG: Step-CA Certificate Operations
Utility DAG for managing certificates after Step-CA deployment

Operations:
- request_certificate: Request a new certificate
- renew_certificate: Renew an existing certificate
- revoke_certificate: Revoke a certificate
- bootstrap_client: Bootstrap a client to trust the CA
- get_ca_info: Get CA information (fingerprint, root cert)

Requires: Step-CA server deployed via step_ca_deployment DAG
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
    'retry_delay': timedelta(minutes=2),
}

dag = DAG(
    'step_ca_operations',
    default_args=default_args,
    description='Certificate operations using Step-CA (request, renew, revoke)',
    schedule=None,
    catchup=False,
    tags=['qubinode', 'kcli-pipelines', 'step-ca', 'certificates', 'utility'],
    params={
        'operation': 'get_ca_info',  # get_ca_info, request_certificate, renew_certificate, revoke_certificate, bootstrap_client
        'ca_url': 'https://step-ca-server.example.com:443',
        'common_name': '',  # e.g., myservice.example.com
        'san_list': '',  # comma-separated SANs, e.g., "myservice,192.168.1.100"
        'duration': '720h',  # Certificate duration (default 30 days)
        'output_path': '/tmp/certs',  # Where to save certificates
        'cert_path': '',  # Path to existing cert (for renew/revoke)
        'key_path': '',  # Path to existing key (for renew)
        'target_host': '',  # Host to bootstrap or copy certs to
        'provisioner': 'acme',  # Provisioner to use (acme, admin)
    },
    doc_md="""
    # Step-CA Certificate Operations
    
    Utility DAG for managing certificates after Step-CA deployment.
    
    ## Operations
    
    ### get_ca_info
    Get CA fingerprint and root certificate.
    ```json
    {"operation": "get_ca_info", "ca_url": "https://step-ca-server.example.com:443"}
    ```
    
    ### request_certificate
    Request a new certificate.
    ```json
    {
        "operation": "request_certificate",
        "ca_url": "https://step-ca-server.example.com:443",
        "common_name": "myservice.example.com",
        "san_list": "myservice,localhost,192.168.1.100",
        "duration": "720h",
        "output_path": "/tmp/certs"
    }
    ```
    
    ### renew_certificate
    Renew an existing certificate.
    ```json
    {
        "operation": "renew_certificate",
        "cert_path": "/etc/certs/server.crt",
        "key_path": "/etc/certs/server.key"
    }
    ```
    
    ### revoke_certificate
    Revoke a certificate.
    ```json
    {
        "operation": "revoke_certificate",
        "cert_path": "/etc/certs/server.crt"
    }
    ```
    
    ### bootstrap_client
    Bootstrap a remote host to trust the CA.
    ```json
    {
        "operation": "bootstrap_client",
        "ca_url": "https://step-ca-server.example.com:443",
        "target_host": "webserver.example.com"
    }
    ```
    
    ## Prerequisites
    - Step-CA server deployed
    - step CLI installed on host
    - CA bootstrapped on host (for certificate operations)
    """,
)


def decide_operation(**context):
    """Branch based on operation parameter"""
    operation = context['params'].get('operation', 'get_ca_info')
    valid_operations = [
        'get_ca_info',
        'request_certificate', 
        'renew_certificate',
        'revoke_certificate',
        'bootstrap_client'
    ]
    if operation in valid_operations:
        return operation
    return 'get_ca_info'


# Task: Ensure step CLI is installed on host
ensure_step_cli = BashOperator(
    task_id='ensure_step_cli',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Ensuring step CLI is installed on host"
    echo "========================================"
    
    # Check if step CLI is installed on host
    if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "which step" &>/dev/null; then
        echo "[OK] step CLI is already installed"
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost "step version"
    else
        echo "[INFO] Installing step CLI on host..."
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "wget -q https://dl.smallstep.com/cli/docs-ca-install/latest/step-cli_amd64.rpm -O /tmp/step-cli_amd64.rpm && \
             rpm -i /tmp/step-cli_amd64.rpm 2>/dev/null || rpm -U /tmp/step-cli_amd64.rpm && \
             step version"
        
        if [ $? -eq 0 ]; then
            echo "[OK] step CLI installed successfully"
        else
            echo "[ERROR] Failed to install step CLI"
            exit 1
        fi
    fi
    ''',
    dag=dag,
)

# Task: Decide operation
decide_operation_task = BranchPythonOperator(
    task_id='decide_operation',
    python_callable=decide_operation,
    dag=dag,
)

# Task: Get CA Info
get_ca_info = BashOperator(
    task_id='get_ca_info',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Step-CA Information"
    echo "========================================"
    
    CA_URL="{{ params.ca_url }}"
    
    # Get CA health
    echo ""
    echo "CA Health Check:"
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "curl -sk ${CA_URL}/health" || echo "Health check failed"
    
    # Get root CA certificate
    echo ""
    echo "Root CA Certificate:"
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "step ca root --ca-url ${CA_URL} /tmp/root_ca.crt 2>/dev/null && cat /tmp/root_ca.crt" || \
        echo "Could not fetch root CA (may need to bootstrap first)"
    
    # Get fingerprint
    echo ""
    echo "CA Fingerprint:"
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "step certificate fingerprint /tmp/root_ca.crt 2>/dev/null" || \
        echo "Could not get fingerprint"
    
    # List provisioners
    echo ""
    echo "Available Provisioners:"
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "step ca provisioner list --ca-url ${CA_URL} 2>/dev/null" || \
        echo "Could not list provisioners"
    
    echo ""
    echo "========================================"
    echo "CA URL: ${CA_URL}"
    echo "========================================"
    ''',
    dag=dag,
)

# Task: Request Certificate
request_certificate = BashOperator(
    task_id='request_certificate',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Certificate Request Instructions"
    echo "========================================"
    
    CA_URL="{{ params.ca_url }}"
    COMMON_NAME="{{ params.common_name }}"
    SAN_LIST="{{ params.san_list }}"
    OUTPUT_PATH="{{ params.output_path }}"
    
    if [ -z "$COMMON_NAME" ]; then
        echo "[ERROR] common_name parameter is required"
        exit 1
    fi
    
    # Get Step-CA VM IP from CA URL
    STEP_CA_IP=$(echo $CA_URL | sed 's|https://||' | sed 's|:.*||')
    
    echo ""
    echo "To request a certificate for: $COMMON_NAME"
    echo ""
    echo "Step 1: SSH to the Qubinode host and run:"
    echo "========================================"
    echo ""
    echo "# Get a token from Step-CA"
    echo "TOKEN=\\$(ssh cloud-user@${STEP_CA_IP} \"sudo step ca token ${COMMON_NAME} --ca-url https://localhost:443 --password-file /etc/step/initial_password --provisioner 'admin@example.com'\" | tail -1)"
    echo ""
    echo "# Request the certificate"
    echo "mkdir -p ${OUTPUT_PATH}"
    if [ -n "$SAN_LIST" ]; then
        SAN_ARGS=""
        IFS=',' read -ra SANS <<< "$SAN_LIST"
        for san in "${SANS[@]}"; do
            SAN_ARGS="$SAN_ARGS --san $san"
        done
        echo "step ca certificate ${COMMON_NAME} ${OUTPUT_PATH}/${COMMON_NAME}.crt ${OUTPUT_PATH}/${COMMON_NAME}.key --ca-url ${CA_URL} --token \"\\$TOKEN\" ${SAN_ARGS} --force"
    else
        echo "step ca certificate ${COMMON_NAME} ${OUTPUT_PATH}/${COMMON_NAME}.crt ${OUTPUT_PATH}/${COMMON_NAME}.key --ca-url ${CA_URL} --token \"\\$TOKEN\" --force"
    fi
    echo ""
    echo "========================================"
    echo ""
    echo "Or use the helper script (if available):"
    echo "  /tmp/request_cert.sh '${STEP_CA_IP}' '${CA_URL}' '${COMMON_NAME}' '${OUTPUT_PATH}' '${SAN_ARGS:-}'"
    echo ""
    echo "========================================"
    echo "Quick One-Liner (run on Qubinode host):"
    echo "========================================"
    echo ""
    echo "TOKEN=\\$(ssh cloud-user@${STEP_CA_IP} \"sudo step ca token ${COMMON_NAME} --ca-url https://localhost:443 --password-file /etc/step/initial_password --provisioner 'admin@example.com'\" | tail -1) && step ca certificate ${COMMON_NAME} ${OUTPUT_PATH}/${COMMON_NAME}.crt ${OUTPUT_PATH}/${COMMON_NAME}.key --ca-url ${CA_URL} --token \"\\$TOKEN\" --force"
    echo ""
    echo "========================================"
    echo "Certificate will be saved to:"
    echo "  Certificate: ${OUTPUT_PATH}/${COMMON_NAME}.crt"
    echo "  Private Key: ${OUTPUT_PATH}/${COMMON_NAME}.key"
    echo "========================================"
    ''',
    execution_timeout=timedelta(minutes=2),
    dag=dag,
)

# Task: Renew Certificate
renew_certificate = BashOperator(
    task_id='renew_certificate',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Certificate Renewal Instructions"
    echo "========================================"
    
    CERT_PATH="{{ params.cert_path }}"
    KEY_PATH="{{ params.key_path }}"
    
    if [ -z "$CERT_PATH" ] || [ -z "$KEY_PATH" ]; then
        echo "[ERROR] cert_path and key_path parameters are required"
        echo ""
        echo "Example usage:"
        echo '  {"operation": "renew_certificate", "cert_path": "/tmp/certs/myservice.crt", "key_path": "/tmp/certs/myservice.key"}'
        exit 1
    fi
    
    echo ""
    echo "To renew certificate: $CERT_PATH"
    echo ""
    echo "Run on Qubinode host:"
    echo "========================================"
    echo ""
    echo "# Check current certificate expiry"
    echo "step certificate inspect --short ${CERT_PATH}"
    echo ""
    echo "# Renew the certificate"
    echo "step ca renew --force ${CERT_PATH} ${KEY_PATH}"
    echo ""
    echo "========================================"
    ''',
    execution_timeout=timedelta(minutes=2),
    dag=dag,
)

# Task: Revoke Certificate
revoke_certificate = BashOperator(
    task_id='revoke_certificate',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Certificate Revocation Instructions"
    echo "========================================"
    
    CERT_PATH="{{ params.cert_path }}"
    CA_URL="{{ params.ca_url }}"
    
    if [ -z "$CERT_PATH" ]; then
        echo "[ERROR] cert_path parameter is required"
        echo ""
        echo "Example usage:"
        echo '  {"operation": "revoke_certificate", "cert_path": "/tmp/certs/myservice.crt", "ca_url": "https://step-ca:443"}'
        exit 1
    fi
    
    echo ""
    echo "To revoke certificate: $CERT_PATH"
    echo ""
    echo "Run on Qubinode host:"
    echo "========================================"
    echo ""
    echo "# View certificate details first"
    echo "step certificate inspect --short ${CERT_PATH}"
    echo ""
    echo "# Revoke the certificate"
    echo "step ca revoke --cert ${CERT_PATH} --ca-url ${CA_URL}"
    echo ""
    echo "========================================"
    echo ""
    echo "WARNING: Certificate revocation is permanent!"
    echo "========================================"
    ''',
    execution_timeout=timedelta(minutes=2),
    dag=dag,
)

# Task: Bootstrap Client
bootstrap_client = BashOperator(
    task_id='bootstrap_client',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Client Bootstrap Instructions"
    echo "========================================"
    
    CA_URL="{{ params.ca_url }}"
    TARGET_HOST="{{ params.target_host }}"
    
    # Get Step-CA VM IP from CA URL
    STEP_CA_IP=$(echo $CA_URL | sed 's|https://||' | sed 's|:.*||')
    
    echo ""
    echo "CA URL: $CA_URL"
    echo "Step-CA IP: $STEP_CA_IP"
    if [ -n "$TARGET_HOST" ]; then
        echo "Target Host: $TARGET_HOST"
    fi
    
    echo ""
    echo "Step 1: Get the CA fingerprint"
    echo "========================================"
    echo ""
    echo "# From the Qubinode host:"
    echo "FINGERPRINT=\\$(ssh cloud-user@${STEP_CA_IP} 'sudo step certificate fingerprint /root/.step/certs/root_ca.crt')"
    echo ""
    echo "# Or from the CA URL:"
    echo "FINGERPRINT=\\$(curl -sk ${CA_URL}/roots.pem | step certificate fingerprint /dev/stdin)"
    echo ""
    
    echo "Step 2: Bootstrap the client"
    echo "========================================"
    echo ""
    if [ -n "$TARGET_HOST" ] && [ "$TARGET_HOST" != "localhost" ]; then
        echo "# On the target host (${TARGET_HOST}):"
        echo ""
        echo "# First install step CLI if not present:"
        echo "wget -q https://dl.smallstep.com/cli/docs-ca-install/latest/step-cli_amd64.rpm && sudo rpm -i step-cli_amd64.rpm"
        echo ""
        echo "# Then bootstrap:"
        echo "step ca bootstrap --ca-url ${CA_URL} --fingerprint \\$FINGERPRINT --install"
    else
        echo "# On the Qubinode host (localhost):"
        echo "step ca bootstrap --ca-url ${CA_URL} --fingerprint \\$FINGERPRINT --install"
    fi
    echo ""
    
    echo "========================================"
    echo "Quick One-Liner (run on target host):"
    echo "========================================"
    echo ""
    echo "FINGERPRINT=\\$(curl -sk ${CA_URL}/roots.pem | step certificate fingerprint /dev/stdin) && step ca bootstrap --ca-url ${CA_URL} --fingerprint \\$FINGERPRINT --install"
    echo ""
    echo "========================================"
    echo ""
    echo "After bootstrapping, you can request certificates with:"
    echo "  step ca certificate <hostname> cert.crt key.key"
    echo "========================================"
    ''',
    execution_timeout=timedelta(minutes=2),
    dag=dag,
)

# Define task dependencies
# First ensure step CLI is installed, then decide operation, then run the selected operation
ensure_step_cli >> decide_operation_task >> [get_ca_info, request_certificate, renew_certificate, revoke_certificate, bootstrap_client]
