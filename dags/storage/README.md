# Storage DAGs

This directory contains DAGs for storage cluster deployment and management.

## Overview

Storage DAGs automate storage-related tasks including:
- Distributed storage cluster deployment
- NFS server configuration
- Storage provisioning and management
- Backup and restore operations
- Storage performance tuning

## Status

This category is currently **empty** and ready for contributions.

## Expected DAGs

Future storage DAGs may include:

| DAG | Description | Status |
|-----|-------------|--------|
| `ceph_cluster_deployment` | Deploy Ceph distributed storage cluster | Planned |
| `nfs_server_deployment` | Deploy and configure NFS servers | Planned |
| `storage_provisioning` | Provision storage volumes and quotas | Planned |
| `storage_backup_restore` | Backup and restore storage volumes | Planned |
| `glusterfs_deployment` | Deploy GlusterFS cluster | Planned |

## Storage Integration

Storage DAGs typically integrate with:

- **OpenShift**: Providing persistent volumes for applications
- **Virtual Machines**: Block storage for VM disks
- **Backup Systems**: Target for backup data
- **Container Registries**: Backend storage for container images

## Contributing

We welcome storage DAGs! To contribute:

1. **Identify a need**: What storage automation would be valuable?
2. **Follow the template**: Use [../TEMPLATE.py](../TEMPLATE.py)
3. **Follow standards**: See [ADR-0045](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0045-dag-standards.md)
4. **Test thoroughly**: Storage requires careful testing to avoid data loss
5. **Submit PR**: See [CONTRIBUTING.md](../../CONTRIBUTING.md)

## DAG Naming Convention

Storage DAGs should follow this pattern:
- `storage_<component>_<action>.py`
- Examples:
  - `ceph_cluster_deployment.py`
  - `nfs_server_deployment.py`
  - `storage_provisioning.py`

## Storage Best Practices

When developing storage DAGs:

1. **Data Safety First**: Never delete data without confirmation
2. **Backup Before Changes**: Always backup before destructive operations
3. **Health Checks**: Include storage health validation
4. **Capacity Monitoring**: Check available capacity before provisioning
5. **Idempotency**: Ensure DAGs can be re-run safely

## Example Parameters

Storage DAGs typically include:

```python
params={
    'action': 'create',  # create, delete, expand, status
    'cluster_name': 'ceph-cluster',
    'num_osds': '3',  # Number of OSDs per node
    'osd_size': '100GB',  # Size of each OSD
    'replication_factor': '3',  # Data replication
    'network': 'storage',  # Storage network
}
```

## Related Documentation

- [CONTRIBUTING.md](../../CONTRIBUTING.md) - Contribution guidelines
- [DAG Template](../TEMPLATE.py) - Template for new DAGs
- [Registry](../registry.yaml) - DAG registry and metadata
