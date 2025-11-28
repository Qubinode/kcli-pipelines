# FreeIPA Identity Management Deployment

**Status:** Production Ready  
**Category:** Infrastructure Prerequisites  
**Priority:** Required (Prerequisite for all other deployments)  
**ADRs:** ADR-0039, ADR-0042, ADR-0043

## Overview

FreeIPA provides centralized identity management, authentication, and authorization for the Qubinode environment. It is a **prerequisite** for all other deployments including OpenShift, VyOS router configuration, and application workloads.

### Key Features

- **Centralized Authentication**: LDAP-based user and group management
- **Kerberos SSO**: Single sign-on across all integrated services
- **DNS Management**: Integrated DNS for service discovery
- **Certificate Authority**: PKI for TLS certificates
- **Host-Based Access Control**: Fine-grained access policies

## Prerequisites

| Requirement | Details |
|-------------|---------|
| **Hypervisor** | KVM/libvirt configured and running |
| **kcli** | Installed and configured |
| **Base Image** | CentOS 9 Stream or RHEL 9 |
| **Network** | Default libvirt network (192.168.122.0/24) |
| **Resources** | 4GB RAM, 2 vCPUs, 50GB disk minimum |
| **Airflow** | Running with host network mode (ADR-0043) |

## Deployment Methods

### Method 1: Airflow DAG (Recommended)

The FreeIPA deployment DAG automates VM provisioning and provides guided installation steps.

#### Via Airflow UI

1. Navigate to **DAGs** → `freeipa_deployment`
2. Click **Trigger DAG w/ config**
3. Configure parameters:
   ```json
   {
     "action": "create",
     "community_version": "true",
     "os_version": "9"
   }
   ```
4. Click **Trigger**

#### Via CLI

```bash
# Trigger FreeIPA deployment
podman exec airflow_airflow-scheduler_1 \
  airflow dags trigger freeipa_deployment \
  --conf '{"action": "create", "community_version": "true", "os_version": "9"}'

# Check status
podman exec airflow_airflow-scheduler_1 \
  airflow dags list-runs -d freeipa_deployment
```

#### Via API

```bash
curl -X POST "http://localhost:8888/api/v1/dags/freeipa_deployment/dagRuns" \
  -H "Content-Type: application/json" \
  -u admin:admin \
  -d '{"conf": {"action": "create", "community_version": "true", "os_version": "9"}}'
```

### Method 2: Manual Deployment

```bash
# Create FreeIPA VM with kcli
kcli create vm freeipa \
  -i centos9stream \
  -P memory=4096 \
  -P numcpus=2 \
  -P disks=[50] \
  -P nets=[default]

# Get VM IP
kcli info vm freeipa | grep "^ip:"
```

## DAG Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `action` | `create` | Action to perform: `create` or `destroy` |
| `community_version` | `false` | Use CentOS (`true`) or RHEL (`false`) |
| `os_version` | `9` | OS version: `8` or `9` |
| `target_server` | `` | Target server profile (optional) |

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
│clone_freeipa_deployer│
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ configure_deployment │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   create_freeipa_vm  │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  wait_for_services   │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ validate_deployment  │
└─────────────────────┘
```

## Post-Deployment: FreeIPA Installation

After the VM is created, SSH in and install FreeIPA:

```bash
# SSH into the VM
ssh cloud-user@<FREEIPA_IP>

# Become root
sudo -i

# Set hostname
hostnamectl set-hostname ipa.example.com

# Update /etc/hosts
echo "<FREEIPA_IP> ipa.example.com ipa" >> /etc/hosts

# Install FreeIPA packages
dnf install -y ipa-server ipa-server-dns

# Run FreeIPA installer
ipa-server-install \
  --realm=EXAMPLE.COM \
  --domain=example.com \
  --ds-password=<DIRECTORY_MANAGER_PASSWORD> \
  --admin-password=<ADMIN_PASSWORD> \
  --setup-dns \
  --forwarder=8.8.8.8 \
  --no-ntp \
  --unattended
```

### Installation Options

| Option | Description |
|--------|-------------|
| `--realm` | Kerberos realm (uppercase) |
| `--domain` | DNS domain |
| `--ds-password` | Directory Server admin password |
| `--admin-password` | IPA admin user password |
| `--setup-dns` | Configure integrated DNS |
| `--forwarder` | DNS forwarder for external queries |
| `--no-ntp` | Skip NTP configuration (if using external NTP) |

## Verification

### Check FreeIPA Services

```bash
# On FreeIPA server
ipactl status

# Expected output:
# Directory Service: RUNNING
# krb5kdc Service: RUNNING
# kadmin Service: RUNNING
# named Service: RUNNING
# httpd Service: RUNNING
# ipa-custodia Service: RUNNING
# pki-tomcatd Service: RUNNING
# ipa-otpd Service: RUNNING
# ipa-dnskeysyncd Service: RUNNING
```

### Test Authentication

```bash
# Get Kerberos ticket
kinit admin

# List users
ipa user-find

# Check DNS
dig @<FREEIPA_IP> ipa.example.com
```

### Access Web UI

- **URL**: https://<FREEIPA_IP>/ipa/ui/
- **Username**: admin
- **Password**: <ADMIN_PASSWORD>

## Integration with Other Services

### OpenShift Integration

FreeIPA can provide:
- LDAP authentication for OpenShift users
- DNS for cluster services
- Certificates for ingress

### VyOS Router Integration

Configure VyOS to use FreeIPA DNS:
```
set system name-server <FREEIPA_IP>
```

## Troubleshooting

### VM Not Getting IP

```bash
# Check VM status
kcli info vm freeipa

# Check libvirt network
virsh net-dhcp-leases default
```

### FreeIPA Installation Fails

```bash
# Check logs
journalctl -u dirsrv@EXAMPLE-COM
journalctl -u krb5kdc
cat /var/log/ipaserver-install.log
```

### DNS Not Resolving

```bash
# Check named service
systemctl status named

# Test DNS
dig @localhost ipa.example.com
```

## Cleanup

### Via Airflow DAG

```bash
podman exec airflow_airflow-scheduler_1 \
  airflow dags trigger freeipa_deployment \
  --conf '{"action": "destroy"}'
```

### Manual Cleanup

```bash
# Delete VM
kcli delete vm freeipa -y

# Verify deletion
kcli list vm
```

## Related Documentation

- [VyOS Router Deployment](vyos-router-deployment.md) - Network segmentation (requires FreeIPA DNS)
- [OpenShift Deployment](onedev-kcli-ocp4-ai-svc-universal.md) - Container platform
- [ADR-0039](../adrs/adr-0039-freeipa-vyos-airflow-dag-integration.md) - DAG Integration
- [ADR-0042](../adrs/adr-0042-freeipa-base-os-upgrade-rhel9.md) - RHEL 9 Migration
- [ADR-0043](../adrs/adr-0043-airflow-container-host-network-access.md) - Host Network Access

## Quick Reference

```bash
# Deploy FreeIPA
podman exec airflow_airflow-scheduler_1 \
  airflow dags trigger freeipa_deployment \
  --conf '{"action": "create", "community_version": "true", "os_version": "9"}'

# Check VM
kcli info vm freeipa

# SSH to VM
ssh cloud-user@$(kcli info vm freeipa | grep "^ip:" | awk '{print $2}')

# Destroy FreeIPA
podman exec airflow_airflow-scheduler_1 \
  airflow dags trigger freeipa_deployment \
  --conf '{"action": "destroy"}'
```

---

**FreeIPA is a prerequisite for all other Qubinode deployments. Deploy it first!**
