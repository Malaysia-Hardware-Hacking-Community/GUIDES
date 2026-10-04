# sandbox — the throwaway VM used to prove the build

Nothing in here is used at runtime, and nothing in here ships with the
installer. `installer.sh` builds LFS on whatever machine you run it on; these
scripts only set up and drive a disposable QEMU guest to test that it works.

They live here rather than beside `installer.sh` because a copy of the
installer must not come with a pile of VM orchestration attached to it.

```bash
bash sandbox/provision-builder.sh            # create the lfs-builder domain
bash sandbox/swap-to-sandbox.sh              # dry run
bash sandbox/swap-to-sandbox.sh --yes        # snapshot, convert, attach, set boot order
```

Everything here assumes `LIBVIRT_DEFAULT_URI=qemu:///session`. Use the session
URI, not `qemu:///system`: this is a per-user libvirt daemon and the system one
does not own these domains.

| File | What it does |
|------|--------------|
| `provision-builder.sh` | creates the `lfs-builder` domain: Ubuntu guest, 6 vCPU, serial console on ttyS0, and a spare disk to build onto |
| `swap-to-sandbox.sh` | snapshots the validated build, converts it, attaches it to the sandbox, and sets the firmware boot order |
| `make-rescue-entry.sh` | run from *inside* LFS: fills the `__UBUNTU_*__` placeholders in `/etc/grub.d/40_custom` and runs `grub-mkconfig` |
| `e2e-target-stage.sh` | exercises target selection and staging against a real spare disk |
| `console.py` | drives the guest over the serial console: login, send commands, capture, optionally power off |

## Two traps worth knowing before editing

**Do not undefine the domain's NVRAM.** `virsh undefine --nvram <domain>` on a
SeaBIOS machine is a well-known way to leave a domain that starts and then dies
in firmware, with the disk untouched and no obvious cause. The builder is BIOS,
not UEFI, and should not have an NVRAM store to begin with.

**LFS cannot be powered down from outside.** The kernel config has no
`CONFIG_ACPI_BUTTON`, so the ACPI power-button event is never delivered and
`virsh shutdown` hangs forever. `console.py` sends `systemctl poweroff` over the
serial console instead. Ubuntu does honour ACPI, so a sandbox's Ubuntu leg shuts
down normally — which is exactly the trap: it works on one leg and hangs on the
other.
