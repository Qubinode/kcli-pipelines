# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

**qubinode-pipelines** is the Tier 2 middleware layer in a three-tier architecture for infrastructure automation. It hosts deployment DAGs (Directed Acyclic Graphs) for Apache Airflow and deployment scripts that integrate with qubinode_navigator (the Tier 3 runtime platform).

```
TIER 1: Domain Projects (contribute DAGs via PR)
    ↓
TIER 2: qubinode-pipelines (this repo - DAGs & scripts)
    ↓ (volume mount at /opt/qubinode-pipelines)
TIER 3: qubinode_navigator (Airflow runtime, platform services)
```

## Repository Structure

```
qubinode-pipelines/
├── dags/                      # Airflow DAGs organized by category
│   ├── registry.yaml          # Central DAG metadata registry
│   ├── TEMPLATE.py            # DAG template for new contributions
│   ├── infrastructure/        # Core infrastructure DAGs (10 tested)
│   ├── ocp/                   # OpenShift DAGs (awaiting contributions)
│   ├── networking/            # Network DAGs
│   ├── storage/               # Storage DAGs
│   └── security/              # Security DAGs
├── scripts/                   # Deployment scripts called by DAGs
│   ├── helper_scripts/
│   │   ├── default.env        # Common environment variables
│   │   └── helper_functions.sh
│   └── */deploy.sh            # Component deployment scripts
└── .github/workflows/dag-validation.yml  # CI validation
```

## Common Commands

```bash
# Validate DAG Python syntax
python -m py_compile dags/infrastructure/my_dag.py

# Check for ADR-0045 violations (quote style, naming)
grep -q "bash_command='''" dags/infrastructure/my_dag.py && echo "ERROR: Use \"\"\" not '''"

# Install validation dependencies
pip install apache-airflow==2.7.3 flake8 black pyyaml

# Lint DAGs
flake8 dags/ --max-line-length=120 --extend-ignore=E203,W503

# Check formatting
black --check --line-length 120 dags/

# Validate Airflow can import DAGs
export AIRFLOW_HOME=$(pwd)/airflow_test
airflow db migrate
cp -r dags/* $AIRFLOW_HOME/dags/
airflow dags list-import-errors
```

## Critical DAG Standards (ADR-0045)

### Quote Style - MANDATORY
```python
# ✅ CORRECT: Triple double quotes
bash_command="""
echo "[OK] Deployment complete"
"""

# ❌ WRONG: Triple single quotes (CI will fail)
bash_command='''
echo "[OK] Deployment complete"
'''
```

### SSH Execution Pattern (ADR-0046)
DAGs must execute scripts on the host via SSH to avoid container limitations:

```python
bash_command="""
ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
    "cd /opt/qubinode-pipelines/scripts/my-component && \
     export ACTION=create && \
     ./deploy.sh"
"""
```

### Naming Conventions
- **DAG filename**: snake_case (e.g., `freeipa_deployment.py`)
- **DAG ID**: Must match filename without `.py`
- **Task IDs**: snake_case, descriptive (e.g., `create_vm`, `validate_environment`)
- **Output markers**: ASCII only - `[OK]`, `[ERROR]`, `[WARN]`, `[INFO]`, `[SKIP]`

### Prohibited Patterns
- **No string concatenation**: Don't use `"""` + variable + `"""`
- **No Unicode/emoji**: Use ASCII markers only (no checkmarks, X marks, etc.)
- **No complex Jinja mixing**: Keep Jinja templates simple (`{{ params.domain }}`)

### Required Docstring
```python
"""
Airflow DAG: [Component Name] Deployment
Category: [ocp|infrastructure|networking|storage|security]

[Description]

Prerequisites:
- List prerequisites

Related ADRs:
- ADR-0045: DAG Standards
- ADR-0046: SSH Execution Pattern
"""
```

## Deployment Script Pattern (ADR-0047)

Scripts in `scripts/*/deploy.sh` must support:

```bash
#!/bin/bash
set -euo pipefail
ACTION="${ACTION:-create}"

# Source environment
if [ -f /opt/qubinode-pipelines/scripts/helper_scripts/default.env ]; then
    source /opt/qubinode-pipelines/scripts/helper_scripts/default.env
fi

function create() { echo "[OK] Created"; }
function delete() { echo "[OK] Deleted"; }
function status() { echo "[INFO] Status checked"; }

case "${ACTION}" in
    create|delete|status) ${ACTION} ;;
    *) echo "[ERROR] Invalid action"; exit 1 ;;
esac
```

## CI/CD Pipeline

GitHub Actions validates every PR:
1. **Python syntax**: `python -m py_compile`
2. **ADR-0045 compliance**: Quote style, snake_case, docstrings
3. **Airflow import**: Tests DAG loads without errors
4. **Registry check**: Verifies `dags/registry.yaml` is updated

## Key Environment Variables

From `scripts/helper_scripts/default.env`:
- `KCLI_SAMPLES_DIR="/opt/qubinode-pipelines/"` - Repository mount path
- `NET_NAME=qubinet` - Default libvirt bridge network
- `INVENTORY=localhost` - Ansible inventory target

## Contributing a New DAG

1. Copy `dags/TEMPLATE.py` to appropriate category
2. Implement using SSH execution pattern
3. Use `"""` quotes (never `'''`)
4. Use ASCII output markers
5. Update `dags/registry.yaml` with metadata
6. Submit PR with validation evidence

## Pre-Commit Validation Checklist

Before submitting a PR, verify:
- [ ] DAG file uses snake_case naming
- [ ] DAG ID matches filename (without `.py`)
- [ ] Uses `"""` (double quotes) for bash_command - never `'''`
- [ ] No Unicode/emoji characters in bash commands
- [ ] No string concatenation in bash_command
- [ ] All paths hardcoded or use environment variables
- [ ] Error handling uses simple exit codes (0=success, 1=failure)
- [ ] SSH pattern used for kcli/Ansible commands (ADR-0046)
- [ ] Python syntax check passes: `python -m py_compile dags/my_dag.py`
- [ ] `dags/registry.yaml` updated with new DAG metadata

## Related Documentation

- [CONTRIBUTING.md](CONTRIBUTING.md) - Full contribution workflow
- [dags/TEMPLATE.py](dags/TEMPLATE.py) - Complete DAG template with examples
- [dags/registry.yaml](dags/registry.yaml) - DAG metadata registry

### ADRs in qubinode_navigator
| ADR | Topic |
|-----|-------|
| ADR-0045 | DAG Development Standards (quote style, naming, output) |
| ADR-0046 | SSH Execution Pattern & Validation Pipeline |
| ADR-0047 | qubinode-pipelines Repository Architecture |
| ADR-0061 | Multi-Repository Architecture (Tier 1/2/3) |
