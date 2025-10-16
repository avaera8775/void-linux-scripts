#!/usr/bin/env bash
# Interactive installer for Void Linux (UEFI) + ZFSBootMenu (unencrypted)
# Based on official ZFSBootMenu 3.0.1 guide
set -euo pipefail

ask() { read -rp "$1: " "$2"; }
confirm() { read -rp "$1 [y/N]: " _r; [[ $_r =~ ^[Yy]$ ]]; }
log() { echo -e "\n==> $*\n"; }

[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

source /etc/os-release
export ID
zgenhostid -f 0x00bab10c

log "Disk selection"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
ask "Enter boot disk (e.g. /dev/sda or /dev/nvme0n1)" BOOT_DISK
ask "Enter boot partition number (e.g. 1)" BOOT_PART
ask "Enter pool disk (same as boot disk if single)" POOL_DISK
ask "Enter pool partition number (e.g. 2)" POOL_PART

if [[ "$BOOT_DISK" =~ nvme ]]; then
  BOOT_DEVICE="${BOOT_DISK}p${BOOT_PART}"
  POOL_DEVICE="${POOL_DISK}p${POOL_PART}"
else
  BOOT_DEVICE="${BOOT_DISK}${BOOT_PART}"
  POOL_DEVICE="${POOL_DISK}${POOL_PART}"
fi

log "You chose:"
echo "  Boot: $BOOT_DEVICE"
echo "  Pool: $POOL_DEVICE"
confirm "Proceed and WIPE these partitions?" || exit 0

log "Wiping existing partition tables"
zpool labelclear -f "$POOL_DISK" || true
wipefs -a "$POOL_DISK" || true
wipefs -a "$BOOT_DISK" || true
sgdisk --zap-all "$POOL_DISK"
sgdisk --zap-all "$BOOT_DISK"

log "Creating EFI and ZFS partitions"
sgdisk -n "${BOOT_PART}:1m:+512m" -t "${BOOT_PART}:ef00" "$BOOT_DISK"
sgdisk -n "${POOL_PART}:0:-10m" -t "${POOL_PART}:bf00" "$POOL_DISK"
partprobe "$BOOT_DISK" "$POOL_DISK"

modprobe zfs
log "Creating zpool"
zpool create -f -o ashift=12 \
  -O compression=lz4 \
  -O acltype=posixacl \
  -O xattr=sa \
  -O relatime=on \
  -o autotrim=on \
  -o compatibility=openzfs-2.2-linux \
  -m none zroot "$POOL_DEVICE"

log "Creating datasets"
zfs create -o mountpoint=none zroot/ROOT
zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/${ID}
zfs create -o mountpoint=/home zroot/home
zpool set bootfs=zroot/ROOT/${ID} zroot

log "Reimporting pool to /mnt"
zpool export zroot
zpool import -N -R /mnt zroot
zfs mount zroot/ROOT/${ID}
zfs mount zroot/home
udevadm trigger

log "Installing Void base system"
XBPS_ARCH=x86_64 xbps-install \
  -S -R https://mirrors.servercentral.com/voidlinux/current \
  -r /mnt base-system

cp /etc/hostid /mnt/etc

log "Entering chroot for configuration"
xchroot /mnt /bin/bash <<'CHROOT'
set -euo pipefail
echo 'KEYMAP="us"' >> /etc/rc.conf
echo 'HARDWARECLOCK="UTC"' >> /etc/rc.conf
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

cat <<EOF >> /etc/default/libc-locales
en_US.UTF-8 UTF-8
en_US ISO-8859-1
EOF
xbps-reconfigure -f glibc-locales
passwd

cat <<EOF > /etc/dracut.conf.d/zol.conf
nofsck="yes"
add_dracutmodules+=" zfs "
omit_dracutmodules+=" btrfs "
EOF

xbps-install -S zfs curl efibootmgr

zfs set org.zfsbootmenu:commandline="quiet" zroot/ROOT

mkfs.vfat -F32 "$BOOT_DEVICE"
mkdir -p /boot/efi
echo "$(blkid | grep "$BOOT_DEVICE" | cut -d' ' -f2) /boot/efi vfat defaults 0 0" >> /etc/fstab
mount /boot/efi

mkdir -p /boot/efi/EFI/ZBM
curl -L https://get.zfsbootmenu.org/efi -o /boot/efi/EFI/ZBM/VMLINUZ.EFI
cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI

# Create EFI boot entries
efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" \
  -L "ZFSBootMenu" \
  -l '\EFI\ZBM\VMLINUZ.EFI'
efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" \
  -L "ZFSBootMenu (Backup)" \
  -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI'

# --- Fallback EFI copy for firmware that forgets entries ---
mkdir -p /boot/efi/EFI/Boot
cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/Boot/Bootx64.efi
echo "Fallback Bootx64.efi created at /boot/efi/EFI/Boot"
CHROOT

log "Unmounting and exporting"
umount -n -R /mnt || true
zpool export zroot

log "Installation complete. Reboot into ZFSBootMenu."
