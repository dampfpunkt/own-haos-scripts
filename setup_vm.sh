#!/bin/bash

# VM Parameter
VM_NAME=HAOS
VM_RAM=4096
VM_CPU=2
VM_DISK_SIZE=32
BRIDGE_NAME=ethbr

# Vorbereitung
HAOS_DIR=~/haos
HAOS_IMAGE_ORIG=haos_ova-16.2.qcow2
HAOS_IMAGE_QCOW2=/var/lib/libvirt/images/${VM_NAME}.qcow2

# 1. HAOS Image herunterladen falls nicht vorhanden
mkdir -p "$HAOS_DIR"
cd "$HAOS_DIR"
if [ ! -f "$HAOS_IMAGE_ORIG" ]; then
    echo "=== HAOS Image herunterladen ==="
    wget -N https://github.com/home-assistant/operating-system/releases/download/16.2/haos_ova-16.2.qcow2.xz
    xz -d -f haos_ova-16.2.qcow2.xz
fi

# 2. VM Disk erstellen
if [ -f "$HAOS_IMAGE_QCOW2" ]; then
    echo "VM Disk existiert bereits, wird überschrieben..."
    sudo rm -f "$HAOS_IMAGE_QCOW2"
fi
sudo cp "$HAOS_IMAGE_ORIG" "$HAOS_IMAGE_QCOW2"
sudo qemu-img resize "$HAOS_IMAGE_QCOW2" ${VM_DISK_SIZE}G
sudo chown libvirt-qemu:kvm "$HAOS_IMAGE_QCOW2"

# 3. MAC Adresse generieren
BASE_MAC="52:54:00:$(printf '%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))"
MAC_ADDR=$BASE_MAC

# 4. VM XML erstellen
XML_FILE=/tmp/${VM_NAME}.xml
sudo tee "$XML_FILE" > /dev/null <<EOF
<domain type='kvm'>
  <name>${VM_NAME}</name>
  <memory unit='MiB'>${VM_RAM}</memory>
  <vcpu placement='static'>${VM_CPU}</vcpu>
  <os>
    <type arch='x86_64' machine='pc-q35-6.2'>hvm</type>
    <loader readonly='yes' type='pflash'>/usr/share/OVMF/OVMF_CODE_4M.fd</loader>
    <nvram>/var/lib/libvirt/qemu/nvram/${VM_NAME}_VARS.fd</nvram>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$HAOS_IMAGE_QCOW2'/>
      <target dev='vda' bus='virtio'/>
      <boot order='1'/>
    </disk>
    <interface type='bridge'>
      <mac address='$MAC_ADDR'/>
      <source bridge='$BRIDGE_NAME'/>
      <model type='virtio'/>
    </interface>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
  </devices>
</domain>
EOF

# 5. VM definieren und starten
sudo virsh define "$XML_FILE"
sudo virsh start "$VM_NAME"

# 6. Statusmeldung

echo "---------------------------------------"
echo "Home Assistant VM '$VM_NAME' wurde erstellt und gestartet."
echo "Zugeteilt: $VM_CPU CPUs, $VM_RAM MiB RAM, $VM_DISK_SIZE GB Disk"
echo "Netzwerk über Bridge: $BRIDGE_NAME"
virsh list --all | grep "$VM_NAME"
echo "---------------------------------------"