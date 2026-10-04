#!/usr/bin/env bash
# Dependency installation: turn a detected package manager into an installed
# toolchain.
#
# Sourced, not executed. All the package-manager-specific knowledge lives in
# pkgmgr/<name>.conf as pure data; this file is the only code that interprets
# it. That split is what makes the table testable without booting seven VMs --
# see tests/test_pkgmgr.sh.
#
# Populated by deps_load:
#   PKG_MGR PKG_INDEX_CMD PKG_INSTALL_TMPL PKGS
# Optional in a conf: DEPS_PREFLIGHT (shell snippet run before installing).
#
# Deliberately NOT here: anything about GRUB. Where grub.cfg lives and which
# command regenerates it differ between the Debian and RHEL layouts and have
# nothing to do with the package manager, so boot.sh detects those by looking at
# the machine. See boot_detect_grub.

[ -n "${_LFS_DEPS_SH:-}" ] && return 0
_LFS_DEPS_SH=1

# Keys every pkgmgr/<name>.conf must define. Enforced at load time rather than
# trusted, because a missing key surfaces as a confusing failure much later --
# e.g. boot.sh referencing an empty config path and silently writing its
# drop-in somewhere harmless.
DEPS_REQUIRED_KEYS="PKG_MGR PKG_INSTALL_TMPL PKGS"

# deps_load [PKGMGR] -- source and validate pkgmgr/PKGMGR.conf.
#
# Defaults to the detected package manager. The argument exists so the test
# suite and a curious user can ask "what would this do on Fedora?" without a
# Fedora host.
deps_load() {
    local d="${1:-${LFS_PKGMGR:-}}"
    [ -n "$d" ] || die "deps_load: no package manager given and none detected"
    local conf="$LFS_ROOT/pkgmgr/$d.conf"
    [ -f "$conf" ] || die "no dependency table for package manager '$d'
  (expected $conf)
  Available: $(ls -1 "$LFS_ROOT/pkgmgr" 2>/dev/null | sed 's/\.conf$//' | tr '\n' ' ')"

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

    local missing=""
    for k in $DEPS_REQUIRED_KEYS; do
        [ -n "${!k:-}" ] || missing="$missing $k"
    done
    [ -z "$missing" ] || die "$conf is missing required key(s):$missing"

    # The manager named in the table must match the file it came from, or the
    # log will claim one thing while another happens.
    [ "$PKG_MGR" = "$d" ] || die "$conf declares PKG_MGR=$PKG_MGR but lives in $d.conf"

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

    # PKGS is newline-and-space separated in the conf for readability; collapse
    # to a single space-separated list for word splitting.
    local pkglist
    pkglist=$(printf '%s' "$PKGS" | tr '\n' ' ' | tr -s ' ')
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
  Install them by hand, or add/fix the package name in that file and re-run --
  the point of this check is to fail now, with a list, rather than hours into
  the build."
    fi
    say "all required build tools present"
}
