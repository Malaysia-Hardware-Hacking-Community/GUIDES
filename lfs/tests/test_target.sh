#!/usr/bin/env bash
# Tests for lfs/lib/target.sh -- the file that destroys data.
#
# No root and no loop devices here, so these split into two honest halves:
#
#   * The safety *logic* (mount parsing, root/swap detection, parent-disk
#     derivation, partition arithmetic) is tested for real against fixtures.
#   * The destructive *commands* are tested by running under LFS_DRY_RUN=1 and
#     asserting the exact command lines that would execute. That proves the
#     plan is not a separate, optimistic code path -- it is the same code.
#
# What this file does NOT do is verify a real mkfs or parted. That needs root
# and a disposable disk, and is done in the VM, not here.
#
# Run:  bash lfs/tests/test_target.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LFS_ROOT=$(cd "$HERE/.." && pwd)
export LFS_LOG=/dev/null
export LFS_DRY_RUN=1

source "$LFS_ROOT/installer.sh"

PASS=0
FAIL=0
FAILED_NAMES=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES $1"; printf '  FAIL %s\n     %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2
     actual:   $3"; fi; }

# expect_die LABEL -- run the rest of the args, expect a non-zero exit.
expect_die() {
    local label="$1"; shift
    if ( "$@" ) >/dev/null 2>&1; then bad "$label" "expected refusal, got success"
    else ok "$label"; fi
}

# A mount table standing in for /proc/self/mounts on a typical btrfs-on-LUKS host.
# Includes the two cases that break naive parsing: a real LUKS mapper, and a
# path with an escaped space.
write_mounts() {
    cat > "$1" <<'EOF'
/dev/mapper/root / btrfs rw,relatime,ssd,space_cache,subvolid=5,subvol=/@ 0 0
proc /proc proc rw,nosuid,nodev,noexec,relatime 0 0
sysfs /sys sysfs rw,nosuid,nodev,noexec,relatime 0 0
tmpfs /run tmpfs rw,nosuid,nodev,relatime,mode=755 0 0
/dev/mapper/root /home btrfs rw,relatime,ssd,subvolid=5,subvol=/@home 0 0
/dev/nvme0n1p2 /boot ext4 rw,relatime 0 0
/dev/nvme0n1p3 /var/log ext4 rw,relatime 0 0
/dev/sdb1 /mnt/my\040backup ext4 rw,relatime 0 0
EOF
}

M=$(mktemp -d)
write_mounts "$M/mounts"
export LFS_MOUNTS_FILE="$M/mounts"

# lsblk stand-in: no real devices, so answers from a fixed table.
cat > "$M/lsblk" <<'EOF'
#!/usr/bin/env bash
# Minimal lsblk stand-in for target.sh. Understands -ln -o NAME / -no PTTYPE
# and the subtree queries target.sh makes.
case "$*" in
  *PTTYPE*)
     for a in "$@"; do
       case "$a" in
         /dev/sda|/dev/sdb|/dev/vda|/dev/nvme0n1) echo "gpt" ;;
         /dev/sdc)                             echo "lvm2" ;;
       esac
     done ;;
  *"NAME,TYPE"*)
     case "$*" in
       *"/dev/sda"*) printf 'NAME TYPE\nsda disk\nsda1 part\nsda2 part\nsda3 part\n' ;;
       *"/dev/sdb"*) printf 'NAME TYPE\nsdb disk\nsdb1 part\n' ;;
       *"/dev/sdc"*) printf 'NAME TYPE\nsdc disk\n' ;;
       *"/dev/nvme0n1"*) printf 'NAME TYPE\nnvme0n1 disk\nnvme0n1p1 part\nnvme0n1p2 part\nnvme0n1p3 part\n' ;;
       *) printf 'NAME TYPE\n' ;;
     esac ;;
  *"-ln -o NAME"*)
     case "$*" in
       *"/dev/sda"*) printf 'NAME\nsda\nsda1\nsda2\nsda3\n' ;;
       *"/dev/sdb"*) printf 'NAME\nsdb\nsdb1\n' ;;
       *"/dev/nvme0n1"*) printf 'NAME\nnvme0n1\nnvme0n1p1\nnvme0n1p2\nnvme0n1p3\n' ;;
       *"/dev/sdc"*) printf 'NAME\nsdc\n' ;;
       *) printf 'NAME\n' ;;
     esac ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$M/lsblk"
export LFS_LSBLK="$M/lsblk"
# Stand in for devices we cannot create without root. target.sh refuses this
# unless LFS_DRY_RUN=1, so it cannot be used to bypass the gate for real.
export LFS_FAKE_BLOCKDEVS="/dev/sda /dev/sda1 /dev/sda2 /dev/sda3 /dev/sdb /dev/sdb1 /dev/sdc /dev/nvme0n1 /dev/nvme0n1p2"

echo "== 1. parent disk derivation (all three naming schemes) =="
check "sda1 -> sda"        "/dev/sda"     "$(target_parent_disk /dev/sda1)"
check "sdb12 -> sdb"       "/dev/sdb"     "$(target_parent_disk /dev/sdb12)"
check "nvme0n1p1 -> nvme0n1" "/dev/nvme0n1" "$(target_parent_disk /dev/nvme0n1p1)"
check "mmcblk0p2 -> mmcblk0" "/dev/mmcblk0" "$(target_parent_disk /dev/mmcblk0p2)"
# Whole disks whose names end in a digit. Get this wrong and a loopback target
# is read as a partition of a disk that does not exist, so it is mkfs'd whole
# with no partition table -- and every test built on it silently stops covering
# the layout code that only runs on a real target.
check "loop0 is a whole disk" "/dev/loop0" "$(target_parent_disk /dev/loop0)"
check "md0 is a whole disk"   "/dev/md0"   "$(target_parent_disk /dev/md0)"
check "dm-0 is a whole disk"  "/dev/dm-0"  "$(target_parent_disk /dev/dm-0)"
# ...and a PARTITION of one of those is a partition, not a whole disk. These
# names are ambiguous in exactly the way that made the bare cases above need
# their own handling: "loop1p2" also matches the bare-disk pattern
# "loop[0-9]*", so if the bare case is tested first the parent of loop1's
# second partition comes back as "loop1p2" itself. That is silent -- nothing
# complains, the name is just wrong -- and it is the answer the loopback
# layout tests use to decide which node is the disk.
for pair in "loop1p2 loop1" "loop10p3 loop10" "md0p1 md0" "nbd0p2 nbd0" \
            "dm-0p1 dm-0" "ram0p1 ram0"; do
    set -- $pair
    check "$1 is a partition of $2" "/dev/$2" "$(target_parent_disk "/dev/$1")"
done
# The whole-disk cases must NOT be truncated: this is the nvme trap, where
# naive s/[^0-9]// turns /dev/nvme0n1 into /dev/nvme0.
check "nvme0n1 -> nvme0n1"  "/dev/nvme0n1" "$(target_parent_disk /dev/nvme0n1)"
check "sda -> sda"          "/dev/sda"     "$(target_parent_disk /dev/sda)"

echo "== 2. next partition number =="
check "empty -> 1"            "1" "$(target_next_partition_number '')"
check "sda1 -> 2"             "2" "$(target_next_partition_number sda1)"
check "sda1 sda2 sda3 -> 4"   "4" "$(target_next_partition_number 'sda1 sda2 sda3')"
# Gaps must not be reused: a gap usually means a partition was deleted, and
# picking its number again is how a stale fstab entry silently finds new data.
check "gap sda1 sda3 -> 4"    "4" "$(target_next_partition_number 'sda1 sda3')"
check "nvme0n1p3 -> 4"        "4" "$(target_next_partition_number nvme0n1p3)"
check "full paths ignored"    "3" "$(target_next_partition_number '/dev/sda1 /dev/sda2')"

echo "== 3. mountpoint detection =="
# Field 2 only. When this passed the whole line through, "/boot ext4 rw 0 0"
# matched none of the case patterns below and root detection silently failed.
check "root mountpoint"  "/"      "$(target_mounts_of /dev/mapper/root | head -1)"
check "/boot mountpoint" "/boot" "$(target_mounts_of /dev/nvme0n1p2 | head -1)"
# All mountpoints of a multi-mount device, e.g. the btrfs subvolumes on Omarchy.
check "root device has 2 mounts" "2" "$(target_mounts_of /dev/mapper/root | wc -l)"
# Escaped space must be decoded, or the mountpoint string is wrong and any
# comparison built on it is wrong too.
check "escaped space decoded" "/mnt/my backup" "$(target_mounts_of /dev/sdb1 | head -1)"
check "unmounted device has none" "" "$(target_mounts_of /dev/sdz9)"

echo "== 4. host root detection =="
for d in /dev/mapper/root /dev/nvme0n1p2; do
    if target_is_host_root "$d"; then ok "root device refused: $d"
    else bad "root device refused: $d" "not detected as root"; fi
done
if target_is_host_root /dev/sdz9; then bad "unrelated device not root" "claimed root"
else ok "unrelated device is not root"; fi

echo "== 5. mounted-partition detection =="
# /dev/sda1..3 exist but none are mounted, so the disk is fair game.
if target_has_mounted_partition /dev/sda; then bad "sda has no mounted partitions" "claimed one"
else ok "sda has no mounted partitions"; fi
# sdb1 IS mounted (/mnt/my backup) -> the whole disk must be refused.
if target_has_mounted_partition /dev/sdb; then ok "sdb refused: sdb1 mounted"
else bad "sdb refused: sdb1 mounted" "not detected"; fi
# nvme0n1p2 and p3 are mounted.
if target_has_mounted_partition /dev/nvme0n1; then ok "nvme0n1 refused: p2/p3 mounted"
else bad "nvme0n1 refused: p2/p3 mounted" "not detected"; fi

echo "== 6. the safety gate refuses bad targets =="
expect_die "refuses relative path"        target_safety_gate sdb side-by-side
expect_die "refuses non-/dev path"        target_safety_gate /tmp/notadevice side-by-side
expect_die "refuses nonexistent device"   target_safety_gate /dev/definitely-not-here side-by-side
# A regular file is a plausible typo for a device and must not be formatted.
: > "$M/fake-disk"
expect_die "refuses regular file"         target_safety_gate "$M/fake-disk" side-by-side
# MODE is the switch that decides whether a whole disk gets erased, so a typo
# must fail at the gate instead of passing it and meaning something else later.
expect_die "refuses a missing MODE"        target_safety_gate /dev/sdb
expect_die "refuses a misspelled MODE"     target_safety_gate /dev/sdb sidebyside
expect_die "refuses an unknown MODE"       target_safety_gate /dev/sdb take-over

expect_die "refuses lvm2 member"          target_safety_gate /dev/sdc side-by-side
expect_die "refuses disk with mounted partition" target_safety_gate /dev/sdb side-by-side
expect_die "refuses mounted partition"    target_safety_gate /dev/nvme0n1p2 side-by-side
expect_die "refuses host root disk"       target_safety_gate /dev/nvme0n1 side-by-side

# An unmounted, unremarkable partition on a clean disk must be allowed --
# a gate that refuses everything is as broken as one that refuses nothing.
( target_safety_gate /dev/sda1 side-by-side ) >/dev/null 2>&1 \
    && ok "allows clean unmounted partition /dev/sda1" \
    || bad "allows clean unmounted partition /dev/sda1" "refused a safe target"

echo "== 7. the test-only escape hatch cannot be used for real =="
# LFS_FAKE_BLOCKDEVS makes /dev/sda look like a real block device. That is
# necessary to test the gate without root, and unacceptable if it can be
# enabled during a real run -- it would turn the block-device and existence
# checks off at exactly the moment they matter.
( LFS_DRY_RUN=0 target_safety_gate /dev/sda1 side-by-side ) >/dev/null 2>&1 \
    && bad "fake blockdev refused outside --plan" "gate accepted it" \
    || ok "fake blockdev refused outside --plan"
# A path that is a real regular file must still be refused even in dry-run,
# so the faked list is additive and can never authorise a non-device.
expect_die "regular file refused even with escape hatch" target_safety_gate "$M/fake-disk" side-by-side

echo "== 8. dry-run emits the real destructive commands =="
# Captures what run() would execute. The point is that --plan and the real path
# are the same code, so the plan cannot understate what will happen.
export LFS_LOG="$M/plan.log"
: > "$LFS_LOG"
target_prepare /dev/sda1 side-by-side
target_mount /dev/sda1
PLAN=$(cat "$LFS_LOG")
for expect in "mkfs.ext4 -F -L LFS /dev/sda1" "mount -t ext4 /dev/sda1 /mnt/lfs"; do
    case "$PLAN" in
        *"$expect"*) ok "plan contains: $expect" ;;
        *) bad "plan contains: $expect" "plan was:
$PLAN" ;;
    esac
done
# A whole disk in takeover must create a partition first, not format the disk.
: > "$LFS_LOG"
target_prepare /dev/sda takeover
PLAN=$(cat "$LFS_LOG")
# BIOS on GPT needs a BIOS boot partition ahead of the filesystem. Without it
# grub-install refuses to embed and then refuses the blocklist fallback, so the
# install gets all the way to the last stage and fails there. The type is the
# bios_grub GUID, not esp: grub-install is looking for one specific GUID.
for expect in "parted -s /dev/sda mklabel gpt" \
              "parted -s /dev/sda mkpart primary 1MiB 3MiB" \
              "parted -s /dev/sda set 1 bios_grub on" \
              "parted -s /dev/sda mkpart primary ext4 3MiB 100%" \
              "mkfs.ext4 -F -L LFS /dev/sda2"; do
    case "$PLAN" in
        *"$expect"*) ok "takeover plan contains: $expect" ;;
        *) bad "takeover plan contains: $expect" "plan was:
$PLAN" ;;
    esac
done

echo "== 9. side-by-side will not add a partition to an existing table =="
# The most important refusal in this file. Carving into a shared table is how
# a "side by side" install becomes a data-loss incident.
expect_die "refuses whole disk with existing partitions in side-by-side" \
    target_prepare /dev/sda side-by-side
# ...but takeover is exactly the case where that is allowed.
( target_prepare /dev/sda takeover ) >/dev/null 2>&1 \
    && ok "takeover of the same disk is allowed" \
    || bad "takeover of the same disk is allowed" "unexpectedly refused"

echo "== 10. planning has no side effects, and can be done before acting =="
# This is the ordering guarantee bootstrap.sh depends on: it must be able to
# resolve the target, ask the operator, and only then format. If target_plan
# emitted the mkfs, the prompt would necessarily come after the disk was
# already destroyed -- invisible under --plan, fatal in a real run.
: > "$LFS_LOG"
target_plan /dev/sda1 side-by-side
# An informational "plan:" line is fine and expected. What must not appear is any
# command that would change the disk.
PLANLOG=$(cat "$LFS_LOG")
case "$PLANLOG" in
    *mkfs*|*parted*|*"would run"*) bad "plan alone does not format" "log contained: $PLANLOG" ;;
    *) ok "plan alone does not format" ;;
esac
check "plan sets the target partition" "/dev/sda1" "$TARGET_PART"
check "plan sets the label" "sda1" "$TARGET_LABEL"

: > "$LFS_LOG"
target_plan /dev/sda takeover
# sda2, NOT sda4 or sda1 -- even though the stub /dev/sda already has
# sda1..sda3. Takeover runs `parted mklabel gpt`, which destroys the table, so
# the partition numbers it goes on to create are fixed: 1 for the BIOS boot
# partition and 2 for the filesystem. Predicting "one past the highest existing
# number" is right for side-by-side, where the table is shared and preserved, and
# wrong here: a re-run over a disk that already holds an LFS filesystem then
# formats a vdd2 that parted will never create, and dies on it.
LFS_FIRMWARE=bios check "takeover on BIOS predicts partition 2, after the BIOS boot partition" "/dev/sda2" "$TARGET_PART"
PLANLOG=$(cat "$LFS_LOG")
case "$PLANLOG" in
    *mkfs*|*parted*|*"would run"*) bad "takeover plan has no side effects" "log contained: $PLANLOG" ;;
    *) ok "takeover plan has no side effects" ;;
esac

# Side-by-side shares the table, so it really does have to pick a free number.
# Tested at the helper rather than through target_plan: target_plan REFUSES a
# partitioned whole disk in side-by-side, and that refusal is an `exit`, so it
# cannot be probed from here without killing the test.
check "next free partition is one past the highest (side-by-side)" "4" \
      "$(target_next_partition_number "sda1 sda2 sda3")"
check "next free partition is 1 on an empty disk" "1" \
      "$(target_next_partition_number "")"

# Re-planning must be idempotent, since target_prepare re-resolves.
: > "$LFS_LOG"
target_prepare /dev/sda1 side-by-side >/dev/null 2>&1
check "prepare after plan agrees on the partition" "/dev/sda1" "$TARGET_PART"

echo "== 90. spare-disk auto-detection =="
# This is the logic behind "just run it": with no --target, the script picks the
# one unused disk. A false positive here means erasing a disk that was never
# offered, so every exclusion is tested rather than assumed.
#
# LFS_LSBLK is pointed at a stub so the whole search runs against a described
# machine with no devices, no root and no kernel.
M=$(mktemp -d)
cat > "$M/lsblk-stub" <<'STUB'
#!/usr/bin/env bash
# Minimal lsblk stand-in driven by files in $STUB_DIR, used to describe a whole
# machine with no real devices attached.
#
# Handles combined short flags. target.sh calls lsblk as -snpo, -nlp, -ln -o, so
# a stub that only matched "-s" as its own argument would never see the flag at
# all and would silently answer from the wrong branch.
want_tree=0; cols=""; name=""; prev=""
for a in "$@"; do
    if [ "$prev" = "-o" ]; then cols="$a"; prev=""; continue; fi
    case "$a" in
        -o)  prev="-o"; continue ;;
        -*)  case "$a" in *s*) want_tree=1 ;; esac; continue ;;
        /dev/*) name="${a##*/}" ;;
    esac
    prev=""
done
if [ "$want_tree" = 1 ]; then
    sed 's/^[^A-Za-z0-9_.\/]*//' "$STUB_DIR/tree"
    exit 0
fi
if [ -z "$name" ]; then
    while read -r n t; do printf '%s %s\n' "$n" "$t"; done < "$STUB_DIR/names"
    exit 0
fi
c_type=$(printf '%s' "$cols" | tr ',' '\n' | grep -qx TYPE && echo 1)
c_mnt=$(printf '%s' "$cols" | tr ',' '\n' | grep -qx MOUNTPOINT && echo 1)
c_pk=$(printf '%s' "$cols" | tr ',' '\n' | grep -qx PKNAME && echo 1)
t=""; [ -f "$STUB_DIR/types" ]  && t=$(awk -v n="$name" '$1==n{print $2}' "$STUB_DIR/types")
m=""; [ -f "$STUB_DIR/mounts" ] && m=$(awk -v n="$name" '$1==n{print $2}' "$STUB_DIR/mounts")
pk=""; [ -f "$STUB_DIR/pkname" ] && pk=$(awk -v n="$name" '$1==n{print $2}' "$STUB_DIR/pkname")
# A specific-device query reports that device and then its partitions, which is
# how target_partitions_of and target_has_mounted_partition see anything at all.
mnt_of() { [ -f "$STUB_DIR/mounts" ] && awk -v n="$1" '$1==n{print $2}' "$STUB_DIR/mounts"; }
emit() { # emit NAME TYPE
    local line="$1"
    [ -n "$c_type" ] && line="$line $2"
    if [ -n "$c_mnt" ]; then line="$line $(mnt_of "$1")"; fi
    if [ -n "$c_pk" ];  then line="$line $pk"; fi
    printf '%s\n' "$line"
}
emit "$name" "${t:-disk}"
if [ -f "$STUB_DIR/parts" ]; then
    for p in $(awk -v n="$name" '$1==n{print $2}' "$STUB_DIR/parts"); do
        emit "$p" part
    done
fi
STUB
chmod +x "$M/lsblk-stub"
export LFS_LSBLK="$M/lsblk-stub"
export STUB_DIR="$M"

# describe NAME... -- declare the machine's disks, and RESET all other state.
# Resetting matters: each case describes a different machine, and a leftover
# partitions or mounts file from the previous case would silently make the next
# assertion pass or fail for the wrong reason.
describe() {
    : > "$M/names"; : > "$M/types"; : > "$M/mounts"; : > "$M/parts"
    for e in "$@"; do printf '%s disk\n' "$e" >> "$M/names"; done
}
no_pkname() { : > "$M/pkname"; }
boot_is() { printf '%s disk\n' "$1" > "$M/tree"; no_pkname; }

# 1. exactly one blank spare disk -> offered
describe vda vdb
boot_is vda
check "a single blank disk is offered" "/dev/vdb" "$(target_find_spare_disks)"

# 2. two blank spares -> both listed, caller decides (bootstrap refuses to guess)
describe vda vdb vdc
boot_is vda
check "two spares are both listed" "/dev/vdb
/dev/vdc" "$(target_find_spare_disks)"

# 3. the boot disk is never offered, even with nothing on it
describe vdb
boot_is vdb
check "the boot disk is not offered" "" "$(target_find_spare_disks)"

# 4. a disk with a mounted partition is not offered, even though the disk
#    itself is not mounted and its partition table is a perfectly normal gpt.
#    This is the case that matters most: a data disk looks blank from lsblk's
#    top-level listing.
describe vda vdb
printf 'vdb vdb1\n' > "$M/parts"
: > "$M/mounts"; printf 'vdb1 /data\n' > "$M/mounts"
boot_is vda
check "a disk with a mounted partition is not offered" "" "$(target_find_spare_disks)"
# ...and with the partition table but no mount, it is still not offered: the
#    disk is not blank, whatever is on it.
: > "$M/mounts"
check "a partitioned disk is not offered" "" "$(target_find_spare_disks)"

# 5. zram/loop/sr are never offered -- the bug that picked /dev/zram0 as "the
#    spare disk" on a real host. They report TYPE=disk and have no partitions.
describe vda vdb zram0 loop0 sr0
boot_is vda
check "zram/loop/sr are excluded" "/dev/vdb" "$(target_find_spare_disks)"

# 6. an unresolvable boot disk offers nothing at all rather than everything.
#    Failing closed matters: if we cannot tell which disk the system is on, the
#    safe answer is to ask, not to offer a list that might contain it.
describe vdb
: > "$M/tree"; : > "$M/mounts"
# Simulate by blanking the tree so target_boot_disk cannot resolve, and by
# taking findmnt off PATH so the fallback finds nothing either:
check "unresolvable boot disk yields no candidates" "" \
      "$(STUB_DIR="$M" bash -c '
          set -uo pipefail
          source "'"$LFS_ROOT"'/installer.sh"
          LFS_LSBLK="'"$M"'/lsblk-stub"
          # blank the tree so target_boot_disk cannot resolve
          : > "'"$M"'/tree"
          PATH=/nonexistent
          target_find_spare_disks 2>/dev/null')"

echo "== 91. target selection policy =="
# target_select is the difference between "attach one disk and press enter" and
# "a script that sometimes erases the wrong one". The cases that must NOT
# proceed are the point of these tests: each one here has to refuse, with a
# message that says what to do next.

# An explicit target is honoured without looking for spares at all, even when
# spares exist -- the operator naming a disk is the whole point.
describe vda vdb vdc
boot_is vda
check "an explicit target is used as given" \
    "/dev/vdc" "$(target_select /dev/vdc)"
check "an explicit partition target is used as given" \
    "/dev/vdb1" "$(target_select /dev/vdb1)"

# One spare: used automatically. This is the zero-config path.
describe vda vdb
boot_is vda
check "exactly one spare is chosen automatically" \
    "/dev/vdb" "$(target_select)"
# ...and the operator is told which disk was picked, after the fact.
out=$( target_select 2>&1 >/dev/null )
case "$out" in
    *"no --target given"*) ok "the automatic choice is announced" ;;
    *) bad "the automatic choice is announced" "got: $out" ;;
esac

# Zero spares: must stop, and must list the disks so the operator can see why.
describe vda
boot_is vda
if ( target_select ) >/dev/null 2>&1; then
    bad "no spares is refused" "exited 0"
else
    rc=$?
    [ "$rc" -eq 2 ] && ok "no spares is refused (rc=2)" \
                    || bad "no spares is refused (rc=2)" "rc=$rc"
fi
out=$( target_select 2>&1 )
case "$out" in
    *"no unused disk was found"*) ok "no spares explains itself" ;;
    *) bad "no spares explains itself" "got: $out" ;;
esac
case "$out" in
    *"--target"*) ok "no spares says how to proceed" ;;
    *) bad "no spares says how to proceed" "got: $out" ;;
esac

# Several spares: the dangerous case. Must refuse and list all of them, because
# "refusing" without saying what it saw is the same as failing to work.
describe vda vdb vdc
boot_is vda
if ( target_select ) >/dev/null 2>&1; then
    bad "several spares is refused" "exited 0 -- this would be a coin flip with an erase attached"
else
    ok "several spares is refused"
fi
out=$( target_select 2>&1 )
case "$out" in
    *"refusing to guess"*) ok "several spares says it will not guess" ;;
    *) bad "several spares says it will not guess" "got: $out" ;;
esac
for d in /dev/vdb /dev/vdc; do
    case "$out" in
        *"$d"*) ok "several spares lists $d" ;;
        *) bad "several spares lists $d" "got: $out" ;;
    esac
done
# Even if the operator has set LFS_I_UNDERSTAND, ambiguity is not overridable
# by the destructive-action acknowledgement. That flag means "I know this
# erases a disk", not "pick one of these for me".
out=$( LFS_I_UNDERSTAND=yes target_select 2>&1 )
case "$out" in
    *"refusing to guess"*) ok "LFS_I_UNDERSTAND does not resolve ambiguity" ;;
    *) bad "LFS_I_UNDERSTAND does not resolve ambiguity" "got: $out" ;;
esac

echo
echo "== 91. --resume reuses a target that already holds a build =="
# This is the bug that made --resume impossible in the default mode. Takeover
# re-partitions and re-formats on every run, so a re-run erased the very disk it
# was supposed to resume onto: the stage markers and the downloaded sources were
# destroyed, and the build silently started from stage 1 again, several hours
# later and looking like a fresh install.
#
# Tested for real here, against a loopback ext4 image, because the whole point
# is what mkfs and the filesystem contain. It skips itself without root rather
# than pretending to have covered the case.
SKIP_REASON=""
if [ "$(id -u)" != 0 ]; then
    SKIP_REASON="needs root (loop devices)"
elif ! command -v losetup >/dev/null 2>&1 || ! command -v mkfs.ext4 >/dev/null 2>&1; then
    SKIP_REASON="needs losetup and mkfs.ext4"
# parted is in this guard because target_prepare is what the section below calls,
# and it creates the partition table with parted. Without it in the guard the
# section ran, the partitioning silently did nothing, and three checks failed
# with messages about blkid and type GUIDs that pointed at the installer rather
# than at the missing tool. A skip that says why beats a failure that lies.
elif ! command -v parted >/dev/null 2>&1; then
    SKIP_REASON="needs parted (target_prepare writes the GPT with it)"
fi
if [ -n "$SKIP_REASON" ]; then
    printf '  skip --resume reuse tests: %s\n' "$SKIP_REASON"
else
    R=$(mktemp -d)
    IMG="$R/disk.img"
    truncate -s 256M "$IMG"
    LOOP=$(losetup --show -f -P "$IMG") || LOOP=""
    if [ -z "$LOOP" ]; then
        printf '  skip --resume reuse tests: losetup found no free device\n'
        rm -rf "$R"
    else
        MNT="$R/mnt"; mkdir -p "$MNT"
        cleanup() { umount "$MNT" 2>/dev/null; losetup -d "$LOOP" 2>/dev/null; rm -rf "$R"; }
        trap cleanup EXIT

        # A blank disk has no build on it, so it must be formatted as usual --
        # and the layout has to be the real one, because a stub cannot tell you
        # whether `parted set 1 bios_grub on` is even accepted.
        P1=$(target_partition_path "$LOOP" 1)
        P2=$(target_partition_path "$LOOP" 2)
        ( LFS_TARGET_MOUNT="$MNT" LFS_DRY_RUN=0 LFS_FIRMWARE=bios \
          target_prepare "$LOOP" takeover ) >/dev/null 2>&1
        if [ "$(blkid -s TYPE -o value "$P2" 2>/dev/null)" = ext4 ]; then
            ok "a blank target is still formatted (resume does not skip the mkfs)"
        else
            bad "a blank target is still formatted (resume does not skip the mkfs)" \
                "blkid on $P2 says: $(blkid -s TYPE -o value "$P2" 2>/dev/null)"
        fi
        # grub-install looks for one specific partition GUID here. An ESP
        # partition, which is what most guides tell you to make, has a different
        # one and is rejected, so the whole install fails at the last stage.
        GPT_BIOS_BOOT=21686148-6449-6E6F-744E-656564454649
        P1_GUID=$(blkid -s UUID -o value "$P1" 2>/dev/null)
        if [ "$P1_GUID" = "$GPT_BIOS_BOOT" ]; then
            ok "BIOS boot partition has the bios_grub type GUID grub-install wants"
        elif parted -s "$LOOP" unit MiB print 2>/dev/null | grep -q 'bios_grub'; then
            ok "BIOS boot partition has the bios_grub type GUID grub-install wants"
        else
            bad "BIOS boot partition has the bios_grub type GUID grub-install wants" \
                "type/UUID on $P1 was: ${P1_GUID:-none}"
        fi
        if [ -n "$(blkid -s TYPE -o value "$P1" 2>/dev/null)" ] \
           && [ "$(blkid -s TYPE -o value "$P1" 2>/dev/null)" != "partition" ]; then
            bad "BIOS boot partition is left unformatted" \
                "it carries a filesystem: $(blkid -s TYPE -o value "$P1")"
        else
            ok "BIOS boot partition is left unformatted"
        fi

        # Now make it look like a build this installer had already done.
        mount "$P2" "$MNT" 2>/dev/null
        mkdir -p "$MNT/.stages" "$MNT/usr" "$MNT/sources"
        : > "$MNT/.stages/sources.done"
        INODE_BEFORE=$(stat -c %i "$MNT/.stages/sources.done")
        umount "$MNT" 2>/dev/null

        # With LFS_TARGET_RESUMING=1 the filesystem must survive untouched, and
        # the checkpoint on it must be the same inode afterwards.
        ( LFS_TARGET_MOUNT="$MNT" LFS_DRY_RUN=0 LFS_TARGET_RESUMING=1 \
          target_prepare "$LOOP" takeover ) >/dev/null 2>&1
        # $P2, not $LOOP: the build lives on the partition. Mounting the whole
        # loop disk would find nothing and the test would report the resume as
        # having destroyed the build.
        mount "$P2" "$MNT" 2>/dev/null
        if [ -f "$MNT/.stages/sources.done" ] \
           && [ "$(stat -c %i "$MNT/.stages/sources.done")" = "$INODE_BEFORE" ]; then
            ok "a resuming target keeps its filesystem and its stage markers"
        else
            bad "a resuming target keeps its filesystem and its stage markers" \
                "the checkpoint is gone: the resume erased the disk it was resuming onto"
        fi
        umount "$MNT" 2>/dev/null

        # And without the resume flag the same disk is still erased, because
        # takeover means takeover.
        ( LFS_TARGET_MOUNT="$MNT" LFS_DRY_RUN=0 \
          target_prepare "$LOOP" takeover ) >/dev/null 2>&1
        mount "$P2" "$MNT" 2>/dev/null
        if [ -e "$MNT/.stages/sources.done" ]; then
            bad "takeover without --resume still erases" "the old build survived"
        else
            ok "takeover without --resume still erases"
        fi
        umount "$MNT" 2>/dev/null
        trap - EXIT
        cleanup
    fi
fi

echo

rm -rf "$M"
unset LFS_LSBLK STUB_DIR

# ---------------------------------------------------------------------------
echo "== 20. REAL UEFI takeover layout on a loop device (root only) =="
# This is the one part that cannot be faked, and the part a UEFI install
# cannot work without: that target_prepare really produces a 2-partition GPT
# whose partition 1 carries the EFI System type GUID and a FAT32 filesystem.
#
# Two real bugs were found by running exactly this, both invisible to dry-run
# assertions because the commands themselves were correct:
#   * target_esp_for asked lsblk for PARTUUID (the random per-partition id)
#     instead of PARTTYPE (the type GUID), so it could never recognise an ESP
#     it had just created -- every UEFI takeover died "no EFI System
#     partition was found".
#   * the layout message interpolated "${dev}1", which is /dev/loop11 for a
#     loop device rather than /dev/loop1p1.
# It skips cleanly without root, which is why the same coverage is a hard
# requirement in the guest, not a nicety.
if [ "$(id -u)" != 0 ]; then
    printf '  skip real UEFI layout test: needs root (run in the build VM)\n'
else
    IMG=$(mktemp -u /tmp/lfs-uefi-XXXXXX.img)
    truncate -s 8G "$IMG" 2>/dev/null
    LOOP=$(losetup -f --show "$IMG" 2>/dev/null)
    if [ -z "$LOOP" ] || [ ! -b "$LOOP" ]; then
        printf '  skip real UEFI layout test: no free loop device\n'
        rm -f "$IMG"
    else
        # target_prepare calls run/die/say, which log to LFS_LOG (/dev/null here)
        # and honour LFS_DRY_RUN. Turn dry-run OFF for this section so parted
        # and mkfs really run; it is a throwaway image.
        LFS_DRY_RUN=0
        export LFS_FIRMWARE=uefi
        export LFS_TARGET_RESUMING=0
        target_prepare "$LOOP" takeover >/dev/null 2>&1
        P1="$(target_partition_path "$LOOP" 1)"
        P2="$(target_partition_path "$LOOP" 2)"
        # Filesystem types and labels, straight from blkid.
        check "uefi p1 is FAT32"     "vfat"  "$(blkid -s TYPE  -o value "$P1" 2>/dev/null)"
        check "uefi p1 label is EFI" "EFI"   "$(blkid -s LABEL -o value "$P1" 2>/dev/null)"
        check "uefi p2 is ext4"      "ext4"  "$(blkid -s TYPE  -o value "$P2" 2>/dev/null)"
        check "uefi p2 label is LFS" "LFS"   "$(blkid -s LABEL -o value "$P2" 2>/dev/null)"
        # The ESP *type* is what firmware keys on. A FAT32 partition without it
        # is invisible to firmware no matter what is in it, so assert the GUID.
        PT="$(lsblk -ndo PARTTYPE "$P1" 2>/dev/null | tr -d '-' | tr 'A-Z' 'a-z')"
        check "uefi p1 has the ESP type GUID" "c12a7328f81f11d2ba4b00a0c93ec93b" "$PT"
        # The functions the rest of the install relies on to find that ESP.
        check "TARGET_ESP is p1"       "$P1"       "$TARGET_ESP"
        check "target_esp_for finds p1" "$P1"      "$(target_esp_for "$LOOP")"
        check "TARGET_PART is p2"      "$P2"       "$TARGET_PART"
        check "parent of p2 is the disk" "$LOOP"   "$(target_parent_disk "$P2")"
        unset TARGET_ESP TARGET_PART
        LFS_DRY_RUN=1
        export LFS_FIRMWARE=bios
        losetup -d "$LOOP" 2>/dev/null
        rm -f "$IMG"
    fi
fi

echo "================================"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf 'failing:%s\n' "$FAILED_NAMES"
    exit 1
fi
printf 'ALL TARGET SAFETY TESTS PASSED\n'
exit 0
