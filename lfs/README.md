# Linux From Scratch 13.1-systemd, in one file

`installer.sh` builds a complete, bootable LFS 13.1-systemd system from the
LFS book's own build instructions. It is one file: copy it anywhere, run it as
root, and it installs a system with its own kernel, its own GRUB, and its own
userspace.

```bash
sudo ./installer.sh --plan     # print every command, change nothing
sudo ./installer.sh            # do it
```

The package list is not hand-written. All 110 package build functions are
distilled from `book-13.1-nochunks.html` and compiled into the file itself, so
the build tracks the book rather than a transcription of it. See
[Regenerating the file](#regenerating-the-file) for how, and for exactly what
was changed relative to the book's literal text.

## Before you run it

This erases a disk. Read the plan output before running it for real — it lists
every command, including the ones that cannot be undone.

**Scope:** Linux **x86_64**, BIOS or UEFI, running as root, with network access.
The build is `x86_64-lfs-linux-gnu` from detection through fstab, so ARM64 and
RISC-V are out of scope rather than merely untested. See `MANUAL.md` section 10.

- **Default is `takeover`.** The target disk becomes the LFS system and the
  machine boots into it. The whole disk is erased.
- **`--mode side-by-side`** keeps the current OS bootable and adds LFS as a
  GRUB menuentry (or a UEFI entry). An existing partition table is never touched.
  The target partition must be on a GPT disk: the boot entry identifies the root
  by `PARTUUID`, and MBR has none. The generated entry has been booted to a
  login prompt on both firmwares under QEMU — SeaBIOS/i386-pc and OVMF — with
  `root=PARTUUID=` resolved on each. No real hardware has been exercised.

A BIOS whole-disk target gets a GPT table with a 2 MiB unformatted `bios_grub`
partition for GRUB to embed into, and the ext4 filesystem as partition 2.
Without that first partition `grub-install` cannot embed, and the build fails
in its last stage after everything else succeeded.

A UEFI whole-disk target gets a 512 MiB FAT32 EFI System partition as
partition 1 (label `EFI`, mounted at `/mnt/lfs/boot/efi`) and the ext4
filesystem as partition 2. It carries the named `EFI/LFS` entry, the removable
`EFI/BOOT` fallback, and a UUID-keyed `/boot/efi` line in `fstab`; the firmware
boot entry is registered from the host, since the book builds no `efibootmgr`.

A takeover install refuses to start if **Secure Boot is enabled**: the GRUB
this build installs is unsigned, and no unsigned kernel boots under Secure
Boot. Use `--mode side-by-side` if you need to keep Secure Boot on.

- **The target is never guessed silently.** With no `--target`, the installer
  uses a disk only if there is *exactly one* unused one. Zero or several, and it
  prints the candidates and stops. With `--target`, it still refuses anything
  that looks like the running root filesystem.
- **Always run `--plan` first.** It is the same code path with mutation
  suppressed, so the plan is the run, minus the writes.

```
--target DEV        disk or partition to install onto. Optional; see above.
--mode MODE         takeover (default) or side-by-side
--firmware MODE     auto (default), bios, or uefi
--plan              print every command, change nothing
--resume            keep completed build stages and continue
--boot-id NAME      UEFI entry name under EFI/NAME. Default: LFS
--yes               do not ask for the confirmation (needed with no terminal)
```

Before it writes anything irreversible the installer prints what is about to
happen and waits for you to type `yes`. A plain `sudo ./installer.sh` on a
terminal therefore just works. With no terminal to prompt on — `nohup`, cron,
CI — it refuses and tells you to pass `--yes`.

The installer refuses to run on Omarchy, and refuses to touch a disk holding the
running system. Both checks happen before anything is written.

A full run is multi-hour at 6 vCPU. It checkpoints each stage, so `--resume`
continues where it stopped rather than starting over:

```bash
sudo ./installer.sh --plan
sudo ./installer.sh --yes                    # stage markers, ~20G of build
sudo ./installer.sh --yes --resume           # pick up after a failure
```

Per-package logs for the long chapter 8 are under `/mnt/lfs/buildlogs/`. The
whole run is appended to `/var/log/installer.log`. The installer does not
reboot; it tells you when the system is ready.

## Package managers

Detection is by package manager, not by distribution name. An unknown
distribution is fine as long as one of these is present; an unknown package
manager is refused rather than guessed at.

| Manager | Distribution | GRUB package (BIOS / UEFI) |
|---------|--------------|-----------------------------|
| `apt-get` | Debian, Ubuntu | `grub-pc` / `grub-efi-amd64`, plus `grub2-common`, which ships `/usr/sbin/grub-install` |
| `dnf` | Fedora, RHEL, Rocky | `grub2-pc` / `grub2-efi-x64` |
| `pacman` | Arch | `grub` / `grub` — one package ships both backends |
| `zypper` | openSUSE | `grub2-i386-pc` / `grub2-x86_64-efi` |
| `apk` | Alpine | `grub` / `grub-efi` |
| `xbps-install` | Void | `grub` / `grub` |
| `emerge` | Gentoo | `sys-boot/grub` / `sys-boot/grub` |

The table declares both firmware variants and the detected firmware picks one.
Getting this wrong is the difference between a build that boots and one that
dies at `grub-install` after an hour of compiling, with the error buried in a
log inside the target.

Every table also carries `parted`, because target selection creates the
partition table, the partitions, and the GPT flags (`bios_grub`, `esp`) with
it; nothing else in the script can write those flags. `deps_verify` checks for
the binaries the script actually calls, so a table with a typo fails there with
one clear list instead of part-way into partitioning.

**Only the `apt-get` path has been built and booted end to end.** The other six
tables are implemented and unit-tested but unproven on real hardware. `apk` is
the weakest of them, and not because of package names: every other family is
glibc, and stage 4's cross toolchain links against the *host* libc. A musl host
needs a gcompat shim there, and that cannot be verified from a table — it is a
best effort until someone runs it on Alpine.

## Build stages

Parallelism is sized from `MemAvailable` (about 1.5 GB per job) and capped at
`nproc`; `LFS_JOBS=n` overrides it. Chapter 8 is the long pole: 80 packages on
six cores is a few hours, and an 8 GB machine runs four jobs at a time rather
than swapping itself to death.

Partitioning, formatting and mounting are **not** a build stage. That is the
destructive part, so it happens earlier, behind the safety gate and the `--plan`
preview. After it, the build is eight checkpointed stages. Each writes
`.stages/<name>.done` on success.

| Stage | Book | What it does |
|-------|------|--------------|
| `sources` | ch3 | download every tarball, verify md5. A wrong checksum aborts here rather than half-way through. Fetches retry on any error, not just the transient few `curl --retry` covers by default — a throttled connection is retried rather than reported as a dead URL |
| `lfsusr` | ch5-6 | the `$LFS` skeleton, and the unprivileged `lfs` user every later stage builds as |
| `toolchain` | ch5 | cross binutils, cross gcc, kernel headers, glibc, target libstdc++ |
| `temptools` | ch5-6 | native binutils and gcc, then make, bison, flex, texinfo, perl, xz |
| `chroot_tools` | ch7 | chroot preparation and its checks: sed, file, findutils, gawk, gzip, tar |
| `ch8` | ch8 | 80 checkpointed packages, per-package logs |
| `sysconfig` | ch9 | fstab, ld.so.conf, locales, tzdata, os-release, root password |
| `bootable` | ch10 | kernel 7.1.8, `grub-install`, boot configuration |

Chapter 8 is checkpointed per package (`.stages/ch8-pkgs/`), so a failure late
in the chapter does not restart glibc and everything after it.

`--resume` is opt-in. Without it, stage checkpoints are deliberately cleared and
the build starts over.

There is no public flag to run a single stage. `lfs_build` takes one internally,
and the one-file CLI deliberately does not expose it: re-running `bootable` re-runs
the whole kernel build anyway, and the other stages depend on the toolchain
stages before them, so "just run stage 7" is rarely the question you actually
have. To resume a failed run, use `--resume`.

## What's in this directory

Only `installer.sh` is used at runtime. Everything else is either how the file
was produced or how it was tested.

| Path | What it is |
|------|------------|
| `installer.sh` | **the deliverable.** Self-contained; reads no sidecar files |
| `MANUAL.md` | how to run it, resume it, read its logs, and tell a good build from a broken one |
| `tests/` | 624 checks, all sourcing `installer.sh` |
| `regen/` | how `installer.sh` is assembled from `regen/lib/` + the book. Not runtime |
| `sandbox/` | the throwaway VM used to prove the build. Not runtime |
| `tools/` | the book distiller and renderer, plus their own tests |
| `book-13.1-nochunks.html` | the book, as the source of truth for the build functions |
| `VERIFY.txt` | raw serial captures: LFS boot, Ubuntu rescue boot, `neofetch` |
| `grub.cfg.ref` | the real generated `grub.cfg`, captured from the VM |
| `kernel.config-7.1.8` | the built kernel's real `.config`, captured from the VM |
| `PROGRESS.md` | the running log: every fix, dead end, and trap hit along the way |

The `installer.sh` header is generated by splicing `regen/lib/*.sh` together
and rewriting only the seams: sourcing, cross-process calls, and the package
tables. The book section is emitted in between two marker comments, and every
build child is handed it from there: those children start with `env -i` and have
no way to find it themselves, so the parent writes it to a world-readable temp
file and passes the path. Not a sidecar — a file created per package and removed
after — and not stdin, because a child that drops privileges to `lfs` cannot
reopen a root-owned pipe through `/proc/self/fd`.

## Regenerating the file

```bash
python3 regen/assemble.py     # rewrites installer.sh in place
```

It is mechanical and it is asserted. The assembler fails rather than emitting a
plausible-looking file if the distiller's output changes shape, if a stage list
names a function that is not there, or if a splice seam is not found. It prints
what it wrote:

```
book: 110 packages across 4 stages (110 functions, 0 not in a stage list)
wrote installer.sh: 6211 lines, 262402 bytes
```

To change the package list, edit `book-13.1-nochunks.html` or `regen/lib/deps.sh`
and re-run. Never hand-edit anything inside the book section of
`installer.sh`; it is overwritten on every assembly.

### What deviates from the book, and why

Each of these is a deviation, not an optimisation. The full list is in the
generated section's header comment in `installer.sh`.

- `exec /bin/bash --login` is dropped (8.39.1 Bash). `exec` replaces the driving
  shell, so run non-interactively it takes the whole build down with "script
  file read error: Bad file descriptor". It is a convenience for a human at an
  interactive prompt.
- `bash tests/run.sh` is dropped (8.81.1 Util-linux). The book itself puts it
  after booting the finished system; in the chroot it refuses to start.
- `PAGE=<paper_size> ./configure ...` keeps the command and drops the
  placeholder (8.64.1 Groff). Taken literally, bash reads the rest of the line
  as a stdin redirect from a file named `paper_size`.
- A bare `./configure ...` or `make ...` line ending in an ellipsis is the book's
  prose placeholder, not a command, and is dropped (8.23.1 GMP).
- `systemctl` calls and prerequisite probes gain `|| true` in the chroot: there
  is no running init and no tty there.
- Meson test suites gain a non-fatal tail; three are known to fail in a chroot,
  and the book says so.
- The kernel is not in the book section. Chapter 10 is built separately, because
  it needs different options than the book's prose describes.

## Testing

No pytest, no dependencies. Each suite sources the real installer.

```bash
bash tests/run-all.sh      # all seven suites, 624 checks
```

| Suite | Checks | What it covers |
|-------|--------|----------------|
| `test_common.sh` | 42 | the `run`/`runsh` seam, logging, dry-run, error propagation, the confirmation gate |
| `test_detect.sh` | 55 | distribution, firmware, and package-manager detection against `tests/fixtures/` |
| `test_pkgmgr.sh` | 161 | all seven package tables, every manager, dependency resolution, verified distro names |
| `test_target.sh` | 82 | target selection, the refusal rules, ordering guarantees, `--resume` reuse, real UEFI loopback layout |
| `test_boot.sh` | 94 | BIOS and UEFI install paths, GRUB drop-in correctness, NVRAM registration |
| `test_build.sh` | 23 | source-fetch parallelism and failure aggregation, per-package checkpoints for stages 04/05/06, non-resume clearing, single-pass hashing, unverifiable files not fetched |
| `test_single.sh` | 167 | the merge itself: no stale references, the book section, dispatch, the child's environment, UEFI wiring, a full `--plan` |

`test_single.sh` is the one that keeps the single-file promise honest. It checks
that the assembler left no reference to a removed file, that `book_emit`
reproduces the in-file book section byte for byte, that every name in a stage
list has a matching function, that sourcing does not re-enable `set -u`, and
that `--internal build-one` runs a named build function and refuses anything
that is not one.

To confirm a test actually bites, break the subject and watch it fail — that is
how the `set -u` leak and the `STAGE5` guard were both found.

The distiller and renderer have their own standalone tests:

```bash
cd tools && python3 test_distill.py     # 16/16
cd tools && python3 test_render.py      # 18/18
```

The `__main__` block at the bottom of each test file is what makes those
commands real. Without it they define the test functions, run nothing, and exit
0. Keep that block last in the file: it introspects `globals()` at import time,
so a test added below it is silently skipped.

## Build notes

These cost real time to work out and are still the first things to break.

### A generated `.bashrc` cannot call the installer's functions

`build_stage_03_lfsusr` writes `/home/lfs/.bashrc`, the only thing the `lfs`
user's login shell has. It contained `MAKEFLAGS="-j$(lfs_job_count)"` — but
`lfs_job_count` is a function of the installer, and a login shell running that
file has never heard of it. The command failed, the count expanded to nothing,
and `MAKEFLAGS` became a bare `-j`, which GNU make reads as *unlimited*
parallelism. The memory cap meant to stop an 8 GB build swapping itself to
death inverted into the one setting that guarantees it. It sat in a file no
test read.

The rule: a count substituted into a generated file has to be resolved in the
shell doing the generating, not left as a command substitution for a shell that
does not have the function. `tests/test_single.sh` §7 generates the same
heredocs into a temp dir and sources them with `env -i`, which is what caught
it.

### `--plan` has to survive a machine with nothing installed

The documented first command is `sudo ./installer.sh --plan`, run before
anything exists on a fresh laptop. Three things broke that specifically:
`deps_verify` called `die()`, which exits the whole script instead of reporting;
`ESP` was only assigned outside the dry-run branch, so the plan printed
"would mount the ESP at ,"; and the self-copy step tried to `install` into a
directory that a preview never created. Each one aborted the preview with an
error about the preview itself. A preview is run *deliberately* — it must always
finish and describe, never gate.

### `--yes` used to skip a prompt that did not exist

The help text said `--yes` skipped the confirmation, and the README repeated it.
There was no confirmation: `confirm_irreversible` only ever checked an
environment variable and died, so the documented bare `sudo ./installer.sh`
could never complete — you had to know about `LFS_I_UNDERSTAND`. There is now a
real prompt for terminals (`tests/test_common.sh` §6b drives it through a
pty), and the no-terminal refusal names `--yes`.

### LFS cannot be powered down from outside

The kernel config has no `CONFIG_ACPI_BUTTON`, so the ACPI power-button event is
never delivered and `virsh shutdown` hangs forever. Use `systemctl poweroff` from
the console.

### Use `systemctl --version`, not `systemd --version`

Upstream installs the binary at `/usr/lib/systemd/systemd` with `/sbin/init`
symlinked to it, and there is no `/usr/bin/systemd`, so the latter is always
"command not found" even when systemd is running correctly as PID 1.

### SeaBIOS ignores `<source index>`

Index orders the device nodes, not the firmware boot order. The only thing that
changes the firmware order is a per-device `<boot order>`, and libvirt refuses
that alongside any `os`-level `<boot>` element:

```
error: unsupported configuration: per-device boot elements cannot be used together with os/boot elements
```

So: delete the `<boot dev='hd'/>` inside `<os>`, and give each disk its own
`<boot order>`. `virsh edit` cannot express this, because it always writes one
of the two forms — edit the XML directly. `sandbox/swap-to-sandbox.sh` does this
in a small Python block, with the reason written next to it.

### The serial console is baked in at `grub-install` time

Three things are configured for ttyS0, and the order matters:

- `console=tty0 console=ttyS0,115200n8` on the kernel command line. Without a
  `console=` the kernel writes to VGA and a serial capture begins mid-flight at
  the getty prompt, with no GRUB menu and no kernel messages. Without it you
  cannot tell a good boot from a boot to the wrong OS.
- `GRUB_TERMINAL="serial console"` so the menu itself is visible.
- `GRUB_SERIAL_COMMAND` must be set *before* `grub-install`. The serial terminal
  is embedded into `core.img` at install time; a later `grub-mkconfig` cannot add
  it.

`GRUB_CMDLINE_LINUX` deliberately carries only the `console=` settings. `10_linux`
already prepends `root=${GRUB_DEVICE} ro` from `grub-probe`, so also setting
`root=` there produced a doubled `root=` — harmless, but two independent sources
of the root device can drift apart.

### The rescue entry needs two UUIDs, not one

`sandbox/make-rescue-entry.sh` fills the `__UBUNTU_*__` placeholders in
`/etc/grub.d/40_custom` and runs `grub-mkconfig`, adding an `Ubuntu (rescue)`
menuentry for the old OS:

```bash
bash sandbox/make-rescue-entry.sh
# RESCUE-ENTRY-OK boot_uuid=... root_uuid=... kernel=/vmlinuz-6.8.0-142-generic ...
```

Ubuntu 24.04 keeps `/boot` as its own partition, so the kernel and the root
filesystem live on different filesystems. A single `search` cannot satisfy both:
`__UBUNTU_BOOT_UUID__` is used by `search --set=root` so GRUB can load the kernel
and initrd, and `__UBUNTU_ROOT_UUID__` is passed to the kernel as `root=UUID=`.
The script scans every partition for a `vmlinux-*` and fails loudly if any
placeholder survives the `sed`, because an unresolved `search` yields a menu entry
that cannot boot.

To boot it once for testing, use `grub-reboot "Ubuntu (rescue)"` rather than
arrow keys — `GRUB_TIMEOUT` is 5s, too tight to navigate reliably over a serial
console. `next_entry` in `grubenv` is one-shot, so the next boot returns to LFS.

## The proof

`VERIFY.txt` holds the raw serial captures. Both firmware modes are proven
standalone, each booted with only the built disk attached, so the disk
enumerates as `/dev/vda` and the boot cannot be relying on the device name the
build host happened to use.

BIOS, built on `vdb`:

- GRUB menu, then `[ 0.000000] Linux version 7.1.8`
- systemd reaching `Multi-User System`, zero failed units
- `uname -r` = `7.1.8`
- `systemctl --version` first line = `systemd 261 (261.2)`
- `ip -brief address` shows a DHCP lease
- `neofetch` with the full artifact block
- `echo LFS-BOOT-OK`

UEFI, built on `vdb`, booted two ways:

- registered NVRAM entry `Boot000B "LFS"` loading `/EFI/LFS/grubx64.efi`
- factory NVRAM, no registered entry, booting the removable fallback
  `/EFI/BOOT/BOOTX64.EFI`
- either way: `root=PARTUUID=d4721651-...` on the command line, `EXT4-fs
  (vda2)` mounted, `/boot/efi` on `vda1`, `Multi-User System`, zero failed
  units, `systemd 261 (261.2)`, GCC `16.2.0`, Bash `5.3.0`, DHCP lease, and
  `echo LFS-UEFI-BOOT-OK`

The UEFI command line is `root=PARTUUID=`, not `root=UUID=`, and that is a
measured choice rather than a stylistic one. Both were tried on the real
target. A device path dies when the disk moves. `root=UUID=` with the correct
filesystem UUID — read back with `blkid` from inside the guest, so it was
genuinely right — panicked on this kernel with `VFS: Cannot open root device`,
never opening the superblock. `root=PARTUUID=` boots, verified on the UEFI path
and required on both. The installer now writes it and refuses to finish if any
device-path or UUID root survives in `grub.cfg`.

The build toolchain is also verified *from inside* the built UEFI root
filesystem, as root: `tools/test_render.py` 18/18, and `test_common.sh` 42,
`test_detect.sh` 55, `test_pkgmgr.sh` 161, all passing. `test_target.sh` did not
complete there because its real-partition section needs `parted`, which the
target does not have installed; that same section passes on the Ubuntu build
host. Its skip guard now names that requirement, so it skips and says why
instead of failing with messages about type GUIDs that pointed the wrong way.

`kernel.config-7.1.8` replaced the hand-written reference symbol list once the
real config existed. The diff gate (every reference symbol must be `=y` in the
capture) was run first: 19/19 present and `=y`, 0 missing, 0 mismatched, against
1749 `CONFIG_` symbols in the real file.
