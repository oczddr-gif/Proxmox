#!/bin/bash
# Интерактивная установка Home Assistant OS на Proxmox 9.0
# Автор: ChatGPT

echo "=== Установка Home Assistant OS на Proxmox 9.0 ==="

# === Вопросы пользователю ===
read -p "Введите VM ID (по умолчанию 9000): " VMID
VMID=${VMID:-9000}

read -p "Введите имя VM (по умолчанию haos): " VMNAME
VMNAME=${VMNAME:-haos}

read -p "Введите количество CPU ядер (по умолчанию 2): " CORES
CORES=${CORES:-2}

read -p "Введите объем памяти в MB (по умолчанию 4096): " RAM
RAM=${RAM:-4096}

read -p "Введите размер системного диска (по умолчанию 32G): " DISK_SIZE
DISK_SIZE=${DISK_SIZE:-32G}

read -p "Введите хранилище для диска (по умолчанию local-lvm): " STORAGE
STORAGE=${STORAGE:-local-lvm}

read -p "Введите сетевой мост (по умолчанию vmbr0): " BRIDGE
BRIDGE=${BRIDGE:-vmbr0}

read -p "Включить автозапуск VM при загрузке Proxmox? (y/n, по умолчанию y): " AUTOSTART
AUTOSTART=${AUTOSTART:-y}

# === Скачивание образа ===
echo "[*] Получаю ссылку на последний образ Home Assistant OS..."
URL=$(curl -s https://api.github.com/repos/home-assistant/operating-system/releases/latest \
    | grep browser_download_url \
    | grep qcow2.xz \
    | cut -d '"' -f 4)

echo "[*] Скачиваю образ: $URL"
wget -O haos.qcow2.xz "$URL"

echo "[*] Распаковываю образ..."
xz -d haos.qcow2.xz

# === Создание VM ===
echo "[*] Создаю VM ID=$VMID, имя=$VMNAME"
qm create $VMID --name $VMNAME --memory $RAM --cores $CORES \
    --net0 virtio,bridge=$BRIDGE \
    --bios ovmf --machine q35 --scsihw virtio-scsi-pci

# === Импорт диска ===
echo "[*] Импортирую диск..."
qm importdisk $VMID haos.qcow2 $STORAGE --format qcow2
qm set $VMID --scsi0 $STORAGE:vm-$VMID-disk-0
qm set $VMID --boot order=scsi0

# === Дополнительные настройки ===
qm set $VMID --serial0 socket --vga serial0
qm set $VMID --agent enabled=1,fstrim_cloned_disks=1

# === Автозапуск (если выбран) ===
if [[ "$AUTOSTART" =~ ^[Yy]$ ]]; then
    qm set $VMID --onboot 1
    echo "[*] Автозапуск включён."
else
    echo "[*] Автозапуск отключён."
fi

# === Итог ===
echo
echo "[+] Готово! VM создана."
echo "VM ID: $VMID"
echo "Имя:   $VMNAME"
echo "CPU:   $CORES"
echo "RAM:   ${RAM}MB"
echo "Диск:  $DISK_SIZE на $STORAGE"
echo "Сеть:  $BRIDGE"
if [[ "$AUTOSTART" =~ ^[Yy]$ ]]; then
    echo "Автозапуск: Включён"
else
    echo "Автозапуск: Выключен"
fi
echo
echo "Запустите виртуалку командой: qm start $VMID"
