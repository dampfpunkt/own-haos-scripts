#!/bin/bash
set -e

# Parameter: VM-Name, RAM, CPUs, Disk-Size
VM_NAME=${1:-haos}
VM_RAM=${2:-4096}
VM_CPU=${3:-2}
VM_DISK_SIZE=${4:-32}  # GB

HAOS_DIR=~/haos
HAOS_IMAGE_ORIG=haos_ova-16.2.qcow2
HAOS_IMAGE_QCOW2=/var/lib/libvirt/images/${VM_NAME}.qcow2
BRIDGE_NAME=zKVMbridge

# === 1️⃣ Bridge erstellen falls noch nicht vorhanden ===
if ! sudo virsh net-info ${BRIDGE_NAME} >/dev/null 2>&1; then
    echo "=== Libvirt Host-Bridge $BRIDGE_NAME erstellen ==="
    sudo tee /tmp/${BRIDGE_NAME}.xml > /dev/null <<EOF
<network>
  <name>${BRIDGE_NAME}</name>
  <forward mode="bridge"/>
  <bridge name="${BRIDGE_NAME}"/>
</network>
EOF
    sudo virsh net-define /tmp/${BRIDGE_NAME}.xml
    sudo virsh net-start ${BRIDGE_NAME}
    sudo virsh net-autostart ${BRIDGE_NAME}
    echo "Bridge $BRIDGE_NAME aktiv."
else
    echo "Bridge $BRIDGE_NAME existiert bereits, überspringe Erstellung."
fi

# === 2️⃣ HAOS-Image herunterladen / entpacken ===
mkdir -p "$HAOS_DIR"
cd "$HAOS_DIR"
if [ ! -f "$HAOS_IMAGE_ORIG" ]; then
    echo "=== HAOS-Image herunterladen ==="
    wget -N https://github.com/home-assistant/operating-system/releases/download/16.2/haos_ova-16.2.qcow2.xz
    xz -d -f haos_ova-16.2.qcow2.xz
fi

# === 3️⃣ VM-Festplatte erstellen und Rechte setzen ===
sudo qemu-img create -f qcow2 -F qcow2 "$HAOS_IMAGE_QCOW2" ${VM_DISK_SIZE}G
sudo cp -f "$HAOS_IMAGE_ORIG" "$HAOS_IMAGE_QCOW2"
sudo chown libvirt-qemu:kvm "$HAOS_IMAGE_QCOW2"

# === 4️⃣ Freie MAC-Adresse ermitteln ===
BASE_MAC="52:54:00:00:00"
LAST_BYTE=1
USED_MACS=$(sudo virsh list --all --name | xargs -n1 sudo virsh dumpxml 2>/dev/null | grep "<mac address=" | grep -oP '([0-9a-f]{2}:){5}[0-9a-f]{2}')

for mac in $USED_MACS; do
    IFS=':' read -ra PARTS <<< "$mac"
    LAST=${PARTS[5]}
    DEC=$((16#$LAST))
    if [ $DEC -ge $LAST_BYTE ]; then
        LAST_BYTE=$((DEC+1))
    fi
done

MAC_ADDR=$(printf "52:54:00:00:00:%02x" $LAST_BYTE)
echo "Vergebe MAC-Adresse $MAC_ADDR für VM $VM_NAME"

# === 5️⃣ VM XML erstellen ===
XML_FILE=/tmp/${VM_NAME}.xml
sudo tee "$XML_FILE" > /dev/null <<EOF
<domain type='kvm'>
  <name>${VM_NAME}</name>
  <memory unit='MiB'>${VM_RAM}</memory>
  <vcpu placement='static'>${VM_CPU}</vcpu>
  <os>
    <type arch='x86_64'>hvm</type>
  </os>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$HAOS_IMAGE_QCOW2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='network'>
      <mac address='$MAC_ADDR'/>
      <source network='$BRIDGE_NAME'/>
      <model type='virtio'/>
      <alias name='net0'/>
    </interface>
    <serial type='pty'>
      <target type='isa-serial' port='0'/>
    </serial>
  </devices>
</domain>
EOF

# === 6️⃣ VM definieren und starten ===
sudo virsh define "$XML_FILE"
sudo virsh start "$VM_NAME"

# === 7️⃣ Scrollbarer ip a Alias ===
grep -qxF "alias ipa='ip a | less'" ~/.bashrc || echo "alias ipa='ip a | less'" >> ~/.bashrc
source ~/.bashrc

# === 8️⃣ IPv4-Adresse abrufen mit Retry (max 60 Sekunden) ===
echo "Warte auf IPv4-Adresse der VM $VM_NAME..."
MAX_WAIT=60
WAITED=0
VM_IP=""

while [ -z "$VM_IP" ] && [ $WAITED -lt $MAX_WAIT ]; do
    sleep 2
    WAITED=$((WAITED+2))
    VM_IP=$(sudo virsh domifaddr "$VM_NAME" --source agent | grep -oP '(\d{1,3}\.){3}\d{1,3}' | head -n1)
done

if [ -n "$VM_IP" ]; then
    echo "VM $VM_NAME läuft unter IP: $VM_IP"
else
    echo "IPv4-Adresse konnte nicht automatisch ermittelt werden. Bitte 'ipa' oder 'sudo virsh domifaddr $VM_NAME' verwenden."
fi

echo "Setup für VM $VM_NAME abgeschlossen!"