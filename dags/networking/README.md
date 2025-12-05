# Networking DAGs

This directory contains DAGs for network configuration and management.

## Overview

Networking DAGs automate network-related tasks including:
- Network topology configuration
- Firewall rule management
- Load balancer setup
- VPN configuration
- Network monitoring and diagnostics

## Status

This category is currently **empty** and ready for contributions.

## Expected DAGs

Future networking DAGs may include:

| DAG | Description | Status |
|-----|-------------|--------|
| `network_topology_setup` | Configure network topology for clusters | Planned |
| `firewall_rules_management` | Manage firewall rules across infrastructure | Planned |
| `load_balancer_deployment` | Deploy and configure load balancers | Planned |
| `vpn_configuration` | Set up VPN for remote access | Planned |
| `network_diagnostics` | Network health checks and diagnostics | Planned |

## Related Infrastructure

Some networking functionality is currently in the infrastructure category:

- **vyos_router_deployment**: VyOS router deployment (in `infrastructure/`)
  - Consider: Should this be moved to networking category?

## Contributing

We welcome networking DAGs! To contribute:

1. **Identify a need**: What network automation would be valuable?
2. **Follow the template**: Use [../TEMPLATE.py](../TEMPLATE.py)
3. **Follow standards**: See [ADR-0045](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0045-dag-standards.md)
4. **Submit PR**: See [CONTRIBUTING.md](../../CONTRIBUTING.md)

## DAG Naming Convention

Networking DAGs should follow this pattern:
- `network_<component>_<action>.py`
- Examples:
  - `network_topology_setup.py`
  - `network_firewall_management.py`
  - `network_load_balancer_deployment.py`

## Related Documentation

- [CONTRIBUTING.md](../../CONTRIBUTING.md) - Contribution guidelines
- [DAG Template](../TEMPLATE.py) - Template for new DAGs
- [Registry](../registry.yaml) - DAG registry and metadata
