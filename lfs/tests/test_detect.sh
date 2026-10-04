#!/usr/bin/env bash
# Tests for lfs/lib/detect.sh. No VM, no root, no network.
#
# Detection is the one unit that must be right about *every* distro before any
# destructive step runs, and it is also the unit most likely to be wrong,
# because "which distro is this" is a much bigger space than the seven we
# support: derivatives, ID_LIKE chains, quoted values, and outright unknown
# systems all have to resolve correctly. So it is tested against real
# os-release fixtures rather than against the machine running the tests.
#
# Run:  bash lfs/tests/test_detect.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LFS_ROOT=$(cd "$HERE/.." && pwd)
FIX="$HERE/fixtures/os-release"
export LFS_LOG=/dev/null          # keep lib/common.sh quiet
export LFS_DRY_RUN=1

source "$LFS_ROOT/installer.sh"

PASS=0
FAIL=0
FAILED_NAMES=""

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
# bad takes the actual value optionally: a two-argument bad() under `set -u`
# would abort the whole suite on a missing $3 and hide every later result, so
# the harness is allowed to be sloppy in reporting.
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES $1"; printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "${2-}" "${3-}"; }

# check NAME EXPECTED ACTUAL
check() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi
}

# detect_for FIXTURE -- run detection against one fixture, tolerating die()
detect_for() {
    ( LFS_OSRELEASE="$FIX/$1" lfs_detect_distro >/dev/null 2>&1 ) && echo ok || echo fail
}

# expect_distro FIXTURE EXPECTED_CANONICAL
expect_distro() {
    local fixture="$1" want="$2" got
    got=$( LFS_OSRELEASE="$FIX/$fixture" lfs_detect_distro 2>/dev/null && printf '%s' "$LFS_DISTRO" )
    check "distro: $fixture -> $want" "$want" "$got"
}

echo "== 1. every distro ID resolves to itself =="
for d in debian ubuntu fedora arch void gentoo alpine; do
    expect_distro "$d" "$d"
done

echo "== 2. derivatives resolve via ID_LIKE =="
# rocky is ID_LIKE="rhel centos fedora" -> fedora is the one we support.
expect_distro rocky rhel
# mint is ID_LIKE="ubuntu debian" -> must pick ubuntu (listed first), not debian:
# the two carry different package tables, so order matters and is deliberate.
expect_distro linuxmint ubuntu

echo "== 3. an unknown distro is labelled, not rejected =="
# This used to be a hard failure, and it is the single change that makes "works
# on any distribution" true: the distribution ID is only ever a label in the
# log now. What decides whether a run can proceed is the package manager, tested
# separately below. Rejecting an unrecognised ID would mean rejecting every
# derivative nobody thought to add to a list.
for d in opensuse unknown-os rocky linuxmint; do
    if ( LFS_OSRELEASE="$FIX/$d" lfs_detect_distro ) >/dev/null 2>&1; then
        ok "accept $d"
    else
        bad "accept $d" "died; an unknown ID must not stop a run"
    fi
done
# The label is cosmetic -- nothing functional reads LFS_DISTRO any more -- so
# what matters is only that it is resolved deterministically and never causes a
# refusal. Resolution is: exact ID if known, else the first ID_LIKE entry that
# is known, else the raw ID passed through unchanged.
expect_distro opensuse suse          # ID_LIKE="suse opensuse", suse comes first
expect_distro linuxmint ubuntu       # ID_LIKE="ubuntu debian"
expect_distro rocky rhel             # ID_LIKE="rhel centos fedora"
# An ID nobody has heard of is passed through verbatim rather than mapped onto
# some distro it is not. (The unknown-os fixture's actual ID is "quantumlinux".)
expect_distro unknown-os quantumlinux
# A known ID is never replaced by its parent.
expect_distro ubuntu ubuntu
expect_distro fedora fedora

echo "== 3c. an unknown distro with no ID_LIKE is still accepted =="
# The worst case for "any distro": no family hint at all. It must still be
# labelled and must not die, because the package manager below is the real gate.
printf 'ID=weirdos\nVERSION_ID=1\n' > /tmp/detect-nolike
if ( LFS_OSRELEASE=/tmp/detect-nolike lfs_detect_distro ) >/dev/null 2>&1; then
    ok "accept a distro with no ID_LIKE"
else
    bad "accept a distro with no ID_LIKE" "died"
fi
v=$( LFS_OSRELEASE=/tmp/detect-nolike lfs_detect_distro >/dev/null 2>&1; printf '%s' "$LFS_DISTRO" )
check "labels it with its raw ID" "weirdos" "$v"
rm -f /tmp/detect-nolike

echo "== 3d. the package manager is the real gate =="
# The point of the whole refactor. A distribution we have never heard of is
# supported if and only if it has a package manager we know how to drive.
expect_pkgmgr() {  # expect_pkgmgr NAME
    got=$( LFS_PKGMGR_OVERRIDE="$1" lfs_detect_pkgmgr >/dev/null 2>&1; printf '%s' "$LFS_PKGMGR" )
    check "package manager $1 is accepted" "$1" "$got"
}
for m in apt-get dnf pacman zypper apk xbps-install emerge; do
    expect_pkgmgr "$m"
done
# An unknown manager must fail loudly, with a message that says how to fix it.
if ( LFS_PKGMGR_OVERRIDE=brew lfs_detect_pkgmgr ) >/dev/null 2>&1; then
    bad "reject an unknown package manager" "exited 0"
else
    ok "reject an unknown package manager"
fi
msg=$( LFS_PKGMGR_OVERRIDE=brew lfs_detect_pkgmgr 2>&1 || true )
# The tables are branches of pkgmgr_table() now, so the pointer has to name
# the function to edit. Matching the old file path here would keep passing
# after the refactor by way of a message nobody reads.
case "$msg" in
    *pkgmgr_table*) ok "message says how to add support (a pkgmgr_table branch)" ;;
    *) bad "message says how to add support" "got: $msg" ;;
esac
# ...and it must list the managers that DO work, or the message is a dead end.
case "$msg" in
    *apt-get*) ok "the refusal lists the supported managers" ;;
    *) bad "the refusal lists the supported managers" "got: $msg" ;;
esac
# And an override naming a supported manager must work even though that binary
# is not installed here -- the override exists precisely for the odd host.
expect_pkgmgr dnf

echo "== 3e. the distro refusal still happens before anything else =="
# An unknown package manager must not let a refused distro through: detection
# refuses by name regardless of what else is true about the host.

echo "== 3b. refused distros are not rescued by ID_LIKE =="
# Omarchy is ID=omarchy ID_LIKE=arch. The arch package table would install
# perfectly well, which is exactly why this has to be refused by name: the
# dangerous case is the one that looks like it works. This is the VM host in
# this project, and its bootloader must never be touched.
if ( LFS_OSRELEASE="$FIX/omarchy" lfs_detect_distro ) >/dev/null 2>&1; then
    bad "reject omarchy despite ID_LIKE=arch" "die" "exited 0, resolved to $LFS_DISTRO"
else
    ok "reject omarchy despite ID_LIKE=arch"
fi
# The message must say why, not just fail: "unsupported distro" would be
# actively misleading when the distro IS arch-based.
msg=$( LFS_OSRELEASE="$FIX/omarchy" lfs_detect_distro 2>&1 || true )
case "$msg" in
    *omarchy*) ok "refusal names the distro" ;;
    *) bad "refusal names the distro" "got: $msg" ;;
esac
case "$msg" in
    *"ID_LIKE"*) ok "refusal explains the ID_LIKE trap" ;;
    *) bad "refusal explains the ID_LIKE trap" "got: $msg" ;;
esac

echo "== 4. os-release parsing =="
v=$( LFS_OSRELEASE="$FIX/ubuntu" lfs_detect_distro >/dev/null 2>&1; printf '%s' "$LFS_DISTRO_NAME" )
check "quoted PRETTY_NAME with spaces+digits" "Ubuntu 24.04.1 LTS" "$v"
v=$( LFS_OSRELEASE="$FIX/debian" lfs_detect_distro >/dev/null 2>&1; printf '%s' "$LFS_DISTRO_VER" )
check "quoted VERSION_ID" "12" "$v"
v=$( LFS_OSRELEASE="$FIX/gentoo" lfs_detect_distro >/dev/null 2>&1; printf '%s' "$LFS_DISTRO_NAME" )
check "PRETTY_NAME preferred over bare NAME" "Gentoo Linux" "$v"
# Exercise the parser directly: unquoted value, no surrounding quotes to strip.
v=$( _osrelease_field NAME "$FIX/gentoo" )
check "unquoted NAME parsed verbatim" "Gentoo" "$v"
v=$( _osrelease_field ID "$FIX/rocky" )
check "quoted ID dequoted" "rocky" "$v"
v=$( LFS_OSRELEASE="$FIX/void" lfs_detect_distro >/dev/null 2>&1; printf '%s' "$LFS_DISTRO_LIKE" )
check "empty ID_LIKE= stays empty" "" "$v"
# blank/comment lines must not confuse the field reader
printf 'ID=fedora\n# ID=arch\n\nVERSION_ID=43\n' > /tmp/detect-test-osrelease
v=$( LFS_OSRELEASE=/tmp/detect-test-osrelease lfs_detect_distro >/dev/null 2>&1; printf '%s' "$LFS_DISTRO" )
check "commented-out ID is ignored" "fedora" "$v"
rm -f /tmp/detect-test-osrelease

echo "== 5. firmware detection =="
tmp=$(mktemp -d)
LFS_EFI_DIR="$tmp/efi" lfs_detect_firmware
check "no /sys/firmware/efi -> bios" "bios" "$LFS_FIRMWARE"
mkdir -p "$tmp/efi"
LFS_EFI_DIR="$tmp/efi" lfs_detect_firmware
check "/sys/firmware/efi present -> uefi" "uefi" "$LFS_FIRMWARE"
rm -rf "$tmp"

echo "== 6. secure boot detection =="
tmp=$(mktemp -d)
LFS_EFIVARS_DIR="$tmp/none" lfs_detect_secureboot
check "unreadable efivarfs -> unknown (not 'disabled')" "unknown" "$LFS_SECUREBOOT"
mkdir -p "$tmp/vars"
# EFI var layout: 4-byte LE attributes, then the value byte.
printf '\x00\x00\x00\x00\x01' > "$tmp/vars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
LFS_EFIVARS_DIR="$tmp/vars" lfs_detect_secureboot
check "value 1 -> enabled" "enabled" "$LFS_SECUREBOOT"
printf '\x00\x00\x00\x00\x00' > "$tmp/vars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
LFS_EFIVARS_DIR="$tmp/vars" lfs_detect_secureboot
check "value 0 -> disabled" "disabled" "$LFS_SECUREBOOT"
rm -rf "$tmp"

echo "== 7. arch / target triplet =="
lfs_detect_arch >/dev/null 2>&1
check "triplet is \$(uname -m)-lfs-linux-gnu" "$(uname -m)-lfs-linux-gnu" "$LFS_TGT"

echo "== 8. every supported package manager has a reachable table =="
# Detection promising a manager that pkgmgr_table() then rejects would fail
# much later, at deps_load, with a much more confusing error. (The reverse
# direction -- a table nothing can select -- is checked in test_pkgmgr.sh.)
for m in $LFS_SUPPORTED_PKGMGR; do
    if pkgmgr_table "$m" >/dev/null 2>&1; then
        ok "package table reachable: $m"
    else
        bad "package table reachable: $m" "pkgmgr_table refused it"
    fi
done

echo
echo "================================"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf 'failing:%s\n' "$FAILED_NAMES"
    exit 1
fi
printf 'ALL DETECT TESTS PASSED\n'
exit 0
