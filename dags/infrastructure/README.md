# Infrastructure DAGs

This directory contains DAGs for core infrastructure services that support application and cluster deployments.

## Overview

Infrastructure DAGs automate the deployment and management of foundational services including:
- DNS and identity management
- Network routing and segmentation
- Certificate authorities
- Container registries
- Generic virtual machines
- Jump servers for remote access

## Available DAGs

### DNS and Identity

| DAG | Description | Status |
|-----|-------------|--------|
| `freeipa_deployment` | FreeIPA Identity Management Server | ✅ Tested |
| `freeipa_dns_management` | Manage FreeIPA DNS records | ✅ Tested |

**Use when**: You need DNS resolution and user/group management for your environment.

### Networking

| DAG | Description | Status |
|-----|-------------|--------|
| `vyos_router_deployment` | VyOS router for network segmentation | ✅ Tested |

**Use when**: You need isolated networks for different purposes (lab, disconnected, provisioning, etc.).

### Certificates

| DAG | Description | Status |
|-----|-------------|--------|
| `step_ca_deployment` | Step-CA certificate authority | ✅ Tested |
| `step_ca_operations` | Certificate operations (request, renew, revoke) | ✅ Tested |

**Use when**: You need internal PKI for disconnected installs or service-to-service TLS.

### Container Registries

| DAG | Description | Status |
|-----|-------------|--------|
| `mirror_registry_deployment` | Quay-based mirror registry | ✅ Tested |
| `harbor_deployment` | Harbor enterprise registry | ✅ Tested |
| `jfrog_deployment` | JFrog Artifactory | ✅ Tested |

**Use when**: You need to host container images for disconnected OpenShift installs or development.

### Virtual Machines

| DAG | Description | Status |
|-----|-------------|--------|
| `generic_vm_deployment` | Deploy RHEL, Fedora, Ubuntu, CentOS VMs | ✅ Tested |
| `jumpserver_deployment` | Apache Guacamole for browser-based access | 🔨 Planned |

**Use when**: You need to deploy standard VMs for testing or applications.

## Typical Deployment Order

For a complete environment, deploy infrastructure in this order:

```
1. FreeIPA (DNS)
   └─> freeipa_deployment

2. VyOS Router (Networking) - optional for network segmentation
   └─> vyos_router_deployment

3. Step-CA (Certificates) - if using disconnected installs
   └─> step_ca_deployment

4. Mirror Registry (Container Images) - for disconnected OpenShift
   └─> mirror_registry_deployment

5. Additional VMs as needed
   └─> generic_vm_deployment
```

## Common Parameters

Most infrastructure DAGs share these common parameters:

```python
params={
    'action': 'create',  # create, delete, or status
    'vm_name': '',  # Custom VM name (auto-generated if empty)
    'domain': 'example.com',  # Domain name
    'community_version': 'false',  # true for CentOS, false for RHEL
}
```

## Prerequisites

Infrastructure DAGs typically require:

- **kcli installed**: VM provisioning tool
- **libvirt/qemu**: Virtualization platform
- **Base OS images**: RHEL, CentOS, Fedora images downloaded
- **vault.yml**: Credentials for automation (in qubinode_navigator)

## DAG Standards

### SSH Execution Pattern

All infrastructure DAGs use SSH to execute on the host (ADR-0046):

```python
deploy_task = BashOperator(
    task_id='deploy_component',
    bash_command="""
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "export ACTION=create && \
         cd /opt/qubinode-pipelines/scripts/component && \
         ./deploy.sh"
    """,
    dag=dag,
)
```

This pattern:
- Avoids container limitations
- Uses host's tools (kcli, virsh, ansible)
- Ensures proper permissions
- Simplifies maintenance

### Output Standards

Use consistent output markers:

```bash
echo "[OK] Component deployed successfully"
echo "[ERROR] Failed to create VM"
echo "[WARN] FreeIPA not found - DNS registration skipped"
echo "[INFO] Using default configuration"
```

## Contributing

To contribute an infrastructure DAG:

1. **Use the template**: Start with [../TEMPLATE.py](../TEMPLATE.py)
2. **Follow standards**: See [ADR-0045](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0045-dag-standards.md)
3. **Test thoroughly**: Verify create, delete, and idempotency
4. **Validate**: Run validation tools from qubinode_navigator
5. **Submit PR**: Include DAG, registry update, and documentation

See [CONTRIBUTING.md](../../CONTRIBUTING.md) for detailed guidelines.

## Example: Deploying FreeIPA

```bash
# Via Airflow UI
1. Navigate to DAGs → freeipa_deployment
2. Click "Trigger DAG w/ config"
3. Set parameters:
   - action: create
   - domain: lab.example.com
   - idm_hostname: idm
4. Click "Trigger"

# Via CLI
airflow dags trigger freeipa_deployment --conf '{
    "action": "create",
    "domain": "lab.example.com",
    "idm_hostname": "idm"
}'

# Via REST API
curl -X POST http://localhost:8080/api/v1/dags/freeipa_deployment/dagRuns \
  -H "Content-Type: application/json" \
  -d '{"conf": {"action": "create", "domain": "lab.example.com"}}'
```

## Troubleshooting

### DAG fails to find deployment script

**Problem**: `[ERROR] /opt/qubinode-pipelines/scripts/component/deploy.sh not found`

**Solution**: Ensure qubinode-pipelines is mounted correctly in docker-compose.yml:
```yaml
volumes:
  - /path/to/qubinode-pipelines:/opt/qubinode-pipelines:ro
```

### SSH connection refused

**Problem**: `ssh: connect to host localhost port 22: Connection refused`

**Solution**: Ensure Airflow container can SSH to host (ADR-0043):
```yaml
network_mode: "host"  # In docker-compose.yml
```

### VM already exists

**Problem**: `[WARN] VM component-name already exists`

**Solution**: This is expected behavior for idempotency. The DAG will check if the VM is running and start it if needed. To redeploy, set `action: delete` first.

## Related Documentation

- [CONTRIBUTING.md](../../CONTRIBUTING.md) - Contribution guidelines
- [DAG Template](../TEMPLATE.py) - Template for new DAGs
- [Registry](../registry.yaml) - DAG registry and metadata
- [ADR-0047: Deployment Script Repository](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0047-deployment-script-repository.md)
