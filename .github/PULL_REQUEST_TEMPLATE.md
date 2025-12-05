## Description

<!-- Provide a brief description of your changes -->

## Type of Change

- [ ] New DAG contribution
- [ ] DAG update/fix
- [ ] Deployment script update
- [ ] Documentation update
- [ ] Other (please describe):

## DAG Information (if applicable)

**DAG Category:** <!-- ocp / infrastructure / networking / storage / security -->

**DAG Name:** <!-- e.g., ocp_initial_deployment -->

**Contributing Project:** <!-- e.g., ocp4-disconnected-helper -->

**Purpose:** <!-- Brief description of what this DAG automates -->

## Checklist

### Required for all PRs

- [ ] My code follows the standards in [CONTRIBUTING.md](../CONTRIBUTING.md)
- [ ] I have updated documentation where necessary
- [ ] I have added/updated comments in complex areas
- [ ] My changes don't break existing functionality

### Required for DAG contributions

- [ ] DAG follows naming convention (snake_case matching filename)
- [ ] DAG uses `"""` (triple double quotes) for bash_command, NOT `'''`
- [ ] DAG uses SSH pattern for host execution (ADR-0046)
- [ ] DAG uses ASCII-only output: `[OK]`, `[ERROR]`, `[WARN]`, `[INFO]`
- [ ] DAG includes category docstring
- [ ] I have validated the DAG syntax locally
- [ ] I have tested the DAG end-to-end
- [ ] I have updated `dags/registry.yaml`

### Validation Evidence

Please provide evidence that you have validated your DAG:

```bash
# Paste output from validation tools here

# Example:
# $ ./airflow/scripts/validate-dag.sh my_dag.py
# [OK] DAG syntax valid
# [OK] DAG standards compliant

# $ ./airflow/scripts/lint-dags.sh my_dag.py
# [OK] Linting passed
```

<!-- Paste validation output here -->

```

```

### Testing Evidence

Describe how you tested your changes:

- [ ] Tested locally with qubinode_navigator
- [ ] Verified create action works
- [ ] Verified delete action works
- [ ] Verified idempotency (can run multiple times safely)

**Test environment:**
- OS: <!-- e.g., RHEL 9, CentOS Stream 9 -->
- kcli version: <!-- if applicable -->
- Airflow version: <!-- e.g., 2.7.3 -->

**Test results:**
<!-- Describe your test results, include screenshots if applicable -->

## Related Issues

<!-- Link to related issues or discussions -->

Closes #
Related to #

## Related ADRs

<!-- List relevant ADRs from qubinode_navigator -->

- [ ] ADR-0045: DAG Standards
- [ ] ADR-0046: SSH Execution Pattern
- [ ] ADR-0047: Deployment Script Repository
- [ ] Other: <!-- List other relevant ADRs -->

## Breaking Changes

<!-- List any breaking changes and migration steps -->

- [ ] No breaking changes
- [ ] Breaking changes (describe below):

## Screenshots (if applicable)

<!-- Add screenshots to help explain your changes -->

## Additional Context

<!-- Add any other context about the pull request here -->

## Post-merge Actions

<!-- Actions to take after merging -->

- [ ] Update external project documentation
- [ ] Notify dependent projects
- [ ] Update qubinode_navigator if needed
- [ ] Other: <!-- Describe -->

---

**By submitting this pull request, I confirm that my contribution is made under the terms of the Apache 2.0 license.**
