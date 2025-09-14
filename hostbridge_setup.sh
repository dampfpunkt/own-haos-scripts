#!/bin/bash
set -e

BRIDGE_NAME=ethbr
PHYSICAL_IF=enp1s0

echo "=== KVM Host Bridge Setup für Ubuntu Server 25 ==="
echo "Aktuelle IP: 192.168.178.144/24, Gateway: 192.168.178.1"

# === 1️⃣ Backup erstellen ===
echo "=== Erstelle Sicherungskopien ==="
sudo cp -r /etc/netplan/ /etc/netplan.backup.$(date +%Y%m%d-%H%M%S)

# === 2️⃣ Bridge erstellen ===
if ! ip link show $BRIDGE_NAME >/dev/null 2>&1; then
    echo "=== Erstelle Bridge Interface $BRIDGE_NAME ==="
    sudo ip link add name $BRIDGE_NAME type bridge
    sudo ip link set dev $BRIDGE_NAME up
    
    echo "=== Füge $PHYSICAL_IF zur Bridge hinzu ==="
    sudo ip link set dev $PHYSICAL_IF master $BRIDGE_NAME
    
    echo "=== Warte auf automatische Netzwerk-Konfiguration ==="
    sleep 10
    
else
    echo "Bridge $BRIDGE_NAME existiert bereits."
fi

# === 3️⃣ Netplan für Persistenz ===
echo "=== Erstelle Netplan-Konfiguration ==="
sudo tee /etc/netplan/60-kvm-bridge.yaml > /dev/null <<EOF
network:
  version: 2
  ethernets:
    $PHYSICAL_IF:
      dhcp4: false
      dhcp6: false
  bridges:
    $BRIDGE_NAME:
      interfaces: [$PHYSICAL_IF]
      dhcp4: true
      dhcp6: true
      parameters:
        stp: true
        forward-delay: 0
EOF

# === 4️⃣ Netplan anwenden ===
echo "=== Aktiviere Netplan-Konfiguration ==="
sudo netplan apply

# === 5️⃣ libvirt Network ===
XML_PATH=/tmp/kvm-hostbridge.xml
cat <<EOF > $XML_PATH
<network>
  <name>hostbridge</name>
  <forward mode="bridge"/>
  <bridge name="$BRIDGE_NAME"/>
</network>
EOF

if ! sudo virsh net-info hostbridge >/dev/null 2>&1; then
    echo "=== Definiere libvirt Netzwerk hostbridge ==="
    sudo virsh net-define $XML_PATH
    sudo virsh net-start hostbridge
    sudo virsh net-autostart hostbridge
fi

echo ""
echo "=== Setup abgeschlossen ==="
ifconfig | less