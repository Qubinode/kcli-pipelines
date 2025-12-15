#!/bin/bash
# Airflow DAG Validation Script
# Validates all DAGs in the dags/ directory
# Usage: ./scripts/validate-dags.sh [--verbose]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERBOSE="${1:-}"

cd "$REPO_ROOT"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "Airflow DAG Validation"
echo "=========================================="
echo ""

# Check if Airflow is available
if ! command -v airflow &>/dev/null; then
    echo -e "${YELLOW}Warning: airflow CLI not found${NC}"
    echo "Attempting Python-based validation..."
    
    # Try Python-based validation
    if python3 -c "from airflow.models import DagBag" 2>/dev/null; then
        echo "Using Python Airflow API for validation..."
        python3 <<'PYTHON_EOF'
import sys
from pathlib import Path

try:
    from airflow.models import DagBag
    
    # Get DAG directory
    dag_dir = Path(__file__).parent / "dags"
    if not dag_dir.exists():
        print(f"ERROR: DAG directory not found: {dag_dir}")
        sys.exit(1)
    
    # Load DAGs
    dag_bag = DagBag(dag_folder=str(dag_dir), include_examples=False)
    
    # Check for import errors
    if dag_bag.import_errors:
        print("ERROR: DAG import errors found:")
        for filename, error in dag_bag.import_errors.items():
            print(f"  {filename}: {error}")
        sys.exit(1)
    
    # Check for DAGs
    if not dag_bag.dags:
        print("WARNING: No DAGs found in dags/ directory")
        sys.exit(0)
    
    # Report
    print(f"✅ Found {len(dag_bag.dags)} DAG(s)")
    for dag_id in sorted(dag_bag.dags.keys()):
        dag = dag_bag.dags[dag_id]
        print(f"  - {dag_id} ({len(dag.tasks)} tasks)")
    
    print("\n✅ All DAGs validated successfully!")
    sys.exit(0)
    
except ImportError as e:
    print(f"ERROR: Cannot import Airflow: {e}")
    print("Install with: pip install apache-airflow")
    sys.exit(1)
except Exception as e:
    print(f"ERROR: Validation failed: {e}")
    sys.exit(1)
PYTHON_EOF
        exit_code=$?
    else
        echo -e "${YELLOW}Warning: Cannot validate DAGs - Airflow not available${NC}"
        echo "Install Airflow: pip install apache-airflow"
        echo "Skipping validation (non-blocking)"
        exit 0  # Don't fail if Airflow is not available
    fi
else
    # Use Airflow CLI
    echo "Using Airflow CLI for validation..."
    
    # Set AIRFLOW_HOME to a temporary directory to avoid conflicts
    export AIRFLOW_HOME="/tmp/airflow-validation-$$"
    mkdir -p "$AIRFLOW_HOME"
    
    # Validate DAGs
    if [ "$VERBOSE" = "--verbose" ]; then
        airflow dags list-import-errors --subdir dags/ 2>&1
    else
        airflow dags list-import-errors --subdir dags/ 2>&1 | head -50
    fi
    
    # Check exit code
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ All DAGs validated successfully!${NC}"
        
        # List DAGs
        echo ""
        echo "Found DAGs:"
        airflow dags list --subdir dags/ 2>&1 | grep -v "^=" | grep -v "^dag_id" | awk '{print "  - " $1}'
    else
        echo -e "${RED}❌ DAG validation failed${NC}"
        exit 1
    fi
    
    # Cleanup
    rm -rf "$AIRFLOW_HOME"
fi

echo ""
echo "=========================================="

