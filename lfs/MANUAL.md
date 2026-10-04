# `installer.sh` manual

How to run the installer, what it does to your machine, how to resume a failed
build, and how to tell a good LFS from a broken one. For what the file *is* and
why it is built this way, see `README.md`. For `--help`, the script answers
faster than this document.

## 1. The short version

```bash
sudo ./installer.sh --plan          # always first; changes nothing
sudo ./installer.sh                 # erases the target, builds LFS
                                    # (asks you to type `yes` first)
                                    # hours later:
                                    # reboot, boot the disk
```

That is the whole happy path. `--yes` is the same run with the confirmation
skipped; use it only when there is no terminal to answer on (`nohup`, cron, CI).

Everything below is for when it goes wrong, or when you want to install alongside
an existing system instead of replacing it.

## 2. Choosing a target

With no `--target`, the installer looks for **exactly one** unused disk and uses
it. If it finds none, or more than one, it prints the candidates and stops. It
never picks one for you out of a set of possibilities.

```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL   # what is attached
sudo ./installer.sh --plan                # confirms the choice
sudo ./installer.sh --target /dev/vdb --yes   # or name it yourself
```

Both a whole disk (`/dev/vdb`) and a partition (`/dev/vdb1`) are accepted. A
whole disk is partitioned by the installer.

### The layout it writes

On a BIOS machine, a whole-disk target is given a GPT table with two
partitions:

| Partition | Size | Type | Contents |
|---|---|---|---|
| `1` | 2 MiB | BIOS boot (`21686148-…`) | nothing — left unformatted |
| `2` | rest of disk | Linux filesystem | ext4, label `LFS`, mounted at `/mnt/lfs` |

On a UEFI machine, the same whole-disk takeover writes an EFI System
partition as partition 1 and the root filesystem as partition 2:

| Partition | Size | Type | Contents |
|---|---|---|---|
| `1` | 512 MiB | EFI System (`c12a7328-…`) | FAT32, label `EFI`, mounted at `/mnt/lfs/boot/efi` |
| `2` | rest of disk | Linux filesystem | ext4, label `LFS`, mounted at `/mnt/lfs` |

That ESP carries three things: `EFI/LFS/grubx64.efi`, the removable fallback
`EFI/BOOT/BOOTX64.EFI` (what a firmware with no boot-entry support falls back
to), and a `/boot/efi` line in `fstab` keyed on the ESP's UUID so the mount
comes back after a reboot. The install also registers `EFI/LFS` in the
firmware's NVRAM from the host, where `efibootmgr` exists — the book builds no
`efibootmgr`, so the chroot's `grub-install` runs `--no-nvram`.

Resuming a run does not reformat that ESP; it is located by partition type and
reused.

The kernel command line this produces is `root=PARTUUID=<the GPT partition
UUID>`, not a device path and not `root=UUID=<the filesystem UUID>`. Both
alternatives were tried on a real UEFI target. A device path (`/dev/vdb2`, which
is what `grub-mkconfig` writes on its own here, because a chroot without udev
cannot resolve an identifier) survives the machine it was built on and fails on
the next one. `root=UUID=` fails everywhere on this kernel: booted with the
correct filesystem UUID, verified with `blkid` from inside the guest, the kernel
still panicked with `VFS: Cannot open root device`, never opening the
superblock. `root=PARTUUID=` is verified on both paths: a guest booted with the
PARTUUID of this install reached a login prompt under UEFI/OVMF, and again
under BIOS/SeaBIOS with the entry GRUB generated into a real host's
`/etc/grub.d` and picked up by `update-grub`. The install refuses to finish if a
device-path or UUID root survives in `grub.cfg`, so neither path can regress
unnoticed.

The first partition exists because GRUB's BIOS installer has to embed
`core.img` somewhere, and a GPT disk has no gap large enough ahead of the first
partition. Without it `grub-install` reports *"this GPT partition label contains
no BIOS Boot Partition; embedding won't be possible"*, offers a blocklist
fallback, and then refuses that too — after the entire build has completed.

The type matters. Guides commonly show `set 1 esp on`, which tags the partition
as an EFI System partition; that is a different GUID and GRUB rejects it. The
installer sets the `bios_grub` type GUID, which is the one `grub-install`
actually looks for.

Pointing `--target` at a partition rather than a whole disk formats that
partition where it already lives and leaves the existing table alone. GRUB then
needs an embedding target that already exists on that disk.

### What it refuses to touch

The installer stops, before writing anything, if the target:

- is the disk holding the running root filesystem,
- is a mounted partition, or is in `/proc/swaps`,
- is your live distribution (it refuses to run on Omarchy),
- is ambiguous, when you did not name it and more than one disk is free.

`--plan` performs every one of these checks. If `--plan` says no, the real run
will too.

It also refuses, before partitioning, to do a **takeover** install on a machine
with **Secure Boot enabled**. The GRUB this build installs is not signed, so
Secure Boot would refuse to execute it and the machine would not come up. (On
this path there is nothing to gain by disabling it first: leave it enabled and
use `--mode side-by-side`, where the host's own signed bootloader chain starts
the kernel.) No unsigned kernel can boot under Secure Boot, so "just turn it off
afterwards" is not advice this installer gives.

Non-x86_64 hosts are out of scope: the 13.1 book builds an x86_64 toolchain and
the whole thing is `x86_64-lfs-linux-gnu` from detection to fstab.

## 3. The two modes

| | `takeover` (default) | `side-by-side` |
|---|---|---|
| The target disk | erased entirely | one partition formatted, existing table kept |
| Current OS | no longer bootable | still bootable |
| After the build | reboot boots LFS | pick LFS from the boot menu |
| Use when | the machine's only job is to be LFS | you need to keep what is there |

```bash
sudo ./installer.sh --mode side-by-side --target /dev/vdb
```

`side-by-side` never modifies the existing partition table. It adds a GRUB
menuentry (BIOS) or a UEFI entry named by `--boot-id` (default `LFS`). The
target partition must be on a GPT disk, because the boot entry identifies the
root by `PARTUUID` and MBR has no partition UUIDs; an MBR target is refused
before the build starts rather than after it.

Both paths write their own boot config rather than letting a generator produce
it, and both use the same two identifiers: `search --fs-uuid` finds the
filesystem the kernel is read from, and the kernel's own `root=` uses the
*PARTUUID*, for the reasons given under "Choosing a target" in section 2.
Neither carries an `initrd` line, because this build creates no initramfs.

On BIOS that config is a `grub.d` drop-in plus `grub-mkconfig`. On UEFI the
loader is built by `grub-mkstandalone` with the config *embedded in the image*,
so the entry is self-contained. It has to be: `grub-install` would instead bake
its prefix into the loader with `grub-mkimage --prefix` and write no config into
`EFI/LFS/` at all, so the entry would resolve the prefix of whichever system was
running at install time — in `side-by-side`, the host's `/boot/grub/grub.cfg`.
The new firmware entry would then boot the host OS and look like an install that
did nothing. Writing a corrected `EFI/LFS/grub.cfg` by hand does not help; there
is no such file, and nothing reads it. Both facts were confirmed in a VM: a
hand-written `EFI/LFS/grub.cfg` was ignored, and the embedded-config loader
booted LFS with the takeover loader deleted.

The loader embeds every module rather than a chosen list. GRUB's `search` is a
meta-module, and a hand-picked list does not resolve it — the image fails at
boot with ``file `.../search.mod' not found`` — so a 4 MB loader is the price of
a side-by-side entry that works on the first try.

`side-by-side` has not been booted on real hardware; `takeover` is the validated
path. Its UEFI entry has been booted in QEMU/OVMF.

## 4. What a run does

The destructive part — partitioning, formatting, mounting — happens up front,
behind the safety gate and after the `--plan`-equivalent confirmation. On a
first run it is not a build stage and not resumable: those writes are not
idempotent, and pretending otherwise is how you lose a disk.

`--resume` is the exception, and only on a target that already holds a
completed run of this installer. A whole disk with a partition carrying an
ext4 filesystem with both `/mnt/lfs/.stages` and `/mnt/lfs/usr` is recognised as
a prepared target and left completely alone: no new partition table, no mkfs,
no touched checkpoints. Anything else — a blank disk, a foreign filesystem, an
unrelated ext4 volume — is still erased, because `--resume` is not a promise to
preserve arbitrary data on a disk you named as the target.

To resume onto a *new* layout (for example after upgrading the installer to
create a BIOS boot partition where it used to create none), do not pass
`--resume`: the old partition table is not the one the new code writes.

After that, eight checkpointed stages run in order. Each writes
`/mnt/lfs/.stages/<name>.done` when it succeeds, and the four package-building
stages (`toolchain`, `temptools`, `chroot_tools`, `ch8`) also write one
`/mnt/lfs/.stages/<stage>-pkgs/<package>.done` per package they finish. Each
package marker records the md5 of the tarball it was built from, so a source
you re-download or corrupt is rebuilt on the next resume rather than skipped.

| Stage | Roughly | Chapter 8 packages |
|---|---|---|
| `sources` | download and md5-verify every tarball | — |
| `lfsusr` | the `$LFS` skeleton and the `lfs` user | — |
| `toolchain` | cross binutils, cross gcc, headers, glibc, libstdc++ | — |
| `temptools` | native binutils, gcc, and the build tools | — |
| `chroot_tools` | chroot preparation and its verification pass | — |
| `ch8` | the bulk of the system | 80 |
| `sysconfig` | fstab, locales, timezone, root password | — |
| `bootable` | kernel, `grub-install`, boot configuration | — |

A failed checksum aborts in `sources`, not three hours into chapter 8.

Expect several hours. Every package-building stage checkpoints per package, so
a failure in chapter 8 does not restart glibc, and a failure late in chapter 6
does not restart the cross toolchain.

## 5. Resuming

Checkpoints are **opt-in**. Without `--resume` the installer deliberately
clears them and starts the build over, so a plain re-run never silently
inherits a half-built tree it did not create.

```bash
sudo ./installer.sh --target /dev/vdb --yes --resume
```

With `--resume`:

- a target that already holds a previous LFS build is **left alone** — it is
  not repartitioned and not reformatted;
- stages whose `.done` marker exists are skipped;
- inside a stage that is not yet complete, packages whose per-package marker
  exists **and** whose source tarball is unchanged are skipped;
- the first unmarked stage starts from the top.

Reuse requires the target to actually look like a build this installer made:
an ext4 filesystem carrying both `.stages/` and `usr/`. A blank disk, an
unrelated ext4 filesystem, or a different filesystem type is still formatted.
If `--resume` is not passed, the disk is erased even if it holds a previous
build. That is the point of `takeover`.

A resumed build reuses the downloaded sources, so a failure late in chapter 8
does not re-download 100 tarballs.

## 6. Logs

| What | Where |
|---|---|
| the whole run, appended | `/var/log/installer.log` (`$LFS_LOG`) |
| one file per package | `/mnt/lfs/buildlogs/` |
| kernel build | `/mnt/lfs/buildlogs/kernel.log` |
| bootloader install | `/mnt/lfs/buildlogs/bootable.log` |

A stage that fails prints the last lines of its own log, because the interesting
part is usually at the bottom:

```bash
tail -50 /mnt/lfs/buildlogs/ch8-build_8_5_1_Glibc.log
grep -E 'error|Error' /mnt/lfs/buildlogs/bootable.log | head
```

While a build runs, `tail -f /var/log/installer.log` shows stage transitions.
The live per-package log is the thing to watch when a stage seems stuck.

## 7. Finishing

The installer **does not reboot**. It finishes, says where LFS is installed, and
stops. Rebooting is deliberate, so the system you are in does not vanish from
under you mid-run.

```bash
sudo umount -R /mnt/lfs     # if it is still mounted
sudo reboot
```

- `takeover`: the target disk boots LFS.
- `side-by-side`: pick the LFS entry from the boot menu.

## 8. Checking that it worked

Inside LFS:

```bash
cat /etc/os-release        # NAME="Linux From Scratch"
uname -r                   # the kernel you built, e.g. 7.1.8
gcc --version | head -1    # the compiler you built, e.g. gcc (GCC) 16.2.0
findmnt -no SOURCE /       # the partition LFS actually booted from
systemctl is-system-running
```

There is no `systemd` binary on an LFS system — only `systemctl`. Use
`systemctl --version`.

You should find, in a successful install:

- a serial console, so a headless VM can still be reached. `takeover` writes
  `console=ttyS0,115200n8` into `/etc/default/grub` and enables
  `serial-getty@ttyS0.service`. The serial terminal is compiled into GRUB's
  `core.img` at `grub-install` time, so it has to be set before that runs.
- `/boot/grub/grub.cfg` written by `grub-mkconfig`, holding the standard
  "Advanced options" submenu. There is **no** rescue entry: LFS has no initrd,
  so `grub-mkconfig` does not generate one, and this installer does not invent
  one. If you need a fallback, add it by hand.

`side-by-side` behaves differently on that last point. It never regenerates the
host's whole menu: on BIOS it writes its own `/etc/grub.d` drop-in, and on UEFI
it embeds a standalone entry in a new loader under `EFI/LFS/`. The host's
existing config is left untouched on both.

## 9. When it goes wrong

**"refusing to guess" / several unused disks**
Name the target explicitly with `--target`.

**`/dev/stdin: Permission denied` or an empty package log**
Should not happen with a current build — that was the privilege-drop bug, fixed
in `build_run_lfs`, which now hands the book section to the `lfs` user as a
readable file. If you see it, check the file is current:
`md5sum installer.sh`.

**A stage fails part-way**
Read that stage's log, fix the cause, then re-run with `--resume` and the same
`--target`. Do not re-run without `--resume` unless you want the disk erased.

**The build finished but the machine will not boot it**
From a live system, mount the target and read `/mnt/lfs/buildlogs/bootable.log`.
On BIOS, note that SeaBIOS ignores `<source index>`, so the boot order must be
set in the firmware, not by passing a source index.

**Target busy during teardown**
The usual cause is a leftover daemon from a package's test suite, not a dying
child. OpenSSL's `make test` forks an ECH `s_server` and an `ocsp` responder
that outlive the suite and hold `/mnt/lfs` open, so the final unmount fails and
the build can print a successful `=== done ===` with the target still mounted.
Current builds reap them; an older one may still leave them. Find and clear:

```sh
fuser -vm /mnt/lfs          # who is holding it
pkill -f 'openssl s_server'; pkill -f 'openssl ocsp'
umount -R /mnt/lfs
```

Treat a target that is still mounted at the end as a failed run, not a
successful one: sync before unmounting, and do not reboot out from under it.

**You want to start over from nothing**
Drop `--resume` and name the same target. That erases it and rebuilds.

## 10. Requirements

- Linux, **x86_64**, running as root. The build is `x86_64-lfs-linux-gnu`; on
  ARM64 or RISC-V there is nothing to fall back to, so this is a hard
  requirement rather than a preference.
- A build host with a working C toolchain, `make`, `curl`, and the
  package manager tables for your distribution (apt-get, dnf, pacman, zypper,
  apk, xbps-install, emerge). The installer installs what it can via your
  package manager; if a tool is still missing afterwards it stops and names it.
- Roughly 20 GB free on the target, plus room for the sources.
- BIOS or UEFI firmware. For a takeover install, **Secure Boot must be off**;
  see "What it refuses to touch" in section 2.
- About 1.5 GB of free RAM per parallel job, capped at your CPU count. The
  installer sizes its own job count from `MemAvailable`; override it with
  `LFS_JOBS` if you want something else. An 8 GB machine builds at 4-5 jobs,
  which is a few hours rather than all night.

  If you run at an unusual job count, the real validation used `LFS_JOBS=5` on
  6 vCPU and 8 GB, and `LFS_JOBS=4` on the same VM. Both completed the full 110
  packages. The default computation lands in that range.
- The `sources` stage fetches up to 8 tarballs at once. Change that with
  `LFS_FETCH_JOBS`, and point it at a local mirror with `LFS_DOWNLOAD_BASE`
  (useful for an offline re-run or a faster host); the default base is the
  LFS.org 13.1-systemd download directory.
- Network access to the package mirrors and source hosts.
- Hours of patience, and a serial console or a way back in if the bootloader
  step goes wrong.

The `apt-get` path has been exercised end to end against a real build, on both
BIOS and UEFI firmware. The other package tables are implemented but unproven;
treat a first run on a non-Debian-family host as experimental.
