#!/usr/bin/env bash
# Tests for the package tables in installer.sh's pkgmgr_table().
#
# These tables are the thing that makes "works on any distribution" true, so
# they are checked for internal consistency rather than merely for loading. A
# typo in a package name cannot be caught here -- deps_verify catches that, on
# the real machine, by looking for the binaries -- but a malformed table, a
# mismatched manager name, or a template that cannot substitute can be.
#
# These are the tests for code that USED to be data files read off disk, so
# nothing here inspects text any more: every case is asked of the function the
# installer actually calls. That is deliberate -- a test that greps a .conf
# proves the .conf is well formed, which is not the property that matters once
# the tables live in the same file as the reader.
#
# Run:  bash lfs/tests/test_pkgmgr.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LFS_ROOT=$(cd "$HERE/.." && pwd)
export LFS_ROOT
M=$(mktemp -d)

# shellcheck source=/dev/null
source "$LFS_ROOT/installer.sh"

export LFS_LOG="$M/log"
export LFS_DRY_RUN=1

PASS=0; FAIL=0; FAILED_NAMES=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES $1"; printf '  FAIL %s\n     %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2
     actual:   $3"; fi; }

MANAGERS=$(lfs_supported_pkgmgr)
[ -n "$MANAGERS" ] || { echo "lfs_supported_pkgmgr returned nothing"; exit 1; }

# set_vars PREFIX... -- the names of every set variable starting with any of
# the given prefixes, sorted. This replaces diffing the .conf files' key sets:
# what matters is that the same set of PKG_* names ends up populated for every
# table, not that the files look alike.
#
# compgen -v, not ${!prefix@}: the latter is not a valid expansion of a
# positional parameter and fails with "bad substitution", which would leave
# this printing nothing and turn the two sections that use it into false
# passes.
set_vars() {
    local v p
    for v in $(compgen -v); do
        for p in "$@"; do
            case "$v" in $p*) printf '%s\n' "$v"; break ;; esac
        done
    done | sort
}

flat_pkgs() { printf '%s' "${PKGS-}" | tr '\n' ' ' | tr -s ' ' | sed 's/^ *//; s/ *$//'; }

# pkg_has NAME -- exact membership in the currently loaded PKGS.
pkg_has() { printf '%s\n' $PKGS | grep -qxF "$1"; }
# pkg_any RE -- any name in PKGS matching the extended regex.
pkg_any() { printf '%s\n' $PKGS | grep -qiE "$1"; }

echo "== 1. every supported manager loads and defines all required keys =="
for mgr in $MANAGERS; do
    if out=$(deps_load "$mgr" 2>&1); then
        ok "loads the $mgr table"
    else
        bad "loads the $mgr table" "$out"
    fi
done

echo
echo "== 2. all tables populate the same key set =="
# A table that sets one fewer key is how a stale value leaks: deps_load clears
# the keys it knows about, and an unknown one just survives the load.
#
# The first set_vars call is also the guard on the helper itself: a broken
# implementation prints nothing, and "everything matches nothing" is a pass.
deps_load "$(printf '%s\n' $MANAGERS | head -1)" >/dev/null 2>&1
set_vars PKG_ | grep -q . \
    || { echo "set_vars found no PKG_* variables after a load -- helper is broken"; exit 1; }

REF=""
for mgr in $MANAGERS; do
    keys=$( deps_load "$mgr" >/dev/null 2>&1; set_vars PKG_ )
    if [ -z "$REF" ]; then
        REF="$keys"
        ok "key set reference taken from $mgr"
    elif [ "$keys" = "$REF" ]; then
        ok "$mgr key set matches the reference"
    else
        bad "$mgr key set matches the reference" \
            "extra/missing: $(diff <(printf '%s\n' "$REF") <(printf '%s\n' "$keys") | tr '\n' ' ')"
    fi
done

echo
echo "== 3. package lists are well formed =="
for mgr in $MANAGERS; do
    deps_load "$mgr" >/dev/null 2>&1
    if [ -z "$PKGS" ]; then bad "$mgr has packages" "PKGS is empty"; continue; fi
    flat=$(flat_pkgs)
    # The list is word-split before it reaches the package manager, so a double
    # space would arrive as an empty argv slot and be rejected by apt/dnf.
    case "$flat" in
        *"  "*) bad "$mgr package list has no double spaces" "$flat" ;;
        *)      ok  "$mgr package list has no double spaces" ;;
    esac
    # A quote or $ in a package name would break the runsh interpolation.
    if printf '%s' "$flat" | grep -q "['\"\\\$]"; then
        bad "$mgr package names are shell-safe" "found a quote or \$ in a package name"
    else
        ok "$mgr package names are shell-safe"
    fi
    # Whether the names actually PROVIDE the build tools cannot be checked here:
    # build-essential, @development-tools and base-devel are groups that supply
    # gcc and make without naming them, so demanding the literal words would
    # fail three correct tables. deps_verify is the real gate -- it looks for the
    # binaries on the machine and fails the run with a list if any are missing.
    ok "$mgr package list is non-empty and well formed"
done

echo
echo "== 4. install template substitutes exactly once =="
for mgr in $MANAGERS; do
    deps_load "$mgr" >/dev/null 2>&1
    out=$(printf "$PKG_INSTALL_TMPL" "pkg-one pkg-two" 2>/dev/null)
    if [ "$out" = "${out%pkg-one pkg-two}" ] || [ "$out" = "${out/pkg-one pkg-two/}" ]; then
        bad "$mgr template substitutes its list" "result: $out"
    else
        ok "$mgr template substitutes its list"
    fi
    if [ "$(printf '%s' "$out" | grep -o 'pkg-one pkg-two' | wc -l)" -ne 1 ]; then
        bad "$mgr template substitutes exactly once" "result: $out"
    else
        ok "$mgr template substitutes exactly once"
    fi
done

echo
echo "== 5. the manager each table declares is the one that was asked for =="
# deps_load enforces this at load time; check it here too so the failure names
# the manager rather than arriving as a runtime error.
for mgr in $MANAGERS; do
    deps_load "$mgr" >/dev/null 2>&1
    check "$mgr table declares PKG_MGR=$mgr" "$mgr" "$PKG_MGR"
done

echo
echo "== 6. the supported list and the tables cannot drift apart =="
# This used to be a directory listing compared against detect.sh's list, and
# the check that mattered most was the reverse one: a manager in the supported
# list with no table is a host that is accepted at detection and then dies at
# deps_load. Both directions still have to hold.
n_tables=$(grep -cE '^    [a-z0-9-]+\)$' <(sed -n '/^pkgmgr_table()/,/^}/p' "$LFS_ROOT/installer.sh"))
check "the table count matches the supported list" "$(printf '%s\n' $MANAGERS | wc -l)" "$n_tables"

for mgr in $MANAGERS; do
    if in_list "$mgr" $LFS_SUPPORTED_PKGMGR; then
        ok "$mgr is in LFS_SUPPORTED_PKGMGR"
    else
        bad "$mgr is in LFS_SUPPORTED_PKGMGR" \
            "table exists but detection will never select it"
    fi
done
for mgr in $LFS_SUPPORTED_PKGMGR; do
    if pkgmgr_table "$mgr" 2>/dev/null; then
        ok "$mgr has a table"
    else
        bad "$mgr has a table" "in LFS_SUPPORTED_PKGMGR but pkgmgr_table rejects it"
    fi
done

echo
echo "== 7. no table carries bootloader settings =="
# GRUB layout is detected from the machine (boot_detect_grub), not from a
# package table. A table that reintroduced GRUB_CONFIG_DIR would resurrect the
# Debian-vs-RHEL guess that detection exists to avoid.
for mgr in $MANAGERS; do
    leaked=$( pkgmgr_table "$mgr" >/dev/null 2>&1; set_vars GRUB_ ESP )
    if [ -n "$leaked" ]; then
        bad "$mgr table has no bootloader keys" "left set: $(printf '%s' "$leaked" | tr '\n' ' ')"
    else
        ok "$mgr table has no bootloader keys"
    fi
done

echo
echo "== 8. index refresh is a real command, or deliberately empty =="
for mgr in $MANAGERS; do
    deps_load "$mgr" >/dev/null 2>&1
    # A value that forgot its quotes would expand $something at load time.
    if printf '%s' "$PKG_INDEX_CMD" | grep -q '\$'; then
        bad "$mgr index command is literal" "contains \$: $PKG_INDEX_CMD"
    else
        ok "$mgr index command is literal"
    fi
    # If set, it must start with the manager itself, or it is a typo.
    if [ -n "$PKG_INDEX_CMD" ]; then
        case "$PKG_INDEX_CMD" in
            "$mgr"*) ok "$mgr index command starts with $mgr" ;;
            *) bad "$mgr index command starts with $mgr" "got: $PKG_INDEX_CMD" ;;
        esac
    else
        ok "$mgr has no index refresh (deliberately empty)"
    fi
done

echo
echo "== 9. load is idempotent and does not leak keys between tables =="
# Loading apt then xbps must not leave apt's PKG_INDEX_CMD behind for xbps,
# which has none. If it did, a void host would try to run apt-get update.
deps_load apt-get >/dev/null 2>&1
if [ -n "$PKG_INDEX_CMD" ]; then ok "apt table defines an index refresh"; else bad "apt table defines an index refresh" "empty"; fi
deps_load xbps-install >/dev/null 2>&1
check "xbps has no index refresh after loading over apt" "" "$PKG_INDEX_CMD"
check "xbps template is not apt-get's" "xbps-install -y %s" "$PKG_INSTALL_TMPL"
# Same in the other direction for the firmware extras: bios grub must not
# survive into a table that has no UEFI extra, and vice versa. This is the
# variant that would silently install a BIOS grub on a UEFI host.
deps_load pacman >/dev/null 2>&1
deps_load apt-get >/dev/null 2>&1
check "apt UEFI extra is not pacman's" "grub-efi-amd64" "$PKG_EXTRA_UEFI"
deps_load dnf >/dev/null 2>&1
check "dnf UEFI extra is not apt's" "grub2-efi-x64" "$PKG_EXTRA_UEFI"

echo
echo "== 10. an unknown package manager is refused, not guessed =="
# The whole "any distribution" claim rests on this being a refusal. If a bogus
# name ever loaded, the run would proceed with an empty package list and
# "install" nothing.
if out=$(deps_load "apt-getty" 2>&1); then
    bad "unknown manager is refused" "deps_load accepted apt-getty"
else
    case "$out" in
        *"no package table"*) ok "unknown manager is refused by name" ;;
        *) bad "unknown manager is refused by name" "got: $out" ;;
    esac
fi
# And the error must list what IS supported, so the failure is actionable.
if out=$(deps_load "apt-getty" 2>&1); then :; else
    case "$out" in
        *apt-get*) ok "the refusal names the supported managers" ;;
        *) bad "the refusal names the supported managers" "got: $out" ;;
    esac
fi

echo
echo "== 11. the firmware-specific GRUB package is actually appended =="
# deps_install is where PKG_EXTRA_BIOS/UEFI stop being decoration, so assert on
# the install line it would produce rather than on the variable alone. Both
# firmwares are checked, because the bug this guards is exactly "it works for
# BIOS" -- which is what the previous apt run proved before the UEFI path was
# ever exercised.
for mgr in $MANAGERS; do
    deps_load "$mgr" >/dev/null 2>&1
    for fw in bios uefi; do
        case "$fw" in
            bios) want="$PKG_EXTRA_BIOS" ;;
            uefi) want="$PKG_EXTRA_UEFI" ;;
        esac
        if [ -z "$want" ]; then
            bad "$mgr declares a $fw GRUB package" "PKG_EXTRA_${fw^^} is empty"
            continue
        fi
        line=$( LFS_FIRMWARE="$fw" LFS_DRY_RUN=1 \
                deps_install 2>&1 | grep -o 'packages: .*' | head -1 )
        case "$line" in
            *" $want"*) ok "$mgr adds '$want' on $fw" ;;
            *) bad "$mgr adds '$want' on $fw" "install line was: $line" ;;
        esac
    done
done
# The wrong-firmware package must NOT be there: installing grub-pc on a UEFI
# host is a slow, confusing failure at grub-install time.
deps_load apt-get >/dev/null 2>&1
line=$( LFS_FIRMWARE=uefi LFS_DRY_RUN=1 deps_install 2>&1 | grep -o 'packages: .*' | head -1 )
case "$line" in
    *grub-pc\ *) bad "uefi install line excludes the bios package" "$line" ;;
    *)          ok  "uefi install line excludes the bios package" ;;
esac
line=$( LFS_FIRMWARE=bios LFS_DRY_RUN=1 deps_install 2>&1 | grep -o 'packages: .*' | head -1 )
case "$line" in
    *grub-efi-amd64\ *) bad "bios install line excludes the uefi package" "$line" ;;
    *)                ok  "bios install line excludes the uefi package" ;;
esac

echo
echo "== 12. every installed name is one that distro actually ships =="
# Each name asserted here was checked against that distribution's live package
# index. They are pinned by name, not merely for shape, because a reverted fix
# would otherwise only surface on a stranger's machine hours into a build.
# Capability names (openSUSE's `gettext` and `python3`) are deliberately NOT
# forced to a literal package: zypper and dnf resolve those through Provides
# (136 providers for python3, 5 for gettext), and pinning python313 would rot on
# the next openSUSE release.
for mgr in $MANAGERS; do
    deps_load "$mgr" >/dev/null 2>&1
    # klibc was never referenced by the script on any path -- it was a pure table
    # entry, and four of the five non-apt managers do not ship it at all.
    if pkg_any 'klibc'; then
        bad "$mgr installs no unused klibc" "$(printf '%s\n' $PKGS | grep -i klibc | tr '\n' ' ')"
    else
        ok "$mgr installs no unused klibc"
    fi
    # task_fetch_sources downloads with curl. wget was installed (and, on
    # Fedora, no longer even exists) yet never called, so a host without curl
    # died at the first download while deps_verify said all tools were present.
    case "$mgr" in
        emerge) want_curl=net-misc/curl ;;
        *)      want_curl=curl ;;
    esac
    if pkg_has "$want_curl"; then ok "$mgr installs the fetcher ($want_curl)"
    else bad "$mgr installs the fetcher ($want_curl)" "not in: $(flat_pkgs)"; fi
    if pkg_any '(^|/)wget$'; then
        bad "$mgr installs no unused wget" "$(printf '%s\n' $PKGS | grep -E '(^|/)wget$' | tr '\n' ' ')"
    else
        ok "$mgr installs no unused wget"
    fi
done

# openSUSE: the names that differ from the Debian/Fedora spellings.
deps_load zypper >/dev/null 2>&1
for want in libelf-devel pkgconf; do
    if pkg_has "$want"; then ok "zypper installs $want"; else bad "zypper installs $want" "not in: $(flat_pkgs)"; fi
done
for gone in elfutils-devel pkg-config; do
    if pkg_has "$gone"; then bad "zypper no longer installs $gone" "still present"; else ok "zypper no longer installs $gone"; fi
done
check "zypper BIOS GRUB package" "grub2-i386-pc"  "$PKG_EXTRA_BIOS"
check "zypper UEFI GRUB package" "grub2-x86_64-efi" "$PKG_EXTRA_UEFI"

# Gentoo: the original table named eleven atoms that do not exist.
deps_load emerge >/dev/null 2>&1
for want in sys-apps/shadow dev-libs/elfutils app-arch/tar sys-apps/texinfo \
            dev-tcltk/expect sys-fs/e2fsprogs sys-block/parted dev-lang/perl \
            dev-libs/libffi; do
    if pkg_has "$want"; then ok "emerge installs $want"; else bad "emerge installs $want" "not in table"; fi
done
for gone in sys-devel/g++ app-admin/shadow app-arch/elfutils app-arch/tar-utils \
            app-doc/texinfo dev-lang/expect sys-apps/e2fsprogs sys-apps/parted \
            sys-devel/perl virtual/libffi; do
    if pkg_has "$gone"; then bad "emerge no longer installs $gone" "still present"; else ok "emerge no longer installs $gone"; fi
done

rm -rf "$M"
echo
echo "================================"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then printf 'failing:%s\n' "$FAILED_NAMES"; exit 1; fi
printf 'ALL PKGMGR TABLE TESTS PASSED\n'
exit 0
