#!/bin/bash
# Raspberry Pi Low-Write Setup Script
# Mit Backup- und Rollback-Mechanismen
# Für Debian 12 Bookworm, Tailscale, ZeroTier, Beszel

set -euo pipefail  # Fehlerbehandlung

# Konfiguration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="/home/$(whoami)/system-backup-$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$SCRIPT_DIR/setup.log"
ROLLBACK_SCRIPT="$BACKUP_DIR/rollback.sh"

# Logging-Funktion
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Fehlerbehandlung
error_exit() {
    log "FEHLER: $1"
    log "Rollback-Skript erstellt: $ROLLBACK_SCRIPT"
    exit 1
}

# Backup-Funktion
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        log "Backup: $file"
        mkdir -p "$BACKUP_DIR$(dirname "$file")"
        cp -p "$file" "$BACKUP_DIR$file" || error_exit "Backup von $file fehlgeschlagen"
    fi
}

# Rollback-Skript erstellen
create_rollback_script() {
    cat > "$ROLLBACK_SCRIPT" << 'EOF'
#!/bin/bash
# Automatisches Rollback-Skript
set -euo pipefail

BACKUP_DIR="$(dirname "$0")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

log "Starte Rollback..."

# Dienste stoppen
sudo systemctl stop log2ram zramswap 2>/dev/null || true

# Dateien wiederherstellen
if [[ -f "$BACKUP_DIR/etc/log2ram.conf" ]]; then
    sudo cp "$BACKUP_DIR/etc/log2ram.conf" /etc/log2ram.conf
    log "log2ram.conf wiederhergestellt"
fi

if [[ -f "$BACKUP_DIR/etc/fstab" ]]; then
    sudo cp "$BACKUP_DIR/etc/fstab" /etc/fstab
    log "fstab wiederhergestellt"
fi

if [[ -d "$BACKUP_DIR/etc/systemd/journald.conf.d" ]]; then
    sudo rm -rf /etc/systemd/journald.conf.d/ram.conf 2>/dev/null || true
    if [[ -f "$BACKUP_DIR/etc/systemd/journald.conf.d/ram.conf" ]]; then
        sudo mkdir -p /etc/systemd/journald.conf.d
        sudo cp "$BACKUP_DIR/etc/systemd/journald.conf.d/ram.conf" /etc/systemd/journald.conf.d/
    fi
fi

# systemd Drop-ins wiederherstellen
if [[ -d "$BACKUP_DIR/etc/systemd/system/tailscaled.service.d" ]]; then
    sudo rm -rf /etc/systemd/system/tailscaled.service.d 2>/dev/null || true
    sudo cp -r "$BACKUP_DIR/etc/systemd/system/tailscaled.service.d" /etc/systemd/system/
fi

# ZeroTier-Konfiguration
if [[ -f "$BACKUP_DIR/var/lib/zerotier-one/local.conf" ]]; then
    sudo cp "$BACKUP_DIR/var/lib/zerotier-one/local.conf" /var/lib/zerotier-one/
fi

log "Rollback abgeschlossen. Neustart erforderlich: sudo reboot"
EOF
    chmod +x "$ROLLBACK_SCRIPT"
}

# Systemvoraussetzungen prüfen
check_prerequisites() {
    log "Prüfe Systemvoraussetzungen..."
    
    # Debian/Raspbian Bookworm prüfen
    if ! grep -q "bookworm" /etc/os-release 2>/dev/null; then
        error_exit "Dieses Skript ist für Debian 12 (Bookworm) vorgesehen"
    fi
    
    # RAM prüfen (mindestens 3GB für 256MB tmpfs)
    local ram_mb=$(free -m | awk 'NR==2{print $2}')
    if [[ $ram_mb -lt 3000 ]]; then
        error_exit "Mindestens 3GB RAM erforderlich, gefunden: ${ram_mb}MB"
    fi
    
    # Root-Rechte prüfen
    if [[ $EUID -eq 0 ]]; then
        error_exit "Bitte als normaler Benutzer ausführen (nicht als root)"
    fi
    
    # sudo prüfen
    if ! sudo -n true 2>/dev/null; then
        log "Sudo-Berechtigung erforderlich..."
        sudo true || error_exit "Sudo-Berechtigung erforderlich"
    fi
    
    log "Systemvoraussetzungen erfüllt"
}

# Backup-Verzeichnis erstellen
create_backup_dir() {
    log "Erstelle Backup-Verzeichnis: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR" || error_exit "Backup-Verzeichnis konnte nicht erstellt werden"
    create_rollback_script
}

# Aktuelle Konfiguration sichern
backup_current_config() {
    log "Sichere aktuelle Konfiguration..."
    
    backup_file "/etc/fstab"
    backup_file "/etc/log2ram.conf"
    backup_file "/etc/default/zramswap"
    
    # systemd-Konfigurationen
    if [[ -d "/etc/systemd/journald.conf.d" ]]; then
        mkdir -p "$BACKUP_DIR/etc/systemd/journald.conf.d"
        cp -r /etc/systemd/journald.conf.d/* "$BACKUP_DIR/etc/systemd/journald.conf.d/" 2>/dev/null || true
    fi
    
    if [[ -d "/etc/systemd/system/tailscaled.service.d" ]]; then
        mkdir -p "$BACKUP_DIR/etc/systemd/system/tailscaled.service.d"
        cp -r /etc/systemd/system/tailscaled.service.d/* "$BACKUP_DIR/etc/systemd/system/tailscaled.service.d/" 2>/dev/null || true
    fi
    
    # ZeroTier-Konfiguration
    backup_file "/var/lib/zerotier-one/local.conf"
    
    log "Backup abgeschlossen"
}

# Log2RAM installieren und konfigurieren
setup_log2ram() {
    log "Installiere und konfiguriere Log2RAM..."
    
    # Repository hinzufügen
    if ! grep -q "azlux" /etc/apt/sources.list.d/azlux.list 2>/dev/null; then
        echo "deb [signed-by=/usr/share/keyrings/azlux.gpg] http://packages.azlux.fr/debian/ bookworm main" | \
            sudo tee /etc/apt/sources.list.d/azlux.list
        sudo wget -O /usr/share/keyrings/azlux.gpg https://azlux.fr/repo.gpg || \
            error_exit "GPG-Schlüssel konnte nicht heruntergeladen werden"
    fi
    
    # Pakete installieren
    sudo apt update || error_exit "apt update fehlgeschlagen"
    sudo apt install -y rsync log2ram || error_exit "Log2RAM Installation fehlgeschlagen"
    
    # Konfiguration schreiben
    sudo tee /etc/log2ram.conf > /dev/null << 'EOF'
# Log2RAM Konfiguration - 256MB für bessere Performance
SIZE=256M
PATH_DISK="/var/log"
USE_RSYNC=true
COMPRESSOR="zstd"
MAIL=false
SYNC_TIME="0 2 * * *"
EOF
    
    log "Log2RAM konfiguriert"
}

# systemd-Journal konfigurieren
setup_systemd_journal() {
    log "Konfiguriere systemd-Journal für RAM..."
    
    sudo mkdir -p /etc/systemd/journald.conf.d
    sudo tee /etc/systemd/journald.conf.d/ram.conf > /dev/null << 'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=50M
MaxRetentionSec=2d
EOF
    
    log "systemd-Journal konfiguriert"
}

# tmpfs-Mounts konfigurieren
setup_tmpfs_mounts() {
    log "Konfiguriere tmpfs-Mounts..."
    
    # Prüfen ob bereits konfiguriert
    if grep -q "# RAM-Dateisysteme" /etc/fstab; then
        log "tmpfs-Mounts bereits konfiguriert"
        return
    fi
    
    # tmpfs-Einträge zu fstab hinzufügen
    sudo tee -a /etc/fstab > /dev/null << 'EOF'

# RAM-Dateisysteme (Low-Write Setup)
tmpfs  /tmp           tmpfs  defaults,noatime,nosuid,nodev,size=256m           0  0
tmpfs  /var/tmp       tmpfs  defaults,noatime,nosuid,nodev,size=128m           0  0
tmpfs  /var/cache/apt tmpfs  defaults,noatime,nosuid,nodev,noexec,size=128m    0  0
EOF
    
    log "tmpfs-Mounts zu fstab hinzugefügt"
}

# Root-Filesystem-Optionen optimieren
optimize_root_mount() {
    log "Optimiere Root-Filesystem-Optionen..."
    
    # Aktuelle Root-Mount-Zeile finden und erweitern
    local root_line=$(grep -E "^[^#].*[[:space:]]/[[:space:]]" /etc/fstab | head -1)
    
    if [[ -n "$root_line" ]] && ! echo "$root_line" | grep -q "noatime,commit=900"; then
        log "Füge noatime,commit=900 zu Root-Mount hinzu"
        
        # Backup der ursprünglichen fstab
        sudo cp /etc/fstab /etc/fstab.backup-$(date +%Y%m%d-%H%M%S)
        
        # Optionen hinzufügen
        sudo sed -i 's|\([[:space:]]/[[:space:]].*[[:space:]]defaults\)|\1,noatime,commit=900|' /etc/fstab
        
        log "Root-Filesystem-Optionen optimiert"
    else
        log "Root-Filesystem bereits optimiert oder nicht gefunden"
    fi
}

# ZRAM-Swap konfigurieren
setup_zram() {
    log "Konfiguriere ZRAM-Swap..."
    
    sudo apt install -y zram-tools || error_exit "ZRAM-Tools Installation fehlgeschlagen"
    
    # Konfiguration
    echo "PERCENT=25" | sudo tee /etc/default/zramswap > /dev/null
    
    # Service aktivieren
    sudo systemctl enable zramswap || error_exit "ZRAM-Service konnte nicht aktiviert werden"
    
    log "ZRAM-Swap konfiguriert"
}

# VPN-Services optimieren
optimize_vpn_services() {
    log "Optimiere VPN-Services..."
    
    # Tailscale-Override
    if systemctl is-active --quiet tailscaled 2>/dev/null; then
        log "Konfiguriere Tailscale für minimales Logging"
        
        sudo mkdir -p /etc/systemd/system/tailscaled.service.d
        sudo tee /etc/systemd/system/tailscaled.service.d/override.conf > /dev/null << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock --port=41641 --verbose=0
EOF
    fi
    
    # ZeroTier-Konfiguration
    if systemctl is-active --quiet zerotier-one 2>/dev/null; then
        log "Konfiguriere ZeroTier für minimales Logging"
        
        sudo mkdir -p /var/lib/zerotier-one
        sudo tee /var/lib/zerotier-one/local.conf > /dev/null << 'EOF'
{
  "settings": {
    "logLevel": "error",
    "logRotate": true,
    "logRotateSize": 1048576
  }
}
EOF
    fi
    
    log "VPN-Services optimiert"
}

# Validierung nach Installation
validate_setup() {
    log "Validiere Setup..."
    
    # Log2RAM prüfen
    if ! systemctl is-enabled log2ram >/dev/null 2>&1; then
        error_exit "Log2RAM ist nicht aktiviert"
    fi
    
    # Konfigurationsdateien prüfen
    local config_files=(
        "/etc/log2ram.conf"
        "/etc/systemd/journald.conf.d/ram.conf"
    )
    
    for file in "${config_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            error_exit "Konfigurationsdatei nicht gefunden: $file"
        fi
    done
    
    # fstab-Einträge prüfen
    if ! grep -q "tmpfs.*tmp.*tmpfs" /etc/fstab; then
        error_exit "tmpfs-Einträge in fstab nicht gefunden"
    fi
    
    log "Setup erfolgreich validiert"
}

# Monitoring-Script erstellen
create_monitoring_script() {
    log "Erstelle Monitoring-Script..."
    
    sudo tee /usr/local/bin/lowwrite-monitor.sh > /dev/null << 'EOF'
#!/bin/bash
# Low-Write System Monitor
LOG="/tmp/system-monitor.log"
DATE=$(date '+%F %R')

# RAM-Nutzung
ram_percent=$(free -m | awk 'NR==2{printf "%.1f",($3/$2)*100}')

# tmpfs-Nutzung
log_usage=$(df -h /var/log 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%' || echo "0")
tmp_usage=$(df -h /tmp 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%' || echo "0")

# VPN-Status
ts_peers=$(tailscale status --json 2>/dev/null | jq '.Peer | length' 2>/dev/null || echo "0")
zt_online=$(zerotier-cli info 2>/dev/null | grep -c ONLINE || echo "0")

# Log schreiben
printf "%s ram=%s%% log=%s%% tmp=%s%% ts_peers=%s zt=%s\n" \
    "$DATE" "$ram_percent" "$log_usage" "$tmp_usage" "$ts_peers" "$zt_online" >> "$LOG"

# Nur letzte 100 Zeilen behalten
tail -n 100 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

# Warnungen
if (( $(echo "$ram_percent > 85" | bc -l 2>/dev/null || echo 0) )); then
    logger -p user.warning "RAM usage high: ${ram_percent}%"
fi

if (( log_usage > 80 )); then
    logger -p user.warning "Log tmpfs usage high: ${log_usage}%"
fi
EOF
    
    sudo chmod +x /usr/local/bin/lowwrite-monitor.sh
    
    # Cron-Job hinzufügen
    (crontab -l 2>/dev/null; echo "*/15 * * * * /usr/local/bin/lowwrite-monitor.sh") | crontab -
    
    log "Monitoring-Script erstellt"
}

# Hauptfunktion
main() {
    log "Starte Low-Write System Setup..."
    log "Backup-Verzeichnis: $BACKUP_DIR"
    
    check_prerequisites
    create_backup_dir
    backup_current_config
    
    setup_log2ram
    setup_systemd_journal
    setup_tmpfs_mounts
    optimize_root_mount
    setup_zram
    optimize_vpn_services
    create_monitoring_script
    
    validate_setup
    
    log "Setup erfolgreich abgeschlossen!"
    log ""
    log "WICHTIGE HINWEISE:"
    log "1. Neustart erforderlich: sudo reboot"
    log "2. Nach Neustart prüfen: systemctl status log2ram"
    log "3. RAM-Nutzung überwachen: df -h | grep tmpfs"
    log "4. Monitoring-Log: tail -f /tmp/system-monitor.log"
    log "5. Rollback-Skript: $ROLLBACK_SCRIPT"
    log ""
    log "Bei Problemen Rollback ausführen:"
    log "bash $ROLLBACK_SCRIPT && sudo reboot"
}

# Skript ausführen
main "$@"
