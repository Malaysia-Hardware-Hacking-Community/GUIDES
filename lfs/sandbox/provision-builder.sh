#!/usr/bin/env bash
# Create the throwaway lfs-builder VM from the pristine seed image.
# Usage: bash lfs/provision-builder.sh
set -euo pipefail
VM=lfs-builder
SEED="${HOME}/vms/ubuntu-24.04-server-cloudimg-amd64.img"
BOOT="${HOME}/vms/lfs-builder.qcow2"
LFS_DISK="${HOME}/vms/lfs-builder-lfs.qcow2"
if virsh -c qemu:///session list --all | grep -q " ${VM} "; then
    echo "$VM already exists" >&2; exit 1
fi
[ -f "$SEED" ] || { echo "seed missing: $SEED" >&2; exit 1; }
qemu-img create -f qcow2 -b "$SEED" -F qcow2 "$BOOT" 20G
qemu-img create -f qcow2 "$LFS_DISK" 128G
echo 'change-me-lfs' > /tmp/lfs-rootpw
/usr/bin/python3 /usr/bin/virt-install \
    --connect qemu:///session --name "$VM" --memory 10240 --vcpus 6 \
    --disk path="$BOOT",format=qcow2,bus=virtio \
    --disk path="$LFS_DISK",format=qcow2,bus=virtio \
    --network user,model=virtio \
    --os-variant ubuntu24.04 --import --noautoconsole \
    --cloud-init root-password-file=/tmp/lfs-rootpw
rm -f /tmp/lfs-rootpw
echo "PROVISIONED $VM"
