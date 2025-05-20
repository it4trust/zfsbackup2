#!/bin/bash
# This is a diagnostic and fix script for zfsbackup2

# Check snapshot existence with debug output
echo "=== Debugging Snapshot Issue ==="
echo "Checking for snapshots on source dataset..."

# Get the SNAPSHOT_TYPES from your config or use default
SNAPSHOT_TYPES="weekly,monthly"
SOURCE_DATASET="rpool/data"

echo "1. Raw snapshot list:"
zfs list -H -t snapshot -o name "${SOURCE_DATASET}"

echo "2. Testing the exact command used in the script:"
snapshot_types_regex=$(echo "${SNAPSHOT_TYPES}" | sed 's/,/\\|/g')
echo "Regex pattern: zfs-auto-snap_(${snapshot_types_regex}).*"

echo "3. Command output:"
zfs list -H -t snapshot -o name,guid,creation -S creation "${SOURCE_DATASET}" | 
    grep -E "zfs-auto-snap_(${snapshot_types_regex}).*" | 
    awk '{print $1"|"$2"|"$3}'

echo "4. Full command with fields for debugging:"
zfs list -H -t snapshot -o name,guid,creation "${SOURCE_DATASET}"

echo ""
echo "=== Fix Options ==="
echo "Option 1: Edit zfsbackup2_script.sh and modify line ~469 in find_newest_common_snapshot function:"
echo "FROM:"
echo "source_snapshots=\$(zfs list -H -t snapshot -o name,guid,creation -S creation \"\${source_dataset}\" | "
echo "                   grep -E \"zfs-auto-snap_(\${snapshot_types_regex}).*\" | "
echo "                   awk '{print \$1\"|\"\$2\"|\"\$3}')"
echo ""
echo "TO: (use case-insensitive matching)"
echo "source_snapshots=\$(zfs list -H -t snapshot -o name,guid,creation -S creation \"\${source_dataset}\" | "
echo "                   grep -i -E \"zfs-auto-snap_(\${snapshot_types_regex}).*\" | "
echo "                   awk '{print \$1\"|\"\$2\"|\"\$3}')"
echo ""
echo "AND modify line ~548 in backup_dataset function:"
echo "FROM:"
echo "source_latest=\$(zfs list -H -t snapshot -o name -S creation \"\${source_dataset}\" | "
echo "               grep -E \"zfs-auto-snap_(\$(echo \"\${SNAPSHOT_TYPES}\" | sed 's/,/\\\\|/g')).*\" | "
echo "               head -1)"
echo ""
echo "TO: (use case-insensitive matching)"
echo "source_latest=\$(zfs list -H -t snapshot -o name -S creation \"\${source_dataset}\" | "
echo "               grep -i -E \"zfs-auto-snap_(\$(echo \"\${SNAPSHOT_TYPES}\" | sed 's/,/\\\\|/g')).*\" | "
echo "               head -1)"
echo ""
echo "Option 2: Try a one-time run with a modified command to see if it works:"
echo "Run this command to see if weekly snapshots are found with case-insensitive matching:"
echo "zfs list -H -t snapshot -o name \"${SOURCE_DATASET}\" | grep -i -E \"zfs-auto-snap_(weekly|monthly).*\""
