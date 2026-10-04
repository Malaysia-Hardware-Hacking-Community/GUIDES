#!/usr/bin/env bash
# Host detection: which distro, which firmware, which secure-boot state.
#
# Sourced, not executed. Every function only reads; none of them mutate the
# system. That is a deliberate constraint: detection runs first, including under
# --plan, so it has to be safe to call before anything else has happened.
#
# Populated variables (after lfs_detect_all):
#   LFS_DISTRO        best-effort family label, for logs only (not a gate)
#   LFS_PKGMGR        the package manager that decides whether a run is possible
#   LFS_DISTRO_RAW    the literal ID= from os-release (may be a derivative)
#   LFS_DISTRO_LIKE   the literal ID_LIKE= from os-release
#   LFS_DISTRO_VER    VERSION_ID
#   LFS_DISTRO_NAME   PRETTY_NAME
#   LFS_FIRMWARE      uefi | bios
#   LFS_SECUREBOOT    enabled | disabled | unknown
#   LFS_TGT           GNU target triplet, e.g. x86_64-lfs-linux-gnu
#   LFS_ARCH          uname -m

[ -n "${_LFS_DETECT_SH:-}" ] && return 0
_LFS_DETECT_SH=1

# Where the os-release facts come from. Overridable purely so the test suite can
# point it at fixtures instead of the running system.
: "${LFS_OSRELEASE:=/etc/os-release}"

# Where the firmware facts come from. Overridable for the same reason
# LFS_OSRELEASE is: the test suite has no real /sys, and hard-coding these would
# make the firmware and secure-boot paths the only untested code in the unit.
: "${LFS_EFI_DIR:=/sys/firmware/efi}"
: "${LFS_EFIVARS_DIR:=/sys/firmware/efi/efivars}"

# The package managers we ship a pkgmgr/<name>.conf for. This list -- not a list
# of distributions -- is what gates a run.
#
# Keying on the package manager rather than on ID= is what makes an unknown
# distribution work. Mint, Pop!_OS, Kali, Rocky, AlmaLinux, Manjaro,
# EndeavourOS, openSUSE and hundreds of others are not in any list we could
# write down, and every one of them is covered by the table for the package
# manager it already ships. All that is needed is a binary we can look for.
LFS_SUPPORTED_PKGMGR="apt-get dnf pacman zypper apk xbps-install emerge"

# Order matters: several systems ship more than one of these (Fedora has
# dnf5 and dnf; Debian has apt and apt-get; Arch has pacman and possibly
# yay/pamacman wrappers). The first match wins, and the list is ordered by how
# specific the choice is, not alphabetically.
LFS_PKGMGR_PROBES="apt-get dnf pacman zypper apk xbps-install emerge"

# Distros that are explicitly refused even though ID_LIKE would resolve them to
# something we support.
#
# Omarchy is ID=omarchy with ID_LIKE=arch, so without this it would silently
# resolve to the `arch` table and run. That is the wrong outcome twice over: it
# is a desktop distribution whose disk layout and bootloader are managed by its
# own installer, not a build host, and this project is not meant to touch the
# machine that runs the VMs. Refused by name rather than by heuristic.
LFS_REFUSED_DISTROS="omarchy"

# Read one key out of an os-release file without sourcing it. Sourcing would let
# a hostile or merely unusual os-release execute code here, and the values we
# want (ID, ID_LIKE, VERSION_ID) never need shell evaluation. Values may be
# quoted, so strip surrounding single/double quotes.
_osrelease_field() {
    local key="$1" file="${2:-$LFS_OSRELEASE}" line value
    [ -r "$file" ] || return 1
    line=$(grep -m1 -E "^${key}=" "$file" 2>/dev/null) || return 1
    value=${line#*=}
    # strip one layer of matching quotes
    value=${value%\"}; value=${value#\"}
    value=${value%\'}; value=${value#\'}
    printf '%s' "$value"
}

# lfs_detect_pkgmgr -- set LFS_PKGMGR to a supported package manager, or die.
#
# The single most important function for "works on any distribution": it asks
# what package manager is installed rather than what the distribution calls
# itself. Nothing here reads os-release, so it works on a system whose
# ID=/ID_LIKE we have never seen, as long as it can install packages.
#
# Overridable via LFS_PKGMGR_OVERRIDE for the test suite and for the rare host
# that has a package manager installed somewhere odd.
lfs_detect_pkgmgr() {
    if [ -n "${LFS_PKGMGR_OVERRIDE:-}" ]; then
        LFS_PKGMGR="$LFS_PKGMGR_OVERRIDE"
    else
        LFS_PKGMGR=""
        local mgr
        for mgr in $LFS_PKGMGR_PROBES; do
            if command -v "$mgr" >/dev/null 2>&1; then LFS_PKGMGR="$mgr"; break; fi
        done
    fi

    if [ -z "$LFS_PKGMGR" ]; then
        die "no supported package manager found.
  Looked for: $LFS_PKGMGR_PROBES
  This script installs its build dependencies with the host's package manager,
  so it needs one of those to be present. On a minimal or rescue system,
  install a toolchain first (gcc, make, and the utilities in
  lfs/pkgmgr/ that match your system), or re-run from a full install."
    fi

    # shellcheck disable=SC2086  # in_list takes a word list; unquoted is the contract
    if ! in_list "$LFS_PKGMGR" $LFS_SUPPORTED_PKGMGR; then
        die "package manager '$LFS_PKGMGR' is not supported.
  Supported: $LFS_SUPPORTED_PKGMGR
  To add one, write lfs/pkgmgr/$LFS_PKGMGR.conf naming its install command and
  the packages that provide the build tools, then add it to
  LFS_SUPPORTED_PKGMGR in lfs/lib/detect.sh."
    fi
    return 0
}

# lfs_detect_distro -- set LFS_DISTRO and friends.
#
# This is INFORMATION, not a gate. It records what the system calls itself so the
# log reads sensibly and so the refusal list below can work; an ID we do not
# recognise is no longer an error, because the package manager is what actually
# decides whether the run can proceed.
#
# Two-step, in this order:
#   1. exact match on ID. This is what makes Ubuntu resolve to `ubuntu` rather
#      than to `debian`, so the two can be named separately in logs.
#   2. otherwise scan ID_LIKE (a space-separated list) for the first known id.
#      This is what makes derivatives read correctly: Rocky/Alma report
#      ID_LIKE="rhel fedora" and so are labelled `fedora`.
lfs_detect_distro() {
    LFS_DISTRO_RAW=$(_osrelease_field ID) \
        || die "cannot read ID from $LFS_OSRELEASE (does it exist?)"
    LFS_DISTRO_LIKE=$(_osrelease_field ID_LIKE) || LFS_DISTRO_LIKE=""
    LFS_DISTRO_VER=$(_osrelease_field VERSION_ID) || LFS_DISTRO_VER=""
    LFS_DISTRO_NAME=$(_osrelease_field PRETTY_NAME) || LFS_DISTRO_NAME=""
    [ -n "$LFS_DISTRO_NAME" ] || LFS_DISTRO_NAME="$LFS_DISTRO_RAW"

    if in_list "$LFS_DISTRO_RAW" $LFS_REFUSED_DISTROS; then
        die "refusing to run on '$LFS_DISTRO_RAW'.
It reports ID_LIKE='${LFS_DISTRO_LIKE:-<none>}', which would otherwise look like
a supported build host, but it is a desktop distribution whose bootloader and
disk layout are managed by its own installer.
Run this inside a virtual machine or a spare-machine install, not here."
    fi

    # Best-effort label for the log. Never fails: an unknown ID is normal now.
    LFS_DISTRO="$LFS_DISTRO_RAW"
    local known="debian ubuntu fedora rhel centos arch suse opensuse void alpine gentoo"
    # shellcheck disable=SC2086  # word-list argument, as above
    if ! in_list "$LFS_DISTRO" $known; then
        local parent
        for parent in $LFS_DISTRO_LIKE; do
            # shellcheck disable=SC2086  # word-list argument, as above
            if in_list "$parent" $known; then LFS_DISTRO="$parent"; break; fi
        done
    fi
    return 0
}

# lfs_detect_firmware -- uefi if the kernel booted via EFI, else bios.
#
# The presence of /sys/firmware/efi is the kernel's own answer to this and does
# not depend on any tool being installed, which matters because detection has to
# work before the dependency step has installed anything.
lfs_detect_firmware() {
    if [ -d "$LFS_EFI_DIR" ]; then
        LFS_FIRMWARE=uefi
    else
        LFS_FIRMWARE=bios
    fi
}

# lfs_detect_secureboot -- read the SecureBoot EFI variable directly.
#
# No tool required: the variable lives in efivarfs as a file whose name is the
# variable name plus the GUID. Its first four bytes are a little-endian uint32
# describing the attributes; the byte after that is the value, 1 = enabled.
# Reading it with od avoids depending on `efi-readvar` or `mokutil`, neither of
# which is guaranteed to be installed at this point.
#
# Reports `unknown` rather than guessing when efivarfs is unreadable, which is
# the common case for an unprivileged caller.
lfs_detect_secureboot() {
    local var="$LFS_EFIVARS_DIR/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
    local byte
    if [ ! -r "$var" ]; then
        LFS_SECUREBOOT=unknown
        return 0
    fi
    # skip the 4-byte attributes field, read 1 byte of the value
    byte=$(dd if="$var" bs=1 skip=4 count=1 2>/dev/null | od -An -tu1 2>/dev/null | tr -d ' \n')
    case "$byte" in
        1) LFS_SECUREBOOT=enabled ;;
        0) LFS_SECUREBOOT=disabled ;;
        "") LFS_SECUREBOOT=unknown ;;
        *)  LFS_SECUREBOOT=unknown ;;
    esac
}

# lfs_detect_arch -- machine arch and the matching GNU triplet.
#
# The triplet must match the one build-lfs.sh uses, because stage 04 gates on
# $LFS/tools/bin/$LFS_TGT-gcc existing. If the two ever disagreed the build
# would fail late and confusingly, so the value is derived the same way.
lfs_detect_arch() {
    LFS_ARCH=$(uname -m)
    LFS_TGT="${LFS_ARCH}-lfs-linux-gnu"
    case "$LFS_ARCH" in
        x86_64|aarch64) ;;
        *) warn "arch '$LFS_ARCH' is not an LFS 13.1 target; the book documents x86_64.
       The build will probably fail. Continuing anyway." ;;
    esac
}

# lfs_detect_all -- run everything, in dependency order, and summarise.
lfs_detect_all() {
    lfs_detect_distro
    lfs_detect_pkgmgr
    lfs_detect_firmware
    lfs_detect_secureboot
    lfs_detect_arch
}

# lfs_detect_report -- human-readable one-liner block for logs and --plan.
lfs_detect_report() {
    printf '  distro      : %s (id %s)\n' \
        "${LFS_DISTRO_NAME:-?}" "${LFS_DISTRO_RAW:-?}" >&2
    printf '  id / like   : %s / %s\n' \
        "${LFS_DISTRO_RAW:-?}" "${LFS_DISTRO_LIKE:-(none)}" >&2
    printf '  version     : %s\n' "${LFS_DISTRO_VER:-?}" >&2
    printf '  pkg manager : %s  <- what decides whether this host can run\n' \
        "${LFS_PKGMGR:-?}" >&2
    printf '  arch        : %s (target %s)\n' \
        "${LFS_ARCH:-?}" "${LFS_TGT:-?}" >&2
    printf '  firmware    : %s\n' "${LFS_FIRMWARE:-?}" >&2
    printf '  secure boot : %s\n' "${LFS_SECUREBOOT:-?}" >&2
}
