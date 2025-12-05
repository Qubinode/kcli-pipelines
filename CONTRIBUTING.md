# Contributing to qubinode-pipelines

Thank you for your interest in contributing to qubinode-pipelines! This repository serves as the **middleware layer** in the three-tier qubinode architecture, hosting deployment DAGs and scripts that integrate with qubinode_navigator.

## Three-Tier Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        TIER 1: DOMAIN PROJECTS                           │
│         (ocp4-disconnected-helper, freeipa-workshop-deployer)           │
│                                                                          │
│  Own: Domain-specific playbooks, automation logic                        │
│  Contribute: DAGs and scripts to qubinode-pipelines via PR              │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ PR-based contribution
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      TIER 2: QUBINODE-PIPELINES                          │
│                  (this repo - middleware layer)                          │
│                                                                          │
│  Own:                                                                    │
│  - Deployment scripts (scripts/*/deploy.sh)                              │
│  - Deployment DAGs (dags/ocp/*.py, dags/infrastructure/*.py)            │
│  - DAG registry (dags/registry.yaml)                                     │
│                                                                          │
│  Mounted at: /opt/qubinode-pipelines                                     │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ Volume mount
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     TIER 3: QUBINODE_NAVIGATOR                           │
│                        (platform / runtime)                              │
│                                                                          │
│  Own:                                                                    │
│  - Airflow infrastructure (docker-compose, containers)                   │
│  - Platform DAGs (rag_*.py, dag_factory.py, dag_loader.py)              │
│  - ADRs, standards, validation tools                                     │
│  - AI Assistant, MCP server                                              │
└─────────────────────────────────────────────────────────────────────────┘
```

## What to Contribute

### Deployment DAGs

Deployment DAGs automate infrastructure and application deployments. They should:

- **Call deployment scripts** in `scripts/` directory via SSH to host
- **Follow ADR-0045 standards** (snake_case, SSH pattern, ASCII output)
- **Be categorized** into one of:
  - `ocp/` - OpenShift deployment and management
  - `infrastructure/` - Core services (DNS, VMs, certificates, registries)
  - `networking/` - Network configuration and management
  - `storage/` - Storage clusters (Ceph, NFS, etc.)
  - `security/` - Security scanning, compliance, hardening

### Deployment Scripts

Deployment scripts (`scripts/*/deploy.sh`) should:

- **Support ACTION variable**: `create`, `delete`, `status`
- **Use standard exit codes**: 0 for success, non-zero for failure
- **Output ASCII markers**: `[OK]`, `[ERROR]`, `[WARN]`, `[INFO]`
- **Be idempotent**: Safe to run multiple times
- **Source environment**: Load `scripts/helper_scripts/default.env`

## Contribution Workflow

### 1. Develop Locally

Develop and test your DAG in your project repository first:

```bash
# In your project (e.g., ocp4-disconnected-helper)
cd my-project
mkdir -p dags
vim dags/my_new_deployment.py
```

### 2. Validate Your DAG

Use qubinode_navigator validation tools:

```bash
# Clone qubinode_navigator if not already available
git clone https://github.com/Qubinode/qubinode_navigator.git

# Validate DAG syntax and standards
./qubinode_navigator/airflow/scripts/validate-dag.sh dags/my_new_deployment.py

# Lint the DAG
./qubinode_navigator/airflow/scripts/lint-dags.sh dags/my_new_deployment.py
```

Both scripts must pass before submitting a PR.

### 3. Submit Pull Request

1. **Fork** this repository
2. **Create a branch**: `git checkout -b feature/my-new-dag`
3. **Add your DAG** to the appropriate category:
   ```bash
   cp dags/my_new_deployment.py qubinode-pipelines/dags/ocp/
   ```
4. **Update registry.yaml**:
   ```yaml
   ocp:
     description: "OpenShift deployment and management DAGs"
     dags:
       - name: my_new_deployment
         file: ocp/my_new_deployment.py
         description: "Description of what this DAG does"
         contributed_by: my-project-name
         status: tested
         prerequisites:
           - List any prerequisites
   ```
5. **Commit and push**:
   ```bash
   git add dags/ocp/my_new_deployment.py dags/registry.yaml
   git commit -m "feat: add my_new_deployment DAG"
   git push origin feature/my-new-dag
   ```
6. **Open PR** with:
   - Clear description of what the DAG does
   - Evidence of validation (paste output from validate-dag.sh and lint-dags.sh)
   - Links to related issues or projects
   - Testing instructions

## DAG Standards (ADR-0045)

All DAGs must comply with these standards:

### Naming

- **Filename**: Snake case matching DAG ID (e.g., `ocp_agent_deployment.py`)
- **DAG ID**: Snake case (e.g., `ocp_agent_deployment`)

### Code Style

```python
# ✅ CORRECT: Use triple double quotes for bash_command
bash_command="""
echo "Hello World"
"""

# ❌ WRONG: Never use triple single quotes
bash_command='''
echo "Hello World"
'''
```

### SSH Pattern (ADR-0046)

Execute commands on host via SSH to avoid container limitations:

```python
bash_command="""
ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
    "cd /opt/qubinode-pipelines/scripts/my-script && \
     export ACTION=create && \
     ./deploy.sh"
"""
```

### Output Standards

Use ASCII-only output markers:

- `[OK]` - Success message
- `[ERROR]` - Error message
- `[WARN]` - Warning message
- `[INFO]` - Informational message

```bash
echo "[OK] Deployment completed successfully"
echo "[ERROR] Failed to connect to server"
echo "[WARN] FreeIPA not found - DNS registration skipped"
echo "[INFO] Using default configuration"
```

### Documentation

Include a docstring at the top of your DAG:

```python
"""
Airflow DAG: My Deployment
Category: ocp

This DAG automates the deployment of...

Features:
- Feature 1
- Feature 2

Prerequisites:
- Prerequisite 1
- Prerequisite 2
"""
```

## DAG Template

Use this template for new DAGs:

```python
"""
Airflow DAG: [DAG Name]
Category: [ocp|infrastructure|networking|storage|security]

[Brief description of what this DAG does]

Prerequisites:
- List prerequisites here

Related ADRs:
- ADR-XXXX: [ADR Title]
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
    'retry_delay': timedelta(minutes=3),
}

dag = DAG(
    'my_deployment',
    default_args=default_args,
    description='Short description',
    schedule=None,
    catchup=False,
    tags=['qubinode', 'category', 'component'],
    params={
        'action': 'create',  # create or destroy
    },
)

def decide_action(**context):
    """Branch based on action parameter"""
    action = context['params'].get('action', 'create')
    if action == 'destroy':
        return 'destroy_task'
    return 'validate_environment'

decide_action_task = BranchPythonOperator(
    task_id='decide_action',
    python_callable=decide_action,
    dag=dag,
)

validate_environment = BashOperator(
    task_id='validate_environment',
    bash_command="""
    echo "========================================"
    echo "Validating Environment"
    echo "========================================"
    
    # Add validation logic here
    
    echo "[OK] Environment validation complete"
    """,
    dag=dag,
)

# Add more tasks here...

# Define workflow
decide_action_task >> validate_environment
```

## Deployment Script Template

Use this template for deployment scripts:

```bash
#!/bin/bash
# Component Deployment Script
# Usage: ACTION=create ./deploy.sh
#
# Environment Variables:
#   ACTION - create, delete, or status (required)
#   VM_NAME - Custom VM name (optional)
#   Other component-specific variables

set -euo pipefail

# Default configuration
ACTION="${ACTION:-create}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source environment
if [ -f /opt/qubinode-pipelines/scripts/helper_scripts/default.env ]; then
    source /opt/qubinode-pipelines/scripts/helper_scripts/default.env
fi

echo "========================================"
echo "Component Deployment"
echo "========================================"
echo "Action: ${ACTION}"
echo "========================================"

function create() {
    echo "[INFO] Creating component..."
    
    # Add creation logic here
    
    echo "[OK] Component created successfully"
}

function delete() {
    echo "[INFO] Deleting component..."
    
    # Add deletion logic here
    
    echo "[OK] Component deleted successfully"
}

function status() {
    echo "[INFO] Checking component status..."
    
    # Add status check logic here
    
    echo "[OK] Status check complete"
}

# Main execution
case "${ACTION}" in
    create)
        create
        ;;
    delete)
        delete
        ;;
    status)
        status
        ;;
    *)
        echo "[ERROR] Invalid action: ${ACTION}"
        echo "Usage: ACTION=[create|delete|status] ./deploy.sh"
        exit 1
        ;;
esac
```

## Testing Your Contribution

### Local Testing

1. **Mount this repo** in qubinode_navigator:
   ```bash
   # In qubinode_navigator directory
   vim docker-compose.yml
   # Add volume mount:
   # - /path/to/qubinode-pipelines:/opt/qubinode-pipelines
   ```

2. **Restart Airflow**:
   ```bash
   cd qubinode_navigator
   docker compose down
   docker compose up -d
   ```

3. **Test your DAG**:
   - Open Airflow UI: http://localhost:8080
   - Find your DAG in the list
   - Trigger it with test parameters
   - Verify it completes successfully

### CI Validation

Once you submit a PR, GitHub Actions will automatically:

1. Validate DAG syntax
2. Check code style (linting)
3. Verify registry.yaml is updated
4. Check for proper documentation

## Getting Help

- **Documentation**: See [README.md](README.md) for architecture overview
- **ADRs**: Read [qubinode_navigator ADRs](https://github.com/Qubinode/qubinode_navigator/tree/main/docs/adrs)
- **Issues**: Open an issue in this repository
- **Discussions**: Use GitHub Discussions for questions

## Code of Conduct

Please be respectful and professional in all interactions. We welcome contributions from everyone.

## License

By contributing, you agree that your contributions will be licensed under the same license as this project (Apache 2.0).
