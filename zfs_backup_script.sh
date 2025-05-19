#!/bin/bash

# ZFS Backup Script für Proxmox 8 / Debian 12
# Automatische inkrementelle Backups auf rotierende externe Festplatten
# Version: 1.2 – Überarbeitete Snapshot-Verwaltung und Auto-Snapshot-Deaktivierung
# Author: Generated for Proxmox ZFS backup system

set -e  # Skript bricht bei jedem Fehler ab

# Globale Variablen
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CONFIG_FILE="/etc/zfs-backup-script.conf"
LOCK_FILE="/var/run/zfs_backup.lock"
LOG_FILE="/var/log/zfs-backup.log"
CHECKMK_DIR="/var/spool/check_mk_agent/piggyback"
VERBOSE=false
TEST_MODE=false

# Farb-Codes für Output
RED='\033[0;31m';   GREEN='\033[0;32m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'
NC='\033[0m'  # No Color

# Logging-Funktion
log() {
    local level="$1"; shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "${LOG_FILE}"
    if [[ "$VERBOSE" == true ]]; then
        case "$level" in
            INFO)  echo -e "${GREEN}[INFO]${NC}  $message" ;;
            WARN)  echo -e "${YELLOW}[WARN]${NC}  $message" ;;
            ERROR) echo -e "${RED}[ERROR]${NC} $message" ;;
            DEBUG) echo -e "${BLUE}[DEBUG]${NC} $message" ;;
        esac
    fi
}

# Fehlerbehandlung
error_exit() {
    log "ERROR" "$1"
    cleanup
    exit 1
}

# Aufräumfunktion
cleanup() {
    [[ -f "$LOCK_FILE" ]] && { rm -f "$LOCK_FILE"; log "INFO" "Lock-File entfernt"; }
    if [[ -n "$BACKUP_POOL_NAME" ]] && zpool list "$BACKUP_POOL_NAME" &>/dev/null; then
        log "INFO" "Exportiere Backup-Pool: $BACKUP_POOL_NAME"
        zpool export "$BACKUP_POOL_NAME" || log "WARN" "Export von $BACKUP_POOL_NAME fehlgeschlagen"
    fi
}

trap cleanup EXIT
trap 'error_exit "Skript durch Benutzer unterbrochen"' INT TERM

# Argumente parsen
parse_arguments() {
    while getopts "vth" opt; do
        case $opt in
            v) VERBOSE=true ;;
            t) TEST_MODE=true ;;
            h) show_help; exit 0 ;;
            *) error_exit "Ungültige Option. Mit -h Hilfe anzeigen." ;;
        esac
    done
}

# Hilfe anzeigen
show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

ZFS Backup Script – inkrementelle Backups auf externe Laufwerke

OPTIONS:
  -v    Verbose mode (detailliertes Logging)
  -t    Test mode (Konfig prüfen, ohne zu übertragen)
  -h    Diese Hilfe

CONFIGURATION:
  $CONFIG_FILE

EOF
}

# Prüfen, ob root
check_root() {
    [[ $EUID -ne 0 ]] && error_exit "Dieses Skript muss als root ausgeführt werden."
}

# Lockfile anlegen
create_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "unknown")
        error_exit "Schon eine Instanz aktiv (PID: $pid). Lock: $LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
    log "INFO" "Lock-File erstellt: $LOCK_FILE"
}

# Konfiguration laden
load_config() {
    [[ ! -f "$CONFIG_FILE" ]] && error_exit "Config nicht gefunden: $CONFIG_FILE"
    source "$CONFIG_FILE"
    local required=(SOURCE_POOL BACKUP_POOL_NAME ALLOWED_DISK_IDS DATASETS MIN_FREE_SPACE_GB SNAPSHOT_RETENTION_DAYS CHECKMK_HOST)
    for var in "${required[@]}"; do
        [[ -z "${!var}" ]] && error_exit "Config-Variable '$var' fehlt in $CONFIG_FILE"
    done
    IFS=',' read -ra DATASETS_ARRAY <<< "$DATASETS"
    IFS=',' read -ra ALLOWED_DISK_IDS_ARRAY <<< "$ALLOWED_DISK_IDS"
    SNAPSHOT_PREFIX="${SNAPSHOT_PREFIX:-autosnap}"
    log "INFO" "Konfiguration geladen"
}

# ZFS-Prüfungen
check_zfs_prerequisites() {
    lsmod | grep -q zfs || error_exit "ZFS-Modul nicht geladen"
    zpool list "$SOURCE_POOL" &>/dev/null || error_exit "Source-Pool '$SOURCE_POOL' nicht gefunden"
    for ds in "${DATASETS_ARRAY[@]}"; do
        ds=$(echo "$ds"|xargs)
        zfs list "$SOURCE_POOL/$ds" &>/dev/null || error_exit "Dataset '$SOURCE_POOL/$ds' nicht gefunden"
    done
    log "INFO" "ZFS-Prüfungen erfolgreich"
}

# Backup-Disk finden und importieren
import_backup_disk() {
    log "INFO" "Suche Backup-Disk..."
    local found=""
    for id in "${ALLOWED_DISK_IDS_ARRAY[@]}"; do
        id=$(echo "$id"|xargs)
        for path in /dev/disk/by-id/*; do
            [[ "$path" == *"$id"* ]] && { found="$path"; break 2; }
        done
    done
    [[ -z "$found" ]] && error_exit "Keine erlaubte Backup-Disk gefunden (erwartet: ${ALLOWED_DISK_IDS_ARRAY[*]})"
    log "INFO" "Gefunden: $found"
    log "INFO" "Importiere Pool '$BACKUP_POOL_NAME'"
    zpool import -d "$(dirname "$found")" "$BACKUP_POOL_NAME" 2>/dev/null \
        || error_exit "Import von '$BACKUP_POOL_NAME' fehlgeschlagen"
    log "INFO" "Backup-Pool importiert"
}

# Auto-Snapshots deaktivieren für ein Dataset
disable_auto_snapshots_for_dataset() {
    local ds="$1"
    local props=(
        "com.sun:auto-snapshot"
        "com.sun:auto-snapshot:frequent"
        "com.sun:auto-snapshot:hourly"
        "com.sun:auto-snapshot:daily"
        "com.sun:auto-snapshot:weekly"
        "com.sun:auto-snapshot:monthly"
    )
    for p in "${props[@]}"; do
        [[ "$TEST_MODE" == false ]] && zfs set "$p"=false "$ds" &>/dev/null || true
    done
    log "INFO" "Auto-Snapshots deaktiviert für $ds"
}

# Auto-Snapshots für alle Backup-Datasets deaktivieren
disable_auto_snapshots() {
    log "INFO" "Deaktiviere Auto-Snapshots auf Backup-Pool und -Datasets"
    disable_auto_snapshots_for_dataset "$BACKUP_POOL_NAME"
    for ds in "${DATASETS_ARRAY[@]}"; do
        ds=$(echo "$ds"|xargs)
        disable_auto_snapshots_for_dataset "$BACKUP_POOL_NAME/$ds"
    done
}

# Snapshot-GUID holen
get_snapshot_guid() {
    zfs get -H -o value guid "$1" 2>/dev/null
}

# Per Dataset: gemeinsame Snapshots finden
find_common_snapshots() {
    local src="$1" dst="$2"
    log "DEBUG" "Finde gemeinsame Snapshots $src ↔ $dst"
    declare -A srcg dstg; local commons=()
    while read -r s; do [[ -n "$s" ]] && srcg["$(get_snapshot_guid "$s")"]=$s; done < <(zfs list -t snapshot -H -o name "$src" | grep "@$SNAPSHOT_PREFIX")
    while read -r s; do [[ -n "$s" ]] && dstg["$(get_snapshot_guid "$s")"]=$s; done < <(zfs list -t snapshot -H -o name "$dst" | grep "@$SNAPSHOT_PREFIX")
    for guid in "${!srcg[@]}"; do
        [[ -n "${dstg[$guid]}" ]] && commons+=("${srcg[$guid]}")
    done
    # nach Creation-Time sortieren
    printf '%s\n' "${commons[@]}" | while read -r snap; do
        ts=$(date -d "$(zfs get -H -o value creation "$snap")" '+%s')
        echo "$ts $snap"
    done | sort -n | awk '{print $2}'
}

# Backup durchführen
perform_backup() {
    local ds="$1"
    local src_ds="$SOURCE_POOL/$ds"
    local dst_ds="$BACKUP_POOL_NAME/$ds"
    log "INFO" "Backup für Dataset: $ds"
    # alle Snapshots sortiert nach Zeit
    mapfile -t snaps < <(zfs list -t snapshot -H -o name,creation "$src_ds" \
        | grep "@$SNAPSHOT_PREFIX" | sort -k2 | awk '{print $1}')
    [[ ${#snaps[@]} -eq 0 ]] && error_exit "Keine Snapshots in $src_ds mit Prefix $SNAPSHOT_PREFIX"
    log "INFO" "Quelle hat ${#snaps[@]} Snapshots"
    if ! zfs list "$dst_ds" &>/dev/null; then
        log "INFO" "Ziel existiert nicht – initiales Backup aller Snapshots"
        if [[ "$TEST_MODE" == true ]]; then
            for s in "${snaps[@]}"; do log "INFO" "TEST: würde übertragen $s"; done
            return 0
        fi
        # erstes Snapshot
        zfs send "${snaps[0]}" | zfs receive "$dst_ds"
        disable_auto_snapshots_for_dataset "$dst_ds"
        # restliche inkrementell
        for ((i=1;i<${#snaps[@]};i++)); do
            zfs send -i "${snaps[i-1]}" "${snaps[i]}" | zfs receive "$dst_ds"
        done
        log "INFO" "Initiales Backup abgeschlossen"
        return 0
    fi
    # gemeinsame Snapshots ermitteln
    mapfile -t common < <(find_common_snapshots "$src_ds" "$dst_ds")
    if [[ ${#common[@]} -eq 0 ]]; then
        log "WARN" "Keine gemeinsamen Snapshots – Full-Resync nötig?"
        [[ "${ALLOW_FULL_RESYNC:-false}" == "true" ]] || error_exit "ALLOW_FULL_RESYNC nicht aktiviert"
        if [[ "$TEST_MODE" == true ]]; then
            log "INFO" "TEST: würde Full-Resync durchführen"
            return 0
        fi
        zfs destroy -r "$dst_ds"
        perform_backup "$ds"
        return $?
    fi
    # neuesten gemeinsamen finden
    local latest=$(printf '%s\n' "${common[@]}" | while read -r s; do
        ts=$(date -d "$(zfs get -H -o value creation "$s")" '+%s')
        echo "$ts $s"
    done|sort -n|tail -1|awk '{print $2}')
    log "INFO" "Neuester gemeinsamer Snapshot: $latest"
    # fehlende (jüngere) finden
    local latest_time=$(date -d "$(zfs get -H -o value creation "$latest")" '+%s')
    missing=()
    for s in "${snaps[@]}"; do
        ts=$(date -d "$(zfs get -H -o value creation "$s")" '+%s')
        if (( ts > latest_time )); then
            # GUID-Abgleich
            guid_src=$(get_snapshot_guid "$s")
            found=false
            while read -r dsnap; do
                [[ "$(get_snapshot_guid "$dsnap")" == "$guid_src" ]] && { found=true; break; }
            done < <(zfs list -t snapshot -H -o name "$dst_ds" | grep "@$SNAPSHOT_PREFIX")
            $found || missing+=("$s")
        fi
    done
    [[ ${#missing[@]} -eq 0 ]] && { log "INFO" "Alles aktuell"; return 0; }
    # sortieren
    mapfile -t missing < <(for s in "${missing[@]}"; do
        ts=$(date -d "$(zfs get -H -o value creation "$s")" '+%s')
        echo "$ts $s"
    done|sort -n|awk '{print $2}')
    log "INFO" "Übertrage ${#missing[@]} fehlende Snapshots"
    if [[ "$TEST_MODE" == true ]]; then
        for s in "${missing[@]}"; do
            log "INFO" "TEST: würde übertragen $s"
        done
        return 0
    fi
    local from="$latest"
    for s in "${missing[@]}"; do
        zfs send -i "$from" "$s" | zfs receive "$dst_ds" \
            || error_exit "Übertragung von $s fehlgeschlagen"
        from="$s"
    done
    log "INFO" "Übertragung abgeschlossen (${#missing[@]} Snapshots)"
}

# Alte Snapshots löschen
clean_old_snapshots() {
    log "INFO" "Lösche Snapshots älter als $SNAPSHOT_RETENTION_DAYS Tage"
    [[ "$TEST_MODE" == true ]] && { log "INFO" "TEST: würde alte Snapshots löschen"; return 0; }
    cutoff=$(date -d "$SNAPSHOT_RETENTION_DAYS days ago" '+%s')
    for ds in "${DATASETS_ARRAY[@]}"; do
        ds=$(echo "$ds"|xargs)
        dst_ds="$BACKUP_POOL_NAME/$ds"
        mapfile -t info < <(get_snapshots_with_time "$dst_ds" "$SNAPSHOT_PREFIX")
        delete=()
        for entry in "${info[@]}"; do
            snap=$(echo "$entry"|awk '{print $1}')
            ts=$(date -d "$(echo "$entry"|awk '{print $2}')" '+%s')
            (( ts < cutoff )) && delete+=("$snap")
        done
        total=$(zfs list -t snapshot -H -o name "$dst_ds" | grep "@$SNAPSHOT_PREFIX" | wc -l)
        keep=$(( total - ${#delete[@]} ))
        if (( keep < 1 )); then
            last=${delete[-1]}
            delete=( "${delete[@]/$last}" )
            log "INFO" "Bewahre mindestens einen Snapshot: $last"
        fi
        for s in "${delete[@]}"; do
            log "INFO" "Lösche $s"
            zfs destroy "$s"
        done
        log "INFO" "Gelöschte Snapshots: ${#delete[@]} für $ds"
    done
}

# Hilfsfunktion für clean_old_snapshots
get_snapshots_with_time() {
    local ds="$1" pref="$2"
    zfs list -t snapshot -H -o name,creation -s creation "$ds" 2>/dev/null \
      | grep "@$pref" \
      | awk '{print $1" "$2}'
}

# CheckMK-Piggyback erzeugen
create_checkmk_piggyback() {
    local status="$1" msg="$2"
    [[ -z "$CHECKMK_HOST" ]] && { log "WARN" "CHECKMK_HOST nicht gesetzt"; return; }
    mkdir -p "$CHECKMK_DIR"
    local file="$CHECKMK_DIR/$CHECKMK_HOST"
    echo "<<<local:sep(0)>>>" > "$file"
    echo "$status ZFS_Backup - $(date '+%Y-%m-%d %H:%M:%S') - $msg" >> "$file"
    echo "<<<zfs_snapshots:sep(0)>>>" >> "$file"
    for ds in "${DATASETS_ARRAY[@]}"; do
        ds=$(echo "$ds"|xargs)
        src_ds="$SOURCE_POOL/$ds"
        snaps=( $(zfs list -t snapshot -H -o name "$src_ds" | grep "@$SNAPSHOT_PREFIX") )
        (( ${#snaps[@]}>0 )) && echo "source_$ds ${snaps[-1]} $(get_snapshot_creation "${snaps[-1]}") count:${#snaps[@]}" >> "$file"
        if zpool list "$BACKUP_POOL_NAME" &>/dev/null; then
            dst_ds="$BACKUP_POOL_NAME/$ds"
            dsn=( $(zfs list -t snapshot -H -o name "$dst_ds" | grep "@$SNAPSHOT_PREFIX") )
            (( ${#dsn[@]}>0 )) && echo "backup_$ds ${dsn[-1]} $(get_snapshot_creation "${dsn[-1]}") count:${#dsn[@]}" >> "$file"
        fi
    done
    log "INFO" "CheckMK-Piggyback: $file"
}

get_snapshot_creation() {
    zfs get -H -o value creation "$1" 2>/dev/null
}

# System-Update
update_system() {
    [[ "$ENABLE_SYSTEM_UPDATE" != "true" ]] && { log "INFO" "System-Update deaktiviert"; return; }
    if [[ "$TEST_MODE" == true ]]; then
        log "INFO" "TEST: würde System-Update durchführen"
        return
    fi
    log "INFO" "Starte System-Update..."
    if apt update && apt dist-upgrade -y; then
        log "INFO" "Update erfolgreich"
    else
        log "WARN" "Update fehlgeschlagen"
    fi
}

# Main
main() {
    log "INFO" "Starte ZFS Backup Script (v1.2)"
    parse_arguments "$@"
    check_root
    create_lock
    load_config
    check_zfs_prerequisites
    import_backup_disk
    disable_auto_snapshots
    check_available_space
    [[ "$TEST_MODE" == true ]] && { create_checkmk_piggyback 0 "Testmodus – alle Prüfungen erfolgreich"; return 0; }

    local success=true
    for ds in "${DATASETS_ARRAY[@]}"; do
        ds=$(echo "$ds"|xargs)
        perform_backup "$ds" || { success=false; log "ERROR" "Backup fehlgeschlagen für $ds"; }
    done

    if $success; then
        clean_old_snapshots
        create_checkmk_piggyback 0 "Backup erfolgreich"
        log "INFO" "Exportiere Backup-Pool"
        zpool export "$BACKUP_POOL_NAME"
        BACKUP_POOL_NAME=""
        update_system
        log "INFO" "Script erfolgreich beendet"
    else
        create_checkmk_piggyback 2 "Backup für einige Datasets fehlgeschlagen"
        error_exit "Backup gescheitert"
    fi
}

main "$@"
