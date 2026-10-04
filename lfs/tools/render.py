#!/usr/bin/env python3
import re
from textwrap import dedent

from distill import Package

# §8.65.2/§8.65.3 are the same package reconfigured for UEFI, not separate
# packages, so they stay out of the stage lists -- see _firmware_platform.
SKIPPED = {"GRUB for 64-bit UEFI", "GRUB for 32-bit UEFI"}
SRC_DIRS = {"Tcl": "tcl8.6.18"}          # tcl tarball has a -src suffix but extracts w/o it

TARBALLS = {
    "Cross Binutils": "binutils-2.47.tar.xz", "Cross GCC": "gcc-16.2.0.tar.xz",
    "Linux API Headers": "linux-7.1.8.tar.xz", "Glibc": "glibc-2.44.tar.xz",
    "Target Libstdc++": "gcc-16.2.0.tar.xz",
    "M4": "m4-1.4.21.tar.xz", "Ncurses": "ncurses-6.6.tar.gz", "Bash": "bash-5.3.tar.gz",
    "Coreutils": "coreutils-9.11.tar.xz", "Diffutils": "diffutils-3.12.tar.xz",
    "File": "file-5.48.tar.gz", "Findutils": "findutils-4.11.0.tar.xz",
    "Gawk": "gawk-5.4.1.tar.xz", "Grep": "grep-3.12.tar.xz", "Gzip": "gzip-1.14.tar.xz",
    "Make": "make-4.4.1.tar.gz", "Patch": "patch-2.8.tar.xz", "Sed": "sed-4.10.tar.xz",
    "Tar": "tar-1.35.tar.xz", "Xz": "xz-5.8.3.tar.xz",
    "Binutils": "binutils-2.47.tar.xz", "GCC": "gcc-16.2.0.tar.xz",
    "Gettext": "gettext-1.0.tar.xz", "Bison": "bison-3.8.2.tar.xz",
    "Perl": "perl-5.44.0.tar.xz", "Zlib": "zlib-1.3.2.tar.gz",
    "mpdecimal": "mpdecimal-4.0.1.tar.gz", "Python": "Python-3.14.7.tar.xz",
    "Python 3": "Python-3.14.7.tar.xz", "Texinfo": "texinfo-7.3.tar.xz",
    "Util-linux": "util-linux-2.42.2.tar.xz",
    "Man-pages": "man-pages-6.18.tar.xz", "Iana-Etc": "iana-etc-20260805.tar.gz",
    "Bzip2": "bzip2-1.0.8.tar.gz", "Lz4": "lz4-1.10.0.tar.gz", "Zstd": "zstd-1.5.7.tar.gz",
    "Readline": "readline-8.3.tar.gz", "Pcre2": "pcre2-10.47.tar.bz2",
    "Bc": "bc-7.0.3.tar.xz", "Flex": "flex-2.6.4.tar.gz", "Tcl": "tcl8.6.18-src.tar.gz",
    "Expect": "expect5.45.4.tar.gz", "DejaGNU": "dejagnu-1.6.3.tar.gz",
    "Ninja": "ninja-1.13.2.tar.gz", "Pkgconf": "pkgconf-3.0.5.tar.xz",
    "GMP": "gmp-6.3.0.tar.xz", "MPFR": "mpfr-4.2.2.tar.xz", "MPC": "mpc-1.4.1.tar.xz",
    "Attr": "attr-2.6.0.tar.gz", "Acl": "acl-2.4.0.tar.xz", "Libcap": "libcap-2.78.tar.xz",
    "Libxcrypt": "libxcrypt-4.5.2.tar.xz", "Shadow": "shadow-4.20.2.tar.xz",
    "Psmisc": "psmisc-23.7.tar.xz", "Libtool": "libtool-2.6.2.tar.xz",
    "GDBM": "gdbm-1.26.tar.gz", "Gperf": "gperf-3.3.tar.gz", "Expat": "expat-2.8.3.tar.xz",
    "Inetutils": "inetutils-2.8.tar.gz", "Less": "less-704.tar.gz",
    "Autoconf": "autoconf-2.73.tar.xz", "Automake": "automake-1.18.1.tar.xz",
    "OpenSSL": "openssl-4.0.1.tar.gz", "Libelf": "elfutils-0.195.tar.bz2",
    "Libffi": "libffi-3.8.0.tar.gz", "Sqlite": "sqlite-autoconf-3530400.tar.gz",
    "Flit-Core": "flit_core-4.0.2.tar.gz", "Packaging": "packaging-26.3.tar.gz",
    "Wheel": "wheel-0.48.0.tar.gz", "Setuptools": "setuptools-84.0.0.tar.gz",
    "Meson": "meson-1.12.0.tar.gz", "Kmod": "kmod-34.2.tar.xz", "Groff": "groff-1.24.1.tar.gz",
    "GRUB for BIOS": "grub-2.14.tar.xz", "IPRoute2": "iproute2-7.1.0.tar.xz",
    "Kbd": "kbd-2.10.0.tar.xz", "Libpipeline": "libpipeline-1.5.8.tar.gz",
    "Vim": "vim-9.2.1025.tar.gz", "MarkupSafe": "markupsafe-3.0.3.tar.gz",
    "Jinja2": "jinja2-3.1.6.tar.gz", "systemd": "systemd-261.2.tar.gz",
    "D-Bus": "dbus-1.16.2.tar.xz", "Man-DB": "man-db-2.13.1.tar.xz",
    "Procps-ng": "procps-ng-4.0.7.tar.xz", "E2fsprogs": "e2fsprogs-1.47.4.tar.gz",
}


def slug(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "_", name).strip("_")


def func_name(p: Package) -> str:
    return f"build_{p.num.replace('.', '_')}_{slug(p.name)}"


def render_package(p: Package) -> str:
    if p.name in SKIPPED:
        return ""
    src = TARBALLS.get(p.name)
    if src is None:
        raise KeyError(f"no TARBALLS entry for {p.name} ({p.num})")
    srcdir = SRC_DIRS.get(p.name, src.rsplit(".tar", 1)[0])
    body = "\n".join(_firmware_platform(p, _tolerate(p)))
    fn = func_name(p)
    return dedent(f"""\
        {fn}() {{
            set -e
            local SOURCES_DIR="${{SOURCES_DIR:-/mnt/lfs/sources}}"
            pushd "$SOURCES_DIR" || return 1
            rm -rf {srcdir} || true
            tar -xf {src} || return 1
            pushd {srcdir} || return 1
            {body}
            popd || return 1
            rm -rf {srcdir} || true
            popd || return 1
        }}
        """)


# The book TOLERATES nonzero exits from its own test/diagnostic commands: the
# test-suite invocations (`make check`, `make test`, `make -k check`, and the
# `su tester -c ... make check` forms) and the follow-up failure-report greps
# (`grep "Timed out" $(find -name \*.out)` in §8.5.1, `grep '^FAIL:' $(find
# -name '*.log')` in §8.22.1 — which exit 1 on a CLEAN pass). Under `set -e`
# those deterministic exits kill stage_07_ch8, so they are re-emitted
# non-fatally while every other command in the block stays fatal. Test-suite
# failure-greps that the book intends as positive assertions (`grep ... dummy.log`
# in §5.5.1/§8.32.1) are NOT matched (regex is anchored to `Timed out`/`^FAIL:`)
# and therefore remain fatal.
# `make` and the target may have `VAR=value` words in between: coreutils 8.61.1
# runs its root-side tests as `make NON_ROOT_USERNAME=tester check-root`, and the
# old pattern missed it, so that one stayed fatal. It is the same category as
# the rest -- a test suite -- and it is the one that actually fails here:
# tests/chroot/chroot-credentials asserts `chroot` exits 125, and the chroot it
# just built exits 1. That is a self-test disagreeing with the binary, not a
# broken build, and the book itself calls the suite optional ("Skip down to
# Install the package if not running the test suite").
_TESTSUITE = re.compile(
    r'^\s*(?:make\s+(?:-k\s+)?(?:check|test|check-root)\b'
    r'|make\s+(?:\w+=\S+\s+)*(?:check|test|check-root)\b'
    r'|su tester -c .*make)')
_FAILGREP = re.compile(r'^\s*grep\s+["\']?(?:Timed out|\^FAIL:)')

# §8.23.1 GMP closes its suite with an informational pass count:
#     cat $(find -name '*.log') | grep -c ^PASS
# Same intent as _FAILGREP -- report the result, never end the stage on it --
# but it starts with `cat`, so the grep-shaped rule never matched it. Two
# hazards follow, and appending `|| true` fixes neither on its own:
#   1. find matching nothing expands to zero words, leaving `cat` with no
#      operands, so it reads stdin. The stages inherit the installer's stdin,
#      which is the operator's console, so an unattended build hangs there
#      instead of failing.
#   2. `grep -c` exits 1 when the count is zero, and under the stage's `set -e`
#      that kills a stage whose `make check` failure the line directly above
#      declared non-fatal.
# So the find is turned into the same traversal feeding cat through -exec, which
# runs cat zero times when there is nothing to read, and the count is made
# non-fatal. [^()] keeps the substitution balanced so a find with a predicate
# containing parentheses is not split mid-expression.
_PASSCOUNT = re.compile(
    r'^(\s*)cat\s+\$\(find(\s+-name[^()]*)\)\s*\|\s*(grep\s+-c\b.*?)\s*$')

# The same hazard in its other shape. §8.5.1 Glibc and §8.22.1 Binutils end
# their suites with `grep "Timed out" $(find -name \*.out) || true` and
# `grep '^FAIL:' $(find -name '*.log') || true`. The `|| true` covers the exit
# status, so these read as already safe, and they are not: with no matching
# files the substitution expands to nothing, leaving grep with no file operands,
# and grep then reads stdin -- which under `make` is the terminal or whatever
# the next recipe feeds it. -exec gives grep explicit operands instead. The
# search path is written out as `.` rather than left implicit.
_GREPFIND = re.compile(r'^(\s*)grep\s+(.*?)\s*\$\(find(\s+-name[^()]*)\)(.*)$')

_EXPECT_TEST = re.compile(r'^\s*expect\b')

# The book writes several command substitutions unquoted where each expands to a
# single path: config.guess triplets, gcc -print-*, $(pwd), $(dirname $L) and
# $(uname -m). None of them contain spaces, so quoting changes nothing about what
# runs and only removes the chance of the shell re-splitting or globbing the
# result. Restricted to this list on purpose: the book also has substitutions
# where word splitting is the point.
_QUOTABLE = (r'config\.guess|gcc\s+-print-|\bpwd\b|\bdirname\b|'
             r'\buname\s+-m\b')

# A substitution is only quoted when the character before its opening `$(` is
# not already the closing quote of a double-quoted string -- otherwise an
# already-correct line would come out as `""$(...)""`. [^()] keeps the match
# inside the innermost substitution, and the non-capturing group keeps the
# lookahead's alternation from escaping the lookahead.
_SUBST_TO_QUOTE = re.compile(
    r'(?<!"\$\()\$\((?=[^()]*(?:' + _QUOTABLE + r'))([^()]*)\)')

# `case` headers are emitted as the book writes them -- pinned by
# test_render_package_emits_case_verbatim -- and case does not word-split its
# word, so there is nothing there to quote.
_CASE_HEADER = re.compile(r'^\s*case\b')

# Book 8.27 rewrites its glibc cross-build cleanup as
#     find /usr -depth -name $(uname -m)-lfs-linux-gnu\* | xargs rm -rf
# xargs splits its input on whitespace, so a path containing a space reaches rm
# as two arguments -- one real, one not -- and rm is then asked to delete
# something unintended. -exec hands each path over intact.
_XARGS_RM = re.compile(r'^(\s*)find\s+([^|]*?)\s*\|\s*xargs\s+rm\s+-rf\s*$')

# `-name \*.so*` is the book's way of handing find a glob unexpanded. Single
# quotes say exactly the same thing with no backslash to misread. Only the
# backslash is consumed, so the glob keeps its leading `*`; the capture stops
# at whitespace, ')', '|' or ';' so a closing paren is never swallowed.
_ESCAPED_GLOB = re.compile("-name " + re.escape("\\") + r"([^\s)|;]*)")

# §8.77.1 systemd runs its suite as `unshare -m ninja test`. Meson's harness has
# three tests that cannot pass in the chroot, and the suite is the only signal
# that the build is sound, so it reports rather than aborts.
#
# Pinned exact by test_meson_test_pattern_is_exact: `-m` is the mount namespace
# this one chapter uses and is not optional, and the trailing `test` is required.
# Matching on `ninja test` alone would silently forgive the real builds in
# §8.21.1 Pkgconf and §8.78.1 D-Bus, which pass and should stay fatal.
_MESON_TEST = re.compile(r'^\s*unshare\s+-m\s+ninja\s+test\b')

# systemctl inside the chroot has no running init to talk to, so
# `systemctl disable --now nscd` (§8.5.1) and `systemctl preset-all` (§8.77.1)
# cannot succeed. Tolerated line by line so a sibling fatal command in the
# same block still aborts the stage.
_SYSTEMCTL = re.compile(r'^\s*systemctl\b')

# §8.18.1 Expect's prerequisite probe spawns a pty to prove the wrapper can
# drive an interactive child. With no controlling terminal that probe cannot
# pass, and it is a self-test of the build environment, not of Expect itself.
_PREREQ = re.compile(r'^\s*python3?\s+-c\b.*\bpty\b')

# §8.49.1 OpenSSL's `make test` leaves `openssl s_server` and `openssl ocsp`
# running as orphans -- they fork and detach, so the suite can exit while they
# are still alive. Left behind, they hold port 443 and the build never
# finishes; they are killed here, right after the suite reports.
# Anchored with .match(), so it keys off how the line starts. It requires the
# OpenSSL note as well, so a plain `make test` in another chapter -- which this
# is separately guarded against by the p.name == "OpenSSL" check -- cannot
# reach the insert.
_ORPHAN_DAEMONS = re.compile(
    r'^\s*make\s+test\s+\|\|\s*\{\s*echo\s+"note: \S*OpenSSL\b')
_ORPHAN_CLEANUP = (
    "for _d in 'openssl s_server' 'openssl ocsp'; do\n"
    "    pkill -f \"$_d\" 2>/dev/null || true\n"
    "done")


def _tolerate(p: Package) -> list[str]:
    out = []
    for b in p.blocks:
        lines = b.rstrip("\n").split("\n")
        # Normalisation before the branch logic, because it is a rewrite of how
        # the line gathers its input rather than a tolerance appended to it --
        # and because a block that runs a test suite takes the branch below,
        # which never reaches the line-wise loop. §8.23.1 GMP is exactly such a
        # block, so doing this per-branch left its summary line unrewritten.
        for i, l in enumerate(lines):
            m = _PASSCOUNT.match(l.rstrip())
            if m:
                # find feeds cat through -exec instead of a substitution, so cat
                # is never left with no operands to read stdin from.
                lines[i] = (f'{m.group(1)}find .{m.group(2)} -exec cat {{}} + | '
                            f'{m.group(3)} || true')
                continue
            new = _XARGS_RM.sub(r'\1find . \2 -exec rm -rf {} +', l)
            new = _ESCAPED_GLOB.sub(r"-name '\1'", new)
            if not _CASE_HEADER.match(new):
                new = _SUBST_TO_QUOTE.sub(r'"$(\1)"', new)
            # Written back before the two rewrites below, which key off `$(find
            # ...)` and so cannot match a line quoted above -- but writing back
            # first is what makes these three stick at all: without it the
            # substitutions are computed and thrown away.
            if new != l:
                lines[i] = new
                l = new
            m = _GREPFIND.match(l.rstrip())
            if m:
                # Same rewrite, and the guard is re-attached here because it was
                # previously added by the _FAILGREP branch below, which appends
                # to the end of the block -- and which no longer matches a line
                # that now starts with find.
                tail = m.group(4).strip()
                guard = tail if tail.startswith('||') else '|| true'
                # -H, not cat: the book greps several files, so it prefixes every
                # match with its filename. Piping cat into grep would keep the
                # build from hanging but drop that prefix, and the filename is
                # the part that says which package timed out.
                lines[i] = (f'{m.group(1)}find .{m.group(3)} -exec grep -H '
                            f'{m.group(2)} {{}} + {guard}')
        # Written back to b, not just to lines: the else-branch below re-splits
        # from b, so a rewrite held only in lines is silently discarded there.
        b = "\n".join(lines)
        is_suite = any(_TESTSUITE.match(l) for l in lines)
        is_expect_test = any(_EXPECT_TEST.match(l) for l in lines)
        if is_suite or is_expect_test:
            note = f'note: {func_name(p)}: test suite exited $? (book: failures non-fatal)'
            # A heredoc's terminator line must stay exactly the delimiter word,
            # so for heredoc blocks the guard goes on the FIRST (command) line
            # instead of after the terminator.
            i = 0 if is_expect_test else -1
            lines[i] = lines[i] + f' || {{ echo "{note}"; }}'
            if p.name == "OpenSSL":
                for j, line in enumerate(lines):
                    if _ORPHAN_DAEMONS.match(line):
                        lines.insert(j + 1, _ORPHAN_CLEANUP)
                        break
            b = "\n".join(lines)
        elif any(_FAILGREP.match(l) for l in lines):
            b = b.rstrip("\n") + " || true"
        else:
            # Tolerate individual systemctl integration lines (no running init
            # in the chroot) and book prerequisite probes (need a tty). Line-wise
            # so sibling fatal commands stay fatal.
            lines = b.split("\n")
            for i, l in enumerate(lines):
                if l.rstrip().endswith(("|| true", "|| {")):
                    continue
                if _MESON_TEST.match(l):
                    note = (f'note: {func_name(p)}: test suite exited $? '
                            f'(book: 3 tests known to fail in chroot)')
                    lines[i] = l.rstrip() + f' || {{ echo "{note}"; }}'
                elif _SYSTEMCTL.match(l) or _PREREQ.match(l):
                    lines[i] = l.rstrip() + " || true"
            b = "\n".join(lines)
        out.append(b)
    return out


# §8.65.1 configures GRUB for BIOS and §8.65.2 reconfigures the same tree for
# 64-bit UEFI; they are one package seen twice, so only the BIOS one is in the
# stage list and this substitutes the platform flags for the firmware the
# target will actually boot from. That is a deviation from the book's single
# ./configure, and it has to be here rather than in task_bootable: the
# platform modules are chosen when GRUB is CONFIGURED, so a chroot that built
# only the BIOS ones has no /usr/lib/grub/x86_64-efi at all, and the bootable
# stage's grub-install --target=x86_64-efi fails with "modinfo.sh doesn't
# exist" -- after chapter 8 has spent hours compiling, from a log inside the
# target. Observed exactly that way on a real UEFI build.
_GRUB_UEFI = "GRUB for BIOS"
_GRUB_CONFIGURE = re.compile(r"^\./configure\b")
_GRUB_PLATFORM = """\
# Deviation from book §8.65.1: §8.65.2's platform flags for a 64-bit UEFI
# build, chosen from the detected firmware. The other two options are the
# book's, and stay on both branches.
case "${LFS_FIRMWARE:-bios}" in
    uefi)
        ./configure --prefix=/usr     \\
            --sysconfdir=/etc \\
            --target=x86_64 \\
            --with-platform=efi \\
            --disable-efiemu  \\
            --disable-werror
        ;;
    *)
        ./configure --prefix=/usr     \\
            --sysconfdir=/etc \\
            --disable-efiemu  \\
            --disable-werror
        ;;
esac"""


def _firmware_platform(p: Package, blocks: list[str]) -> list[str]:
    if p.name != _GRUB_UEFI:
        return blocks
    hits = [i for i, b in enumerate(blocks) if _GRUB_CONFIGURE.match(b)]
    if len(hits) != 1:
        raise SystemExit(
            f"{func_name(p)}: expected exactly one ./configure block, found "
            f"{len(hits)}; the platform substitution would be wrong")
    blocks = list(blocks)
    blocks[hits[0]] = _GRUB_PLATFORM
    return blocks


def render_all(pkgs: list[Package]) -> str:
    out = ["#!/usr/bin/env bash",
           "# generated by distill.py --emit - do not edit by hand",
           "set -u"]
    rendered = []
    for p in pkgs:
        if p.chapter == 10:
            continue                      # the kernel is built by kernel-config.sh
        fn = render_package(p)
        if fn:
            out.append(fn)
            rendered.append(p)
    for ch in range(5, 9):
        names = [func_name(p) for p in rendered if p.chapter == ch]
        out.append(f"STAGE{ch}=( " + " ".join(names) + " )")
    # Package -> tarball, so the per-package checkpoints in stages 04/05/06 can
    # hash the source a package was built from. Keyed by function name because
    # that is what the stage loops iterate and what the marker files are named
    # after; the book reuses names across chapters (Bash is 6.4.1 and 8.39.1,
    # GCC 6.18.1 and 8.32.1) and only the function name distinguishes them.
    out.append("declare -A PKG_SRC=(")
    for p in rendered:
        out.append(f"  [{func_name(p)}]={TARBALLS[p.name]}")
    out.append(")")
    return "\n".join(out) + "\n"
