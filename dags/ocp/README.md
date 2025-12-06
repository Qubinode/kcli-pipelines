# OpenShift Deployment DAGs

This directory contains DAGs for OpenShift cluster deployment and management.

## Overview

OpenShift DAGs automate the complete lifecycle of OpenShift clusters, including:
- Initial cluster deployment
- Disconnected/air-gapped installations
- Cluster updates and upgrades
- Pre-deployment validation
- Registry synchronization

## Expected DAGs

External projects like [ocp4-disconnected-helper](https://github.com/tosin2013/ocp4-disconnected-helper) will contribute DAGs to this category.

### Planned DAGs

| DAG | Description | Status |
|-----|-------------|--------|
| `ocp_initial_deployment` | Initial OpenShift cluster deployment | Planned |
| `ocp_agent_deployment` | Agent-based installer workflow | Planned |
| `ocp_disconnected_workflow` | Complete disconnected install workflow | Planned |
| `ocp_incremental_update` | Cluster updates and upgrades | Planned |
| `ocp_pre_deployment_validation` | Pre-flight checks and validation | Planned |
| `ocp_registry_sync` | Mirror registry synchronization | Planned |

## Typical Workflow

A complete OpenShift deployment typically follows this sequence:

```
1. Pre-deployment validation
   └─> ocp_pre_deployment_validation

2. Infrastructure setup (if needed)
   ├─> freeipa_deployment (DNS)
   ├─> vyos_router_deployment (Networking)
   ├─> step_ca_deployment (Certificates for disconnected)
   └─> mirror_registry_deployment (Container images for disconnected)

3. OpenShift deployment
   └─> ocp_initial_deployment OR ocp_disconnected_workflow

4. Post-deployment
   └─> ocp_registry_sync (Keep registry updated)
```

## Integration with Infrastructure DAGs

OpenShift DAGs depend on infrastructure DAGs:

- **FreeIPA**: DNS resolution for cluster nodes
- **VyOS Router**: Network segmentation and routing
- **Step-CA**: TLS certificates for disconnected installs
- **Mirror Registry**: Container images for disconnected installs

## Contributing

To contribute an OpenShift DAG:

1. **Develop locally** in your project (e.g., ocp4-disconnected-helper)
2. **Test thoroughly** with real deployments
3. **Validate** using qubinode_navigator tools:
   ```bash
   ./airflow/scripts/validate-dag.sh your_ocp_dag.py
   ./airflow/scripts/lint-dags.sh your_ocp_dag.py
   ```
4. **Submit PR** with:
   - DAG file in this directory
   - Update to `../registry.yaml`
   - Documentation and testing evidence

See [CONTRIBUTING.md](../../CONTRIBUTING.md) for detailed guidelines.

## DAG Standards

All OpenShift DAGs must follow these standards:

### Naming

- Filename: `ocp_<component>_<action>.py` (e.g., `ocp_initial_deployment.py`)
- DAG ID: Match filename without `.py` (e.g., `ocp_initial_deployment`)

### Parameters

Common parameters across OpenShift DAGs:

```python
params={
    'action': 'create',  # create, destroy, update
    'cluster_name': 'ocp-cluster',
    'base_domain': 'example.com',
    'disconnected': 'false',  # true for disconnected installs
    'openshift_version': '4.14.0',
}
```

### Prerequisites Check

Always validate prerequisites:

```python
validate_environment = BashOperator(
    task_id='validate_environment',
    bash_command="""
    echo "[INFO] Checking OpenShift prerequisites..."
    
    # Check for required infrastructure
    if ! ssh root@localhost "kcli info vm freeipa" &>/dev/null; then
        echo "[ERROR] FreeIPA not deployed - DNS required"
        exit 1
    fi
    echo "[OK] FreeIPA available"
    
    # Add more checks...
    """,
    dag=dag,
)
```

### Output Standards

Use consistent output markers:

- `[OK]` - Success
- `[ERROR]` - Error (exit non-zero)
- `[WARN]` - Warning (continue)
- `[INFO]` - Information

## Example DAG Structure

```python
"""
Airflow DAG: OpenShift Initial Deployment
Category: ocp

Automates initial OpenShift cluster deployment using agent-based installer.

Prerequisites:
- FreeIPA for DNS
- Base OS images
- Pull secret configured
"""

from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import BranchPythonOperator

# ... DAG definition ...

# Workflow:
# validate_environment -> prepare_install_config -> download_installer
#   -> generate_iso -> deploy_nodes -> wait_for_bootstrap
#   -> wait_for_install_complete -> validate_cluster
```

## Related Documentation

- [CONTRIBUTING.md](../../CONTRIBUTING.md) - Contribution guidelines
- [ADR-0045: DAG Standards](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0045-dag-standards.md)
- [ADR-0046: SSH Execution Pattern](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0046-ssh-execution-pattern.md)
- [ocp4-disconnected-helper](https://github.com/tosin2013/ocp4-disconnected-helper) - Primary contributor
