#!/usr/bin/env bash
# Automated Void Linux (UEFI) + ZFSBootMenu install (unencrypted)
# Follows official ZFSBootMenu 3.0.1 guide
set -euo pipefail

### ── config ─────────────────────────────────────────────
BOOT_DISK="/dev/nvme2n1"
BOOT_PART="1"
POOL_DISK="/dev/nvme2n1"
POOL_PART="2"
USERNAME="johan"
PASSWORD="changeme"
HOSTNAME="voidlinux"

### ── Internal setup ───────────────────────────────────────────────
log() { echo -e "\n==> $*\n"; }

[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

for cmd in sgdisk zpool zfs xbps-install xchroot curl efibootmgr; do
  command -v "$cmd" >/dev/null || { echo "Missing required command: $cmd"; exit 1; }
done

source /etc/os-release
export ID
zgenhostid -f 0x00bab10c

# Handle SATA vs NVMe naming
if [[ "$BOOT_DISK" =~ nvme ]]; then
  BOOT_DEVICE="${BOOT_DISK}p${BOOT_PART}"
  POOL_DEVICE="${POOL_DISK}p${POOL_PART}"
else
  BOOT_DEVICE="${BOOT_DISK}${BOOT_PART}"
  POOL_DEVICE="${POOL_DISK}${POOL_PART}"
fi

log "Using disk layout:"
echo "  Boot: $BOOT_DEVICE"
echo "  Pool: $POOL_DEVICE"
sleep 3

### ── Disk preparation ─────────────────────────────────────────────
log "Wiping existing partitions on $BOOT_DISK"
zpool labelclear -f "$POOL_DISK" || true
wipefs -a "$POOL_DISK" || true
wipefs -a "$BOOT_DISK" || true
sgdisk --zap-all "$POOL_DISK"
sgdisk --zap-all "$BOOT_DISK"

log "Creating EFI and ZFS partitions"
sgdisk -n "${BOOT_PART}:1m:+512m" -t "${BOOT_PART}:ef00" "$BOOT_DISK"
sgdisk -n "${POOL_PART}:0:-10m" -t "${POOL_PART}:bf00" "$POOL_DISK"
partprobe "$BOOT_DISK" "$POOL_DISK"

### ── ZFS setup ───────────────────────────────────────────────────
modprobe zfs
log "Creating zpool zroot"
zpool create -f -o ashift=12 \
  -O compression=lz4 \
  -O acltype=posixacl \
  -O xattr=sa \
  -O relatime=on \
  -o autotrim=on \
  -o compatibility=openzfs-2.2-linux \
  -m none zroot "$POOL_DEVICE"

zfs create -o mountpoint=none zroot/ROOT
zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/${ID}
zfs create -o mountpoint=/home zroot/home
zpool set bootfs=zroot/ROOT/${ID} zroot

zpool export zroot
zpool import -N -R /mnt zroot
zfs mount zroot/ROOT/${ID}
zfs mount zroot/home
udevadm trigger

### ── Void install ────────────────────────────────────────────────
log "Installing Void base system"
XBPS_ARCH=x86_64 xbps-install \
  -S -R https://mirrors.servercentral.com/voidlinux/current \
  -r /mnt base-system

cp /etc/hostid /mnt/etc

### ── Chroot configuration ────────────────────────────────────────
log "Configuring system in chroot"
xchroot /mnt /bin/bash -s <<CHROOT
set -euo pipefail

# Locale & time
echo 'KEYMAP="us"' >> /etc/rc.conf
echo 'HARDWARECLOCK="UTC"' >> /etc/rc.conf
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

cat <<EOF >> /etc/default/libc-locales
en_US.UTF-8 UTF-8
en_US ISO-8859-1
EOF
xbps-reconfigure -f glibc-locales

# Hostname setup
echo "${HOSTNAME}" > /etc/hostname
cat <<EOF > /etc/hosts
127.0.0.1   localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

# Users
echo "root:${PASSWORD}" | chpasswd
useradd -m -G wheel,users -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${PASSWORD}" | chpasswd

# Dracut config
cat <<EOF > /etc/dracut.conf.d/zol.conf
nofsck="yes"
add_dracutmodules+=" zfs "
omit_dracutmodules+=" btrfs "
EOF

xbps-install -S zfs curl efibootmgr sudo

zfs set org.zfsbootmenu:commandline="quiet" zroot/ROOT

mkfs.vfat -F32 "$BOOT_DEVICE"
mkdir -p /boot/efi
echo "$(blkid | grep "$BOOT_DEVICE" | cut -d' ' -f2) /boot/efi vfat defaults 0 0" >> /etc/fstab
mount /boot/efi

mkdir -p /boot/efi/EFI/ZBM
curl -L https://get.zfsbootmenu.org/efi -o /boot/efi/EFI/ZBM/VMLINUZ.EFI
cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI

efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" \
  -L "ZFSBootMenu" \
  -l '\EFI\ZBM\VMLINUZ.EFI'
efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" \
  -L "ZFSBootMenu (Backup)" \
  -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI'

mkdir -p /boot/efi/EFI/Boot
cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/Boot/Bootx64.efi
echo "Fallback Bootx64.efi created at /boot/efi/EFI/Boot"
CHROOT

### ── Cleanup ─────────────────────────────────────────────────────
log "Unmounting and exporting"
umount -n -R /mnt || true
zpool export zroot

log "Installation complete."
echo "Hostname: ${HOSTNAME}"
echo "Root: root / ${PASSWORD}"
echo "User: ${USERNAME} / ${PASSWORD}"
echo "Reboot into ZFSBootMenu to boot Void."
