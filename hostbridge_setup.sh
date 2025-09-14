#!/bin/bash
set -e

BRIDGE_NAME=ethbr
PHYSICAL_IF=enp1s0

echo "=== KVM Host Bridge Setup für Ubuntu Server 25 ==="
echo "Netzwerk: 192.168.178.0/24, Gateway: 192.168.178.1"

# === 1️⃣ Bridge erstellen und konfigurieren ===
if ! ip link show $BRIDGE_NAME >/dev/null 2>&1; then
    echo "=== Erstelle Bridge Interface $BRIDGE_NAME ==="
    sudo ip link add name $BRIDGE_NAME type bridge
    sudo ip link set dev $BRIDGE_NAME up
    
    echo "=== Aktuelle Netzwerk-Konfiguration von $PHYSICAL_IF sichern ==="
    # IPv4 und IPv6 Adressen vom physischen Interface ermitteln
    IPV4_ADDR=$(ip addr show $PHYSICAL_IF | grep -oP '(?<=inet )[0-9]+(\.[0-9]+){3}/[0-9]+' | head -n1)
    IPV6_ADDR=$(ip addr show $PHYSICAL_IF | grep -oP '(?<=inet6 )[0-9a-f:]+/[0-9]+' | grep -v 'fe80' | head -n1)
    
    echo "Aktuelle IPv4: $IPV4_ADDR"
    echo "Aktuelle IPv6: $IPV6_ADDR"
    
    echo "=== Füge physisches Interface $PHYSICAL_IF zur Bridge hinzu ==="
    sudo ip link set dev $PHYSICAL_IF master $BRIDGE_NAME
    
    # IP-Adressen auf Bridge übertragen (falls bereits konfiguriert)
    if [ -n "$IPV4_ADDR" ]; then
        echo "Übertrage IPv4-Adresse $IPV4_ADDR auf $BRIDGE_NAME"
        sudo ip addr add $IPV4_ADDR dev $BRIDGE_NAME
        sudo ip addr del $IPV4_ADDR dev $PHYSICAL_IF 2>/dev/null || true
    fi
    
    if [ -n "$IPV6_ADDR" ]; then
        echo "Übertrage IPv6-Adresse $IPV6_ADDR auf $BRIDGE_NAME"  
        sudo ip addr add $IPV6_ADDR dev $BRIDGE_NAME
        sudo ip addr del $IPV6_ADDR dev $PHYSICAL_IF 2>/dev/null || true
    fi
    
    # Standardrouten anpassen
    IPV4_GW=$(ip route | grep default | grep $PHYSICAL_IF | awk '{print $3}' | head -n1)
    if [ -n "$IPV4_GW" ]; then
        echo "Setze Standard IPv4 Gateway $IPV4_GW auf $BRIDGE_NAME"
        sudo ip route replace default via $IPV4_GW dev $BRIDGE_NAME
    fi
    
    IPV6_GW=$(ip -6 route | grep default | grep $PHYSICAL_IF | awk '{print $3}' | head -n1)
    if [ -n "$IPV6_GW" ]; then
        echo "Setze Standard IPv6 Gateway $IPV6_GW auf $BRIDGE_NAME"
        sudo ip -6 route replace default via $IPV6_GW dev $BRIDGE_NAME
    fi
    
    # Falls keine IP konfiguriert war, DHCP für Bridge aktivieren  
    if [ -z "$IPV4_ADDR" ]; then
        echo "Aktiviere DHCP IPv4 für $BRIDGE_NAME"
        sudo dhclient -4 $BRIDGE_NAME
    fi
    
    if [ -z "$IPV6_ADDR" ]; then
        echo "Aktiviere DHCP IPv6 für $BRIDGE_NAME"
        sudo dhclient -6 $BRIDGE_NAME
    fi
    
else
    echo "Bridge $BRIDGE_NAME existiert bereits."
fi

# === 2️⃣ libvirt Host Bridge Netzwerk XML erstellen ===
XML_PATH=/tmp/kvm-hostbridge.xml
cat <<EOF > $XML_PATH
<network>
  <name>hostbridge</name>
  <forward mode="bridge"/>
  <bridge name="$BRIDGE_NAME"/>
</network>
EOF

# === 3️⃣ libvirt Netzwerk definieren und starten ===
if ! sudo virsh net-info hostbridge >/dev/null 2>&1; then
    echo "=== Definiere und starte libvirt Netzwerk hostbridge ==="
    sudo virsh net-define $XML_PATH
    sudo virsh net-start hostbridge
    sudo virsh net-autostart hostbridge
    echo "Libvirt Netzwerk 'hostbridge' erfolgreich erstellt und aktiviert."
else
    echo "Libvirt Netzwerk hostbridge existiert bereits."
fi

echo ""
echo "=== Setup der Host Bridge $BRIDGE_NAME abgeschlossen ==="
echo "Bridge: $BRIDGE_NAME mit Interface: $PHYSICAL_IF"
echo "Libvirt Network: hostbridge verfügbar für VMs"
echo ""

# === 4️⃣ Netzwerkstatus anzeigen ===
echo "=== ifconfig Übersicht ==="
ifconfig | less