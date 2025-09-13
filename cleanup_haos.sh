#!/bin/bash
# cleanup_haos.sh
# Entfernt alte HAOS-VM + zugehörige Bridge (zKVMbridge)

VM_NAME="haos"
BRIDGE_NAME="zKVMbridge"
STORAGE_POOL="default"

echo "=== Alte HAOS-VM und Bridge entfernen ==="

# Prüfen, ob VM existiert
if sudo virsh list --all | grep -q " $VM_NAME "; then
    echo "VM $VM_NAME gefunden."

    # Falls die VM läuft -> herunterfahren
    if sudo virsh list | grep -q " $VM_NAME "; then
        echo "VM $VM_NAME läuft – fahre herunter..."
        sudo virsh shutdown "$VM_NAME"

        # Warten, bis die VM gestoppt ist
        echo "Warte auf Shutdown..."
        while sudo virsh list | grep -q " $VM_NAME "; do
            sleep 2
        done
    fi

    # VM undefinieren (Konfiguration löschen)
    echo "Lösche VM-Konfiguration..."
    sudo virsh undefine "$VM_NAME" --remove-all-storage --nvram 2>/dev/null || true
else
    echo "Keine VM mit dem Namen $VM_NAME gefunden."
fi

# Eventuelles Volume manuell löschen (falls undefine nicht alles entfernt hat)
if sudo virsh vol-list $STORAGE_POOL | grep -q "${VM_NAME}.qcow2"; then
    echo "Lösche verbleibendes Volume ${VM_NAME}.qcow2..."
    sudo virsh vol-delete --pool $STORAGE_POOL "${VM_NAME}.qcow2"
fi

# Bridge löschen, falls sie existiert
if sudo virsh net-list --all | grep -q "$BRIDGE_NAME"; then
    echo "Lösche Bridge $BRIDGE_NAME..."
    sudo virsh net-destroy "$BRIDGE_NAME" 2>/dev/null || true
    sudo virsh net-undefine "$BRIDGE_NAME" 2>/dev/null || true
else
    echo "Keine Bridge $BRIDGE_NAME gefunden."
fi

echo "=== Bereinigung abgeschlossen ==="