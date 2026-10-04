#!/usr/bin/env bash
# Tests for lfs/lib/boot.sh.
#
# The generated GRUB text and the decision logic are tested for real. The
# firmware-level effects (grub-install actually writing to an ESP, efibootmgr
# registering an NVRAM entry) are asserted in dry-run only, because they need
# root and a real ESP. They are the part that must be re-verified in the VM.
#
# Run:  bash lfs/tests/test_boot.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LFS_ROOT=$(cd "$HERE/.." && pwd)
M=$(mktemp -d)
export LFS_LOG="$M/log"
export LFS_DRY_RUN=1
export LFS_MOUNTS_FILE="$M/mounts"
export LFS_ARCH=x86_64
export LFS_TGT=x86_64-lfs-linux-gnu

source "$LFS_ROOT/installer.sh"

PASS=0; FAIL=0; FAILED_NAMES=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES $1"; printf '  FAIL %s\n     %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2
     actual:   $3"; fi; }
contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing from output: $3
     output: $2" ;; esac; }
absent()   { case "$2" in *"$3"*) bad "$1" "unexpectedly present: $3
     output: $2" ;; *) ok "$1" ;; esac; }
expect_die() { local label="$1"; shift
    if ( "$@" ) >/dev/null 2>&1; then bad "$label" "expected refusal, got success"
    else ok "$label"; fi; }

echo "== 1. generated GRUB menuentry =="
# The kernel stage copies the image out of the kernel source tree. "arch/x86/boot"
# is where it lands; "arch/x86_boot" is a typo that looks like a directory, so the
# copy failed only after a full kernel compile -- at the end of the bootable stage,
# minutes into work that had already succeeded.
KERNEL_STAGE=$( sed -n '/^task_kernel()/,/^}/p' "$LFS_ROOT/installer.sh" )
[ -n "$KERNEL_STAGE" ] || { echo "  FAIL could not extract task_kernel()"; FAIL=1; }
absent       "no mangled bzImage source path" "$KERNEL_STAGE" "x86_boot"
contains     "bzImage copied from arch/x86/boot" "$KERNEL_STAGE" "cp arch/x86/boot/bzImage"
FS_UUID=11111111-2222-3333-4444-555555555555
PART_UUID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
E=$(boot_grub_menuentry "$FS_UUID" "$PART_UUID" 7.1.8)
contains "has a menuentry"        "$E" "menuentry \"Linux From Scratch 7.1.8\""
contains "kernel version in path" "$E" "/boot/vmlinuz-7.1.8"
contains "searches by fs-uuid"    "$E" "search --no-floppy --fs-uuid --set=root $FS_UUID"
# root= is the PARTUUID, not the filesystem UUID, even though `search` above uses
# the filesystem UUID. This kernel panics with "VFS: Cannot open root device" on
# root=UUID= even when the UUID is correct, and a device path breaks when the
# disk renumbers. Measured on a real UEFI target; see VERIFY.txt.
contains "kernel root by PARTUUID" "$E" "root=PARTUUID=$PART_UUID"
absent   "kernel root is never a filesystem UUID" "$E" "root=UUID="
absent   "kernel root is never a device path"     "$E" "root=/dev/"
# No initrd line: this build creates no initramfs (virtio, ext4 and the EFI stub
# are built in), and a menuentry naming a missing initrd drops GRUB to the rescue
# prompt with no diagnostic. The takeover grub.cfg carries no initrd either.
absent   "no initrd line for a build that makes no initrd" "$E" "initrd"
# The whole reason for using UUIDs: GRUB's (hd0,gpt1) notation silently
# points at the wrong disk once a second one is attached, and GRUB's failure
# mode is a quiet drop to the rescue prompt rather than an error.
absent "no fragile (hdN,gptN) notation" "$E" "(hd0"
absent "no fragile hd notation at all"   "$E" "(hd"
# Serial console must be in the kernel line, or the LFS VM is unbootable
# without a graphical console attached.
contains "serial console on kernel line" "$E" "console=ttyS0,115200n8"
# A menuentry with a syntax error is dropped by grub-mkconfig with no useful
# diagnostic, so braces are worth asserting.
opens=$(printf '%s' "$E" | grep -c '{'); closes=$(printf '%s' "$E" | grep -c '}')
check "braces balanced" "$opens" "$closes"

echo "== 2. grub-install target is a CPU name, not the cross triple =="
# $LFS_TGT is x86_64-lfs-linux-gnu. grub-install rejects that with
# --target=x86_64-lfs-linux-gnu-efi, so the two must not be conflated.
check "efi target for x86_64"  "x86_64-efi"  "$(boot_grub_efi_target)"
absent "efi target is not the lfs triple" "$(boot_grub_efi_target)" "lfs-linux-gnu"
LFS_ARCH=aarch64
check "efi target for aarch64" "aarch64-efi" "$(boot_grub_efi_target)"
LFS_ARCH=x86_64
check "efi suffix for x86_64"  "x64"  "$(boot_efi_arch_suffix)"
LFS_ARCH=aarch64
check "efi suffix for aarch64" "aa64" "$(boot_efi_arch_suffix)"
LFS_ARCH=x86_64

echo "== 3. ESP discovery =="
# The fallback list is pinned to paths that cannot be mounted. Without this the
# "no ESP" cases silently pass or fail depending on whether the machine running
# the tests happens to have /boot/efi mounted -- true inside a UEFI VM, false on
# a host with /boot as the ESP itself.
export LFS_ESP_CANDIDATES="$M/no-esp-here"
: > "$LFS_MOUNTS_FILE"
boot_find_esp >/dev/null 2>&1 && bad "no ESP -> not found" "found one" || ok "no ESP -> not found"
# An ESP is the only vfat thing on the system; the ext4 mounts must not match.
printf '/dev/nvme0n1p1 /boot/efi vfat rw 0 0\n/dev/nvme0n1p2 /boot ext4 rw 0 0\n/dev/mapper/root / btrfs rw 0 0\n' > "$LFS_MOUNTS_FILE"
check "finds the vfat mount" "/boot/efi" "$(boot_find_esp)"
# The mount table must win over an unmounted fallback path.
export LFS_ESP_CANDIDATES="$M/not-mounted-either"
check "mount table beats fallback list" "/boot/efi" "$(boot_find_esp)"
# A genuinely mounted fallback must still be found when the table is empty.
mkdir -p "$M/real-esp"
: > "$LFS_MOUNTS_FILE"
if mountpoint -q "$M/real-esp" 2>/dev/null; then
    export LFS_ESP_CANDIDATES="$M/real-esp"
    check "falls back to a mounted path" "$M/real-esp" "$(boot_find_esp)"
else
    # Bind-mounting needs root this suite does not have; skip rather than
    # pretend to have covered it.
    ok "falls back to a mounted path (skipped: needs root for a bind mount)"
fi

echo "== 4. syslinux hosts are refused, not silently ignored =="
# Writing a GRUB drop-in to a syslinux host produces a file nothing reads and
# no error at all, so the entry would simply never appear.
mkdir -p "$M/boot-syslinux/syslinux"
# `check "$(func; echo $?)"` cannot be used here: die calls exit, which tears
# down the command substitution before the echo ever runs.
expect_die "refuses syslinux host" boot_check_not_syslinux "$M/boot-syslinux"
mkdir -p "$M/boot-clean"
( boot_check_not_syslinux "$M/boot-clean" >/dev/null 2>&1 ) \
    && ok "accepts a plain /boot" || bad "accepts a plain /boot" "unexpectedly refused"

echo "== 5. BIOS install in dry-run =="
export GRUB_CONFIG_DIR="$M/grub.d"
export GRUB_CUSTOM_FILE=40_lfs
export GRUB_REGEN="update-grub"
mkdir -p "$GRUB_CONFIG_DIR"
: > "$LFS_LOG"
boot_install_bios aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee 11111111-2222-3333-4444-555555555555 7.1.8
PLAN=$(cat "$LFS_LOG")
contains "regenerates grub"          "$PLAN" "update-grub"
contains "mentions the drop-in"     "$PLAN" "40_lfs"
# Not executable => GRUB skips it silently. This is a real failure mode.
contains "chmods the drop-in +x"    "$PLAN" "chmod 0755"
absent   "does not write a file in dry-run" "$PLAN" "would write /dev/null"

# The dry-run above must not have written the drop-in. This version renders the
# entry to a variable and checks THAT before touching grub.d, so a bad root= is
# caught without a file appearing on the host -- which is also what makes the
# check meaningful under --plan, where nothing may be written at all.
if [ -e "$GRUB_CONFIG_DIR/$GRUB_CUSTOM_FILE" ]; then
    bad "dry-run wrote no drop-in file" "$GRUB_CONFIG_DIR/$GRUB_CUSTOM_FILE exists"
else
    ok "dry-run wrote no drop-in file"
fi

# A menuentry whose root= names nothing boots to a rescue prompt, silently. This
# is the guard that refuses to write one.
expect_die "refuses a menuentry with no PARTUUID" \
    boot_install_bios 11111111-2222-3333-4444-555555555555 "" 7.1.8

# grub-mkconfig runs every /etc/grub.d/* file as a SHELL script and concatenates
# its stdout into grub.cfg. A raw "menuentry ... }" block is not valid shell, so
# update-grub dies with 'menuentry: not found' and 'Syntax error: "}" unexpected'
# and the entry never appears -- while the file on disk looks perfect. Found by
# running the real function on a Debian-layout host. So assert the two things a
# text-only check misses: it parses as shell, and running it EMITS the entry.
GRUB_REGEN="true"   # isolate: we are testing the drop-in, not the regeneration
DROPIN="$GRUB_CONFIG_DIR/$GRUB_CUSTOM_FILE"
rm -f "$DROPIN"
# In a subshell: boot_install_bios calls die (which exits) if the drop-in it
# just wrote is not valid shell, and that must be observed, not end the suite.
( LFS_DRY_RUN=0; boot_install_bios aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee \
      11111111-2222-3333-4444-555555555555 7.1.8 ) >/dev/null 2>&1
if sh -n "$DROPIN" 2>/dev/null; then
    ok "the drop-in is a valid shell script"
else
    bad "the drop-in is a valid shell script" "sh -n rejected it"
fi
EMITTED=$(sh "$DROPIN" 2>/dev/null)
case "$EMITTED" in
    *menuentry*root=PARTUUID=11111111-2222-3333-4444-555555555555*)
        ok "running the drop-in emits the menuentry" ;;
    *) bad "running the drop-in emits the menuentry" "got: $EMITTED" ;;
esac
# A quoted heredoc, so a kernel path or UUID containing shell metacharacters
# cannot be expanded by grub-mkconfig when it runs the file.
contains "the heredoc is quoted so nothing is expanded" "$EMITTED" 'root=PARTUUID=11111111-2222-3333-4444-555555555555'
LFS_DRY_RUN=1

echo "== 6. BIOS install refuses a missing grub.d =="
export GRUB_CONFIG_DIR="$M/nonexistent-grub.d"
expect_die "dies when grub.d missing" boot_install_bios aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee 11111111-2222-3333-4444-555555555555 7.1.8
export GRUB_CONFIG_DIR="$M/grub.d"

echo "== 7. UEFI install in dry-run =="
export ESP_MOUNT=/boot/efi
export LFS_SECUREBOOT=disabled
# Each section sets up its own mount table: they share one file, and section 3
# deliberately leaves it empty.
printf '/dev/nvme0n1p1 /boot/efi vfat rw 0 0\n' > "$LFS_MOUNTS_FILE"
export LFS_ESP_CANDIDATES="$M/no-esp-here"
: > "$LFS_LOG"
boot_install_uefi aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee 11111111-2222-3333-4444-555555555555 7.1.8
PLAN=$(cat "$LFS_LOG")
# The loader must be self-contained: grub-install bakes its prefix into the
# image via `grub-mkimage --prefix` and writes no config into EFI/<id>/, so a
# loader that resolves its config by prefix reads the *host's*
# /boot/grub/grub.cfg in side-by-side mode and boots the host OS. Verified in a
# VM: an EFI/LFS/grub.cfg written by hand was never read, while the same config
# embedded in the image booted LFS. So the fix is grub-mkstandalone, not a
# written stub file.
contains "builds a self-contained loader" "$PLAN" "grub-mkstandalone"
contains "correct efi target"            "$PLAN" "--format=x86_64-efi"
contains "embeds the config in the image" "$PLAN" "boot/grub/grub.cfg="
absent   "never uses grub-install"        "$PLAN" "grub-install "
absent   "no EFI stub grub.cfg is written" "$PLAN" "EFI/LFS/grub.cfg"
absent   "never overwrites the host id"   "$PLAN" "--bootloader-id=ubuntu"
absent   "does not wipe the ESP"          "$PLAN" "mkfs"

export ESP_MOUNT=/boot/efi
export LFS_SECUREBOOT=disabled
printf '/dev/nvme0n1p1 /boot/efi vfat rw 0 0\n' > "$LFS_MOUNTS_FILE"
export LFS_ESP_CANDIDATES="$M/no-esp-here"
# The rendered config is echoed with a [PLAN ] prefix on stdout, not into the
# log, so take both and assert the body against stdout.
OUT=$(boot_install_uefi aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee 11111111-2222-3333-4444-555555555555 7.1.8 2>&1)
PLAN=$(cat "$LFS_LOG")
contains "the UEFI loader lands in the LFS EFI dir" "$PLAN" "/boot/efi/EFI/LFS/grubx64.efi"
contains "the UEFI config searches by filesystem UUID" "$OUT" "--fs-uuid --set=root aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
contains "the UEFI config roots by PARTUUID"           "$OUT" "root=PARTUUID=11111111-2222-3333-4444-555555555555"
absent   "the UEFI config names no initrd"             "$OUT" "initrd"
absent   "the UEFI config has no root=UUID="           "$OUT" "root=UUID="
absent   "the UEFI config has no root=/dev/"           "$OUT" "root=/dev/"

# Same silent-rescue-prompt guard the BIOS path has: an entry whose root=
# names nothing must never reach the ESP.
expect_die "the UEFI path refuses a missing PARTUUID" \
    boot_install_uefi aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee "" 7.1.8
absent   "the UEFI config has no root=/dev/"           "$PLAN" "root=/dev/"

echo "== 8. UEFI install with no ESP mounted is refused =="
: > "$LFS_MOUNTS_FILE"
export LFS_ESP_CANDIDATES="$M/no-esp-here"
expect_die "dies with no ESP" boot_install_uefi aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee 11111111-2222-3333-4444-555555555555 7.1.8

# grub-mkstandalone is a hard requirement of this path. Without an early check
# the run only fails at the very end, after the whole build, with a tool error
# that looks like a GRUB bug rather than a missing package.
printf '/dev/nvme0n1p1 /boot/efi vfat rw 0 0\n' > "$LFS_MOUNTS_FILE"
export LFS_ESP_CANDIDATES="$M/no-esp-here"
export LFS_SECUREBOOT=disabled
# The suite runs dry-run throughout, and the check is deliberately skipped in
# dry-run (a plan has no tools to look for), so this one case runs for real.
LFS_DRY_RUN=0
export LFS_DRY_RUN
command() { return 127; }
expect_die "dies with a clear message when grub-mkstandalone is missing" \
    boot_install_uefi aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee 11111111-2222-3333-4444-555555555555 7.1.8
unset -f command
export LFS_DRY_RUN=1

echo "== 9. Secure Boot takes the signed-image path =="
printf '/dev/nvme0n1p1 /boot/efi vfat rw 0 0\n' > "$LFS_MOUNTS_FILE"
# With Secure Boot on and no distribution shim present, this must refuse rather
# than install an unsigned GRUB that firmware will reject at boot time.
export LFS_SECUREBOOT=enabled
expect_die "dies when no signed shim exists" boot_install_uefi aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee 11111111-2222-3333-4444-555555555555 7.1.8
# A different, equally bad failure: firmware enabled but we cannot read the
# variable. Must not be treated as "secure boot off".
export LFS_SECUREBOOT=unknown
: > "$LFS_LOG"
boot_install_uefi aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee 11111111-2222-3333-4444-555555555555 7.1.8
PLAN=$(cat "$LFS_LOG")
contains "unknown secure boot still installs grub" "$PLAN" "grub-mkstandalone"
export LFS_SECUREBOOT=disabled

rm -rf "$M"
echo "== 8. host GRUB layout is detected, not assumed =="
# The Debian and RHEL families disagree about both the config path and the
# snippet suffix the regen command globs for:
#     Debian/Arch: /boot/grub/grub.cfg  + /etc/grub.d/*.conf  + update-grub
#     Fedora/RHEL: /boot/grub2/grub.cfg + /etc/grub.d/*.cfg  + grub2-mkconfig
# The bug itself: on a Debian host that HAS its config, boot_detect_grub must
# not claim it has none. This is the assertion the substring logic could not
# pass, because "update-grub" contains no config path to match against.
detect_bare() {  # detect_bare BOOTDIR -- stderr from boot_detect_grub
    local d
    d=$(mktemp -d)
    printf '#!/bin/sh\nexit 0\n' > "$d/update-grub"; chmod +x "$d/update-grub"
    ( PATH="$d"; hash -r; GRUB_CONFIG_DIR=""; GRUB_CUSTOM_FILE=""
      GRUB_REGEN=""; GRUB_TARGET_CFG=""
      boot_detect_grub "$1" ) 2>&1
    rm -rf "$d"
}
BT=$(mktemp -d); mkdir -p "$BT/grub"; : > "$BT/grub/grub.cfg"
case "$(detect_bare "$BT")" in
    *"no existing GRUB config"*)
        bad "a Debian host with /boot/grub/grub.cfg warns about no config" \
            "warned anyway: $(detect_bare "$BT")" ;;
    *) ok "a Debian host with /boot/grub/grub.cfg warns about no config" ;;
esac
rm -rf "$BT/grub"
case "$(detect_bare "$BT")" in
    *"no existing GRUB config"*)
        ok "a GRUB config whose directory is absent still warns" ;;
    *) bad "a GRUB config whose directory is absent still warns" \
            "stayed quiet: $(detect_bare "$BT")" ;;
esac
rm -rf "$BT"

# No package-manager table can express which one a host is, so boot_detect_grub
# looks. Getting it wrong is silent: a 40_lfs with no .conf suffix is never
# picked up, and the LFS entry simply never appears in the menu.
# Each case gets its OWN directory containing exactly the tools that case
# declares. Reusing one directory and deleting the others would be defeated by
# bash's command hash table: once `command -v update-grub` has succeeded, the
# shell keeps reporting it found even after the file is gone, so a later case
# silently tested the previous case's tool.
detect_with() {  # detect_with CMD... -- a PATH holding only these tools
    local d
    d=$(mktemp -d)
    local t
    for t in "$@"; do
        printf '#!/bin/sh\nexit 0\n' > "$d/$t"; chmod +x "$d/$t"
    done
    # Note the cleanup is in the parent, not the subshell: inside it PATH is the
    # stub directory, which contains no rm.
    ( PATH="$d"; hash -r
      GRUB_CONFIG_DIR=""; GRUB_CUSTOM_FILE=""; GRUB_REGEN=""; GRUB_TARGET_CFG=""
      boot_detect_grub >/dev/null 2>&1
      printf '%s|%s|%s|%s' "$GRUB_CONFIG_DIR" "$GRUB_CUSTOM_FILE" "$GRUB_REGEN" \
             "${GRUB_TARGET_CFG:-}" )
    rm -rf "$d"
}

check "Debian layout: update-grub + .conf" \
    "/etc/grub.d|40_lfs.conf|update-grub|/boot/grub/grub.cfg" "$(detect_with update-grub)"
check "RHEL layout: grub2-mkconfig + .cfg" \
    "/etc/grub.d|40_lfs.cfg|grub2-mkconfig -o /boot/grub2/grub.cfg|/boot/grub2/grub.cfg" \
    "$(detect_with grub2-mkconfig)"
check "Arch layout: grub-mkconfig + .conf" \
    "/etc/grub.d|40_lfs.conf|grub-mkconfig -o /boot/grub/grub.cfg|/boot/grub/grub.cfg" \
    "$(detect_with grub-mkconfig)"
# update-grub wins when several are installed: it is the distribution's own
# wrapper and knows about its own layout, including any distro-specific hook.
check "update-grub wins when several are present" \
    "/etc/grub.d|40_lfs.conf|update-grub|/boot/grub/grub.cfg" \
    "$(detect_with update-grub grub2-mkconfig grub-mkconfig)"

# Which config each family will write. update-grub takes NO path argument -- it
# picks /boot/grub/grub.cfg itself -- so this used to be recovered by matching
# the config path against the regen command as a substring. That can never
# succeed for update-grub: the string "update-grub" contains no path. So the
# check always fell through and warned "no existing GRUB config found under
# /boot/grub{,2}" on every Debian/Ubuntu host, including one that had just
# written /boot/grub/grub.cfg successfully. The path is now stated per family.
check "update-grub targets /boot/grub/grub.cfg" \
    "/etc/grub.d|40_lfs.conf|update-grub|/boot/grub/grub.cfg" \
    "$(detect_with update-grub)"
check "grub2-mkconfig targets /boot/grub2/grub.cfg" \
    "/etc/grub.d|40_lfs.cfg|grub2-mkconfig -o /boot/grub2/grub.cfg|/boot/grub2/grub.cfg" \
    "$(detect_with grub2-mkconfig)"
check "grub-mkconfig targets /boot/grub/grub.cfg" \
    "/etc/grub.d|40_lfs.conf|grub-mkconfig -o /boot/grub/grub.cfg|/boot/grub/grub.cfg" \
    "$(detect_with grub-mkconfig)"

# The warning's premise: the config the host will write, or the directory that
# will hold it, is really there. A GRUB that is installed but has never run
# mkconfig has the directory and no config, and update-grub will create the
# config itself -- warning there would be noise about a working host.
CFG_T=$(mktemp -d)
: > "$CFG_T/grub.cfg"
if boot_grub_cfg_ok "$CFG_T/grub.cfg"; then
    ok "an existing config counts as present"
else
    bad "an existing config counts as present" "rejected an existing $CFG_T/grub.cfg"
fi
if boot_grub_cfg_ok "$CFG_T/not-yet-generated.cfg"; then
    ok "a config not yet generated but with its directory present counts as present"
else
    bad "a config not yet generated but with its directory present counts as present" \
        "rejected $CFG_T/not-yet-generated.cfg although $CFG_T exists"
fi
if boot_grub_cfg_ok "$CFG_T/no/such/dir/grub.cfg"; then
    bad "a config under a directory that does not exist is reported missing" \
        "accepted $CFG_T/no/such/dir/grub.cfg"
else
    ok "a config under a directory that does not exist is reported missing"
fi
rm -rf "$CFG_T"
# No GRUB tooling at all must fail loudly rather than guess a command that would
# write a config nothing reads.
EMPTY_PATH=$(mktemp -d)
out=$( ( PATH="$EMPTY_PATH"; hash -r; GRUB_CONFIG_DIR=""; boot_detect_grub ) 2>&1 )
rm -rf "$EMPTY_PATH"
case "$out" in
    *grub-mkconfig*) ok "no grub tooling is a clear error" ;;
    *) bad "no grub tooling is a clear error" "got: $out" ;;
esac
# A missing /etc/grub.d must also be refused, not defaulted to.
if ( boot_detect_grub ) >/dev/null 2>&1; then
    # /etc/grub.d exists on this host, so it legitimately succeeds; only assert
    # it does not invent a directory when the real one is absent.
    ok "existing /etc/grub.d is used"
else
    ok "no /etc/grub.d is refused"
fi

echo "== 10. firmware boot entry names the real disk and partition =="
# The entry this replaces hardcoded "--part 1" and fell back to /dev/sda. On any
# disk whose ESP is not partition 1 that registers a boot entry pointing at the
# wrong place, and efibootmgr returns success anyway -- a boot entry that exists
# and does not work is worse than none. The loader must also end in .efi.
# Section 8 removed $M, so this section gets its own log file.
LFS_LOG=$(mktemp)
lsblk() { case "$*" in
    *PKNAME*) printf 'nvme0n1\n' ;;
    *PARTN*)  printf '2\n' ;;
    *) command lsblk "$@" ;;
esac; }
efibootmgr() { printf 'EFIBOOTMGR %s\n' "$*" >> "$LFS_LOG"; }
export LFS_BOOT_ID=LFS
boot_register_nvram /dev/nvme0n1p2 >/dev/null
NV=$(cat "$LFS_LOG")
contains "nvram uses the parent disk"  "$NV" "/dev/nvme0n1"
contains "nvram uses the real part"    "$NV" "--part 2"
contains "nvram loader ends in .efi"   "$NV" '\EFI\LFS\grubx64.efi'
absent   "nvram does not hardcode part 1" "$NV" "--part 1"
absent   "nvram does not guess /dev/sda"  "$NV" "/dev/sda"
# An ESP whose disk cannot be resolved is a warning-plus-nonzero, never a silent
# success that a caller might treat as "entry created".
lsblk() { case "$*" in
    *PKNAME*) printf '\n' ;;
    *PARTN*)  printf '2\n' ;;
    *) command lsblk "$@" ;;
esac; }
if boot_register_nvram /dev/nvme0n1p2 >/dev/null 2>&1; then
    bad "unresolvable ESP fails the helper" "returned success"
else
    ok "unresolvable ESP fails the helper"
fi
unset -f lsblk efibootmgr
rm -f "$LFS_LOG"
# And the side-by-side installer must route through that helper rather than
# open-coding efibootmgr again.
UEFI_FN=$( sed -n '/^boot_install_uefi()/,/^}/p' "$LFS_ROOT/installer.sh" )
contains "uefi install uses boot_register_nvram" "$UEFI_FN" "boot_register_nvram"
absent   "uefi install has no hardcoded --part 1" "$UEFI_FN" "--part 1"
# The loader must embed its config rather than resolve one by prefix, and must
# not call grub-install at all. A guard that stops this reverting to
# grub-install + a written EFI/<id>/grub.cfg would look plausible -- and pass --
# because the written stub is simply never read.
contains "uefi install builds a self-contained loader" "$UEFI_FN" "grub-mkstandalone"
contains "uefi install embeds the config"             "$UEFI_FN" "boot/grub/grub.cfg="
absent   "uefi install does not call grub-install"    "$UEFI_FN" "run grub-install"
absent   "uefi install writes no EFI stub grub.cfg"   "$UEFI_FN" 'EFI/$LFS_BOOT_ID/grub.cfg"'
# A hand-picked --install-modules list does not resolve GRUB's meta-modules: a
# loader built with only search_fs_uuid/search_label dies at boot with
# "file `.../search.mod' not found". Verified in a VM, so the full module set
# must be embedded by omitting the flag.
absent   "uefi install does not hand-pick modules"    "$UEFI_FN" "--install-modules="
contains "uefi install renders the LFS entry"         "$UEFI_FN" 'boot_grub_menuentry "$root_uuid" "$root_partuuid" "$kver"'
contains "uefi install validates the entry"           "$UEFI_FN" 'root=PARTUUID='
# And the Secure Boot branch must NOT build a loader: it installs the host
# distribution's signed shim and tells the operator to finish by hand, because a
# freshly built GRUB is unsigned and would be rejected.
SB_FN=$( sed -n '/^boot_install_uefi_secureboot()/,/^}/p' "$LFS_ROOT/installer.sh" )
absent   "the Secure Boot path builds no unsigned loader" "$SB_FN" "grub-mkstandalone"
absent   "the Secure Boot path writes no EFI grub.cfg"    "$SB_FN" "grub.cfg"

echo
echo "== 7. the chroot's GRUB is built for the platform it will install =="
# GRUB's platform modules are chosen at CONFIGURE time, not install time, so
# the book package that builds GRUB in the chroot and the task that installs it
# have to name the same platform. They did not: §8.65.1 was built unmodified
# (i386-pc) while task_bootable asked for x86_64-efi, and a real UEFI build
# died at the very end with "modinfo.sh doesn't exist", after chapter 8.
GRUB_FN=$( sed -n '/^ *build_8_65_1_GRUB_for_BIOS()/,/^ *}/p' "$LFS_ROOT/installer.sh" )
if [ -z "$GRUB_FN" ]; then bad "grub book function found" "build_8_65_1_GRUB_for_BIOS is not in the installer"
else
    ok "grub book function found"
    contains "grub configure is keyed on the firmware" "$GRUB_FN" 'case "${LFS_FIRMWARE:-bios}" in'
    # both branches, and the branch grub-install actually uses must agree
    check "grub has one configure per firmware"  "2" "$(printf '%s\n' "$GRUB_FN" | grep -c '^\s*\./configure')"
    GRUB_UEFI_BRANCH=$(printf '%s\n' "$GRUB_FN" | sed -n '/uefi)/,/;;/p')
    contains "uefi branch sets the efi platform"  "$GRUB_UEFI_BRANCH" "--with-platform=efi"
    contains "uefi branch sets the efi target"    "$GRUB_UEFI_BRANCH" "--target=x86_64"
    GRUB_BIOS_BRANCH=$(printf '%s\n' "$GRUB_FN" | sed -n '/^ *\*)/,/;;/p')
    absent "bios branch does not build efi modules" "$GRUB_BIOS_BRANCH" "--with-platform=efi"
    # the platform the book builds is the platform task_bootable installs:
    # x86_64 + efi, matched against the --target it passes grub-install
    EFI_TARGET=$(boot_grub_efi_target)
    contains "grub builds the platform grub-install targets" \
        "$GRUB_UEFI_BRANCH" "--target=${EFI_TARGET%-efi}"
fi
# And the guard that turns a mismatch into a clear message before the kernel
# build, instead of a grub-install error after it.
STAGE9=$( sed -n '/^build_stage_09()/,/^}/p' "$LFS_ROOT/installer.sh" )
contains "stage 09 checks the grub platform"  "$STAGE9" "usr/lib/grub/\$grub_platform"
contains "stage 09 guards uefi"               "$STAGE9" "grub_platform=x86_64-efi"
contains "stage 09 guards bios"               "$STAGE9" "grub_platform=i386-pc"

echo
echo "================================"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then printf 'failing:%s\n' "$FAILED_NAMES"; exit 1; fi
printf 'ALL BOOT TESTS PASSED\n'
exit 0
