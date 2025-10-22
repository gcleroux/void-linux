#!/usr/bin/env -S sh -xe

# Script vars
export DISK=/dev/vda
export BOOT_PART=1
export ROOT_PART=2
export BTRFSOPTS=rw,noatime,compress=zstd

export HOST=voidlinux
export USER=guillaume
export USER_PW=void
export ROOT_PW=void
export LUKS_PASSPHRASE=void
export TIMEZONE=America/Toronto
export LOCALE=en_CA.UTF-8

export DISK_BOOT=${DISK}${BOOT_PART}
export DISK_ROOT=${DISK}${ROOT_PART}
export ESPLABEL=BOOT
export ROOTLABEL=ROOT
# Set XBPS vars
export REPO=https://mirrors.servercentral.com/voidlinux/current
export ARCH=x86_64

export PKGS="base-system base-devel booster limine cryptsetup xtools clevis neovim"
export IGNORE_PKGS="dracut nvi"

xbps-install -y gptfdisk

# Partitioning disk
sgdisk -Z ${DISK}
sgdisk -a 2048 -o ${DISK}
sgdisk -n 1:0:+4G ${DISK} # ESP
sgdisk -t 1:ef00 ${DISK}
sgdisk -n 2:0:-10% ${DISK} # LINUX
sgdisk -t 2:8300 ${DISK}

# Encrypting root partition
echo "${LUKS_PASSPHRASE}" | cryptsetup -q luksFormat ${DISK_ROOT}
echo "${LUKS_PASSPHRASE}" | cryptsetup -q luksOpen ${DISK_ROOT} root

# Formatting FS
mkfs.vfat -F 32 -n ${ESPLABEL} ${DISK_BOOT}
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

mount ${DISK_BOOT} /mnt/boot
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
useradd -R /mnt -mG wheel,input,audio,video ${USER}
echo "${USER}:${USER_PW}" | chpasswd -R /mnt -c SHA512
echo "root:${ROOT_PW}" | chpasswd -R /mnt -c SHA512
xchroot /mnt chsh -s /usr/bin/bash ${USER}
xchroot /mnt chsh -s /bin/bash root
echo "%wheel ALL=(ALL:ALL) ALL" >/mnt/etc/sudoers.d/99-wheel
echo "%wheel ALL=(ALL) NOPASSWD: /sbin/reboot, /sbin/poweroff" >>/mnt/etc/sudoers.d/99-wheel

# System locale settings
echo ${HOST} >/mnt/etc/hostname
xchroot /mnt ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
echo "LANG=${LOCALE}" >/mnt/etc/locale.conf
echo "${LOCALE} UTF-8" >>/mnt/etc/default/libc-locales

# Setup the bootloader
mkdir -pv /mnt/boot/EFI/BOOT
cp /mnt/usr/share/limine/BOOTX64.EFI /mnt/boot/EFI/BOOT
echo "universal: true" >>/mnt/etc/booster.yaml

UUID=$(blkid -s UUID -o value /dev/mapper/root)
LUKSUUID=$(blkid -s UUID -o value ${DISK_ROOT})
cat <<EOF >/mnt/boot/limine.conf
timeout: 5

/Void Linux
    protocol: linux
    kernel_path: boot():/vmlinuz-6.12.54_1
    module_path: boot():/initramfs-6.12.54_1.img
    cmdline: quiet rd.luks.uuid=$LUKSUUID root=UUID=$UUID rootfstype=btrfs rootflags=subvol=@ rw
EOF

# Binding LUKS volume to TPM
xchroot /mnt /bin/sh -c "echo ${LUKS_PASSPHRASE} | clevis luks bind -d ${DISK_ROOT} -k - tpm2 '{}'"

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
