#!/bin/bash

# ZFS Backup Script for Proxmox 8 / Debian 12
# Automatic incremental backups to rotating external drives
# Version: 1.0
# Author: Generated for Proxmox ZFS backup system

# Exit on any error
set -e

# Global variables
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CONFIG_FILE="/etc/zfs-backup-script.conf"
LOCK_FILE="/var/run/zfs_backup.lock"
LOG_FILE="/var/log/zfs-backup.log"
CHECKMK_DIR="/var/spool/check_mk_agent/piggyback"
VERBOSE=false
TEST_MODE=false

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level="$1"
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo -e "${timestamp} [${level}] ${message}" | tee -a "${LOG_FILE}"
    
    if [[ "$VERBOSE" == true ]]; then
        case "$level" in
            "INFO")  echo -e "${GREEN}[INFO]${NC} $message" ;;
            "WARN")  echo -e "${YELLOW}[WARN]${NC} $message" ;;
            "ERROR") echo -e "${RED}[ERROR]${NC} $message" ;;
            "DEBUG") echo -e "${BLUE}[DEBUG]${NC} $message" ;;
        esac
    fi
}

# Error handler
error_exit() {
    log "ERROR" "$1"
    cleanup
    exit 1
}

# Cleanup function
cleanup() {
    # Remove lock file
    if [[ -f "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE"
        log "INFO" "Lock file removed"
    fi
    
    # Export pool if imported during script run
    if [[ -n "$BACKUP_POOL_NAME" ]] && zpool list "$BACKUP_POOL_NAME" >/dev/null 2>&1; then
        log "INFO" "Exporting backup pool: $BACKUP_POOL_NAME"
        zpool export "$BACKUP_POOL_NAME" || log "WARN" "Failed to export pool $BACKUP_POOL_NAME"
    fi
}

# Signal handlers
trap cleanup EXIT
trap 'error_exit "Script interrupted by user"' INT TERM

# Parse command line arguments
parse_arguments() {
    while getopts "vth" opt; do
        case $opt in
            v) VERBOSE=true ;;
            t) TEST_MODE=true ;;
            h) show_help; exit 0 ;;
            *) error_exit "Invalid option. Use -h for help." ;;
        esac
    done
}

# Show help
show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

ZFS Backup Script for automatic incremental backups to rotating external drives

OPTIONS:
    -v    Verbose mode - detailed logging and output
    -t    Test mode - check configuration and readiness without performing backup
    -h    Show this help message

CONFIGURATION:
    Configuration file: $CONFIG_FILE

EXAMPLES:
    $SCRIPT_NAME           # Run backup normally
    $SCRIPT_NAME -v        # Run with verbose output
    $SCRIPT_NAME -t        # Test mode - check if backup is possible
    $SCRIPT_NAME -vt       # Test mode with verbose output

EOF
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root"
    fi
}

# Create lock file
create_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "unknown")
        error_exit "Another instance is already running (PID: $pid). Lock file: $LOCK_FILE"
    fi
    
    echo $$ > "$LOCK_FILE"
    log "INFO" "Lock file created: $LOCK_FILE"
}

# Load configuration
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error_exit "Configuration file not found: $CONFIG_FILE"
    fi
    
    source "$CONFIG_FILE"
    
    # Validate required variables
    local required_vars=(
        "SOURCE_POOL"
        "BACKUP_POOL_NAME"
        "ALLOWED_DISK_IDS"
        "DATASETS"
        "MIN_FREE_SPACE_GB"
        "SNAPSHOT_RETENTION_DAYS"
        "CHECKMK_HOST"
    )
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            error_exit "Required configuration variable '$var' is not set in $CONFIG_FILE"
        fi
    done
    
    # Convert comma-separated values to arrays
    IFS=',' read -ra DATASETS_ARRAY <<< "$DATASETS"
    IFS=',' read -ra ALLOWED_DISK_IDS_ARRAY <<< "$ALLOWED_DISK_IDS"
    
    log "INFO" "Configuration loaded successfully"
}

# Check ZFS prerequisites
check_zfs_prerequisites() {
    # Check if ZFS module is loaded
    if ! lsmod | grep -q zfs; then
        error_exit "ZFS module is not loaded"
    fi
    
    # Check if source pool exists
    if ! zpool list "$SOURCE_POOL" >/dev/null 2>&1; then
        error_exit "Source pool '$SOURCE_POOL' not found"
    fi
    
    # Check if datasets exist
    for dataset in "${DATASETS_ARRAY[@]}"; do
        dataset=$(echo "$dataset" | xargs) # Trim whitespace
        if ! zfs list "$SOURCE_POOL/$dataset" >/dev/null 2>&1; then
            error_exit "Dataset '$SOURCE_POOL/$dataset' not found"
        fi
    done
    
    log "INFO" "ZFS prerequisites check passed"
}

# Identify and import backup disk
import_backup_disk() {
    log "INFO" "Searching for backup disk..."
    
    # Get list of available disks
    local found_disk=""
    
    for disk_id in "${ALLOWED_DISK_IDS_ARRAY[@]}"; do
        disk_id=$(echo "$disk_id" | xargs) # Trim whitespace
        
        # Search for disk by WWN or serial number
        for disk_path in /dev/disk/by-id/*; do
            if [[ "$disk_path" == *"$disk_id"* ]]; then
                found_disk="$disk_path"
                log "INFO" "Found backup disk: $found_disk (ID: $disk_id)"
                break 2
            fi
        done
    done
    
    if [[ -z "$found_disk" ]]; then
        error_exit "No allowed backup disk found. Expected one of: ${ALLOWED_DISK_IDS[*]}"
    fi
    
    # Try to import the pool
    log "INFO" "Attempting to import backup pool from disk: $found_disk"
    
    if ! zpool import -d "$(dirname "$found_disk")" "$BACKUP_POOL_NAME" 2>/dev/null; then
        error_exit "Failed to import backup pool '$BACKUP_POOL_NAME' from disk $found_disk"
    fi
    
    log "INFO" "Backup pool '$BACKUP_POOL_NAME' imported successfully"
}

# Check available space
check_available_space() {
    local available_gb=$(zfs list -H -o avail -p "$BACKUP_POOL_NAME" | awk '{print int($1/1024/1024/1024)}')
    
    log "INFO" "Available space on backup pool: ${available_gb}GB"
    
    if [[ $available_gb -lt $MIN_FREE_SPACE_GB ]]; then
        error_exit "Insufficient space on backup pool. Available: ${available_gb}GB, Required: ${MIN_FREE_SPACE_GB}GB"
    fi
    
    log "INFO" "Space check passed"
}

# Get latest snapshot with prefix
get_latest_snapshot() {
    local dataset="$1"
    local prefix="$2"
    
    zfs list -t snapshot -H -o name,creation -s creation "$dataset" 2>/dev/null | \
    grep "@$prefix" | \
    tail -n 1 | \
    awk '{print $1}'
}

# Get snapshot GUID
get_snapshot_guid() {
    local snapshot="$1"
    zfs get -H -o value guid "$snapshot" 2>/dev/null
}

# Get snapshot creation time
get_snapshot_creation() {
    local snapshot="$1"
    zfs get -H -o value creation "$snapshot" 2>/dev/null
}

# Find common snapshot between source and backup
find_common_snapshot() {
    local source_dataset="$1"
    local backup_dataset="$2"
    
    log "INFO" "Finding common snapshot between $source_dataset and $backup_dataset"
    
    # Get all snapshots from both datasets
    local source_snapshots=($(zfs list -t snapshot -H -o name "$source_dataset" 2>/dev/null | sort))
    local backup_snapshots=($(zfs list -t snapshot -H -o name "$backup_dataset" 2>/dev/null | sort))
    
    # Find latest common snapshot by GUID
    local common_snapshot=""
    for source_snap in "${source_snapshots[@]}"; do
        local source_guid=$(get_snapshot_guid "$source_snap")
        
        for backup_snap in "${backup_snapshots[@]}"; do
            local backup_guid=$(get_snapshot_guid "$backup_snap")
            
            if [[ "$source_guid" == "$backup_guid" ]]; then
                common_snapshot="$source_snap"
                break 2
            fi
        done
    done
    
    echo "$common_snapshot"
}

# Perform incremental backup
perform_backup() {
    local dataset="$1"
    local source_dataset="$SOURCE_POOL/$dataset"
    local backup_dataset="$BACKUP_POOL_NAME/$dataset"
    
    log "INFO" "Starting backup for dataset: $dataset"
    
    # Get latest source snapshot
    local latest_source_snapshot=$(get_latest_snapshot "$source_dataset" "$SNAPSHOT_PREFIX")
    
    if [[ -z "$latest_source_snapshot" ]]; then
        error_exit "No snapshots found for dataset $source_dataset with prefix $SNAPSHOT_PREFIX"
    fi
    
    log "INFO" "Latest source snapshot: $latest_source_snapshot"
    
    # Check if backup dataset exists
    if ! zfs list "$backup_dataset" >/dev/null 2>&1; then
        log "INFO" "Backup dataset does not exist, creating initial backup"
        
        if [[ "$TEST_MODE" == true ]]; then
            log "INFO" "TEST MODE: Would create initial backup from $latest_source_snapshot"
            return 0
        fi
        
        # Create initial backup
        zfs send "$latest_source_snapshot" | zfs receive "$backup_dataset"
        log "INFO" "Initial backup completed for $dataset"
        return 0
    fi
    
    # Find common snapshot
    local common_snapshot=$(find_common_snapshot "$source_dataset" "$backup_dataset")
    
    if [[ -z "$common_snapshot" ]]; then
        error_exit "No common snapshot found between source and backup for dataset $dataset"
    fi
    
    log "INFO" "Common snapshot found: $common_snapshot"
    
    # Check if backup is up to date
    local latest_backup_snapshot=$(get_latest_snapshot "$backup_dataset" "$SNAPSHOT_PREFIX")
    local source_guid=$(get_snapshot_guid "$latest_source_snapshot")
    local backup_guid=$(get_snapshot_guid "$latest_backup_snapshot")
    
    if [[ "$source_guid" == "$backup_guid" ]]; then
        log "INFO" "Backup is already up to date for dataset $dataset"
        return 0
    fi
    
    if [[ "$TEST_MODE" == true ]]; then
        log "INFO" "TEST MODE: Would perform incremental backup from $common_snapshot to $latest_source_snapshot"
        return 0
    fi
    
    # Perform incremental backup
    log "INFO" "Performing incremental backup from $common_snapshot to $latest_source_snapshot"
    zfs send -I "$common_snapshot" "$latest_source_snapshot" | zfs receive "$backup_dataset"
    
    log "INFO" "Incremental backup completed for $dataset"
}

# Clean old snapshots
clean_old_snapshots() {
    log "INFO" "Cleaning old snapshots older than $SNAPSHOT_RETENTION_DAYS days"
    
    if [[ "$TEST_MODE" == true ]]; then
        log "INFO" "TEST MODE: Would clean old snapshots"
        return 0
    fi
    
    local cutoff_date=$(date -d "$SNAPSHOT_RETENTION_DAYS days ago" '+%s')
    
    for dataset in "${DATASETS_ARRAY[@]}"; do
        dataset=$(echo "$dataset" | xargs)
        local backup_dataset="$BACKUP_POOL_NAME/$dataset"
        
        # Get all snapshots for this dataset
        local snapshots=($(zfs list -t snapshot -H -o name,creation "$backup_dataset" 2>/dev/null))
        
        for i in $(seq 0 2 $((${#snapshots[@]} - 1))); do
            local snapshot="${snapshots[$i]}"
            local creation="${snapshots[$i+1]}"
            local snapshot_date=$(date -d "$creation" '+%s')
            
            if [[ $snapshot_date -lt $cutoff_date ]]; then
                log "INFO" "Deleting old snapshot: $snapshot (created: $creation)"
                zfs destroy "$snapshot"
            fi
        done
    done
}

# Create CheckMK piggyback file
create_checkmk_piggyback() {
    local status="$1"
    local message="$2"
    
    if [[ -z "$CHECKMK_HOST" ]]; then
        log "WARN" "CHECKMK_HOST not configured, skipping piggyback file creation"
        return 0
    fi
    
    # Create directory if it doesn't exist
    mkdir -p "$CHECKMK_DIR"
    
    local piggyback_file="$CHECKMK_DIR/$CHECKMK_HOST"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    cat > "$piggyback_file" << EOF
<<<local:sep(0)>>>
$status ZFS_Backup - $timestamp - $message
EOF
    
    # Add snapshot information for each dataset
    echo "<<<zfs_snapshots:sep(0)>>>" >> "$piggyback_file"
    
    for dataset in "${DATASETS_ARRAY[@]}"; do
        dataset=$(echo "$dataset" | xargs)
        local source_dataset="$SOURCE_POOL/$dataset"
        local latest_snapshot=$(get_latest_snapshot "$source_dataset" "$SNAPSHOT_PREFIX")
        
        if [[ -n "$latest_snapshot" ]]; then
            local creation=$(get_snapshot_creation "$latest_snapshot")
            echo "source_$dataset $latest_snapshot $creation" >> "$piggyback_file"
        fi
        
        # Add backup snapshot info if pool is still imported
        if zpool list "$BACKUP_POOL_NAME" >/dev/null 2>&1; then
            local backup_dataset="$BACKUP_POOL_NAME/$dataset"
            local backup_snapshot=$(get_latest_snapshot "$backup_dataset" "$SNAPSHOT_PREFIX")
            
            if [[ -n "$backup_snapshot" ]]; then
                local backup_creation=$(get_snapshot_creation "$backup_snapshot")
                echo "backup_$dataset $backup_snapshot $backup_creation" >> "$piggyback_file"
            fi
        fi
    done
    
    log "INFO" "CheckMK piggyback file created: $piggyback_file"
}

# Update system (apt update && apt dist-upgrade)
update_system() {
    if [[ "$ENABLE_SYSTEM_UPDATE" != "true" ]]; then
        log "INFO" "System update disabled in configuration"
        return 0
    fi
    
    if [[ "$TEST_MODE" == true ]]; then
        log "INFO" "TEST MODE: Would run system update (apt update && apt dist-upgrade -y)"
        return 0
    fi
    
    log "INFO" "Starting system update..."
    
    if apt update && apt dist-upgrade -y; then
        log "INFO" "System update completed successfully"
    else
        log "WARN" "System update failed"
    fi
}

# Main backup function
main() {
    log "INFO" "ZFS Backup Script started"
    
    # Parse arguments
    parse_arguments "$@"
    
    # Check prerequisites
    check_root
    create_lock
    load_config
    check_zfs_prerequisites
    
    # Import backup disk
    import_backup_disk
    
    # Check available space
    check_available_space
    
    if [[ "$TEST_MODE" == true ]]; then
        log "INFO" "TEST MODE: All checks passed, backup would be possible"
        create_checkmk_piggyback "0" "Test mode - all checks passed"
        return 0
    fi
    
    # Perform backup for each dataset
    local backup_success=true
    for dataset in "${DATASETS_ARRAY[@]}"; do
        dataset=$(echo "$dataset" | xargs)
        
        if ! perform_backup "$dataset"; then
            backup_success=false
            log "ERROR" "Backup failed for dataset: $dataset"
        fi
    done
    
    if [[ "$backup_success" == true ]]; then
        # Clean old snapshots
        clean_old_snapshots
        
        # Create success piggyback file
        create_checkmk_piggyback "0" "Backup completed successfully"
        
        # Export backup pool
        log "INFO" "Exporting backup pool: $BACKUP_POOL_NAME"
        zpool export "$BACKUP_POOL_NAME"
        BACKUP_POOL_NAME=""  # Prevent cleanup function from trying to export again
        
        # Update system if enabled
        update_system
        
        log "INFO" "ZFS Backup Script completed successfully"
    else
        create_checkmk_piggyback "2" "Backup failed for one or more datasets"
        error_exit "Backup failed for one or more datasets"
    fi
}

# Run main function
main "$@"