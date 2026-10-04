#!/usr/bin/env bash
# Fill the 40_custom placeholders from the attached vda (Ubuntu rescue root).
# Run inside LFS (chroot or booted) with /dev/vda present.
set -euo pipefail
TEMPLATE=/etc/grub.d/40_custom

ROOT_UUID=$(blkid -s UUID -o value /dev/vda1) || { echo "vda1 not found" >&2; exit 1; }
mkdir -p /mnt/ubu-ro
mount /dev/vda1 /mnt/ubu-ro 2>/dev/null || mount -o ro /dev/vda1 /mnt/ubu-ro

# Ubuntu 24.04 on the sandbox has /boot as its OWN partition, so the obvious
# "ls /mnt/ubu-ro/boot/vmlinuz-*" finds nothing and the entry silently has no
# kernel. Search vda1's /boot first, then every other vda partition, and use
# whichever filesystem actually carries a kernel. BOOT_UUID and ROOT_UUID are
# then genuinely different: `search` finds the kernel, root=UUID= finds the
# root filesystem.
KBOOT_UUID=""
KBOOT_MNT=""
KERN=""
for part in /dev/vda1 /dev/vda*; do
    [ -b "$part" ] || continue
    mnt=/mnt/ubu-ro
    if [ "$part" != /dev/vda1 ]; then
        mnt=/mnt/ubu-part
        mkdir -p "$mnt"
        mount -o ro "$part" "$mnt" 2>/dev/null || continue
    fi
    # /boot may be a directory on the root fs or a separate mount point
    for cand in "$mnt/boot" "$mnt"; do
        k=$(ls -1 "$cand"/vmlinuz-* 2>/dev/null | tail -1) || continue
        [ -n "$k" ] || continue
        KERN="$k"
        KBOOT_UUID=$(blkid -s UUID -o value "$part")
        KBOOT_MNT="$mnt"
        break 2
    done
done
[ -n "$KERN" ] || { echo "no vmlinuz found on any /dev/vda* partition" >&2; exit 1; }
# Strip the mount prefix: grub paths are relative to the searched filesystem.
KREL=${KERN#"$KBOOT_MNT"}
INIT=$(ls -1 "$KBOOT_MNT"${KREL/vmlinuz-/initrd.img-} 2>/dev/null | tail -1) || INIT=""
[ -n "$INIT" ] || INIT=$(ls -1 "$KBOOT_MNT"/initrd.img-* 2>/dev/null | tail -1) || INIT=""
# A virtio Ubuntu root needs its initrd to find the root device, so an empty
# INIT is a hard error, not something to paper over by emitting a bare "initrd"
# line that grub would try to load as a module path.
[ -n "$INIT" ] || { echo "no initrd.img alongside $KREL -- rescue entry would not boot" >&2; exit 1; }
IREL=${INIT#"$KBOOT_MNT"}

sed -e "s/__UBUNTU_BOOT_UUID__/${KBOOT_UUID}/" \
    -e "s/__UBUNTU_ROOT_UUID__/${ROOT_UUID}/" \
    -e "s|__UBUNTU_KERNEL__|${KREL}|" \
    -e "s|__UBUNTU_INITRD__|${IREL}|" \
    "$TEMPLATE" > "$TEMPLATE.tmp"
mv "$TEMPLATE.tmp" "$TEMPLATE"
chmod +x "$TEMPLATE"
# No unfilled placeholder may survive: an unresolved search --set=root makes the
# entry fail at boot with no obvious cause.
if grep -q '__UBUNTU_' "$TEMPLATE"; then
    echo "unresolved placeholders remain:" >&2
    grep -n '__UBUNTU_' "$TEMPLATE" >&2
    exit 1
fi
grub-mkconfig -o /boot/grub/grub.cfg
echo "RESCUE-ENTRY-OK boot_uuid=$KBOOT_UUID root_uuid=$ROOT_UUID kernel=$KREL initrd=$IREL"
