#!/usr/bin/env bash
# Target selection, safety gating, and preparation for the LFS target.
#
# Sourced, not executed. This is the most dangerous file in the project: it is
# the only one that destroys data. Two rules follow from that and shape the
# whole design:
#
#   1. Every destructive command goes through run/runsh, so --plan prints the
#      real commands without running them. There is no separate "preview" code
#      path that could drift from what actually executes.
#   2. Refusal is the default. Every check below fails closed and fails with a
#      message naming the specific reason, because "refused" without a reason
#      is indistinguishable from a bug.
#
# The target is always explicit. Nothing here ever scans for free space or
# picks a device on the operator's behalf.

[ -n "${_LFS_TARGET_SH:-}" ] && return 0
_LFS_TARGET_SH=1

# Injectable for tests; the test suite has no real block devices and no real
# /proc. Overridable so the safety logic is testable rather than assumed.
: "${LFS_MOUNTS_FILE:=/proc/self/mounts}"
: "${LFS_TARGET_MOUNT:=/mnt/lfs}"
: "${LFS_LSBLK:=lsblk}"

# Size of the EFI System partition created on a whole-disk UEFI takeover.
# 512 MiB is the smallest size that is comfortable rather than merely legal:
# GRUB's EFI payload is ~10 MiB, a kernel plus modules is ~150 MiB, and firmware
# implementations are known to misbehave with ESPs under ~100 MiB. 512 leaves
# room for several kernels and still reads as a rounding error next to a build
# filesystem. Overridable for a disk that is genuinely tiny.
: "${LFS_ESP_SIZE_MB:=512}"

# ---------------------------------------------------------------- pure logic

# target_parent_disk DEV -> /dev/sda1 => /dev/sda
# Handles the three naming schemes that all exist in the wild, which is the
# whole reason this is a function and not a sed:
#   sda1     -> sda        (strip trailing digits)
#   nvme0n1p1 -> nvme0n1   (strip digits after the 'p' partition marker)
#   mmcblk0p1 -> mmcblk0
target_parent_disk() {
    local d="$1" base="${1##*/}" parent
    # Order matters. Case patterns match a *substring*, so nvme*n[0-9] also
    # matches "nvme0n1p2" -- the p-suffix case must therefore be tested first.
    case "$base" in
        # A PARTITION of a p-named whole disk, tested before the bare-disk case
        # below. "loop1p2" is loop1's second partition; it also matches the
        # bare-disk pattern "loop[0-9]*", so testing that first would hand back
        # "loop1p2" as if it were a whole disk. The trailing "[0-9]" anchors
        # each of these patterns at the end, which is the whole distinction:
        # "loop*p[0-9]" needs the 'p', so bare "loop0" cannot match it.
        loop*p[0-9]|md*p[0-9]|nbd*p[0-9]|ram*p[0-9]|dm-*p[0-9])
            parent="${base%p[0-9]*}" ;;      # loop1p2 -> loop1, dm-0p1 -> dm-0
        # Bare whole disks. "loop0" is not partition 0 of a disk called "loop";
        # it is a disk called loop0 -- but it literally ends in "p0", so the
        # nvme rule further down matches it and strips that to "loo". Getting
        # this wrong made a loopback target get mkfs'd whole with no partition
        # table at all, so the layout code that only runs on a real target was
        # never exercised by anything.
        loop[0-9]*|md[0-9]*|nbd[0-9]*|ram[0-9]*|dm-[0-9]*) parent="$base" ;;
        *p[0-9]*)    parent="${base%p[0-9]*}" ;;  # nvme0n1p2, mmcblk0p1
        nvme*n[0-9]) parent="$base" ;;            # nvme0n1: digit is part of the name
        mmcblk[0-9]) parent="$base" ;;            # mmcblk0
        *[0-9])      parent="${base%%[0-9]*}" ;;  # sda1, vdb12
        *)           parent="$base" ;;            # vdb
    esac
    case "$d" in
        */*) printf '%s/%s' "${d%/*}" "$parent" ;;
        *)   printf '%s' "$parent" ;;
    esac
}

# target_next_partition_number "sda1 sda2" -> 3
# Takes a *list of existing partition names* rather than a device, so the
# arithmetic is testable without lsblk or a real disk.
target_next_partition_number() {
    local existing="$1" max=0 n
    for n in $existing; do
        n="${n##*/}"
        # Isolate the digits: strip everything up to and including the last
        # non-digit. Stripping the *trailing* digits instead leaves the letters
        # behind, and "sda" then fails the integer test below.
        case "$n" in
            *p[0-9]*) n="${n##*p}" ;;         # nvme0n1p3 -> 3
            *[0-9])   n="${n##*[!0-9]}" ;;    # sda12    -> 12
            *)        n=0 ;;
        esac
        [ "$n" -gt "$max" ] 2>/dev/null && max="$n"
    done
    printf '%d' $((max + 1))
}

# target_partition_path DEV N -- the device node for partition N of DEV.
#
# Two schemes are in use and they are not interchangeable. sd, vd and hd number
# partitions by appending: /dev/vdd -> /dev/vdd1. nvme, mmcblk and loop append a
# "p" first: /dev/nvme0n1 -> /dev/nvme0n1p1, /dev/loop0 -> /dev/loop0p1.
#
# Building the name by appending alone is not a harmless guess. On an nvme
# target, /dev/nvme0n11 does not exist, so the resume check walked past a
# completely good build, decided the target was blank, and reformatted it. That
# is the one mistake this file must not make.
target_partition_path() {
    local dev="$1" n="$2"
    if [ -b "${dev}${n}" ]; then printf '%s\n' "${dev}${n}"; return 0; fi
    if [ -b "${dev}p${n}" ]; then printf '%s\n' "${dev}p${n}"; return 0; fi
    # No node yet -- it appears only after the table is written. Guess from the
    # device name, because "append a digit" is a guess that is wrong for half of
    # the block devices Linux offers.
    case "${dev##*/}" in
        nvme*|mmcblk*|loop*|nbd*|md*|dm-*) printf '%sp%s\n' "$dev" "$n" ;;
        *)                                  printf '%s%s\n' "$dev" "$n" ;;
    esac
}

# target_kernel_name /dev/sda1 -> sda1  (what lsblk and parted expect)
target_kernel_name() { printf '%s' "${1##*/}"; }

# ------------------------------------------------------------------- checks

# target_mounts_of DEV -- every mountpoint backed by DEV, from LFS_MOUNTS_FILE.
# Handles the octal escaping the kernel uses in /proc/self/mounts
# (\040 for space, \011 for tab, \134 for backslash) because a path containing
# a space is exactly the case where a naive comparison silently mismatches and
# a real mountpoint gets missed by the safety check.
target_mounts_of() {
    local want="${1##*/}" mp dev
    [ -r "$LFS_MOUNTS_FILE" ] || return 0
    # Project $1/$2 with awk rather than `read -r dev mp`: a two-variable read
    # assigns the remainder of the line to mp, so every mountpoint would come
    # back as "/boot ext4 rw,relatime 0 0", match no case pattern in
    # target_is_host_root, and the root-device check would silently pass.
    while IFS=$'\t' read -r dev mp; do
        [ -n "$dev" ] || continue
        if [ "${dev##*/}" = "$want" ]; then
            # Unescape in the same order the kernel escapes, so a \1340 does
            # not become a space.
            mp=$(printf '%s' "$mp" | sed 's/\\040/ /g; s/\\011/	/g; s/\\134/\\/g')
            printf '%s\n' "$mp"
        fi
    done < <(awk 'NF>=2 {print $1"\t"$2}' "$LFS_MOUNTS_FILE")
}

# target_is_host_root DEV -- true if DEV backs the running system.
target_is_host_root() {
    local mp
    while read -r mp; do
        case "$mp" in
            /|/boot|/boot/*) return 0 ;;
        esac
    done < <(target_mounts_of "$1")
    return 1
}

# target_is_host_swap DEV
target_is_host_swap() {
    target_mounts_of "$1" | grep -q '^/proc/swaps$' && return 0
    local mp
    while read -r mp; do
        case "$mp" in /dev/shm|/run/*) ;; esac
    done < <(target_mounts_of "$1")
    grep -qE "[[:space:]]$1[[:space:]]" /proc/swaps 2>/dev/null && return 0
    return 1
}

# target_has_mounted_partition DEV -- any partition of a disk currently in use.
# This is what stops a whole-disk target from taking a disk the host is still
# booting from, even if the parent itself shows no mountpoints.
target_has_mounted_partition() {
    local parent part
    parent=$(target_parent_disk "$1")
    while read -r part; do
        [ -n "$part" ] || continue
        [ "$part" = "$1" ] && continue
        [ -n "$(target_mounts_of "$part")" ] && return 0
    done < <(target_children_of "$parent")
    return 1
}

# target_children_of DEV -- partition names, via lsblk.
target_children_of() {
    $LFS_LSBLK -ln -o NAME "$1" 2>/dev/null | tail -n +2
}

# target_select [EXPLICIT]
# Print the device to build onto. With EXPLICIT, that is the answer. Without
# it, exactly one unused disk must be found -- zero or several is an error that
# returns 2, never a guess. Picking "the first of several" would be a coin flip
# with an erase attached to it.
target_select() {
    if [ -n "${1:-}" ]; then
        printf '%s\n' "$1"
        return 0
    fi
    local spares n
    spares=$(target_find_spare_disks)
    n=$(printf '%s' "$spares" | grep -c . || true)
    if [ "$n" -eq 1 ]; then
        # Always say which disk, loudly and unmissably, before it gets
        # partitioned. An automatic choice the operator did not make is exactly
        # the case where they most need to be told.
        say "no --target given; using the only unused disk found: $spares" >&2
        printf '%s\n' "$spares"
        return 0
    fi
    if [ "$n" -eq 0 ]; then
        say "no --target given, and no unused disk was found.
$($LFS_LSBLK -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null)

Attach a blank disk to this machine, or name one explicitly:
  --target /dev/DEVICE" >&2
    else
        say "no --target given, and $n unused disks were found -- refusing to guess:
$(printf '%s\n' "$spares")

Name the one you want:
  --target /dev/DEVICE" >&2
    fi
    return 2
}

# target_partitions_of DEV -- only the partitions (children of the disk itself).
target_partitions_of() {
    $LFS_LSBLK -ln -o NAME,TYPE "$1" 2>/dev/null | tail -n +2 | awk '$2=="part"{print $1}'
}

# target_is_blockdev DEV
# LFS_FAKE_BLOCKDEVS exists only so the test suite can stand in for devices it
# cannot create without root. It is empty in normal use, so the real -b test
# is what always runs.
target_is_blockdev() {
    # shellcheck disable=SC2086  # word-list argument, as above
    in_list "$1" ${LFS_FAKE_BLOCKDEVS:-} && return 0
    [ -b "$1" ]
}

# ----------------------------------------------------------------- the gate

# target_safety_gate DEV MODE -- refuse anything suspicious. Exits non-zero via
# die on refusal. MODE is side-by-side|takeover.
#
# The distinction that matters: in side-by-side mode a *whole disk* that
# already has a partition table is refused outright, because carving space into
# it means modifying a table something else may depend on. In takeover mode the
# same disk is fine, because the whole point is to replace it.

# target_find_spare_disks -- print every whole disk that looks unused.
#
# Powers "just run it": with no --target, the bootstrap needs to work out which
# disk is the spare one. A disk qualifies only if ALL of the following hold:
#
#   * it is a whole disk, not a partition (lsblk TYPE=disk)
#   * it has no partitions at all
#   * none of it is mounted
#   * it is not the device the system booted from
#   * it holds no swap
#   * it is not part of a RAID or LVM group
#
# Anything less and the disk is somebody's data, so it is not a candidate. The
# caller decides what to do with the list; this function never picks.
target_find_spare_disks() {
    local disk name boot

    # Resolve the boot disk once, up front. If we cannot work out which disk the
    # system is running from, every other check below is unreliable -- the boot
    # disk is the one disk that must never appear in this list -- so report
    # nothing and let the caller ask the user to pass --target.
    boot=$(target_boot_disk)
    if [ -z "$boot" ]; then
        warn "could not determine which disk this system booted from; not offering
any automatic target choice. Pass --target explicitly."
        return 0
    fi

    # -d TYPE=disk, -n no header. $LFS_LSBLK is overridable so the test suite
    # can feed it fixtures.
    #
    # TYPE=disk is necessary but NOT sufficient: zram, loop, ram, sr and friends
    # all report TYPE=disk. Left unfiltered, /dev/zram0 -- a compressed
    # block device carved out of RAM -- matches every remaining test on a host
    # with no zram swap, and gets picked as "the spare disk". Partitioning one
    # of those is nonsense at best.
    for name in $($LFS_LSBLK -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
        case "$name" in
            # Virtual/pseudo block devices that are not real disks. Matched on
            # the whole name, so a real disk called "sda" is unaffected while
            # "sr0", "zram0", "loop0", "ram0" and friends are skipped.
            zram*|ram*|loop*|sr*|fd*|dm-*|md*|nbd*|zfs*|rdisk*) continue ;;
        esac
        disk="/dev/$name"
        # Under --plan this works from what lsblk reports rather than from what
        # is openable in this namespace, so the test suite can drive it with a
        # described machine that has no real devices. The real existence check
        # belongs to target_safety_gate, which runs on the real path and is not
        # skipped there.
        if [ "${LFS_DRY_RUN:-0}" != 1 ]; then
            [ -e "$disk" ] || continue
        fi

        # Partitions present => something is already laid out on it.
        [ -z "$(target_partitions_of "$disk")" ] || continue

        # Any mount anywhere on this disk (including on its partitions).
        if target_has_mounted_partition "$disk" 2>/dev/null; then continue; fi

        # The disk the running system booted from is never spare, whatever its
        # partition table looks like.
        [ "$disk" = "$boot" ] && continue

        # Any swap on it.
        target_is_host_swap "$disk" && continue

        # RAID/LVM members are someone else's storage.
        if $LFS_LSBLK -ndo TYPE "$disk" 2>/dev/null | grep -qE '^(raid[0-9]+|lvm|crypt|LVM2_member|linux_raid_member)$'; then
            continue
        fi

        printf '%s\n' "$disk"
    done
}

# target_boot_disk -- the whole disk this system booted from.
#
# Returns empty if it cannot be determined, which callers MUST treat as "unknown",
# never as "none". Guessing wrong here would classify the running system's own
# disk as spare, so an empty answer has to stop the search rather than permit it.
#
# Two things make this harder than it looks, and both are handled:
#   * a btrfs subvolume root: findmnt reports /dev/nvme0n1p2[/@], whose basename
#     is "@]" -- not a device. Strip the [subvol] part before taking a name.
#   * an LVM/crypt root: findmnt reports /dev/mapper/vg-root, whose basename is
#     "root". Those are resolved by asking lsblk for the parent instead.
target_boot_disk() {
    local src parent disk

    # lsblk's MOUNTPOINT column reports where a filesystem is mounted, which
    # sidesteps the subvolume syntax entirely; -p makes NAME a full path.
    src=$($LFS_LSBLK -nlp -o NAME,MOUNTPOINT 2>/dev/null \
          | awk '$NF=="/" && NF==2 {print $1; exit}')
    if [ -z "$src" ]; then
        src=$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*\]//')
    fi
    [ -n "$src" ] || return 0
    case "$src" in
        /dev/*) ;;
        *) return 0 ;;    # overlay, tmpfs, network root: no disk to name
    esac

    # Resolve to a real whole disk. Asking for the device tree is what gets
    # through device-mapper: a root on LVM-over-LUKS is /dev/mapper/root, and
    # PKNAME of a dm node is just the dm node again, so a PKNAME-only walk
    # would stop there and report a path that is not in the disk list at all --
    # which would then fail to match, and the system disk would look spare.
    # -s walks ancestors; sed strips the tree-drawing prefix so awk sees names.
    # -p already prints /dev/... , so normalise rather than blindly prefixing
    # (which would yield /dev//dev/nvme0n1).
    local disk
    disk=$($LFS_LSBLK -snpo NAME,TYPE "$src" 2>/dev/null \
           | sed 's/^[^A-Za-z0-9_.\/]*//' \
           | awk '$2=="disk"{n=$1; sub("^/dev/","",n); print "/dev/"n; exit}')
    if [ -n "$disk" ]; then
        printf '%s' "$disk"
        return 0
    fi

    # Fallback for a host whose lsblk cannot render a tree: climb PKNAME. The
    # cap stops a pathological dm loop from spinning.
    local i
    for i in 1 2 3; do
        local parent
        parent=$($LFS_LSBLK -ndo PKNAME "$src" 2>/dev/null | tr -d '[:space:]')
        [ -n "$parent" ] || break
        src="/dev/$parent"
    done
    printf '%s' "$src"
}

# target_safety_gate DEV MODE -- refuse anything unsafe to destroy. Runs in
# --plan too, so a plan is never a false promise.
target_safety_gate() {
    local dev="$1" mode="${2:-}" parent

    # MODE selects no check below, but it is validated anyway. It is the switch
    # that decides whether the whole disk gets erased, so a typo must fail here
    # loudly rather than pass a gate and then mean something else downstream --
    # and a missing argument should say so, not die on an unbound variable.
    case "$mode" in
        side-by-side|takeover) ;;
        "") die "target_safety_gate: MODE is required (side-by-side or takeover)" ;;
        *) die "target_safety_gate: unknown MODE '$mode' (side-by-side or takeover)" ;;
    esac

    # Explicit, absolute, real device path. Rejecting relative paths and
    # non-/dev locations keeps "lfs-bootstrap.sh --target sdb" from ever being
    # interpreted as a file in the current directory.
    case "$dev" in
        /dev/*) ;;
        *) die "target must be an absolute /dev/ path, got: $dev" ;;
    esac
    if [ "$dev" != "$(readlink -f "$dev" 2>/dev/null || printf '%s' "$dev")" ]; then
        say "note: $dev is a symlink to $(readlink -f "$dev")"
    fi
    # If the test escape hatch is set, make it loud. In a real run, silently
    # treating a non-existent path as a block device would disable the very
    # checks this function exists to perform.
    if [ -n "${LFS_FAKE_BLOCKDEVS:-}" ] && [ "${LFS_DRY_RUN:-0}" != 1 ]; then
        die "LFS_FAKE_BLOCKDEVS is a test-only setting and is refused outside --plan"
    fi
    # shellcheck disable=SC2086  # word-list argument, as above
    if ! in_list "$dev" ${LFS_FAKE_BLOCKDEVS:-}; then
        [ -e "$dev" ] || die "target does not exist: $dev"
    fi
    target_is_blockdev "$dev" || die "target is not a block device: $dev"

    # A mounted target, whatever it is mounted at, is never touched.
    local mps
    mps=$(target_mounts_of "$dev")
    if [ -n "$mps" ]; then
        die "target is mounted, refusing:
$(printf '%s\n' "$mps" | sed 's/^/  /')
Unmount it first, or pick a different target."
    fi

    target_is_host_root "$dev" && die "target is part of the running system's root filesystem: $dev"
    target_is_host_swap "$dev" && die "target is in use by swap: $dev"

    parent=$(target_parent_disk "$dev")
    if [ "$parent" != "$dev" ]; then
        target_has_mounted_partition "$dev" \
            && die "another partition of $parent is mounted; refusing to touch $dev"
    else
        # Whole-disk target: refuse if any partition of it is mounted.
        if target_has_mounted_partition "$dev"; then
            # The generic "you booted from this disk" wording is wrong for the
            # case that actually happens in practice: a previous run of THIS
            # installer died, and left its own build mounted at LFS_TARGET_MOUNT.
            # That is the documented recovery path -- re-run with --resume -- and
            # refusing here with a message about booting from the wrong disk
            # sends the reader looking for a problem they do not have.
            if [ -n "$LFS_TARGET_RESUMING" ] && mountpoint -q "$LFS_TARGET_MOUNT" 2>/dev/null; then
                die "$dev is still mounted at $LFS_TARGET_MOUNT from an earlier run of this installer.
That mount is left over, not something you booted from. Clear it, then run --resume again:
    umount -R $LFS_TARGET_MOUNT
If that reports 'target is busy', a process from the old build is still running with its
working directory on the target -- OpenSSL's test suite is the usual culprit. Find it with:
    fuser -vm $LFS_TARGET_MOUNT
and stop it before unmounting."
            fi
            die "$dev has mounted partitions, refusing to touch the whole disk.
If this is meant to be a takeover, that disk must not be the one you booted from."
        fi
    fi

    # Refuse devices that are members of a stack we do not understand. Writing
    # an ext4 filesystem onto an LVM physical volume or a RAID member destroys
    # the array, and neither lsblk PARTUUID nor a raw mkfs will warn.
    local pttype
    # Trim: some lsblk versions and wrappers emit a blank line, and a leading
    # newline would stop "\nlvm2" from matching the lvm2 case arm below and let
    # an LVM physical volume through to mkfs.
    pttype=$($LFS_LSBLK -no PTTYPE "$dev" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$pttype" ]; then
        say "target $dev has partition table type: $pttype"
        case "$pttype" in
            gpt|dos|msdos) ;;
            lvm2|raid1|raid5|raid10|isw_raid_member|LVM2_member) 
                die "target is a $pttype member; refusing to write a filesystem over it" ;;
            *) warn "unrecognised partition table type '$pttype' on $dev" ;;
        esac
    fi

    return 0
}

# -------------------------------------------------------------- preparation

# target_plan DEV MODE -- resolve which partition will be used and say what will
# happen. NO side effects.
#
# Split out from target_prepare so the caller can run confirm_irreversible
# *between* deciding and doing. If prepare() both decided and acted, the
# confirmation would necessarily land after the mkfs had already run -- which
# looks correct under --plan, because nothing executes there, and destroys the
# disk in a real run before the prompt is ever shown.
#
# Sets TARGET_PART and TARGET_LABEL.
target_plan() {
    local dev="$1" mode="$2" existing partnum

    if [ "$dev" = "$(target_parent_disk "$dev")" ]; then
        existing=$(target_partitions_of "$dev")
        if [ -n "$existing" ] && [ "$mode" = side-by-side ]; then
            die "$dev already has partitions and --mode is side-by-side.
Side-by-side will not add a partition to an existing table, because the table
is shared state. Use --mode takeover, or target an unused partition explicitly."
        fi
        # Takeover wipes the table (mklabel gpt), so the new partition number
        # is fixed -- including on a re-run over a disk that already has an LFS
        # filesystem on it. Predicting "one past the highest existing number" is
        # right for side-by-side, where the table is shared and preserved, and
        # wrong here: on a re-run it predicted vdd2 while parted created vdd1,
        # and the mkfs that followed failed on a device node that was never going
        # to appear.
        #
        # For a whole-disk takeover the filesystem is always partition 2,
        # whichever firmware: partition 1 is the small bootloader partition,
        # a BIOS boot partition under BIOS and an EFI System partition under
        # UEFI. One rule about where the ext4 lives, so the resume and mount
        # code has no firmware special case to get wrong.
        if [ "$mode" = takeover ]; then
            partnum=2
        else
            partnum=$(target_next_partition_number "$existing")
        fi
        TARGET_PART=$(target_partition_path "$dev" "$partnum")
        if [ "$mode" = takeover ]; then
            if [ "${LFS_FIRMWARE:-bios}" = bios ]; then
                say "plan: new GPT table on $dev"
                say "plan:   $(target_partition_path "$dev" 1)  2MiB     BIOS boot partition (unformatted, bios_grub)"
            else
                say "plan: new GPT table on $dev"
                say "plan:   $(target_partition_path "$dev" 1)  ${LFS_ESP_SIZE_MB}MiB    EFI System partition (FAT32)"
            fi
            say "plan:   $TARGET_PART  rest     ext4, label LFS"
        else
            say "plan: partition $TARGET_PART, ext4, label LFS"
        fi
    else
        TARGET_PART="$dev"
        say "plan: format $TARGET_PART as ext4, label LFS"
    fi
    TARGET_LABEL="${TARGET_PART##*/}"
    export TARGET_PART TARGET_LABEL
}

# target_actual_partition DEV [SKIP] -- the name of the partition parted just
# made, ignoring the first SKIP entries.
#
# Reads the number back out of the table rather than assuming the prediction
# held, then waits for the kernel to publish the node. Both matter: parted
# returns as soon as the table is written, and the partition device node appears
# a moment later, so an mkfs issued immediately after can name a node that does
# not exist yet.
#
# SKIP exists because a BIOS target has two partitions and only one of them is
# the filesystem. Returning the first entry would hand back the BIOS boot
# partition, and the mkfs that followed would format the place GRUB embeds into.
target_actual_partition() {
    local dev="$1" skip="${2:-0}" n i
    n=$(parted -s "$dev" print 2>/dev/null \
        | awk -v skip="$skip" '/^ [0-9]+ +[0-9]/ { if (skip > 0) { skip--; next } print $1; exit }')
    [ -n "$n" ] || return 1
    # udevadm settle where available; the short sleep is the fallback for a
    # container or a minimal image with no udev daemon.
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle --timeout=10 >/dev/null 2>&1
    fi
    local node
    for i in 1 2 3 4 5 6 7 8 9 10; do
        node=$(target_partition_path "$dev" "$n")
        [ -b "$node" ] && { printf '%s\n' "$node"; return 0; }
        sleep 0.5
    done
    return 1
}

# target_esp_for DEV -- the EFI System partition on DEV, or fail.
#
# Needed by --resume, and by the bootloader step, both of which have to find the
# ESP on a disk nobody described rather than assume it is partition 1. On a fresh
# run target_prepare just made it and can say so; on a resumed run the operator
# is looking at a table written by an earlier run, possibly an earlier layout.
#
# Two questions, asked in order of reliability:
#   1. does a partition carry the ESP partition-type GUID? That is the
#      definition, and it survives a filesystem that has not been formatted yet.
#   2. does a partition look like FAT? Weaker -- a vfat partition is not
#      necessarily the ESP -- but it is what is left on a disk whose type GUID
#      was written by a parted too old to set flags, and a wrong-but-obvious
#      answer here only costs an extra grub-install --efi-directory.
# Deliberately not a "mounted vfat anywhere" search: on a UEFI host the ESP
# being used to boot the *host* is on some other disk, and installing LFS's
# bootloader into the host's ESP is exactly the mistake side-by-side exists to
# avoid.
target_esp_for() {
    local dev="$1" n node guid
    for n in 1 2 3 4 5 6 7 8; do
        node=$(target_partition_path "$dev" "$n")
        [ -b "$node" ] || continue
        # PARTTYPE, not PARTUUID. PARTUUID is the random per-partition id
        # parted generates; the type GUID lives in PARTTYPE. Asking PARTUUID
        # whether a partition is an ESP can never match anything, which looks
        # exactly like "no ESP on this disk" and is invisible until a UEFI
        # build fails after creating one.
        guid=$(lsblk -ndo PARTTYPE "$node" 2>/dev/null | tr -d '-' | tr '[:upper:]' '[:lower:]')
        [ "$guid" = c12a7328f81f11d2ba4b00a0c93ec93b ] && {
            printf '%s\n' "$node"; return 0; }
    done
    # Second pass: a formatted FAT partition whose type flag is missing. Weaker,
    # but it rescues a table written by a parted that could not set the flag, and
    # the cost of being wrong is only an extra --efi-directory.
    for n in 1 2 3 4 5 6 7 8; do
        node=$(target_partition_path "$dev" "$n")
        [ -b "$node" ] || continue
        case "$(blkid -s TYPE -o value "$node" 2>/dev/null)" in
            vfat|fat|fat32|fat16) printf '%s\n' "$node"; return 0 ;;
        esac
    done
    return 1
}

# target_prepared_partition DEV -- the partition on DEV holding a previous LFS
# build, if there is one.
#
# "A previous LFS build" means more than "is ext4": an ext4 filesystem could be
# anything. It means the filesystem actually carries this installer's own
# layout, which is what the build creates before it checkpoints anything.
target_prepared_partition() {
    local dev="$1" p found=""
    for p in "$dev" \
             "$(target_partition_path "$dev" 1)" \
             "$(target_partition_path "$dev" 2)" \
             "$(target_partition_path "$dev" 3)" \
             "$(target_partition_path "$dev" 4)"; do
        [ -b "$p" ] || continue
        [ "$(blkid -s TYPE -o value "$p" 2>/dev/null)" = ext4 ] || continue
        # Mounted read-only to look inside: the target is not mounted at this
        # point, and mounting it read-write to check would be its own hazard.
        if mount -o ro "$p" "$LFS_TARGET_MOUNT" 2>/dev/null; then
            if [ -d "$LFS_TARGET_MOUNT/.stages" ] && [ -d "$LFS_TARGET_MOUNT/usr" ]; then
                found="$p"
                umount "$LFS_TARGET_MOUNT" 2>/dev/null
                printf '%s\n' "$found"
                return 0
            fi
            umount "$LFS_TARGET_MOUNT" 2>/dev/null
        fi
    done
    return 1
}

# target_prepare DEV MODE -- do what target_plan described.
# Calls target_plan itself so it stays usable standalone; the call is pure and
# idempotent, so a caller that already planned gets the same answer.
#
# With LFS_TARGET_RESUMING=1, a target that already holds a previous LFS build is
# left alone. Without that, takeover re-partitions and re-formats on every run,
# which silently makes --resume impossible: the disk it was supposed to resume
# onto is the thing it erases. All the safety gates above still apply either way
# (mounted partitions, the host's own root), and a blank or unrelated filesystem
# is still formatted -- only a filesystem this installer built is reused.
target_prepare() {
    local dev="$1" mode="$2" part actual keep="" _skip=0 esp=""

    target_plan "$dev" "$mode"
    part="$TARGET_PART"

    if [ "$mode" = takeover ] && [ "${LFS_TARGET_RESUMING:-0}" = 1 ]; then
        if keep=$(target_prepared_partition "$dev"); then
            say "resuming: $keep already holds an LFS build, leaving it alone"
            TARGET_PART="$keep"
            TARGET_LABEL="${keep##*/}"
            # The ESP is found, never reformatted, on this path: it belongs to a
            # filesystem the build already depends on, and reformatting it would
            # throw away a bootloader that a previous run may have installed.
            # A resumed UEFI build with no ESP found is fatal later, at the
            # bootloader step, naming the disk -- which is the right place for
            # it, because by then the operator has seen the whole build succeed
            # and only the last step is missing.
            if [ "${LFS_FIRMWARE:-bios}" = uefi ]; then
                if esp=$(target_esp_for "$dev"); then
                    say "resuming: reusing existing EFI System partition $esp"
                    TARGET_ESP="$esp"
                fi
                export TARGET_ESP
            fi
            export TARGET_PART TARGET_LABEL
            return 0
        fi
    fi

    if [ "$part" != "$dev" ]; then
        # Only a whole-disk target needs a partition table. A partition target
        # is formatted where it already lives, leaving the table untouched.
        say "creating GPT partition table on $dev (takeover)"
        run parted -s "$dev" mklabel gpt || die "failed to write a partition table to $dev"

        # GRUB for BIOS embeds core.img into the gap ahead of the first
        # partition. A GPT disk does not have a gap that big, so grub-install
        # reports "this GPT partition label contains no BIOS Boot Partition;
        # embedding won't be possible" and then refuses the blocklist fallback
        # outright. The book answers this with a small, UNFORMATTED partition of
        # BIOS-boot type, and so does this.
        #
        # The type matters and is not the obvious one. `set N esp on` -- what most
        # guides show -- tags it as an EFI System partition, which is a different
        # GUID, and GRUB's BIOS installer does not accept it. `bios_grub` sets the
        # 21686148-... type that grub-install is actually looking for.
        #
        # UEFI needs a partition for the opposite reason: firmware has to find
        # \\EFI\\<vendor>\\grubx64.efi on a FAT32 filesystem it recognises as an ESP,
        # and there is no such thing as "embed GRUB in the gap" here. So the
        # shape is the same -- a small partition 1, the filesystem as partition 2
        # -- with the roles filled by different tools. That symmetry is also
        # why the filesystem is partition 2 in both cases: one rule about where
        # the ext4 lives, rather than a special case.
        if [ "${LFS_FIRMWARE:-bios}" = bios ]; then
            _skip=1
            say "creating 2MiB BIOS boot partition $(target_partition_path "$dev" 1) (unformatted, bios_grub type)"
            run parted -s "$dev" mkpart primary 1MiB 3MiB \
                || die "failed to create the BIOS boot partition on $dev"
            run parted -s "$dev" set 1 bios_grub on \
                || die "failed to mark $(target_partition_path "$dev" 1) as a BIOS boot partition"
            run parted -s "$dev" mkpart primary ext4 3MiB 100% \
                || die "failed to create a partition on $dev"
        else
            _skip=1
            say "creating ${LFS_ESP_SIZE_MB}MiB EFI System partition $(target_partition_path "$dev" 1) (FAT32)"
            run parted -s "$dev" mkpart primary fat32 1MiB "$((LFS_ESP_SIZE_MB + 1))MiB" \
                || die "failed to create the EFI System partition on $dev"
            # `esp on` is what makes firmware and grub-install agree this is the
            # ESP; without the flag it is just a FAT32 partition that nothing
            # looks for. parted 3.6+ also accepts the raw type GUID, which is
            # spelled out here so a parted that has dropped the flag still gets
            # the right partition type rather than an untyped one.
            run parted -s "$dev" set 1 esp on \
                || run parted -s "$dev" type 1 C12A7328-F81F-11D2-BA4B-00A0C93EC93B \
                || die "failed to mark $(target_partition_path "$dev" 1) as an EFI System partition"
            run parted -s "$dev" mkpart primary ext4 "$((LFS_ESP_SIZE_MB + 1))MiB" 100% \
                || die "failed to create a partition on $dev"
        fi
        # Ask parted what it actually made. mklabel wiped the old table, so this
        # is normally 1, but re-reading is what makes a re-run over an
        # already-partitioned disk safe instead of a coin toss. Skipped under
        # --plan, where parted was only printed and there is no node to find --
        # the prediction is already right, and dying here would break the plan.
        if [ "${LFS_DRY_RUN:-0}" = 1 ]; then
            :
        elif actual=$(target_actual_partition "$dev" "$_skip"); then
            part="$actual"
            TARGET_PART="$actual"
            TARGET_LABEL="${actual##*/}"
            export TARGET_PART TARGET_LABEL
        else
            die "parted made a partition on $dev but no device node appeared for it"
        fi
    fi

    say "formatting $part as ext4, label LFS"
    # mkfs.ext4 -F: the target is verified unmounted by the gate above, so
    # forcing past the "this looks like a mounted filesystem" guard is safe
    # here, and is what makes re-running the bootstrap work on an
    # already-formatted target.
    #
    # The || die matters as much as the command: without it a failed mkfs is
    # followed by a mount attempt and then a cheerful "done", which is how a
    # broken run reports success.
    run mkfs.ext4 -F -L LFS "$part" || die "failed to create ext4 on $part"

    # EFI System partition, for a whole-disk UEFI takeover only. A partition
    # target is formatted where it already lives and its table is not ours to
    # change, so there is nowhere to put an ESP here -- that case needs the
    # operator to say which partition is the ESP.
    if [ "${LFS_FIRMWARE:-bios}" = uefi ] && [ "$part" != "$dev" ]; then
        local esp
        if esp=$(target_esp_for "$dev"); then
            # -F32 forced: an ESP left unformatted by a previous run is not
            # something mkfs should refuse to touch, and -n 11 is the FAT
            # volume-label limit. EFI rather than LFS as the label so it is
            # obvious in a partition listing which of the two is which.
            say "formatting $esp as FAT32, label EFI"
            run mkfs.fat -F 32 -n EFI "$esp" || die "failed to create FAT32 on $esp"
            TARGET_ESP="$esp"
            export TARGET_ESP
        elif [ "${LFS_DRY_RUN:-0}" != 1 ]; then
            die "firmware is UEFI but no EFI System partition was found on $dev.
GRUB's EFI bootloader has to be written to one, and a plain FAT32 partition
without the ESP type is not something firmware will look at. Re-run with
--plan to see the layout, or pass --target as a partition that already has an
ESP if this disk has one."
        fi
    fi
    return 0
}

# target_mount -- mount the prepared target at LFS_TARGET_MOUNT.
target_mount() {
    local part="$1"
    say "mounting $part at $LFS_TARGET_MOUNT"
    run mkdir -p "$LFS_TARGET_MOUNT" || die "could not create $LFS_TARGET_MOUNT"
    # Not -o noatime: LFS is built once and then run for years, and the default
    # relatime behaviour is fine. noatime would only add a non-obvious knob.
    run mount -t ext4 "$part" "$LFS_TARGET_MOUNT" \
        || die "failed to mount $part at $LFS_TARGET_MOUNT"
}

target_unmount() {
    local m="$LFS_TARGET_MOUNT" i
    if mountpoint -q "$m" 2>/dev/null; then
        say "unmounting $m"
        # Retry, briefly. This is called on the failure path, immediately after a
        # build stage gave up, and the stage's last child (runuser, and the bash
        # it exec'd) may still be tearing down with an fd open under the mount
        # point. Without the retry that races the dying child and reports
        # "target is busy", which strands the mount -- and the instruction to
        # re-run with --resume then fails at the mount step instead of resuming.
        # 5 x 1s is generous for a process that is already exiting.
        for i in 1 2 3 4 5; do
            if run umount -R "$m"; then
                return 0
            fi
            [ "$i" -lt 5 ] && sleep 1
        done
        say "could not unmount $m; it is still mounted"
        return 1
    fi
    return 0
}
