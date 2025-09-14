#!/bin/bash
set -euo pipefail  # Stricter error handling

# Require root privileges
if [[ $EUID -ne 0 ]]; then
    echo "Script muss als root ausgeführt werden." >&2
    exit 1
fi

echo "=== VM Cleanup ==="
if virsh list --all | grep -q "haos"; then
    virsh destroy haos 2>/dev/null || true
    virsh undefine haos --remove-all-storage 2>/dev/null || true
    echo "HAOS-VM entfernt."
fi

echo "=== Netplan-Bereinigung (selektiv) ==="
NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"

if grep -q "haosbr" "$NETPLAN_FILE"; then
    # Backup mit detaillierterer Benennung  
    cp "$NETPLAN_FILE" "${NETPLAN_FILE}.pre-cleanup.$(date +%F-%H%M%S)"
    
    # Selektive Entfernung statt Überschreibung
    sed -i '/haosbr/d' "$NETPLAN_FILE"
    sed -i '/bridges:/,/^[[:space:]]*$/d' "$NETPLAN_FILE"
    
    # Syntax-Validierung vor Apply
    if netplan generate; then
        netplan apply
        echo "Netplan bereinigt und validiert übernommen."
    else
        echo "FEHLER: Netplan-Syntax ungültig. Backup wiederherstellen!" >&2
        exit 1
    fi
fi

echo "=== Bridge-Cleanup ==="
# libvirt network cleanup
if virsh net-list --all | grep -q "haosbr"; then
    virsh net-destroy haosbr 2>/dev/null || true
    virsh net-undefine haosbr 2>/dev/null || true
fi

# Kernel bridge cleanup  
if ip link show haosbr &>/dev/null; then
    ip link set haosbr down 2>/dev/null || true
    ip link delete haosbr type bridge 2>/dev/null || true
fi

echo "=== Cleanup abgeschlossen ==="
ifconfig | more