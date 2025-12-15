# Pre-commit Hooks Setup Guide

This repository includes pre-commit hooks to ensure code quality and security before commits.

## Features

- **DAG Validation**: Validates Airflow DAGs for syntax and import errors
- **Secret Detection**: Uses gitleaks to detect accidentally committed secrets
- **Code Quality**: Python linting, YAML validation, and file formatting
- **Security**: Detects private keys and other sensitive files

## Installation

### Option 1: Full Installation (Recommended)

```bash
# Install pre-commit
pip install pre-commit

# Install gitleaks (if not already installed)
# On RHEL/CentOS:
sudo dnf install -y gitleaks
# Or download from: https://github.com/gitleaks/gitleaks/releases

# Install the hooks
cd /home/vpcuser/qubinode-pipelines
pre-commit install

# Install hooks for all environments
pre-commit install --hook-type pre-commit --hook-type pre-push
```

### Option 2: Simple Installation (Local Hooks Only)

If you prefer not to install external dependencies, use the simplified config:

```bash
# Copy the simple config
cp .pre-commit-config-simple.yaml .pre-commit-config.yaml

# Install pre-commit
pip install pre-commit

# Install hooks
pre-commit install
```

## Usage

### Automatic (on commit)

Hooks run automatically when you commit:

```bash
git add dags/infrastructure/jfrog_deployment.py
git commit -m "Update JFrog deployment"
# Pre-commit hooks will run automatically
```

### Manual

Run hooks manually on all files:

```bash
# Run all hooks
pre-commit run --all-files

# Run specific hook
pre-commit run airflow-dag-validation --all-files
pre-commit run gitleaks --all-files

# Run on staged files only
pre-commit run
```

### Validate DAGs Only

```bash
# Use the standalone script
./scripts/validate-dags.sh

# With verbose output
./scripts/validate-dags.sh --verbose
```

## Hooks Included

### 1. Airflow DAG Validation

- **Hook ID**: `airflow-dag-validation`
- **Purpose**: Validates all Airflow DAGs for syntax errors and import issues
- **Runs on**: `dags/**/*.py`
- **Requires**: Airflow installed (`pip install apache-airflow`)

### 2. Gitleaks (Secret Detection)

- **Hook ID**: `gitleaks`
- **Purpose**: Detects secrets, API keys, passwords, and other sensitive data
- **Runs on**: All files
- **Requires**: gitleaks binary installed
- **Config**: `.gitleaksignore` for false positives

### 3. Python Code Quality

- **Black**: Code formatter
- **Flake8**: Linter
- **Runs on**: `dags/**/*.py`

### 4. File Checks

- Trailing whitespace removal
- End of file fixes
- YAML/JSON validation
- Large file detection
- Merge conflict detection
- Private key detection

## Configuration

### Ignoring Files

Add patterns to `.gitleaksignore` to exclude false positives:

```bash
# Example: Ignore example files
^examples/.*\.env$
^.*\.example$
```

### Skipping Hooks

Skip hooks for a specific commit:

```bash
git commit --no-verify -m "Emergency fix"
```

**Warning**: Only skip hooks when absolutely necessary!

## Troubleshooting

### Airflow Not Found

```bash
# Install Airflow
pip install apache-airflow

# Or use the standalone validation script
./scripts/validate-dags.sh
```

### Gitleaks Not Found

```bash
# Install gitleaks
# RHEL/CentOS:
sudo dnf install -y gitleaks

# Or download binary:
wget https://github.com/gitleaks/gitleaks/releases/download/v8.18.0/gitleaks_8.18.0_linux_x64.tar.gz
tar -xzf gitleaks_8.18.0_linux_x64.tar.gz
sudo mv gitleaks /usr/local/bin/
```

### Hook Failures

Update hooks to latest versions:

```bash
pre-commit autoupdate
```

## CI/CD Integration

These hooks can also be used in CI/CD pipelines:

```yaml
# Example GitHub Actions
- name: Run pre-commit
  uses: pre-commit/action@v3.0.0
```

## Best Practices

1. **Always run hooks before pushing**: `pre-commit run --all-files`
2. **Fix issues locally**: Don't skip hooks unless absolutely necessary
3. **Update hooks regularly**: `pre-commit autoupdate`
4. **Review gitleaks findings**: Some may be false positives, add to `.gitleaksignore`

## Related Files

- `.pre-commit-config.yaml`: Main configuration
- `.pre-commit-config-simple.yaml`: Simplified version (local hooks only)
- `.gitleaksignore`: Patterns to ignore for gitleaks
- `scripts/validate-dags.sh`: Standalone DAG validation script

