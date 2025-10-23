#!/usr/bin/env -S sh -xe

#
# Opionionated/inflexible Void Linux install script for myself.
#
# Uses btrfs + subvolumes for easy snapshots/rollbacks.
# Uses LUKS encryption with auto TPM unlock, limine bootloader and
# booster initramfs.
#

# User defined config
#####################

# Disk
DISK=/dev/vda
LUKS_PASSPHRASE=void

# Packages
REPO=https://mirrors.servercentral.com/voidlinux/current
ARCH=x86_64
PKGS="base-devel xtools neovim wget intel-ucode"
IGNORE_PKGS="nvi"

# Users
USER=guillaume
USER_PW=void
ROOT_PW=void

# System
HOST=voidlinux
TIMEZONE=America/Toronto
LOCALE=en_CA.UTF-8

# Helper functions
##################

# Extract a partition path regardless of disk type
# Useful when disk is an NVMe
partpath() {
    disk="$1"
    part="$2"
    case "$disk" in
    *[0-9]) printf '%sp%s\n' "$disk" "$part" ;; # ends with digit -> needs 'p'
    *) printf '%s%s\n' "$disk" "$part" ;;
    esac
}

# Main script functions
#######################

# Partition and format disk
setup_disk() {
    boot_disk=$(partpath "$DISK" 1)
    root_disk=$(partpath "$DISK" 2)
    btrfs_opts=rw,noatime,compress=zstd
    efi_label=BOOT
    root_label=ROOT

    # Partitioning disk
    xbps-install -y gptfdisk # Needed for sgdisk
    sgdisk -Z ${DISK}
    sgdisk -a 2048 -o ${DISK}
    sgdisk -n 1:0:+4G ${DISK} # ESP
    sgdisk -t 1:ef00 ${DISK}
    sgdisk -n 2:0:-10% ${DISK} # LINUX
    sgdisk -t 2:8300 ${DISK}

    # Encrypting root partition
    echo "${LUKS_PASSPHRASE}" | cryptsetup -q luksFormat ${root_disk}
    echo "${LUKS_PASSPHRASE}" | cryptsetup -q luksOpen ${root_disk} root

    # Formatting FS
    mkfs.vfat -F 32 -n ${efi_label} ${boot_disk}
    mkfs.btrfs -L ${root_label} -f /dev/mapper/root

    # Creating the subvolumes
    mount /dev/mapper/root /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@snapshots
    btrfs subvolume create /mnt/@log
    btrfs subvolume create /mnt/@cache
    umount /mnt

    # Mounting FS
    mount -o ${btrfs_opts},subvol=@ /dev/mapper/root /mnt
    mkdir -pv /mnt/boot /mnt/home /mnt/var/log /mnt/var/cache /mnt/.snapshots

    mount ${boot_disk} /mnt/boot
    mount -o ${btrfs_opts},subvol=@home /dev/mapper/root /mnt/home
    mount -o ${btrfs_opts},subvol=@snapshots /dev/mapper/root /mnt/.snapshots
    mount -o ${btrfs_opts},subvol=@log /dev/mapper/root /mnt/var/log
    mount -o ${btrfs_opts},subvol=@cache /dev/mapper/root /mnt/var/cache
}

# Install base-system and setup void repository
install_base_system() {
    # Load XBPS keys
    mkdir -p /mnt/var/db/xbps/keys
    cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/

    # Always ignore dracut
    mkdir -p /mnt/etc/xbps.d
    echo "ignorepkg=dracut" >>/mnt/etc/xbps.d/99-ignorepkg.conf

    # User provided ignorepkgs
    for pkgs in $IGNORE_PKGS; do
        echo "ignorepkg=$pkgs" >>/mnt/etc/xbps.d/99-ignorepkg.conf
    done

    # Installing base-system
    XBPS_ARCH=$ARCH xbps-install -Sy -r /mnt -R "$REPO" base-system limine booster clevis cryptsetup

    # Setting the upstream repository
    XBPS_ARCH=$ARCH xbps-install -Sy -r /mnt -R "$REPO" void-repo-nonfree
    cp /mnt/usr/share/xbps.d/*-repository-*.conf /mnt/etc/xbps.d/
    sed -i "s|https://repo-default.voidlinux.org/current|$REPO|g" /mnt/etc/xbps.d/*-repository-*.conf

    # Install user provided packages
    XBPS_ARCH=$ARCH xbps-install -Sy -r /mnt -R "$REPO" ${PKGS}

    # Create fstab
    xgenfstab -U /mnt >/mnt/etc/fstab
}

# Save passphrase to TPM if available
# Does nothing if not present
setup_tpm() {
    root_disk=$(partpath "$DISK" 2)
    tpm_desc_file="/sys/class/tpm/tpm0/device/description"

    if [ -r "$tpm_desc_file" ]; then
        tpm_desc=$(cat "$tpm_desc_file")
        if [ "$tpm_desc" = "TPM 2.0 Device" ]; then
            # Binding LUKS volume to TPM
            xchroot /mnt /bin/sh -c "echo ${LUKS_PASSPHRASE} | clevis luks bind -d ${root_disk} -k - tpm2 '{}'"
        fi
    fi
}

# Setup hostname, locale and system services
setup_host() {
    echo ${HOST} >/mnt/etc/hostname
    xchroot /mnt ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime

    # System locale settings
    echo "LANG=${LOCALE}" >/mnt/etc/locale.conf
    echo "${LOCALE} UTF-8" >>/mnt/etc/default/libc-locales

    # Activate system services
    for service in dhcpcd sshd; do
        xchroot /mnt ln -sfv /etc/sv/$service /etc/runit/runsvdir/default
    done
}

# Setup admin user and root user settings
setup_users() {
    # User settings
    useradd -R /mnt -mG wheel,input,audio,video ${USER}
    echo "${USER}:${USER_PW}" | chpasswd -R /mnt -c SHA512
    xchroot /mnt chsh -s /usr/bin/bash ${USER}

    # Root settings
    echo "root:${ROOT_PW}" | chpasswd -R /mnt -c SHA512
    xchroot /mnt chsh -s /bin/bash root

    # Sudo config
    echo "%wheel ALL=(ALL:ALL) ALL" >/mnt/etc/sudoers.d/99-wheel
    echo "%wheel ALL=(ALL) NOPASSWD: /sbin/reboot, /sbin/poweroff" >>/mnt/etc/sudoers.d/99-wheel
}

# Setup limine and booster config
# In case of multiple kernel installed, only add an entry for the latest one
setup_bootloader() {
    root_disk=$(partpath "$DISK" 2)
    root_uuid=$(blkid -s UUID -o value /dev/mapper/root)
    luks_uuid=$(blkid -s UUID -o value ${root_disk})
    latest_kernel=$(xbps-query -r /mnt --regex -s '^linux[0-9.]+-[0-9._]+' | sort -Vrk2 | cut -d ' ' -f 2 | cut -d '-' -f 2 | head -n 1)

    # Booster conf
    echo "universal: true" >>/mnt/etc/booster.yaml

    # EFI/BOOT dir
    mkdir -pv /mnt/boot/EFI/BOOT
    cp /mnt/usr/share/limine/BOOTX64.EFI /mnt/boot/EFI/BOOT

    # Limine conf
    # Only add a wallpaper if download was successful
    mkdir -pv /mnt/boot/limine /mnt/boot/limine/Wallpapers
    if wget -q -O /mnt/boot/limine/Wallpapers/nord.png https://i.redd.it/1r1kk9qi00961.png; then
        wallpaper="wallpaper: boot():/limine/Wallpapers/nord.png"
    else
        wallpaper=""
    fi

    cat <<EOF >/mnt/boot/limine/limine.conf
timeout: 5
${wallpaper}

/Void Linux - ${latest_kernel}
    protocol: linux
    kernel_path: boot():/vmlinuz-${latest_kernel}
    module_path: boot():/initramfs-${latest_kernel}.img
    cmdline: quiet rd.luks.uuid=$luks_uuid root=UUID=$root_uuid rootfstype=btrfs rootflags=subvol=@ rw
EOF
}

# Run the installer
###################

setup_disk
install_base_system
setup_tpm
setup_host
setup_users
setup_bootloader

# Finish system setup
xchroot /mnt xbps-reconfigure -fa
umount -R /mnt
