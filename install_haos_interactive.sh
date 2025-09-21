#!/usr/bin/env bash
# Optimized HAOS Installer for Proxmox VE 9.0
# Based on tteck helper scripts (MIT License)

set -euo pipefail

VMID=$(pvesh get /cluster/nextid)
VMNAME="Home-Assistant-OS"
DISK_SIZE="32G"
RAM="4096"
CORES="2"
BRIDGE="vmbr0"
STORAGE="local-lvm"
URL="https://github.com/home-assistant/operating-system/releases/latest/download/haos_ova.qcow2.xz"
FILE="haos_ova.qcow2.xz"

echo "➡️  Создание VM $VMID ($VMNAME) в Proxmox 9.0"
echo "   RAM: ${RAM}M | CPU: ${CORES} | Disk: ${DISK_SIZE} | Storage: $STORAGE"

cd /tmp
wget -q --show-progress "$URL"
unxz "$FILE"

qcow2="${FILE%.xz}"

# Создание VM
qm create $VMID --name $VMNAME --memory $RAM --cores $CORES \
  --net0 virtio,bridge=$BRIDGE --machine q35 --bios ovmf --scsihw virtio-scsi-pci \
  --cpu host --agent enabled=1,fstrim_cloned_disks=1 --onboot 1

# EFI диск (фикс предупреждения efidisk)
qm set $VMID --efidisk0 ${STORAGE}:0,format=qcow2,efitype=4m,pre-enrolled-keys=1

# Диск ОС
qm importdisk $VMID "$qcow2" $STORAGE
qm set $VMID --scsi0 ${STORAGE}:vm-$VMID-disk-0,iothread=1,discard=on,ssd=1,size=$DISK_SIZE
qm set $VMID --boot order=scsi0

# Консоль через serial (ускоряет работу)
qm set $VMID --serial0 socket --vga serial0

echo "✅ VM $VMNAME ($VMID) успешно создана."
echo "➡️  Запуск..."
qm start $VMID
