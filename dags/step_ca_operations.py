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
    
    # Check if step CLI is installed on host
    if ! ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "which step" &>/dev/null; then
        echo "[ERROR] step CLI not installed on host"
        echo "Install with: wget https://dl.smallstep.com/cli/docs-ca-install/latest/step-cli_amd64.rpm && rpm -i step-cli_amd64.rpm"
        exit 1
    fi
    
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
    echo "Requesting Certificate"
    echo "========================================"
    
    CA_URL="{{ params.ca_url }}"
    COMMON_NAME="{{ params.common_name }}"
    SAN_LIST="{{ params.san_list }}"
    DURATION="{{ params.duration }}"
    OUTPUT_PATH="{{ params.output_path }}"
    PROVISIONER="{{ params.provisioner }}"
    
    if [ -z "$COMMON_NAME" ]; then
        echo "[ERROR] common_name parameter is required"
        exit 1
    fi
    
    echo "Common Name: $COMMON_NAME"
    echo "SANs: $SAN_LIST"
    echo "Duration: $DURATION"
    echo "Output Path: $OUTPUT_PATH"
    echo "Provisioner: $PROVISIONER"
    
    # Build SAN arguments
    SAN_ARGS=""
    if [ -n "$SAN_LIST" ]; then
        IFS=',' read -ra SANS <<< "$SAN_LIST"
        for san in "${SANS[@]}"; do
            SAN_ARGS="$SAN_ARGS --san $san"
        done
    fi
    
    # Request certificate on host
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "mkdir -p ${OUTPUT_PATH} && \
         step ca certificate ${COMMON_NAME} \
           ${OUTPUT_PATH}/${COMMON_NAME}.crt \
           ${OUTPUT_PATH}/${COMMON_NAME}.key \
           --ca-url ${CA_URL} \
           --provisioner ${PROVISIONER} \
           --not-after ${DURATION} \
           ${SAN_ARGS} \
           --force"
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "========================================"
        echo "[OK] Certificate Generated"
        echo "========================================"
        echo "Certificate: ${OUTPUT_PATH}/${COMMON_NAME}.crt"
        echo "Private Key: ${OUTPUT_PATH}/${COMMON_NAME}.key"
        echo ""
        echo "Certificate Details:"
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "step certificate inspect --short ${OUTPUT_PATH}/${COMMON_NAME}.crt"
    else
        echo "[ERROR] Certificate request failed"
        exit 1
    fi
    ''',
    execution_timeout=timedelta(minutes=5),
    dag=dag,
)

# Task: Renew Certificate
renew_certificate = BashOperator(
    task_id='renew_certificate',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Renewing Certificate"
    echo "========================================"
    
    CERT_PATH="{{ params.cert_path }}"
    KEY_PATH="{{ params.key_path }}"
    
    if [ -z "$CERT_PATH" ] || [ -z "$KEY_PATH" ]; then
        echo "[ERROR] cert_path and key_path parameters are required"
        exit 1
    fi
    
    echo "Certificate: $CERT_PATH"
    echo "Private Key: $KEY_PATH"
    
    # Check certificate expiry
    echo ""
    echo "Current Certificate:"
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "step certificate inspect --short ${CERT_PATH}"
    
    # Renew certificate
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "step ca renew --force ${CERT_PATH} ${KEY_PATH}"
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "========================================"
        echo "[OK] Certificate Renewed"
        echo "========================================"
        echo "New Certificate Details:"
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "step certificate inspect --short ${CERT_PATH}"
    else
        echo "[ERROR] Certificate renewal failed"
        exit 1
    fi
    ''',
    execution_timeout=timedelta(minutes=5),
    dag=dag,
)

# Task: Revoke Certificate
revoke_certificate = BashOperator(
    task_id='revoke_certificate',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Revoking Certificate"
    echo "========================================"
    
    CERT_PATH="{{ params.cert_path }}"
    CA_URL="{{ params.ca_url }}"
    
    if [ -z "$CERT_PATH" ]; then
        echo "[ERROR] cert_path parameter is required"
        exit 1
    fi
    
    echo "Certificate: $CERT_PATH"
    
    # Show certificate details before revocation
    echo ""
    echo "Certificate to Revoke:"
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "step certificate inspect --short ${CERT_PATH}"
    
    # Revoke certificate
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "step ca revoke --cert ${CERT_PATH} --ca-url ${CA_URL}"
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "========================================"
        echo "[OK] Certificate Revoked"
        echo "========================================"
    else
        echo "[ERROR] Certificate revocation failed"
        exit 1
    fi
    ''',
    execution_timeout=timedelta(minutes=5),
    dag=dag,
)

# Task: Bootstrap Client
bootstrap_client = BashOperator(
    task_id='bootstrap_client',
    bash_command='''
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Bootstrapping Client"
    echo "========================================"
    
    CA_URL="{{ params.ca_url }}"
    TARGET_HOST="{{ params.target_host }}"
    
    if [ -z "$TARGET_HOST" ]; then
        echo "No target_host specified, bootstrapping localhost"
        TARGET_HOST="localhost"
    fi
    
    echo "CA URL: $CA_URL"
    echo "Target Host: $TARGET_HOST"
    
    # Get CA fingerprint first
    echo ""
    echo "Getting CA fingerprint..."
    FINGERPRINT=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "curl -sk ${CA_URL}/roots.pem | step certificate fingerprint /dev/stdin" 2>/dev/null)
    
    if [ -z "$FINGERPRINT" ]; then
        echo "[ERROR] Could not get CA fingerprint"
        exit 1
    fi
    
    echo "CA Fingerprint: $FINGERPRINT"
    
    # Bootstrap target host
    echo ""
    echo "Bootstrapping ${TARGET_HOST}..."
    
    if [ "$TARGET_HOST" = "localhost" ]; then
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "step ca bootstrap --ca-url ${CA_URL} --fingerprint ${FINGERPRINT} --install"
    else
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
            "ssh -o StrictHostKeyChecking=no ${TARGET_HOST} '\
                # Install step CLI if not present
                if ! command -v step &>/dev/null; then
                    wget -q https://dl.smallstep.com/cli/docs-ca-install/latest/step-cli_amd64.rpm
                    sudo rpm -i step-cli_amd64.rpm
                fi
                # Bootstrap CA
                step ca bootstrap --ca-url ${CA_URL} --fingerprint ${FINGERPRINT} --install
            '"
    fi
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "========================================"
        echo "[OK] Client Bootstrapped"
        echo "========================================"
        echo "Host ${TARGET_HOST} now trusts the CA"
        echo "You can now request certificates with:"
        echo "  step ca certificate <hostname> cert.crt key.key"
    else
        echo "[ERROR] Bootstrap failed"
        exit 1
    fi
    ''',
    execution_timeout=timedelta(minutes=10),
    dag=dag,
)

# Define task dependencies
decide_operation_task >> [get_ca_info, request_certificate, renew_certificate, revoke_certificate, bootstrap_client]
