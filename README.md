### -v (Verbose Mode)

```bash
./zfs-backup.sh -v
```

**Funktionen**:
- Detailliertes Logging in Echtzeit
- Farbige Konsolenausgabe für bessere Lesbarkeit
- Erweiterte Fehlermeldungen
- Debug-Informationen

**Verwendung**: 
- Manuelle Skript-Ausführung
- Fehlerdiagnose
- Entwicklung und Testing

### -t (Test Mode)

```bash
./zfs-backup.sh -t
```

**Funktionen**:
- Simuliert Backup-Durchlauf ohne Ausführung
- Prüft alle Voraussetzungen:
  - Konfiguration
  - Festplatten-Verfügbarkeit
  - Speicherplatz
  - Snapshot-Verfügbarkeit
- Gibt detaillierte Informationen über geplante Aktionen aus
- Erstellt CheckMK-Piggyback mit Test-Status

**Ausgabebeispiel**:
```
[INFO] Configuration loaded successfully
[INFO] ZFS prerequisites check passed
[INFO] Found backup disk: /dev/disk/by-id/wwn-0x5000c500xxxxxxxx
[INFO] Available space on backup pool: 500GB
[INFO] TEST MODE: Would perform incremental backup from rpool/data@zfs-auto-snap_daily-2023-12-01-0000 to rpool/data@zfs-auto-snap_daily-2023-12-08-0000
[INFO] TEST MODE: All checks passed, backup would be possible
```

### -h (Help)

```bash
./zfs-backup.sh -h
```

Zeigt Hilfetext mit allen verfügbaren Optionen und Beispielen.

### Kombinierte Parameter

```bash
# Test mit detaillierter Ausgabe
./zfs-backup.sh -vt

# Normaler Backup mit verbose output
./zfs-backup.sh -v
```

## Cronjob-Integration

### Empfohlene Cronjob-Konfiguration

```bash
# Bearbeiten der root-crontab
sudo crontab -e

# Backup jeden Sonntag um 02:00 Uhr
0 2 * * 0 /usr/local/bin/zfs-backup.sh >> /var/log/zfs-backup-cron.log 2>&1

# Alternative: Backup täglich um 02:00 Uhr (falls Festplatten häufiger gewechselt werden)
0 2 * * * /usr/local/bin/zfs-backup.sh >> /var/log/zfs-backup-cron.log 2>&1
```

### Cronjob mit Test-Modus (täglich)

```bash
# Täglicher Test um 01:30 Uhr, Backup nur sonntags
30 1 * * * /usr/local/bin/zfs-backup.sh -t >> /var/log/zfs-backup-test.log 2>&1
0 2 * * 0 /usr/local/bin/zfs-backup.sh >> /var/log/zfs-backup.log 2>&1
```

### E-Mail-Benachrichtigung bei Fehlern

```bash
# Installation von mailutils für E-Mail-Versand
sudo apt install mailutils

# Cronjob mit E-Mail bei Fehlern
0 2 * * 0 /usr/local/bin/zfs-backup.sh || echo "ZFS Backup failed on $(hostname)" | mail -s "Backup Error" admin@example.com
```

### Logging-Rotation

```bash
# Logrotate-Konfiguration erstellen
sudo nano /etc/logrotate.d/zfs-backup

# Inhalt:
/var/log/zfs-backup*.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
}
```

## Fehlerbehandlung & Logging

### Logging-System

Das Skript verwendet ein mehrstufiges Logging-System:

```bash
# Log-Level:
# INFO  - Normale Operationen
# WARN  - Warnungen, die Aufmerksamkeit benötigen  
# ERROR - Fehler, die zum Skript-Abbruch führen
# DEBUG - Detailierte Informationen (nur mit -v)
```

### Zentrale Log-Datei

```bash
# Standard-Log-Datei
/var/log/zfs-backup.log

# Struktur:
2023-12-08 02:00:01 [INFO] ZFS Backup Script started
2023-12-08 02:00:02 [INFO] Configuration loaded successfully
2023-12-08 02:00:03 [INFO] Found backup disk: /dev/disk/by-id/wwn-0x5000c500xxxxxxxx
2023-12-08 02:00:15 [INFO] Incremental backup completed for data
2023-12-08 02:05:30 [INFO] ZFS Backup Script completed successfully
```

### Fehler-Kategorien und Behandlung

#### 1. Konfigurationsfehler

```bash
# Beispiele:
- Fehlende Konfigurationsdatei
- Ungültige Dataset-Namen
- Fehlende Pflichtfelder

# Behandlung:
- Sofortiger Abbruch mit clara Fehlermeldung
- Logging der fehlenden/ungültigen Konfiguration
```

#### 2. Hardware-/System-Fehler

```bash
# Beispiele:
- Backup-Festplatte nicht gefunden
- Unzureichender Speicherplatz
- ZFS-Pool Import-Fehler

# Behandlung:
- Detaillierte Diagnose-Ausgabe
- Cleanup ausgeführter Operationen
- CheckMK-Benachrichtigung mit Fehler-Status
```

#### 3. Backup-Spezifische Fehler

```bash
# Beispiele:
- Keine gemeinsamen Snapshots gefunden
- zfs send/receive Fehler
- Snapshot-Erstellungs-Probleme

# Behandlung:
- Fallback-Strategien wo möglich
- Detaillierte Fehlerdiagnose
- Sicherer Pool-Export auch bei Fehlern
```

### Signal-Handling

```bash
# Das Skript fängt Interrupts ab:
trap cleanup EXIT     # Normale Beendigung
trap 'error_exit "Script interrupted by user"' INT TERM

# Cleanup-Funktion:
- Entfernt Lockfile
- Exportiert importierte Pools
- Schreibt Abschluss-Log-Eintrag
```

### Log-Analyse-Kommandos

```bash
# Letzten Backup-Lauf anzeigen
sudo tail -f /var/log/zfs-backup.log

# Fehler-Suche
sudo grep -i error /var/log/zfs-backup.log

# Backup-Erfolg der letzten 7 Tage
sudo grep "completed successfully" /var/log/zfs-backup.log | tail -7

# Detaillierte Statüsauswertung
sudo zfs-backup.sh -t -v
```

## CheckMK-Anbindung

### Piggyback-File-Format

Das Skript erstellt CheckMK-kompatible Piggyback-Dateien unter:
```
/var/spool/check_mk_agent/piggyback/[CHECKMK_HOST]
```

### Datei-Inhalt

```bash
# Haupt-Status
<<<local:sep(0)>>>
0 ZFS_Backup - 2023-12-08 02:05:30 - Backup completed successfully

# Snapshot-Informationen
<<<zfs_snapshots:sep(0)>>>
source_data rpool/data@zfs-auto-snap_daily-2023-12-08-0000 2023-12-08 00:00:00
backup_data backup/data@zfs-auto-snap_daily-2023-12-08-0000 2023-12-08 02:05:00
source_vm rpool/vm@zfs-auto-snap_daily-2023-12-08-0000 2023-12-08 00:00:00
backup_vm backup/vm@zfs-auto-snap_daily-2023-12-08-0000 2023-12-08 02:07:00
```

### Status-Codes

```bash
0 - OK (Backup erfolgreich)
1 - WARNING (Backup mit Warnungen)
2 - CRITICAL (Backup fehlgeschlagen)
3 - UNKNOWN (Unbekannter Status)
```

### CheckMK-Service-Konfiguration

Erstellen Sie in CheckMK einen lokalen Check:

```python
# /omd/sites/[SITE]/local/share/check_mk/checks/zfs_backup
def inventory_zfs_backup(info):
    if info:
        yield None, {}

def check_zfs_backup(item, params, info):
    if not info:
        return 3, "No backup information available"
    
    status_line = info[0][0]
    parts = status_line.split(' - ', 2)
    
    if len(parts) >= 3:
        status = int(parts[0])
        timestamp = parts[1]
        message = parts[2]
        
        return status, f"Last backup: {timestamp} - {message}"
    
    return 3, "Invalid backup status format"

check_info["zfs_backup"] = {
    "check_function": check_zfs_backup,
    "inventory_function": inventory_zfs_backup,
    "service_description": "ZFS Backup Status",
}
```

### Monitoring-Dashboard

In CheckMK können Sie ein Dashboard erstellen, das zeigt:
- Backup-Status aller Hosts
- Letzte erfolgreiche Backup-Zeit
- Anzahl der gesicherten Snapshots
- Trend-Analyse der Backup-Größen

## Operative Prozesse

### Wöchentlicher Festplatten-Wechsel

#### Prozedur:

1. **Vorbereitungscheck**
   ```bash
   # Test-Lauf vor Wechsel
   sudo zfs-backup.sh -t
   ```

2. **Aktuelle Festplatte entfernen**
   - Backup-Completion prüfen (CheckMK/Logs)
   - Festplatte sicher entfernen
   - Beschriftung mit Datum des letzten Backups

3. **Neue Festplatte einsetzen**
   - Physisch verbinden
   - Auto-Import prüfen:
   ```bash
   sudo zpool import
   ```

4. **Funktionstest**
   ```bash
   sudo zfs-backup.sh -vt
   ```

#### Rotations-Schema (Beispiel)

```
Woche 1: Festplatte A (aktiv)    - Festplatte B (offsite)
Woche 2: Festplatte B (aktiv)    - Festplatte A (offsite)
Woche 3: Festplatte A (aktiv)    - Festplatte B (offsite)
...
```

### Notfall-Wiederherstellung

#### 1. Dataset-Wiederherstellung

```bash
# Pool importieren
sudo zpool import backup

# Verfügbare Snapshots anzeigen
sudo zfs list -t snapshot backup/data

# Snapshot zurückspielen
sudo zfs rollback backup/data@zfs-auto-snap_daily-2023-12-01-0000

# Oder: Dataset komplett wiederherstellen
sudo zfs send backup/data@latest | sudo zfs receive rpool/data_restored
```

#### 2. Vollständige System-Wiederherstellung

```bash
# Boot von Live-System
# ZFS-Pools importieren
sudo zpool import rpool
sudo zpool import backup

# System-Rollback
sudo zfs rollback rpool/ROOT/pve-1@zfs-auto-snap_daily-2023-12-01-0000

# Oder: Neuinstallation mit Daten-Restore
# [Detaillierte Proxmox-Recovery-Prozedur erforderlich]
```

### Kapazitäts-Management

#### Überwachung

```bash
# Backup-Pool-Größe prüfen
sudo zpool list backup

# Dataset-Größen
sudo zfs list backup

# Snapshot-Größen und -Anzahl
sudo zfs list -t snapshot backup | wc -l
sudo zfs list -t snapshot -o name,used,refer backup
```

#### Optimierung

```bash
# Komprimierung aktivieren (falls nicht bereits aktiv)
sudo zfs set compression=lz4 backup

# Deduplication (nur bei ausreichend RAM!)
sudo zfs set dedup=on backup

# Snapshot-Rotation anpassen
# Editiere SNAPSHOT_RETENTION_DAYS in /etc/zfs-backup-script.conf
```

## Troubleshooting

### Häufige Probleme und Lösungen

#### Problem: "No allowed backup disk found"

**Ursachen:**
- Festplatte nicht angeschlossen
- Falsche Disk-ID in Konfiguration
- USB-Verbindungsprobleme

**Diagnose:**
```bash
# Angeschlossene Festplatten auflisten
ls -la /dev/disk/by-id/

# Konfiguration prüfen
grep ALLOWED_DISK_IDS /etc/zfs-backup-script.conf

# USB-Geräte anzeigen
lsusb
dmesg | grep usb
```

**Lösung:**
```bash
# Korrekte Disk-ID ermitteln und in Konfiguration eintragen
sudo nano /etc/zfs-backup-script.conf
```

#### Problem: "Failed to import backup pool"

**Ursachen:**
- Pool bereits importiert
- Pool-Beschädigung
- Falsche Pool-Namen

**Diagnose:**
```bash
# Importierbare Pools anzeigen
sudo zpool import

# Pool-Status prüfen
sudo zpool status backup

# Pool-History anzeigen
sudo zpool history backup
```

**Lösung:**
```bash
# Falls Pool bereits importiert
sudo zpool export backup

# Bei Pool-Problemen
sudo zpool import -f backup

# Bei Beschädigung
sudo zpool scrub backup
```

#### Problem: "No common snapshot found"

**Ursachen:**
- Backup-Pool leer oder neu
- Alle gemeinsamen Snapshots gelöscht
- GUID-Mismatch durch Pool-Neuerstellung

**Diagnose:**
```bash
# Snapshots vergleichen
sudo zfs list -t snapshot rpool/data
sudo zfs list -t snapshot backup/data

# GUID-Vergleich
sudo zfs get guid rpool/data@snapshot-name
sudo zfs get guid backup/data@snapshot-name
```

**Lösung:**
```bash
# Initiales Backup erzwingen (ACHTUNG: Überschreibt backup/data!)
sudo zfs destroy -r backup/data
sudo zfs-backup.sh
```

#### Problem: "Insufficient space on backup pool"

**Ursachen:**
- Backup-Pool zu klein
- Alte Snapshots nicht gelöscht
- Unerwartete Datenmengen

**Diagnose:**
```bash
# Speicherplatzbelegung detailliert
sudo zfs list -o space backup
sudo zfs list -t snapshot backup

# Größte Snapshots finden
sudo zfs list -t snapshot -s used backup | tail -10
```

**Lösung:**
```bash
# Retention-Zeit verkürzen
sudo nano /etc/zfs-backup-script.conf
# SNAPSHOT_RETENTION_DAYS reduzieren

# Manuell alte Snapshots löschen
sudo zfs destroy backup/data@old-snapshot

# Komprimierung aktivieren
sudo zfs set compression=lz4 backup
```

#### Problem: Backup läuft endlos

**Ursachen:**
- Sehr große Datasets
- Langsame USB-Verbindung
- I/O-Probleme

**Diagnose:**
```bash
# Backup-Prozess überwachen
sudo pgrep -f zfs-backup
sudo iostat -x 1

# ZFS-Operationen überwachen
sudo zpool iostat 1
sudo tail -f /var/log/zfs-backup.log
```

**Lösung:**
```bash
# Bei USB 2.0: Auf USB 3.0+ wechseln
# Bei großen Initial-Backups: Patience oder
# Backup in Teilen (einzelne Datasets)

# Einzelnes Dataset testen
sudo nano /etc/zfs-backup-script.conf
# DATASETS="data" # nur ein Dataset
```

### Debug-Methoden

#### Verbose Logging aktivieren

```bash
# Detaillierte Ausgabe für Diagnose
sudo zfs-backup.sh -v

# Log-Level für ZFS erhöhen
echo 1 | sudo tee /sys/module/zfs/parameters/zfs_dbgmsg_enable

# ZFS Debug-Messages lesen
sudo dmesg | grep -i zfs
```

#### Manual Testing

```bash
# Einzelne Funktionen manuell testen
source /etc/zfs-backup-script.conf

# Pool-Import testen
sudo zpool import -d /dev/disk/by-id backup

# Snapshot-Vergleich manuell
sudo zfs list -H -o name,guid -t snapshot rpool/data
sudo zfs list -H -o name,guid -t snapshot backup/data

# Send/Receive-Test
sudo zfs send rpool/data@latest | sudo zfs receive -n backup/data_test
```

#### Konfigurations-Validierung

```bash
# Syntax-Check der Konfiguration
source /etc/zfs-backup-script.conf && echo "Config OK"

# Alle konfigurierten Datasets prüfen
for dataset in $(echo $DATASETS | tr ',' ' '); do
    if ! zfs list $SOURCE_POOL/$dataset >/dev/null 2>&1; then
        echo "ERROR: Dataset $SOURCE_POOL/$dataset not found"
    fi
done
```

### Performance-Optimierung

#### Backup-Geschwindigkeit

```bash
# Komprimierung für schnellere Übertragung
sudo zfs set compression=lz4 rpool/data

# Recordsize optimieren (vor Daten-Import!)
sudo zfs set recordsize=1M backup/data

# Send-Optionen erweitern
# Im Skript: zfs send -c -e (compressed, embedded)
```

#### System-Ressourcen

```bash
# I/O-Scheduler optimieren
echo mq-deadline | sudo tee /sys/block/sda/queue/scheduler

# ZFS-Memory-Limits anpassen
echo $(($(grep MemTotal /proc/meminfo | awk '{print $2}') * 1024 / 2)) | sudo tee /sys/module/zfs/parameters/zfs_arc_max

# Nice-Level für Backup-Prozess
# Im Cronjob: nice -n 10 /usr/local/bin/zfs-backup.sh
```

### Best Practices

#### Sicherheit

1. **Festplatten-Verschlüsselung**
   ```bash
   # LUKS-Verschlüsselung vor ZFS-Pool
   sudo cryptsetup luksFormat /dev/sdb
   sudo cryptsetup luksOpen /dev/sdb backup_crypt
   sudo zpool create backup /dev/mapper/backup_crypt
   ```

2. **Zugriffsrechte**
   ```bash
   sudo chmod 600 /etc/zfs-backup-script.conf
   sudo chmod 755 /usr/local/bin/zfs-backup.sh
   ```

3. **Audit-Trail**
   ```bash
   # Backup-Aktivitäten in separatem Log
   echo "$(date): Backup started by $(whoami)" >> /var/log/zfs-backup-audit.log
   ```

#### Monitoring

1. **Proaktive Überwachung**
   - CheckMK-Alerts bei ausbleibendem Backup
   - Slack/E-Mail-Benachrichtigung bei Fehlern
   - Dashboards für Backup-Trends

2. **Kapazitäts-Planung**
   - Regelmäßige Auswertung der Backup-Größen
   - Hochrechnung des Speicherplatzbedarfs
   - Rechtzeitige Beschaffung größerer Festplatten

#### Wartung

1. **Regelmäßige Tests**
   - Monatlicher Restore-Test einzelner Dateien
   - Jährlicher Full-Recovery-Test
   - Dokumentation der Test-Ergebnisse

2. **System-Updates**
   - ZFS-Tools aktuell halten
   - Kernel-Updates mit ZFS-Kompatibilität prüfen
   - Backup vor kritischen System-Updates

---

### Autor und Wartung

Dieses Skript und die Dokumentation wurden für eine Proxmox 8 ZFS-Backup-Umgebung entwickelt. Bei Fragen oder Problemen sollten zunächst die Log-Dateien und die Test-Modi genutzt werden.

**Letzte Aktualisierung**: Dezember 2023
**Version**: 1.0
**Kompatibilität**: Proxmox 8, Debian 12, ZFS 2.x

---

*Ende der Dokumentation*
