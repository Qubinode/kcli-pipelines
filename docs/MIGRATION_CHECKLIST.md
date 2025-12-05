# Migration Checklist: kcli-pipelines to qubinode-pipelines

This document provides a step-by-step checklist for migrating from kcli-pipelines to qubinode-pipelines.

## Overview

The repository has been restructured with:
- New three-tier architecture
- Organized DAG categories
- Structured scripts directory
- Comprehensive documentation
- CI/CD validation
- Updated path references

## For System Administrators

### Pre-Migration Checklist

- [ ] Review [README.md](../README.md) to understand new architecture
- [ ] Review [BACKWARD_COMPATIBILITY.md](BACKWARD_COMPATIBILITY.md) for migration options
- [ ] Backup current configuration and custom DAGs
- [ ] Note any custom modifications to deployment scripts
- [ ] Document current mount points in docker-compose.yml

### Migration Steps

#### Option A: Symlink Approach (Recommended)

- [ ] **Step 1**: Clone new repository
  ```bash
  cd /opt
  git clone https://github.com/Qubinode/qubinode-pipelines.git
  ```

- [ ] **Step 2**: Create backward compatibility symlink
  ```bash
  ln -s /opt/qubinode-pipelines /opt/kcli-pipelines
  ls -la /opt/kcli-pipelines  # Verify symlink
  ```

- [ ] **Step 3**: Update docker-compose.yml
  ```yaml
  volumes:
    # New primary path
    - /opt/qubinode-pipelines:/opt/qubinode-pipelines:ro
    # Old path via symlink (backward compatibility)
    - /opt/kcli-pipelines:/opt/kcli-pipelines:ro
  ```

- [ ] **Step 4**: Restart Airflow
  ```bash
  cd /path/to/qubinode_navigator
  docker compose down
  docker compose up -d
  ```

- [ ] **Step 5**: Verify DAGs are visible
  - Open Airflow UI: http://localhost:8080
  - Check that all DAGs appear in the list
  - DAGs should be organized in categories

- [ ] **Step 6**: Test a sample DAG
  - Trigger `freeipa_deployment` with action=status
  - Verify it completes successfully
  - Check logs for any path-related errors

#### Option B: Direct Migration

- [ ] **Step 1**: Backup old repository
  ```bash
  cd /opt
  mv kcli-pipelines kcli-pipelines.backup.$(date +%Y%m%d)
  ```

- [ ] **Step 2**: Clone new repository
  ```bash
  git clone https://github.com/Qubinode/qubinode-pipelines.git
  ```

- [ ] **Step 3**: Update docker-compose.yml
  ```yaml
  volumes:
    # Only new path
    - /opt/qubinode-pipelines:/opt/qubinode-pipelines:ro
  ```

- [ ] **Step 4**: Update custom DAGs (if any)
  ```bash
  # Find and update path references
  find /opt/qubinode_navigator -name "*.py" -type f \
    -exec sed -i 's|/opt/kcli-pipelines|/opt/qubinode-pipelines|g' {} \;
  ```

- [ ] **Step 5**: Restart Airflow
  ```bash
  cd /path/to/qubinode_navigator
  docker compose down
  docker compose up -d
  ```

- [ ] **Step 6**: Verify and test
  - Check Airflow UI
  - Test DAGs
  - Verify scripts work

### Post-Migration Verification

- [ ] All expected DAGs are visible in Airflow UI
- [ ] DAGs are organized into categories (infrastructure, ocp, etc.)
- [ ] Can trigger and run DAGs successfully
- [ ] Deployment scripts execute without path errors
- [ ] Logs show correct paths: `/opt/qubinode-pipelines`
- [ ] Custom integrations (if any) still work

### Troubleshooting

If you encounter issues:

- [ ] Check symlink: `ls -la /opt/kcli-pipelines`
- [ ] Verify mounts: `docker exec airflow-webserver ls -la /opt/`
- [ ] Check Airflow logs: `docker logs airflow-webserver`
- [ ] Review [BACKWARD_COMPATIBILITY.md](BACKWARD_COMPATIBILITY.md)
- [ ] Open issue: https://github.com/Qubinode/qubinode-pipelines/issues

## For Contributors / External Projects

### For Project Maintainers

- [ ] Review [CONTRIBUTING.md](../CONTRIBUTING.md)
- [ ] Update project documentation to reference `qubinode-pipelines`
- [ ] Update installation instructions
- [ ] Update any scripts that reference `kcli-pipelines`
- [ ] Test DAG contributions with new structure

### DAG Contribution Checklist

- [ ] DAG follows new directory structure (dags/category/)
- [ ] DAG uses `/opt/qubinode-pipelines` paths
- [ ] DAG follows standards (triple double quotes, SSH pattern, ASCII output)
- [ ] Updated `dags/registry.yaml` with DAG entry
- [ ] Validated with qubinode_navigator tools
- [ ] Tested end-to-end
- [ ] Created PR with evidence

### Example: Updating ocp4-disconnected-helper

- [ ] **Step 1**: Update documentation
  ```markdown
  # Before
  Clone kcli-pipelines to /opt/kcli-pipelines
  
  # After
  Clone qubinode-pipelines to /opt/qubinode-pipelines
  ```

- [ ] **Step 2**: Update scripts
  ```bash
  # Find references
  grep -r "kcli-pipelines" .
  
  # Update paths
  find . -type f \( -name "*.sh" -o -name "*.py" \) \
    -exec sed -i 's|kcli-pipelines|qubinode-pipelines|g' {} \;
  ```

- [ ] **Step 3**: Update DAGs to contribute
  - Move DAG to appropriate category (e.g., `dags/ocp/`)
  - Update paths to `/opt/qubinode-pipelines`
  - Add entry to `dags/registry.yaml`

- [ ] **Step 4**: Test
  - Clone qubinode-pipelines locally
  - Test DAG with qubinode_navigator
  - Verify create/delete/status actions

- [ ] **Step 5**: Submit PR
  - Use PR template
  - Include validation evidence
  - Link to related issues

## For CI/CD Pipeline Maintainers

- [ ] Update pipeline references from kcli-pipelines to qubinode-pipelines
- [ ] Update clone URLs
- [ ] Update mount paths in CI configuration
- [ ] Test pipeline with new paths
- [ ] Update pipeline documentation

## Timeline

| Phase | Duration | Status |
|-------|----------|--------|
| **Phase 1**: Repository restructure | Complete | ✅ Done |
| **Phase 2**: Documentation | Complete | ✅ Done |
| **Phase 3**: CI/CD validation | Complete | ✅ Done |
| **Phase 4**: User migration (symlink) | 3 months | 🔨 Current |
| **Phase 5**: External project updates | 6 months | 📋 Planned |
| **Phase 6**: Deprecate old paths | 12 months | 📋 Planned |

## Success Criteria

Migration is successful when:

- [x] Repository restructured with new directory layout
- [x] All DAGs moved to categorized directories
- [x] All scripts organized in scripts/ directory
- [x] Documentation complete (README, CONTRIBUTING, etc.)
- [x] CI/CD validation workflow working
- [x] Path references updated
- [ ] Users successfully migrated (symlink or direct)
- [ ] External projects updated (ocp4-disconnected-helper, etc.)
- [ ] No critical issues reported
- [ ] DAG contributions flowing via PR process

## Support

Need help with migration?

1. **Read documentation**: Start with [README.md](../README.md) and [BACKWARD_COMPATIBILITY.md](BACKWARD_COMPATIBILITY.md)
2. **Check examples**: Look at existing DAGs in `dags/infrastructure/`
3. **Ask questions**: Open a discussion on GitHub
4. **Report issues**: Create an issue with details

## References

- [README.md](../README.md) - New architecture overview
- [CONTRIBUTING.md](../CONTRIBUTING.md) - Contribution guidelines
- [BACKWARD_COMPATIBILITY.md](BACKWARD_COMPATIBILITY.md) - Detailed migration guide
- [dags/registry.yaml](../dags/registry.yaml) - DAG registry
- [dags/TEMPLATE.py](../dags/TEMPLATE.py) - DAG template
- [.github/PULL_REQUEST_TEMPLATE.md](../.github/PULL_REQUEST_TEMPLATE.md) - PR template

## Feedback

We value your feedback! Please:

- Report issues: https://github.com/Qubinode/qubinode-pipelines/issues
- Suggest improvements: https://github.com/Qubinode/qubinode-pipelines/discussions
- Contribute: See [CONTRIBUTING.md](../CONTRIBUTING.md)
