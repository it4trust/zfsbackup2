# ZFSBackup2: Automatisierte und inkrementelle ZFS-Backups für Proxmox 8 auf Debian 12

## Inhaltsverzeichnis

1. [Überblick](#überblick)
2. [Systemvoraussetzungen](#systemvoraussetzungen)
3. [Installation](#installation)
4. [Konfiguration](#konfiguration)
5. [Verwendung](#verwendung)
6. [Funktionen im Detail](#funktionen-im-detail)
7. [Snapshot-Management](#snapshot-management)
8. [CheckMK-Integration](#checkmk-integration)
9. [Fehlerbehandlung](#fehlerbehandlung)
10. [Wartung](#wartung)
11. [Cron-Integration](#cron-integration)
12. [Häufig gestellte Fragen](#häufig-gestellte-fragen)

## Überblick

ZFSBackup2 ist ein Bash-Skript, das automatisierte und inkrementelle ZFS-Backups von Proxmox 8 auf Debian 12 auf wechselnde externe Festplatten durchführt. Das Tool verwendet `zfs-auto-snapshot` für die Snapshot-Erstellung und ist für den regelmäßigen Einsatz mit wöchentlich wechselnden externen Festplatten optimiert.

**Hauptmerkmale:**

- Inkrementelle ZFS-Backups basierend auf wöchentlichen oder monatlichen Snapshots
- Automatische Erkennung und Verwendung von externen Festplatten über eindeutige IDs
- Intelligenter Vergleich von Snapshots zwischen Quelle und Ziel mittels GUID und Erstellungszeitstempel
- Speicherplatzprüfung vor Backups
- Integrierte Systemupdates nach erfolgreichen Backups
- CheckMK-Integration für Überwachung
- Umfangreiches Logging

## Systemvoraussetzungen

- Debian 12 oder höher
- Proxmox 8
- ZFS-Dateisystem auf Quellsystem
- Externe Festplatte mit ZFS-Pool
- Installiertes `zfs-auto-snapshot`-Paket
- Root-Rechte für die Ausführung des Skripts

### Benötigte Pakete

```bash
apt-get update
apt-get install -y zfsutils-linux zfs-auto-snapshot
```

## Installation

1. Erstellen Sie die notwendigen Verzeichnisse:

```bash
mkdir -p /usr/local/sbin
mkdir -p /etc/zfsbackup2
mkdir -p /var/log/zfsbackup2
```

2. Kopieren Sie das Skript und die Konfigurationsdatei:

```bash
cp zfsbackup2.sh /usr/local/sbin/
cp zfsbackup2.conf /etc/zfsbackup2/
```

3. Setzen Sie die richtigen Berechtigungen:

```bash
chmod +x /usr/local/sbin/zfsbackup2.sh
chmod 644 /etc/zfsbackup2/zfsbackup2.conf
```

## Konfiguration

Die Konfigurationsdatei liegt unter `/etc/zfsbackup2/zfsbackup2.conf` und enthält alle notwendigen Parameter für das Backup.

### Wichtige Konfigurationsparameter

```bash
# Zu sichernde Datasets (durch Kommas getrennt)
DATASETS="rpool/data,rpool/vm"

# Name des Zielpools auf der externen Festplatte
TARGET_POOL="backuppool"

# Erlaubte externe Festplatten-IDs (durch Kommas getrennt)
# Verwenden Sie WWN oder Seriennummern von lsblk -o name,serial,wwn
ALLOWED_DISK_IDS="0x5000c500c128d767,WD-WXYZ1A2B3C"

# Maximale Auslastung des Zielpools in Prozent (0-100)
MAX_USAGE=80

# Maximale Anzahl von Wiederholungen bei fehlgeschlagenen Backups
MAX_RETRIES=1

# Zu verwendende Snapshot-Typen (durch Kommas getrennt)
# Nur weekly und monthly werden empfohlen
SNAPSHOT_TYPES="weekly,monthly"
```

### Festplatten-IDs ermitteln

Um die IDs Ihrer externen Festplatten zu ermitteln, verwenden Sie folgenden Befehl:

```bash
lsblk -d -o NAME,SIZE,MODEL,SERIAL,WWN
```

Verwenden Sie entweder die WWN oder die Seriennummer in der Konfigurationsdatei.

## Verwendung

Das Skript kann manuell oder durch Cron ausgeführt werden.

### Manuelle Ausführung

```bash
/usr/local/sbin/zfsbackup2.sh
```

### Befehlszeilenparameter

```
Usage: zfsbackup2.sh [options]

Options:
  -c, --config FILE    Spezifische Konfigurationsdatei verwenden (Standard: /etc/zfsbackup2/zfsbackup2.conf)
  -h, --help           Hilfe anzeigen und beenden
  -v, --version        Versionsinformation anzeigen und beenden
  -t, --test           Konfiguration testen und beenden
```

### Konfigurationstest

Sie können die Konfiguration vor dem eigentlichen Backup testen:

```bash
/usr/local/sbin/zfsbackup2.sh --test
```

## Funktionen im Detail

### Snapshot-Vergleich

Das Skript vergleicht die Snapshots auf Quelle und Ziel anhand der GUID und des Erstellungszeitstempels. Es wählt den neuesten gemeinsamen Snapshot für inkrementelle Backups aus, mit folgender Priorität:
1. `weekly`
2. `monthly`

Es werden niemals `hourly`, `daily` oder `frequent` Snapshots für Backups verwendet.

### Inkrementelles Backup

Das Skript führt inkrementelle Backups durch, indem es `zfs send -I` und `zfs receive` nutzt. Wenn kein gemeinsamer Snapshot gefunden wird, wird ein vollständiges Backup durchgeführt.

Beispiel für einen inkrementellen Backup-Befehl:
```bash
zfs send -v -I 'rpool/data@zfs-auto-snap_weekly-2023-05-01-1200' 'rpool/data@zfs-auto-snap_weekly-2023-05-08-1200' | zfs receive -F -v 'backuppool/data'
```

### Festplatten-Handling

Das Skript erkennt automatisch die zulässigen externen Festplatten anhand ihrer eindeutigen IDs (WWN oder Seriennummer). Es importiert den ZFS-Pool zu Beginn des Backups und exportiert ihn am Ende wieder.

### Speicherplatzprüfung

Vor dem Backup wird überprüft, ob auf dem Zielpool genügend Speicherplatz vorhanden ist. Wenn die Auslastung den konfigurierten Grenzwert überschreitet (Standard: 80%), wird das Backup abgebrochen.

### Systemupdates

Nach einem erfolgreichen Backup führt das Skript ein Systemupdate durch:
```bash
apt-get update && apt-get dist-upgrade -y
```

Wenn ein Neustart erforderlich ist, wird dies im CheckMK-Status vermerkt.

## Snapshot-Management

ZFSBackup2 nutzt die von `zfs-auto-snapshot` erstellten Snapshots. Es verwendet nur die `weekly` und `monthly` Snapshots für Backups, da diese langlebiger sind und einen besseren inkrementellen Backup-Pfad bieten.

Die Snapshots auf dem Zielsystem spiegeln die Snapshots auf dem Quellsystem wider. Wenn ein Snapshot auf dem Quellsystem gelöscht wird, wird er bei der nächsten Ausführung auch auf dem Zielsystem nicht mehr referenziert.

## CheckMK-Integration

Das Skript erstellt eine Piggyback-Datei für CheckMK unter dem Pfad `/var/lib/check_mk_agent/spool/zfsbackup2_status`. Diese enthält Informationen über:

- Den aktuellen Status des Backups
- Zeitstempel des letzten erfolgreichen Backups
- Vergleich der Snapshots auf Quelle und Ziel
- Informationen zu Systemupdates und ob ein Neustart erforderlich ist

### Beispiel einer CheckMK-Ausgabe

```
<<<zfsbackup2>>>
P "ZFS Backup Status" 0 - Last run: 2023-05-10 14:30:45
P "rpool/data" 0 - Last backup: 2023-05-08 12:00:00, source latest: 2023-05-08 12:00:00
P "rpool/vm" 0 - Last backup: 2023-05-08 12:00:00, source latest: 2023-05-08 12:00:00
P "System Update Status" 0 - System updated, no reboot required
```

### Status-Codes

- `0`: Alles in Ordnung
- `1`: Warnung (z.B. Backup älter als ein Tag)
- `2`: Kritischer Fehler (z.B. Backup fehlgeschlagen)

## Fehlerbehandlung

Das Skript verfügt über umfangreiche Fehlerbehandlung und Logging. Bei Fehlern werden entsprechende Informationen in der Logdatei und in der CheckMK-Statusdatei gespeichert.

### Häufige Fehlermeldungen

- **"No allowed external drives found"**: Keine der in der Konfiguration angegebenen externen Festplatten wurde gefunden.
- **"Failed to import pool"**: Der ZFS-Pool konnte nicht von der externen Festplatte importiert werden.
- **"Pool is too full"**: Der Zielpool hat die maximale Auslastungsgrenze überschritten.
- **"No suitable snapshots found"**: Es wurden keine geeigneten Snapshots auf dem Quellsystem gefunden.

### Wiederholungslogik

Das Skript versucht fehlgeschlagene Backups zu wiederholen. Die Anzahl der Wiederholungen kann in der Konfigurationsdatei festgelegt werden.

## Wartung

### Logdateien

Die Logdateien befinden sich unter `/var/log/zfsbackup2/zfsbackup2.log`. Es wird empfohlen, eine Logrotation einzurichten, um zu verhindern, dass die Logdateien zu groß werden.

Beispiel für eine Logrotate-Konfiguration unter `/etc/logrotate.d/zfsbackup2`:

```
/var/log/zfsbackup2/zfsbackup2.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0640 root root
}
```

### Überprüfung der externen Festplatten

Es wird empfohlen, die externen Festplatten regelmäßig auf SMART-Fehler zu überprüfen:

```bash
smartctl -a /dev/sdX
```

## Cron-Integration

Es wird empfohlen, das Skript über Cron regelmäßig auszuführen. Hier ein Beispiel für einen wöchentlichen Backup-Job:

```
# ZFSBackup2 - Wöchentliches Backup jeden Sonntag um 01:00 Uhr
0 1 * * 0 root /usr/local/sbin/zfsbackup2.sh >> /var/log/zfsbackup2/cron.log 2>&1
```

Fügen Sie diese Zeile in `/etc/crontab` ein oder erstellen Sie eine neue Datei unter `/etc/cron.d/zfsbackup2`.

## Häufig gestellte Fragen

### Warum werden nur `weekly` und `monthly` Snapshots verwendet?

Die `weekly` und `monthly` Snapshots bieten eine bessere langfristige Konsistenz und sind länger verfügbar, was für inkrementelle Backups auf wechselnden externen Festplatten wichtig ist. Die `hourly` und `daily` Snapshots werden oft schneller rotiert und könnten bei wöchentlichen Backup-Zyklen bereits gelöscht sein.

### Was passiert, wenn die externe Festplatte nicht erkannt wird?

Das Skript bricht sauber ab und hinterlässt eine entsprechende Meldung in der Logdatei und im CheckMK-Status.

### Wie sieht ein typischer Backup-Workflow aus?

1. Anschließen der externen Festplatte
2. Ausführen des Backup-Skripts (automatisch per Cron oder manuell)
3. Skript erkennt die erlaubte Festplatte und importiert den ZFS-Pool
4. Für jedes konfigurierte Dataset wird ein inkrementelles Backup durchgeführt
5. Nach erfolgreichen Backups werden Systemupdates ausgeführt
6. Der ZFS-Pool wird exportiert und die Festplatte kann entfernt werden
7. Festplatte kann sicher verwahrt und in der nächsten Woche mit einer anderen Festplatte ausgetauscht werden

### Kann ich mehrere externe Festplatten gleichzeitig verwenden?

Ja, das Skript erkennt alle konfigurierten Festplatten. Es verwendet jedoch immer nur die erste erkannte Festplatte für das Backup.

### Wie kann ich überprüfen, ob das Backup erfolgreich war?

Sie können die Logdatei unter `/var/log/zfsbackup2/zfsbackup2.log` überprüfen oder den CheckMK-Status kontrollieren. Bei erfolgreichen Backups sollte der CheckMK-Status "0" sein.
