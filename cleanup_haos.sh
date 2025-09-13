#!/bin/bash
set -e

echo "=== Alte HAOS-VM stoppen ==="
sudo virsh shutdown haos || true
sleep 5

echo "=== Alte HAOS-VM und Storage entfernen ==="
sudo virsh undefine haos --remove-all-storage || true

echo "=== Alte Bridge haosbr löschen ==="
# Bridge herunterfahren (falls existiert)
if ip link show haosbr >/dev/null 2>&1; then
    sudo ip link set haosbr down
fi

# Bridge entfernen (falls brctl installiert)
if command -v brctl >/dev/null 2>&1; then
    sudo brctl delbr haosbr || true
fi

echo "Cleanup abgeschlossen!"