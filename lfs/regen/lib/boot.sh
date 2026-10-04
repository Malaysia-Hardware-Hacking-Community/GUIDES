#!/usr/bin/env bash
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

[ -n "${_LFS_BOOT_SH:-}" ] && return 0
_LFS_BOOT_SH=1

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
# Added by lfs-bootstrap.sh. Delete this file to remove the LFS boot entry.
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
# decision bootstrap.sh makes explicitly, not a side effect of asking.
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
add it to the list in boot_detect_grub (lfs/lib/boot.sh)."

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
Install the host's GRUB tools, or add the correct command to boot_detect_grub
(lfs/lib/boot.sh) if it lives somewhere unusual."
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
    wrapper=$(printf '#!/bin/sh\n# Added by lfs-bootstrap.sh. Delete this file to remove the LFS boot entry.\ncat <<'"'"'LFS_GRUB_EOF'"'"'\n%s\nLFS_GRUB_EOF\n' "$(printf '%s\n' "$entry" | grep -v '^# Added by')")

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
