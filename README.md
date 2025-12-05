# qubinode-pipelines

**Middleware layer for deployment DAGs and scripts in the qubinode ecosystem**

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Contributions Welcome](https://img.shields.io/badge/contributions-welcome-brightgreen.svg)](CONTRIBUTING.md)

## Overview

`qubinode-pipelines` is the **Tier 2 middleware layer** in the three-tier qubinode architecture. It serves as the source of truth for deployment DAGs (Directed Acyclic Graphs) and deployment scripts that integrate with [qubinode_navigator](https://github.com/Qubinode/qubinode_navigator).

This repository clarifies ownership and integration patterns for external projects contributing automation to the qubinode ecosystem.

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

### Role Clarity

- **Tier 1 (Domain Projects)**: Focus on domain-specific automation (playbooks, configs)
- **Tier 2 (qubinode-pipelines)**: Source of truth for deployment DAGs and scripts
- **Tier 3 (qubinode_navigator)**: Airflow runtime, platform services, standards

## Repository Structure

```
qubinode-pipelines/
├── dags/                          # Deployment DAGs organized by category
│   ├── registry.yaml              # DAG registry and metadata
│   ├── TEMPLATE.py                # Template for new DAGs
│   ├── ocp/                       # OpenShift deployment DAGs
│   │   └── README.md
│   ├── infrastructure/            # Core infrastructure DAGs
│   │   ├── README.md
│   │   ├── freeipa_deployment.py
│   │   ├── vyos_router_deployment.py
│   │   ├── step_ca_deployment.py
│   │   ├── mirror_registry_deployment.py
│   │   └── ...
│   ├── networking/                # Network configuration DAGs
│   │   └── README.md
│   ├── storage/                   # Storage cluster DAGs
│   │   └── README.md
│   └── security/                  # Security and compliance DAGs
│       └── README.md
├── scripts/                       # Deployment scripts called by DAGs
│   ├── vyos-router/
│   │   └── deploy.sh
│   ├── freeipa/
│   │   └── deploy-freeipa.sh
│   ├── step-ca-server/
│   │   └── deploy.sh
│   └── helper_scripts/
│       ├── default.env            # Common environment variables
│       └── helper_functions.sh
├── CONTRIBUTING.md                # Contribution guidelines
└── README.md                      # This file
```

## Quick Start

### For Users

1. **Set up qubinode_navigator**:
   ```bash
   git clone https://github.com/Qubinode/qubinode_navigator.git
   cd qubinode_navigator
   ```

2. **Mount qubinode-pipelines**:
   ```bash
   # Edit docker-compose.yml to add volume mount:
   volumes:
     - /path/to/qubinode-pipelines:/opt/qubinode-pipelines:ro
   ```

3. **Start Airflow**:
   ```bash
   docker compose up -d
   ```

4. **Access Airflow UI**: http://localhost:8080
   - Username: `admin`
   - Password: (from qubinode_navigator setup)

5. **Trigger a DAG**:
   - Navigate to the DAG you want to run
   - Click "Trigger DAG w/ config"
   - Set parameters as needed
   - Click "Trigger"

### For Contributors

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines on:
- Developing new DAGs
- Validating your contributions
- Submitting pull requests
- DAG and script standards

## Available DAGs

### Infrastructure Category

| DAG | Description | Status |
|-----|-------------|--------|
| `freeipa_deployment` | FreeIPA DNS and identity management | ✅ Tested |
| `freeipa_dns_management` | Manage FreeIPA DNS records | ✅ Tested |
| `vyos_router_deployment` | VyOS router for network segmentation | ✅ Tested |
| `generic_vm_deployment` | Deploy RHEL, Fedora, Ubuntu, CentOS VMs | ✅ Tested |
| `step_ca_deployment` | Step-CA certificate authority | ✅ Tested |
| `step_ca_operations` | Certificate operations (request, renew, revoke) | ✅ Tested |
| `mirror_registry_deployment` | Quay mirror registry for disconnected OCP | ✅ Tested |
| `harbor_deployment` | Harbor enterprise container registry | ✅ Tested |
| `jfrog_deployment` | JFrog Artifactory | ✅ Tested |
| `jumpserver_deployment` | Apache Guacamole jumpserver | 🔨 Planned |

### OCP Category

OpenShift deployment DAGs will be contributed by external projects like [ocp4-disconnected-helper](https://github.com/tosin2013/ocp4-disconnected-helper).

**Expected DAGs:**
- `ocp_initial_deployment` - Initial cluster deployment
- `ocp_agent_deployment` - Agent-based installer workflow
- `ocp_disconnected_workflow` - Disconnected install workflow
- `ocp_incremental_update` - Cluster updates and upgrades
- `ocp_pre_deployment_validation` - Pre-flight checks
- `ocp_registry_sync` - Mirror registry synchronization

## Key Concepts

### DAG Categories

DAGs are organized into categories based on their purpose:

- **ocp**: OpenShift cluster deployment and management
- **infrastructure**: Core services (DNS, VMs, certificates, registries)
- **networking**: Network configuration and management
- **storage**: Storage clusters (Ceph, NFS, etc.)
- **security**: Security scanning, compliance, hardening

### DAG Registry

All DAGs are documented in `dags/registry.yaml`, which tracks:
- DAG name and location
- Description and purpose
- Contributing project
- Status (tested, planned, deprecated)
- Prerequisites

### Deployment Scripts

Each component has a deployment script in `scripts/*/deploy.sh` that:
- Supports `ACTION` variable: `create`, `delete`, `status`
- Uses standard exit codes (0 = success)
- Outputs ASCII markers: `[OK]`, `[ERROR]`, `[WARN]`, `[INFO]`
- Sources common environment: `scripts/helper_scripts/default.env`

## Integration Patterns

### Pattern 1: External Project Contributing DAGs

External projects develop domain-specific automation and contribute DAGs:

```
┌──────────────────────────────┐
│  ocp4-disconnected-helper    │
│  - Develops playbooks         │
│  - Tests locally              │
│  - Creates DAG                │
│  - Validates with tools       │
└──────────────┬───────────────┘
               │
               │ PR
               ▼
┌──────────────────────────────┐
│  qubinode-pipelines          │
│  - Reviews PR                 │
│  - Merges DAG                 │
│  - Updates registry           │
└──────────────┬───────────────┘
               │
               │ Volume mount
               ▼
┌──────────────────────────────┐
│  qubinode_navigator          │
│  - Loads DAGs                 │
│  - Executes workflows         │
│  - Provides UI                │
└──────────────────────────────┘
```

### Pattern 2: DAG Calling Deployment Script

DAGs call deployment scripts via SSH to the host:

```python
deploy_component = BashOperator(
    task_id='deploy_component',
    bash_command="""
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "export ACTION=create && \
         export VM_NAME=my-vm && \
         cd /opt/qubinode-pipelines/scripts/my-component && \
         ./deploy.sh"
    """,
    dag=dag,
)
```

This pattern (ADR-0046, ADR-0047):
- Avoids container limitations
- Uses host's tools (kcli, virsh, ansible)
- Ensures proper permissions
- Simplifies maintenance

## Backward Compatibility

For systems currently using `/opt/kcli-pipelines`, create a symlink:

```bash
# On the host
ln -s /opt/qubinode-pipelines /opt/kcli-pipelines
```

This ensures existing DAGs and scripts continue to work during migration.

## Related Documentation

- **ADRs in qubinode_navigator:**
  - [ADR-0061: Multi-Repository Architecture](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0061-multi-repository-architecture.md)
  - [ADR-0062: External Project Integration Guide](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0062-external-project-integration-guide.md)
  - [ADR-0040: DAG Distribution](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0040-dag-distribution.md)
  - [ADR-0045: DAG Standards](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0045-dag-standards.md)
  - [ADR-0046: SSH Execution Pattern](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0046-ssh-execution-pattern.md)
  - [ADR-0047: Deployment Script Repository](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0047-deployment-script-repository.md)

- **External Projects:**
  - [ocp4-disconnected-helper](https://github.com/tosin2013/ocp4-disconnected-helper)
  - [freeipa-workshop-deployer](https://github.com/tosin2013/freeipa-workshop-deployer)

- **Platform:**
  - [qubinode_navigator](https://github.com/Qubinode/qubinode_navigator)

## Legacy Documentation

Legacy documentation for individual VM deployments:
* [Create KCLI profiles for multiple environments](docs/configure-kcli-profiles.md)
* [Deploy VM Workflow](docs/deploy-vm.md)
* [Deploy the freeipa-server-container on vm](docs/deploy-dns.md)
* [Deploy the mirror-registry on vm](docs/mirror-registry.md)
* [Deploy the microshift-demos on vm](docs/microshift-demos.md)
* [Deploy the device-edge-workshops on vm](docs/device-edge-workshops.md)
* [Deploy the openshift-jumpbox on vm](docs/openshift-jumpbox.md)
* [Deploy the Red Hat Ansible Automation Platform on vm](docs/ansible-aap.md)
* [Deploy the ubuntu on vm](docs/ubuntu.md)
* [Deploy the fedora on vm](docs/fedora.md)
* [Deploy the rhel9 on vm](docs/rhel.md)
* [Deploy the OpenShift 4 Disconnected Helper](docs/ocp4-disconnected-helper.md)

## Support

- **Issues**: Report bugs or request features via [GitHub Issues](https://github.com/Qubinode/qubinode-pipelines/issues)
- **Discussions**: Ask questions in [GitHub Discussions](https://github.com/Qubinode/qubinode-pipelines/discussions)
- **Contributing**: See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.
