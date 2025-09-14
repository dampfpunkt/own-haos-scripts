#!/bin/bash
set -e

echo "=== Stopping and removing old HAOS VM if it exists ==="
if virsh list --all | grep -q "haos"; then
    virsh destroy haos || true
    virsh undefine haos --remove-all-storage || true
    echo "HAOS VM removed."
else
    echo "No HAOS VM found."
fi

echo
echo "=== Removing old bridges (haosbr or zkvmbridge) ==="
for BR in haosbr zkvmbridge; do
    if virsh net-list --all | grep -q "$BR"; then
        echo "Bridge $BR found in libvirt, removing..."
        virsh net-destroy $BR || true
        virsh net-undefine $BR || true
        echo "Bridge $BR removed from libvirt."
    elif ip link show | grep -q "$BR"; then
        echo "Bridge $BR found as Linux bridge, removing..."
        sudo ip link set $BR down || true
        sudo brctl delbr $BR || true
        echo "Bridge $BR removed from system."
    else
        echo "Bridge $BR not found."
    fi
done

echo
echo "=== Current active networks in libvirt ==="
virsh net-list --all

echo
echo "=== Current interfaces on host ==="
ifconfig