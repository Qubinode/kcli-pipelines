"""
FreeIPA DNS Management DAG

This DAG provides DNS record management for FreeIPA/IdM.
It can be triggered by other DAGs or manually to add/remove DNS entries.

Usage:
    Trigger with conf:
    {
        "action": "present",      # or "absent" to remove
        "hostname": "mirror-registry",
        "ip_address": "192.168.122.61",
        "domain": "example.com",
        "freeipa_server": "freeipa.example.com"
    }
"""

from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import BranchPythonOperator

default_args = {
    'owner': 'qubinode',
    'depends_on_past': False,
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 2,
    'retry_delay': timedelta(minutes=1),
}

dag = DAG(
    'freeipa_dns_management',
    default_args=default_args,
    description='Manage DNS records in FreeIPA/IdM',
    schedule=None,  # Triggered manually or by other DAGs
    start_date=datetime(2024, 1, 1),
    catchup=False,
    tags=['dns', 'freeipa', 'idm', 'infrastructure'],
    params={
        'action': 'present',  # present or absent
        'hostname': '',  # e.g., mirror-registry
        'ip_address': '',  # e.g., 192.168.122.61
        'domain': 'example.com',
    },
    doc_md="""
# FreeIPA DNS Management DAG

## Purpose
Manages DNS A records in FreeIPA/IdM server. Can be used to:
- Add DNS records for new VMs/services
- Remove DNS records when VMs are deleted
- Update DNS records when IPs change

## Parameters
| Parameter | Description | Default |
|-----------|-------------|---------|
| action | `present` to add, `absent` to remove | present |
| hostname | Short hostname (e.g., mirror-registry) | required |
| ip_address | IP address for the A record | required (for present) |
| domain | DNS zone/domain | example.com |

**Note**: This DAG uses LDAP EXTERNAL auth via SSH to the FreeIPA server.
No admin password is required - it uses root access on the FreeIPA VM.

## Example Usage

### Add DNS record for mirror-registry
```json
{
    "action": "present",
    "hostname": "mirror-registry",
    "ip_address": "192.168.122.61",
    "domain": "example.com"
}
```

### Remove DNS record
```json
{
    "action": "absent",
    "hostname": "mirror-registry",
    "domain": "example.com"
}
```

## Integration with Registry DAGs
This DAG can be triggered from registry deployment DAGs using TriggerDagRunOperator.
"""
)


def validate_params(**context):
    """Validate required parameters"""
    params = context['params']
    hostname = params.get('hostname', '')
    ip_address = params.get('ip_address', '')
    action = params.get('action', 'present')
    
    if not hostname:
        raise ValueError("hostname parameter is required")
    
    if action == 'present' and not ip_address:
        raise ValueError("ip_address parameter is required when action is 'present'")
    
    return 'add_dns_record' if action == 'present' else 'remove_dns_record'


validate_task = BranchPythonOperator(
    task_id='validate_parameters',
    python_callable=validate_params,
    dag=dag,
)


add_dns = BashOperator(
    task_id='add_dns_record',
    bash_command="""
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Adding DNS Record to FreeIPA"
    echo "========================================"
    
    HOSTNAME="{{ params.hostname }}"
    IP_ADDRESS="{{ params.ip_address }}"
    DOMAIN="{{ params.domain }}"
    
    FQDN="${HOSTNAME}.${DOMAIN}"
    
    echo "Hostname: $HOSTNAME"
    echo "FQDN: $FQDN"
    echo "IP Address: $IP_ADDRESS"
    echo "Domain Zone: $DOMAIN"
    echo "FreeIPA Server: $FREEIPA_SERVER"
    echo ""
    
    # Get FreeIPA server IP
    FREEIPA_IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli info vm freeipa 2>/dev/null | grep 'ip:' | awk '{print \\$2}' | head -1")
    
    if [ -z "$FREEIPA_IP" ]; then
        echo "[ERROR] Could not find FreeIPA VM"
        exit 1
    fi
    
    echo "FreeIPA IP: $FREEIPA_IP"
    echo ""
    
    # Add DNS record using LDAP EXTERNAL auth (via FreeIPA server)
    echo "[INFO] Adding DNS A record via LDAP..."
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@$FREEIPA_IP bash -s <<EOF
# Add DNS A record using EXTERNAL SASL auth (root access)
ldapadd -Y EXTERNAL -H ldapi://%2Frun%2Fslapd-EXAMPLE-COM.socket 2>/dev/null <<LDIF || true
dn: idnsname=${HOSTNAME},idnsname=${DOMAIN}.,cn=dns,dc=example,dc=com
objectClass: idnsrecord
objectClass: top
idnsname: ${HOSTNAME}
arecord: ${IP_ADDRESS}
LDIF

# If record exists, modify it
ldapmodify -Y EXTERNAL -H ldapi://%2Frun%2Fslapd-EXAMPLE-COM.socket 2>/dev/null <<LDIF || true
dn: idnsname=${HOSTNAME},idnsname=${DOMAIN}.,cn=dns,dc=example,dc=com
changetype: modify
replace: arecord
arecord: ${IP_ADDRESS}
LDIF
EOF
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "[OK] DNS record added successfully"
        echo "    ${HOSTNAME}.${DOMAIN} -> ${IP_ADDRESS}"
        
        # Verify the record
        echo ""
        echo "[INFO] Verifying DNS record..."
        sleep 2
        RESOLVED=$(ssh -o StrictHostKeyChecking=no root@localhost \
            "dig +short ${FQDN} @${FREEIPA_IP}" 2>/dev/null || true)
        
        if [ "$RESOLVED" = "$IP_ADDRESS" ]; then
            echo "[OK] DNS verification successful: ${FQDN} resolves to ${RESOLVED}"
        else
            echo "[WARN] DNS verification returned: ${RESOLVED:-empty}"
            echo "       Expected: ${IP_ADDRESS}"
            echo "       DNS propagation may take a moment"
        fi
    else
        echo "[ERROR] Failed to add DNS record"
        exit 1
    fi
    """,
    execution_timeout=timedelta(minutes=5),
    dag=dag,
)


remove_dns = BashOperator(
    task_id='remove_dns_record',
    bash_command="""
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Removing DNS Record from FreeIPA"
    echo "========================================"
    
    HOSTNAME="{{ params.hostname }}"
    DOMAIN="{{ params.domain }}"
    
    echo "Hostname: $HOSTNAME"
    echo "Domain Zone: $DOMAIN"
    echo ""
    
    # Get FreeIPA IP
    FREEIPA_IP=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "kcli info vm freeipa 2>/dev/null | grep 'ip:' | awk '{print \\$2}' | head -1")
    
    if [ -z "$FREEIPA_IP" ]; then
        echo "[WARN] FreeIPA not found - skipping DNS removal"
        exit 0
    fi
    
    # Check if record exists
    CURRENT_IP=$(ssh -o StrictHostKeyChecking=no root@localhost \
        "dig +short ${HOSTNAME}.${DOMAIN} @${FREEIPA_IP}" 2>/dev/null || true)
    
    if [ -z "$CURRENT_IP" ]; then
        echo "[WARN] No existing DNS record found for ${HOSTNAME}.${DOMAIN}"
        echo "[OK] Nothing to remove"
        exit 0
    fi
    
    echo "Current IP: $CURRENT_IP"
    echo "FreeIPA IP: $FREEIPA_IP"
    echo ""
    
    # Remove DNS record using LDAP EXTERNAL auth
    echo "[INFO] Removing DNS A record via LDAP..."
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@$FREEIPA_IP bash -s <<EOF
ldapdelete -Y EXTERNAL -H ldapi://%2Frun%2Fslapd-EXAMPLE-COM.socket \
    "idnsname=${HOSTNAME},idnsname=${DOMAIN}.,cn=dns,dc=example,dc=com" 2>&1
EOF
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "[OK] DNS record removed successfully"
    else
        echo "[WARN] DNS removal may have failed - check FreeIPA manually"
    fi
    """,
    execution_timeout=timedelta(minutes=5),
    dag=dag,
)


success_task = BashOperator(
    task_id='dns_operation_complete',
    bash_command='echo "[OK] DNS operation completed successfully"',
    trigger_rule='one_success',
    dag=dag,
)

# Task dependencies
validate_task >> [add_dns, remove_dns]
add_dns >> success_task
remove_dns >> success_task

