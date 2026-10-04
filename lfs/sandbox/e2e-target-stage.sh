#!/usr/bin/env bash
# E2E: exercise the real destructive target path on the disposable disk.
# Run inside the guest as root. Does NOT run the LFS build (hours) and does
# NOT touch the bootloader (needs a built kernel); it proves that detection,
# the safety gate, partitioning, formatting and mounting all work on real
# hardware rather than against fixtures.
set -uo pipefail
cd /root/lfs || exit 1
export LFS_LOG=/var/log/lfs-e2e.log
export LFS_DRY_RUN=0
export LFS_I_UNDERSTAND=yes

source lib/common.sh
source lib/detect.sh
source lib/deps.sh
source lib/target.sh

TARGET=/dev/vdc

echo "### 1. detection"
lfs_detect_all || exit 1
echo "distro=$LFS_DISTRO name=$LFS_DISTRO_NAME firmware=$LFS_FIRMWARE arch=$LFS_ARCH"

echo
echo "### 2. safety gate (must pass: unused disk)"
target_safety_gate "$TARGET" side-by-side && echo "GATE: allowed" || { echo "GATE: refused"; exit 1; }

echo
echo "### 3. plan (pure, no side effects)"
target_plan "$TARGET" side-by-side || exit 1
echo "planned partition: $TARGET_PART (label $TARGET_LABEL)"

echo
echo "### 4. prepare (parted + mkfs)"
target_prepare "$TARGET" side-by-side || exit 1

echo
echo "### 5. mount"
target_mount "$TARGET_PART" || exit 1

echo
echo "### 6. verify on real hardware"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$TARGET"
echo "--- new partition table ---"
parted -s "$TARGET" print
echo "--- blkid ---"
blkid "$TARGET_PART"
echo "--- mount table ---"
findmnt -no SOURCE,FSTYPE,OPTIONS,TARGET "$LFS_TARGET_MOUNT"
echo "--- write/read test through the mount ---"
mountpoint -q "$LFS_TARGET_MOUNT" || { echo "NOT MOUNTED"; exit 1; }
dd if=/dev/urandom of="$LFS_TARGET_MOUNT/probe" bs=1M count=8 status=none
sync
md5sum "$LFS_TARGET_MOUNT/probe"
echo "free space: $(df -h "$LFS_TARGET_MOUNT" | tail -1 | awk '{print $4}')"
rm -f "$LFS_TARGET_MOUNT/probe"
echo
echo "### E2E TARGET STAGE OK"
