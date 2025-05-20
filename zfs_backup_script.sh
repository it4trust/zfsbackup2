#!/bin/bash
# =================================================================
# ZFSBackup2 - Automatisierte inkrementelle ZFS-Backups
# für Proxmox 8 auf Debian 12
# =================================================================

# Strict mode
set -euo pipefail

# Script directory and name
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME=$(basename "$0")
VERSION="1.0.0"

# Constants and defaults
readonly DEFAULT_CONFIG_DIR="/etc/zfsbackup2"
readonly DEFAULT_CONFIG_FILE="${DEFAULT_CONFIG_DIR}/zfsbackup2.conf"
readonly DEFAULT_LOG_DIR="/var/log/zfsbackup2"
readonly DEFAULT_LOG_FILE="${DEFAULT_LOG_DIR}/zfsbackup2.log"
readonly DEFAULT_LOCK_FILE="/var/run/zfsbackup2.lock"
readonly DEFAULT_CHECKMK_DIR="/var/lib/check_mk_agent/spool"
readonly DEFAULT_CHECKMK_FILE="${DEFAULT_CHECKMK_DIR}/zfsbackup2_status"
readonly DEFAULT_DATASETS=""
readonly DEFAULT_TARGET_POOL="backuppool"
readonly DEFAULT_MAX_USAGE=80
readonly DEFAULT_MAX_RETRIES=1
readonly DEFAULT_ALLOWED_DISK_IDS=""
readonly DEFAULT_SNAPSHOT_TYPES="weekly,monthly"

# Actual variables (will be overridden by config)
CONFIG_FILE="${DEFAULT_CONFIG_FILE}"
LOG_DIR="${DEFAULT_LOG_DIR}"
LOG_FILE="${DEFAULT_LOG_FILE}"
LOCK_FILE="${DEFAULT_LOCK_FILE}"
CHECKMK_DIR="${DEFAULT_CHECKMK_DIR}"
CHECKMK_FILE="${DEFAULT_CHECKMK_DIR}/zfsbackup2_status"
DATASETS="${DEFAULT_DATASETS}"
TARGET_POOL="${DEFAULT_TARGET_POOL}"
MAX_USAGE=${DEFAULT_MAX_USAGE}
MAX_RETRIES=${DEFAULT_MAX_RETRIES}
ALLOWED_DISK_IDS="${DEFAULT_ALLOWED_DISK_IDS}"
SNAPSHOT_TYPES="${DEFAULT_SNAPSHOT_TYPES}"
RETRY_COUNT=0

# ==================== FUNCTIONS ====================

# Print usage information
usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} [options]

Automated incremental ZFS backups for Proxmox 8 on Debian 12.

Options:
  -c, --config FILE    Use specific config file (default: ${DEFAULT_CONFIG_FILE})
  -h, --help           Display this help and exit
  -v, --version        Output version information and exit
  -t, --test           Test configuration and exit

EOF
}

# Logger function
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    # Ensure log directory exists
    mkdir -p "${LOG_DIR}"
    
    # Print to stdout (if not in cron)
    if [ -t 1 ] || [ "${level}" == "ERROR" ]; then
        echo "[${timestamp}] [${level}] ${message}"
    fi
    
    # Log to file
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}"
}

# Create lock file
create_lock() {
    if [ -f "${LOCK_FILE}" ]; then
        local pid
        pid=$(cat "${LOCK_FILE}")
        if ps -p "${pid}" > /dev/null; then
            log "ERROR" "Another instance of this script is already running (PID: ${pid})"
            exit 1
        else
            log "WARNING" "Found stale lock file. Previous run may have failed. Removing and continuing."
            rm -f "${LOCK_FILE}"
        fi
    fi
    
    echo $$ > "${LOCK_FILE}"
    log "INFO" "Lock file created: ${LOCK_FILE} (PID: $$)"
}

# Remove lock file
remove_lock() {
    if [ -f "${LOCK_FILE}" ]; then
        rm -f "${LOCK_FILE}"
        log "INFO" "Lock file removed: ${LOCK_FILE}"
    fi
}

# Create directories if they don't exist
create_directories() {
    mkdir -p "${LOG_DIR}"
    mkdir -p "${CHECKMK_DIR}"
    # Ensure proper permissions
    chmod 755 "${LOG_DIR}"
    chmod 755 "${CHECKMK_DIR}"
}

# Load configuration file
load_config() {
    if [ ! -f "${CONFIG_FILE}" ]; then
        log "ERROR" "Config file not found: ${CONFIG_FILE}"
        exit 1
    fi

    log "INFO" "Loading configuration from ${CONFIG_FILE}"
    
    # Source the config file
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
    
    # Validate required settings
    if [ -z "${DATASETS}" ]; then
        log "ERROR" "No datasets defined in config file"
        exit 1
    fi
    
    if [ -z "${TARGET_POOL}" ]; then
        log "ERROR" "No target pool defined in config file"
        exit 1
    fi
    
    if [ -z "${ALLOWED_DISK_IDS}" ]; then
        log "ERROR" "No allowed disk IDs defined in config file"
        exit 1
    fi
    
    log "INFO" "Configuration loaded successfully"
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
check_prerequisites() {
    log "INFO" "Checking prerequisites..."
    
    local missing_prerequisites=0
    
    # Check for required commands
    for cmd in zfs zpool awk sed grep sort head tail tr cut wc; do
        if ! command_exists "${cmd}"; then
            log "ERROR" "Required command not found: ${cmd}"
            missing_prerequisites=1
        fi
    done
    
    # Check for zfs-auto-snapshot
    if ! command_exists zfs-auto-snapshot; then
        log "ERROR" "zfs-auto-snapshot not found. Please install it first."
        missing_prerequisites=1
    fi
    
    # Check if running as root
    if [ "$(id -u)" -ne 0 ]; then
        log "ERROR" "This script must be run as root"
        missing_prerequisites=1
    fi
    
    if [ "${missing_prerequisites}" -eq 1 ]; then
        exit 1
    fi
    
    log "INFO" "All prerequisites satisfied"
}

# Get a list of external drives
get_external_drives() {
    local drives=()
    local disks
    
    # Get a list of all block devices
    disks=$(lsblk -dno NAME,TYPE | grep disk | awk '{print $1}')
    
    for disk in $disks; do
        local wwn
        local serial
        local model
        local size
        
        # Get disk identifiers
        wwn=$(udevadm info --query=property --name="/dev/${disk}" | grep -E '^ID_WWN=' | cut -d= -f2)
        serial=$(udevadm info --query=property --name="/dev/${disk}" | grep -E '^ID_SERIAL(_SHORT)?=' | head -1 | cut -d= -f2)
        model=$(udevadm info --query=property --name="/dev/${disk}" | grep -E '^ID_MODEL=' | cut -d= -f2)
        size=$(lsblk -dno SIZE "/dev/${disk}" | tr -d ' ')
        
        # Check if the disk ID is in the allowed list
        IFS=',' read -r -a allowed_ids <<< "${ALLOWED_DISK_IDS}"
        for id in "${allowed_ids[@]}"; do
            if [ -n "${wwn}" ] && [ "${wwn}" == "${id}" ]; then
                drives+=("/dev/${disk}")
                log "INFO" "Found allowed external drive: /dev/${disk} (WWN: ${wwn}, Model: ${model}, Size: ${size})"
                break
            elif [ -n "${serial}" ] && [ "${serial}" == "${id}" ]; then
                drives+=("/dev/${disk}")
                log "INFO" "Found allowed external drive: /dev/${disk} (Serial: ${serial}, Model: ${model}, Size: ${size})"
                break
            fi
        done
    done
    
    # Even if no allowed drives are found, we'll attempt to proceed with importing the pool
    # This allows the script to work when ALLOWED_DISK_IDS isn't configured
    if [ ${#drives[@]} -eq 0 ]; then
        log "WARNING" "No allowed external drives found with IDs: ${ALLOWED_DISK_IDS}. Will attempt direct pool import."
        # Return success even if no drives match
        return 0
    fi
    
    echo "${drives[*]}"
    return 0
}

# Import ZFS pool
import_pool() {
    local drive="$1"
    
    log "INFO" "Checking if target pool ${TARGET_POOL} is already imported..."
    if zpool list -H "${TARGET_POOL}" &>/dev/null; then
        log "INFO" "Pool ${TARGET_POOL} is already imported"
        return 0
    fi
    
    log "INFO" "Attempting to import pool ${TARGET_POOL}..."
    # First try to import by name without specifying a device
    if zpool import "${TARGET_POOL}"; then
        log "INFO" "Successfully imported pool ${TARGET_POOL}"
        return 0
    fi
    
    # If that fails, try with the device directory
    log "INFO" "First attempt failed, trying with device path..."
    if ! zpool import -d "/dev" "${TARGET_POOL}"; then
        log "ERROR" "Failed to import pool ${TARGET_POOL}"
        return 1
    fi
    
    log "INFO" "Successfully imported pool ${TARGET_POOL}"
    return 0
}

# Export ZFS pool
export_pool() {
    log "INFO" "Exporting pool ${TARGET_POOL}..."
    if ! zpool export "${TARGET_POOL}"; then
        log "WARNING" "Failed to export pool ${TARGET_POOL}"
        return 1
    fi
    
    log "INFO" "Successfully exported pool ${TARGET_POOL}"
    return 0
}

# Check pool usage
check_pool_usage() {
    local pool="$1"
    local used_percent
    
    used_percent=$(zpool list -H -o capacity "${pool}" | tr -d '%')
    
    log "INFO" "Checking pool usage: ${pool} is ${used_percent}% full (max allowed: ${MAX_USAGE}%)"
    
    if [ "${used_percent}" -ge "${MAX_USAGE}" ]; then
        log "ERROR" "Pool ${pool} is too full (${used_percent}% used, max allowed: ${MAX_USAGE}%)"
        return 1
    fi
    
    return 0
}

# Find the newest common snapshot between source and target
find_newest_common_snapshot() {
    local source_dataset="$1"
    local target_dataset="$2"
    
    log "INFO" "Finding newest common snapshot between ${source_dataset} and ${target_dataset}..."
    
    # Get list of snapshots from source and target, filtering by specified types
    local source_snapshots
    local target_snapshots
    local snapshot_types_regex
    
    # Convert comma-separated list to regex OR pattern
    snapshot_types_regex=$(echo "${SNAPSHOT_TYPES}" | sed 's/,/\\|/g')
    
    # Get source snapshots
    source_snapshots=$(zfs list -H -t snapshot -o name,guid,creation -S creation "${source_dataset}" | 
                       grep -E "zfs-auto-snap_(${snapshot_types_regex}).*" | 
                       awk '{print $1"|"$2"|"$3}')
    
    if [ -z "${source_snapshots}" ]; then
        log "ERROR" "No suitable snapshots found on source dataset ${source_dataset}"
        return 1
    fi
    
    # Check if target dataset exists
    if ! zfs list -H "${target_dataset}" &>/dev/null; then
        log "INFO" "Target dataset ${target_dataset} does not exist, will create it with initial backup"
        echo ""
        return 0
    fi
    
    # Get target snapshots
    target_snapshots=$(zfs list -H -t snapshot -o name,guid,creation -S creation "${target_dataset}" | 
                       grep -E "zfs-auto-snap_(${snapshot_types_regex}).*" | 
                       awk '{print $1"|"$2"|"$3}')
    
    if [ -z "${target_snapshots}" ]; then
        log "WARNING" "No suitable snapshots found on target dataset ${target_dataset}, will use full backup"
        echo ""
        return 0
    fi
    
    # Find common snapshots by GUID
    local common_snapshot=""
    while IFS= read -r source_snap; do
        local source_guid
        source_guid=$(echo "${source_snap}" | cut -d'|' -f2)
        
        if echo "${target_snapshots}" | grep -q "${source_guid}"; then
            common_snapshot=$(echo "${source_snap}" | cut -d'|' -f1)
            local creation_date
            creation_date=$(echo "${source_snap}" | cut -d'|' -f3)
            log "INFO" "Found common snapshot: ${common_snapshot} (created: ${creation_date})"
            echo "${common_snapshot}"
            return 0
        fi
    done <<< "${source_snapshots}"
    
    log "WARNING" "No common snapshots found between ${source_dataset} and ${target_dataset}, will use full backup"
    echo ""
    return 0
}

# Perform incremental backup for a single dataset
backup_dataset() {
    local source_dataset="$1"
    local target_dataset="${TARGET_POOL}/${source_dataset#*/}"
    local common_snapshot
    
    log "INFO" "Starting backup of dataset: ${source_dataset} to ${target_dataset}"
    
    # Find the newest common snapshot
    common_snapshot=$(find_newest_common_snapshot "${source_dataset}" "${target_dataset}")
    local backup_type="full"
    local source_latest
    
    # Get the latest snapshot of the specified types from source
    source_latest=$(zfs list -H -t snapshot -o name -S creation "${source_dataset}" | 
                   grep -E "zfs-auto-snap_($(echo "${SNAPSHOT_TYPES}" | sed 's/,/\\|/g')).*" | 
                   head -1)
    
    if [ -z "${source_latest}" ]; then
        log "ERROR" "No suitable snapshots found on source dataset ${source_dataset}"
        return 1
    fi
    
    # Prepare the zfs send command
    local send_cmd
    if [ -z "${common_snapshot}" ]; then
        # Full backup
        send_cmd="zfs send -v '${source_latest}'"
        log "INFO" "Performing full backup using snapshot: ${source_latest}"
    else
        # Incremental backup
        send_cmd="zfs send -v -I '${common_snapshot}' '${source_latest}'"
        backup_type="incremental"
        log "INFO" "Performing incremental backup from ${common_snapshot} to ${source_latest}"
    fi
    
    # Prepare the zfs receive command
    local receive_cmd="zfs receive -F -v '${target_dataset}'"
    
    # Execute the backup
    log "INFO" "Executing: ${send_cmd} | ${receive_cmd}"
    
    # Create a fifo to capture output while still piping between commands
    local fifo_file
    fifo_file=$(mktemp -u)
    mkfifo "${fifo_file}"
    
    # Start the receive process in the background
    eval "${receive_cmd} < '${fifo_file}'" > >(tee -a "${LOG_FILE}") 2>&1 &
    local receive_pid=$!
    
    # Start the send process
    eval "${send_cmd} > '${fifo_file}'" > >(tee -a "${LOG_FILE}") 2>&1
    local send_status=$?
    
    # Wait for receive to complete
    wait "${receive_pid}"
    local receive_status=$?
    
    # Remove the fifo
    rm -f "${fifo_file}"
    
    # Check the results
    if [ "${send_status}" -eq 0 ] && [ "${receive_status}" -eq 0 ]; then
        log "INFO" "Successfully completed ${backup_type} backup of ${source_dataset} to ${target_dataset}"
        return 0
    else
        log "ERROR" "Backup failed for ${source_dataset}. Send status: ${send_status}, Receive status: ${receive_status}"
        return 1
    fi
}

# Update CheckMK status file
update_checkmk_status() {
    local status="$1"
    local message="$2"
    local backup_date
    backup_date=$(date "+%Y-%m-%d %H:%M:%S")
    
    log "INFO" "Updating CheckMK status file: ${CHECKMK_FILE}"
    
    mkdir -p "${CHECKMK_DIR}"
    
    cat > "${CHECKMK_FILE}" << EOF
<<<zfsbackup2>>>
P "ZFS Backup Status" ${status} - ${message} (Last run: ${backup_date})
EOF
    
    # Set appropriate permissions
    chmod 644 "${CHECKMK_FILE}"
    
    log "INFO" "CheckMK status updated: ${status} - ${message}"
}

# Generate snapshot comparison for CheckMK
generate_snapshot_comparison() {
    local status=0
    local comparison_output=""
    local age_warning=0
    local now
    now=$(date +%s)
    
    log "INFO" "Generating snapshot comparison for CheckMK..."
    
    # Process each dataset
    IFS=',' read -r -a dataset_array <<< "${DATASETS}"
    for source_dataset in "${dataset_array[@]}"; do
        local target_dataset="${TARGET_POOL}/${source_dataset#*/}"
        
        # Skip if the target dataset doesn't exist yet
        if ! zfs list -H "${target_dataset}" &>/dev/null; then
            comparison_output="${comparison_output}P \"${target_dataset}\" 1 - Dataset does not exist yet\n"
            status=1
            continue
        fi
        
        # Get the latest snapshot from source and target
        local source_latest
        local target_latest
        local source_latest_time
        local target_latest_time
        local time_diff
        
        source_latest=$(zfs list -H -t snapshot -o name,creation -S creation "${source_dataset}" | 
                       grep -E "zfs-auto-snap_($(echo "${SNAPSHOT_TYPES}" | sed 's/,/\\|/g')).*" | 
                       head -1)
        
        target_latest=$(zfs list -H -t snapshot -o name,creation -S creation "${target_dataset}" |
                       grep -E "zfs-auto-snap_($(echo "${SNAPSHOT_TYPES}" | sed 's/,/\\|/g')).*" | 
                       head -1)
        
        if [ -z "${source_latest}" ] || [ -z "${target_latest}" ]; then
            comparison_output="${comparison_output}P \"${target_dataset}\" 1 - Missing snapshots\n"
            status=1
            continue
        fi
        
        # Extract creation timestamps
        source_latest_time=$(echo "${source_latest}" | awk '{print $2}')
        target_latest_time=$(echo "${target_latest}" | awk '{print $2}')
        
        # Convert timestamps to Unix time for comparison
        source_latest_unix=$(date -d "${source_latest_time}" +%s)
        target_latest_unix=$(date -d "${target_latest_time}" +%s)
        time_diff=$((now - target_latest_unix))
        
        # Output snapshot names
        source_latest_name=$(echo "${source_latest}" | awk '{print $1}')
        target_latest_name=$(echo "${target_latest}" | awk '{print $1}')
        
        # Check if backup is older than 24 hours (86400 seconds)
        if [ "${time_diff}" -gt 86400 ]; then
            comparison_output="${comparison_output}P \"${target_dataset}\" 1 - Last backup too old (${target_latest_time}), source latest: ${source_latest_name}\n"
            age_warning=1
        else
            comparison_output="${comparison_output}P \"${target_dataset}\" 0 - Last backup: ${target_latest_time}, source latest: ${source_latest_time}\n"
        fi
    done
    
    # Update final status
    status=$((status | age_warning))
    
    # Write to CheckMK file
    mkdir -p "${CHECKMK_DIR}"
    cat > "${CHECKMK_FILE}" << EOF
<<<zfsbackup2>>>
P "ZFS Backup Status" ${status} - Last run: $(date "+%Y-%m-%d %H:%M:%S")
$(echo -e "${comparison_output}")
EOF
    
    # Set appropriate permissions
    chmod 644 "${CHECKMK_FILE}"
    
    log "INFO" "CheckMK status file updated with snapshot comparison"
    
    return ${status}
}

# Run system updates
run_system_updates() {
    log "INFO" "Running system updates..."
    
    if ! apt-get update; then
        log "WARNING" "Failed to update package lists"
        return 1
    fi
    
    if ! apt-get dist-upgrade -y; then
        log "WARNING" "Failed to upgrade packages"
        return 1
    fi
    
    log "INFO" "System update completed successfully"
    
    # Check if reboot is required
    if [ -f /var/run/reboot-required ]; then
        log "INFO" "System reboot is required after updates"
        # Update CheckMK status to indicate reboot required
        echo "P \"System Update Status\" 1 - Reboot required after updates" >> "${CHECKMK_FILE}"
    else
        log "INFO" "No reboot required after updates"
        echo "P \"System Update Status\" 0 - System updated, no reboot required" >> "${CHECKMK_FILE}"
    fi
    
    return 0
}

# Main backup procedure
do_backup() {
    local all_success=0
    
    log "INFO" "Starting ZFS backup procedure..."
    
    # Get external drives - but continue even if no allowed drives are found
    local external_drives
    external_drives=$(get_external_drives)
    
    # Import the pool - this should work even without specific drives
    import_pool "${external_drives}" || {
        log "ERROR" "Failed to import the target pool"
        update_checkmk_status 2 "Failed to import the target pool"
        return 1
    }
    
    # Check pool usage
    check_pool_usage "${TARGET_POOL}" || {
        log "ERROR" "Target pool usage exceeds threshold"
        update_checkmk_status 2 "Target pool usage exceeds threshold (${MAX_USAGE}%)"
        export_pool
        return 1
    }
    
    # Process each dataset
    IFS=',' read -r -a dataset_array <<< "${DATASETS}"
    log "INFO" "Processing ${#dataset_array[@]} datasets: ${DATASETS}"
    
    for dataset in "${dataset_array[@]}"; do
        log "INFO" "Processing dataset: ${dataset}"
        if ! backup_dataset "${dataset}"; then
            log "ERROR" "Backup failed for dataset: ${dataset}"
            all_success=1
        fi
    done
    
    # Generate snapshot comparison for CheckMK
    generate_snapshot_comparison
    
    # Run system updates if all backups were successful
    if [ "${all_success}" -eq 0 ]; then
        log "INFO" "All backups completed successfully, running system updates"
        run_system_updates
    else
        log "WARNING" "Some backups failed, skipping system updates"
        update_checkmk_status 1 "Some backups failed"
    fi
    
    # Export the pool
    export_pool
    
    return "${all_success}"
}

# Clean up function (trap for exit)
cleanup() {
    local exit_code=$?
    log "INFO" "Script execution completed with exit code ${exit_code}"
    remove_lock
    exit "${exit_code}"
}

# ==================== MAIN SCRIPT ====================

# Parse command line arguments
while [ $# -gt 0 ]; do
    case "$1" in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -v|--version)
            echo "ZFSBackup2 version ${VERSION}"
            exit 0
            ;;
        -t|--test)
            TEST_MODE=1
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Set up trap for cleanup
trap cleanup EXIT INT TERM

# Create directories
create_directories

# Start logging
log "INFO" "===== ZFSBackup2 v${VERSION} started ====="

# Load configuration
load_config

# Check prerequisites
check_prerequisites

# If test mode, exit now
if [ "${TEST_MODE:-0}" -eq 1 ]; then
    log "INFO" "Configuration test completed successfully"
    exit 0
fi

# Create lock file
create_lock

# Main backup procedure with retry logic
if ! do_backup; then
    if [ "${RETRY_COUNT}" -lt "${MAX_RETRIES}" ]; then
        log "WARNING" "Backup failed, retrying (attempt ${RETRY_COUNT}/${MAX_RETRIES})..."
        RETRY_COUNT=$((RETRY_COUNT + 1))
        # Wait a bit before retrying
        sleep 5
        if ! do_backup; then
            log "ERROR" "Backup failed after retry"
            update_checkmk_status 2 "Backup failed after retry"
            exit 1
        fi
    else
        log "ERROR" "Backup failed, max retries reached"
        update_checkmk_status 2 "Backup failed, max retries reached"
        exit 1
    fi
fi

log "INFO" "===== ZFSBackup2 completed successfully ====="
update_checkmk_status 0 "Backup completed successfully"
exit 0
