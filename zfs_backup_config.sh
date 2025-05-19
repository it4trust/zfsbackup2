# ZFS Backup Script Configuration
# Configuration file for /usr/local/bin/zfs-backup.sh

# Source ZFS Pool (the pool containing the datasets to backup)
SOURCE_POOL="rpool"

# Backup ZFS Pool Name (name of the pool on the external drives)
BACKUP_POOL_NAME="backup"

# Allowed disk IDs (comma-separated list of WWN or serial numbers)
# These are the only disks that will be accepted for backup
# You can find disk IDs with: ls -la /dev/disk/by-id/
ALLOWED_DISK_IDS="wwn-0x5000c500xxxxxxxx,wwn-0x5000c500yyyyyyyy"

# Datasets to backup (comma-separated list, relative to SOURCE_POOL)
# Example: "data,vm,ct" will backup rpool/data, rpool/vm, rpool/ct
DATASETS="data,vm,ct"

# Snapshot prefix to look for (usually set by zfs-auto-snapshot)
# Only snapshots with this prefix will be considered for backup
SNAPSHOT_PREFIX="zfs-auto-snap"

# Minimum free space required on backup pool (in GB)
# Backup will abort if less space is available
MIN_FREE_SPACE_GB=50

# Snapshot retention on backup pool (in days)
# Snapshots older than this will be automatically deleted
SNAPSHOT_RETENTION_DAYS=30

# CheckMK integration
# Hostname for CheckMK piggyback files (leave empty to disable)
CHECKMK_HOST="proxmox-host"

# System update after successful backup
# Set to "true" to run apt update && apt dist-upgrade -y after backup
# Set to "false" to disable system updates
ENABLE_SYSTEM_UPDATE="true"

# Advanced settings (usually don't need to be changed)

# Log file location
LOG_FILE="/var/log/zfs-backup.log"

# Lock file location  
LOCK_FILE="/var/run/zfs_backup.lock"

# CheckMK piggyback directory
CHECKMK_DIR="/var/spool/check_mk_agent/piggyback"