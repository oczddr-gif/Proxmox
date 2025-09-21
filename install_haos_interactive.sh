#!/usr/bin/env bash
# Optimized HAOS installer for Proxmox VE 9.x
# Usage: run as root
set -Eeuo pipefail
trap 'echo; echo "[ERROR] on line $LINENO"; exit 1' ERR

# --- Settings (можно менять) ---
HAOS_URL=${HAOS_URL:-"https://github.com/home-assistant/operating-system/releases/download/16.2/haos_ova-16.2.qcow2.xz"}
VMNAME=${VMNAME:-"home-assistant-os"}
DISK_SIZE=${DISK_SIZE:-"32G"}
RAM=${RAM:-4096}
CORES=${CORES:-2}
BRIDGE=${BRIDGE:-vmbr0}

# --- Helpers ---
log()    { echo -e "[*] $*"; }
err()    { echo -e "\e[31m[ERROR]\e[0m $*" >&2; }
check_cmd(){ command -v "$1" >/dev/null 2>&1 || { err "Command '$1' not found"; exit 1; } }

# --- Basic checks ---
if [ "$(id -u)" -ne 0 ]; then err "Запустите скрипт от root"; exit 1; fi
check_cmd pveversion
check_cmd pvesm
check_cmd qm
check_cmd wget
check_cmd unxz || { err "unxz (xz-utils) не найден. Установите: apt update && apt install -y xz-utils"; exit 1; }

# --- PVE version check (поддерживаем 8.1+) ---
PVE_FULL=$(pveversion 2>/dev/null)
PVE_VER=$(echo "$PVE_FULL" | sed -n 's/.*pve-manager\/\([0-9]\+\)\.\([0-9]\+\).*/\1.\2/p' || true)
if [ -z "$PVE_VER" ]; then err "Не удалось распарсить pveversion: $PVE_FULL"; fi
PVE_MAJOR=${PVE_VER%%.*}
PVE_MINOR=${PVE_VER#*.}
PVE_MINOR=${PVE_MINOR:-0}
if (( PVE_MAJOR < 8 )) || ( (( PVE_MAJOR == 8 )) && (( PVE_MINOR < 1 )) ); then
  err "Требуется Proxmox VE 8.1 или новее. Обнаружено: $PVE_VER"
  exit 1
fi
log "Proxmox версия: $PVE_VER — OK"

# --- pick next id and storage ---
NEXTID=$(pvesh get /cluster/nextid 2>/dev/null || true)
if [ -z "$NEXTID" ]; then err "Не удалось получить nextid"; exit 1; fi

# Найти первый storage, который поддерживает content 'images'
STORAGE=$(pvesm status -content images 2>/dev/null | awk 'NR>1{print $1; exit}')
if [ -z "$STORAGE" ]; then
  err "Не найден storage с поддержкой 'images'. Проверьте pvesm status -content images"
  pvesm status -content images | sed -n '1,200p'
  exit 1
fi
log "Используем storage: $STORAGE"

VMID=${VMID:-$NEXTID}
log "Создаём VMID=$VMID, имя=$VMNAME"

# --- download ---
TMPDIR=$(mktemp -d)
pushd "$TMPDIR" >/dev/null
log "Скачиваю $HAOS_URL ..."
if ! wget --quiet --show-progress -O haos.qcow2.xz "$HAOS_URL"; then
  err "Не удалось скачать образ. Проверьте URL или доступ в интернет."
  exit 1
fi
log "Распаковка..."
unxz -v haos.qcow2.xz
IMG=haos.qcow2
if [ ! -f "$IMG" ]; then err "Файл образа не найден после распаковки"; exit 1; fi

# --- create VM ---
log "Создаю VM (qm create) ..."
qm create "$VMID" \
  --name "$VMNAME" \
  --memory "$RAM" \
  --cores "$CORES" \
  --net0 virtio,bridge="$BRIDGE" \
  --machine q35 \
  --bios ovmf \
  --scsihw virtio-scsi-pci \
  --cpu host \
  --agent enabled=1,fstrim_cloned_disks=1 \
  --onboot 1 \
  --ostype l26 >/dev/null

# allocate tiny efidisk (чтобы не было WARN)
log "Alloc efidisk0 (4M) ..."
pvesm alloc "$STORAGE" "$VMID" vm-"$VMID"-disk-efiboot 4M >/dev/null || true

log "Импортирую диск (qm importdisk) ..."
qm importdisk "$VMID" "$IMG" "$STORAGE" >/dev/null

# Найдём имя импортированного диска
# Обычно qm importdisk создаёт vm-<VMID>-disk-0(.[qcow2|raw])
IMPORTED=$(pvesm status -storage "$STORAGE" | awk -v vm="$VMID" 'NR>1 && $1 ~ vm {print $1":"$2; exit}' || true)
# fallback: составим стандартное имя
if [ -z "$IMPORTED" ]; then
  DISKNAME="vm-$VMID-disk-0"
  IMPORTED="$STORAGE:$DISKNAME"
fi

log "Подключаю efidisk0 и основной диск ..."
# efidisk: указываем хранилище и маленький размер, efitype 4m
qm set "$VMID" --efidisk0 "$STORAGE":vm-"$VMID"-disk-efiboot,format=qcow2,efitype=4m >/dev/null || true
# scsi0 — основной импортированный диск
qm set "$VMID" --scsi0 "${IMPORTED}",iothread=1,discard=on,ssd=1,size="$DISK_SIZE" --boot order=scsi0 >/dev/null

# serial console
qm set "$VMID" --serial0 socket --vga serial0 >/dev/null

log "VM создана: $VMNAME ($VMID)"
log "Запуск VM ..."
qm start "$VMID" >/dev/null || { err "Не удалось запустить VM $VMID"; qm status "$VMID" || true; exit 1; }

popd >/dev/null
rm -rf "$TMPDIR"

log "Готово. Откройте консоль в Proxmox или подождите ~1-2 минуты для загрузки HAOS."
exit 0
