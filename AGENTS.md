# AGENTS.md - AI Coding Agent Instructions for qubinode-pipelines

> **Purpose**: This file provides comprehensive context and instructions for AI coding agents (Claude Code, Cursor, GitHub Copilot, etc.) to effectively contribute to the qubinode-pipelines repository.

______________________________________________________________________

## Quick Context

**What is qubinode-pipelines?**
The **Tier 2 middleware layer** in the three-tier Qubinode architecture. It hosts:

- **Deployment DAGs** - Airflow workflow definitions for infrastructure automation
- **Deployment Scripts** - Shell scripts that perform actual deployments
- **DAG Registry** - Central metadata registry for all DAGs

**This repository does NOT contain:**
- Airflow runtime (that's in qubinode_navigator)
- Domain-specific playbooks (those stay in Tier 1 projects)
- Platform services (AI Assistant, MCP servers)

**Primary Use Cases:**

1. Contributing new deployment DAGs for infrastructure components
2. Adding deployment scripts for new automation workflows
3. Updating existing DAGs to fix bugs or add features
4. Maintaining the DAG registry

______________________________________________________________________

## Three-Tier Architecture

```
TIER 1: DOMAIN PROJECTS (ocp4-disconnected-helper, freeipa-workshop-deployer)
    │   Own: Playbooks, domain logic
    │   Contribute: DAGs via PR to this repo
    ▼
TIER 2: QUBINODE-PIPELINES (this repo)
    │   Own: DAGs, deployment scripts, registry
    │   Mounted at: /opt/qubinode-pipelines
    ▼
TIER 3: QUBINODE_NAVIGATOR (runtime platform)
        Own: Airflow, AI Assistant, MCP servers, ADRs
```

______________________________________________________________________

## Repository Structure

```
qubinode-pipelines/
├── AGENTS.md                 # THIS FILE - AI agent instructions
├── CLAUDE.md                 # Claude Code specific instructions
├── CONTRIBUTING.md           # Human contribution guide
├── README.md                 # Project overview
│
├── dags/                     # Deployment DAGs organized by category
│   ├── registry.yaml         # Central DAG metadata registry
│   ├── TEMPLATE.py           # Template for new DAGs
│   ├── infrastructure/       # Core infrastructure (10 DAGs)
│   │   ├── freeipa_deployment.py
│   │   ├── vyos_router_deployment.py
│   │   ├── step_ca_deployment.py
│   │   ├── mirror_registry_deployment.py
│   │   └── ...
│   ├── ocp/                  # OpenShift DAGs (awaiting contributions)
│   ├── networking/           # Network configuration DAGs
│   ├── storage/              # Storage cluster DAGs
│   └── security/             # Security and compliance DAGs
│
├── scripts/                  # Deployment scripts called by DAGs
│   ├── helper_scripts/
│   │   ├── default.env       # Common environment variables
│   │   └── helper_functions.sh
│   ├── vyos-router/
│   │   └── deploy.sh
│   ├── freeipa/
│   │   └── deploy-freeipa.sh
│   └── step-ca-server/
│       └── deploy.sh
│
└── .github/
    ├── workflows/
    │   └── dag-validation.yml  # CI validation pipeline
    └── PULL_REQUEST_TEMPLATE.md
```

______________________________________________________________________

## DAG Standards (CRITICAL - ADR-0045)

All DAGs MUST follow these standards. CI will reject non-compliant DAGs.

### Quote Style - MANDATORY

```python
# CORRECT: Use triple double quotes
bash_command="""
echo "[OK] Deployment complete"
"""

# WRONG: Never use triple single quotes (CI will fail)
bash_command='''
echo "[OK] Deployment complete"
'''
```

### Naming Conventions

| Element | Convention | Example |
|---------|------------|---------|
| DAG filename | snake_case | `freeipa_deployment.py` |
| DAG ID | Matches filename | `freeipa_deployment` |
| Task IDs | snake_case | `validate_environment` |
| Output markers | ASCII only | `[OK]`, `[ERROR]`, `[WARN]`, `[INFO]` |

### SSH Execution Pattern (ADR-0046)

DAGs run inside Airflow containers but must execute commands on the host:

```python
bash_command="""
ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
    "cd /opt/qubinode-pipelines/scripts/my-component && \
     export ACTION={{ params.action }} && \
     ./deploy.sh"
"""
```

### Standard DAG Template

```python
"""
Airflow DAG: [Component Name] Deployment
Category: [infrastructure|ocp|networking|storage|security]

[Description of what this DAG does]

Prerequisites:
- List prerequisites here

Related ADRs:
- ADR-0045: DAG Development Standards
- ADR-0046: SSH Execution Pattern
"""

from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.bash import BashOperator

default_args = {
    'owner': 'qubinode',
    'depends_on_past': False,
    'start_date': datetime(2025, 1, 1),
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 1,
    'retry_delay': timedelta(minutes=3),
}

dag = DAG(
    'my_component_deployment',  # Must match filename
    default_args=default_args,
    description='Short description',
    schedule=None,
    catchup=False,
    tags=['qubinode', 'qubinode-pipelines', 'category'],
    params={
        'action': 'create',  # create or destroy
    },
)

deploy = BashOperator(
    task_id='deploy_component',
    bash_command="""
    echo "========================================"
    echo "Deploying Component"
    echo "========================================"

    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR root@localhost \
        "export ACTION={{ params.action }} && \
         cd /opt/qubinode-pipelines/scripts/my-component && \
         ./deploy.sh"

    echo "[OK] Deployment completed"
    """,
    dag=dag,
)
```

______________________________________________________________________

## Contribution Workflow

### For AI Agents Contributing DAGs

1. **Create DAG** following the template above
2. **Validate locally**:
   ```bash
   # Syntax check
   python -m py_compile dags/infrastructure/my_dag.py

   # Check for prohibited patterns
   grep -q "bash_command='''" dags/infrastructure/my_dag.py && echo "ERROR: Use triple double quotes"
   ```
3. **Update registry.yaml** with DAG metadata
4. **Commit with conventional format**:
   ```
   feat(dags): Add my_component_deployment DAG

   - Adds deployment DAG for [component]
   - Follows ADR-0045 standards
   - SSH execution pattern (ADR-0046)
   ```
5. **Push and create PR** - CI will validate automatically

### Pre-Commit Checklist

Before committing any DAG:

- [ ] Filename is snake_case
- [ ] DAG ID matches filename (without .py)
- [ ] Uses `"""` for bash_command (never `'''`)
- [ ] No Unicode/emoji in bash commands
- [ ] Uses SSH pattern for host execution
- [ ] Has docstring with description and prerequisites
- [ ] `python -m py_compile` passes
- [ ] `dags/registry.yaml` updated

______________________________________________________________________

## Deployment Script Standards (ADR-0047)

Scripts in `scripts/*/deploy.sh` must follow this pattern:

```bash
#!/bin/bash
# Component Deployment Script
set -euo pipefail

ACTION="${ACTION:-create}"

# Source environment
if [ -f /opt/qubinode-pipelines/scripts/helper_scripts/default.env ]; then
    source /opt/qubinode-pipelines/scripts/helper_scripts/default.env
fi

echo "========================================"
echo "Component Deployment"
echo "========================================"
echo "Action: ${ACTION}"

function create() {
    echo "[INFO] Creating component..."
    # Implementation
    echo "[OK] Component created"
}

function delete() {
    echo "[INFO] Deleting component..."
    # Implementation
    echo "[OK] Component deleted"
}

function status() {
    echo "[INFO] Checking status..."
    # Implementation
    echo "[OK] Status check complete"
}

case "${ACTION}" in
    create|delete|status) ${ACTION} ;;
    *) echo "[ERROR] Invalid action: ${ACTION}"; exit 1 ;;
esac
```

______________________________________________________________________

## CI/CD Pipeline

GitHub Actions automatically validates PRs:

1. **Python Syntax** - `python -m py_compile` on all DAGs
2. **ADR-0045 Compliance** - Quote style, naming, docstrings
3. **Airflow Import** - Verifies DAGs load without errors
4. **Registry Check** - Warns if registry.yaml not updated

### CI Configuration

The workflow uses Airflow 2.7.3 with official constraint files:

```yaml
pip install "apache-airflow==2.7.3" --constraint "$CONSTRAINT_URL"
pip install "apache-airflow-providers-ssh" --constraint "$CONSTRAINT_URL"
```

______________________________________________________________________

## Common Tasks for AI Agents

### Adding a New Infrastructure DAG

```bash
# 1. Copy template
cp dags/TEMPLATE.py dags/infrastructure/my_component_deployment.py

# 2. Edit the DAG (follow standards above)

# 3. Validate
python -m py_compile dags/infrastructure/my_component_deployment.py

# 4. Update registry
# Edit dags/registry.yaml

# 5. Commit
git add dags/infrastructure/my_component_deployment.py dags/registry.yaml
git commit -m "feat(dags): Add my_component_deployment DAG"
```

### Fixing a DAG Standards Violation

```bash
# Find violations
grep -r "bash_command='''" dags/

# Fix by replacing ''' with """
sed -i "s/bash_command='''/bash_command=\"\"\"/g" dags/infrastructure/broken_dag.py
sed -i "s/'''/\"\"\"/g" dags/infrastructure/broken_dag.py
```

### Adding a Deployment Script

```bash
# 1. Create directory
mkdir -p scripts/my-component

# 2. Create script following standard pattern
cat > scripts/my-component/deploy.sh << 'EOF'
#!/bin/bash
set -euo pipefail
ACTION="${ACTION:-create}"
# ... (follow template above)
EOF

# 3. Make executable
chmod +x scripts/my-component/deploy.sh
```

______________________________________________________________________

## Environment Variables

From `scripts/helper_scripts/default.env`:

| Variable | Default | Description |
|----------|---------|-------------|
| `KCLI_SAMPLES_DIR` | `/opt/qubinode-pipelines/` | Repository mount path |
| `NET_NAME` | `qubinet` | Default libvirt network |
| `INVENTORY` | `localhost` | Ansible inventory target |

______________________________________________________________________

## Related Documentation

### In This Repository
- [CONTRIBUTING.md](CONTRIBUTING.md) - Detailed contribution guide
- [README.md](README.md) - Project overview
- [dags/TEMPLATE.py](dags/TEMPLATE.py) - Full DAG template
- [dags/registry.yaml](dags/registry.yaml) - DAG registry

### In qubinode_navigator
- [ADR-0045](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0045-dag-standards.md) - DAG Development Standards
- [ADR-0046](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0046-ssh-execution-pattern.md) - SSH Execution Pattern
- [ADR-0047](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0047-deployment-script-repository.md) - Deployment Script Repository
- [ADR-0061](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0061-multi-repository-architecture.md) - Multi-Repository Architecture
- [ADR-0062](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0062-external-project-integration-guide.md) - External Project Integration

______________________________________________________________________

## Agent Session Checklist

When starting a new session:

- [ ] Understand the three-tier architecture
- [ ] Check current branch and git status
- [ ] Reference ADR-0045 for DAG standards
- [ ] Use SSH pattern (ADR-0046) for host commands
- [ ] Validate DAGs before committing
- [ ] Update registry.yaml for new DAGs
- [ ] Follow conventional commit format

______________________________________________________________________

## Prohibited Patterns

| Pattern | Problem | Solution |
|---------|---------|----------|
| `bash_command='''` | Breaks Jinja templating | Use `"""` |
| `✅`, `❌`, `🚀` | Unicode breaks logging | Use `[OK]`, `[ERROR]` |
| String concatenation | Unpredictable behavior | Single heredoc string |
| Direct ansible in container | Version mismatch | SSH to host |
| Hardcoded credentials | Security risk | Use params or env vars |

______________________________________________________________________

*Last updated: 2025-12-06*
*Version: 1.0 - Initial creation*
*Compatible with: Claude Code, Cursor, GitHub Copilot, and other AI coding agents*
