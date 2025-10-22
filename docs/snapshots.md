# How to create/restore snapshots

## Creating a bootable snapshot

1. Create a snapshot of @ into @snapshots

   ```bash
   sudo btrfs subvolume snapshot -r / /.snapshots/root-2025-10-21
   ```

2. Add an entry to `/boot/limine.conf`

   ```txt
   # ...

   /Snapshots
   //2025-10-21
        protocol: linux
        kernel_path: boot():/vmlinuz-6.12.54_1
        module_path: boot():/initramfs-6.12.54_1.img
        cmdline: quiet rd.luks.uuid=824a5f02-31ae-4dad-b7ce-35282ad6d5e4 root=UUID=9ad7919c-fdce-47b9-9f54-bd61be11e358 rootfstype=btrfs rootflags=subvol=@snapshots/root-2025-10-21 ro
   ```

## Restoring from a snapshot

1. Boot the system into the desired snapshot

2. Mount the root FS

   ```bash
   mount /dev/vda2 /mnt
   ```

3. Remove the old @ subvolume

   ```bash
   # Optionally, you could save the @ subvolume
   sudo btrfs subvolume snapshot /mnt/@ /mnt/@save

   sudo btrfs subvolume delete /mnt/@
   ```

4. Create a snapshot of the desired snapshot as @

   ```bash
   sudo btrfs subvolume snapshot /mnt/@snapshots/root-2025-10-21 /mnt/@
   ```

5. Reboot the system into @
