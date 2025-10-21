#!/usr/bin/env -S sh -xe

# Script vars
export DISK=/dev/vda
export BTRFSOPTS=rw,noatime,compress=zstd
export ESPLABEL=BOOT
export ROOTLABEL=ROOT
# Set XBPS vars
export REPO=https://mirrors.servercentral.com/voidlinux/current
export ARCH=x86_64

export PKGS="base-system base-devel booster limine cryptsetup foot xtools"
export IGNORE_PKGS="dracut"

xbps-install -y gptfdisk

# Partitioning disk
sgdisk -Z ${DISK}
sgdisk -a 2048 -o ${DISK}
sgdisk -n 1:0:+4G ${DISK} # ESP
sgdisk -t 1:ef00 ${DISK}
sgdisk -n 2:0:-10% ${DISK} # LINUX
sgdisk -t 2:8300 ${DISK}

# Encrypting root partition
# TODO: Change passphrase
echo "asdfasdf" | cryptsetup -q luksFormat ${DISK}2
echo "asdfasdf" | cryptsetup -q luksOpen ${DISK}2 root

# Formatting FS
mkfs.vfat -F 32 -n ${ESPLABEL} ${DISK}1
mkfs.btrfs -L ${ROOTLABEL} -f /dev/mapper/root

# Creating the subvolumes
mount /dev/mapper/root /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@cache
umount /mnt

# Mounting FS
mount -o ${BTRFSOPTS},subvol=@ /dev/mapper/root /mnt
mkdir -pv /mnt/boot /mnt/home /mnt/var/log /mnt/var/cache /mnt/.snapshots

mount ${DISK}1 /mnt/boot
mount -o ${BTRFSOPTS},subvol=@home /dev/mapper/root /mnt/home
mount -o ${BTRFSOPTS},subvol=@snapshots /dev/mapper/root /mnt/.snapshots
mount -o ${BTRFSOPTS},subvol=@log /dev/mapper/root /mnt/var/log
mount -o ${BTRFSOPTS},subvol=@cache /dev/mapper/root /mnt/var/cache

# Load XBPS keys
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/

# Ignore unused pkgs
mkdir -p /mnt/etc/xbps.d
for pkgs in $IGNORE_PKGS; do
    echo "ignorepkg=$pkgs" >>/mnt/etc/xbps.d/99-ignorepkg.conf
done

# Installing base-system
XBPS_ARCH=$ARCH xbps-install -S -y -r /mnt -R "$REPO" ${PKGS}

# Create fstab
xgenfstab -U /mnt >/mnt/etc/fstab

# User settings
useradd -R /mnt -mG wheel,input,audio,video guillaume
echo "guillaume:void" | chpasswd -R /mnt -c SHA512 # TODO: Change password
echo "root:voidlinux" | chpasswd -R /mnt -c SHA512
xchroot /mnt chsh -s /usr/bin/bash guillaume
xchroot /mnt chsh -s /bin/bash root
echo "%wheel ALL=(ALL:ALL) ALL" >/mnt/etc/sudoers.d/99-wheel
echo "%wheel ALL=(ALL) NOPASSWD: /sbin/reboot, /sbin/poweroff" >>/mnt/etc/sudoers.d/99-wheel

# System locale settings
echo voidlinux >/mnt/etc/hostname
xchroot /mnt ln -sf /usr/share/zoneinfo/America/Toronto /etc/localtime
echo "LANG=en_CA.UTF-8" >/mnt/etc/locale.conf
echo "en_CA.UTF-8 UTF-8" >>/mnt/etc/default/libc-locales

# Setup the bootloader
mkdir -pv /mnt/boot/EFI/BOOT
cp /mnt/usr/share/limine/BOOTX64.EFI /mnt/boot/EFI/BOOT
xbps-alternatives -r /mnt -s booster

UUID=$(blkid -s UUID -o value /dev/mapper/root)
LUKSUUID=$(blkid -s UUID -o value ${DISK}2)
cat <<EOF >/mnt/boot/limine.conf
timeout: 5

/Void Linux
    protocol: linux
    kernel_path: boot():/vmlinuz-6.12.54_1
    module_path: boot():/initramfs-6.12.54_1.img
    cmdline: quiet rd.luks.uuid=$LUKSUUID root=UUID=$UUID rootfstype=btrfs rootflags=subvol=@ rw
EOF

# Setting the upstream repository
xbps-install -Sy -r /mnt -R "$REPO" void-repo-nonfree
cp /mnt/usr/share/xbps.d/*-repository-*.conf /mnt/etc/xbps.d/
sed -i "s|https://repo-default.voidlinux.org/current|$REPO|g" /mnt/etc/xbps.d/*-repository-*.conf

# Activate system services
for service in dhcpcd sshd; do
    xchroot /mnt ln -sfv /etc/sv/$service /etc/runit/runsvdir/default
done

# Finish system setup
xchroot /mnt xbps-reconfigure -fa
umount -R /mnt
