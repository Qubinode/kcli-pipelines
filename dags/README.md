# kcli-pipelines Airflow DAGs

This directory contains Airflow DAG definitions for infrastructure provisioning workflows.

## Available DAGs

| DAG | Description | Status |
|-----|-------------|--------|
| `freeipa_deployment.py` | Deploy FreeIPA Identity Management Server | ✅ Ready |
| `vyos_router_deployment.py` | Deploy VyOS Router for network segmentation | ✅ Ready |

## Synchronizing DAGs to Qubinode Navigator

Use the sync script to copy DAGs to your qubinode_navigator installation:

```bash
# Clone or update kcli-pipelines
git clone https://github.com/Qubinode/kcli-pipelines.git /opt/kcli-pipelines
# OR
cd /opt/kcli-pipelines && git pull

# Run sync script
/opt/kcli-pipelines/scripts/sync-dags-to-qubinode.sh

# Dry-run to see what would happen
/opt/kcli-pipelines/scripts/sync-dags-to-qubinode.sh --dry-run
```

## DAG Parameters

### FreeIPA Deployment

| Parameter | Default | Description |
|-----------|---------|-------------|
| `action` | `create` | `create` or `destroy` |
| `community_version` | `false` | `true` for CentOS, `false` for RHEL |
| `os_version` | `9` | OS version: `8` or `9` |
| `target_server` | `` | Target server profile |

### VyOS Router Deployment

| Parameter | Default | Description |
|-----------|---------|-------------|
| `action` | `create` | `create` or `destroy` |
| `vyos_version` | `1.5-rolling-202411250007` | VyOS version |
| `vyos_channel` | `stable` | `stable`, `lts`, or `rolling` |
| `configure_router` | `true` | Run configuration script |
| `add_host_routes` | `true` | Add routes to host |

## Triggering DAGs

### Via Airflow UI
1. Navigate to Airflow UI (default: http://localhost:8888)
2. Find the DAG in the list
3. Click "Trigger DAG w/ config"
4. Set parameters and trigger

### Via CLI
```bash
# FreeIPA
airflow dags trigger freeipa_deployment --conf '{"action": "create", "os_version": "9"}'

# VyOS
airflow dags trigger vyos_router_deployment --conf '{"action": "create"}'
```

### Via API
```bash
curl -X POST "http://localhost:8888/api/v1/dags/freeipa_deployment/dagRuns" \
  -H "Content-Type: application/json" \
  -d '{"conf": {"action": "create"}}'
```

## Contributing New DAGs

1. Create your DAG file in this directory
2. Follow the existing DAG patterns
3. Include comprehensive documentation in `dag.doc_md`
4. Test locally before submitting PR
5. Update this README with your DAG

## Deployment Order

**Important:** Deploy in this order for proper dependency resolution:

1. **FreeIPA** (Prerequisite) - Identity management and DNS
2. **VyOS Router** - Network segmentation and routing
3. **OpenShift/Other workloads** - Application platforms

## Detailed Documentation

- [FreeIPA Identity Management](../docs/freeipa-identity-management.md) - Complete deployment guide
- [VyOS Router Deployment](../docs/vyos-router-deployment.md) - Network infrastructure guide

## Related ADRs

- [ADR-0039: FreeIPA and VyOS Airflow DAG Integration](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0039-freeipa-vyos-airflow-dag-integration.md)
- [ADR-0040: DAG Distribution from kcli-pipelines](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0040-dag-distribution-from-kcli-pipelines.md)
- [ADR-0041: VyOS Version Upgrade Strategy](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0041-vyos-version-upgrade-strategy.md)
- [ADR-0042: FreeIPA Base OS Upgrade to RHEL 9](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0042-freeipa-base-os-upgrade-rhel9.md)
- [ADR-0043: Airflow Container Host Network Access](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0043-airflow-container-host-network-access.md)
