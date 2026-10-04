#!/usr/bin/env python3
"""Assemble the split lfs/ sources into the single installer.sh.

Mechanical on purpose: the lib/ sections and the build stages are spliced in
verbatim, and only the seams (sourcing, cross-process calls, the package
tables) are rewritten.

The book's build functions are GENERATED here, not read from a file, by
importing the same distiller the project used to run by hand. They used to be
emitted to sources/generated-packages.sh and sourced at run time, which meant
the "one file" needed a second file to work. The generated text is identical:
assemble.py asserts the produced text matches the last known-good output.
"""
import re
import subprocess
import sys
import pathlib

REGEN = pathlib.Path(__file__).resolve().parent
ROOT = REGEN.parent
BOOK = ROOT / "book-13.1-nochunks.html"
TOOLS = ROOT / "tools"

# The deliverable's filename, and -- because the script copies itself into the
# target and then re-enters that copy as `bash /root/<name> --internal ...` --
# also the name of the chroot copy. Those two are one fact, so they are one
# constant. assert_script_name_coupled() below fails the build if the literal in
# the shell ever stops matching this, which is the drift that would otherwise
# only show up as "no such file" inside a chroot an hour into a build.
SCRIPT_NAME = "installer.sh"
CHROOT_SELF = "/root/" + SCRIPT_NAME
sys.path.insert(0, str(TOOLS))


def distil_book():
    """Run the project's distiller over the checked-in book HTML."""
    import distill                                     # noqa: E402  (sys.path above)
    import render                                      # noqa: E402
    pkgs = distill.extract_book(BOOK)
    return render.render_all(pkgs)


def read(p):
    return (REGEN / p).read_text()


def assert_script_name_coupled(text):
    """Fail the build if the chroot copy name drifts from the output filename.

    The installer copies itself into the target as /root/<name> and every
    chroot stage re-enters it as `bash /root/<name> --internal <stage>`. The
    name is therefore written twice -- once here in SCRIPT_NAME, once as a
    literal in the shell -- and the two have to agree. If they don't, nothing
    fails until a chroot stage tries to exec a file that isn't there, which is
    an hour or more into a build, on a disposable disk, with a log full of
    unrelated output. Checking it at assembly time costs nothing.
    """
    for needle, why in (
        ('install -m 0755 "$LFS_SELF" "$LFS/root/%s"' % SCRIPT_NAME,
         "self-copy into the target"),
        ('bash %s --internal' % CHROOT_SELF,
         "chroot re-entry path"),
    ):
        if needle not in text:
            raise SystemExit(
                "assemble.py: SCRIPT_NAME is %r but the %s does not match.\n"
                "  expected to find: %s\n"
                "  Rename the literal in the generated shell, or change "
                "SCRIPT_NAME -- they are one fact." % (SCRIPT_NAME, why, needle))
    stray = set(re.findall(r"/root/([A-Za-z0-9_.-]+\.sh) --internal", text))
    if stray and stray != {SCRIPT_NAME}:
        raise SystemExit(
            "assemble.py: chroot stages re-enter %s but SCRIPT_NAME is %r"
            % (sorted(stray), SCRIPT_NAME))


def strip_lib(text, guard):
    """Drop a sourced lib's shebang and its include-once guard.

    In a single file an include-once guard is not merely redundant, it is a
    trap: `return 0` partway through a sourced file silently defines nothing
    after that point, so the SECOND source of the installer would come up with
    only the functions above the first guard. Asserted clean below.
    """
    lines = text.split("\n")
    out = []
    for ln in lines:
        if ln.startswith("#!"):
            continue
        if ln.strip() in ('[ -n "${%s:-}" ] && return 0' % guard,
                          "%s=1" % guard):
            continue
        out.append(ln)
    # collapse the blank-line runs the removals leave behind
    text = "\n".join(out)
    return re.sub(r"\n{3,}", "\n\n", text).strip("\n")


HEADER = r'''#!/usr/bin/env bash
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
'''

PKGMGR = r'''
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
'''

# --- deps.sh: replace file-sourcing with an in-file table lookup -----------
DEPS_OLD = '''    local conf="$LFS_ROOT/pkgmgr/$d.conf"
    [ -f "$conf" ] || die "no dependency table for package manager '$d'
  (expected $conf)
  Available: $(ls -1 "$LFS_ROOT/pkgmgr" 2>/dev/null | sed 's/\\.conf$//' | tr '\\n' ' ')"

    # Clear first: these are global-ish names, and a previous load of a
    # different table would otherwise leave stale values behind for any key
    # this conf happens not to set. PKG_INDEX_CMD is deliberately unset rather
    # than defaulted: a table that omits it means "no refresh step", and
    # defaulting to a previous distro's command would run the wrong one.
    local k
    for k in $DEPS_REQUIRED_KEYS DEPS_PREFLIGHT PKG_INDEX_CMD; do unset "$k"; done
    PKG_INDEX_CMD=""

    # shellcheck source=/dev/null
    . "$conf" || die "failed to load $conf"
'''

DEPS_NEW = '''    local conf="the $d package table"

    # Clear first: these are global-ish names, and a previous load of a
    # different table would otherwise leave stale values behind for any key
    # this table happens not to set. PKG_INDEX_CMD is deliberately unset rather
    # than defaulted: a table that omits it means "no refresh step", and
    # defaulting to a previous table's command would run the wrong one.
    local k
    for k in $DEPS_REQUIRED_KEYS DEPS_PREFLIGHT PKG_INDEX_CMD \\
             PKG_EXTRA_BIOS PKG_EXTRA_UEFI; do unset "$k"; done
    PKG_INDEX_CMD=""
    PKG_EXTRA_BIOS=""
    PKG_EXTRA_UEFI=""

    pkgmgr_table "$d" || die "no package table for '$d'
  Supported: $(lfs_supported_pkgmgr | tr '\\n' ' ')"
'''

deps = strip_lib(read("lib/deps.sh"), "_LFS_DEPS_SH")
assert DEPS_OLD in deps, "deps_load seam not found"
deps = deps.replace(DEPS_OLD, DEPS_NEW)

# deps_install: append the firmware-specific GRUB platform package
OLD_PKGS = '''    local pkglist
    pkglist=$(printf '%s' "$PKGS" | tr '\\n' ' ' | tr -s ' ')
    say "packages: $pkglist"
'''
NEW_PKGS = '''    local pkglist
    pkglist=$(printf '%s' "$PKGS" | tr '\\n' ' ' | tr -s ' ')

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
'''
assert OLD_PKGS in deps, "deps_install seam not found"
deps = deps.replace(OLD_PKGS, NEW_PKGS)
deps = deps.replace(
    "  Install them by hand, or add/fix the package name in that file and re-run --",
    "  Install them by hand, or add/fix the package name in that table and re-run --")

# --- the book's build functions, generated and inlined ------------------------
#
# These used to be written to $LFS/sources/generated-packages.sh and sourced
# from there, which meant this "one file" needed a second file to build
# anything. They are generated below instead, so the ONLY things the file
# still needs are the sources it downloads itself.
BOOKFUNCS = r'''
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
'''

_book_funcs_body = distil_book()

# The generated text carries its own shebang and `set -u`; both are wrong in
# context. A shebang mid-file is a syntax error, and `set -u` would re-enable
# the flag a caller may deliberately have turned off (the test suites do).
# Stripped by shape rather than by exact string, and the result is checked
# below, so a change in the distiller's header cannot quietly land as a
# syntax error 2000 lines into the installer.
_book_lines = _book_funcs_body.split("\n")
assert _book_lines[0].startswith("#!"), "distiller no longer emits a shebang first"
_book_lines = _book_lines[1:]
# Drop the generated-by banner and any `set` line that appears before the first
# function definition; both are prologue, not build content.
_pre = []
while _book_lines and (_book_lines[0].startswith("#") or _book_lines[0].strip() == ""
                       or re.match(r"^set\s", _book_lines[0])):
    _pre.append(_book_lines.pop(0))
assert _book_lines and _book_lines[0].lstrip().startswith("build_"), \
    "book section does not start with a build function; got: %r" % (
        _book_lines[0] if _book_lines else None)
_book_funcs_body = "\n".join(_book_lines)

# Emitted ONCE, between two marker comments. Sourcing this file defines the
# functions; book_emit (below) re-extracts the same marked region for children
# that start with an empty environment and so cannot read it for themselves.
# Emitting it a second time unmarked would define everything twice and add 90 KB
# of pure waste to the file.
n_stages = len(re.findall(r"^STAGE\d=", _book_funcs_body, re.M))
assert n_stages == 4, "expected STAGE5..STAGE8, found %d stage lists" % n_stages
n_funcs = len(re.findall(r"^\s*build_\d+_\d+_\w+\(\) \{", _book_funcs_body, re.M))

# The invariant that matters is not "112 functions" -- it is that every name in
# a stage list has a function. A stage list naming a function that is not there
# makes chapter 5 or 8 fail with "command not found" after the toolchain has
# been built, which is hours in and very hard to read back to this file. The
# count is reported so a suspicious change is visible, but nothing asserts on
# it: the skip list is expected to change when the book changes.
_stage_names = []
for _m in re.finditer(r"^STAGE\d=\(([^)]*)\)", _book_funcs_body, re.M):
    _stage_names.extend(_m.group(1).split())
_defined = set(re.findall(r"^\s*(build_\d+_\d+_\w+)\(\) \{", _book_funcs_body, re.M))
_missing = [n for n in _stage_names if n not in _defined]
assert not _missing, "stage lists name undefined functions: %s" % _missing[:5]
_orphan = sorted(_defined - set(_stage_names))
print("book: %d packages across 4 stages (%d functions, %d not in a stage list)"
      % (len(_stage_names), n_funcs, len(_orphan)))
if _orphan:
    print("      not in a stage list: %s" % " ".join(_orphan))

BOOKFUNCS += r'''
# One function does the work here: book_emit, which reprints the region between
# the two markers. The markers are the only contract between it and the
# generated text, which is why the section is emitted exactly once, delimited,
# and never hand-edited.
# ---8<--- BOOK_FUNCS_BEGIN
'''
BOOKFUNCS += _book_funcs_body
BOOKFUNCS += r'''
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
'''

# --- the build driver, converted from a separate script into functions -----
BUILD = r'''
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
'''

# --- the in-chroot tasks, previously separate scripts ----------------------
TASKS = r'''
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
'''

# --- fetch-sources: runs on the HOST, so it is a plain function ------------
FETCH = r'''
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
'''

# --- main: from bootstrap.sh, with takeover as the default ----------------
MAIN = r'''
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
'''

out = [HEADER]
out.append("\n# ===========================================================================\n"
           "# Logging, confirmation and command execution\n"
           "# ===========================================================================\n\n"
           + strip_lib(read("lib/common.sh"), "_LFS_COMMON_SH"))
out.append(PKGMGR)
out.append("\n# ===========================================================================\n"
           "# Detection\n"
           "# ===========================================================================\n\n"
           + strip_lib(read("lib/detect.sh"), "_LFS_DETECT_SH"))
out.append("\n# ===========================================================================\n"
           "# Dependencies\n"
           "# ===========================================================================\n\n" + deps)
out.append("\n# ===========================================================================\n"
           "# Target selection, safety and preparation\n"
           "# ===========================================================================\n\n"
           + strip_lib(read("lib/target.sh"), "_LFS_TARGET_SH"))
out.append("\n# ===========================================================================\n"
           "# Host bootloader integration\n"
           "# ===========================================================================\n\n"
           + strip_lib(read("lib/boot.sh"), "_LFS_BOOT_SH"))
out.append(BUILD)
out.append(BOOKFUNCS)
out.append(FETCH)
out.append(TASKS)
out.append(MAIN)

text = "\n".join(out)
text = re.sub(r"\n{4,}", "\n\n\n", text)

# No include-once guard may survive the merge. One left in place means a
# second `source installer.sh` -- which is exactly what the test suites and
# anyone poking at a function interactively do -- returns early and silently
# loses every function below it.
leaked = re.findall(r"^_LFS_[A-Z_]+_SH=1$", text, re.M)
assert not leaked, "include-once guards survived the merge: %s" % leaked

# --- the split layout is gone: retarget every reference to it ---------------
#
# Comments and error messages inherited from the lib/ layout still talk about
# "pkgmgr/<name>.conf" and "lfs/lib/boot.sh", which would send a reader looking
# for files that no longer exist. Each entry is asserted, so if a source comment
# is reworded upstream this fails here instead of silently shipping a stale
# pointer.
RETARGET = [
    ("`bootstrap.sh --plan` is trustworthy by construction rather than by everyone\n"
     "# remembering to check the flag.",
     "`installer.sh --plan` is trustworthy by construction rather than by\n"
     "# everyone remembering to check the flag."),

    ("# The package managers we ship a pkgmgr/<name>.conf for. This list -- not a list\n"
     "# of distributions -- is what gates a run.",
     "# The package managers that have a table below. This list -- not a list of\n"
     "# distributions -- is what gates a run."),

    ("  install a toolchain first (gcc, make, and the utilities in\n"
     "  lfs/pkgmgr/ that match your system), or re-run from a full install.\"",
     "  install a toolchain first (gcc, make, and the utilities in the package\n"
     "  table for your system), or re-run from a full install.\""),

    ("  To add one, write lfs/pkgmgr/$LFS_PKGMGR.conf naming its install command and\n"
     "  the packages that provide the build tools, then add it to\n"
     "  LFS_SUPPORTED_PKGMGR in lfs/lib/detect.sh.\"",
     "  To add one, add a branch to pkgmgr_table() above naming its install command\n"
     "  and the packages that provide the build tools, and add its name to\n"
     "  lfs_supported_pkgmgr.\""),

    ("# The triplet must match the one build-lfs.sh uses, because stage 04 gates on",
     "# The triplet must match the one lfs_build uses, because stage 04 gates on"),

    ("# Sourced, not executed. All the package-manager-specific knowledge lives in\n"
     "# pkgmgr/<name>.conf as pure data; this file is the only code that interprets\n"
     "# it. That split is what makes the table testable without booting seven VMs --\n"
     "# see tests/test_pkgmgr.sh.",
     "# Not sourced from anywhere: the package-manager-specific knowledge lives in\n"
     "# pkgmgr_table() above as pure data, and the code below is the only thing\n"
     "# that interprets it. That split is what makes each table testable without\n"
     "# booting seven VMs -- see tests/test_pkgmgr.sh."),

    ("# Populated by deps_load:\n"
     "#   PKG_MGR PKG_INDEX_CMD PKG_INSTALL_TMPL PKGS\n"
     "# Optional in a conf: DEPS_PREFLIGHT (shell snippet run before installing).",
     "# Populated by deps_load:\n"
     "#   PKG_MGR PKG_INDEX_CMD PKG_INSTALL_TMPL PKGS\n"
     "#   PKG_EXTRA_BIOS PKG_EXTRA_UEFI  (cleared by every load, then re-set)\n"
     "# Optional: DEPS_PREFLIGHT (shell snippet run before installing)."),

    ("# nothing to do with the package manager, so boot.sh detects those by looking at",
     "# nothing to do with the package manager, so the code below detects those by\n"
     "# looking at"),

    ("# Keys every pkgmgr/<name>.conf must define. Enforced at load time rather than\n"
     "# trusted, because a missing key surfaces as a confusing failure much later --\n"
     "# e.g. boot.sh referencing an empty config path and silently writing its\n"
     "# drop-in somewhere harmless.",
     "# Keys every package table must define. Enforced at load time rather than\n"
     "# trusted, because a missing key surfaces as a confusing failure much later --\n"
     "# e.g. the GRUB code referencing an empty config path and silently writing its\n"
     "# drop-in somewhere harmless."),

    ("# deps_load [PKGMGR] -- source and validate pkgmgr/PKGMGR.conf.",
     "# deps_load [PKGMGR] -- populate and validate the PKG_* keys for PKGMGR."),

    ("    # non-/dev locations keeps \"lfs-bootstrap.sh --target sdb\" from ever being",
     "    # non-/dev locations keeps \"installer.sh --target sdb\" from ever being"),

    ("# Added by lfs-bootstrap.sh. Delete this file to remove the LFS boot entry.",
     "# Added by installer.sh. Delete this file to remove the LFS boot entry."),

    ("# decision bootstrap.sh makes explicitly, not a side effect of asking.",
     "# decision installer.sh makes explicitly, not a side effect of asking."),

    ("add it to the list in boot_detect_grub (lfs/lib/boot.sh).",
     "add it to the list in boot_detect_grub() above."),

    ("Install the host's GRUB tools, or add the correct command to boot_detect_grub\n"
     "(lfs/lib/boot.sh) if it lives somewhere unusual.",
     "Install the host's GRUB tools, or add the correct command to the layout list in\n"
     "boot_detect_grub() above if it lives somewhere unusual."),

    # ---- deps.sh, where the merge turned "conf" into a file name ----
    ('    [ "$PKG_MGR" = "$d" ] || die "$conf declares PKG_MGR=$PKG_MGR but lives in $d.conf"',
     '    [ "$PKG_MGR" = "$d" ] || die "$conf declares PKG_MGR=$PKG_MGR, not $d"'),

    ("    # PKGS is newline-and-space separated in the conf for readability; collapse\n"
     "    # to a single space-separated list for word splitting.",
     "    # PKGS is newline-and-space separated in the table for readability; collapse\n"
     "    # to a single space-separated list for word splitting."),
]
for old, new in RETARGET:
    assert old in text, "retarget seam not found:\n%r" % old
    text = text.replace(old, new)

# One source of truth for the supported list. detect.sh hardcoded its own copy,
# and the two would drift the first time a table was added.
old_list = 'LFS_SUPPORTED_PKGMGR="apt-get dnf pacman zypper apk xbps-install emerge"'
assert old_list in text, "supported pkgmgr list not found"
text = text.replace(
    old_list,
    'LFS_SUPPORTED_PKGMGR=$(printf \'%s\' "$(lfs_supported_pkgmgr)" | tr \'\\n\' \' \')')

assert_script_name_coupled(text)
(ROOT / SCRIPT_NAME).write_text(text)
# count("\n") + 1 counts the empty string after the final newline, so the
# report was one line higher than wc -l. Nothing is wrong with the file; the
# number it prints just has to be the number a user would get from wc.
print("wrote %s: %d lines, %d bytes"
      % (SCRIPT_NAME, text.count("\n"), len(text)))
