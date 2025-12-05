#!/bin/bash
#
# sync-dags-to-qubinode.sh
# Synchronize DAGs from kcli-pipelines to qubinode_navigator
#
# ADR-0040: DAG Distribution Strategy from kcli-pipelines Repository
#
# Usage:
#   ./sync-dags-to-qubinode.sh [options]
#
# Options:
#   --source DIR      Source directory (default: auto-detect)
#   --target DIR      Target directory (default: auto-detect)
#   --validate        Validate DAGs before copying (default: true)
#   --backup          Backup existing DAGs before sync (default: true)
#   --dry-run         Show what would be done without making changes
#   --force           Overwrite local modifications without prompting
#   --help            Show this help message
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default settings
VALIDATE=true
BACKUP=true
DRY_RUN=false
FORCE=false
SOURCE_DIR=""
TARGET_DIR=""

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KCLI_PIPELINES_DIR="$(dirname "$SCRIPT_DIR")"

# Print functions
print_header() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

# Show help
show_help() {
    cat << EOF
sync-dags-to-qubinode.sh - Synchronize DAGs from kcli-pipelines to qubinode_navigator

USAGE:
    ./sync-dags-to-qubinode.sh [OPTIONS]

OPTIONS:
    --source DIR      Source directory containing DAGs
                      Default: <kcli-pipelines>/dags or /opt/qubinode-pipelines/dags
    
    --target DIR      Target Airflow DAGs directory
                      Default: Auto-detect from qubinode_navigator
    
    --validate        Validate DAG Python syntax before copying
                      Default: true
    
    --no-validate     Skip DAG validation
    
    --backup          Create backup of existing DAGs before overwriting
                      Default: true
    
    --no-backup       Skip backup creation
    
    --dry-run         Show what would be done without making changes
    
    --force           Overwrite local modifications without prompting
    
    --help            Show this help message

EXAMPLES:
    # Basic sync with defaults
    ./sync-dags-to-qubinode.sh
    
    # Dry run to see what would happen
    ./sync-dags-to-qubinode.sh --dry-run
    
    # Sync without validation (not recommended)
    ./sync-dags-to-qubinode.sh --no-validate
    
    # Custom source and target
    ./sync-dags-to-qubinode.sh --source /path/to/dags --target /opt/airflow/dags

ENVIRONMENT VARIABLES:
    KCLI_PIPELINES_DIR    Path to kcli-pipelines repository
    QUBINODE_DAGS_DIR     Path to qubinode_navigator DAGs directory

EOF
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --source)
                SOURCE_DIR="$2"
                shift 2
                ;;
            --target)
                TARGET_DIR="$2"
                shift 2
                ;;
            --validate)
                VALIDATE=true
                shift
                ;;
            --no-validate)
                VALIDATE=false
                shift
                ;;
            --backup)
                BACKUP=true
                shift
                ;;
            --no-backup)
                BACKUP=false
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Auto-detect source directory
detect_source_dir() {
    if [ -n "$SOURCE_DIR" ]; then
        return
    fi
    
    # Try environment variable
    if [ -n "$KCLI_PIPELINES_DIR" ] && [ -d "$KCLI_PIPELINES_DIR/dags" ]; then
        SOURCE_DIR="$KCLI_PIPELINES_DIR/dags"
        return
    fi
    
    # Try script location
    if [ -d "$KCLI_PIPELINES_DIR/dags" ]; then
        SOURCE_DIR="$KCLI_PIPELINES_DIR/dags"
        return
    fi
    
    # Try common locations
    for dir in /opt/qubinode-pipelines/dags /root/kcli-pipelines/dags ~/kcli-pipelines/dags; do
        if [ -d "$dir" ]; then
            SOURCE_DIR="$dir"
            return
        fi
    done
    
    print_error "Could not find source DAGs directory"
    print_info "Please specify with --source or set KCLI_PIPELINES_DIR"
    exit 1
}

# Auto-detect target directory
detect_target_dir() {
    if [ -n "$TARGET_DIR" ]; then
        return
    fi
    
    # Try environment variable
    if [ -n "$QUBINODE_DAGS_DIR" ] && [ -d "$QUBINODE_DAGS_DIR" ]; then
        TARGET_DIR="$QUBINODE_DAGS_DIR"
        return
    fi
    
    # Try common locations
    for dir in /root/qubinode_navigator/airflow/dags /opt/qubinode_navigator/airflow/dags ~/qubinode_navigator/airflow/dags; do
        if [ -d "$dir" ]; then
            TARGET_DIR="$dir"
            return
        fi
    done
    
    print_error "Could not find target DAGs directory"
    print_info "Please specify with --target or set QUBINODE_DAGS_DIR"
    exit 1
}

# Validate a DAG file
validate_dag() {
    local dag_file="$1"
    local filename=$(basename "$dag_file")
    
    # Skip non-Python files
    if [[ ! "$filename" == *.py ]]; then
        return 0
    fi
    
    # Skip __init__.py and similar
    if [[ "$filename" == __* ]]; then
        return 0
    fi
    
    # Python syntax check
    if ! python3 -m py_compile "$dag_file" 2>/dev/null; then
        print_error "Syntax error in $filename"
        return 1
    fi
    
    # Check for DAG definition
    if ! grep -q "DAG\|dag" "$dag_file"; then
        print_warning "$filename may not contain a DAG definition"
    fi
    
    return 0
}

# Create backup of existing DAGs
create_backup() {
    local target_dir="$1"
    local backup_dir="${target_dir}.backup.$(date +%Y%m%d-%H%M%S)"
    
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would create backup at: $backup_dir"
        return 0
    fi
    
    mkdir -p "$backup_dir"
    
    # Copy existing DAGs to backup
    local count=0
    for dag in "$target_dir"/*.py; do
        if [ -f "$dag" ]; then
            cp "$dag" "$backup_dir/"
            ((count++))
        fi
    done
    
    if [ $count -gt 0 ]; then
        print_success "Backed up $count DAG(s) to $backup_dir"
    fi
}

# Sync DAGs
sync_dags() {
    local source_dir="$1"
    local target_dir="$2"
    
    local synced=0
    local skipped=0
    local failed=0
    
    for dag in "$source_dir"/*.py; do
        if [ ! -f "$dag" ]; then
            continue
        fi
        
        local filename=$(basename "$dag")
        local target_file="$target_dir/$filename"
        
        # Skip __init__.py and similar
        if [[ "$filename" == __* ]]; then
            continue
        fi
        
        # Skip non-DAG files
        if [[ "$filename" == *_test.py ]] || [[ "$filename" == test_* ]]; then
            continue
        fi
        
        echo -n "Processing $filename... "
        
        # Validate if enabled
        if [ "$VALIDATE" = true ]; then
            if ! validate_dag "$dag"; then
                print_error "Validation failed, skipping"
                ((failed++))
                continue
            fi
        fi
        
        # Check for local modifications
        if [ -f "$target_file" ] && [ "$FORCE" = false ]; then
            if ! diff -q "$dag" "$target_file" >/dev/null 2>&1; then
                # Files differ
                local source_hash=$(md5sum "$dag" | awk '{print $1}')
                local target_hash=$(md5sum "$target_file" | awk '{print $1}')
                
                if [ "$source_hash" != "$target_hash" ]; then
                    if [ "$DRY_RUN" = true ]; then
                        print_warning "[DRY-RUN] Would overwrite modified file"
                    else
                        print_warning "File differs from source"
                    fi
                fi
            fi
        fi
        
        # Copy file
        if [ "$DRY_RUN" = true ]; then
            print_info "[DRY-RUN] Would copy to $target_file"
            ((synced++))
        else
            if cp "$dag" "$target_file"; then
                print_success "Synced"
                ((synced++))
            else
                print_error "Copy failed"
                ((failed++))
            fi
        fi
    done
    
    echo ""
    print_header "Sync Summary"
    echo "  Synced:  $synced"
    echo "  Skipped: $skipped"
    echo "  Failed:  $failed"
    
    if [ $failed -gt 0 ]; then
        return 1
    fi
    return 0
}

# Main function
main() {
    parse_args "$@"
    
    print_header "DAG Sync: kcli-pipelines → qubinode_navigator"
    
    # Detect directories
    detect_source_dir
    detect_target_dir
    
    echo ""
    echo "Configuration:"
    echo "  Source:   $SOURCE_DIR"
    echo "  Target:   $TARGET_DIR"
    echo "  Validate: $VALIDATE"
    echo "  Backup:   $BACKUP"
    echo "  Dry-run:  $DRY_RUN"
    echo "  Force:    $FORCE"
    
    # Verify directories exist
    if [ ! -d "$SOURCE_DIR" ]; then
        print_error "Source directory does not exist: $SOURCE_DIR"
        exit 1
    fi
    
    if [ ! -d "$TARGET_DIR" ]; then
        print_error "Target directory does not exist: $TARGET_DIR"
        print_info "Create it with: mkdir -p $TARGET_DIR"
        exit 1
    fi
    
    # Count source DAGs
    dag_count=$(find "$SOURCE_DIR" -maxdepth 1 -name "*.py" ! -name "__*" | wc -l)
    
    if [ "$dag_count" -eq 0 ]; then
        print_warning "No DAG files found in $SOURCE_DIR"
        exit 0
    fi
    
    print_info "Found $dag_count DAG file(s) to sync"
    
    # Create backup if enabled
    if [ "$BACKUP" = true ]; then
        print_header "Creating Backup"
        create_backup "$TARGET_DIR"
    fi
    
    # Sync DAGs
    print_header "Syncing DAGs"
    sync_dags "$SOURCE_DIR" "$TARGET_DIR"
    
    # Final message
    echo ""
    if [ "$DRY_RUN" = true ]; then
        print_info "Dry-run complete. No changes were made."
        print_info "Run without --dry-run to apply changes."
    else
        print_success "DAG sync complete!"
        print_info "Airflow will automatically detect new/modified DAGs."
        print_info "Check Airflow UI to verify DAGs are loaded."
    fi
}

# Run main
main "$@"
