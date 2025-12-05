# Security DAGs

This directory contains DAGs for security scanning, compliance, and hardening.

## Overview

Security DAGs automate security-related tasks including:
- Vulnerability scanning
- Compliance checking
- Security hardening
- Certificate management
- Security audit and reporting

## Status

This category is currently **empty** and ready for contributions.

## Expected DAGs

Future security DAGs may include:

| DAG | Description | Status |
|-----|-------------|--------|
| `security_vulnerability_scan` | Scan infrastructure for vulnerabilities | Planned |
| `security_compliance_check` | Check compliance with security standards (CIS, STIG) | Planned |
| `security_hardening` | Apply security hardening configurations | Planned |
| `security_audit` | Generate security audit reports | Planned |
| `certificate_rotation` | Rotate expiring certificates | Planned |
| `security_monitoring_setup` | Deploy security monitoring tools | Planned |

## Related Security Components

Some security functionality exists in other categories:

- **step_ca_deployment**: Certificate authority (in `infrastructure/`)
- **step_ca_operations**: Certificate management (in `infrastructure/`)

## Use Cases

Security DAGs are useful for:

1. **Continuous Security**: Regular vulnerability scanning
2. **Compliance**: Automated compliance validation
3. **Incident Response**: Rapid deployment of security patches
4. **Audit**: Automated security audit trails
5. **Best Practices**: Enforcing security configurations

## Contributing

We welcome security DAGs! To contribute:

1. **Identify a need**: What security automation would be valuable?
2. **Follow the template**: Use [../TEMPLATE.py](../TEMPLATE.py)
3. **Follow standards**: See [ADR-0045](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0045-dag-standards.md)
4. **Security first**: Ensure DAGs don't introduce vulnerabilities
5. **Submit PR**: See [CONTRIBUTING.md](../../CONTRIBUTING.md)

## DAG Naming Convention

Security DAGs should follow this pattern:
- `security_<component>_<action>.py`
- Examples:
  - `security_vulnerability_scan.py`
  - `security_compliance_check.py`
  - `security_hardening.py`

## Security Best Practices

When developing security DAGs:

1. **Least Privilege**: Use minimal required permissions
2. **Secrets Management**: Never hardcode credentials
3. **Audit Logging**: Log all security operations
4. **Non-Destructive**: Security checks should be read-only when possible
5. **Reporting**: Generate clear, actionable reports

## Example Parameters

Security DAGs typically include:

```python
params={
    'action': 'scan',  # scan, report, remediate
    'scan_type': 'vulnerability',  # vulnerability, compliance, configuration
    'severity_threshold': 'high',  # critical, high, medium, low
    'compliance_standard': 'cis',  # cis, stig, pci-dss
    'remediate': 'false',  # Auto-remediate findings
}
```

## Security Standards

Security DAGs should align with:

- **CIS Benchmarks**: Center for Internet Security standards
- **STIG**: Security Technical Implementation Guides
- **PCI-DSS**: Payment Card Industry standards
- **NIST**: National Institute of Standards and Technology
- **ISO 27001**: Information security management

## Example Workflow

```
1. Scan for vulnerabilities
   └─> security_vulnerability_scan

2. Generate compliance report
   └─> security_compliance_check

3. Apply hardening (if approved)
   └─> security_hardening

4. Verify changes
   └─> security_vulnerability_scan (re-scan)

5. Generate audit report
   └─> security_audit
```

## Related Documentation

- [CONTRIBUTING.md](../../CONTRIBUTING.md) - Contribution guidelines
- [DAG Template](../TEMPLATE.py) - Template for new DAGs
- [Registry](../registry.yaml) - DAG registry and metadata
- [Step-CA Operations](../infrastructure/step_ca_operations.py) - Certificate management
