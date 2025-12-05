"""
Airflow DAG: [Component Name] Deployment
Category: [ocp|infrastructure|networking|storage|security]

[Brief description of what this DAG automates]

Features:
- Feature 1
- Feature 2
- Feature 3

Prerequisites:
- Prerequisite 1
- Prerequisite 2

Related ADRs:
- ADR-XXXX: [ADR Title]
- ADR-0045: DAG Standards
- ADR-0046: SSH Execution Pattern
"""

from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import BranchPythonOperator

# Default arguments
default_args = {
    'owner': 'qubinode',
    'depends_on_past': False,
    'start_date': datetime(2025, 1, 1),
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 1,
    'retry_delay': timedelta(minutes=3),
}

# DAG definition
dag = DAG(
    'component_deployment',  # Use snake_case matching filename
    default_args=default_args,
    description='Brief description for Airflow UI',
    schedule=None,  # Manual trigger only
    catchup=False,
    tags=['qubinode', 'category', 'component'],
    params={
        'action': 'create',  # create or destroy
        'param1': 'default_value',
        'param2': 'default_value',
    },
)


def decide_action(**context):
    """Branch based on action parameter (create or destroy)."""
    action = context['params'].get('action', 'create')
    if action == 'destroy':
        return 'destroy_component'
    return 'validate_environment'


# Task: Decide action
decide_action_task = BranchPythonOperator(
    task_id='decide_action',
    python_callable=decide_action,
    dag=dag,
)

# =============================================================================
# CREATE WORKFLOW
# =============================================================================

# Task: Validate environment
validate_environment = BashOperator(
    task_id='validate_environment',
    bash_command="""
    echo "========================================"
    echo "Validating Deployment Environment"
    echo "========================================"
    
    # Check prerequisites
    # Example: Check if kcli is installed
    if ! command -v kcli &> /dev/null; then
        echo "[ERROR] kcli not installed"
        exit 1
    fi
    echo "[OK] kcli installed"
    
    # Add more validation checks...
    
    echo ""
    echo "[OK] Environment validation complete"
    """,
    dag=dag,
)

# Task: Deploy component
# ADR-0046: Use SSH to execute on host
deploy_component = BashOperator(
    task_id='deploy_component',
    bash_command="""
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Deploying Component"
    echo "========================================"
    
    PARAM1="{{ params.param1 }}"
    PARAM2="{{ params.param2 }}"
    
    echo "Parameter 1: $PARAM1"
    echo "Parameter 2: $PARAM2"
    
    # Execute deployment script on host via SSH (ADR-0046, ADR-0047)
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "export ACTION=create && \
         export PARAM1=$PARAM1 && \
         export PARAM2=$PARAM2 && \
         cd /opt/qubinode-pipelines/scripts/component && \
         ./deploy.sh"
    
    echo ""
    echo "[OK] Component deployment initiated"
    """,
    execution_timeout=timedelta(minutes=30),
    dag=dag,
)

# Task: Wait for component
wait_for_component = BashOperator(
    task_id='wait_for_component',
    bash_command="""
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Waiting for Component"
    echo "========================================"
    
    MAX_ATTEMPTS=30
    ATTEMPT=0
    
    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        ATTEMPT=$((ATTEMPT + 1))
        echo "Check $ATTEMPT/$MAX_ATTEMPTS..."
        
        # Add check logic here
        # Example: Check if component is responding
        # if check_component_health; then
        #     echo "[OK] Component is ready"
        #     exit 0
        # fi
        
        sleep 10
    done
    
    echo "[WARN] Timeout waiting for component"
    """,
    execution_timeout=timedelta(minutes=10),
    dag=dag,
)

# Task: Validate deployment
validate_deployment = BashOperator(
    task_id='validate_deployment',
    bash_command="""
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Validating Deployment"
    echo "========================================"
    
    # Add validation checks here
    
    echo ""
    echo "========================================"
    echo "[OK] Component Deployment Complete!"
    echo "========================================"
    echo ""
    echo "Access Information:"
    echo "  URL: https://component.example.com"
    echo "  SSH: ssh user@component.example.com"
    echo ""
    """,
    dag=dag,
)

# =============================================================================
# DESTROY WORKFLOW
# =============================================================================

destroy_component = BashOperator(
    task_id='destroy_component',
    bash_command="""
    export PATH="/home/airflow/.local/bin:/usr/local/bin:$PATH"
    echo "========================================"
    echo "Destroying Component"
    echo "========================================"
    
    # Execute destroy via SSH (ADR-0046)
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "export ACTION=delete && \
         cd /opt/qubinode-pipelines/scripts/component && \
         ./deploy.sh"
    
    echo ""
    echo "[OK] Component destroyed successfully"
    """,
    dag=dag,
)

# =============================================================================
# DAG WORKFLOW
# =============================================================================

# Create workflow
decide_action_task >> validate_environment >> deploy_component >> wait_for_component >> validate_deployment

# Destroy workflow
decide_action_task >> destroy_component

# DAG documentation
dag.doc_md = """
# Component Deployment DAG

This DAG automates the deployment of [Component Name].

## Workflow

### Create (action=create)
1. **validate_environment** - Check prerequisites
2. **deploy_component** - Deploy via deployment script
3. **wait_for_component** - Wait for component to be ready
4. **validate_deployment** - Verify deployment

### Destroy (action=destroy)
1. **destroy_component** - Remove component

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| action | create | create or destroy |
| param1 | default_value | Description of param1 |
| param2 | default_value | Description of param2 |

## Prerequisites

- Prerequisite 1
- Prerequisite 2

## Usage

### Via Airflow UI
1. Navigate to DAGs → component_deployment
2. Click "Trigger DAG w/ config"
3. Set parameters as needed
4. Click "Trigger"

### Via CLI
```bash
airflow dags trigger component_deployment --conf '{
    "action": "create",
    "param1": "value1",
    "param2": "value2"
}'
```

## Post-Deployment

After deployment:
1. Access component at: https://component.example.com
2. Check logs: ssh user@component.example.com
3. View status: Set action=status and re-trigger

## Related ADRs

- ADR-0045: DAG Standards
- ADR-0046: SSH Execution Pattern
- ADR-0047: Deployment Script Repository
"""
