# ZFS Backup Script v1.2 - Dokumentation

## Überblick

Das ZFS Backup Script automatisiert die inkrementelle Sicherung von ZFS-Datasets auf wechselnde externe Festplatten. Es wurde speziell für Proxmox 8 Systeme unter Debian 12 entwickelt und arbeitet mit den von `zfs-auto-snapshot` erstellten Snapshots.

### Hauptfunktionen

- **Inkrementelle Backups**: Übertragung nur geänderter Daten basierend auf Snapshots
- **Festplatten-Rotation**: Unterstützung für wechselnde Backup-Festplatten
- **Umfassende Snapshot-Bereinigung**: Entfernung verwaister Snapshots aller Typen (daily, hourly, weekly, monthly, frequent)
- **Flexibles Dataset-Mapping**: Unterstützung für individuelle Ziel-Pfade
- **CheckMK Integration**: Monitoring-Integration über Piggyback-Dateien
- **Sicherheitsmechanismen**: Lockfile-Schutz, Speicherplatz-Prüfung
- **Flexible Konfiguration**: Externe Konfigurationsdatei

## Installation und Voraussetzungen

### Systemanforderungen

- Proxmox 8 oder Debian 12
- ZFS-Dateisystem konfiguriert
- Root-Berechtigung für die Ausführung

### Erforderliche Pakete

```bash
apt update
apt install -y zfsutils-linux bc coreutils util-linux udev
```

### Zusätzliche Tools für erweiterte Funktionen

```bash
# Für zfs-auto-snapshot (falls noch nicht installiert)
apt install -y zfs-auto-snapshot

# Für CheckMK Agent (optional)
apt install -y check-mk-agent
```

### Installation des Scripts

1. Script und Konfigurationsdatei in dasselbe Verzeichnis kopieren:
```bash
mkdir -p /opt/zfs-backup
cp zfs-backup2.sh /opt/zfs-backup/
cp zfs-backup2-skript.conf /opt/zfs-backup/
chmod +x /opt/zfs-backup/zfs-backup2.sh
```

2. Log-Verzeichnis vorbereiten:
```bash
touch /var/log/zfs-backup2.log
chmod 640 /var/log/zfs-backup2.log
```

## Konfiguration

### Konfigurationsdatei (zfs-backup2-skript.conf)

Die Konfiguration erfolgt über die Datei `zfs-backup2-skript.conf`, die im gleichen Verzeichnis wie das Script liegen muss.

#### Pflichtparameter

**DATASETS**
```bash
# Traditionelles Format (Dataset wird im Backup-Pool repliziert)
DATASETS=rpool/data,rpool/vms

# Flexibles Mapping (Quelle:Ziel)
DATASETS=rpool/data:backup/mydata,rpool/vms:vms,rpool/ct:containers

# Gemischtes Format
DATASETS=rpool/data,rpool/vms:vms,rpool/ct:backup/containers
```

Unterstützte Formate:
- **Traditionell**: `rpool/data` → `backup/rpool/data`
- **Flexibel**: `rpool/data:mydata` → `backup/mydata`
- **Absolut**: `rpool/data:backup/mydata` → `backup/mydata`

**BACKUP_DISK_IDS**
```bash
BACKUP_DISK_IDS=0x5000c500a1b2c3d4,WD-ABCD1234567890,ST1000DM003-ABC123
```
- Kommagetrennte Liste eindeutiger Identifikatoren der erlaubten Backup-Festplatten
- Unterstützte Formate:
  - WWN (World Wide Name): `0x5000c500a1b2c3d4`
  - ATA-Serial: `WD-ABCD1234567890`
  - Andere eindeutige Seriennummern

**BACKUP_POOL**
```bash
BACKUP_POOL=backup
```
- Name des ZFS-Pools auf der Backup-Festplatte
- Muss auf allen Backup-Festplatten identisch sein

#### Optionale Parameter

**MIN_FREE_SPACE_GB**
```bash
MIN_FREE_SPACE_GB=10
```
- Minimaler freier Speicherplatz in GB (Standard: 10)
- Script bricht ab bei Unterschreitung

**FULL_BACKUP_ON_NO_COMMON**
```bash
FULL_BACKUP_ON_NO_COMMON=true
```
- Verhalten bei fehlendem gemeinsamen Snapshot (Standard: true)
- `true`: Vollständiges Backup wird durchgeführt
- `false`: Dataset wird übersprungen (sicherer)

**SYSTEM_UPDATE_ENABLED**
```bash
SYSTEM_UPDATE_ENABLED=false
```
- Automatisches System-Update nach erfolgreichem Backup (Standard: false)
- Führt `apt update && apt dist-upgrade -y` aus

**CHECKMK_ENABLED**
```bash
CHECKMK_ENABLED=true
```
- CheckMK Piggyback-Integration aktivieren (Standard: true)

**CHECKMK_PIGGYBACK_DIR**
```bash
CHECKMK_PIGGYBACK_DIR=/var/spool/check_mk_agent/piggyback
```
- Verzeichnis für CheckMK Piggyback-Dateien

### Festplatten-Identifikation

Zur eindeutigen Identifikation der Backup-Festplatten können verschiedene Methoden verwendet werden:

```bash
# WWN (World Wide Name) ermitteln
lsblk -o NAME,WWN

# ATA-Seriennummer ermitteln
udevadm info --query=property --name=/dev/sdX | grep ID_SERIAL

# Alle verfügbaren IDs anzeigen
ls -la /dev/disk/by-id/

# Festplatten-Informationen anzeigen
smartctl -i /dev/sdX
```

**Beispiel für die Identifikation:**
```bash
# Festplatte an /dev/sdb identifizieren
udevadm info --query=property --name=/dev/sdb | grep -E "ID_SERIAL|ID_WWN"
```

## Funktionsweise

### Backup-Prozess

1. **Initialisierung**
   - Konfiguration laden und validieren
   - Lockfile erstellen (verhindert parallele Ausführung)
   - Backup-Festplatte identifizieren und ZFS-Pool importieren

2. **Vorbereitung**
   - Verfügbaren Speicherplatz prüfen
   - Abbruch bei unzureichendem Speicher

3. **Dataset-Backup (für jedes konfigurierte Dataset)**
   - Neuesten `zfs-auto-snap_daily` Snapshot der Quelle finden
   - Gemeinsamen Snapshot zwischen Quelle und Ziel suchen
   - Inkrementelle oder vollständige Übertragung durchführen
   - **Umfassende Bereinigung**: Verwaiste Snapshots aller Typen im Ziel bereinigen

4. **Nachbearbeitung**
   - CheckMK Piggyback-Datei schreiben
   - Optional: System-Update durchführen
   - Backup-Pool exportieren
   - Cleanup und Lockfile entfernen

### Snapshot-Handling

Das Script arbeitet primär mit Snapshots, die das Präfix `zfs-auto-snap_daily` haben. Diese werden typischerweise von `zfs-auto-snapshot` erstellt.

**Inkrementelle Übertragung:**
```bash
zfs send -I <gemeinsamer_snapshot> <aktueller_snapshot> | zfs receive -F <ziel_dataset>
```

**Vollständige Übertragung:**
```bash
zfs send <snapshot> | zfs receive -F <ziel_dataset>
```

### Erweiterte Snapshot-Bereinigung

**Das Script bereinigt nun alle Snapshot-Typen:**
- `zfs-auto-snap_daily-*`
- `zfs-auto-snap_hourly-*`
- `zfs-auto-snap_weekly-*`
- `zfs-auto-snap_monthly-*`
- `zfs-auto-snap_frequent-*`

**Bereinigungslogik:**
1. Für jeden Snapshot-Typ werden die Snapshots in Quelle und Ziel verglichen
2. Snapshots auf dem Backup-Pool werden nur gelöscht, wenn sie in der Quelle nicht mehr existieren
3. Dies gewährleistet perfekte Synchronisation zwischen Quelle und Backup
4. Verhindert Speicherverschwendung durch verwaiste Snapshots

**Beispiel:**
```bash
# Wenn dieser Snapshot in rpool/data gelöscht wird:
rpool/data@zfs-auto-snap_hourly-2025-02-26-1117

# Wird automatisch auch dieser im Backup gelöscht:
backup/data@zfs-auto-snap_hourly-2025-02-26-1117
```

### Dataset-Mapping

Das Script unterstützt flexibles Mapping zwischen Quelle und Ziel:

**Beispiele:**
```bash
# Traditionell: rpool/data → backup/rpool/data
DATASETS=rpool/data

# Umbenennung: rpool/data → backup/mydata
DATASETS=rpool/data:mydata

# Absolute Pfade: rpool/data → backup/storage/data
DATASETS=rpool/data:storage/data

# Mehrere Datasets mit verschiedenen Mappings
DATASETS=rpool/data:storage,rpool/vms:virtualmachines,rpool/ct:containers
```

## Verwendung

### Kommandozeilen-Parameter

```bash
./zfs-backup2.sh [OPTIONEN]
```

**-v (Verbose)**
- Aktiviert detailliertes Logging
- Zeigt ausgeführte ZFS-Befehle und Debug-Informationen
- Hilfreich für Fehlerdiagnose und Entwicklung

**-d (Dry-Run)**
- Simuliert den Backup-Prozess ohne Änderungen
- Zeigt geplante Aktionen an
- Ideal zum Testen der Konfiguration und neuer Setups

### Verwendungsbeispiele

```bash
# Normaler Backup-Lauf
./zfs-backup2.sh

# Mit detailliertem Logging (für Debugging)
./zfs-backup2.sh -v

# Simulation ohne Änderungen (für Tests)
./zfs-backup2.sh -d

# Kombination: Verbose Dry-Run
./zfs-backup2.sh -v -d
```

### Cron-Integration

Für automatische Backups kann das Script in Cron eingetragen werden:

```bash
# Tägliches Backup um 02:00 Uhr
0 2 * * * /opt/zfs-backup/zfs-backup2.sh >/dev/null 2>&1

# Wöchentliches Backup mit Log-Rotation
0 2 * * 0 /opt/zfs-backup/zfs-backup2.sh && logrotate /etc/logrotate.d/zfs-backup
```

## Monitoring und Fehlerbehandlung

### Logging

Das Script erstellt detaillierte Logs in `/var/log/zfs-backup2.log`:

```bash
# Log-Ausgabe verfolgen
tail -f /var/log/zfs-backup2.log

# Nur Fehler anzeigen
grep ERROR /var/log/zfs-backup2.log

# Letzte Backup-Session anzeigen
grep -A 20 "=== ZFS Backup gestartet ===" /var/log/zfs-backup2.log | tail -20
```

### CheckMK Integration

Bei aktivierter CheckMK-Integration wird eine Piggyback-Datei erstellt:

```bash
# Piggyback-Status prüfen
cat /var/spool/check_mk_agent/piggyback/$(hostname)/zfs_backup
```

**Ausgabeformat:**
```
<<<zfs_backup>>>
Status: OK
Timestamp: 2025-05-23 12:26:15
Snapshot: rpool/data@zfs-auto-snap_daily-2025-05-23-1025
GUID: 12345678-1234-1234-1234-123456789abc
```

### Häufige Probleme und Lösungen

**Problem: "Keine gültige Backup-Festplatte gefunden"**
```bash
# Lösung: Festplatten-IDs prüfen
lsblk -o NAME,WWN,SERIAL
ls -la /dev/disk/by-id/ | grep <erwartete_id>
```

**Problem: "Kein gemeinsamer Snapshot gefunden"**
```bash
# Lösung 1: FULL_BACKUP_ON_NO_COMMON=true setzen
# Lösung 2: Manuelles vollständiges Backup
zfs send rpool/data@<neuester_snapshot> | zfs receive -F backup/data
```

**Problem: "Zu wenig freier Speicherplatz"**
```bash
# Lösung: Alte Snapshots manuell bereinigen
zfs list -t snapshot backup/data | head -20
zfs destroy backup/data@<alter_snapshot>
```

**Problem: Lockfile-Fehler**
```bash
# Lösung: Verwaistes Lockfile entfernen (nur wenn Script nicht läuft!)
rm -f /var/run/zfs_backup.lock
```

## Sicherheitshinweise

1. **Root-Rechte**: Script benötigt Root-Rechte für ZFS-Operationen
2. **Lockfile**: Verhindert parallele Ausführung und Pool-Konflikte
3. **Pool-Export**: Backup-Pool wird automatisch exportiert für sicheres Entfernen
4. **Validierung**: Umfassende Parameter- und Zustandsprüfung vor Aktionen
5. **Rollback**: Bei Fehlern werden keine Änderungen am Quell-System vorgenommen

## Fehlerbehebung

### Debug-Modus

```bash
# Ausführliches Logging für Fehlerdiagnose
./zfs-backup2.sh -v 2>&1 | tee debug.log
```

### Manuelle Aktionen

```bash
# Pool-Status prüfen
zpool status
zpool list

# Snapshots vergleichen
zfs list -t snapshot rpool/data | grep daily
zfs list -t snapshot backup/data | grep daily

# Pool manuell importieren/exportieren
zpool import backup
zpool export backup
```

### Log-Analyse

```bash
# Wichtige Log-Einträge filtern
grep -E "(ERROR|WARN|gemeinsamer|Übertrage)" /var/log/zfs-backup2.log

# Backup-Statistiken
grep -E "(erfolgreich|fehlgeschlagen)" /var/log/zfs-backup2.log
```

## Erweiterte Konfiguration

### Beispiel-Konfiguration für verschiedene Szenarien

**Einfaches Proxmox-Setup:**
```bash
DATASETS=rpool/data,rpool/ROOT
BACKUP_DISK_IDS=WD-WMATX1234567
BACKUP_POOL=backup
MIN_FREE_SPACE_GB=20
FULL_BACKUP_ON_NO_COMMON=true
```

**Komplexes Multi-Pool-Setup:**
```bash
DATASETS=rpool/data:storage,rpool/vms:virtual-machines,tank/backups:archives
BACKUP_DISK_IDS=0x5000c500a1b2c3d4,0x5000c500e5f6a7b8
BACKUP_POOL=offsite
MIN_FREE_SPACE_GB=50
FULL_BACKUP_ON_NO_COMMON=false
CHECKMK_ENABLED=true
SYSTEM_UPDATE_ENABLED=true
```

**Produktions-Setup mit hoher Sicherheit:**
```bash
DATASETS=production/databases:db-backup,production/files:file-backup
BACKUP_DISK_IDS=0x5000c500a1b2c3d4
BACKUP_POOL=secure-backup
MIN_FREE_SPACE_GB=100
FULL_BACKUP_ON_NO_COMMON=false
CHECKMK_ENABLED=true
SYSTEM_UPDATE_ENABLED=false
```

Diese umfassende Dokumentation deckt alle Aspekte des ZFS Backup Scripts ab, einschließlich der neuen erweiterten Snapshot-Bereinigung für alle Snapshot-Typen.
