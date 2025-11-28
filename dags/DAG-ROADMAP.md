# kcli-pipelines DAG Roadmap

## Overview

This document outlines the Airflow DAGs for kcli-pipelines, following ADR-0047 (kcli-pipelines as DAG Source Repository).

## DAG Architecture

```
+------------------------------------------------------------------+
|                    Base Infrastructure DAGs                       |
+------------------------------------------------------------------+
| freeipa_deployment.py     | DNS/Identity Management (TESTED)     |
| vyos_router_deployment.py | Network Router (TESTED)              |
| step_ca_deployment.py     | Certificate Authority (PLANNED)      |
+------------------------------------------------------------------+

+------------------------------------------------------------------+
|                    Generic VM DAGs                                |
+------------------------------------------------------------------+
| generic_vm_deployment.py  | RHEL8/9, Fedora, Ubuntu, CentOS      |
| jumpserver_deployment.py  | Browser-based access (Guacamole)     |
+------------------------------------------------------------------+

+------------------------------------------------------------------+
|                    OpenShift DAGs                                 |
+------------------------------------------------------------------+
| ocp_agent_installer.py    | Agent-based installer (NOT TESTED)   |
| ocp_baremetal_internal.py | Baremetal internal (NOT TESTED)      |
| ocp_baremetal_external.py | Baremetal + Route53 (NOT TESTED)     |
| ocp_disconnected.py       | Disconnected install (NOT TESTED)    |
+------------------------------------------------------------------+

+------------------------------------------------------------------+
|                    Registry/Storage DAGs                          |
+------------------------------------------------------------------+
| registry_deployment.py    | Harbor/Mirror Registry (NOT TESTED)  |
| ceph_cluster.py           | Ceph Storage (NOT TESTED)            |
+------------------------------------------------------------------+
```

## Priority Order

### Phase 1: Core Infrastructure (COMPLETE)
- [x] `freeipa_deployment.py` - DNS/Identity
- [x] `vyos_router_deployment.py` - Network routing

### Phase 2: Essential Services (IN PROGRESS)
- [ ] `generic_vm_deployment.py` - Foundation for all VMs
- [ ] `step_ca_deployment.py` - Certificates for disconnected installs

### Phase 3: User Access
- [ ] `jumpserver_deployment.py` - Browser-based GUI access

### Phase 4: OpenShift (NOT TESTED)
- [ ] `ocp_agent_installer.py` - Full stack deployment
- [ ] `ocp_disconnected.py` - Disconnected installs

---

## DAG Details

### 1. generic_vm_deployment.py (Priority: HIGH)

**Purpose**: Deploy any VM type using kcli profiles

**Supported VM Types**:
- rhel8, rhel9
- fedora39
- ubuntu
- centos9stream
- openshift-jumpbox
- microshift-demos
- device-edge-workshops
- ansible-aap

**Parameters**:
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| action | choice | create | create, delete, status |
| vm_profile | choice | rhel9 | VM profile to deploy |
| vm_name | string | auto | VM name (auto-generated if empty) |
| community_version | bool | false | Use community packages |

**Tasks**:
1. `validate_environment` - Check kcli, images, FreeIPA
2. `configure_kcli_profile` - Set up VM profile
3. `create_vm` - Deploy VM via kcli
4. `register_dns` - Add to FreeIPA DNS
5. `configure_vm` - Post-deploy configuration
6. `validate_deployment` - Health checks

**Script**: `/opt/kcli-pipelines/deploy-vm.sh`

---

### 2. step_ca_deployment.py (Priority: HIGH)

**Purpose**: Deploy Step-CA certificate authority for disconnected installs

**Why Important**:
- Required for disconnected OpenShift installs
- Provides internal PKI infrastructure
- Used by Harbor/Mirror Registry
- Integrates with ocp4-disconnected-helper
- ACME protocol support (Certbot, Caddy, Traefik compatible)
- Short-lived certificates for zero-trust architectures

**ADR**: [ADR-0048: Step-CA Integration for Disconnected Deployments](../../qubinode_navigator/docs/adrs/adr-0048-step-ca-integration-for-disconnected-deployments.md)

**Parameters**:
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| action | choice | create | create, delete |
| domain | string | example.com | Domain for certificates |
| vm_name | string | step-ca-server | VM name |

**Tasks**:
1. `validate_environment` - Check prerequisites
2. `configure_kcli_profile` - Set up step-ca profile
3. `create_vm` - Deploy step-ca-server VM
4. `configure_step_ca` - Initialize CA, add ACME provisioner
5. `register_ca` - Register with system trust
6. `validate_deployment` - Test certificate issuance

**Integration Points**:
- **Mirror Registry**: TLS certificates for Harbor/Quay
- **OpenShift**: `additionalTrustBundle` for disconnected installs
- **Kubernetes**: cert-manager ClusterIssuer or autocert controller
- **Services**: ACME protocol for automatic certificate renewal

**Scripts**:
- `/opt/kcli-pipelines/step-ca-server/configure-kcli-profile.sh`
- `/opt/kcli-pipelines/step-ca-server/configure-step-ca-local.sh`
- `/opt/kcli-pipelines/step-ca-server/register-step-ca.sh`

**Post-Deployment Usage**:
```bash
# Get CA fingerprint
step certificate fingerprint $(step path)/certs/root_ca.crt

# Bootstrap client
step ca bootstrap --ca-url https://step-ca-server.example.com:443 --fingerprint <FINGERPRINT>

# Request certificate (ACME)
step ca certificate myservice.example.com cert.pem key.pem --provisioner acme

# Request certificate (JWK)
step ca certificate myservice.example.com cert.pem key.pem
```

**Documentation**: [Using Step-CA Guide](/root/kcli-pipelines/step-ca-server/docs/using-step-ca.md)

---

### 2b. step_ca_operations.py (Utility DAG)

**Purpose**: Certificate operations after Step-CA deployment

**Operations**:
| Operation | Description |
|-----------|-------------|
| `get_ca_info` | Get CA fingerprint, root cert, provisioners |
| `request_certificate` | Request a new certificate |
| `renew_certificate` | Renew an existing certificate |
| `revoke_certificate` | Revoke a certificate |
| `bootstrap_client` | Bootstrap a host to trust the CA |

**Example Usage**:
```bash
# Get CA info
airflow dags trigger step_ca_operations --conf '{
    "operation": "get_ca_info",
    "ca_url": "https://step-ca-server.example.com:443"
}'

# Request certificate for registry
airflow dags trigger step_ca_operations --conf '{
    "operation": "request_certificate",
    "ca_url": "https://step-ca-server.example.com:443",
    "common_name": "registry.example.com",
    "san_list": "registry,localhost",
    "duration": "8760h",
    "output_path": "/tmp/certs"
}'

# Bootstrap a new host
airflow dags trigger step_ca_operations --conf '{
    "operation": "bootstrap_client",
    "ca_url": "https://step-ca-server.example.com:443",
    "target_host": "webserver.example.com"
}'
```

---

### 3. jumpserver_deployment.py (Priority: MEDIUM)

**Purpose**: Deploy browser-based access to the environment via Apache Guacamole

**Features**:
- Web-based SSH/VNC/RDP access
- No client software required
- Secure access from anywhere
- Integrated with FreeIPA authentication

**Parameters**:
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| action | choice | create | create, delete |
| guacamole_version | string | latest | Guacamole version |
| enable_vnc | bool | true | Enable VNC connections |
| enable_ssh | bool | true | Enable SSH connections |

**Tasks**:
1. `validate_environment` - Check prerequisites
2. `create_jumpserver_vm` - Deploy Fedora VM
3. `install_guacamole` - Install Apache Guacamole
4. `configure_connections` - Set up VM connections
5. `configure_auth` - FreeIPA integration
6. `validate_deployment` - Test web access

**Architecture**:
```
Browser --> Nginx (443) --> Guacamole --> VMs
                                      --> VyOS Console
                                      --> Host SSH
```

---

### 4. ocp_agent_installer.py (Priority: LOW - NOT TESTED)

**Purpose**: Full OpenShift deployment using agent-based installer

**Prerequisites**:
- FreeIPA (DNS)
- VyOS Router (networking)
- Step-CA (certificates, for disconnected)

**Workflow**:
1. Deploy FreeIPA (if not exists)
2. Deploy VyOS Router (if not exists)
3. Wait for VyOS configuration
4. Configure host routes
5. Configure DNS entries
6. Deploy OpenShift

**Source**: OneDev `Internal - OpenShift Agent Based Installer Helper`

---

## Integration with ocp4-disconnected-helper

The Step-CA DAG is critical for disconnected installs:

```
+------------------+     +------------------+     +------------------+
|   Step-CA        | --> | Mirror Registry  | --> | OpenShift        |
|   (Certificates) |     | (Images)         |     | (Disconnected)   |
+------------------+     +------------------+     +------------------+
```

**ocp4-disconnected-helper** uses Step-CA for:
- Registry TLS certificates
- Internal service certificates
- Cluster certificate signing

---

## Testing Status

| DAG | Status | Last Tested | Notes |
|-----|--------|-------------|-------|
| freeipa_deployment.py | ✅ TESTED | 2025-11-27 | Working |
| vyos_router_deployment.py | ✅ TESTED | 2025-11-27 | Working |
| generic_vm_deployment.py | ✅ TESTED | 2025-11-28 | Working - deployed test-rhel9 VM |
| step_ca_deployment.py | ✅ TESTED | 2025-11-28 | Working - deployed step-ca-server VM |
| step_ca_operations.py | ✅ TESTED | 2025-11-28 | Certificate operations - provides instructions |
| jumpserver_deployment.py | 🔨 PLANNED | - | Priority 3 |
| ocp_agent_installer.py | ⚠️ NOT TESTED | - | From OneDev |
| ocp_baremetal_internal.py | ⚠️ NOT TESTED | - | From OneDev |
| ocp_baremetal_external.py | ⚠️ NOT TESTED | - | From OneDev |
| registry_deployment.py | ⚠️ NOT TESTED | - | From OneDev |

---

## Contributing

1. Create deploy.sh in `/opt/kcli-pipelines/<component>/`
2. Create DAG following ADR-0045 standards
3. DAG calls deploy.sh via SSH (ADR-0046, ADR-0047)
4. Test locally before committing
5. Update this roadmap with status
