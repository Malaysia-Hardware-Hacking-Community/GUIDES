#!/usr/bin/env bash
# Task 13: move the validated LFS disk from lfs-builder onto ubuntu-sandbox.
#
# The LFS disk was booted and validated on lfs-builder as vdb. It is attached
# to ubuntu-sandbox as vdb as well, alongside the sandbox's own vda Ubuntu, and
# the BIOS boot order is set per-device (vdb order 1, vda order 2) so LFS is the
# default and "Ubuntu (rescue)" remains reachable from the grub menu.
#
# NOT automatic: every step mutates VM state and the snapshot/convert pair is
# slow and space-hungry. Run the steps by hand, or with --yes to run them all.
#
# Note on libvirt: the boot order CANNOT be set with `virsh edit`. Per-device
# <boot order> is the only thing that changes the SeaBIOS order, and libvirt
# rejects it alongside any os-level <boot> element -- `virsh edit` always writes
# one of the two, so it cannot express "vdb first" at all. This script rewrites
# the XML directly.
set -euo pipefail

SESSION=qemu:///session
LFS_SRC=${LFS_SRC:-/home/gluppler/vms/lfs-builder-lfs.qcow2}
LFS_DST=${LFS_DST:-/home/gluppler/vms/ubuntu-sandbox-lfs.qcow2}
DOMAIN=ubuntu-sandbox
SNAPSHOT=pre-lfs-swap

say() { printf '\n=== %s\n' "$*"; }
virsh_() { timeout 60 virsh -c "$SESSION" "$@"; }
need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
need virsh
need qemu-img

for d in "$LFS_SRC"; do
    [ -f "$d" ] || { echo "missing $d -- run the builder build first" >&2; exit 1; }
done

if [ "${1:-}" != "--yes" ]; then
    cat <<EOF
This will:
  1. snapshot $DOMAIN as '$SNAPSHOT'          (rollback insurance)
  2. qemu-img convert $LFS_SRC -> $LFS_DST    (copy, source untouched)
  3. power off $DOMAIN
  4. attach $LFS_DST as vdb and make vdb the first boot device
Re-run with --yes to proceed.
EOF
    exit 0
fi

say "1/4 snapshot $DOMAIN as $SNAPSHOT"
virsh_ snapshot-create-as "$DOMAIN" "$SNAPSHOT" \
    --description "rollback insurance before LFS disk attach"
virsh_ snapshot-list "$DOMAIN"

say "2/4 convert the validated LFS disk"
if [ -e "$LFS_DST" ]; then
    echo "refusing to overwrite existing $LFS_DST" >&2
    exit 1
fi
qemu-img convert -f qcow2 -O qcow2 "$LFS_SRC" "$LFS_DST"
qemu-img info "$LFS_DST" | head -4

say "3/4 power off $DOMAIN"
virsh_ destroy "$DOMAIN"

say "4/4 attach vdb and set the BIOS boot order"
dump=$(mktemp)
virsh_ dumpxml "$DOMAIN" >"$dump"
/usr/bin/python3 - "$dump" "$LFS_DST" <<'PY'
import re, sys

path, disk = sys.argv[1], sys.argv[2]
xml = open(path).read()

# libvirt rejects per-device <boot order> next to any os-level <boot>.
xml = re.sub(r"\n\s*<boot dev='[^']*'/>", "", xml, count=1)

# vda keeps order 2; the LFS disk is the new vdb with order 1.
xml = re.sub(r"(<disk type='file' device='disk'>.*?)(</disk>)",
             r"\1  <boot order='2'/>\n    \2", xml, count=1, flags=re.S)

new = (f"    <disk type='file' device='disk'>\n"
       f"      <driver name='qemu' type='qcow2'/>\n"
       f"      <source file='{disk}'/>\n"
       f"      <target dev='vdb' bus='virtio'/>\n"
       f"      <boot order='1'/>\n"
       f"    </disk>\n")
if "<target dev='vdb'" in xml:
    sys.exit("vdb already present -- undefine first or edit by hand")
i = xml.index("</disk>") + len("</disk>")
open(path, "w").write(xml[:i] + "\n" + new.rstrip("\n") + xml[i:])
PY
virsh_ define "$dump"
rm -f "$dump"
virsh_ dumpxml "$DOMAIN" | grep -E "<target dev='vd|<boot order|<boot dev"

cat <<EOF

Next, from inside LFS (chroot or booted, with /dev/vda attached):
    bash lfs/make-rescue-entry.sh
which fills the 40_custom placeholders and runs grub-mkconfig. Then boot and
check BOTH entries: LFS by default, and "Ubuntu (rescue)" for the old Ubuntu.
EOF
