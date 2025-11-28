# VyOS Router Deployment

**Status:** Production Ready  
**Category:** Network Infrastructure  
**Priority:** Required (After FreeIPA)  
**ADRs:** ADR-0039, ADR-0041, ADR-0043

## Overview

VyOS provides network segmentation, routing, NAT, and DHCP services for the Qubinode environment. It creates isolated networks for different workloads (lab, provisioning, bare metal) while maintaining connectivity through a central router.

### Key Features

- **Network Segmentation**: Isolated VLANs for different purposes
- **NAT/Masquerade**: Internet access for isolated networks
- **DHCP Server**: IP address management per network
- **Static Routing**: Inter-network communication
- **Firewall**: Traffic filtering and security zones

## Prerequisites

| Requirement | Details |
|-------------|---------|
| **FreeIPA** | Deployed and running (for DNS) |
| **Hypervisor** | KVM/libvirt configured |
| **Airflow** | Running with host network mode (ADR-0043) |
| **VyOS ISO** | Downloaded (DAG provides instructions) |
| **Resources** | 4GB RAM, 2 vCPUs, 20GB disk |

## Network Architecture

```
                    ┌─────────────────────────────────────┐
                    │           Host System               │
                    │         192.168.122.1               │
                    └──────────────┬──────────────────────┘
                                   │
                    ┌──────────────┴──────────────────────┐
                    │         VyOS Router                 │
                    │    eth0: 192.168.122.x (default)    │
                    ├─────────────────────────────────────┤
                    │ eth1: 1924 - Lab Network            │
                    │ eth2: 1925 - Disco Network          │
                    │ eth3: 1926 - Reserved               │
                    │ eth4: 1927 - Metal Network          │
                    │ eth5: 1928 - Provisioning Network   │
                    └─────────────────────────────────────┘
                         │      │      │      │      │
                         ▼      ▼      ▼      ▼      ▼
                    ┌────┐  ┌────┐  ┌────┐  ┌────┐  ┌────┐
                    │1924│  │1925│  │1926│  │1927│  │1928│
                    │Lab │  │Disc│  │Rsvd│  │Metl│  │Prov│
                    └────┘  └────┘  └────┘  └────┘  └────┘
```

### Network Definitions

| Network | Name | Purpose | Subnet (Example) |
|---------|------|---------|------------------|
| 1924 | Lab | Development/Testing | 192.168.49.0/24 |
| 1925 | Disco | Disconnected/Air-gapped | 192.168.50.0/24 |
| 1926 | Reserved | Future use | 192.168.51.0/24 |
| 1927 | Metal | Bare metal provisioning | 192.168.52.0/24 |
| 1928 | Provisioning | PXE/DHCP boot | 192.168.53.0/24 |

## Deployment Methods

### Method 1: Airflow DAG (Recommended)

The VyOS DAG creates the libvirt networks and provides VM creation instructions.

#### Via Airflow UI

1. Navigate to **DAGs** → `vyos_router_deployment`
2. Click **Trigger DAG w/ config**
3. Configure parameters:
   ```json
   {
     "action": "create",
     "vyos_version": "1.5-rolling-202411250007"
   }
   ```
4. Click **Trigger**

#### Via CLI

```bash
# Trigger VyOS deployment
podman exec airflow_airflow-scheduler_1 \
  airflow dags trigger vyos_router_deployment \
  --conf '{"action": "create"}'

# Check status
podman exec airflow_airflow-scheduler_1 \
  airflow dags list-runs -d vyos_router_deployment
```

### Method 2: Manual Deployment

#### Step 1: Create Networks (Automated by DAG)

```bash
# Networks are created by the DAG, but can be done manually:
for NET in 1924 1925 1926 1927 1928; do
  LAST_DIGIT="${NET: -1}"
  cat > /tmp/net-$NET.xml <<EOF
<network>
  <name>$NET</name>
  <bridge name='virbr$LAST_DIGIT' stp='on' delay='0'/>
  <domain name='$NET' localOnly='yes'/>
</network>
EOF
  virsh net-define /tmp/net-$NET.xml
  virsh net-start $NET
  virsh net-autostart $NET
done
```

#### Step 2: Download VyOS ISO

```bash
VYOS_VERSION="1.5-rolling-202411250007"
curl -L -o ~/vyos-${VYOS_VERSION}-generic-amd64.iso \
  https://github.com/vyos/vyos-nightly-build/releases/download/${VYOS_VERSION}/vyos-${VYOS_VERSION}-generic-amd64.iso
```

#### Step 3: Create VM

```bash
# Create disk
qemu-img create -f qcow2 /var/lib/libvirt/images/vyos-router.qcow2 20G

# Create VM with multiple NICs
virt-install -n vyos-router \
  --ram 4096 \
  --vcpus 2 \
  --cdrom ~/vyos-${VYOS_VERSION}-generic-amd64.iso \
  --os-variant debian10 \
  --network network=default,model=e1000e \
  --network network=1924,model=e1000e \
  --network network=1925,model=e1000e \
  --network network=1926,model=e1000e \
  --network network=1927,model=e1000e \
  --network network=1928,model=e1000e \
  --graphics vnc \
  --disk path=/var/lib/libvirt/images/vyos-router.qcow2,bus=virtio \
  --noautoconsole
```

#### Step 4: Install VyOS

```bash
# Access console
virsh console vyos-router

# Login with: vyos / vyos
# Run installation
install image

# Follow prompts:
# - Partition: Auto
# - Image name: default
# - Copy config: Yes
# - Set password: <your-password>

# Reboot
reboot
```

## DAG Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `action` | `create` | Action: `create` or `destroy` |
| `vyos_version` | `1.5-rolling-202411250007` | VyOS version to deploy |
| `vyos_channel` | `stable` | Channel: `stable`, `lts`, or `rolling` |
| `configure_router` | `true` | Run configuration script |
| `add_host_routes` | `true` | Add routes to host |

## DAG Workflow

```
┌─────────────────┐
│  decide_action  │
└────────┬────────┘
         │
    ┌────┴────┐
    │ create? │
    └────┬────┘
         │
         ▼
┌─────────────────────┐
│ validate_environment│
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│create_libvirt_networks│
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  download_vyos_iso   │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   create_vyos_vm     │ ← Provides instructions
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  wait_for_vyos_boot  │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   configure_vyos     │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   add_host_routes    │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ validate_deployment  │
└─────────────────────┘
```

## Post-Deployment: VyOS Configuration

After VyOS is installed, configure the router:

### Basic Configuration

```bash
# Access VyOS
ssh vyos@<VYOS_IP>

# Enter configuration mode
configure

# Set hostname
set system host-name vyos-router

# Configure eth0 (default network - DHCP or static)
set interfaces ethernet eth0 address dhcp
# OR
set interfaces ethernet eth0 address 192.168.122.10/24

# Configure internal interfaces
set interfaces ethernet eth1 address 192.168.49.1/24
set interfaces ethernet eth2 address 192.168.50.1/24
set interfaces ethernet eth3 address 192.168.51.1/24
set interfaces ethernet eth4 address 192.168.52.1/24
set interfaces ethernet eth5 address 192.168.53.1/24

# Enable SSH
set service ssh port 22

# Commit and save
commit
save
```

### NAT Configuration

```bash
configure

# Source NAT for all internal networks
set nat source rule 10 outbound-interface name eth0
set nat source rule 10 source address 192.168.49.0/24
set nat source rule 10 translation address masquerade

set nat source rule 20 outbound-interface name eth0
set nat source rule 20 source address 192.168.50.0/24
set nat source rule 20 translation address masquerade

set nat source rule 30 outbound-interface name eth0
set nat source rule 30 source address 192.168.51.0/24
set nat source rule 30 translation address masquerade

set nat source rule 40 outbound-interface name eth0
set nat source rule 40 source address 192.168.52.0/24
set nat source rule 40 translation address masquerade

set nat source rule 50 outbound-interface name eth0
set nat source rule 50 source address 192.168.53.0/24
set nat source rule 50 translation address masquerade

commit
save
```

### DHCP Server Configuration

```bash
configure

# DHCP for Lab network (1924)
set service dhcp-server shared-network-name LAB subnet 192.168.49.0/24 range 0 start 192.168.49.100
set service dhcp-server shared-network-name LAB subnet 192.168.49.0/24 range 0 stop 192.168.49.200
set service dhcp-server shared-network-name LAB subnet 192.168.49.0/24 default-router 192.168.49.1
set service dhcp-server shared-network-name LAB subnet 192.168.49.0/24 name-server <FREEIPA_IP>
set service dhcp-server shared-network-name LAB subnet 192.168.49.0/24 lease 86400

# Repeat for other networks as needed

commit
save
```

### DNS Configuration (Use FreeIPA)

```bash
configure

# Use FreeIPA as DNS server
set system name-server <FREEIPA_IP>

commit
save
```

## Host Routes Configuration

Add routes on the host to reach VyOS networks:

```bash
# Get VyOS IP
VYOS_IP=$(virsh domifaddr vyos-router | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)

# Add routes
sudo ip route add 192.168.49.0/24 via $VYOS_IP
sudo ip route add 192.168.50.0/24 via $VYOS_IP
sudo ip route add 192.168.51.0/24 via $VYOS_IP
sudo ip route add 192.168.52.0/24 via $VYOS_IP
sudo ip route add 192.168.53.0/24 via $VYOS_IP

# Make persistent (add to /etc/sysconfig/network-scripts/route-<interface>)
```

## Verification

### Check Networks

```bash
# List libvirt networks
virsh net-list --all

# Expected output:
# 1924      active   yes   yes
# 1925      active   yes   yes
# 1926      active   yes   yes
# 1927      active   yes   yes
# 1928      active   yes   yes
# default   active   yes   yes
```

### Check VyOS Status

```bash
# SSH to VyOS
ssh vyos@<VYOS_IP>

# Show interfaces
show interfaces

# Show routes
show ip route

# Show NAT rules
show nat source rules

# Show DHCP leases
show dhcp server leases
```

### Test Connectivity

```bash
# From host, ping VyOS internal interface
ping 192.168.49.1

# From VyOS, ping FreeIPA
ping <FREEIPA_IP>

# From VyOS, test DNS
nslookup ipa.example.com <FREEIPA_IP>
```

## Troubleshooting

### VM Not Starting

```bash
# Check VM status
virsh dominfo vyos-router

# Check for errors
virsh start vyos-router 2>&1
```

### Network Not Active

```bash
# Start network
virsh net-start 1924

# Check network info
virsh net-info 1924
```

### No IP Address

```bash
# Check DHCP leases
virsh net-dhcp-leases default

# Access console
virsh console vyos-router
```

### Routing Issues

```bash
# On VyOS, check routes
show ip route

# On host, check routes
ip route show

# Test with traceroute
traceroute 192.168.49.1
```

## Cleanup

### Via Airflow DAG

```bash
podman exec airflow_airflow-scheduler_1 \
  airflow dags trigger vyos_router_deployment \
  --conf '{"action": "destroy"}'
```

### Manual Cleanup

```bash
# Stop and delete VM
virsh destroy vyos-router
virsh undefine vyos-router --remove-all-storage

# Remove networks (optional)
for NET in 1924 1925 1926 1927 1928; do
  virsh net-destroy $NET
  virsh net-undefine $NET
done
```

## Related Documentation

- [FreeIPA Deployment](freeipa-identity-management.md) - **Prerequisite** - Identity management
- [OpenShift Deployment](onedev-kcli-ocp4-ai-svc-universal.md) - Container platform
- [ADR-0039](../adrs/adr-0039-freeipa-vyos-airflow-dag-integration.md) - DAG Integration
- [ADR-0041](../adrs/adr-0041-vyos-version-upgrade-strategy.md) - VyOS Version Strategy
- [ADR-0043](../adrs/adr-0043-airflow-container-host-network-access.md) - Host Network Access

## Quick Reference

```bash
# Create networks and get instructions
podman exec airflow_airflow-scheduler_1 \
  airflow dags trigger vyos_router_deployment \
  --conf '{"action": "create"}'

# Check networks
virsh net-list --all

# Check VM
virsh dominfo vyos-router

# Access VyOS console
virsh console vyos-router

# SSH to VyOS (after installation)
ssh vyos@<VYOS_IP>

# Destroy VyOS
podman exec airflow_airflow-scheduler_1 \
  airflow dags trigger vyos_router_deployment \
  --conf '{"action": "destroy"}'
```

---

**Deploy FreeIPA first, then VyOS Router for complete network infrastructure!**
