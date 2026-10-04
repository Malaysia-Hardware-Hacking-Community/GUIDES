#!/usr/bin/env bash
# installer.sh -- install Linux From Scratch onto a machine, from one file.
#
# WHAT THIS DOES
#   Detects the host, installs the build dependencies, chooses a target disk,
#   builds LFS 13.1-systemd onto it, installs a bootloader, and leaves you a
#   working system. With no arguments it performs a FULL INSTALL: the chosen
#   disk becomes LFS and the machine boots into it.
#
# ONE FILE
#   There is nothing else to fetch or to keep in sync. Copy this one file to
#   the machine, or run it straight from a URL. It copies itself into the
#   build's chroot to run its own later stages, so it stays self-contained even
#   though the build crosses a chroot boundary.
#
# ANY DISTRIBUTION
#   Support is keyed on the PACKAGE MANAGER, never on the distribution id, so
#   an unrecognised derivative works as long as it ships one of:
#       apt-get  dnf  pacman  zypper  apk  xbps-install  emerge
#   An unknown package manager is the only thing refused, because a package
#   list cannot be invented for it. See the package table section below.
#
# NO TARGET ARGUMENT NEEDED
#   With exactly one unused disk attached, that disk is used and the choice is
#   announced. With none, or with several, it prints what it found and stops.
#   "The first of several" is a coin flip with an erase attached to it.
#
# READ THIS FIRST
#   A full install erases the target disk. Run --plan first: it executes the
#   same code and only suppresses the mutating commands, so the plan cannot
#   drift from what a real run does.
#
#   installer.sh --plan          # change nothing, print everything
#   installer.sh                 # full install onto the one unused disk
#   installer.sh --mode side-by-side    # keep the current OS bootable
#
    : "${LFS_LOG:=/var/log/installer.log}"

# Where this file actually is, for the sections that re-read themselves -- the
# book functions are handed to children that start with an empty environment and
# so cannot source the parent. Set here rather than only in the execute branch
# because book_emit is also reachable from a sourced shell.
LFS_SELF=${LFS_SELF:-$(readlink -f "${BASH_SOURCE[0]}")}

# SAFETY-COPYCALL: "set -uo pipefail" without the -e. Stage failure RETURNS
# rather than exits, because the caller still has to unmount the ESP and the
# target; a bare exit there would strand both mounted. The one place that wants
# strict behaviour -- the in-chroot tasks -- turns -e on for itself.


# ===========================================================================
# Logging, confirmation and command execution
# ===========================================================================

# Shared logging and error helpers. Source, never execute.
#
# Every unit (detect/deps/target/boot) sources this so that output formatting,
# log-file handling and the dry-run gate are defined in exactly one place. The
# dry-run gate matters most: target selection and boot installation can make a
# machine unbootable, so every mutating call goes through `run` and is
# suppressed under
# --plan rather than each unit growing its own copy of that check.

# Log file for the whole run. Appended to, so a --resume run keeps history.
: "${LFS_LOG:=/var/log/installer.log}"

# 1 = print the command and skip it, 0 = run it for real.
: "${LFS_DRY_RUN:=0}"

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Append to the log file, best-effort.
#
# Must never be able to break the caller. Previewing a plan as a normal user is
# a legitimate thing to do, and the default /var/log/installer.log is not
# writable without root -- which used to print a tee error in front of every
# single line and bury the actual plan.
_logappend() {
    [ -n "${LFS_LOG:-}" ] || return 0
    local dir
    dir=$(dirname "$LFS_LOG" 2>/dev/null) || return 0
    [ -d "$dir" ] && [ -w "$dir" ] || return 0
    printf '%s\n' "$1" >> "$LFS_LOG" 2>/dev/null || true
}

_log() {
    # $1 = level, rest = message
    local level="$1"; shift
    local line
    line=$(printf '%s [%-5s] %s' "$(_ts)" "$level" "$*")
    printf '%s\n' "$line" >&2
    _logappend "$line"
}

say()  { _log "info" "$@"; }
warn() { _log "warn" "$@"; }
die()  { _log "fatal" "$@"; exit 1; }

# run CMD ARG... -- execute unless --plan, in which case just show what would run.
#
# This is the only sanctioned way for a unit to touch the system. Anything that
# mutates disks, partitions, or bootloader config MUST go through here, so that
# `installer.sh --plan` is trustworthy by construction rather than by
# everyone remembering to check the flag.
#
# Takes varargs, not one string, and executes argv[0] with the rest as
# arguments. Passing a single quoted string therefore executes a program whose
# name is the whole string: "run 'parted -s /dev/vdc mklabel gpt'" fails with
# ENOENT for a binary that is installed. The printed output is identical either
# way, so --plan cannot detect that mistake -- which is why the argument
# handling is fixed here rather than left to each call site.
run() {
    if [ "$LFS_DRY_RUN" = 1 ]; then
        local line
        line=$(printf '%s [PLAN ] would run: %s' "$(_ts)" "$*")
        printf '%s\n' "$line" >&2
        _logappend "$line"
        return 0
    fi
    local line
    line=$(printf '%s [exec ] %s' "$(_ts)" "$*")
    printf '%s\n' "$line" >&2
    _logappend "$line"
    "$@"
}

# same as run(), but for shell snippets that need redirection/pipes. The
# snippet is printed under --plan and eval'd otherwise.
runsh() {
    if [ "$LFS_DRY_RUN" = 1 ]; then
        local line
        line=$(printf '%s [PLAN ] would run: %s' "$(_ts)" "$1")
        printf '%s\n' "$line" >&2
        _logappend "$line"
        return 0
    fi
    local line
    line=$(printf '%s [exec ] %s' "$(_ts)" "$1")
    printf '%s\n' "$line" >&2
    _logappend "$line"
    bash -c "$1"
}

# A gate for anything irreversible. Under --plan it is always allowed (that is
# the point of a plan); otherwise it demands an explicit acknowledgement.
# $1 = what is about to happen, $2 = the env var that must be set to yes.
confirm_irreversible() {
    local what="$1" ack_var="${2:-LFS_I_UNDERSTAND}"
    if [ "$LFS_DRY_RUN" = 1 ]; then
        local line
        line=$(printf '%s [PLAN ] IRREVERSIBLE: %s' "$(_ts)" "$what")
        printf '%s\n' "$line" >&2
        _logappend "$line"
        return 0
    fi
    if [ "${!ack_var:-}" = "yes" ]; then
        return 0
    fi
    # Interactive gate. A plain `sudo ./installer.sh` runs on a terminal, and a
    # terminal has a human at it, so ask. Without this the documented one-liner
    # could never complete: --yes was described as skipping a prompt that did
    # not exist, so a bare run only ever died demanding an env var.
    #
    # Anything that is not a terminal -- nohup, cron, CI, a piped run -- has no
    # human to answer, so it falls through to the refusal rather than blocking
    # on a read that will never return.
    if [ -t 0 ] && [ -t 2 ]; then
        local reply=""
        printf '\n  About to happen:\n    %s\n' "$what" >&2
        printf '\n  This cannot be undone. Type yes to continue: ' >&2
        IFS= read -r reply || reply=""
        if [ "$reply" = "yes" ]; then
            return 0
        fi
        die "not confirmed ('$reply'), stopping before anything was changed.
  Re-run with --plan to see the full list of changes first, or --yes to
  acknowledge non-interactively."
    fi
    die "refusing to do something irreversible without $ack_var=yes
  What is about to happen: $what
  Re-run with --plan first to see the full list of changes.
  (There is no terminal to prompt on: pass --yes to acknowledge.)"
}

# in_list NEEDLE HAYSTACK... -- membership test over the arguments as given.
in_list() {
    local needle="$1"; shift
    # An empty needle must never match -- not even an empty list. Callers ask
    # "is this device/distro exempt?", and a vacuous match on an unset value
    # would wave a dangerous operation straight through. This guard used to be
    # an accident rather than a decision: unquoted $@ turned one empty argument
    # into zero words, so the loop below never ran and the function fell
    # through to "no match". Quoting $@ to stop word-splitting removed the
    # accident, so the intent is now stated rather than relied upon.
    [ -n "$needle" ] || return 1
    local item
    # "$@", not $@: an element containing a space is one element. Unquoted, it
    # word-splits, so it could never match and the needle could match the wrong
    # fragment of it -- and an unquoted $@ also globs against the cwd.
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

# lfs_job_count -- how many parallel make jobs to allow, for -j.
#
# Not simply $(nproc). GCC compiling glibc peaks at roughly 1.5 GB per cc1, so
# -j on a many-core machine asks for more memory than the box has; the OOM
# killer then takes a compiler out mid-object and the build fails with an error
# that reads like a corrupt source tree rather than "out of memory". Capping by
# memory turns that into a slower build instead of a dead one.
#
# MemAvailable, not MemFree: on a machine that has just booted, most of what
# looks like free memory is reclaimable page cache, and budgeting against it
# would leave the build one fork short of trouble.
#
# LFS_JOBS overrides everything, for a box whose real limit is something this
# cannot see (a cgroup limit that does not match /proc/meminfo, a shared host).
lfs_job_count() {
    local cpu mem_kb jobs
    if [ -n "${LFS_JOBS:-}" ]; then
        printf '%s' "$LFS_JOBS"
        return 0
    fi
    cpu=$(nproc 2>/dev/null || printf '1')
    mem_kb=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
    # No /proc/meminfo (a non-Linux host, or a container with it hidden): the
    # CPU count is the best guess available and is what this did before.
    case "${mem_kb:-}" in
        ''|*[!0-9]*) printf '%s' "$cpu"; return 0 ;;
    esac
    # 1.5 GB per job, rounded down: jobs = mem_MiB / 1536.
    jobs=$(( mem_kb / 1024 / 1536 ))
    [ "$jobs" -lt 1 ] && jobs=1
    [ "$jobs" -gt "$cpu" ] && jobs="$cpu"
    printf '%s' "$jobs"
}

# ===========================================================================
# Package tables
# ===========================================================================
#
# Pure data, one branch per package manager. This is the only place that knows
# package NAMES; nothing downstream mentions a distribution. The tables are
# asserted by tests/test_pkgmgr.sh, which is why they live here as assignments
# rather than buried in command lines: a typo in a package name should fail a
# test, not a build.
#
# PKGS            always installed
# PKG_INDEX_CMD   index refresh, run before install (may be empty)
# PKG_INSTALL_TMPL install command, with exactly one %s
# PKG_EXTRA_BIOS   added only on BIOS firmware
# PKG_EXTRA_UEFI   added only on UEFI firmware
#
# The firmware split is not decoration. On every one of these families the BIOS
# and UEFI GRUB images are separate packages, and a table that names only one
# of them produces a build that compiles for hours and then fails at
# grub-install, or installs a loader with no modules. apt-get's table was
# verified live on Ubuntu 24.04; the others are best-known names that have NOT
# been run on a real host -- see the note on each.

lfs_supported_pkgmgr() {
    printf '%s\n' apt-get dnf pacman zypper apk xbps-install emerge
}

pkgmgr_table() {  # pkgmgr_table NAME -- populate PKG_* from the table
    case "$1" in
    apt-get)
        # Debian package family: apt-get. Covers Debian, Ubuntu, Mint, Pop!_OS,
        # elementary, Kali, Devuan, MX and anything else that ships apt.
        #
        # Verified live on Ubuntu 24.04.
        #
        # GRUB here is grub2-common (which ships /usr/sbin/grub-install) plus
        # both platform image packages, because grub-install reads the image
        # out of the -bin package at install time. The name the table used to
        # carry, plain "grub", is a virtual package with no installation
        # candidate on Ubuntu 24.04 -- apt-get refuses it outright, and since
        # this runs before the target is touched that fails fast and safe.
        PKG_MGR=apt-get
        PKG_INDEX_CMD='apt-get update'
        PKG_INSTALL_TMPL='apt-get install -y --no-install-recommends %s'
        PKG_EXTRA_BIOS='grub-pc'
        PKG_EXTRA_UEFI='grub-efi-amd64'
        # curl, not wget: task_fetch_sources downloads with curl, and wget was
        # installed and never called. klibc was dropped for the same reason --
        # no path in this script references it, and most families do not ship it.
        PKGS="build-essential bison flex texinfo gawk sed grep findutils tar
             xz-utils bzip2 zstd patch file bc libtool gettext pkg-config curl
             gnupg expect rsync libncurses-dev libssl-dev libelf-dev
             libffi-dev python3 perl e2fsprogs parted mount util-linux passwd
             grub2-common grub-pc-bin grub-efi-amd64-bin
             efibootmgr dosfstools mtools"
        ;;
    dnf)
        # Fedora family: dnf. Covers Fedora and the RHEL derivatives that share
        # its names (Rocky, AlmaLinux, CentOS Stream, Oracle, Amazon Linux).
        # NOT verified live -- table review only.
        PKG_MGR=dnf
        PKG_INDEX_CMD='dnf makecache --refresh'
        PKG_INSTALL_TMPL='dnf install -y %s'
        PKG_EXTRA_BIOS='grub2-pc'
        PKG_EXTRA_UEFI='grub2-efi-x64'
        PKGS="@development-tools bison flex texinfo gawk sed grep findutils tar
             xz bzip2 zstd patch file bc libtool gettext pkgconf-pkg-config curl
             gnupg2 expect rsync ncurses-devel openssl-devel
             elfutils-libelf-devel libffi-devel python3 perl e2fsprogs
             util-linux shadow-utils efibootmgr dosfstools mtools parted"
        ;;
    pacman)
        # Arch family: pacman. Covers Manjaro, EndeavourOS, Garuda, Artix.
        # NOT verified live -- table review only.
        PKG_MGR=pacman
        PKG_INDEX_CMD='pacman -Sy --noconfirm'
        PKG_INSTALL_TMPL='pacman -S --needed --noconfirm %s'
        # Arch's single grub package ships both backends.
        PKG_EXTRA_BIOS='grub'
        PKG_EXTRA_UEFI='grub'
        PKGS="base-devel bison flex texinfo gawk sed grep findutils tar xz bzip2
             zstd patch file bc libtool gettext pkgconf curl gnupg expect rsync
             ncurses openssl elfutils libffi python perl e2fsprogs util-linux
             shadow efibootmgr dosfstools mtools parted"
        ;;
    zypper)
        # SUSE/openSUSE family: zypper. openSUSE reports ID="opensuse-leap" or
        # "opensuse-tumbleweed" with ID_LIKE="suse opensuse" -- neither of
        # which this script ever matches, which is the point.
        # NOT verified live -- table review only.
        PKG_MGR=zypper
        PKG_INDEX_CMD='zypper --non-interactive refresh'
        PKG_INSTALL_TMPL='zypper --non-interactive install %s'
        PKG_EXTRA_BIOS='grub2-i386-pc'
        PKG_EXTRA_UEFI='grub2-x86_64-efi'
        PKGS="gcc gcc-c++ make glibc-devel bison flex texinfo gawk sed grep
             findutils tar xz bzip2 zstd patch file bc libtool gettext
             pkgconf curl gpg2 expect rsync ncurses-devel libopenssl-devel
             libelf-devel libffi-devel python3 perl e2fsprogs util-linux
             shadow efibootmgr dosfstools mtools parted"
        ;;
    apk)
        # Alpine family: apk. The risk here is libc, not package names: every
        # other family is glibc and Alpine is musl, and stage 04's cross
        # toolchain links against the HOST libc. That cannot be verified from
        # a table, so this one is honestly a best effort.
        # NOT verified live -- table review only.
        PKG_MGR=apk
        PKG_INDEX_CMD='apk update'
        PKG_INSTALL_TMPL='apk add --no-cache %s'
        PKG_EXTRA_BIOS='grub'
        PKG_EXTRA_UEFI='grub-efi'
        PKGS="build-base bash binutils gcc g++ make musl-dev linux-headers perl
             python3 texinfo gawk sed grep findutils tar xz bzip2 zstd patch file
             bc libtool gettext pkgconf curl gnupg expect rsync ncurses-dev
             openssl-dev elfutils-dev libffi-dev e2fsprogs util-linux
             e2fsprogs-extra shadow efibootmgr dosfstools mtools parted"
        ;;
    xbps-install)
        # Void Linux family: xbps. Rolling release. xbps has no separate index
        # refresh -- install resolves and fetches in one step.
        # NOT verified live -- table review only.
        PKG_MGR=xbps-install
        PKG_INDEX_CMD=''
        PKG_INSTALL_TMPL='xbps-install -y %s'
        PKG_EXTRA_BIOS='grub'
        PKG_EXTRA_UEFI='grub'
        PKGS="base-devel bison flex texinfo gawk sed grep findutils tar xz bzip2
             zstd patch file bc libtool gettext pkg-config curl gnupg expect
             rsync ncurses-devel openssl-devel elfutils-devel libffi-devel
             python3 perl e2fsprogs util-linux shadow efibootmgr
             dosfstools mtools parted"
        ;;
    emerge)
        # Gentoo family: Portage. Gentoo is not a "list of packages"
        # distribution: atoms may be masked, may resolve to different USE-flag
        # sets, and the resolver may demand @world updates. deps_verify is the
        # real gate here -- it checks the binaries the build needs and stops
        # with a clear list if emerge did not deliver them.
        # NOT verified live -- table review only.
        PKG_MGR=emerge
        PKG_INDEX_CMD=''
        PKG_INSTALL_TMPL='emerge --noreplace --quiet %s'
        PKG_EXTRA_BIOS='sys-boot/grub'
        PKG_EXTRA_UEFI='sys-boot/grub'
        # g++ is not an atom: sys-devel/gcc ships it with the default USE=cxx.
        # The remaining corrections are atoms that did not exist under those
        # names; each was checked against packages.gentoo.org, and the binary
        # gate in deps_verify covers the rest.
        PKGS="sys-devel/gcc sys-devel/make sys-devel/binutils
             sys-libs/glibc dev-lang/perl dev-lang/python sys-devel/bison
             sys-devel/flex sys-apps/texinfo sys-apps/gawk sys-apps/sed
             sys-apps/grep sys-apps/findutils app-arch/tar
             app-arch/xz-utils app-arch/zstd sys-devel/patch sys-apps/file
             sys-devel/bc sys-devel/libtool sys-devel/gettext dev-util/pkgconf
             net-misc/curl app-crypt/gnupg dev-tcltk/expect net-misc/rsync
             sys-libs/ncurses dev-libs/openssl dev-libs/libffi dev-libs/elfutils
             sys-fs/e2fsprogs sys-apps/util-linux sys-block/parted sys-apps/shadow"
        ;;
    *)
        return 1
        ;;
    esac
    return 0
}


# ===========================================================================
# Detection
# ===========================================================================

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

# Where the os-release facts come from. Overridable purely so the test suite can
# point it at fixtures instead of the running system.
: "${LFS_OSRELEASE:=/etc/os-release}"

# Where the firmware facts come from. Overridable for the same reason
# LFS_OSRELEASE is: the test suite has no real /sys, and hard-coding these would
# make the firmware and secure-boot paths the only untested code in the unit.
: "${LFS_EFI_DIR:=/sys/firmware/efi}"
: "${LFS_EFIVARS_DIR:=/sys/firmware/efi/efivars}"

# The package managers that have a table below. This list -- not a list of
# distributions -- is what gates a run.
#
# Keying on the package manager rather than on ID= is what makes an unknown
# distribution work. Mint, Pop!_OS, Kali, Rocky, AlmaLinux, Manjaro,
# EndeavourOS, openSUSE and hundreds of others are not in any list we could
# write down, and every one of them is covered by the table for the package
# manager it already ships. All that is needed is a binary we can look for.
LFS_SUPPORTED_PKGMGR=$(printf '%s' "$(lfs_supported_pkgmgr)" | tr '\n' ' ')

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
  install a toolchain first (gcc, make, and the utilities in the package
  table for your system), or re-run from a full install."
    fi

    # shellcheck disable=SC2086  # in_list takes a word list; unquoted is the contract
    if ! in_list "$LFS_PKGMGR" $LFS_SUPPORTED_PKGMGR; then
        die "package manager '$LFS_PKGMGR' is not supported.
  Supported: $LFS_SUPPORTED_PKGMGR
  To add one, add a branch to pkgmgr_table() above naming its install command
  and the packages that provide the build tools, and add its name to
  lfs_supported_pkgmgr."
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
# The triplet must match the one lfs_build uses, because stage 04 gates on
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

# ===========================================================================
# Dependencies
# ===========================================================================

# Dependency installation: turn a detected package manager into an installed
# toolchain.
#
# Not sourced from anywhere: the package-manager-specific knowledge lives in
# pkgmgr_table() above as pure data, and the code below is the only thing
# that interprets it. That split is what makes each table testable without
# booting seven VMs -- see tests/test_pkgmgr.sh.
#
# Populated by deps_load:
#   PKG_MGR PKG_INDEX_CMD PKG_INSTALL_TMPL PKGS
#   PKG_EXTRA_BIOS PKG_EXTRA_UEFI  (cleared by every load, then re-set)
# Optional: DEPS_PREFLIGHT (shell snippet run before installing).
#
# Deliberately NOT here: anything about GRUB. Where grub.cfg lives and which
# command regenerates it differ between the Debian and RHEL layouts and have
# nothing to do with the package manager, so the code below detects those by
# looking at
# the machine. See boot_detect_grub.

# Keys every package table must define. Enforced at load time rather than
# trusted, because a missing key surfaces as a confusing failure much later --
# e.g. the GRUB code referencing an empty config path and silently writing its
# drop-in somewhere harmless.
DEPS_REQUIRED_KEYS="PKG_MGR PKG_INSTALL_TMPL PKGS"

# deps_load [PKGMGR] -- populate and validate the PKG_* keys for PKGMGR.
#
# Defaults to the detected package manager. The argument exists so the test
# suite and a curious user can ask "what would this do on Fedora?" without a
# Fedora host.
deps_load() {
    local d="${1:-${LFS_PKGMGR:-}}"
    [ -n "$d" ] || die "deps_load: no package manager given and none detected"
    local conf="the $d package table"

    # Clear first: these are global-ish names, and a previous load of a
    # different table would otherwise leave stale values behind for any key
    # this table happens not to set. PKG_INDEX_CMD is deliberately unset rather
    # than defaulted: a table that omits it means "no refresh step", and
    # defaulting to a previous table's command would run the wrong one.
    local k
    for k in $DEPS_REQUIRED_KEYS DEPS_PREFLIGHT PKG_INDEX_CMD \
             PKG_EXTRA_BIOS PKG_EXTRA_UEFI; do unset "$k"; done
    PKG_INDEX_CMD=""
    PKG_EXTRA_BIOS=""
    PKG_EXTRA_UEFI=""

    pkgmgr_table "$d" || die "no package table for '$d'
  Supported: $(lfs_supported_pkgmgr | tr '\n' ' ')"

    local missing=""
    for k in $DEPS_REQUIRED_KEYS; do
        [ -n "${!k:-}" ] || missing="$missing $k"
    done
    [ -z "$missing" ] || die "$conf is missing required key(s):$missing"

    # The manager named in the table must match the file it came from, or the
    # log will claim one thing while another happens.
    [ "$PKG_MGR" = "$d" ] || die "$conf declares PKG_MGR=$PKG_MGR, not $d"

    # Exactly one substitution point, or the package list is either dropped or
    # dumped into a single argv slot.
    case "$PKG_INSTALL_TMPL" in
        *%s*) ;;
        *) die "$conf: PKG_INSTALL_TMPL has no %s placeholder" ;;
    esac
    [ "$(printf '%s' "$PKG_INSTALL_TMPL" | tr -cd '%' | wc -c)" = 1 ] \
        || die "$conf: PKG_INSTALL_TMPL must contain exactly one %s"

    LFS_PKGMGR_CONF="$conf"
}

# deps_install -- install this host's build dependencies.
#
# The refresh step is separate from the install so that under --plan the user
# sees both, and so a cached-but-stale index is an explicit step rather than an
# invisible side effect of the install command.
deps_install() {
    # Under --plan nothing is actually installed, so requiring root would defeat
    # the point of previewing the whole run as an ordinary user.
    if [ "$LFS_DRY_RUN" != 1 ] && [ "$(id -u)" != 0 ]; then
        die "dependency installation needs root (run as root, or under sudo)"
    fi

    say "installing build dependencies via $PKG_MGR"
    if [ -n "${DEPS_PREFLIGHT:-}" ]; then
        say "running preflight for $PKG_MGR"
        runsh "$DEPS_PREFLIGHT" || die "preflight failed for $PKG_MGR"
    fi

    if [ -n "$PKG_INDEX_CMD" ]; then
        runsh "$PKG_INDEX_CMD" || die "package index refresh failed: $PKG_INDEX_CMD"
    fi

    # PKGS is newline-and-space separated in the table for readability; collapse
    # to a single space-separated list for word splitting.
    local pkglist
    pkglist=$(printf '%s' "$PKGS" | tr '\n' ' ' | tr -s ' ')

    # GRUB's platform package is firmware-specific on every family here, so the
    # table declares both and the detected firmware picks one. Getting this
    # wrong is the difference between a build that boots and one that dies at
    # grub-install after an hour of compiling, with the error buried in a log
    # inside the target.
    local extra=""
    case "${LFS_FIRMWARE:-}" in
        bios) extra="${PKG_EXTRA_BIOS:-}" ;;
        uefi) extra="${PKG_EXTRA_UEFI:-}" ;;
    esac
    if [ -n "$extra" ]; then
        say "firmware ${LFS_FIRMWARE}: adding $extra"
        pkglist="$pkglist $extra"
    fi

    say "packages: $pkglist"

    # PKG_INSTALL_TMPL is deliberately used as the format string: it is the
    # package manager's own install command, which legitimately carries %s for
    # the list. deps_validate above refuses any value without exactly one %s,
    # so there is no second conversion for $pkglist to be read as, and the
    # argument is passed positionally rather than interpolated into the template.
    # shellcheck disable=SC2059
    runsh "$(printf "$PKG_INSTALL_TMPL" "$pkglist")" \
        || die "dependency installation failed for $PKG_MGR"

    say "dependencies installed"
}

# deps_verify -- check the tools the build actually needs are now present.
#
# Deliberately checks for *binaries* rather than re-reading the package list.
# The package table is what we asked for; this is what we got, and on a
# distribution with split packages (libelf, ncurses, gettext) a name can resolve
# to a library-only package with no binary in it. Catching that here gives one
# clear error instead of a confusing failure hours into a compile.
deps_verify() {
    local missing=()
    local tool
    # The build's own hard requirements (book ch5 cross toolchain) plus the
    # host-side utilities the target-selection and boot steps shell out to.
    #
    # parted is in this list because target_prepare creates every partition and
    # every partition FLAG with it -- mklabel, mkpart, and `set 1 bios_grub on`
    # / `set 1 esp on` -- and nothing else in this script can write a GPT flag.
    # fdisk was checked here instead. fdisk does exist (util-linux ships it) --
    # but nothing in this script calls it, so the check passed on a tool that
    # never runs while saying nothing about the one that does. Without parted
    # present, target_prepare fails at the first partition step instead of here,
    # with a confusing "no such file" instead of a list.
    for tool in gcc g++ make ld as awk sed grep tar xz patch find mount \
                blkid mkfs.ext4 parted chroot uname python3 curl; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if [ "${#missing[@]}" -ne 0 ]; then
        die "these required tools are still missing after install: ${missing[*]}
  On a $PKG_MGR system the package providing one of them may be named
  differently than the table in $LFS_PKGMGR_CONF.
  Install them by hand, or add/fix the package name in that table and re-run --
  the point of this check is to fail now, with a list, rather than hours into
  the build."
    fi
    say "all required build tools present"
}

# ===========================================================================
# Target selection, safety and preparation
# ===========================================================================

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
    # non-/dev locations keeps "installer.sh --target sdb" from ever being
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

# ===========================================================================
# Host bootloader integration
# ===========================================================================

# Boot integration: make the freshly built LFS bootable alongside the host.
#
# Sourced, not executed.
#
# The two firmware paths are genuinely different problems, not two spellings of
# one:
#
#   BIOS -- the host owns the bootloader. There is exactly one MBR, and it
#     already points at some GRUB. The only safe move is to add a menuentry to
#     the host's own GRUB and let the host's regeneration run.
#
#   UEFI -- there are many independent boot entries in the ESP, each named by
#     EFI/<vendor>/BOOTX64.EFI. Adding LFS means adding a *new* entry alongside
#     the host's, leaving the host's untouched.
#
# Secure Boot adds a third case: firmware refuses to run anything it has not
# verified. See boot_install_uefi_secureboot.

: "${LFS_BOOT_ID:=LFS}"

# Conventional places an ESP gets mounted, in preference order. Not read from a
# distro table any more: the mount point is a property of how the host was set
# up, not of its distribution. Overridable so the test suite can assert the
# "no ESP mounted" refusal without depending on whether the machine running the
# tests happens to have /boot/efi mounted -- which is exactly the kind of
# environment dependence that made this case pass on one host and fail on
# another.
: "${LFS_ESP_CANDIDATES:=/boot/efi /efi}"

# --------------------------------------------------------- generated content

# boot_grub_menuentry ROOT_FS_UUID ROOT_PARTUUID KERNEL_VER -- emit a GRUB menuentry.
#
# Pure function, so the generated text is unit-testable without any disk.
#
# Deliberately keys on identifiers rather than GRUB's (hd0,gpt1) device notation.
# The hd notation depends on the BIOS drive-order and the partition table layout,
# so a disk added as a second device routinely comes up as (hd1,...) when the
# entry was written assuming (hd0,...) -- and GRUB's failure mode there is a
# silent drop to the rescue prompt. Identifiers do not move.
#
# `search` still needs the FILESYSTEM UUID, because that is what locates the
# partition GRUB reads the kernel from. The kernel's own root= gets the
# PARTUUID, for two measured reasons rather than taste:
#
#   - a device path (what grub-mkconfig emits unaided) breaks as soon as the
#     disk enumerates differently;
#   - root=UUID= does not work on this kernel at all. Booted with the correct
#     filesystem UUID -- read back with blkid inside the guest -- it panics with
#     "VFS: Cannot open root device", never opening the superblock.
#
# PARTUUID boots. That is the whole reason this takes a partition UUID rather
# than the filesystem UUID it already had.
boot_grub_menuentry() {
    local root_fs_uuid="$1" root_partuuid="$2" kver="$3"
    cat <<EOF
# Added by installer.sh. Delete this file to remove the LFS boot entry.
menuentry "Linux From Scratch $kver" --class lfs {
    insmod part_gpt
    insmod part_msdos
    insmod ext2
    search --no-floppy --fs-uuid --set=root $root_fs_uuid
    linux /boot/vmlinuz-$kver root=PARTUUID=$root_partuuid ro console=tty0 console=ttyS0,115200n8
}
EOF
}

# Deliberately NO initrd line. This build creates no initramfs: virtio, ext4 and
# the EFI stub are all built into the kernel (CONFIG_VIRTIO_BLK=y,
# CONFIG_EXT4_FS=y), which is why the takeover grub.cfg that grub-mkconfig
# generated carries no initrd line either. Emitting one here would point GRUB at
# a file that does not exist; grub-mkconfig's failure mode for a menuentry whose
# initrd is missing is to drop to the rescue prompt with no explanation, so this
# is the same class of silent breakage the UUID choice above exists to avoid.

# boot_efi_entry_name -- the directory name LFS gets inside the ESP.
boot_efi_entry_name() { printf 'EFI/%s' "$LFS_BOOT_ID"; }

# --------------------------------------------------------------- ESP finding

# boot_find_esp -- print the mountpoint of a mounted ESP, or nothing.
# Looks at the real mount table first, then falls back to the conventional
# /boot/efi, then /efi. Does not mount anything: mounting the ESP is a
# decision installer.sh makes explicitly, not a side effect of asking.
boot_find_esp() {
    local mp fstype
    if [ -r "$LFS_MOUNTS_FILE" ]; then
        # Project $1/$2/$3 with awk instead of `read dev mp fstype`: a
        # three-variable read assigns the *remainder of the line* to the last
        # variable, so fstype arrives as "vfat rw 0 0" and matches no arm,
        # and the ESP is then reported as absent.
        while IFS=$'\t' read -r _dev mp fstype; do
            case "$fstype" in
                vfat|fat|fat32|fat16) printf '%s' "$mp"; return 0 ;;
            esac
        done < <(awk 'NF>=3 {print $1"\t"$2"\t"$3}' "$LFS_MOUNTS_FILE")
    fi
    # ${LFS_ESP_CANDIDATES} rather than hardcoded paths: see its definition.
    for cand in $LFS_ESP_CANDIDATES; do
        [ -n "$cand" ] || continue
        if mountpoint -q "$cand" 2>/dev/null; then printf '%s' "$cand"; return 0; fi
    done
    return 1
}

# boot_check_not_syslinux -- refuse, clearly, when the host bootloader is not
# GRUB. Alpine defaults to syslinux, and writing /etc/grub.d/40_lfs on a
# syslinux host produces a file nothing reads: no error, no boot entry.
boot_check_not_syslinux() {
    local bootdir="${1:-/boot}"
    if [ -e "$bootdir/syslinux" ] || [ -e "$bootdir/extlinux" ]; then
        die "host bootloader looks like syslinux/extlinux ($bootdir/syslinux), not GRUB.
A GRUB drop-in would be ignored silently. Convert the host to GRUB first, or
use --firmware=uefi with an ESP."
    fi
    return 0
}

# ------------------------------------------------------------------ detect

# boot_detect_grub -- work out where this host keeps its GRUB configuration.
#
# Deliberately detected from the running machine rather than read out of a
# per-distro table, because the GRUB layout tracks the *bootloader generation*,
# not the package manager: Debian and Arch both use /boot/grub/grub.cfg with
# /etc/grub.d/*.conf, while Fedora and RHEL use /boot/grub2/grub.cfg and
# /etc/grub.d/*.cfg. No package-manager table can express "which of these two is
# this host", and guessing wrong writes a drop-in nothing reads.
#
# Sets:
#   GRUB_CONFIG_DIR   where drop-in snippets go
#   GRUB_CUSTOM_FILE  what to call ours
#   GRUB_REGEN        command that regenerates the host config
#   GRUB_TARGET_CFG   config that command will write
#
# Takes an optional boot directory (default /boot), matching
# boot_check_not_syslinux, so detection can be pointed at a scratch tree.
#
# The drop-in name has to match the host's convention because the *regen
# command* only picks up files with the right suffix: Debian's grub-mkconfig
# globs /etc/grub.d/*.conf, Fedora's globs *.cfg. A 40_lfs with no suffix is
# silently ignored on a Debian host, and a 40_lfs.cfg is ignored on Arch.
boot_grub_cfg_ok() {
    # A config that has not been generated yet is fine as long as its directory
    # exists: the regen command creates the file. Only a config under a
    # directory that is not there at all means the path is wrong.
    [ -f "$1" ] || [ -d "${1%/*}" ]
}

boot_detect_grub() {
    # Optional boot directory, so this can be pointed at a scratch tree when
    # testing rather than only at the real /boot. Same shape as
    # boot_check_not_syslinux.
    local bootdir="${1:-/boot}"
    GRUB_CONFIG_DIR=""

    # The config dir. /etc/grub.d is the modern location on every family
    # (Fedora included, despite its grub2 config path), but check the older
    # RHEL spot too so a genuinely ancient host is found rather than refused.
    local d
    for d in /etc/grub.d /etc/grub2.d; do
        if [ -d "$d" ]; then GRUB_CONFIG_DIR="$d"; break; fi
    done
    [ -n "$GRUB_CONFIG_DIR" ] || die "no GRUB config directory found.
Looked for /etc/grub.d and /etc/grub2.d. If this host uses another layout,
add it to the list in boot_detect_grub() above."

    # Which snippet suffix the regen command will actually pick up, and which
    # config it will write. The path is stated per family rather than scraped
    # back out of the command, because update-grub takes NO path argument -- it
    # chooses /boot/grub/grub.cfg itself on Debian/Ubuntu. Recovering the path by
    # matching it against the command could therefore never succeed for
    # update-grub: the string "update-grub" contains no path. That check fell
    # through on every Debian host and warned "no existing GRUB config found
    # under /boot/grub{,2}" about a config the host had just written.
    if command -v update-grub >/dev/null 2>&1; then
        GRUB_REGEN='update-grub'
        GRUB_CUSTOM_FILE='40_lfs.conf'
        GRUB_TARGET_CFG="$bootdir/grub/grub.cfg"
    elif command -v grub2-mkconfig >/dev/null 2>&1; then
        GRUB_REGEN='grub2-mkconfig -o /boot/grub2/grub.cfg'
        GRUB_CUSTOM_FILE='40_lfs.cfg'
        GRUB_TARGET_CFG="$bootdir/grub2/grub.cfg"
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        GRUB_REGEN='grub-mkconfig -o /boot/grub/grub.cfg'
        GRUB_CUSTOM_FILE='40_lfs.conf'
        GRUB_TARGET_CFG="$bootdir/grub/grub.cfg"
    else
        die "GRUB is installed but none of update-grub, grub2-mkconfig or
grub-mkconfig is on PATH, so the host config cannot be regenerated.
Install the host's GRUB tools, or add the correct command to the layout list in
boot_detect_grub() above if it lives somewhere unusual."
    fi

    # Confirm the config this host will write is really there, so a wrong path
    # is caught here rather than producing a boot entry that never appears in
    # the menu. The directory counts as enough: GRUB can be installed and have
    # never run mkconfig, and update-grub will create the config itself.
    boot_grub_cfg_ok "$GRUB_TARGET_CFG" && return 0
    warn "no existing GRUB config at $GRUB_TARGET_CFG; assuming $GRUB_REGEN
is still the right command for this host."
    return 0
}

# ------------------------------------------------------------------ install

# boot_install_bios ROOT_FS_UUID ROOT_PARTUUID KERNEL_VER
#
# Adds a drop-in to the host's grub.d and regenerates. The drop-in must be
# chmod +x or GRUB silently skips it.
boot_install_bios() {
    local root_uuid="$1" root_partuuid="$2" kver="$3"
    local dropin="$GRUB_CONFIG_DIR/$GRUB_CUSTOM_FILE"

    # A menuentry whose root= names nothing boots to a rescue prompt rather than
    # to an error, and this path is the one nobody watches. Render to a variable
    # and check THAT, so nothing touches the host's grub.d until it is known good
    # -- and so --plan, which must not write anything, can check the same text.
    [ -n "$root_partuuid" ] || die "internal error: no root PARTUUID for the LFS menuentry"
    local entry
    entry=$(boot_grub_menuentry "$root_uuid" "$root_partuuid" "$kver") || die "failed to render the LFS menuentry"
    case "$entry" in
        *root=PARTUUID=*) ;;
        *) die "the generated menuentry does not boot by PARTUUID; refusing to use it" ;;
    esac

    boot_check_not_syslinux /boot
    [ -d "$GRUB_CONFIG_DIR" ] || die "GRUB config dir not found: $GRUB_CONFIG_DIR (is GRUB installed?)"

    # A /etc/grub.d drop-in is not a GRUB config: grub-mkconfig runs every file
    # in that directory as a SHELL script and concatenates its stdout into
    # grub.cfg. A raw "menuentry ... }" block is not valid shell, so writing one
    # directly makes update-grub die with "menuentry: not found" and
    # 'Syntax error: "}" unexpected' -- the entry then never exists, while the
    # file on disk looks perfectly correct. (Found by running the real
    # function on a Debian-layout host.) The drop-in has to EMIT the entry.
    local wrapper
    wrapper=$(printf '#!/bin/sh\n# Added by installer.sh. Delete this file to remove the LFS boot entry.\ncat <<'"'"'LFS_GRUB_EOF'"'"'\n%s\nLFS_GRUB_EOF\n' "$(printf '%s\n' "$entry" | grep -v '^# Added by')")

    say "adding LFS menuentry to host GRUB: $dropin"
    if [ "${LFS_DRY_RUN:-0}" != 1 ]; then
        printf '%s\n' "$wrapper" > "$dropin" || die "failed to write $dropin"
        chmod 0755 "$dropin" || die "failed to chmod +x $dropin"
        # Cheap proof that the file we just wrote is the kind of thing
        # grub-mkconfig can run, before the regeneration that would fail on it.
        sh -n "$dropin" 2>/dev/null \
            || die "the generated drop-in is not a valid shell script, so grub-mkconfig
cannot run it; refusing to leave a broken file in $GRUB_CONFIG_DIR.
Rendered form was:
$wrapper"
    else
        say "[PLAN ] would write $dropin:"
        printf '%s\n' "$wrapper" | sed 's/^/[PLAN ]   /'
        say "[PLAN ] would chmod 0755 $dropin"
    fi

    say "regenerating host GRUB config"
    runsh "$GRUB_REGEN" || die "GRUB regeneration failed; the boot entry is not usable"
}

# boot_install_uefi ROOT_FS_UUID ROOT_PARTUUID KERNEL_VER
#
# Installs a self-contained GRUB loader into the ESP under a separate
# --bootloader-id so the host's entry is untouched and the firmware menu gains
# an LFS entry. The config is embedded in the image (see below) because a
# loader that resolves its config by prefix would read the host's menu.
boot_install_uefi() {
    local root_uuid="$1" root_partuuid="$2" kver="$3" esp

    esp=$(boot_find_esp) || die "no EFI System Partition is mounted.
Mount the ESP (usually /boot/efi) and re-run, e.g.:
  mount /dev/<esp-partition> ${ESP_MOUNT:-/boot/efi}
The LFS EFI directory would be $(boot_efi_entry_name)/."

    if [ "$LFS_SECUREBOOT" = "enabled" ]; then
        boot_install_uefi_secureboot "$esp"
        return
    fi

    local arch entry cfg_tmp loader
    arch=$(boot_efi_arch_suffix)
    loader="$esp/EFI/$LFS_BOOT_ID/grub${arch}.efi"

    # Checked here, before the build gets far, because this tool is a hard
    # requirement of the UEFI side-by-side path and a missing one otherwise
    # surfaces as a confusing grub-mkstandalone failure at the end of a long
    # run. It ships in the same package as grub-install on every distro.
    if [ "${LFS_DRY_RUN:-0}" != 1 ] && ! command -v grub-mkstandalone >/dev/null 2>&1; then
        die "grub-mkstandalone was not found, and the UEFI side-by-side entry cannot be built without it.
It ships in the same package as grub-install (grub2-common on Debian/Ubuntu,
grub2-tools on Fedora/RHEL). Install it, or use --mode takeover, which does not
need it."
    fi

    [ -n "$root_partuuid" ] || die "internal error: no root PARTUUID for the LFS boot entry"
    entry=$(boot_grub_menuentry "$root_uuid" "$root_partuuid" "$kver") || die "failed to render the LFS boot entry"
    case "$entry" in
        *root=PARTUUID=*) ;;
        *) die "the generated boot entry does not boot by PARTUUID; refusing to use it" ;;
    esac

    # grub-install is NOT used here. It bakes its prefix into the loader with
    # `grub-mkimage --prefix` and never writes a config into EFI/<id>/, so the
    # entry reads the prefix of whichever root was running at install time --
    # the host's /boot/grub/grub.cfg in side-by-side mode. The new firmware
    # entry then boots the host OS, which looks like LFS silently failing.
    # (Writing EFI/<id>/grub.cfg does not help; there is no such file to
    # write and nothing would read it.)
    #
    # grub-mkstandalone instead embeds the config in the image itself, so the
    # loader is self-contained: it boots the LFS kernel no matter which prefix
    # the host or firmware would otherwise choose.
    # grub-mkstandalone embeds every module when no module list is given. That
    # is deliberate: a hand-picked --install-modules list does not resolve
    # dependencies, and GRUB's `search` is a meta-module -- an image built with
    # only search_fs_uuid/search_label fails at boot with
    # "file `.../search.mod' not found". A 4 MB loader is a fine trade for a
    # side-by-side entry that has to work on the first boot.
    if [ "${LFS_DRY_RUN:-0}" != 1 ]; then
        cfg_tmp=$(mktemp "${TMPDIR:-/tmp}/lfs-grub.XXXXXX.cfg") || die "could not create a temporary file for the GRUB config"
        printf '%s\n' "$entry" > "$cfg_tmp" || { rm -f "$cfg_tmp"; die "could not write the GRUB config"; }
        trap 'rm -f "$cfg_tmp"' RETURN
        run mkdir -p "$esp/EFI/$LFS_BOOT_ID" || die "could not create $esp/EFI/$LFS_BOOT_ID"
        run grub-mkstandalone "--format=$(boot_grub_efi_target)" \
            "--output=$loader" \
            "boot/grub/grub.cfg=$cfg_tmp" \
            || die "could not build a self-contained loader at $loader"
    else
        # Same command the real run executes, so the plan shows the true
        # mechanism rather than a paraphrase of it.
        run mkdir -p "$esp/EFI/$LFS_BOOT_ID"
        run grub-mkstandalone "--format=$(boot_grub_efi_target)" \
            "--output=$loader" \
            "boot/grub/grub.cfg=<the entry above>"
        say "[PLAN ] the embedded config would be:"
        printf '%s\n' "$entry" | sed 's/^/[PLAN ]   /'
    fi

    # A firmware boot-order entry is a convenience, not the mechanism: the menu
    # entry always exists, and some firmware refuses --no-nvram-style entries.
    if [ "${LFS_DRY_RUN:-0}" != 1 ]; then
        local esp_dev
        esp_dev=$(findmnt -no SOURCE --target "$esp" 2>/dev/null || true)
        boot_register_nvram "$esp_dev" || \
            warn "could not add a firmware boot-order entry; use the one-time boot menu instead"
    fi

    say "UEFI entry installed; LFS will appear as '$LFS_BOOT_ID' in the firmware boot menu"
}

# boot_register_nvram ESP_DEV [BOOT_ID] -- add a firmware boot entry for the
# GRUB already installed on ESP_DEV.
#
# Disk and partition are resolved from the ESP itself. The version this
# replaces hardcoded "--part 1" and a fallback disk of /dev/sda, so on any disk
# whose ESP is not the first partition it registered an entry pointing at the
# wrong place -- and efibootmgr accepts that silently, producing a boot entry
# that exists and does not work. The loader path also has to end in .efi;
# "grubx64" without it is not a file the firmware will find.
#
# Returns non-zero when the entry cannot be created, so callers decide whether
# that is fatal. It is not, on a disk that also carries the EFI/BOOT fallback.
boot_register_nvram() {
    local esp_dev="$1" boot_id="${2:-${LFS_BOOT_ID:-LFS}}"
    local disk part arch
    [ -n "$esp_dev" ] || { warn "no EFI System Partition device to register"; return 1; }
    disk=$(lsblk -no PKNAME "$esp_dev" 2>/dev/null)
    part=$(lsblk -no PARTN  "$esp_dev" 2>/dev/null)
    if [ -z "$disk" ] || [ -z "$part" ]; then
        warn "cannot resolve the disk and partition of $esp_dev"
        return 1
    fi
    arch=$(boot_efi_arch_suffix)
    say "registering '$boot_id' in the firmware boot order (/dev/$disk part $part)"
    efibootmgr --create --label "$boot_id" \
        --disk "/dev/$disk" --part "$part" \
        --loader "\\EFI\\$boot_id\\grub$arch.efi" >/dev/null 2>&1
}

# boot_grub_efi_target -- the value for grub-install's --target.
#
# NOT the same thing as $LFS_TGT. That is the cross-compile triple
# (x86_64-lfs-linux-gnu); grub-install wants a CPU name (x86_64-efi). Passing
# the triple produces --target=x86_64-lfs-linux-gnu-efi, which grub-install
# rejects outright.
boot_grub_efi_target() {
    printf '%s-efi' "$LFS_ARCH"
}

# boot_efi_arch_suffix
boot_efi_arch_suffix() {
    case "$LFS_ARCH" in
        x86_64)  printf 'x64' ;;
        aarch64) printf 'aa64' ;;
        *)       printf '%s' "$LFS_ARCH" ;;
    esac
}

# boot_install_uefi_secureboot ESP
#
# With Secure Boot enabled, a freshly built GRUB image is unsigned and firmware
# will refuse it -- the entry is installed, the menu shows it, and selecting it
# drops straight back to the previous boot. That is a confusing failure, so it
# is handled explicitly rather than attempted and hoped for.
#
# The working approach is to reuse the host distribution's *signed* shim and
# GRUB, which are already trusted by the platform, and let that trusted GRUB
# load our LFS kernel. The LFS kernel itself is not subject to Secure Boot
# unless module signing is forced at runtime.
boot_install_uefi_secureboot() {
    local esp="$1" arch efi_shim efi_grub target_src
    arch=$(boot_efi_arch_suffix)
    target_src="/usr/lib/shim/shim${arch}.efi"

    if [ ! -f "$target_src" ]; then
        die "Secure Boot is enabled but $target_src was not found.
An unsigned GRUB cannot boot under Secure Boot, so this cannot be completed
safely. Options:
  1. Enrol this machine's MOK and sign GRUB with a key enrolled in the MOK list.
  2. Temporarily disable Secure Boot in firmware, boot LFS, then re-enable it.
  3. Install the signed GRUB this distribution already ships, if one exists."
    fi

    efi_shim="$esp/EFI/$LFS_BOOT_ID/shim${arch}.efi"
    efi_grub="$esp/EFI/$LFS_BOOT_ID/grub${arch}.efi"

    say "Secure Boot is enabled: installing the distribution's signed shim+grub as '$LFS_BOOT_ID'"
    run mkdir -p "$esp/EFI/$LFS_BOOT_ID"
    run cp "$target_src" "$efi_shim"
    # The distro's own grub binary, if shipped, is the signed one that shim
    # will accept. Falling back to a freshly built one here would fail
    # signature verification exactly as above.
    local signed_grub
    # Concrete paths only: a quoted glob inside a `for` list stays literal, so
    # "/boot/efi/EFI/*/grub.efi" would never match and the loop would skip it
    # silently.
    for cand in "/usr/lib/grub/${arch}-efi-signed/grub${arch}.efi.signed" \
                "/usr/share/efi/${arch}/grub${arch}.efi" \
                "/usr/lib/grub/${arch}-efi/grub${arch}.efi"; do
        if [ -f "$cand" ]; then signed_grub="$cand"; break; fi
    done
    [ -n "${signed_grub:-}" ] \
        || die "no signed grub${arch}.efi found to pair with shim; see the Secure Boot message above"

    say "using signed GRUB: $signed_grub"
    run cp "$signed_grub" "$efi_grub"
    say "NOTE: the LFS boot entry must be added to that GRUB's config by hand;"
    say "      grub-install was not used because it would overwrite the signed image."
}

# ===========================================================================
# The build
# ===========================================================================
#
# Staged, checkpointed LFS 13.1-systemd build. Partitioning, formatting and
# mounting are NOT here: they happen earlier, on the host, because they are the
# destructive part and need the safety gate and the --plan preview. By the time
# any of this runs it is handed an already-mounted ext4 filesystem at $LFS.
#
# Each stage writes $LFS/.stages/<name>.done on success, and chapter 8 also
# checkpoints per package (80 of them), so an interrupted build resumes instead
# of starting again from glibc.

lfs_build() {  # lfs_build [--mount DIR] [--resume] [--stage NAME]
    local RESUME=0 ONLY=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --resume) RESUME=1 ;;
            --stage)  ONLY="${2:-}"; shift ;;
            --mount)  LFS="${2:-}"; shift ;;
            *) say "usage: installer.sh --build [--resume] [--stage NAME]"; return 2 ;;
        esac
        shift
    done

    # A --stage name is validated HERE, before the sources gate below. Otherwise
    # `--stage typo` on a target whose sources were never fetched dies at the
    # sources check with "the sources stage has not run", which says nothing
    # about the actual mistake and reads like a broken resume.
    if [ -n "$ONLY" ]; then
        case "$ONLY" in
            sources|lfsusr|toolchain|temptools|chroot_tools|ch8|sysconfig|bootable) ;;
            *) say "unknown stage: $ONLY
  known stages: sources lfsusr toolchain temptools chroot_tools ch8 sysconfig bootable"
               return 2 ;;
        esac
    fi

    : "${LFS:=/mnt/lfs}"
    : "${LFS_TGT:=$(uname -m)-lfs-linux-gnu}"
    : "${LFS_ROOT_DEV:=}"
    : "${LFS_ROOT_UUID:=}"
    : "${LFS_BOOT_DISK:=}"
    : "${LFS_FIRMWARE:=bios}"
    : "${LFS_ESP_MOUNT:=}"

    # Declared, then assigned. `local MAKEFLAGS="$(lfs_job_count)"` would mask
    # the substitution's exit status behind local's own, so a lfs_job_count that
    # failed would leave MAKEFLAGS set to "-j" and let every later make run
    # unparallelised instead of stopping. lfs_job_count returns 0 on every path,
    # so splitting these changes no behaviour -- it only stops hiding a failure.
    local MAKEFLAGS LC_ALL=POSIX
    MAKEFLAGS="-j$(lfs_job_count)"
    local CONFIG_SITE="$LFS/usr/share/config.site"
    export LFS LFS_TGT MAKEFLAGS LC_ALL CONFIG_SITE
    export LFS_ROOT_DEV LFS_ROOT_UUID LFS_BOOT_DISK LFS_FIRMWARE LFS_ESP_MOUNT

    local STAGEDIR="$LFS/.stages" LOGDIR="$LFS/buildlogs"
    mkdir -p "$STAGEDIR" "$LOGDIR"

    # -rf and /* , not -f and *.done: the per-package checkpoint directories
    # (ch8-pkgs, temptools-pkgs, ...) live under STAGEDIR now, and a bare
    # *.done glob would leave every one of them in place -- so a non-resume run
    # would still skip every package. :? because `rm -rf "$STAGEDIR"/*` with an
    # empty STAGEDIR is `rm -rf /*`.
    [ "$RESUME" = 0 ] && rm -rf "${STAGEDIR:?}"/*

    # The book's build functions are in this file, so there is nothing left to
    # source. The stage lists are still checked, because an empty STAGE5 would
    # otherwise make chapter 5 report success having built nothing.
    #
    # ${#_s[@]} would be the length of the STRING "STAGE5" here, not the length
    # of the array -- six, always, so the guard would pass forever. The indirect
    # expansion is what makes this a real check.
    for _s in STAGE5 STAGE6 STAGE7 STAGE8; do
        # shellcheck disable=SC1087  # $_s must expand indirectly; see above
        eval "_n=\${#$_s[@]}"
        [ "${_n:-0}" -gt 0 ] \
            || { say "FAIL: $_s is empty -- the book functions did not load"; return 1; }
    done
    unset _s _n

    # Stage failure returns rather than exiting: the caller still has to unmount
    # the ESP and the target, and a bare `exit` here would strand both mounted.
    build_run_stage() {  # build_run_stage MARK FUNC
        local mark="$STAGEDIR/$1.done" fn="$2"
        if [ -f "$mark" ]; then echo "skip (done): $1"; return 0; fi
        echo "== stage: $1 =="
        if ! "$fn"; then echo "STAGE FAILED: $1" >&2; return 1; fi
        touch "$mark"
        echo "== stage done: $1 =="
    }

    if [ -n "$ONLY" ]; then
        case "$ONLY" in
            sources)         build_run_stage sources      build_stage_02_src ;;
            lfsusr)          build_run_stage lfsusr       build_stage_03_lfsusr ;;
            toolchain)       build_run_stage toolchain    build_stage_04 ;;
            temptools)       build_run_stage temptools    build_stage_05 ;;
            chroot_tools)    build_run_stage chroot_tools build_stage_06 ;;
            ch8)             build_run_stage ch8          build_stage_07 ;;
            sysconfig)       build_run_stage sysconfig    build_stage_08 ;;
            bootable)        build_run_stage bootable     build_stage_09 ;;
            *) say "unknown stage: $ONLY"; return 2 ;;
        esac
        return $?
    fi

    build_run_stage sources      build_stage_02_src      || return 1
    build_run_stage lfsusr       build_stage_03_lfsusr   || return 1
    build_run_stage toolchain    build_stage_04          || return 1
    build_run_stage temptools    build_stage_05          || return 1
    build_run_stage chroot_tools build_stage_06          || return 1
    build_run_stage ch8          build_stage_07          || return 1
    build_run_stage sysconfig    build_stage_08          || return 1
    build_run_stage bootable     build_stage_09          || return 1
    echo "BUILD COMPLETE"
}

build_stage_02_src() { task_fetch_sources; }

build_stage_03_lfsusr() {
    mkdir -pv "$LFS"/{etc,var} "$LFS"/usr/{bin,lib,sbin}
    for i in bin lib sbin; do ln -sv "usr/$i" "$LFS/$i"; done
    case $(uname -m) in x86_64) mkdir -pv "$LFS"/lib64 ;; esac
    mkdir -pv "$LFS/sources" "$LFS/tools"
    groupadd lfs 2>/dev/null || true
    useradd -s /bin/bash -g lfs -m -k /dev/null lfs 2>/dev/null || true
    chown -v lfs "$LFS"/{usr{,/*},lib,var,etc,tools,sources} 2>/dev/null || true
    case $(uname -m) in x86_64) chown -v lfs "$LFS"/lib64 2>/dev/null || true ;; esac
    install -d -m 0755 -o lfs -g lfs /home/lfs
    cat > /home/lfs/.bash_profile <<'EOF'
exec env -i HOME=/home/lfs TERM="$TERM" PS1="\u:\w\$ " /bin/bash
EOF
    emit_lfs_bashrc > /home/lfs/.bashrc
}

# emit_lfs_bashrc -- write the lfs user's login environment to its stdout
#
# Split out of build_stage_03_lfsusr so the test suite can call the actual
# producer. The version this replaces rebuilt the heredocs a second time in the
# test, which meant the test passed against a copy: change the generator and the
# copy keeps passing the old expectation, and the bug this function exists to
# prevent is back in the file nothing reads.
emit_lfs_bashrc() {
    # Two heredocs on purpose. The first is unquoted so the real mount point and
    # target triplet are baked in; the second expands the job count now and keeps
    # its own runtime references escaped. One quoted heredoc would keep LFS=/mnt/lfs
    # and silently build into the wrong place; one unquoted heredoc would strip the
    # backslash out of PS1's "\u:\w\$ ".
    #
    # The job count is substituted HERE, not left as $(lfs_job_count) for the
    # login shell to evaluate. lfs_job_count is a function defined by this
    # script; a login shell running this .bashrc does not have it, so the command
    # failed, the count expanded to nothing, and MAKEFLAGS became "-j" -- which
    # make reads as *unlimited* parallelism. The memory cap meant to stop the
    # build swapping itself to death inverted into the one setting that guarantees
    # it.
    {
        cat <<EOF
set +h
umask 022
LFS=$LFS
LC_ALL=POSIX
LFS_TGT=$LFS_TGT
EOF
        cat <<EOF
PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:$PATH; fi
PATH=\$LFS/tools/bin:\$PATH
CONFIG_SITE=\$LFS/usr/share/config.site
MAKEFLAGS="-j$(lfs_job_count)"
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE MAKEFLAGS
EOF
    }
}

# build_run_lfs FUNC LOG -- run one book build function as the lfs user
#
# env -i means the child has an empty environment and cannot pick the book
# section up from anywhere on its own, so the parent has to hand it over.
#
# It hands it over as a file, NOT on stdin. The obvious version -- pipe the
# section in and `source /dev/stdin` -- works as root and fails as the lfs user.
# /dev/stdin is a symlink to /proc/self/fd/0, and reopening a pipe through
# procfs is only allowed for the user that owns the pipe inode. The child drops
# privileges to lfs, so it does not own the pipe root just made, and bash
# answers "Permission denied". That is not a theoretical difference: it is why
# the real build died in stage 4 with a one-line log while every host test
# passed. A world-readable temp file has no such ownership rule.
#
# It must be `source` and not `cat`: cat copies the bytes to stdout, and bash
# only defines a function when it PARSES one, so `{ cat; }` produces a log full
# of function definitions followed by "command not found", which is exactly what
# happened the first time.
#
# The child's own `set -e` is kept: each function is invoked as a separate
# top-level command, so a failed step there stops that package and nothing after.
build_run_lfs() {
    local fn="$1" log="$2" lib rc
    lib=$(mktemp "${TMPDIR:-/tmp}/lfs-book.XXXXXXXX") || return 1
    book_emit > "$lib" || { rm -f "$lib"; return 1; }
    # mktemp is 0600 and the child is not root, so it has to be opened up.
    chmod 0644 "$lib" || { rm -f "$lib"; return 1; }
    # shellcheck disable=SC2016  # single quotes are the point: $1 and $HOME must be
    # expanded by the bash INSIDE the env -i sandbox, not by this host shell. The
    # directive sits here because it cannot live inside a backslash continuation.
    runuser -u lfs -- env -i HOME=/home/lfs TERM="${TERM:-xterm}" \
        LFS="$LFS" LC_ALL="POSIX" LFS_TGT="$LFS_TGT" \
        CONFIG_SITE="$CONFIG_SITE" MAKEFLAGS="$MAKEFLAGS" \
        PATH="/usr/bin:/bin:$LFS/tools/bin" \
        bash -e -c 'source "$1"; cd "${HOME:-/tmp}"; '"$fn" \
        lfs-book "$lib" \
        > "$log" 2>&1
    rc=$?
    rm -f "$lib"
    return $rc
}

# Per-package checkpoints for stages 04/05/06.
#
# Stage 07 checkpoints per package and these three did not, so a failure on the
# last of chapter 6's 17 packages -- GCC, the longest single build in the book,
# is among them -- threw away every package before it. The marker is written
# only after the package function returns 0, so a resume skips exactly the
# packages that already succeeded.
#
# The marker holds the md5 of the tarball the package was built from rather than
# a bare timestamp, so replacing or half-downloading a source re-runs that
# package without anyone having to remember to delete a marker first. An empty
# marker (no PKG_SRC entry, or no tarball on disk at build time) is trusted, to
# stay compatible with mark files written before this existed.
pkg_done() {  # pkg_done PKGDIR PKG -- true when PKG can be skipped
    local pkgdir="$1" pkg="$2" mark src want have
    mark="$pkgdir/$pkg.done"
    [ -f "$mark" ] || return 1
    want=$(cat "$mark" 2>/dev/null) || want=""
    [ -n "$want" ] || return 0
    src="${PKG_SRC[$pkg]:-}"
    [ -n "$src" ] && [ -f "$LFS/sources/$src" ] || return 1
    have=$(md5sum "$LFS/sources/$src" | cut -d' ' -f1)
    [ "$want" = "$have" ]
}

pkg_mark() {  # pkg_mark PKGDIR PKG -- record PKG as built
    local pkgdir="$1" pkg="$2" mark src
    mkdir -p "$pkgdir"
    mark="$pkgdir/$pkg.done"
    src="${PKG_SRC[$pkg]:-}"
    if [ -n "$src" ] && [ -f "$LFS/sources/$src" ]; then
        md5sum "$LFS/sources/$src" | cut -d' ' -f1 > "$mark"
    else
        : > "$mark"
    fi
}

build_stage_04() {
    local p PKGDIR="$STAGEDIR/toolchain-pkgs"
    mkdir -p "$PKGDIR"
    for p in "${STAGE5[@]}"; do
        if pkg_done "$PKGDIR" "$p"; then
            echo "== ch5 $p == (checkpoint, skipping)"; continue
        fi
        echo "== ch5 $p =="
        build_run_lfs "$p" "$LOGDIR/ch5-$p.log" || { echo "FAIL ch5 $p" >&2; return 1; }
        pkg_mark "$PKGDIR" "$p"
    done
    # book 5.5 ldd fix (extracted in build_5_5_1_Glibc) plus a hard gate:
    "$LFS/tools/bin/$LFS_TGT-gcc" --version > /dev/null \
        || { echo "no cross gcc" >&2; return 1; }
    echo "TOOLCHAIN-OK"
}

build_stage_05() {
    local p PKGDIR="$STAGEDIR/temptools-pkgs"
    mkdir -p "$PKGDIR"
    for p in "${STAGE6[@]}"; do
        if pkg_done "$PKGDIR" "$p"; then
            echo "== ch6 $p == (checkpoint, skipping)"; continue
        fi
        echo "== ch6 $p =="
        build_run_lfs "$p" "$LOGDIR/ch6-$p.log" || { echo "FAIL ch6 $p" >&2; return 1; }
        pkg_mark "$PKGDIR" "$p"
    done
}

build_stage_06() {
    chown --from lfs -R root:root "$LFS"/{usr,var,etc,tools} \
        || { echo "chown fail" >&2; return 1; }
    case $(uname -m) in
      x86_64) chown --from lfs -R root:root "$LFS/lib64" \
          || { echo "chown lib64 fail" >&2; return 1; } ;;
    esac
    # book 7.5/7.6 essential dirs + files, inside the chroot
    lfs_enter_chroot "bash /root/installer.sh --internal chroot-prep" \
        > "$LOGDIR/chroot-prep.log" 2>&1 \
        || { echo "FAIL chroot-prep" >&2; return 1; }
    local p PKGDIR="$STAGEDIR/chroot-tools-pkgs"
    mkdir -p "$PKGDIR"
    for p in "${STAGE7[@]}"; do
        if pkg_done "$PKGDIR" "$p"; then
            echo "== ch7 $p == (checkpoint, skipping)"; continue
        fi
        echo "== ch7 $p =="
        # The book functions live in the copy of this file that stage 06 put at
        # /root/installer.sh, so re-enter THIS script to run one. Four
        # invocations per chapter rather than one, but it is the difference
        # between one file and a file plus a generated companion.
        lfs_enter_chroot "bash /root/installer.sh --internal build-one $p" \
            > "$LOGDIR/ch7-$p.log" 2>&1 || { echo "FAIL ch7 $p" >&2; return 1; }
        pkg_mark "$PKGDIR" "$p"
    done
    lfs_enter_chroot "rm -rf /tools" || true   # book 7.15
}

build_stage_07() {
    # Per-package checkpoints: chapter 8 is 80 packages, and a mid-chapter
    # failure otherwise forces a re-run from glibc (~25 min) plus binutils/gcc.
    # A marker is written only after the package function returns 0, so a resume
    # skips exactly the packages that already succeeded.
    local PKGDIR="$STAGEDIR/ch8-pkgs" p m
    mkdir -p "$PKGDIR"
    for p in "${STAGE8[@]}"; do
        m="$PKGDIR/$p.done"
        if [ -f "$m" ]; then
            echo "== ch8 $p == (checkpoint, skipping)"
            continue
        fi
        echo "== ch8 $p =="
        # The book functions live in the copy of this file that stage 06 put at
        # /root/installer.sh, so re-enter THIS script to run one. Four
        # invocations per chapter rather than one, but it is the difference
        # between one file and a file plus a generated companion.
        lfs_enter_chroot "bash /root/installer.sh --internal build-one $p" \
            > "$LOGDIR/ch8-$p.log" 2>&1 || { echo "FAIL ch8 $p" >&2; return 1; }
        : > "$m"
    done
    # Chapter 8 tail, excluded from the generated functions (next-heading
    # boundary). 8.82.2 Configuring E2fsprogs.
    lfs_enter_chroot "sed 's/metadata_csum_seed,//' -i /etc/mke2fs.conf" \
        || { echo "FAIL mke2fs.conf" >&2; return 1; }
    # 8.84 Stripping + 8.85 Cleaning Up.
    lfs_enter_chroot "bash /root/installer.sh --internal strip-ch8" \
        > "$LOGDIR/ch8-strip.log" 2>&1 || { echo "FAIL ch8 strip" >&2; return 1; }
}

build_stage_08() {
    lfs_enter_chroot "bash /root/installer.sh --internal sysconfig" \
        > "$LOGDIR/sysconfig.log" 2>&1 || { echo "FAIL ch9 system-config" >&2; return 1; }
}

build_stage_09() {
    # Fail here, on the host, naming the missing variable -- rather than letting
    # the bootable stage abort inside the chroot after the kernel has already
    # spent an hour compiling.
    local missing=()
    [ -n "$LFS_ROOT_DEV" ]  || missing+=(LFS_ROOT_DEV)
    [ -n "$LFS_ROOT_UUID" ] || missing+=(LFS_ROOT_UUID)
    # Needed on both firmware paths: the GRUB kernel line is rewritten to
    # root=PARTUUID, and without it the rewrite would produce
    # root=PARTUUID= -- an identifier nothing matches, which is the same silent
    # rescue-prompt failure the rewrite itself exists to prevent.
    [ -n "$LFS_ROOT_PARTUUID" ] || missing+=(LFS_ROOT_PARTUUID)
    if [ "$LFS_FIRMWARE" = bios ]; then
        [ -n "$LFS_BOOT_DISK" ] || missing+=(LFS_BOOT_DISK)
    else
        [ -n "$LFS_ESP_MOUNT" ] || missing+=(LFS_ESP_MOUNT)
        [ -n "$LFS_ESP_UUID" ]  || missing+=(LFS_ESP_UUID)
    fi
    if [ "${#missing[@]}" -gt 0 ]; then
        say "FAIL stage 09: cannot install a bootloader, unset: ${missing[*]}"
        return 1
    fi
    # The chroot's GRUB can only install the platform it was CONFIGURED for,
    # and that happened back in stage 07. Checking here rather than letting
    # grub-install fail later is worth the two lines: the kernel below is an
    # hour of compiling, and a UEFI build whose GRUB was configured for BIOS
    # has already lost it by this point.
    local grub_platform
    if [ "$LFS_FIRMWARE" = uefi ]; then grub_platform=x86_64-efi; else grub_platform=i386-pc; fi
    if [ ! -d "$LFS/usr/lib/grub/$grub_platform" ]; then
        say "FAIL stage 09: the chroot has no GRUB $grub_platform modules"
        say "  expected $LFS/usr/lib/grub/$grub_platform (firmware $LFS_FIRMWARE)"
        # Both markers, because either one alone leaves the trap half-armed.
        # Dropping only the package marker re-runs GRUB but then the chapter
        # checkpoint skips the stage that rebuilds it; dropping only ch8.done
        # re-runs the chapter but every package marker still says "already
        # built", so GRUB is never rebuilt at all.
        say "  rebuild it: rm -f $STAGEDIR/ch8-pkgs/build_8_65_1_GRUB_for_BIOS.done $STAGEDIR/ch8.done"
        say "  and re-run with --resume"
        return 1
    fi
    lfs_enter_chroot "bash /root/installer.sh --internal kernel" \
        > "$LOGDIR/kernel.log" 2>&1 || { echo "FAIL kernel build" >&2; return 1; }
    lfs_enter_chroot "bash /root/installer.sh --internal bootable" \
        > "$LOGDIR/bootable.log" 2>&1 || {
            echo "FAIL grub install; see $LOGDIR/bootable.log" >&2
            # Surface the reason: the log is inside the build, and the common
            # causes (grub-install failing on a BIOS target, a missing ESP under
            # UEFI) are otherwise invisible from here.
            tail -n 20 "$LOGDIR/bootable.log" >&2 || true
            return 1
        }
}

# ===========================================================================
# Crossing into the chroot
# ===========================================================================

# lfs_enter_chroot 'command' -- run a command inside the $LFS chroot.
#
# Not routed through run/runsh on purpose: those exist to make --plan suppress
# mutating commands, and a real build is only ever reached on the real path.
lfs_enter_chroot() {
    local MOUNT="${LFS:-/mnt/lfs}"
    # Book 7.3: the mount points must exist before anything is mounted.
    mkdir -pv "$MOUNT"/{dev,proc,sys,run}
    # Deviation from book 7.3.1, which bind-mounts the host /dev: devtmpfs
    # provides the device nodes directly and needs no host-side dependency.
    mountpoint -q "$MOUNT/dev"     || mount -vt devtmpfs devtmpfs "$MOUNT/dev"
    mountpoint -q "$MOUNT/dev/pts" || mount -vt devpts devpts -o gid=5,mode=0620 "$MOUNT/dev/pts"
    mountpoint -q "$MOUNT/proc"    || mount -vt proc proc "$MOUNT/proc"
    mountpoint -q "$MOUNT/sys"     || mount -vt sysfs sysfs "$MOUNT/sys"
    mountpoint -q "$MOUNT/run"     || mount -vt tmpfs tmpfs "$MOUNT/run"
    [ -e "$MOUNT/dev/shm" ] || install -d -m 1777 "$MOUNT/dev/shm"

    # /usr/bin/env -i starts from an empty environment, so the disk identity is
    # passed through explicitly. Without this the bootable stage sees none of it
    # and falls back to guessing which disk to install GRUB onto.
    chroot "$MOUNT" /usr/bin/env -i \
        HOME=/root TERM="${TERM:-xterm}" PS1='(lfs chroot) \u:\w\$ ' \
        PATH=/usr/bin:/usr/sbin MAKEFLAGS="-j$(lfs_job_count)" \
        TESTSUITEFLAGS="-j$(lfs_job_count)" SOURCES_DIR=/sources \
        LFS_ROOT_DEV="${LFS_ROOT_DEV:-}" \
        LFS_ROOT_UUID="${LFS_ROOT_UUID:-}" \
        LFS_ROOT_PARTUUID="${LFS_ROOT_PARTUUID:-}" \
        LFS_BOOT_DISK="${LFS_BOOT_DISK:-}" \
        LFS_FIRMWARE="${LFS_FIRMWARE:-bios}" \
        LFS_ESP_MOUNT="${LFS_ESP_MOUNT:-}" \
        LFS_ESP_UUID="${LFS_ESP_UUID:-}" \
        LFS_BOOT_ID="${LFS_BOOT_ID:-LFS}" \
        /bin/bash -e -c "$1"
}


# ===========================================================================
# The book's build functions
# ===========================================================================
#
# GENERATED -- do not edit anything in this section by hand. These 113 package
# functions and the four stage lists are distilled mechanically from the LFS
# 13.1-systemd book (the same extraction that produced the validated build),
# with the book's chapter numbering turned into function names:
#
#     8.24.1 MPFR   ->   build_8_24_1_MPFR
#
# They are INLINED rather than downloaded or generated at run time on purpose.
# A distiller run during installation would make the whole build depend on
# scraping upstream HTML: one markup change, and an installer that worked
# yesterday now dies in stage 02 on a machine with no way to see why. Being
# larger is the cheaper failure.
#
# What was changed relative to the book's literal text, and why, is worth
# knowing before you trust any of it. Each of these is a deviation, not an
# optimisation:
#
#   * `exec /bin/bash --login` is dropped (8.39.1 Bash). `exec` replaces the
#     driving shell, so run non-interactively it takes the whole build down
#     with "script file read error: Bad file descriptor". It is a convenience
#     for a human at an interactive prompt.
#   * `bash tests/run.sh` is dropped (8.81.1 Util-linux). The book itself puts
#     it after booting the finished system; in the chroot it refuses to start.
#   * `PAGE=<paper_size> ./configure ...` keeps the command and drops the
#     placeholder (8.64.1 Groff). Taken literally, bash reads the rest of the
#     line as a stdin redirect from a file named paper_size.
#   * A bare `./configure ...` or `make ...` line ending in an ellipsis is the
#     book's prose placeholder, not a command, and is dropped (8.23.1 GMP).
#   * systemctl calls and prerequisite probes gain `|| true` in the chroot:
#     there is no running init and no tty there.
#   * Meson test suites gain a non-fatal tail; three are known to fail in a
#     chroot, and the book says so.
#   * Three commands that feed a file reader from `$(find ...)` are rewritten,
#     all for the same reason: with nothing to match, the substitution expands
#     to zero words and the reader is left with no operands and reads stdin,
#     which for a stage is the operator's console -- an unattended build hangs
#     there rather than finishing or failing.
#       §8.23.1 GMP      cat $(find -name '*.log') | grep -c ^PASS
#                    ->  find -name '*.log' -exec cat {} + | grep -c ^PASS || true
#         (also: grep -c exits 1 on a zero count, killing a stage whose `make
#         check` failure the line above just called non-fatal, and -exec stops
#         the count skipping log files whose names contain spaces)
#       §8.5.1 Glibc     grep "Timed out" $(find -name \*.out) || true
#       §8.22.1 Binutils grep '^FAIL:' $(find -name '*.log') || true
#                    ->  find ... -exec grep -H <pattern> {} + || true
#         (-H because the book greps several files and prefixes each match with
#         its filename, which is how the reader learns which package failed;
#         piping cat into grep would drop that prefix)
#   * GRUB's ./configure picks §8.65.2's UEFI platform flags when the target
#     boots UEFI, instead of §8.65.1's BIOS-only ones (8.65.1). The book
#     presents these as one package configured twice; a single build has to
#     pick one, and the modules for the platform it did not pick do not
#     exist in the chroot afterwards.
#
# The kernel is NOT here. Chapter 10 is built by task_kernel, which needs a
# different set of options than the book's prose describes, and the UEFI GRUB
# packages (§8.65.2/§8.65.3) are skipped in favour of the BIOS one configured
# for the detected firmware, plus task_bootable's explicit firmware switch.

# One function does the work here: book_emit, which reprints the region between
# the two markers. The markers are the only contract between it and the
# generated text, which is why the section is emitted exactly once, delimited,
# and never hand-edited.
# ---8<--- BOOK_FUNCS_BEGIN
        build_5_2_1_Cross_Binutils() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf binutils-2.47 || true
            tar -xf binutils-2.47.tar.xz || return 1
            pushd binutils-2.47 || return 1
            mkdir -v build
cd       build
../configure --prefix=$LFS/tools \
             --with-sysroot=$LFS \
             --target=$LFS_TGT   \
             --disable-nls       \
             --enable-gprofng=no \
             --disable-werror    \
             --enable-new-dtags  \
             --enable-default-hash-style=gnu
make
make install
            popd || return 1
            rm -rf binutils-2.47 || true
            popd || return 1
        }

        build_5_3_1_Cross_GCC() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf gcc-16.2.0 || true
            tar -xf gcc-16.2.0.tar.xz || return 1
            pushd gcc-16.2.0 || return 1
            tar -xf ../mpfr-4.2.2.tar.xz
mv -v mpfr-4.2.2 mpfr
tar -xf ../gmp-6.3.0.tar.xz
mv -v gmp-6.3.0 gmp
tar -xf ../mpc-1.4.1.tar.xz
mv -v mpc-1.4.1 mpc
case $(uname -m) in
  x86_64)
    sed -e '/m64=/s/lib64/lib/' \
        -i.orig gcc/config/i386/t-linux64
 ;;
esac
mkdir -v build
cd       build
../configure                  \
    --target=$LFS_TGT         \
    --prefix=$LFS/tools       \
    --with-glibc-version=2.44 \
    --with-sysroot=$LFS       \
    --with-newlib             \
    --without-headers         \
    --enable-default-pie      \
    --enable-default-ssp      \
    --disable-fixincludes     \
    --disable-nls             \
    --disable-shared          \
    --disable-multilib        \
    --disable-threads         \
    --disable-libatomic       \
    --disable-libgomp         \
    --disable-libquadmath     \
    --disable-libssp          \
    --disable-libvtv          \
    --disable-libstdcxx       \
    --enable-languages=c,c++
make
make install
cat ../gcc/{limitx,glimits,limity}.h  > \
  "$($LFS_TGT-gcc -print-file-name=include)"/limits.h
            popd || return 1
            rm -rf gcc-16.2.0 || true
            popd || return 1
        }

        build_5_4_1_Linux_API_Headers() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf linux-7.1.8 || true
            tar -xf linux-7.1.8.tar.xz || return 1
            pushd linux-7.1.8 || return 1
            make mrproper
make headers
find usr/include -type f ! -name '*.h' -delete
cp -rv usr/include $LFS/usr
            popd || return 1
            rm -rf linux-7.1.8 || true
            popd || return 1
        }

        build_5_5_1_Glibc() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf glibc-2.44 || true
            tar -xf glibc-2.44.tar.xz || return 1
            pushd glibc-2.44 || return 1
            case $(uname -m) in
    i?86)   ln -sfv ld-linux.so.2 $LFS/lib/ld-lsb.so.3
    ;;
    x86_64) ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64
            ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64/ld-lsb-x86-64.so.3
    ;;
esac
patch -Np1 -i ../glibc-fhs-1.patch
patch -Np1 -i ../glibc-2.44-upstream_fixes-1.patch
mkdir -v build
cd       build
echo "rootsbindir=/usr/sbin" > configparms
../configure                             \
      --prefix=/usr                      \
      --host=$LFS_TGT                    \
      --build="$(../scripts/config.guess)" \
      --disable-nscd                     \
      libc_cv_slibdir=/usr/lib           \
      --enable-kernel=5.10
make
make DESTDIR=$LFS install
sed '/RTLDLIST=/s@/usr@@g' -i $LFS/usr/bin/ldd
echo 'int main(){}' | $LFS_TGT-gcc -x c - -v -Wl,--verbose &> dummy.log
$LFS_TGT-readelf -l a.out | grep ': /lib'
grep -E -o "$LFS/lib.*/S?crt[1in].*succeeded" dummy.log
grep -B3 "^ $LFS/usr/include" dummy.log
grep 'SEARCH.*/usr/lib' dummy.log |sed 's|; |\n|g'
grep "/lib.*/libc.so.6 " dummy.log
grep found dummy.log
rm -v a.out dummy.log
            popd || return 1
            rm -rf glibc-2.44 || true
            popd || return 1
        }

        build_5_6_1_Target_Libstdc() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf gcc-16.2.0 || true
            tar -xf gcc-16.2.0.tar.xz || return 1
            pushd gcc-16.2.0 || return 1
            mkdir -v build
cd       build
../libstdc++-v3/configure      \
    --host=$LFS_TGT            \
    --build="$(../config.guess)" \
    CXX=$LFS_TGT-gcc           \
    --prefix=/usr              \
    --disable-multilib         \
    --disable-nls              \
    --disable-libstdcxx-pch    \
    --with-gxx-include-dir=/tools/$LFS_TGT/include/c++/16.2.0
make
make DESTDIR=$LFS install
rm -v $LFS/usr/lib/lib{stdc++{,exp,fs},supc++}.la
            popd || return 1
            rm -rf gcc-16.2.0 || true
            popd || return 1
        }

        build_6_2_1_M4() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf m4-1.4.21 || true
            tar -xf m4-1.4.21.tar.xz || return 1
            pushd m4-1.4.21 || return 1
            cat > $LFS/usr/share/config.site << EOF
ac_cv_func_posix_spawn_file_actions_addchdir=yes
ac_cv_func_posix_spawn_file_actions_addfchdir=yes
EOF
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build="$(build-aux/config.guess)"
make
make DESTDIR=$LFS install
            popd || return 1
            rm -rf m4-1.4.21 || true
            popd || return 1
        }

        build_6_3_1_Ncurses() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf ncurses-6.6 || true
            tar -xf ncurses-6.6.tar.gz || return 1
            pushd ncurses-6.6 || return 1
            mkdir build
pushd build
  ../configure --prefix=$LFS/tools AWK=gawk
  make -C include
  make -C progs tic
  install progs/tic $LFS/tools/bin
popd
./configure --prefix=/usr                \
            --host=$LFS_TGT              \
            --build="$(./config.guess)"    \
            --mandir=/usr/share/man      \
            --with-manpage-format=normal \
            --with-shared                \
            --without-normal             \
            --with-cxx-shared            \
            --without-debug              \
            --without-ada                \
            --disable-stripping          \
            AWK=gawk
make
make DESTDIR=$LFS install
ln -sv libncursesw.so $LFS/usr/lib/libncurses.so
sed -e 's/^#if.*XOPEN.*$/#if 1/' \
    -i $LFS/usr/include/curses.h
            popd || return 1
            rm -rf ncurses-6.6 || true
            popd || return 1
        }

        build_6_4_1_Bash() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf bash-5.3 || true
            tar -xf bash-5.3.tar.gz || return 1
            pushd bash-5.3 || return 1
            ./configure --prefix=/usr                      \
            --build="$(sh support/config.guess)" \
            --host=$LFS_TGT                    \
            --without-bash-malloc              \
            --docdir=/usr/share/doc/bash-5.3
make
make DESTDIR=$LFS install
ln -sv bash $LFS/bin/sh
            popd || return 1
            rm -rf bash-5.3 || true
            popd || return 1
        }

        build_6_5_1_Coreutils() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf coreutils-9.11 || true
            tar -xf coreutils-9.11.tar.xz || return 1
            pushd coreutils-9.11 || return 1
            ./configure --prefix=/usr                     \
            --host=$LFS_TGT                   \
            --build="$(build-aux/config.guess)" \
            --enable-install-program=hostname
make
make DESTDIR=$LFS install
mv -v $LFS/usr/bin/chroot              $LFS/usr/sbin
mkdir -pv $LFS/usr/share/man/man8
mv -v $LFS/usr/share/man/man1/chroot.1 $LFS/usr/share/man/man8/chroot.8
sed -i 's/"1"/"8"/'                    $LFS/usr/share/man/man8/chroot.8
            popd || return 1
            rm -rf coreutils-9.11 || true
            popd || return 1
        }

        build_6_6_1_Diffutils() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf diffutils-3.12 || true
            tar -xf diffutils-3.12.tar.xz || return 1
            pushd diffutils-3.12 || return 1
            ./configure --prefix=/usr   \
            --host=$LFS_TGT \
            gl_cv_func_strcasecmp_works=yes \
            --build="$(./build-aux/config.guess)"
make
make DESTDIR=$LFS install
            popd || return 1
            rm -rf diffutils-3.12 || true
            popd || return 1
        }

        build_6_7_1_File() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf file-5.48 || true
            tar -xf file-5.48.tar.gz || return 1
            pushd file-5.48 || return 1
            mkdir build
pushd build
  ../configure --disable-bzlib      \
               --disable-libseccomp \
               --disable-xzlib      \
               --disable-zlib
  make
popd
./configure --prefix=/usr --host=$LFS_TGT --build="$(./config.guess)"
make FILE_COMPILE="$(pwd)"/build/src/file
make DESTDIR=$LFS install
rm -v $LFS/usr/lib/libmagic.la
            popd || return 1
            rm -rf file-5.48 || true
            popd || return 1
        }

        build_6_8_1_Findutils() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf findutils-4.11.0 || true
            tar -xf findutils-4.11.0.tar.xz || return 1
            pushd findutils-4.11.0 || return 1
            ./configure --prefix=/usr                   \
            --localstatedir=/var/lib/locate \
            --host=$LFS_TGT                 \
            --build="$(build-aux/config.guess)"
make
make DESTDIR=$LFS install
            popd || return 1
            rm -rf findutils-4.11.0 || true
            popd || return 1
        }

        build_6_9_1_Gawk() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf gawk-5.4.1 || true
            tar -xf gawk-5.4.1.tar.xz || return 1
            pushd gawk-5.4.1 || return 1
            sed -i 's/extras//' Makefile.in
./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build="$(build-aux/config.guess)"
make
make DESTDIR=$LFS install
            popd || return 1
            rm -rf gawk-5.4.1 || true
            popd || return 1
        }

        build_6_10_1_Grep() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf grep-3.12 || true
            tar -xf grep-3.12.tar.xz || return 1
            pushd grep-3.12 || return 1
            ./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build="$(./build-aux/config.guess)"
make
make DESTDIR=$LFS install
            popd || return 1
            rm -rf grep-3.12 || true
            popd || return 1
        }

        build_6_11_1_Gzip() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf gzip-1.14 || true
            tar -xf gzip-1.14.tar.xz || return 1
            pushd gzip-1.14 || return 1
            ./configure --prefix=/usr --host=$LFS_TGT
make
make DESTDIR=$LFS install
            popd || return 1
            rm -rf gzip-1.14 || true
            popd || return 1
        }

        build_6_12_1_Make() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf make-4.4.1 || true
            tar -xf make-4.4.1.tar.gz || return 1
            pushd make-4.4.1 || return 1
            ./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build="$(build-aux/config.guess)"
make
make DESTDIR=$LFS install
            popd || return 1
            rm -rf make-4.4.1 || true
            popd || return 1
        }

        build_6_13_1_Patch() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf patch-2.8 || true
            tar -xf patch-2.8.tar.xz || return 1
            pushd patch-2.8 || return 1
            ./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build="$(build-aux/config.guess)"
make
make DESTDIR=$LFS install
            popd || return 1
            rm -rf patch-2.8 || true
            popd || return 1
        }

        build_6_14_1_Sed() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf sed-4.10 || true
            tar -xf sed-4.10.tar.xz || return 1
            pushd sed-4.10 || return 1
            ./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build="$(./build-aux/config.guess)"
make
make DESTDIR=$LFS install
            popd || return 1
            rm -rf sed-4.10 || true
            popd || return 1
        }

        build_6_15_1_Tar() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf tar-1.35 || true
            tar -xf tar-1.35.tar.xz || return 1
            pushd tar-1.35 || return 1
            ./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build="$(build-aux/config.guess)"
make
make DESTDIR=$LFS install
            popd || return 1
            rm -rf tar-1.35 || true
            popd || return 1
        }

        build_6_16_1_Xz() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf xz-5.8.3 || true
            tar -xf xz-5.8.3.tar.xz || return 1
            pushd xz-5.8.3 || return 1
            ./configure --prefix=/usr                     \
            --host=$LFS_TGT                   \
            --build="$(build-aux/config.guess)" \
            --disable-static                  \
            --docdir=/usr/share/doc/xz-5.8.3
make
make DESTDIR=$LFS install
rm -v $LFS/usr/lib/liblzma.la
            popd || return 1
            rm -rf xz-5.8.3 || true
            popd || return 1
        }

        build_6_17_1_Binutils() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf binutils-2.47 || true
            tar -xf binutils-2.47.tar.xz || return 1
            pushd binutils-2.47 || return 1
            sed '6031s/$add_dir//' -i ltmain.sh
mkdir -v build
cd       build
../configure                   \
    --prefix=/usr              \
    --build="$(../config.guess)" \
    --host=$LFS_TGT            \
    --disable-nls              \
    --enable-shared            \
    --enable-gprofng=no        \
    --disable-werror           \
    --enable-64-bit-bfd        \
    --enable-new-dtags         \
    --enable-default-hash-style=gnu
make
make DESTDIR=$LFS install
rm -v $LFS/usr/lib/lib{bfd,ctf,ctf-nobfd,opcodes,sframe}.{a,la}
            popd || return 1
            rm -rf binutils-2.47 || true
            popd || return 1
        }

        build_6_18_1_GCC() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf gcc-16.2.0 || true
            tar -xf gcc-16.2.0.tar.xz || return 1
            pushd gcc-16.2.0 || return 1
            tar -xf ../mpfr-4.2.2.tar.xz
mv -v mpfr-4.2.2 mpfr
tar -xf ../gmp-6.3.0.tar.xz
mv -v gmp-6.3.0 gmp
tar -xf ../mpc-1.4.1.tar.xz
mv -v mpc-1.4.1 mpc
case $(uname -m) in
  x86_64)
    sed -e '/m64=/s/lib64/lib/' \
        -i.orig gcc/config/i386/t-linux64
  ;;
esac
mkdir -v build
cd       build
../configure                   \
    --build="$(../config.guess)" \
    --host=$LFS_TGT            \
    --target=$LFS_TGT          \
    --prefix=/usr              \
    --with-build-sysroot=$LFS  \
    --enable-default-pie       \
    --enable-default-ssp       \
    --disable-fixincludes      \
    --disable-nls              \
    --disable-multilib         \
    --disable-libatomic        \
    --disable-libgomp          \
    --disable-libquadmath      \
    --disable-libsanitizer     \
    --disable-libssp           \
    --disable-libvtv           \
    --enable-languages=c,c++   \
    CXX_FOR_TARGET="$LFS_TGT-gcc -nostdinc++" \
    LDFLAGS_FOR_TARGET=-L$PWD/$LFS_TGT/libgcc \
    target_configargs=gcc_cv_target_thread_file=posix
make
make DESTDIR=$LFS install
ln -sv gcc $LFS/usr/bin/cc
            popd || return 1
            rm -rf gcc-16.2.0 || true
            popd || return 1
        }

        build_7_7_1_Gettext() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf gettext-1.0 || true
            tar -xf gettext-1.0.tar.xz || return 1
            pushd gettext-1.0 || return 1
            ./configure --disable-shared
make
cp -v gettext-tools/src/{msgfmt,msgmerge,xgettext} /usr/bin
            popd || return 1
            rm -rf gettext-1.0 || true
            popd || return 1
        }

        build_7_8_1_Bison() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf bison-3.8.2 || true
            tar -xf bison-3.8.2.tar.xz || return 1
            pushd bison-3.8.2 || return 1
            ./configure --prefix=/usr \
            --docdir=/usr/share/doc/bison-3.8.2
make
make install
            popd || return 1
            rm -rf bison-3.8.2 || true
            popd || return 1
        }

        build_7_9_1_Perl() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf perl-5.44.0 || true
            tar -xf perl-5.44.0.tar.xz || return 1
            pushd perl-5.44.0 || return 1
            sh Configure -des                                         \
             -D prefix=/usr                               \
             -D vendorprefix=/usr                         \
             -D useshrplib                                \
             -D privlib=/usr/lib/perl5/5.44/core_perl     \
             -D archlib=/usr/lib/perl5/5.44/core_perl     \
             -D sitelib=/usr/lib/perl5/5.44/site_perl     \
             -D sitearch=/usr/lib/perl5/5.44/site_perl    \
             -D vendorlib=/usr/lib/perl5/5.44/vendor_perl \
             -D vendorarch=/usr/lib/perl5/5.44/vendor_perl
make
make install
            popd || return 1
            rm -rf perl-5.44.0 || true
            popd || return 1
        }

        build_7_10_1_Zlib() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf zlib-1.3.2 || true
            tar -xf zlib-1.3.2.tar.gz || return 1
            pushd zlib-1.3.2 || return 1
            ./configure --prefix=/usr
make
make install
rm -fv /usr/lib/libz.a
            popd || return 1
            rm -rf zlib-1.3.2 || true
            popd || return 1
        }

        build_7_11_1_mpdecimal() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf mpdecimal-4.0.1 || true
            tar -xf mpdecimal-4.0.1.tar.gz || return 1
            pushd mpdecimal-4.0.1 || return 1
            ./configure --prefix=/usr    \
            --disable-static \
            --docdir=/usr/share/doc/mpdecimal-4.0.1
make
make install
            popd || return 1
            rm -rf mpdecimal-4.0.1 || true
            popd || return 1
        }

        build_7_12_1_Python() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf Python-3.14.7 || true
            tar -xf Python-3.14.7.tar.xz || return 1
            pushd Python-3.14.7 || return 1
            ./configure --prefix=/usr       \
            --enable-shared     \
            --without-ensurepip \
            --without-static-libpython
make
make install
            popd || return 1
            rm -rf Python-3.14.7 || true
            popd || return 1
        }

        build_7_13_1_Texinfo() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf texinfo-7.3 || true
            tar -xf texinfo-7.3.tar.xz || return 1
            pushd texinfo-7.3 || return 1
            ./configure --prefix=/usr
make
make install
            popd || return 1
            rm -rf texinfo-7.3 || true
            popd || return 1
        }

        build_7_14_1_Util_linux() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf util-linux-2.42.2 || true
            tar -xf util-linux-2.42.2.tar.xz || return 1
            pushd util-linux-2.42.2 || return 1
            mkdir -pv /var/lib/hwclock
./configure --libdir=/usr/lib     \
            --runstatedir=/run    \
            --disable-chfn-chsh   \
            --disable-login       \
            --disable-nologin     \
            --disable-su          \
            --disable-setpriv     \
            --disable-runuser     \
            --disable-pylibmount  \
            --disable-static      \
            --disable-liblastlog2 \
            --without-python      \
            ADJTIME_PATH=/var/lib/hwclock/adjtime \
            --docdir=/usr/share/doc/util-linux-2.42.2
make
make install
            popd || return 1
            rm -rf util-linux-2.42.2 || true
            popd || return 1
        }

        build_8_3_1_Man_pages() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf man-pages-6.18 || true
            tar -xf man-pages-6.18.tar.xz || return 1
            pushd man-pages-6.18 || return 1
            rm -v man3/crypt*
make -R GIT=false prefix=/usr install
            popd || return 1
            rm -rf man-pages-6.18 || true
            popd || return 1
        }

build_8_4_1_Iana_Etc() {
    set -e
    local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
    pushd "$SOURCES_DIR" || return 1
    rm -rf iana-etc-20260805 || true
    tar -xf iana-etc-20260805.tar.gz || return 1
    pushd iana-etc-20260805 || return 1
    cp -v services protocols /etc
    popd || return 1
    rm -rf iana-etc-20260805 || true
    popd || return 1
}

        build_8_5_1_Glibc() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf glibc-2.44 || true
            tar -xf glibc-2.44.tar.xz || return 1
            pushd glibc-2.44 || return 1
            patch -Np1 -i ../glibc-fhs-1.patch
patch -Np1 -i ../glibc-2.44-upstream_fixes-1.patch
mkdir -v build
cd       build
../configure --prefix=/usr                   \
             --disable-werror                \
             --disable-nscd                  \
             libc_cv_slibdir=/usr/lib        \
             --enable-stack-protector=strong \
             --enable-kernel=5.10
make
make check || { echo "note: build_8_5_1_Glibc: test suite exited $? (book: failures non-fatal)"; }
find . -name '*.out' -exec grep -H "Timed out" {} + || true
touch /etc/ld.so.conf
sed '/test-installation/s@$(PERL)@echo not running@' -i ../Makefile
rm -f /usr/sbin/nscd
systemctl disable --now nscd || true
make DESTDIR=$PWD/dest install
install -vm755 dest/usr/lib/*.so.* /usr/lib
DIR=$(dirname "$(gcc -print-libgcc-file-name)")
[ -e $DIR/include/limits.h ]    || mv $DIR/include{-fixed,}/limits.h
[ -e $DIR/include/syslimits.h ] || mv $DIR/include{-fixed,}/syslimits.h
rm -rfv $DIR/include-fixed/*
unset DIR
make install
sed '/RTLDLIST=/s@/usr@@g' -i /usr/bin/ldd
localedef -i C -f UTF-8 C.UTF-8
localedef -i cs_CZ -f UTF-8 cs_CZ.UTF-8
localedef -i de_DE -f ISO-8859-1 de_DE
localedef -i de_DE@euro -f ISO-8859-15 de_DE@euro
localedef -i de_DE -f UTF-8 de_DE.UTF-8
localedef -i el_GR -f ISO-8859-7 el_GR
localedef -i en_GB -f ISO-8859-1 en_GB
localedef -i en_GB -f UTF-8 en_GB.UTF-8
localedef -i en_HK -f ISO-8859-1 en_HK
localedef -i en_PH -f ISO-8859-1 en_PH
localedef -i en_US -f ISO-8859-1 en_US
localedef -i en_US -f UTF-8 en_US.UTF-8
localedef -i es_ES -f ISO-8859-15 es_ES@euro
localedef -i es_MX -f ISO-8859-1 es_MX
localedef -i fa_IR -f UTF-8 fa_IR
localedef -i fr_FR -f ISO-8859-1 fr_FR
localedef -i fr_FR@euro -f ISO-8859-15 fr_FR@euro
localedef -i fr_FR -f UTF-8 fr_FR.UTF-8
localedef -i is_IS -f ISO-8859-1 is_IS
localedef -i is_IS -f UTF-8 is_IS.UTF-8
localedef -i it_IT -f ISO-8859-1 it_IT
localedef -i it_IT -f ISO-8859-15 it_IT@euro
localedef -i it_IT -f UTF-8 it_IT.UTF-8
localedef -i ja_JP -f EUC-JP ja_JP
localedef -i ja_JP -f UTF-8 ja_JP.UTF-8
localedef -i nl_NL@euro -f ISO-8859-15 nl_NL@euro
localedef -i ru_RU -f KOI8-R ru_RU.KOI8-R
localedef -i ru_RU -f UTF-8 ru_RU.UTF-8
localedef -i se_NO -f UTF-8 se_NO.UTF-8
localedef -i ta_IN -f UTF-8 ta_IN.UTF-8
localedef -i tr_TR -f UTF-8 tr_TR.UTF-8
localedef -i zh_CN -f GB18030 zh_CN.GB18030
localedef -i zh_HK -f BIG5-HKSCS zh_HK.BIG5-HKSCS
localedef -i zh_TW -f UTF-8 zh_TW.UTF-8
make localedata/install-locales
            popd || return 1
            rm -rf glibc-2.44 || true
            popd || return 1
        }

        build_8_6_1_Zlib() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf zlib-1.3.2 || true
            tar -xf zlib-1.3.2.tar.gz || return 1
            pushd zlib-1.3.2 || return 1
            ./configure --prefix=/usr
make
make check || { echo "note: build_8_6_1_Zlib: test suite exited $? (book: failures non-fatal)"; }
make install
rm -fv /usr/lib/libz.a
            popd || return 1
            rm -rf zlib-1.3.2 || true
            popd || return 1
        }

        build_8_7_1_Bzip2() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf bzip2-1.0.8 || true
            tar -xf bzip2-1.0.8.tar.gz || return 1
            pushd bzip2-1.0.8 || return 1
            patch -Np1 -i ../bzip2-1.0.8-install_docs-1.patch
sed -i 's@\(ln -s -f \)$(PREFIX)/bin/@\1@' Makefile
sed -i "s@(PREFIX)/man@(PREFIX)/share/man@g" Makefile
make -f Makefile-libbz2_so
make clean
make
make PREFIX=/usr install
cp -av libbz2.so.* /usr/lib
ln -sfv libbz2.so.1.0.8 /usr/lib/libbz2.so
ln -sfv libbz2.so.1.0.8 /usr/lib/libbz2.so.1
cp -v bzip2-shared /usr/bin/bzip2
for i in /usr/bin/{bzcat,bunzip2}; do
  ln -sfv bzip2 $i
done
rm -fv /usr/lib/libbz2.a
            popd || return 1
            rm -rf bzip2-1.0.8 || true
            popd || return 1
        }

        build_8_8_1_Xz() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf xz-5.8.3 || true
            tar -xf xz-5.8.3.tar.xz || return 1
            pushd xz-5.8.3 || return 1
            ./configure --prefix=/usr    \
            --disable-static \
            --docdir=/usr/share/doc/xz-5.8.3
make
make check || { echo "note: build_8_8_1_Xz: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf xz-5.8.3 || true
            popd || return 1
        }

        build_8_9_1_Lz4() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf lz4-1.10.0 || true
            tar -xf lz4-1.10.0.tar.gz || return 1
            pushd lz4-1.10.0 || return 1
            make BUILD_STATIC=no PREFIX=/usr
make -j1 check
make BUILD_STATIC=no PREFIX=/usr install
            popd || return 1
            rm -rf lz4-1.10.0 || true
            popd || return 1
        }

        build_8_10_1_Zstd() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf zstd-1.5.7 || true
            tar -xf zstd-1.5.7.tar.gz || return 1
            pushd zstd-1.5.7 || return 1
            make prefix=/usr
make check || { echo "note: build_8_10_1_Zstd: test suite exited $? (book: failures non-fatal)"; }
make prefix=/usr install
rm -v /usr/lib/libzstd.a
            popd || return 1
            rm -rf zstd-1.5.7 || true
            popd || return 1
        }

        build_8_11_1_File() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf file-5.48 || true
            tar -xf file-5.48.tar.gz || return 1
            pushd file-5.48 || return 1
            ./configure --prefix=/usr
make
make check || { echo "note: build_8_11_1_File: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf file-5.48 || true
            popd || return 1
        }

        build_8_12_1_Readline() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf readline-8.3 || true
            tar -xf readline-8.3.tar.gz || return 1
            pushd readline-8.3 || return 1
            sed -i '/MV.*old/d' Makefile.in
sed -i '/{OLDSUFF}/c:' support/shlib-install
sed -i 's/-Wl,-rpath,[^ ]*//' support/shobj-conf
sed -e '270a\
     else\
       chars_avail = 1;'      \
    -e '288i\   result = -1;' \
    -i.orig input.c
./configure --prefix=/usr    \
            --disable-static \
            --with-curses    \
            --docdir=/usr/share/doc/readline-8.3
make SHLIB_LIBS="-lncursesw"
make install
install -v -m644 doc/*.{ps,pdf,html,dvi} /usr/share/doc/readline-8.3
            popd || return 1
            rm -rf readline-8.3 || true
            popd || return 1
        }

        build_8_13_1_Pcre2() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf pcre2-10.47 || true
            tar -xf pcre2-10.47.tar.bz2 || return 1
            pushd pcre2-10.47 || return 1
            ./configure --prefix=/usr                       \
            --docdir=/usr/share/doc/pcre2-10.47 \
            --enable-unicode                    \
            --enable-jit                        \
            --enable-pcre2-16                   \
            --enable-pcre2-32                   \
            --enable-pcre2grep-libz             \
            --enable-pcre2grep-libbz2           \
            --enable-pcre2test-libreadline      \
            --disable-static
make
make check || { echo "note: build_8_13_1_Pcre2: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf pcre2-10.47 || true
            popd || return 1
        }

        build_8_14_1_M4() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf m4-1.4.21 || true
            tar -xf m4-1.4.21.tar.xz || return 1
            pushd m4-1.4.21 || return 1
            ./configure --prefix=/usr
make
make check || { echo "note: build_8_14_1_M4: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf m4-1.4.21 || true
            popd || return 1
        }

        build_8_15_1_Bc() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf bc-7.0.3 || true
            tar -xf bc-7.0.3.tar.xz || return 1
            pushd bc-7.0.3 || return 1
            CC='gcc -std=c99' ./configure --prefix=/usr -G -O3 -r
make
make test || { echo "note: build_8_15_1_Bc: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf bc-7.0.3 || true
            popd || return 1
        }

        build_8_16_1_Flex() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf flex-2.6.4 || true
            tar -xf flex-2.6.4.tar.gz || return 1
            pushd flex-2.6.4 || return 1
            ./configure --prefix=/usr    \
            --disable-static \
            --docdir=/usr/share/doc/flex-2.6.4
make
make check || { echo "note: build_8_16_1_Flex: test suite exited $? (book: failures non-fatal)"; }
make install
ln -sv flex   /usr/bin/lex
ln -sv flex.1 /usr/share/man/man1/lex.1
            popd || return 1
            rm -rf flex-2.6.4 || true
            popd || return 1
        }

        build_8_17_1_Tcl() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf tcl8.6.18 || true
            tar -xf tcl8.6.18-src.tar.gz || return 1
            pushd tcl8.6.18 || return 1
            SRCDIR="$(pwd)"
cd unix
./configure --prefix=/usr           \
            --mandir=/usr/share/man \
            --disable-rpath
make

sed -e "s|$SRCDIR/unix|/usr/lib|" \
    -e "s|$SRCDIR|/usr/include|"  \
    -i tclConfig.sh

sed -e "s|$SRCDIR/unix/pkgs/tdbc1.1.13|/usr/lib/tdbc1.1.13|" \
    -e "s|$SRCDIR/pkgs/tdbc1.1.13/generic|/usr/include|"     \
    -e "s|$SRCDIR/pkgs/tdbc1.1.13/library|/usr/lib/tcl8.6|"  \
    -e "s|$SRCDIR/pkgs/tdbc1.1.13|/usr/include|"             \
    -i pkgs/tdbc1.1.13/tdbcConfig.sh

sed -e "s|$SRCDIR/unix/pkgs/itcl4.3.7|/usr/lib/itcl4.3.7|" \
    -e "s|$SRCDIR/pkgs/itcl4.3.7/generic|/usr/include|"    \
    -e "s|$SRCDIR/pkgs/itcl4.3.7|/usr/include|"            \
    -i pkgs/itcl4.3.7/itclConfig.sh

unset SRCDIR
LC_ALL=C.UTF-8 make test
make install 
chmod 644 /usr/lib/libtclstub8.6.a
chmod -v u+w /usr/lib/libtcl8.6.so
make install-private-headers
ln -sfv tclsh8.6 /usr/bin/tclsh
mv -v /usr/share/man/man3/{Thread,Tcl_Thread}.3
cd ..
tar -xf ../tcl8.6.18-html.tar.gz --strip-components=1
mkdir -v -p /usr/share/doc/tcl-8.6.18
cp -v -r  ./html/* /usr/share/doc/tcl-8.6.18
            popd || return 1
            rm -rf tcl8.6.18 || true
            popd || return 1
        }

        build_8_18_1_Expect() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf expect5.45.4 || true
            tar -xf expect5.45.4.tar.gz || return 1
            pushd expect5.45.4 || return 1
            python3 -c 'from pty import spawn; spawn(["echo", "ok"])' || true
patch -Np1 -i ../expect-5.45.4-gcc15-1.patch
./configure --prefix=/usr           \
            --with-tcl=/usr/lib     \
            --enable-shared         \
            --disable-rpath         \
            --mandir=/usr/share/man \
            --with-tclinclude=/usr/include
make
make test || { echo "note: build_8_18_1_Expect: test suite exited $? (book: failures non-fatal)"; }
make install
ln -svf expect5.45.4/libexpect5.45.4.so /usr/lib
            popd || return 1
            rm -rf expect5.45.4 || true
            popd || return 1
        }

        build_8_19_1_DejaGNU() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf dejagnu-1.6.3 || true
            tar -xf dejagnu-1.6.3.tar.gz || return 1
            pushd dejagnu-1.6.3 || return 1
            mkdir -v build
cd       build
../configure --prefix=/usr
makeinfo --html --no-split -o doc/dejagnu.html ../doc/dejagnu.texi
makeinfo --plaintext       -o doc/dejagnu.txt  ../doc/dejagnu.texi
make check || { echo "note: build_8_19_1_DejaGNU: test suite exited $? (book: failures non-fatal)"; }
make install
install -v -dm755  /usr/share/doc/dejagnu-1.6.3
install -v -m644   doc/dejagnu.{html,txt} /usr/share/doc/dejagnu-1.6.3
            popd || return 1
            rm -rf dejagnu-1.6.3 || true
            popd || return 1
        }

        build_8_20_1_Ninja() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf ninja-1.13.2 || true
            tar -xf ninja-1.13.2.tar.gz || return 1
            pushd ninja-1.13.2 || return 1
            sed -i '/int Guess/a \
  int   j = 0;\
  char* jobs = getenv( "NINJAJOBS" );\
  if ( jobs != NULL ) j = atoi( jobs );\
  if ( j > 0 ) return j;\
' src/ninja.cc
python3 configure.py --bootstrap --verbose
install -vm755 ninja /usr/bin/
install -vDm644 misc/bash-completion /usr/share/bash-completion/completions/ninja
install -vDm644 misc/zsh-completion  /usr/share/zsh/site-functions/_ninja
            popd || return 1
            rm -rf ninja-1.13.2 || true
            popd || return 1
        }

        build_8_21_1_Pkgconf() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf pkgconf-3.0.5 || true
            tar -xf pkgconf-3.0.5.tar.xz || return 1
            pushd pkgconf-3.0.5 || return 1
            tar -xf ../meson-1.12.0.tar.gz
mkdir build
cd    build

python3 ../meson-1.12.0/meson.py setup --prefix=/usr --buildtype=release ..
ninja
ninja test
ninja install
mv /usr/share/doc/pkgconf{,-3.0.5}
ln -sv pkgconf   /usr/bin/pkg-config
ln -sv pkgconf.1 /usr/share/man/man1/pkg-config.1
            popd || return 1
            rm -rf pkgconf-3.0.5 || true
            popd || return 1
        }

        build_8_22_1_Binutils() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf binutils-2.47 || true
            tar -xf binutils-2.47.tar.xz || return 1
            pushd binutils-2.47 || return 1
            mkdir -v build
cd       build
../configure --prefix=/usr       \
             --sysconfdir=/etc   \
             --enable-ld=default \
             --enable-plugins    \
             --enable-shared     \
             --disable-werror    \
             --enable-64-bit-bfd \
             --enable-new-dtags  \
             --with-system-zlib  \
             --with-lib-path=/usr/lib \
             --enable-default-hash-style=gnu
make tooldir=/usr
make -k check || { echo "note: build_8_22_1_Binutils: test suite exited $? (book: failures non-fatal)"; }
find . -name '*.log' -exec grep -H '^FAIL:' {} + || true
make tooldir=/usr install
rm -rfv /usr/lib/lib{bfd,ctf,ctf-nobfd,gprofng,opcodes,sframe}.a \
        /usr/share/doc/gprofng/
            popd || return 1
            rm -rf binutils-2.47 || true
            popd || return 1
        }

        build_8_23_1_GMP() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf gmp-6.3.0 || true
            tar -xf gmp-6.3.0.tar.xz || return 1
            pushd gmp-6.3.0 || return 1
            sed -i '/long long t1;/,+1s/()/(...)/' configure
./configure --prefix=/usr    \
            --enable-cxx     \
            --disable-static \
            --docdir=/usr/share/doc/gmp-6.3.0
make
make html
make check || { echo "note: build_8_23_1_GMP: test suite exited $? (book: failures non-fatal)"; }
find . -name '*.log' -exec cat {} + | grep -c ^PASS || true
make install
make install-html
            popd || return 1
            rm -rf gmp-6.3.0 || true
            popd || return 1
        }

        build_8_24_1_MPFR() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf mpfr-4.2.2 || true
            tar -xf mpfr-4.2.2.tar.xz || return 1
            pushd mpfr-4.2.2 || return 1
            ./configure --prefix=/usr        \
            --disable-static     \
            --enable-thread-safe \
            --docdir=/usr/share/doc/mpfr-4.2.2
make
make html
make check || { echo "note: build_8_24_1_MPFR: test suite exited $? (book: failures non-fatal)"; }
make install
make install-html
            popd || return 1
            rm -rf mpfr-4.2.2 || true
            popd || return 1
        }

        build_8_25_1_MPC() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf mpc-1.4.1 || true
            tar -xf mpc-1.4.1.tar.xz || return 1
            pushd mpc-1.4.1 || return 1
            ./configure --prefix=/usr    \
            --disable-static \
            --docdir=/usr/share/doc/mpc-1.4.1
make
make html
make check || { echo "note: build_8_25_1_MPC: test suite exited $? (book: failures non-fatal)"; }
make install
make install-html
            popd || return 1
            rm -rf mpc-1.4.1 || true
            popd || return 1
        }

        build_8_26_1_Attr() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf attr-2.6.0 || true
            tar -xf attr-2.6.0.tar.gz || return 1
            pushd attr-2.6.0 || return 1
            ./configure --prefix=/usr     \
            --disable-static  \
            --sysconfdir=/etc \
            --docdir=/usr/share/doc/attr-2.6.0
make
make check || { echo "note: build_8_26_1_Attr: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf attr-2.6.0 || true
            popd || return 1
        }

        build_8_27_1_Acl() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf acl-2.4.0 || true
            tar -xf acl-2.4.0.tar.xz || return 1
            pushd acl-2.4.0 || return 1
            ./configure --prefix=/usr    \
            --disable-static \
            --docdir=/usr/share/doc/acl-2.4.0
make
make check || { echo "note: build_8_27_1_Acl: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf acl-2.4.0 || true
            popd || return 1
        }

        build_8_28_1_Libcap() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf libcap-2.78 || true
            tar -xf libcap-2.78.tar.xz || return 1
            pushd libcap-2.78 || return 1
            sed -i '/install -m.*STA/d' libcap/Makefile
make prefix=/usr lib=lib
make test || { echo "note: build_8_28_1_Libcap: test suite exited $? (book: failures non-fatal)"; }
make prefix=/usr lib=lib install
            popd || return 1
            rm -rf libcap-2.78 || true
            popd || return 1
        }

        build_8_29_1_Libxcrypt() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf libxcrypt-4.5.2 || true
            tar -xf libxcrypt-4.5.2.tar.xz || return 1
            pushd libxcrypt-4.5.2 || return 1
            sed -i '/strchr/s/const//' lib/crypt-{sm3,gost}-yescrypt.c
./configure --prefix=/usr                \
            --enable-hashes=strong,glibc \
            --enable-obsolete-api=no     \
            --disable-static             \
            --disable-failure-tokens
make
make check || { echo "note: build_8_29_1_Libxcrypt: test suite exited $? (book: failures non-fatal)"; }
make install
make distclean
./configure --prefix=/usr                \
            --enable-hashes=strong,glibc \
            --enable-obsolete-api=glibc  \
            --disable-static             \
            --disable-failure-tokens
make
cp -av --remove-destination .libs/libcrypt.so.1* /usr/lib
            popd || return 1
            rm -rf libxcrypt-4.5.2 || true
            popd || return 1
        }

        build_8_30_1_Shadow() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf shadow-4.20.2 || true
            tar -xf shadow-4.20.2.tar.xz || return 1
            pushd shadow-4.20.2 || return 1
            find man -name Makefile.in -exec sed -i 's/getspnam\.3 / /' {} \;
find man -name Makefile.in -exec sed -i 's/passwd\.5 / /'   {} \;
sed -e 's:#ENCRYPT_METHOD SHA512:ENCRYPT_METHOD YESCRYPT:' \
    -e 's:/var/spool/mail:/var/mail:'                      \
    -e '/PATH=/{s@/sbin:@@;s@/bin:@@}'                     \
    -i etc/login.defs
touch /usr/bin/passwd
./configure --sysconfdir=/etc   \
            --disable-static    \
            --with-{b,yes}crypt \
            --without-libbsd    \
            --disable-logind    \
            --with-group-name-max-length=32
make
make exec_prefix=/usr install
make -C man install-man
            popd || return 1
            rm -rf shadow-4.20.2 || true
            popd || return 1
        }

        build_8_31_1_Gawk() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf gawk-5.4.1 || true
            tar -xf gawk-5.4.1.tar.xz || return 1
            pushd gawk-5.4.1 || return 1
            sed -i 's/extras//' Makefile.in
./configure --prefix=/usr
make
chown -R tester .
su tester -c "PATH=$PATH make check" || { echo "note: build_8_31_1_Gawk: test suite exited $? (book: failures non-fatal)"; }
rm -f /usr/bin/gawk-5.4.1
make install
ln -sv gawk.1 /usr/share/man/man1/awk.1
install -vDm644 doc/{awkforai.txt,*.{eps,pdf,jpg}} -t /usr/share/doc/gawk-5.4.1
            popd || return 1
            rm -rf gawk-5.4.1 || true
            popd || return 1
        }

        build_8_32_1_GCC() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf gcc-16.2.0 || true
            tar -xf gcc-16.2.0.tar.xz || return 1
            pushd gcc-16.2.0 || return 1
            case $(uname -m) in
  x86_64)
    sed -e '/m64=/s/lib64/lib/' \
        -i.orig gcc/config/i386/t-linux64
  ;;
esac
mkdir -v build
cd       build
../configure --prefix=/usr            \
             LD=ld                    \
             --enable-languages=c,c++ \
             --enable-default-pie     \
             --enable-default-ssp     \
             --enable-host-pie        \
             --enable-targets=all     \
             --disable-multilib       \
             --disable-bootstrap      \
             --disable-fixincludes    \
             --with-system-zlib
make
ulimit -s -H unlimited
chown -R tester .
su tester -c "PATH=$PATH make -k check" || { echo "note: build_8_32_1_GCC: test suite exited $? (book: failures non-fatal)"; }
../contrib/test_summary -t
make install
chown -v -R root:root "$(gcc -print-file-name=include)"{,-fixed}
ln -svr /usr/bin/cpp /usr/lib
ln -sv gcc.1 /usr/share/man/man1/cc.1
ln -sfvr "$(gcc -print-prog-name=liblto_plugin.so)" /usr/lib/bfd-plugins/
echo 'int main(){}' | cc -x c - -v -Wl,--verbose &> dummy.log
readelf -l a.out | grep ': /lib'
grep -E -o '/usr/lib.*/S?crt[1in].*succeeded' dummy.log
grep -B4 '^ /usr/include' dummy.log
grep 'SEARCH.*/usr/lib' dummy.log |sed 's|; |\n|g'
grep "/lib.*/libc.so.6 " dummy.log
grep found dummy.log
rm -v a.out dummy.log
mkdir -pv /usr/share/gdb/auto-load/usr/lib
mv -v /usr/lib/*gdb.py /usr/share/gdb/auto-load/usr/lib
            popd || return 1
            rm -rf gcc-16.2.0 || true
            popd || return 1
        }

        build_8_33_1_Ncurses() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf ncurses-6.6 || true
            tar -xf ncurses-6.6.tar.gz || return 1
            pushd ncurses-6.6 || return 1
            ./configure --prefix=/usr           \
            --mandir=/usr/share/man \
            --with-shared           \
            --without-debug         \
            --without-normal        \
            --with-cxx-shared       \
            --enable-pc-files       \
            --with-pkg-config-libdir=/usr/lib/pkgconfig
make
make DESTDIR=$PWD/dest install
sed -e 's/^#if.*XOPEN.*$/#if 1/' \
    -i dest/usr/include/curses.h
cp --remove-destination -av dest/* /
for lib in ncurses form panel menu ; do
    ln -sfv lib${lib}w.so /usr/lib/lib${lib}.so
    ln -sfv ${lib}w.pc    /usr/lib/pkgconfig/${lib}.pc
done
ln -sfv libncursesw.so /usr/lib/libcurses.so
cp -v -R doc -T /usr/share/doc/ncurses-6.6
make distclean
./configure --prefix=/usr    \
            --with-shared    \
            --without-normal \
            --without-debug  \
            --without-cxx-binding \
            --with-abi-version=5
make sources libs
cp -av lib/lib*.so.5* /usr/lib
            popd || return 1
            rm -rf ncurses-6.6 || true
            popd || return 1
        }

        build_8_34_1_Sed() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf sed-4.10 || true
            tar -xf sed-4.10.tar.xz || return 1
            pushd sed-4.10 || return 1
            ./configure --prefix=/usr
make
make html
chown -R tester .
su tester -c "PATH=$PATH make check" || { echo "note: build_8_34_1_Sed: test suite exited $? (book: failures non-fatal)"; }
make install
install -vDm644 doc/sed.html -t /usr/share/doc/sed-4.10
            popd || return 1
            rm -rf sed-4.10 || true
            popd || return 1
        }

        build_8_35_1_Psmisc() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf psmisc-23.7 || true
            tar -xf psmisc-23.7.tar.xz || return 1
            pushd psmisc-23.7 || return 1
            ./configure --prefix=/usr
make
make check || { echo "note: build_8_35_1_Psmisc: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf psmisc-23.7 || true
            popd || return 1
        }

        build_8_36_1_Gettext() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf gettext-1.0 || true
            tar -xf gettext-1.0.tar.xz || return 1
            pushd gettext-1.0 || return 1
            ./configure --prefix=/usr    \
            --disable-static \
            --docdir=/usr/share/doc/gettext-1.0
make
make check || { echo "note: build_8_36_1_Gettext: test suite exited $? (book: failures non-fatal)"; }
make install
chmod -v 0755 /usr/lib/preloadable_libintl.so
            popd || return 1
            rm -rf gettext-1.0 || true
            popd || return 1
        }

        build_8_37_1_Bison() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf bison-3.8.2 || true
            tar -xf bison-3.8.2.tar.xz || return 1
            pushd bison-3.8.2 || return 1
            ./configure --prefix=/usr --docdir=/usr/share/doc/bison-3.8.2
make
make check || { echo "note: build_8_37_1_Bison: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf bison-3.8.2 || true
            popd || return 1
        }

        build_8_38_1_Grep() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf grep-3.12 || true
            tar -xf grep-3.12.tar.xz || return 1
            pushd grep-3.12 || return 1
            sed -i "s/echo/#echo/" src/egrep.sh
./configure --prefix=/usr
make
make check || { echo "note: build_8_38_1_Grep: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf grep-3.12 || true
            popd || return 1
        }

        build_8_39_1_Bash() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf bash-5.3 || true
            tar -xf bash-5.3.tar.gz || return 1
            pushd bash-5.3 || return 1
            ./configure --prefix=/usr             \
            --without-bash-malloc     \
            --with-installed-readline \
            --docdir=/usr/share/doc/bash-5.3
make
chown -R tester .
LC_ALL=C.UTF-8 su -s /usr/bin/expect tester << "EOF" || { echo "note: build_8_39_1_Bash: test suite exited $? (book: failures non-fatal)"; }
set timeout -1
spawn make tests
expect eof
lassign [wait] _ _ _ value
exit $value
EOF
make install
            popd || return 1
            rm -rf bash-5.3 || true
            popd || return 1
        }

        build_8_40_1_Libtool() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf libtool-2.6.2 || true
            tar -xf libtool-2.6.2.tar.xz || return 1
            pushd libtool-2.6.2 || return 1
            ./configure --prefix=/usr
make
make check || { echo "note: build_8_40_1_Libtool: test suite exited $? (book: failures non-fatal)"; }
make install
rm -fv /usr/lib/libltdl.a
            popd || return 1
            rm -rf libtool-2.6.2 || true
            popd || return 1
        }

        build_8_41_1_GDBM() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf gdbm-1.26 || true
            tar -xf gdbm-1.26.tar.gz || return 1
            pushd gdbm-1.26 || return 1
            ./configure --prefix=/usr    \
            --disable-static \
            --enable-libgdbm-compat
make
make check || { echo "note: build_8_41_1_GDBM: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf gdbm-1.26 || true
            popd || return 1
        }

        build_8_42_1_Gperf() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf gperf-3.3 || true
            tar -xf gperf-3.3.tar.gz || return 1
            pushd gperf-3.3 || return 1
            ./configure --prefix=/usr --docdir=/usr/share/doc/gperf-3.3
make
make check || { echo "note: build_8_42_1_Gperf: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf gperf-3.3 || true
            popd || return 1
        }

        build_8_43_1_Expat() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf expat-2.8.3 || true
            tar -xf expat-2.8.3.tar.xz || return 1
            pushd expat-2.8.3 || return 1
            ./configure --prefix=/usr    \
            --disable-static \
            --docdir=/usr/share/doc/expat-2.8.3
make
make check || { echo "note: build_8_43_1_Expat: test suite exited $? (book: failures non-fatal)"; }
make install
install -v -m644 doc/*.{html,css} /usr/share/doc/expat-2.8.3
            popd || return 1
            rm -rf expat-2.8.3 || true
            popd || return 1
        }

        build_8_44_1_Inetutils() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf inetutils-2.8 || true
            tar -xf inetutils-2.8.tar.gz || return 1
            pushd inetutils-2.8 || return 1
            sed -i 's/def HAVE_TERMCAP_TGETENT/ 1/' telnet/telnet.c
./configure --prefix=/usr        \
            --bindir=/usr/bin    \
            --localstatedir=/var \
            --disable-logger     \
            --disable-whois      \
            --disable-rcp        \
            --disable-rexec      \
            --disable-rlogin     \
            --disable-rsh        \
            --disable-servers
make
make check || { echo "note: build_8_44_1_Inetutils: test suite exited $? (book: failures non-fatal)"; }
make install
mv -v /usr/{,s}bin/ifconfig
            popd || return 1
            rm -rf inetutils-2.8 || true
            popd || return 1
        }

        build_8_45_1_Less() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf less-704 || true
            tar -xf less-704.tar.gz || return 1
            pushd less-704 || return 1
            ./configure --prefix=/usr --sysconfdir=/etc
make
make check || { echo "note: build_8_45_1_Less: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf less-704 || true
            popd || return 1
        }

        build_8_46_1_Perl() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf perl-5.44.0 || true
            tar -xf perl-5.44.0.tar.xz || return 1
            pushd perl-5.44.0 || return 1
            export BUILD_ZLIB=False
export BUILD_BZIP2=0
sh Configure -des                                          \
             -D prefix=/usr                                \
             -D vendorprefix=/usr                          \
             -D privlib=/usr/lib/perl5/5.44/core_perl      \
             -D archlib=/usr/lib/perl5/5.44/core_perl      \
             -D sitelib=/usr/lib/perl5/5.44/site_perl      \
             -D sitearch=/usr/lib/perl5/5.44/site_perl     \
             -D vendorlib=/usr/lib/perl5/5.44/vendor_perl  \
             -D vendorarch=/usr/lib/perl5/5.44/vendor_perl \
             -D man1dir=/usr/share/man/man1                \
             -D man3dir=/usr/share/man/man3                \
             -D pager="/usr/bin/less -isR"                 \
             -D useshrplib                                 \
             -D usethreads
make
TEST_JOBS=$(nproc) make test_harness
make install
unset BUILD_ZLIB BUILD_BZIP2
            popd || return 1
            rm -rf perl-5.44.0 || true
            popd || return 1
        }

        build_8_47_1_Autoconf() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf autoconf-2.73 || true
            tar -xf autoconf-2.73.tar.xz || return 1
            pushd autoconf-2.73 || return 1
            ./configure --prefix=/usr
make
make check || { echo "note: build_8_47_1_Autoconf: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf autoconf-2.73 || true
            popd || return 1
        }

        build_8_48_1_Automake() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf automake-1.18.1 || true
            tar -xf automake-1.18.1.tar.xz || return 1
            pushd automake-1.18.1 || return 1
            ./configure --prefix=/usr --docdir=/usr/share/doc/automake-1.18.1
make
make -j$(($(nproc)>4?$(nproc):4)) check
make install
            popd || return 1
            rm -rf automake-1.18.1 || true
            popd || return 1
        }

        build_8_49_1_OpenSSL() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf openssl-4.0.1 || true
            tar -xf openssl-4.0.1.tar.gz || return 1
            pushd openssl-4.0.1 || return 1
            ./config --prefix=/usr         \
         --openssldir=/etc/ssl \
         --libdir=lib          \
         shared                \
         zlib-dynamic
make
make test || { echo "note: build_8_49_1_OpenSSL: test suite exited $? (book: failures non-fatal)"; }
for _d in 'openssl s_server' 'openssl ocsp'; do
    pkill -f "$_d" 2>/dev/null || true
done
make INSTALL_LIBS= MANSUFFIX=ssl install
mv -v /usr/share/doc/openssl /usr/share/doc/openssl-4.0.1
cp -vfr doc/* /usr/share/doc/openssl-4.0.1
            popd || return 1
            rm -rf openssl-4.0.1 || true
            popd || return 1
        }

        build_8_50_1_Libelf() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf elfutils-0.195 || true
            tar -xf elfutils-0.195.tar.bz2 || return 1
            pushd elfutils-0.195 || return 1
            ./configure --prefix=/usr        \
            --disable-debuginfod \
            --enable-libdebuginfod=dummy
make -C lib
make -C libelf
make -k check || { echo "note: build_8_50_1_Libelf: test suite exited $? (book: failures non-fatal)"; }
make -C libelf install
install -vm644 config/libelf.pc /usr/lib/pkgconfig
rm /usr/lib/libelf.a
            popd || return 1
            rm -rf elfutils-0.195 || true
            popd || return 1
        }

        build_8_51_1_Libffi() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf libffi-3.8.0 || true
            tar -xf libffi-3.8.0.tar.gz || return 1
            pushd libffi-3.8.0 || return 1
            ./configure --prefix=/usr    \
            --disable-static \
            --with-gcc-arch=native
make
make check || { echo "note: build_8_51_1_Libffi: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf libffi-3.8.0 || true
            popd || return 1
        }

        build_8_52_1_Sqlite() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf sqlite-autoconf-3530400 || true
            tar -xf sqlite-autoconf-3530400.tar.gz || return 1
            pushd sqlite-autoconf-3530400 || return 1
            python3 -m zipfile -e ../sqlite-doc-3530400.zip .
./configure --prefix=/usr     \
            --disable-static  \
            --enable-fts{4,5} \
            CPPFLAGS="-D SQLITE_ENABLE_COLUMN_METADATA=1 \
                      -D SQLITE_ENABLE_UNLOCK_NOTIFY=1   \
                      -D SQLITE_ENABLE_DBSTAT_VTAB=1     \
                      -D SQLITE_SECURE_DELETE=1"
make LDFLAGS.rpath=""
make install
cp -v -R sqlite-doc-3530400 -T /usr/share/doc/sqlite-3.53.4
            popd || return 1
            rm -rf sqlite-autoconf-3530400 || true
            popd || return 1
        }

        build_8_53_1_mpdecimal() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf mpdecimal-4.0.1 || true
            tar -xf mpdecimal-4.0.1.tar.gz || return 1
            pushd mpdecimal-4.0.1 || return 1
            ./configure --prefix=/usr    \
            --disable-static \
            --docdir=/usr/share/doc/mpdecimal-4.0.1
make
make check_local
make install
            popd || return 1
            rm -rf mpdecimal-4.0.1 || true
            popd || return 1
        }

        build_8_54_1_Python_3() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf Python-3.14.7 || true
            tar -xf Python-3.14.7.tar.xz || return 1
            pushd Python-3.14.7 || return 1
            patch -Np1 -i ../Python-3.14.7-openssl_4-1.patch
./configure --prefix=/usr          \
            --enable-shared        \
            --with-system-expat    \
            --enable-optimizations \
            --without-static-libpython
make
make test TESTOPTS="--timeout 120" || { echo "note: build_8_54_1_Python_3: test suite exited $? (book: failures non-fatal)"; }
make install
cat > /etc/pip.conf << EOF
[global]
root-user-action = ignore
disable-pip-version-check = true
EOF
install -v -dm755 /usr/share/doc/python-3.14.7/html

tar --strip-components=1  \
    --no-same-owner       \
    --no-same-permissions \
    -C /usr/share/doc/python-3.14.7/html \
    -xvf ../python-3.14.7-docs-html.tar.bz2
            popd || return 1
            rm -rf Python-3.14.7 || true
            popd || return 1
        }

        build_8_55_1_Flit_Core() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf flit_core-4.0.2 || true
            tar -xf flit_core-4.0.2.tar.gz || return 1
            pushd flit_core-4.0.2 || return 1
            pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps $PWD
pip3 install --no-index --find-links dist flit_core
            popd || return 1
            rm -rf flit_core-4.0.2 || true
            popd || return 1
        }

        build_8_56_1_Packaging() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf packaging-26.3 || true
            tar -xf packaging-26.3.tar.gz || return 1
            pushd packaging-26.3 || return 1
            pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps $PWD
pip3 install --no-index --find-links dist packaging
            popd || return 1
            rm -rf packaging-26.3 || true
            popd || return 1
        }

        build_8_57_1_Wheel() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf wheel-0.48.0 || true
            tar -xf wheel-0.48.0.tar.gz || return 1
            pushd wheel-0.48.0 || return 1
            pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps $PWD
pip3 install --no-index --find-links dist wheel
            popd || return 1
            rm -rf wheel-0.48.0 || true
            popd || return 1
        }

        build_8_58_1_Setuptools() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf setuptools-84.0.0 || true
            tar -xf setuptools-84.0.0.tar.gz || return 1
            pushd setuptools-84.0.0 || return 1
            pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps $PWD
pip3 install --no-index --find-links dist setuptools
            popd || return 1
            rm -rf setuptools-84.0.0 || true
            popd || return 1
        }

        build_8_59_1_Meson() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf meson-1.12.0 || true
            tar -xf meson-1.12.0.tar.gz || return 1
            pushd meson-1.12.0 || return 1
            pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps $PWD
pip3 install --no-index --find-links dist meson
install -vDm644 data/shell-completions/bash/meson /usr/share/bash-completion/completions/meson
install -vDm644 data/shell-completions/zsh/_meson /usr/share/zsh/site-functions/_meson
            popd || return 1
            rm -rf meson-1.12.0 || true
            popd || return 1
        }

        build_8_60_1_Kmod() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf kmod-34.2 || true
            tar -xf kmod-34.2.tar.xz || return 1
            pushd kmod-34.2 || return 1
            mkdir -p build
cd       build

meson setup --prefix=/usr ..    \
            --buildtype=release \
            -D manpages=false
ninja
ninja install
            popd || return 1
            rm -rf kmod-34.2 || true
            popd || return 1
        }

        build_8_61_1_Coreutils() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf coreutils-9.11 || true
            tar -xf coreutils-9.11.tar.xz || return 1
            pushd coreutils-9.11 || return 1
            patch -Np1 -i ../coreutils-9.11-i18n-1.patch
autoreconf -fv
automake -af
FORCE_UNSAFE_CONFIGURE=1 ./configure \
            --prefix=/usr
make
make NON_ROOT_USERNAME=tester check-root || { echo "note: build_8_61_1_Coreutils: test suite exited $? (book: failures non-fatal)"; }
groupadd -g 102 dummy -U tester
chown -R tester . 
su tester -c "PATH=$PATH make -k RUN_EXPENSIVE_TESTS=yes check" \
   < /dev/null || { echo "note: build_8_61_1_Coreutils: test suite exited $? (book: failures non-fatal)"; }
groupdel dummy
make install
mv -v /usr/bin/chroot /usr/sbin
mv -v /usr/share/man/man1/chroot.1 /usr/share/man/man8/chroot.8
sed -i 's/"1"/"8"/' /usr/share/man/man8/chroot.8
            popd || return 1
            rm -rf coreutils-9.11 || true
            popd || return 1
        }

        build_8_62_1_Diffutils() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf diffutils-3.12 || true
            tar -xf diffutils-3.12.tar.xz || return 1
            pushd diffutils-3.12 || return 1
            ./configure --prefix=/usr
make
make check || { echo "note: build_8_62_1_Diffutils: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf diffutils-3.12 || true
            popd || return 1
        }

        build_8_63_1_Findutils() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf findutils-4.11.0 || true
            tar -xf findutils-4.11.0.tar.xz || return 1
            pushd findutils-4.11.0 || return 1
            ./configure --prefix=/usr --localstatedir=/var/lib/locate
make
chown -R tester .
su tester -c "PATH=$PATH make check -k" || { echo "note: build_8_63_1_Findutils: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf findutils-4.11.0 || true
            popd || return 1
        }

        build_8_64_1_Groff() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf groff-1.24.1 || true
            tar -xf groff-1.24.1.tar.gz || return 1
            pushd groff-1.24.1 || return 1
            ./configure --prefix=/usr
make -j1
make check || { echo "note: build_8_64_1_Groff: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf groff-1.24.1 || true
            popd || return 1
        }

        build_8_65_1_GRUB_for_BIOS() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf grub-2.14 || true
            tar -xf grub-2.14.tar.xz || return 1
            pushd grub-2.14 || return 1
            sed 's/--image-base/--nonexist-linker-option/' -i configure
# Deviation from book §8.65.1: §8.65.2's platform flags for a 64-bit UEFI
# build, chosen from the detected firmware. The other two options are the
# book's, and stay on both branches.
case "${LFS_FIRMWARE:-bios}" in
    uefi)
        ./configure --prefix=/usr     \
            --sysconfdir=/etc \
            --target=x86_64 \
            --with-platform=efi \
            --disable-efiemu  \
            --disable-werror
        ;;
    *)
        ./configure --prefix=/usr     \
            --sysconfdir=/etc \
            --disable-efiemu  \
            --disable-werror
        ;;
esac
make
make install
            popd || return 1
            rm -rf grub-2.14 || true
            popd || return 1
        }

        build_8_66_1_Gzip() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf gzip-1.14 || true
            tar -xf gzip-1.14.tar.xz || return 1
            pushd gzip-1.14 || return 1
            ./configure --prefix=/usr
make
make check || { echo "note: build_8_66_1_Gzip: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf gzip-1.14 || true
            popd || return 1
        }

        build_8_67_1_IPRoute2() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf iproute2-7.1.0 || true
            tar -xf iproute2-7.1.0.tar.xz || return 1
            pushd iproute2-7.1.0 || return 1
            sed -i /ARPD/d Makefile
rm -fv man/man8/arpd.8
make NETNS_RUN_DIR=/run/netns
make SBINDIR=/usr/sbin install
install -vDm644 COPYING README* -t /usr/share/doc/iproute2-7.1.0
            popd || return 1
            rm -rf iproute2-7.1.0 || true
            popd || return 1
        }

        build_8_68_1_Kbd() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf kbd-2.10.0 || true
            tar -xf kbd-2.10.0.tar.xz || return 1
            pushd kbd-2.10.0 || return 1
            patch -Np1 -i ../kbd-2.10.0-backspace-1.patch
sed -i '/RESIZECONS_PROGS=/s/yes/no/' configure
sed -i 's/resizecons.8 //' docs/man/man8/Makefile.in
./configure --prefix=/usr --disable-vlock
make
make check || { echo "note: build_8_68_1_Kbd: test suite exited $? (book: failures non-fatal)"; }
make install
cp -R -v docs/doc -T /usr/share/doc/kbd-2.10.0
            popd || return 1
            rm -rf kbd-2.10.0 || true
            popd || return 1
        }

        build_8_69_1_Libpipeline() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf libpipeline-1.5.8 || true
            tar -xf libpipeline-1.5.8.tar.gz || return 1
            pushd libpipeline-1.5.8 || return 1
            ./configure --prefix=/usr
make
make install
            popd || return 1
            rm -rf libpipeline-1.5.8 || true
            popd || return 1
        }

        build_8_70_1_Make() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf make-4.4.1 || true
            tar -xf make-4.4.1.tar.gz || return 1
            pushd make-4.4.1 || return 1
            ./configure --prefix=/usr
make
chown -R tester .
su tester -c "PATH=$PATH make check" || { echo "note: build_8_70_1_Make: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf make-4.4.1 || true
            popd || return 1
        }

        build_8_71_1_Patch() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf patch-2.8 || true
            tar -xf patch-2.8.tar.xz || return 1
            pushd patch-2.8 || return 1
            ./configure --prefix=/usr
make
make check || { echo "note: build_8_71_1_Patch: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf patch-2.8 || true
            popd || return 1
        }

        build_8_72_1_Tar() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf tar-1.35 || true
            tar -xf tar-1.35.tar.xz || return 1
            pushd tar-1.35 || return 1
            patch -Np1 -i ../tar-1.35-acl_fix-1.patch
FORCE_UNSAFE_CONFIGURE=1  \
./configure --prefix=/usr
make
make check || { echo "note: build_8_72_1_Tar: test suite exited $? (book: failures non-fatal)"; }
make install
make -C doc install-html docdir=/usr/share/doc/tar-1.35
            popd || return 1
            rm -rf tar-1.35 || true
            popd || return 1
        }

        build_8_73_1_Texinfo() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf texinfo-7.3 || true
            tar -xf texinfo-7.3.tar.xz || return 1
            pushd texinfo-7.3 || return 1
            ./configure --prefix=/usr
make
make check || { echo "note: build_8_73_1_Texinfo: test suite exited $? (book: failures non-fatal)"; }
make install
make TEXMF=/usr/share/texmf install-tex
pushd /usr/share/info
  rm -v dir
  for f in *
    do install-info $f dir 2>/dev/null
  done
popd
            popd || return 1
            rm -rf texinfo-7.3 || true
            popd || return 1
        }

        build_8_74_1_Vim() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf vim-9.2.1025 || true
            tar -xf vim-9.2.1025.tar.gz || return 1
            pushd vim-9.2.1025 || return 1
            echo '#define SYS_VIMRC_FILE "/etc/vimrc"' >> src/feature.h
./configure --prefix=/usr
make
chown -R tester .
sed '/test_plugin_glvs/d' -i src/testdir/Make_all.mak
su tester -c "TERM=xterm-256color LANG=en_US.UTF-8 make -j1 test" \
   &> vim-test.log || { echo "note: build_8_74_1_Vim: test suite exited $? (book: failures non-fatal)"; }
make install
ln -sv vim /usr/bin/vi
for L in  /usr/share/man/{,*/}man1/vim.1; do
    ln -sv vim.1 "$(dirname $L)"/vi.1
done
ln -sv ../vim/vim92/doc /usr/share/doc/vim-9.2.1025
            popd || return 1
            rm -rf vim-9.2.1025 || true
            popd || return 1
        }

        build_8_75_1_MarkupSafe() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf markupsafe-3.0.3 || true
            tar -xf markupsafe-3.0.3.tar.gz || return 1
            pushd markupsafe-3.0.3 || return 1
            pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps $PWD
pip3 install --no-index --find-links dist Markupsafe
            popd || return 1
            rm -rf markupsafe-3.0.3 || true
            popd || return 1
        }

        build_8_76_1_Jinja2() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf jinja2-3.1.6 || true
            tar -xf jinja2-3.1.6.tar.gz || return 1
            pushd jinja2-3.1.6 || return 1
            pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps $PWD
pip3 install --no-index --find-links dist Jinja2
            popd || return 1
            rm -rf jinja2-3.1.6 || true
            popd || return 1
        }

        build_8_77_1_systemd() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf systemd-261.2 || true
            tar -xf systemd-261.2.tar.gz || return 1
            pushd systemd-261.2 || return 1
            sed -e 's/GROUP="render"/GROUP="video"/' \
    -e 's/GROUP="sgx", //'               \
    -i rules.d/50-udev-default.rules.in
mkdir -p build
cd       build

meson setup ..                \
      --prefix=/usr           \
      --buildtype=release     \
      -D default-dnssec=no    \
      -D firstboot=false      \
      -D install-tests=false  \
      -D ldconfig=false       \
      -D sysusers=false       \
      -D rpmmacrosdir=no      \
      -D homed=disabled       \
      -D man=disabled         \
      -D mode=release         \
      -D pamconfdir=no        \
      -D dev-kvm-mode=0660    \
      -D nobody-group=nogroup \
      -D sysupdate=disabled   \
      -D ukify=disabled       \
      -D docdir=/usr/share/doc/systemd-261.2
ninja
echo 'NAME="Linux From Scratch"' > /etc/os-release
unshare -m ninja test || { echo "note: build_8_77_1_systemd: test suite exited $? (book: 3 tests known to fail in chroot)"; }
ninja install
tar -xf ../../systemd-man-pages-261.2.tar.xz \
    --no-same-owner --strip-components=1     \
    -C /usr/share/man
systemd-machine-id-setup
systemctl preset-all || true
            popd || return 1
            rm -rf systemd-261.2 || true
            popd || return 1
        }

        build_8_78_1_D_Bus() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf dbus-1.16.2 || true
            tar -xf dbus-1.16.2.tar.xz || return 1
            pushd dbus-1.16.2 || return 1
            mkdir build
cd    build

meson setup --prefix=/usr --buildtype=release --wrap-mode=nofallback ..
ninja
ninja test
ninja install
ln -sfv /etc/machine-id /var/lib/dbus
            popd || return 1
            rm -rf dbus-1.16.2 || true
            popd || return 1
        }

        build_8_79_1_Man_DB() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf man-db-2.13.1 || true
            tar -xf man-db-2.13.1.tar.xz || return 1
            pushd man-db-2.13.1 || return 1
            ./configure --prefix=/usr                         \
            --docdir=/usr/share/doc/man-db-2.13.1 \
            --sysconfdir=/etc                     \
            --disable-setuid                      \
            --enable-cache-owner=bin              \
            --with-browser=/usr/bin/lynx          \
            --with-vgrind=/usr/bin/vgrind         \
            --with-grap=/usr/bin/grap
make
make check || { echo "note: build_8_79_1_Man_DB: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf man-db-2.13.1 || true
            popd || return 1
        }

        build_8_80_1_Procps_ng() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf procps-ng-4.0.7 || true
            tar -xf procps-ng-4.0.7.tar.xz || return 1
            pushd procps-ng-4.0.7 || return 1
            ./configure --prefix=/usr                           \
            --docdir=/usr/share/doc/procps-ng-4.0.7 \
            --disable-static                        \
            --disable-kill                          \
            --enable-watch8bit                      \
            --with-systemd
make
chown -R tester .
su tester -c "PATH=$PATH make check" || { echo "note: build_8_80_1_Procps_ng: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf procps-ng-4.0.7 || true
            popd || return 1
        }

        build_8_81_1_Util_linux() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf util-linux-2.42.2 || true
            tar -xf util-linux-2.42.2.tar.xz || return 1
            pushd util-linux-2.42.2 || return 1
            ./configure --bindir=/usr/bin     \
            --libdir=/usr/lib     \
            --runstatedir=/run    \
            --sbindir=/usr/sbin   \
            --disable-chfn-chsh   \
            --disable-login       \
            --disable-nologin     \
            --disable-su          \
            --disable-setpriv     \
            --disable-runuser     \
            --disable-pylibmount  \
            --disable-liblastlog2 \
            --disable-static      \
            --without-python      \
            ADJTIME_PATH=/var/lib/hwclock/adjtime \
            --docdir=/usr/share/doc/util-linux-2.42.2
make
touch /etc/fstab
chown -R tester .
su tester -c "make -k check" || { echo "note: build_8_81_1_Util_linux: test suite exited $? (book: failures non-fatal)"; }
make install
            popd || return 1
            rm -rf util-linux-2.42.2 || true
            popd || return 1
        }

        build_8_82_1_E2fsprogs() {
            set -e
            local SOURCES_DIR="${SOURCES_DIR:-/mnt/lfs/sources}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf e2fsprogs-1.47.4 || true
            tar -xf e2fsprogs-1.47.4.tar.gz || return 1
            pushd e2fsprogs-1.47.4 || return 1
            mkdir -v build
cd       build
../configure --prefix=/usr       \
             --sysconfdir=/etc   \
             --enable-elf-shlibs \
             --disable-libblkid  \
             --disable-libuuid   \
             --disable-uuidd     \
             --disable-fsck
make
make check || { echo "note: build_8_82_1_E2fsprogs: test suite exited $? (book: failures non-fatal)"; }
make install
rm -fv /usr/lib/{libcom_err,libe2p,libext2fs,libss}.a
gunzip -v /usr/share/info/libext2fs.info.gz
install-info --dir-file=/usr/share/info/dir /usr/share/info/libext2fs.info
makeinfo -o      doc/com_err.info ../lib/et/com_err.texinfo
install -v -m644 doc/com_err.info /usr/share/info
install-info --dir-file=/usr/share/info/dir /usr/share/info/com_err.info
            popd || return 1
            rm -rf e2fsprogs-1.47.4 || true
            popd || return 1
        }

STAGE5=( build_5_2_1_Cross_Binutils build_5_3_1_Cross_GCC build_5_4_1_Linux_API_Headers build_5_5_1_Glibc build_5_6_1_Target_Libstdc )
STAGE6=( build_6_2_1_M4 build_6_3_1_Ncurses build_6_4_1_Bash build_6_5_1_Coreutils build_6_6_1_Diffutils build_6_7_1_File build_6_8_1_Findutils build_6_9_1_Gawk build_6_10_1_Grep build_6_11_1_Gzip build_6_12_1_Make build_6_13_1_Patch build_6_14_1_Sed build_6_15_1_Tar build_6_16_1_Xz build_6_17_1_Binutils build_6_18_1_GCC )
STAGE7=( build_7_7_1_Gettext build_7_8_1_Bison build_7_9_1_Perl build_7_10_1_Zlib build_7_11_1_mpdecimal build_7_12_1_Python build_7_13_1_Texinfo build_7_14_1_Util_linux )
STAGE8=( build_8_3_1_Man_pages build_8_4_1_Iana_Etc build_8_5_1_Glibc build_8_6_1_Zlib build_8_7_1_Bzip2 build_8_8_1_Xz build_8_9_1_Lz4 build_8_10_1_Zstd build_8_11_1_File build_8_12_1_Readline build_8_13_1_Pcre2 build_8_14_1_M4 build_8_15_1_Bc build_8_16_1_Flex build_8_17_1_Tcl build_8_18_1_Expect build_8_19_1_DejaGNU build_8_20_1_Ninja build_8_21_1_Pkgconf build_8_22_1_Binutils build_8_23_1_GMP build_8_24_1_MPFR build_8_25_1_MPC build_8_26_1_Attr build_8_27_1_Acl build_8_28_1_Libcap build_8_29_1_Libxcrypt build_8_30_1_Shadow build_8_31_1_Gawk build_8_32_1_GCC build_8_33_1_Ncurses build_8_34_1_Sed build_8_35_1_Psmisc build_8_36_1_Gettext build_8_37_1_Bison build_8_38_1_Grep build_8_39_1_Bash build_8_40_1_Libtool build_8_41_1_GDBM build_8_42_1_Gperf build_8_43_1_Expat build_8_44_1_Inetutils build_8_45_1_Less build_8_46_1_Perl build_8_47_1_Autoconf build_8_48_1_Automake build_8_49_1_OpenSSL build_8_50_1_Libelf build_8_51_1_Libffi build_8_52_1_Sqlite build_8_53_1_mpdecimal build_8_54_1_Python_3 build_8_55_1_Flit_Core build_8_56_1_Packaging build_8_57_1_Wheel build_8_58_1_Setuptools build_8_59_1_Meson build_8_60_1_Kmod build_8_61_1_Coreutils build_8_62_1_Diffutils build_8_63_1_Findutils build_8_64_1_Groff build_8_65_1_GRUB_for_BIOS build_8_66_1_Gzip build_8_67_1_IPRoute2 build_8_68_1_Kbd build_8_69_1_Libpipeline build_8_70_1_Make build_8_71_1_Patch build_8_72_1_Tar build_8_73_1_Texinfo build_8_74_1_Vim build_8_75_1_MarkupSafe build_8_76_1_Jinja2 build_8_77_1_systemd build_8_78_1_D_Bus build_8_79_1_Man_DB build_8_80_1_Procps_ng build_8_81_1_Util_linux build_8_82_1_E2fsprogs )
declare -A PKG_SRC=(
  [build_5_2_1_Cross_Binutils]=binutils-2.47.tar.xz
  [build_5_3_1_Cross_GCC]=gcc-16.2.0.tar.xz
  [build_5_4_1_Linux_API_Headers]=linux-7.1.8.tar.xz
  [build_5_5_1_Glibc]=glibc-2.44.tar.xz
  [build_5_6_1_Target_Libstdc]=gcc-16.2.0.tar.xz
  [build_6_2_1_M4]=m4-1.4.21.tar.xz
  [build_6_3_1_Ncurses]=ncurses-6.6.tar.gz
  [build_6_4_1_Bash]=bash-5.3.tar.gz
  [build_6_5_1_Coreutils]=coreutils-9.11.tar.xz
  [build_6_6_1_Diffutils]=diffutils-3.12.tar.xz
  [build_6_7_1_File]=file-5.48.tar.gz
  [build_6_8_1_Findutils]=findutils-4.11.0.tar.xz
  [build_6_9_1_Gawk]=gawk-5.4.1.tar.xz
  [build_6_10_1_Grep]=grep-3.12.tar.xz
  [build_6_11_1_Gzip]=gzip-1.14.tar.xz
  [build_6_12_1_Make]=make-4.4.1.tar.gz
  [build_6_13_1_Patch]=patch-2.8.tar.xz
  [build_6_14_1_Sed]=sed-4.10.tar.xz
  [build_6_15_1_Tar]=tar-1.35.tar.xz
  [build_6_16_1_Xz]=xz-5.8.3.tar.xz
  [build_6_17_1_Binutils]=binutils-2.47.tar.xz
  [build_6_18_1_GCC]=gcc-16.2.0.tar.xz
  [build_7_7_1_Gettext]=gettext-1.0.tar.xz
  [build_7_8_1_Bison]=bison-3.8.2.tar.xz
  [build_7_9_1_Perl]=perl-5.44.0.tar.xz
  [build_7_10_1_Zlib]=zlib-1.3.2.tar.gz
  [build_7_11_1_mpdecimal]=mpdecimal-4.0.1.tar.gz
  [build_7_12_1_Python]=Python-3.14.7.tar.xz
  [build_7_13_1_Texinfo]=texinfo-7.3.tar.xz
  [build_7_14_1_Util_linux]=util-linux-2.42.2.tar.xz
  [build_8_3_1_Man_pages]=man-pages-6.18.tar.xz
  [build_8_4_1_Iana_Etc]=iana-etc-20260805.tar.gz
  [build_8_5_1_Glibc]=glibc-2.44.tar.xz
  [build_8_6_1_Zlib]=zlib-1.3.2.tar.gz
  [build_8_7_1_Bzip2]=bzip2-1.0.8.tar.gz
  [build_8_8_1_Xz]=xz-5.8.3.tar.xz
  [build_8_9_1_Lz4]=lz4-1.10.0.tar.gz
  [build_8_10_1_Zstd]=zstd-1.5.7.tar.gz
  [build_8_11_1_File]=file-5.48.tar.gz
  [build_8_12_1_Readline]=readline-8.3.tar.gz
  [build_8_13_1_Pcre2]=pcre2-10.47.tar.bz2
  [build_8_14_1_M4]=m4-1.4.21.tar.xz
  [build_8_15_1_Bc]=bc-7.0.3.tar.xz
  [build_8_16_1_Flex]=flex-2.6.4.tar.gz
  [build_8_17_1_Tcl]=tcl8.6.18-src.tar.gz
  [build_8_18_1_Expect]=expect5.45.4.tar.gz
  [build_8_19_1_DejaGNU]=dejagnu-1.6.3.tar.gz
  [build_8_20_1_Ninja]=ninja-1.13.2.tar.gz
  [build_8_21_1_Pkgconf]=pkgconf-3.0.5.tar.xz
  [build_8_22_1_Binutils]=binutils-2.47.tar.xz
  [build_8_23_1_GMP]=gmp-6.3.0.tar.xz
  [build_8_24_1_MPFR]=mpfr-4.2.2.tar.xz
  [build_8_25_1_MPC]=mpc-1.4.1.tar.xz
  [build_8_26_1_Attr]=attr-2.6.0.tar.gz
  [build_8_27_1_Acl]=acl-2.4.0.tar.xz
  [build_8_28_1_Libcap]=libcap-2.78.tar.xz
  [build_8_29_1_Libxcrypt]=libxcrypt-4.5.2.tar.xz
  [build_8_30_1_Shadow]=shadow-4.20.2.tar.xz
  [build_8_31_1_Gawk]=gawk-5.4.1.tar.xz
  [build_8_32_1_GCC]=gcc-16.2.0.tar.xz
  [build_8_33_1_Ncurses]=ncurses-6.6.tar.gz
  [build_8_34_1_Sed]=sed-4.10.tar.xz
  [build_8_35_1_Psmisc]=psmisc-23.7.tar.xz
  [build_8_36_1_Gettext]=gettext-1.0.tar.xz
  [build_8_37_1_Bison]=bison-3.8.2.tar.xz
  [build_8_38_1_Grep]=grep-3.12.tar.xz
  [build_8_39_1_Bash]=bash-5.3.tar.gz
  [build_8_40_1_Libtool]=libtool-2.6.2.tar.xz
  [build_8_41_1_GDBM]=gdbm-1.26.tar.gz
  [build_8_42_1_Gperf]=gperf-3.3.tar.gz
  [build_8_43_1_Expat]=expat-2.8.3.tar.xz
  [build_8_44_1_Inetutils]=inetutils-2.8.tar.gz
  [build_8_45_1_Less]=less-704.tar.gz
  [build_8_46_1_Perl]=perl-5.44.0.tar.xz
  [build_8_47_1_Autoconf]=autoconf-2.73.tar.xz
  [build_8_48_1_Automake]=automake-1.18.1.tar.xz
  [build_8_49_1_OpenSSL]=openssl-4.0.1.tar.gz
  [build_8_50_1_Libelf]=elfutils-0.195.tar.bz2
  [build_8_51_1_Libffi]=libffi-3.8.0.tar.gz
  [build_8_52_1_Sqlite]=sqlite-autoconf-3530400.tar.gz
  [build_8_53_1_mpdecimal]=mpdecimal-4.0.1.tar.gz
  [build_8_54_1_Python_3]=Python-3.14.7.tar.xz
  [build_8_55_1_Flit_Core]=flit_core-4.0.2.tar.gz
  [build_8_56_1_Packaging]=packaging-26.3.tar.gz
  [build_8_57_1_Wheel]=wheel-0.48.0.tar.gz
  [build_8_58_1_Setuptools]=setuptools-84.0.0.tar.gz
  [build_8_59_1_Meson]=meson-1.12.0.tar.gz
  [build_8_60_1_Kmod]=kmod-34.2.tar.xz
  [build_8_61_1_Coreutils]=coreutils-9.11.tar.xz
  [build_8_62_1_Diffutils]=diffutils-3.12.tar.xz
  [build_8_63_1_Findutils]=findutils-4.11.0.tar.xz
  [build_8_64_1_Groff]=groff-1.24.1.tar.gz
  [build_8_65_1_GRUB_for_BIOS]=grub-2.14.tar.xz
  [build_8_66_1_Gzip]=gzip-1.14.tar.xz
  [build_8_67_1_IPRoute2]=iproute2-7.1.0.tar.xz
  [build_8_68_1_Kbd]=kbd-2.10.0.tar.xz
  [build_8_69_1_Libpipeline]=libpipeline-1.5.8.tar.gz
  [build_8_70_1_Make]=make-4.4.1.tar.gz
  [build_8_71_1_Patch]=patch-2.8.tar.xz
  [build_8_72_1_Tar]=tar-1.35.tar.xz
  [build_8_73_1_Texinfo]=texinfo-7.3.tar.xz
  [build_8_74_1_Vim]=vim-9.2.1025.tar.gz
  [build_8_75_1_MarkupSafe]=markupsafe-3.0.3.tar.gz
  [build_8_76_1_Jinja2]=jinja2-3.1.6.tar.gz
  [build_8_77_1_systemd]=systemd-261.2.tar.gz
  [build_8_78_1_D_Bus]=dbus-1.16.2.tar.xz
  [build_8_79_1_Man_DB]=man-db-2.13.1.tar.xz
  [build_8_80_1_Procps_ng]=procps-ng-4.0.7.tar.xz
  [build_8_81_1_Util_linux]=util-linux-2.42.2.tar.xz
  [build_8_82_1_E2fsprogs]=e2fsprogs-1.47.4.tar.gz
)

# ---8<--- BOOK_FUNCS_END

# book_emit -- print the book's build functions and stage lists on stdout.
#
# Sent to the chapter 5-6 children and to the chapter 7-8 chroot entries, all
# of which start with `env -i` and have no way to reach this file themselves.
# stdout rather than a variable on purpose: a 90 KB variable is copied on every
# expansion, a pipe is not.
book_emit() {
    sed -n '/^# ---8<--- BOOK_FUNCS_BEGIN$/,/^# ---8<--- BOOK_FUNCS_END$/p' "$LFS_SELF" \
        | sed '1d;$d'
}

# book_function NAME -- print the one named build function, or nothing.
#
# The closing `done` flag rather than awk's `exit`: exiting early closes the
# pipe, book_emit's sed takes SIGPIPE, and under `set -o pipefail` the function
# returns 141 instead of 0 about one run in fifteen. Reading to EOF costs
# nothing here (the section is 2400 lines) and makes the status deterministic.
book_function() {
    local want="$1"
    book_emit | awk -v fn="        ${want}() {" '
        $0 == fn { inside = 1; depth = 0 }
        inside && !done {
            n = gsub(/\{/, "{"); m = gsub(/\}/, "}")
            depth += n - m
            print
            if (n > 0) started = 1
            if (started && depth == 0) done = 1
        }'
}

# task_build_one FUNC -- run one book build function inside the chroot.
#
# Reached as `--internal build-one <name>` from build_stage_06 and
# build_stage_07. The name is checked against the functions actually in this
# file rather than trusted: it arrives from a STAGE* array one shell away from
# the definition of those arrays, and eval'ing a name that turned out to be
# junk would be a very poor first surprise inside a chroot.
task_build_one() {
    local fn="$1"
    [ -n "$fn" ] || { echo "build-one: no function name given" >&2; return 2; }
    case "$fn" in
        build_[0-9]*_*_*)
            declare -F "$fn" >/dev/null || {
                echo "build-one: no such build function: $fn" >&2
                return 1
            }
            ;;
        *)
            echo "build-one: refusing to run a non-build function: $fn" >&2
            return 2
            ;;
    esac
    "$fn"
}


# Fetch and verify every LFS 13.1-systemd source. Runs on the host, in stage 02.
task_fetch_sources() {
    local LFS="${LFS:-/mnt/lfs}"
    local BASE="${LFS_DOWNLOAD_BASE:-https://www.linuxfromscratch.org/lfs/downloads/13.1-systemd}"
    local JOBS="${LFS_FETCH_JOBS:-8}"
    mkdir -p "$LFS/sources"
    cd "$LFS/sources"
    curl -fsSL "$BASE/wget-list" -o wget-list
    curl -fsSL "$BASE/md5sums" -o md5sums
    # Fetch only what we can verify. Upstream's wget-list names a handful of
    # files that have no md5sums entry (lfs-bootscripts among them, and that one
    # 404s); nothing in this script consumes them, so requesting them every run
    # just burns round trips and prints "optional extra" noise.
    awk 'NR==FNR { md5[$2]=1; next }
         { f=$0; sub(/.*\//,"",f); if (f in md5) print }' md5sums wget-list > wget-list.need
    local failed_required=""
    # Each fetch runs in its own subshell; failures are written to a marker file
    # in a temp dir so we can aggregate them after all workers finish.
    local FETCH_TMP
    FETCH_TMP=$(mktemp -d)
    # xargs -P: parallel fetches. Failure aggregation avoids aborting on the
    # first bad file.
    # The single-quoted script is expanded by the child sh, not this shell, so
    # its $1/$2/$3 and $(...) are deliberate.
    # shellcheck disable=SC2016
    xargs -a wget-list.need -P "$JOBS" -I{} sh -c '
        url="$1"; fetch_tmp="$2"; md5path="$3"
        [ -n "$url" ] || exit 0
        f="${url##*/}"
        if [ -f "$f" ] && md5sum -c <(grep -F "  $f" "$md5path") >/dev/null 2>&1; then
            echo "OK   cached: $f"
            exit 0
        fi
        echo "GET  $f"
        errf="$fetch_tmp/.$f.curlerr"
        if ! curl -fL --retry 8 --retry-delay 3 --retry-max-time 300 \
                 --retry-all-errors "$url" -o "$f" 2>"$errf"; then
            msg=$(tr "\n" " " < "$errf" | tail -c 200)
            rm -f "$errf" "$f"
            printf "%s\n" "$f" > "$fetch_tmp/FAIL.$f"
            echo "  curl failed: $msg" >&2
            exit 1
        fi
        rm -f "$errf"
        exit 0
    ' _ {} "$FETCH_TMP" md5sums || true
    # Read failure markers
    if [ -n "$(find "$FETCH_TMP" -name 'FAIL.*' 2>/dev/null)" ]; then
        for m in "$FETCH_TMP"/FAIL.*; do
            [ -f "$m" ] || continue
            failed_required="$failed_required $(cat "$m")"
            rm -f "$m"
        done
    fi
    rmdir "$FETCH_TMP" 2>/dev/null || true
    if [ -n "$failed_required" ]; then
        echo "FATAL: required source unavailable:$failed_required" >&2
        return 1
    fi
    # One pass serves both the gate and the count. Running it twice re-read the
    # whole source set merely to count the ": OK" lines the first run printed.
    local md5out
    md5out=$(md5sum -c md5sums) || return 1
    chmod -R a+rX "$LFS/sources"
    printf '%s\n' "$md5out"
    echo "SOURCES-OK $(find "$LFS/sources" -type f | wc -l) entries, $(printf '%s\n' "$md5out" | grep -c ': OK$') verified"
    return 0
}


# ===========================================================================
# In-chroot tasks
# ===========================================================================
#
# Each of these runs INSIDE the built system, invoked as
#     installer.sh --internal <name>
# by build_stage_* above, after this file has copied itself to
# /root/installer.sh in the target. They are functions rather than separate
# files for the same reason everything else here is: one file to move around.
# They print directly instead of using say/warn, because the chroot has no
# /var/log and no host logging context.

# book 7.5 / 7.6: essential directories and files.
task_chroot_prep() {
    mkdir -pv /{boot,home,mnt,opt,srv}
    mkdir -pv /etc/{opt,sysconfig}
    mkdir -pv /lib/firmware
    mkdir -pv /media/{floppy,cdrom}
    mkdir -pv /usr/{,local/}{include,src}
    mkdir -pv /usr/lib/locale
    mkdir -pv /usr/local/{bin,lib,sbin}
    mkdir -pv /usr/{,local/}share/{color,dict,doc,info,locale,man}
    mkdir -pv /usr/{,local/}share/{misc,terminfo,zoneinfo}
    mkdir -pv /usr/{,local/}share/man/man{1..8}
    mkdir -pv /var/{cache,local,log,mail,opt,spool}
    mkdir -pv /var/lib/{color,misc,locate}

    ln -sfv /run /var/run
    ln -sfv /run/lock /var/lock

    install -dv -m 0750 /root
    install -dv -m 1777 /tmp /var/tmp

    ln -sv /proc/self/mounts /etc/mtab

    cat > /etc/hosts << EOF
127.0.0.1  localhost $(hostname)
::1        localhost
EOF

    cat > /etc/passwd << "EOF"
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
systemd-journal-gateway:x:73:73:systemd Journal Gateway:/:/usr/bin/false
systemd-journal-remote:x:74:74:systemd Journal Remote:/:/usr/bin/false
systemd-journal-upload:x:75:75:systemd Journal Upload:/:/usr/bin/false
systemd-network:x:76:76:systemd Network Management:/:/usr/bin/false
systemd-resolve:x:77:77:systemd Resolver:/:/usr/bin/false
systemd-timesync:x:78:78:systemd Time Synchronization:/:/usr/bin/false
systemd-coredump:x:79:79:systemd Core Dumper:/:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/usr/bin/false
systemd-oom:x:81:81:systemd Out Of Memory Daemon:/:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOF

    cat > /etc/group << "EOF"
root:x:0:
bin:x:1:daemon
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:
video:x:12:
utmp:x:13:
clock:x:14:
cdrom:x:15:
adm:x:16:
messagebus:x:18:
systemd-journal:x:23:
input:x:24:
mail:x:34:
kvm:x:61:
systemd-journal-gateway:x:73:
systemd-journal-remote:x:74:
systemd-journal-upload:x:75:
systemd-network:x:76:
systemd-resolve:x:77:
systemd-timesync:x:78:
systemd-coredump:x:79:
uuidd:x:80:
systemd-oom:x:81:
wheel:x:97:
users:x:999:
nogroup:x:65534:
EOF

    echo "tester:x:101:101::/home/tester:/bin/bash" >> /etc/passwd
    echo "tester:x:101:" >> /etc/group
    install -o tester -d /home/tester

    touch /var/log/{btmp,lastlog,faillog,wtmp}
    chgrp -v utmp /var/log/lastlog
    chmod -v 664  /var/log/lastlog
    chmod -v 600  /var/log/btmp
}

# book 8.84 Stripping + 8.85 Cleaning Up.
task_strip_ch8() {
    save_usrlib="$(cd /usr/lib; ls ld-linux*[^g])
             libc.so.6
             libthread_db.so.1
             libquadmath.so.0.0.0
             libstdc++.so.6.0.36
             libitm.so.1.0.0
             libatomic.so.1.2.0"

    cd /usr/lib

    for LIB in $save_usrlib; do
        objcopy --only-keep-debug --compress-debug-sections=zstd "$LIB" "$LIB.dbg"
        cp "$LIB" "/tmp/$LIB"
        strip --strip-unneeded "/tmp/$LIB"
        objcopy --add-gnu-debuglink="$LIB.dbg" "/tmp/$LIB"
        install -vm755 "/tmp/$LIB" /usr/lib
        rm "/tmp/$LIB"
    done

    online_usrbin="bash find strip"
    online_usrlib="libbfd-2.47.20260726.so
               libsframe.so.3.0.0
               libhistory.so.8.3
               libncursesw.so.6.6
               libm.so.6
               libreadline.so.8.3
               libz.so.1.3.2
               libzstd.so.1.5.7
               $(cd /usr/lib; find libnss*.so* -type f)"

    for BIN in $online_usrbin; do
        cp "/usr/bin/$BIN" "/tmp/$BIN"
        strip --strip-unneeded "/tmp/$BIN"
        install -vm755 "/tmp/$BIN" /usr/bin
        rm "/tmp/$BIN"
    done

    for LIB in $online_usrlib; do
        cp "/usr/lib/$LIB" "/tmp/$LIB"
        strip --strip-unneeded "/tmp/$LIB"
        install -vm755 "/tmp/$LIB" /usr/lib
        rm "/tmp/$LIB"
    done

    # Single-quoted so find receives the glob unexpanded. The $(find ...) itself
    # stays unquoted on purpose: this is a word list for `for`, so splitting is
    # the point. Paths under /usr/lib carry no spaces, which is what makes that
    # safe rather than merely convenient.
    for i in $(find /usr/lib -type f -name '*.so*' ! -name '*dbg') \
             $(find /usr/lib -type f -name '*.a')                 \
             $(find /usr/{bin,sbin,libexec} -type f); do
        # Unquoted on purpose: this arm is a glob pattern matched against the
        # word list. Quoting $(basename "$i") would make it a literal string and
        # the arm would never fire, so every file would fall through to `*` and
        # be stripped regardless of whether it was already saved.
        # shellcheck disable=SC2086
        case "$online_usrbin $online_usrlib $save_usrlib" in
            *$(basename $i)* )
                ;;
            * )
                # The book's loop is written for an interactive shell, where a
                # per-file `strip` failure just prints "file format not
                # recognized" and the loop moves on. Under `set -e` that same
                # failure is fatal, and `find` turns up plenty of non-ELF files:
                # shell/perl scripts, GNU ld scripts, .la files, plain text.
                # `strip` cannot do anything useful with those, so check the
                # ELF magic and skip them -- the book's intent is to strip ELF
                # binaries, and a genuine strip failure on a real binary stays
                # fatal. read -N 4 avoids a subprocess per file.
                if read -N 4 -r _magic < "$i" 2>/dev/null && [[ "$_magic" == $'\x7fELF' ]]; then
                    strip --strip-unneeded "$i"
                fi
                ;;
        esac
    done

    unset _magic

    unset BIN LIB save_usrlib online_usrbin online_usrlib
    rm -rf /tmp/{*,.*}
    find /usr/lib /usr/libexec -name \*.la -delete
    # -exec rather than `| xargs rm -rf`: xargs splits on whitespace, so a
    # path containing a space would reach rm as two arguments -- one real, one
    # not -- and rm would then be asked to delete something unintended.
    find /usr -depth -name "$(uname -m)"-lfs-linux-gnu\* -exec rm -rf {} +
    # Book 8.85's cleanup is not re-entrant. A resume that reaches this task
    # again finds `tester` already deleted, `userdel` exits 1, and under `set
    # -e` the ch8 stage dies on its very last command -- so the stage a resume
    # exists in order to retry can never be retried, and the operator is stuck
    # re-diagnosing a completed build. Checked rather than `|| true`, because
    # the end state the book wants is "no tester": a userdel that fails for
    # any other reason (a live process, say) stays fatal.
    if id tester >/dev/null 2>&1; then
        userdel -r tester
    fi
}

# Chapter 9 plus book 8.5.2: glibc config, networkd, hostname, locale, clock.
task_sysconfig() {
    mkdir -p /etc/systemd/network /etc/ld.so.conf.d /boot

    cat > /etc/nsswitch.conf << "EOF"
# Begin /etc/nsswitch.conf

passwd: files systemd
group: files systemd
shadow: files systemd

hosts: mymachines resolve [!UNAVAIL=return] files myhostname dns
networks: files

protocols: files
services: files
ethers: files
rpc: files

# End /etc/nsswitch.conf
EOF

    # The book writes this file as two successive `cat >>` blocks. Written as one
    # `cat >` with the same final contents: a re-run must not append a second
    # copy of the include line (this stage is not checkpointed, so a retry
    # after a later failure re-executes this whole task).
    cat > /etc/ld.so.conf << "EOF"
# Begin /etc/ld.so.conf
/usr/local/lib
/opt/lib

# Add an include directory
include /etc/ld.so.conf.d/*.conf

EOF
    mkdir -pv /etc/ld.so.conf.d

    # zoneinfo from tzdata (book 8.5.2.2). zic comes from the glibc build that
    # already ran in chapter 8, so this is safe to run at chapter 9.
    # The book runs `tar -xf ../../tzdata2026c.tar.gz` with NO cd into a
    # versioned subdirectory: the IANA tarball is flat (calendars, CONTRIBUTING,
    # africa, ...), so cd'ing into a tzdata2026c/ dir fails with "No such file
    # or directory". Extract into a dedicated build dir so /sources stays clean
    # for the later find/strip cleanup, and run zic from there as the book does.
    mkdir -p /sources/tzdata-build
    cd /sources/tzdata-build
    rm -rf ./* 2>/dev/null || true
    tar -xf /sources/tzdata2026c.tar.gz
    ZONEINFO=/usr/share/zoneinfo
    mkdir -pv $ZONEINFO/{posix,right}
    for tz in etcetera southamerica northamerica europe africa antarctica  \
              asia australasia backward; do
        zic -L /dev/null   -d $ZONEINFO       ${tz}
        zic -L /dev/null   -d $ZONEINFO/posix ${tz}
        zic -L leapseconds -d $ZONEINFO/right ${tz}
    done
    cp -v zone.tab zone1970.tab iso3166.tab $ZONEINFO
    zic -d $ZONEINFO -p America/New_York
    unset ZONEINFO tz
    cd /sources && rm -rf tzdata-build

    cat > /etc/systemd/network/10-dhcp-ether.network <<'EOF'
[Match]
Type=ether

[Network]
DHCP=yes
EOF
    cat > /etc/hostname <<'EOF'
lfs
EOF
    # The chapter 8 systemd test step left /etc/os-release as the single line
    # NAME="Linux From Scratch" (book 8.77.1, purely so `ninja test` has
    # something to read). That is not a valid os-release for identification
    # tools: neofetch falls back to `uname -m` and reports "OS: x86_64" instead
    # of the system. Complete it.
    cat > /etc/os-release <<'EOF'
NAME="Linux From Scratch"
ID=lfs
VERSION="13.1-systemd"
PRETTY_NAME="Linux From Scratch 13.1-systemd"
HOME_URL="https://linuxfromscratch.org/"
EOF
    cat > /etc/locale.conf <<'EOF'
LANG=en_US.UTF-8
EOF
    ln -sfv /usr/share/zoneinfo/UTC /etc/localtime
    localedef -i en_US -f UTF-8 en_US.UTF-8
    systemd-machine-id-setup
    systemctl preset-all --preset-mode=enable-only 2>/dev/null || true
    systemctl enable systemd-networkd.service systemd-resolved.service \
                  serial-getty@ttyS0.service
    echo 'root:lfs' | chpasswd
}

# Build the kernel.
task_kernel() {
    mkdir -p /boot
    cd /sources
    rm -rf linux-7.1.8
    tar -xf linux-7.1.8.tar.xz
    cd linux-7.1.8
    make defconfig
    ./scripts/config \
      --enable VIRTIO_PCI --enable VIRTIO_BLK --enable VIRTIO_NET \
      --enable EXT4_FS --enable SERIAL_8250 --enable SERIAL_8250_CONSOLE \
      --enable DEVTMPFS --enable DEVTMPFS_MOUNT --enable IKCONFIG \
      --enable IKCONFIG_PROC --enable CGROUPS --enable PROC_FS \
      --enable SYSFS --enable NET --enable INET --enable E1000 --enable 8139CP \
      --enable SCSI_VIRTIO --enable BLK_DEV_INITRD
    make olddefconfig
    make -j"$(lfs_job_count)" bzImage modules
    make modules_install
    cp .config /boot/config-7.1.8
    cp arch/x86/boot/bzImage /boot/vmlinuz-7.1.8
    cp System.map /boot/System.map-7.1.8
}

# fstab + GRUB install, so the built system can boot on its own.
task_bootable() {
    : "${LFS_ROOT_DEV:?LFS_ROOT_DEV must name the LFS root partition}"
    : "${LFS_ROOT_UUID:?LFS_ROOT_UUID must be the UUID of $LFS_ROOT_DEV}"
    : "${LFS_ROOT_PARTUUID:?LFS_ROOT_PARTUUID must be the PARTUUID of $LFS_ROOT_DEV}"
    : "${LFS_FIRMWARE:=bios}"

    # Root is keyed on the UUID rather than the device path. virtio device names
    # are assigned by enumeration order, so /dev/vdc1 on this boot can be
    # /dev/vdb1 after a reboot with a disk added; a UUID-based fstab survives
    # that, a path-based one silently boots the wrong thing or lands in an
    # emergency shell.
    mkdir -p /boot
    cat > /etc/fstab <<EOF
# file system                  mount point  type  options            dump pass
UUID=$LFS_ROOT_UUID              /            ext4  defaults           1 1
proc                           /proc        proc  nosuid,noexec,nodev 0 0
sysfs                          /sys         sysfs nosuid,noexec,nodev 0 0
devpts                         /dev/pts     devpts gid=5,mode=0620     0 0
tmpfs                          /run         tmpfs defaults             0 0
tmpfs                          /tmp         tmpfs defaults             0 0
EOF

    # Under UEFI the installed system owns an ESP, and it must come back at boot
    # or the firmware entry points at a filesystem nobody mounted, and a later
    # grub-install has nowhere to write. Keyed on the ESP's UUID for the same
    # disk-order reason as root: /dev/vdb1 today can be /dev/vdc1 tomorrow.
    if [ "$LFS_FIRMWARE" = uefi ]; then
        : "${LFS_ESP_UUID:?LFS_ESP_UUID must be the UUID of the EFI System Partition}"
        mkdir -p /boot/efi
        printf 'UUID=%s              /boot/efi    vfat  umask=0077         0 2\n' \
            "$LFS_ESP_UUID" >> /etc/fstab
    fi

    # Serial console. A VM driven over `virsh console` (ttyS0) emits nothing at
    # all without console= on the kernel command line -- neither GRUB nor any
    # kernel message reaches the wire.
    #
    # tty0 is listed first so the VGA console keeps working; ttyS0 last, i.e.
    # primary. GRUB_SERIAL_COMMAND must be set BEFORE grub-install: the serial
    # terminal is embedded into core.img at install time, so a later
    # grub-mkconfig alone cannot add it.
    #
    # /etc/default does not exist on a book-built LFS system (nothing in
    # chapters 1-9 creates it, and grub-mkconfig copes without it), so the
    # directory is made first -- without it the stage would abort.
    mkdir -p /etc/default
    # GRUB_CMDLINE_LINUX deliberately carries ONLY the console= settings. The
    # 10_linux probe already prepends "root=${GRUB_DEVICE} ro", so setting
    # root= here too would give two independent sources for the root device
    # that can silently drift apart. Let the probe own root=; we own the
    # consoles.
    cat > /etc/default/grub <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Linux From Scratch"
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8"
GRUB_TERMINAL="serial console"
GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1"
EOF

    case "$LFS_FIRMWARE" in
        bios)
            # BIOS needs the bootloader on the whole disk, not the partition.
            : "${LFS_BOOT_DISK:?LFS_BOOT_DISK must name the disk to install GRUB to}"
            grub-install --target=i386-pc "$LFS_BOOT_DISK"
            ;;
        uefi)
            # Under UEFI the host firmware owns the boot path, and the installer
            # adds an EFI entry for the built kernel. Installing a BIOS GRUB
            # here would be wrong, and re-running grub-install for the ESP would
            # fight with that entry. The ESP must be mounted inside the chroot
            # for GRUB to see it; the caller is responsible for that.
            : "${LFS_ESP_MOUNT:?LFS_ESP_MOUNT must name the ESP mounted inside the chroot}"
            grub-install --target="$(uname -m)-efi" --efi-directory="$LFS_ESP_MOUNT" \
                --bootloader-id="${LFS_BOOT_ID:-LFS}" --no-nvram
            # The removable fallback: EFI/BOOT/BOOTX64.EFI, the path firmware
            # boots with no NVRAM entry at all. Without it the disk works only on
            # the machine that installed it -- move it, reset CMOS, or install
            # under a firmware that ignores efibootmgr, and there is nothing to
            # boot. A fresh UEFI disk has to be self-booting.
            grub-install --target="$(uname -m)-efi" --efi-directory="$LFS_ESP_MOUNT" \
                --removable --no-nvram
            ;;
        *) echo "unknown LFS_FIRMWARE: $LFS_FIRMWARE" >&2; return 1 ;;
    esac

    grub-mkconfig -o /boot/grub/grub.cfg

    # The kernel command line gets root= from grub-mkconfig, and left alone it
    # writes the DEVICE PATH: /etc/grub.d/10_linux only falls through to a
    # filesystem or partition identifier when it can resolve one where
    # grub-mkconfig runs, and a chroot without udev cannot. Measured on the
    # target with /dev/disk/by-uuid hand-created: still the device path. That
    # silently undoes the reasoning the fstab above is built on -- a disk that
    # enumerates as /dev/vdb on the build host is /dev/vda the moment it is the
    # only disk, and root=/dev/vdb2 then finds nothing and panics.
    #
    # Rewritten to PARTUUID=, not UUID=. Both are equally immune to renumbering,
    # but this kernel will not resolve a filesystem UUID at root-mount time:
    # booted with root=UUID=<the real UUID, confirmed by blkid inside the guest>
    # it panics with "VFS: Cannot open root device", never opening the
    # superblock, while the same kernel with root=PARTUUID= mounts and reaches
    # a login prompt. So the identifier that is verifiably bootable is the one
    # written here, and the fstab keeps the filesystem UUID because systemd
    # mounts the root by the same superblock read that works from userspace.
    local rootpart="${LFS_ROOT_DEV#/dev/}"
    sed -i "s|root=/dev/$rootpart\b|root=PARTUUID=$LFS_ROOT_PARTUUID|g" /boot/grub/grub.cfg

    # A device path here is survivable on the machine that built it and fatal on
    # the next one, and a UUID would panic on every boot, so neither is allowed
    # to ship silently.
    if grep -qE '^[[:space:]]*linux[[:space:]].*root=(/dev/|UUID=)' /boot/grub/grub.cfg; then
        echo "grub.cfg does not boot by PARTUUID; a device path dies when the" \
             "disk is moved and a filesystem UUID is not resolvable by this" \
             "kernel at root-mount time" >&2
        grep -E '^[[:space:]]*linux[[:space:]].*root=' /boot/grub/grub.cfg >&2
        return 1
    fi
}


# ===========================================================================
# Main
# ===========================================================================

lfs_usage() {
    cat <<'EOF'
usage: installer.sh [--target DEV] [options]

Target:
  --target DEV        the disk or partition to install LFS onto, e.g. /dev/vdb
                      or /dev/vdb1. Optional: with no --target this looks for
                      exactly one unused disk and uses it. If it finds none, or
                      more than one, it prints the candidates and stops rather
                      than guessing. Nothing is ever inferred silently.

Options:
  --mode MODE           takeover (default) or side-by-side.
                          takeover:     the target disk becomes LFS and the
                            machine boots into it. Erases the whole disk.
                          side-by-side: keep the current OS bootable. LFS is
                            added as a GRUB menuentry or UEFI entry, and an
                            existing partition table is never touched. The
                            target partition must be on a GPT disk.
  --firmware MODE       auto (default), bios, or uefi. auto detects from
                        /sys/firmware/efi. Override for a VM whose firmware
                        does not advertise itself correctly.
  --plan                print every command that would run, change nothing.
  --resume              keep completed build stages and continue where it
                        stopped. Without this, stage checkpoints are cleared.
  --boot-id NAME        UEFI entry name under EFI/NAME. Default: LFS.
  --yes                 do not ask for the confirmation that otherwise appears
                        before anything irreversible. Needed when there is no
                        terminal (nohup, CI, a piped run) to prompt on.
  -h, --help            this text.

Examples:
  # The one-liner. Needs exactly one unused disk attached. Full install.
  curl -O <repo>/installer.sh && sudo ./installer.sh

  # See exactly what it would do, changing nothing. Always do this first.
  sudo ./installer.sh --plan

  # Keep the current OS, add LFS alongside it:
  sudo ./installer.sh --mode side-by-side

  # Name the disk yourself:
  sudo ./installer.sh --target /dev/vdb

The build takes hours and is checkpointed: if it stops, re-run with --resume.

Logs to $LFS_LOG (default /var/log/installer.log).
EOF
}

lfs_main() {
    # Prefers the environment only so the test suites can drive lfs_main
    # directly with a fixture target; the environment variables below are the
    # documented overrides for unattended runs.
    local TARGET="${LFS_TARGET:-}" MODE="${LFS_MODE:-takeover}" \
           FIRMWARE="${LFS_FIRMWARE_FLAG:-auto}" RESUME="${LFS_RESUME:-0}" _keep

    while [ $# -gt 0 ]; do
        case "$1" in
            --target)   TARGET="${2:-}"; shift ;;
            --mode)     MODE="${2:-}"; shift ;;
            --firmware) FIRMWARE="${2:-}"; shift ;;
            --boot-id)  LFS_BOOT_ID="${2:-}"; shift ;;
            --plan)     LFS_DRY_RUN=1 ;;
            --resume)   RESUME=1 ;;
            --yes)      export LFS_I_UNDERSTAND=yes ;;
            -h|--help)  lfs_usage; return 0 ;;
            *) say "unknown option: $1"; echo; lfs_usage; return 2 ;;
        esac
        shift
    done

    case "$MODE" in
        side-by-side|takeover) ;;
        *) die "--mode must be side-by-side or takeover, got: $MODE" ;;
    esac
    case "$FIRMWARE" in
        auto|bios|uefi) ;;
        *) die "--firmware must be auto, bios or uefi, got: $FIRMWARE" ;;
    esac

    say "=== LFS install ==="

    # Detection runs before anything else, and in particular before a target is
    # chosen or a single package is installed: a host this refuses to touch
    # should be refused before it is told which disk was picked for it.
    lfs_detect_all || return 1
    deps_load || return 1

    say "detected: $LFS_DISTRO_NAME (id=$LFS_DISTRO_RAW version=$LFS_DISTRO_VER)"
    say "          package manager: $LFS_PKGMGR"
    say "firmware: $LFS_FIRMWARE (secure boot: $LFS_SECUREBOOT)"
    lfs_detect_arch
    say "arch:    $LFS_ARCH, target triplet $LFS_TGT"
    say "mode:    $MODE"

    # ------------------------------------------------------------ target
    #
    # Choose the target: whatever was named, or the single unused disk. The
    # refusal lives in target_select so it is unit-tested rather than sitting
    # inline here.
    if ! TARGET=$(target_select "$TARGET"); then
        return 2
    fi
    say "using target=$TARGET"

    if [ "$FIRMWARE" != auto ]; then
        [ "$LFS_FIRMWARE" = "$FIRMWARE" ] \
            || warn "requested --firmware $FIRMWARE but the system reports $LFS_FIRMWARE"
        LFS_FIRMWARE="$FIRMWARE"
    fi

    # A takeover UEFI install writes a GRUB image that this build did not sign.
    # Secure Boot will refuse to execute it, so the disk is left with a boot
    # entry that appears in the menu and then bounces straight back -- a failure
    # that looks like a broken build rather than a firmware policy. Refuse here,
    # before the target is erased, with the two things that actually work. This
    # is checked for --plan too: a plan that cannot be carried out is not a plan.
    #
    # Side-by-side is different and already handled: there the host's signed
    # shim and GRUB stay in place and load the LFS kernel (see
    # boot_install_uefi_secureboot), so it is not refused here.
    if [ "$LFS_FIRMWARE" = uefi ] && [ "$MODE" = takeover ] \
       && [ "$LFS_SECUREBOOT" = enabled ]; then
        die "Secure Boot is enabled, and a freshly built GRUB is unsigned, so this
installation would not boot: firmware would reject the bootloader and drop back
to whatever was there before.

Two things work instead:
  1. Disable Secure Boot in firmware, install, and re-enable it afterwards.
  2. Install with --mode side-by-side, which keeps the host's signed shim and
     GRUB and adds LFS to that menu instead of replacing the boot disk.

The same applies to a machine whose Secure Boot state cannot be read: this
installer refuses only on a definite 'enabled', and warns otherwise."
    fi

    : "${LFS_BOOT_ID:=LFS}"
    export LFS_BOOT_ID

    # Refuse to plan a run that could not work, so --plan is not a false
    # promise: under --plan nothing is actually mounted, so anything that
    # depends on real state is checked here and allowed to fail later in the
    # real run.
    if [ "$LFS_DRY_RUN" = 1 ]; then
        case "$TARGET" in
            /dev/*) ;;
            *) die "--plan still requires an absolute /dev/ target, got: $TARGET" ;;
        esac
    fi

    if [ "$LFS_DRY_RUN" != 1 ] && [ "$(id -u)" != 0 ]; then
        die "must run as root (partitioning, mounting and bootloader changes).
Try: sudo $0 --plan   # to preview first"
    fi

    # ---------------------------------------------------------------- deps
    deps_install || return 1
    if [ "$LFS_DRY_RUN" = 1 ]; then
        # Nothing was actually installed, so missing tools are expected here.
        # A preview must still finish, so check inline instead of calling
        # deps_verify: die() would exit the whole script mid-plan.
        local dtool dmissing=""
        for dtool in gcc g++ make ld as awk sed grep tar xz patch find \
                     mount blkid mkfs.ext4 parted chroot uname python3 curl; do
            command -v "$dtool" >/dev/null 2>&1 || dmissing="$dmissing $dtool"
        done
        if [ -n "$dmissing" ]; then
            say "plan: build tools that would be installed now:$dmissing"
        else
            say "all required build tools present"
        fi
    else
        deps_verify || return 1
    fi

    # The host bootloader layout is discovered on the host, not read from a
    # package table, so this works on a distribution nobody has ever heard of.
    # Only side-by-side needs it: a full install puts GRUB on the target disk
    # itself and never touches the host's menu, so a host with no GRUB at all
    # can still do a full install.
    if [ "$LFS_FIRMWARE" = bios ] && [ "$MODE" = side-by-side ]; then
        boot_detect_grub
        say "host GRUB: dir=$GRUB_CONFIG_DIR drop-in=$GRUB_CUSTOM_FILE regen='$GRUB_REGEN'"
    fi

    # -------------------------------------------------------------- target
    # A resume is announced to everything downstream BEFORE the gate runs, not
    # after: the gate is what refuses a leftover mount from a crashed run, and
    # it has to know this is a resume to explain that case honestly instead of
    # blaming the user for booting from the wrong disk.
    if [ "$RESUME" = 1 ]; then
        export LFS_TARGET_RESUMING=1
    fi

    # The gate runs before anything is written, and under --plan too: a plan
    # that ignored the safety checks would be worse than no plan at all.
    target_safety_gate "$TARGET" "$MODE" || return 1

    # Resolve the target partition first (pure, no side effects), THEN ask,
    # THEN act. target_prepare re-resolves idempotently; splitting them here
    # is what keeps the confirmation prompt ahead of the mkfs instead of behind
    # it.
    target_plan "$TARGET" "$MODE" || return 1
    # The partition that survives a resume is the one already on the disk, not
    # the one a fresh takeover would create. Re-plan around it so the
    # confirmation below is not asking about a partition that will not exist.
    if [ "$RESUME" = 1 ]; then
        if _keep=$(target_prepared_partition "$TARGET") && [ -n "$_keep" ]; then
            TARGET_PART="$_keep"
            TARGET_LABEL="${_keep##*/}"
            export TARGET_PART TARGET_LABEL
        fi
    fi
    if [ "$MODE" = takeover ] && [ "$RESUME" = 1 ] && [ -n "$_keep" ]; then
        # On a resume the disk is NOT erased, so the prompt must not say it is.
        confirm_irreversible "continue the LFS build already on $TARGET_PART"
    elif [ "$MODE" = takeover ]; then
        confirm_irreversible "erase $TARGET and install Linux From Scratch onto $TARGET_PART"
    else
        confirm_irreversible "format $TARGET_PART as ext4 and install Linux From Scratch onto it"
    fi
    target_prepare "$TARGET" "$MODE" || return 1
    target_mount "$TARGET_PART" || return 1

    # LFS is the target's mount point, and lfs_main is the first place in the
    # program that needs it by that name. It is not set anywhere above: each
    # build stage calls lfs_build, which does `: "${LFS:=/mnt/lfs}"` for itself,
    # so the name only ever existed *inside* the build.
    #
    # Which is a trap. Any "$LFS/..." written here before this line silently
    # expands to "/..." -- not an error, not an empty string, just a path on the
    # HOST. The chroot copy of this file was installed with "$LFS/root/..." from
    # this function and landed on the build host's own /root every time, while
    # the copy inside the target stayed stale, so a resumed build kept running
    # the old installer. Nothing warned. Setting it here makes the expansion
    # mean what it reads as, and lfs_build inherits the same value.
    LFS="$LFS_TARGET_MOUNT"

    # Put this file inside the chroot, and do it HERE rather than in the
    # chroot_tools stage where it used to live. Chapters 7-8 cross the chroot
    # boundary by re-running THIS script with --internal, so this copy is the
    # program that builds 80 packages -- and it has to be the copy that was just
    # run, not whatever happened to be there.
    #
    # It was in the stage, and the stage is checkpointed, so --resume skipped it.
    # The result: after a failure you fixed the installer, resumed, and chapter 8
    # cheerfully re-ran the OLD one. That is the exact situation --resume exists
    # for, and it silently defeated it. Unconditional, so every run refreshes it.
    # Under --plan the target was never mounted, so $LFS/root does not exist.
    # Writing the copy is part of the run being described, not part of the
    # preview, so report the command and move on instead of failing on a
    # directory the preview itself never created.
    if [ "$LFS_DRY_RUN" = 1 ]; then
        say "[PLAN ] would install $LFS_SELF into $LFS/root/installer.sh"
    else
        # `install -D` is GNU coreutils; busybox's install has no -D, so the
        # destination directory is created first and plain install is used.
        mkdir -p "$LFS/root" || { echo "mkdir $LFS/root FAILED" >&2; return 1; }
        install -m 0755 "$LFS_SELF" "$LFS/root/installer.sh" \
            || { echo "self->chroot copy FAILED" >&2; return 1; }
    fi

    # Resolve identity of the new filesystem before the build, not after: the
    # bootable stage needs it to write a correct fstab and to install GRUB on
    # the right disk. Reading the UUID after the build meant the build had to
    # guess, and what it guessed was hardcoded.
    local TARGET_UUID ESP="" KVER=""
    if [ "$LFS_DRY_RUN" = 1 ]; then
        # Under --plan the disk was never partitioned, so there is no UUID to
        # read and demanding one would abort the plan over its own inaction. Use
        # a placeholder so the fstab and grub-install commands still render; a
        # real run reads the genuine UUID below.
        TARGET_UUID="00000000-0000-0000-0000-000000000000"
        TARGET_PARTUUID="00000000-0000-0000-0000-000000000000"
        warn "plan: $TARGET_PART was not really formatted, so it has no UUID yet."
        warn "plan: using a placeholder in the commands below."
    else
        TARGET_UUID=$(blkid -s UUID -o value "$TARGET_PART" 2>/dev/null)
        [ -n "$TARGET_UUID" ] || die "could not read the UUID of $TARGET_PART"
        # Read here rather than at the call site: boot_install_bios needs it, and
        # a side-by-side target is not partitioned by this script, so there is no
        # other place that would have it.
        TARGET_PARTUUID=$(blkid -s PARTUUID -o value "$TARGET_PART" 2>/dev/null || true)
        # MBR has no partition UUIDs, and this kernel cannot mount the root by
        # filesystem UUID either (measured: VFS: Cannot open root device), so
        # there is no identifier that survives the host enumerating its disks in
        # a different order. Refusing here, before an hour of compiling, beats a
        # rescue prompt on the next boot. Only side-by-side can reach this: the
        # other modes write a GPT and always have one.
        if [ -z "$TARGET_PARTUUID" ]; then
            die "$TARGET_PART has no PARTUUID, so its partition table is not GPT.
side-by-side installs a boot entry that identifies the root by PARTUUID, because
this kernel cannot mount it by filesystem UUID or by a stable device path.
Re-run with a GPT target partition, or use --mode takeover on a whole disk,
which writes a GPT itself."
        fi
    fi
    # GRUB's BIOS backend installs to a whole disk, so a partition target has to
    # be reduced to its parent. Computed here, on the host, where lsblk is
    # guaranteed to exist and to know the real name -- inside the chroot it is a
    # book-built util-linux that may not be in place yet.
    LFS_BOOT_DISK=$(target_parent_disk "$TARGET_PART")
    export LFS_ROOT_DEV="$TARGET_PART" LFS_ROOT_UUID="$TARGET_UUID" \
           LFS_ROOT_PARTUUID="$TARGET_PARTUUID" LFS_BOOT_DISK

    # --------------------------------------------------------------- build
    say "building LFS 13.1-systemd into $LFS_TARGET_MOUNT (this takes a while)"
    # Under UEFI the chroot needs the ESP mounted so the bootable stage's
    # grub-install can see it. Unmounted again on the way out, whatever happens.
    #
    # A whole-disk takeover owns its ESP -- target_prepare made one and left its
    # device in TARGET_ESP -- so that is mounted. A side-by-side install has no
    # ESP of its own and borrows the host's, which is already mounted somewhere,
    # so that is bind-mounted instead. Either way LFS_ESP_MOUNT is the path
    # *inside the chroot*, which is what the bootable stage hands to grub-install.
    # ESP is the path inside the target, so it is known up front; the
    # non-dry-run branch below only mounts and resolves ESP_DEV. A preview has
    # to report this path too, or it prints "would mount the ESP at ,".
    local ESP="" ESP_DEV=""
    if [ "$LFS_FIRMWARE" = uefi ]; then
        ESP=/boot/efi
    fi
    if [ "$LFS_FIRMWARE" = uefi ] && [ "$LFS_DRY_RUN" != 1 ]; then
        if [ "$MODE" = takeover ] && [ -n "${TARGET_ESP:-}" ]; then
            ESP_DEV="$TARGET_ESP"
            say "mounting the target ESP $ESP_DEV at $ESP for the bootloader install"
            mkdir -p "$LFS_TARGET_MOUNT$ESP"
            run mount "$ESP_DEV" "$LFS_TARGET_MOUNT$ESP" \
                || die "failed to mount $ESP_DEV at $LFS_TARGET_MOUNT$ESP"
        else
            local host_esp
            host_esp=$(boot_find_esp) || die "firmware is UEFI but no ESP is mounted, so the
chroot's grub-install has nowhere to write. Mount the ESP (usually /boot/efi)
and re-run."
            say "binding the host ESP $host_esp into the chroot as $ESP"
            ESP_DEV=$(findmnt -no SOURCE --target "$host_esp" 2>/dev/null || true)
            mkdir -p "$LFS_TARGET_MOUNT$ESP"
            run mount --bind "$host_esp" "$LFS_TARGET_MOUNT$ESP" \
                || die "failed to bind $host_esp into the chroot"
        fi
        export LFS_ESP_MOUNT="$ESP"
        # The fstab entry needs the ESP's UUID, and the bootable stage cannot
        # read it: inside the chroot the ESP is seen through this host mount and
        # the book-built blkid is not there yet. Read it here, where the device
        # node and the tooling are both known.
        if [ -n "$ESP_DEV" ]; then
            LFS_ESP_UUID=$(blkid -s UUID -o value "$ESP_DEV" 2>/dev/null || true)
            [ -n "$LFS_ESP_UUID" ] \
                || die "could not read the UUID of the EFI System Partition $ESP_DEV"
            export LFS_ESP_UUID
        fi
    fi

    local build_args=(--mount "$LFS_TARGET_MOUNT")
    [ "$RESUME" = 1 ] && build_args+=(--resume)

    if [ "$LFS_DRY_RUN" = 1 ]; then
        say "[PLAN ] would run the build (stages: sources, lfsusr, toolchain,"
        say "[PLAN ]  temptools, chroot_tools, ch8, sysconfig, bootable)"
        if [ "$LFS_FIRMWARE" = uefi ]; then
            say "[PLAN ] would mount the ESP at $ESP, install GRUB as"
            say "[PLAN ]  EFI/$LFS_BOOT_ID plus the EFI/BOOT fallback, and add a firmware entry"
        fi
        say "[PLAN ] would then install a bootloader and finish"
    elif ! lfs_build "${build_args[@]}"; then
        [ -n "$ESP" ] && run umount "$LFS_TARGET_MOUNT$ESP"
        target_unmount
        die "LFS build failed. $LFS_TARGET_MOUNT is still mounted.
Fix the cause and re-run with --resume; completed stages are checkpointed in
$LFS_TARGET_MOUNT/.stages"
    fi
    [ -n "$ESP" ] && run umount "$LFS_TARGET_MOUNT$ESP"

    # ----------------------------------------------------------------- boot
    if [ "$MODE" = takeover ]; then
        # The target disk got its own bootloader from the bootable stage. The
        # host's menu is deliberately left alone: a full install replaces the
        # system, it does not add a second one to it.
        # The chroot's grub-install ran with --no-nvram -- the book builds no
        # efibootmgr -- so the firmware boot order is registered here, from the
        # host, where efibootmgr exists. Failure is a warning, not a fatal: the
        # EFI/BOOT fallback the bootable stage also wrote means the disk boots
        # with no NVRAM entry at all.
        if [ "$LFS_FIRMWARE" = uefi ] && [ "$LFS_DRY_RUN" != 1 ] && [ -n "${TARGET_ESP:-}" ]; then
            boot_register_nvram "$TARGET_ESP" || \
                warn "could not register a firmware boot entry for '$LFS_BOOT_ID'; the disk still boots via its EFI/BOOT fallback or the one-time boot menu"
        fi
        say "full install: $LFS_BOOT_DISK now boots LFS on its own"
    else
        if [ "$LFS_DRY_RUN" = 1 ]; then
            KVER="<built kernel version>"
        else
            # `sort -V` is GNU-only -- busybox and BSD sort lack it, and this
            # line decides which kernel the bootloader installs, so it has to
            # work everywhere. Numeric keys on the dot-separated fields give the
            # same answer as `sort -V` (checked against it for 6.12.3/6.9.12,
            # 6.12.10, 5.15.1/6.6.1/6.12.3, x.y.z-lfs and x.y.z.w). `find`
            # rather than `ls` so a name with a space cannot split.
            KVER=$(find "$LFS_TARGET_MOUNT/boot" -maxdepth 1 -name 'vmlinuz-*' \
                       2>/dev/null | sed 's|.*/||; s/^vmlinuz-//' \
                   | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
            [ -n "$KVER" ] || die "no kernel found in $LFS_TARGET_MOUNT/boot after the build"
            say "LFS kernel: $KVER, target UUID: $TARGET_UUID"
        fi
        # The menuentry/UEFI entry is keyed on identifiers rather than the device
        # path, so it keeps working if the disk order changes. boot_grub_menuentry
        # needs both: the filesystem UUID to `search` for the kernel, and the
        # PARTUUID for the kernel's own root=, because this kernel cannot resolve
        # a filesystem UUID at mount time (measured: VFS: Cannot open root device).
        case "$LFS_FIRMWARE" in
            uefi) boot_install_uefi "$TARGET_UUID" "$TARGET_PARTUUID" "$KVER" || return 1 ;;
            bios) boot_install_bios "$TARGET_UUID" "$TARGET_PARTUUID" "$KVER" || return 1 ;;
            *) die "internal error: unknown firmware '$LFS_FIRMWARE'" ;;
        esac
    fi

    target_unmount

    say "=== done ==="
    say "LFS is installed on $TARGET_PART"
    if [ "$MODE" = takeover ]; then
        say "Reboot. $LFS_BOOT_DISK will boot Linux From Scratch."
    elif [ "$LFS_FIRMWARE" = uefi ]; then
        say "Boot it from the firmware menu, entry: $LFS_BOOT_ID"
    else
        say "Boot it from the GRUB menu, entry: Linux From Scratch $KVER"
    fi
    say "Log: $LFS_LOG"
    return 0
}

# lfs_internal TASK -- run an in-chroot task. Not a user-facing entry point.
lfs_internal() {
    case "$1" in
        chroot-prep) task_chroot_prep ;;
        kernel)      task_kernel ;;
        strip-ch8)   task_strip_ch8 ;;
        sysconfig)   task_sysconfig ;;
        bootable)    task_bootable ;;
        build-one)   task_build_one "${2:-}" ;;
        *) echo "unknown internal task: $1" >&2; return 2 ;;
    esac
}

# -------------------------------------------------------------- dispatch
#
# Sourcing this file defines everything and runs nothing, which is what lets
# the test suite exercise individual functions against the real code instead of
# a copy of it. Executing it runs the installer.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --internal)
            shift
            # These run inside the target, where the original scripts each had
            # their own `set -e`. The installer itself does not use -e (it wants
            # to clean up after a failed stage), so the strictness is applied
            # here, only here.
            set -e
            lfs_internal "$@"
            exit $?
            ;;
        --build)
            shift
            lfs_build "$@"
            exit $?
            ;;
    esac
    lfs_main "$@"
    exit $?
fi
