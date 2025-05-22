# ZFS Backup Script - Dokumentation

## Überblick

Das ZFS Backup Script automatisiert die inkrementelle Sicherung von ZFS-Datasets auf wechselnde externe Festplatten. Es wurde speziell für Proxmox 8 Systeme unter Debian 12 entwickelt und arbeitet mit den von `zfs-auto-snapshot` erstellten Snapshots.

### Hauptfunktionen

- **Inkrementelle Backups**: Übertragung nur geänderter Daten basierend auf Snapshots
- **Festplatten-Rotation**: Unterstützung für wechselnde Backup-Festplatten
- **Automatische Bereinigung**: Entfernung verwaister Snapshots
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
DATASETS=rpool/data01,rpool/data02,rpool/vms
```
- Kommagetrennte Liste der zu sichernden ZFS-Datasets
- Keine Leerzeichen zwischen den Einträgen
- Beispiel: Sicherung von Daten und VM-Speicher

**BACKUP_DISK_IDS**
```bash
BACKUP_DISK_IDS=0x5000c500a1b2c3d4,WD-ABCD1234567890
```
- Eindeutige Identifikatoren der erlaubten Backup-Festplatten
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
- Minimaler freier Speicherplatz in GB
- Script bricht ab bei Unterschreitung

**FULL_BACKUP_ON_NO_COMMON**
```bash
FULL_BACKUP_ON_NO_COMMON=false
```
- Verhalten bei fehlendem gemeinsamen Snapshot
- `true`: Vollständiges Backup wird durchgeführt
- `false`: Dataset wird übersprungen (sicherer)

**SYSTEM_UPDATE_ENABLED**
```bash
SYSTEM_UPDATE_ENABLED=false
```
- Automatisches System-Update nach erfolgreichem Backup
- Führt `apt update && apt dist-upgrade -y` aus

### Festplatten-Identifikation

Zur eindeutigen Identifikation der Backup-Festplatten können verschiedene Methoden verwendet werden:

```bash
# WWN (World Wide Name) ermitteln
lsblk -o NAME,WWN

# ATA-Seriennummer ermitteln
udevadm info --query=property --name=/dev/sdX | grep ID_SERIAL

# Alle verfügbaren IDs anzeigen
ls -la /dev/disk/by-id/
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
   - Verwaiste Snapshots im Ziel bereinigen

4. **Nachbearbeitung**
   - CheckMK Piggyback-Datei schreiben
   - Optional: System-Update durchführen
   - Backup-Pool exportieren
   - Cleanup und Lockfile entfernen

### Snapshot-Handling

Das Script arbeitet ausschließlich mit Snapshots, die das Präfix `zfs-auto-snap_daily` haben. Diese werden typischerweise von `zfs-auto-snapshot` erstellt.

**Inkrementelle Übertragung:**
```bash
zfs send -I <gemeinsamer_snapshot> <aktueller_snapshot> | zfs receive -F <ziel_dataset>
```

**Vollständige Übertragung:**
```bash
zfs send <snapshot> | zfs receive -F <ziel_dataset>
```

### Snapshot-Rotation

Alte Snapshots auf dem Backup-Pool werden automatisch bereinigt:
- Snapshots, die auf der Quelle nicht mehr existieren, werden entfernt
- Erhält die Konsistenz zwischen Quelle und Ziel
- Spart Speicherplatz auf der Backup-Festplatte

## Verwendung

### Kommandozeilen-Parameter

```bash
./zfs-backup2.sh [OPTIONEN]
```

**-v (Verbose)**
- Aktiviert detailliertes Logging
- Zeigt ausgeführte Befehle und Debug-Informationen
- Hilfreich für Fehlerdiagnose

**-d (Dry-Run)**
- Simuliert den Backup-Prozess ohne Änderungen
- Zeigt geplante Aktionen an
- Ideal zum Testen der Konfiguration

### Beispiele

```bash
# Normaler Backup-Lauf
./zfs-backup2.sh

# Mit det
