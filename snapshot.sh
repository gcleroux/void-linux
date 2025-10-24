#!/usr/bin/env -S sh -xe

VERSION=$(uname -r)
DATE=$(date +%F)
HASH=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)

# Look for collision on the snapshot name
while [ -f "/.snapshots/${DATE}_${VERSION}-${HASH}" ]; do
    HASH=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)
done

SNAPSHOT="${DATE}_${VERSION}-${HASH}"

# Create the snapshot
btrfs subvolume snapshot -r / /.snapshots/${SNAPSHOT}

# Copy the vmlinux/initramfs/config
cp /boot/initramfs-${VERSION}.img /boot/initramfs_${SNAPSHOT}.img
cp /boot/vmlinuz-${VERSION} /boot/vmlinuz_${SNAPSHOT}
cp /boot/config-${VERSION} /boot/config_${SNAPSHOT}

# Add the snapshot boot entry to limine
LUKS_UUID=$(blkid -t TYPE=crypto_LUKS -s UUID -o value)
ROOT_UUID=$(blkid /dev/mapper/luks-${LUKS_UUID} -s UUID -o value)
# Add the boot entry to limine
cat <<EOF >>/boot/limine/limine.conf

/Snapshot - ${SNAPSHOT}
    protocol: linux
    kernel_path: boot():/vmlinuz_${SNAPSHOT}
    module_path: boot():/initramfs_${SNAPSHOT}.img
    cmdline: quiet rd.luks.uuid=${LUKS_UUID} root=UUID=${ROOT_UUID} rootfstype=btrfs rootflags=subvol=@snapshots/${SNAPSHOT} ro
EOF
