#!/bin/bash
# cleanup_haos.sh – entfernt alte HAOS-VM + haosbr-Bridge
# und stellt sicher, dass der Server danach direkt über enp1s0 online bleibt.

set -e

echo "=== Alte HAOS-VM stoppen und löschen ==="
if virsh list --all | grep -q "haos"; then
    virsh destroy haos 2>/dev/null || true
    virsh undefine haos --remove-all-storage || true
    echo "HAOS-VM entfernt."
else
    echo "Keine HAOS-VM gefunden."
fi

echo "=== Netplan prüfen und korrigieren ==="
NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"

if grep -q "haosbr" "$NETPLAN_FILE"; then
    echo "haosbr in Netplan gefunden – Datei wird angepasst..."

    # Backup anlegen
    cp "$NETPLAN_FILE" "${NETPLAN_FILE}.bak.$(date +%F-%H%M%S)"

    # Neue minimal-konfiguration schreiben
    cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  ethernets:
    enp1s0:
      dhcp4: true
      dhcp6: true
EOF

    netplan apply
    echo "Netplan korrigiert und übernommen. Server sollte sofort wieder online sein."
else
    echo "In Netplan war keine haosbr eingetragen – keine Änderung notwendig."
fi

echo "=== haosbr-Bridge löschen (falls vorhanden) ==="
if virsh net-list --all | grep -q "haosbr"; then
    virsh net-destroy haosbr || true
    virsh net-undefine haosbr || true
    echo "haosbr wurde aus libvirt entfernt."
fi

# Bridge auch im Kernel löschen, falls noch da
if ip link show haosbr &>/dev/null; then
    sudo ip link delete haosbr type bridge || true
    echo "haosbr wurde aus dem Kernel entfernt."
fi

echo "=== Fertig. Netzwerk läuft jetzt direkt über enp1s0 ==="
ifconfig | more