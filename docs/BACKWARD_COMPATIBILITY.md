# Backward Compatibility Guide

This document describes how to maintain backward compatibility during the migration from `kcli-pipelines` to `qubinode-pipelines`.

## Overview

The repository has been renamed from `kcli-pipelines` to `qubinode-pipelines` to clarify its role in the three-tier architecture. This change affects:

1. Mount point: `/opt/kcli-pipelines` → `/opt/qubinode-pipelines`
2. Path references in DAGs and scripts
3. External projects that depend on this repository

## Migration Strategy

### For New Installations

Use the new repository name and mount point:

```bash
# Clone repository
git clone https://github.com/Qubinode/qubinode-pipelines.git /opt/qubinode-pipelines

# Mount in qubinode_navigator docker-compose.yml
volumes:
  - /opt/qubinode-pipelines:/opt/qubinode-pipelines:ro
```

### For Existing Installations

You have two options for existing installations:

#### Option 1: Symlink (Recommended for Gradual Migration)

Create a symlink from the old path to the new path. This allows existing DAGs and scripts to continue working while you migrate:

```bash
# On the host machine
cd /opt

# Clone new repository
git clone https://github.com/Qubinode/qubinode-pipelines.git

# Create symlink for backward compatibility
ln -s /opt/qubinode-pipelines /opt/kcli-pipelines

# Verify symlink
ls -la /opt/kcli-pipelines
# Should show: /opt/kcli-pipelines -> /opt/qubinode-pipelines
```

Update docker-compose.yml to mount both paths:

```yaml
volumes:
  # New path (primary)
  - /opt/qubinode-pipelines:/opt/qubinode-pipelines:ro
  # Old path (for backward compatibility via symlink)
  - /opt/kcli-pipelines:/opt/kcli-pipelines:ro
```

**Benefits:**
- Existing DAGs continue to work
- Gradual migration path
- No immediate changes required
- Time to update external projects

**Timeline:**
- Keep symlink for 2-3 release cycles
- Announce deprecation
- Remove in future version

#### Option 2: Direct Migration (Clean Break)

Remove the old repository and use only the new one:

```bash
# On the host machine
cd /opt

# Backup old repository (optional)
mv kcli-pipelines kcli-pipelines.backup

# Clone new repository
git clone https://github.com/Qubinode/qubinode-pipelines.git

# Update docker-compose.yml
# Change: /opt/kcli-pipelines -> /opt/qubinode-pipelines
```

Update all custom DAGs and scripts to use new paths:

```bash
# Find and replace in your custom DAGs
find /opt/qubinode_navigator -name "*.py" -type f -exec sed -i 's|/opt/kcli-pipelines|/opt/qubinode-pipelines|g' {} \;
```

**Benefits:**
- Clean, single source of truth
- No ambiguity
- Simpler configuration

**Requirements:**
- Update all references immediately
- May break external projects temporarily
- Requires coordinated update

## Path Migration Examples

### In DAGs

**Before (old path):**
```python
bash_command="""
cd /opt/kcli-pipelines/vyos-router && ./deploy.sh
"""
```

**After (new path):**
```python
bash_command="""
cd /opt/qubinode-pipelines/scripts/vyos-router && ./deploy.sh
"""
```

### In Shell Scripts

**Before (old path):**
```bash
if [ -f /opt/kcli-pipelines/helper_scripts/default.env ]; then
    source /opt/kcli-pipelines/helper_scripts/default.env
fi
```

**After (new path):**
```bash
if [ -f /opt/qubinode-pipelines/scripts/helper_scripts/default.env ]; then
    source /opt/qubinode-pipelines/scripts/helper_scripts/default.env
fi
```

### In Environment Files

**Before (old path):**
```bash
KCLI_PIPELINES_DIR="/opt/kcli-pipelines"
HELPER_SCRIPTS="/opt/kcli-pipelines/helper_scripts"
```

**After (new path):**
```bash
QUBINODE_PIPELINES_DIR="/opt/qubinode-pipelines"
HELPER_SCRIPTS="/opt/qubinode-pipelines/scripts/helper_scripts"
```

## Docker Compose Configuration

### Option 1: Symlink Approach

```yaml
version: '3.8'
services:
  airflow-webserver:
    volumes:
      # Primary mount point
      - /opt/qubinode-pipelines:/opt/qubinode-pipelines:ro
      # Backward compatibility via symlink
      - /opt/kcli-pipelines:/opt/kcli-pipelines:ro
```

### Option 2: Direct Migration

```yaml
version: '3.8'
services:
  airflow-webserver:
    volumes:
      # Only new mount point
      - /opt/qubinode-pipelines:/opt/qubinode-pipelines:ro
```

## External Project Migration

External projects (e.g., ocp4-disconnected-helper) should update their references:

### 1. Update Documentation

```markdown
# Before
Clone kcli-pipelines to /opt/kcli-pipelines

# After
Clone qubinode-pipelines to /opt/qubinode-pipelines
```

### 2. Update Scripts

```bash
# Find all references
grep -r "kcli-pipelines" .

# Update to new path
find . -type f -name "*.sh" -exec sed -i 's|kcli-pipelines|qubinode-pipelines|g' {} \;
find . -type f -name "*.py" -exec sed -i 's|kcli-pipelines|qubinode-pipelines|g' {} \;
```

### 3. Update DAGs

Submit updated DAGs to qubinode-pipelines via PR (see CONTRIBUTING.md).

## Testing Migration

### Verify Symlink

```bash
# Check symlink exists
ls -la /opt/kcli-pipelines

# Should output:
# /opt/kcli-pipelines -> /opt/qubinode-pipelines

# Verify access through both paths
ls /opt/kcli-pipelines/scripts/
ls /opt/qubinode-pipelines/scripts/

# Both should show same content
```

### Verify DAG Functionality

```bash
# Test old path (via symlink)
ssh root@localhost "cd /opt/kcli-pipelines/scripts/vyos-router && ls deploy.sh"

# Test new path (direct)
ssh root@localhost "cd /opt/qubinode-pipelines/scripts/vyos-router && ls deploy.sh"

# Both should succeed
```

### Verify Airflow

1. Open Airflow UI: http://localhost:8080
2. Check that all DAGs are visible
3. Trigger a test DAG
4. Verify it completes successfully

## Common Issues

### Issue: DAG not found after migration

**Symptom:**
```
FileNotFoundError: /opt/kcli-pipelines/scripts/component/deploy.sh not found
```

**Solution:**
- Verify symlink exists: `ls -la /opt/kcli-pipelines`
- Check docker-compose.yml has correct volume mounts
- Restart Airflow: `docker compose restart`

### Issue: Script fails with permission denied

**Symptom:**
```
bash: /opt/qubinode-pipelines/scripts/deploy.sh: Permission denied
```

**Solution:**
```bash
# Fix script permissions
chmod +x /opt/qubinode-pipelines/scripts/*/deploy.sh
chmod +x /opt/qubinode-pipelines/scripts/*/*/*.sh
```

### Issue: Environment variables not loaded

**Symptom:**
```
HELPER_SCRIPTS: unbound variable
```

**Solution:**
Update script to source from new location:
```bash
source /opt/qubinode-pipelines/scripts/helper_scripts/default.env
```

## Deprecation Timeline

| Phase | Timeline | Action |
|-------|----------|--------|
| **Phase 1** | Current | Both paths supported via symlink |
| **Phase 2** | +3 months | Deprecation warnings in logs |
| **Phase 3** | +6 months | Documentation updated to show new path only |
| **Phase 4** | +12 months | Remove backward compatibility (symlink optional) |

## Support

If you encounter issues during migration:

1. **Check this guide**: Common issues are documented above
2. **Search existing issues**: [GitHub Issues](https://github.com/Qubinode/qubinode-pipelines/issues)
3. **Ask for help**: Open a new issue with:
   - Your migration approach (symlink or direct)
   - Error messages
   - Steps to reproduce
   - Environment details

## Related Documentation

- [README.md](../README.md) - New architecture overview
- [CONTRIBUTING.md](../CONTRIBUTING.md) - Contribution guidelines
- [ADR-0061: Multi-Repository Architecture](https://github.com/Qubinode/qubinode_navigator/blob/main/docs/adrs/adr-0061-multi-repository-architecture.md)
