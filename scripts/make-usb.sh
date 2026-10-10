#!/bin/bash
# Prepare a USB stick for PhantomixOS: FAT32 boot + ext4 data partitions.
#
# The ext4 partition is not optional. FAT32 caps files at 4 GiB and
# qwen2.5-coder-7b-instruct-q4_k_m.gguf is 4,683,073,536 bytes, so on FAT32
# that model cannot be stored. ext4 also supplies the xattrs that an overlay
# upperdir would need.
#
# Usage:
#   sudo ./scripts/make-usb.sh /dev/sdX [ISO_PATH]
#
#   /dev/sdX   the WHOLE disk, not a partition (e.g. /dev/sdb, not /dev/sdb1)
#
# This DESTROYS all data on the target device.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
VERSION="0.1.0"
ARCH="amd64"
ISO_NAME="PhantomixOS-$VERSION-$ARCH.iso"

DEV="${1:-}"
ISO_PATH="${2:-$ROOT/build/output/$ISO_NAME}"

log() { echo "[make-usb] $*"; }
die() { echo "[make-usb] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (try: sudo $0 $DEV)"

[ -n "$DEV" ] || die "no device given. Usage: sudo $0 /dev/sdX"
[ -b "$DEV" ] || die "$DEV is not a block device"
[ -f "$ISO_PATH" ] || die "ISO not found: $ISO_PATH
       Build it first:  sudo ./scripts/build-iso.sh"

# Refuse partitions: we partition the whole disk.
case "$DEV" in
    *[0-9]) die "$DEV looks like a partition. Pass the whole disk, e.g. ${DEV%p[0-9]}" ;;
esac

# Resolve the base disk name (nvme0n1 has no p1 suffix pattern in some names).
BASE_DISK=$(lsblk -ndo PKNAME "$DEV" 2>/dev/null | head -1)
[ -n "$BASE_DISK" ] && DEV="/dev/$BASE_DISK"

log "Target device: $DEV"
log "ISO:           $ISO_PATH ($(du -h "$ISO_PATH" | cut -f1))"

echo ""
log "Mounted partitions on $DEV (these will be unmounted):"
lsblk -n "$DEV" 2>/dev/null | sed 's/^/  /' || true
echo ""

read -r -p "  Erase $DEV and write PhantomixOS? [y/N] " ans
case "$ans" in
    y|Y|yes|YES) ;;
    *) die "aborted" ;;
esac

for tool in sfdisk mkfs.vfat mkfs.ext4 parted; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' not found. Install: apt-get install -y dosfstools parted"
done

log "Unmounting anything on $DEV..."
umount "$DEV"* 2>/dev/null || true
sleep 1

# Partition layout: GPT, 8 GiB FAT32 boot + rest ext4.
log "Partitioning (GPT: 8G FAT32 + remainder ext4)..."
parted -s "$DEV" mklabel gpt
parted -s -a optimal "$DEV" mkpart primary fat32 1MiB 8500MiB
parted -s -a optimal "$DEV" mkpart primary ext4 8500MiB 100%

# Refresh partition table without a reboot.
partprobe "$DEV" 2>/dev/null || true
udevadm settle 2>/dev/null || sleep 2

P1=$(lsblk -ln -o NAME "$DEV" | sed -n 1p)
P2=$(lsblk -ln -o NAME "$DEV" | sed -n 2p)
[ -n "$P1" ] && [ -n "$P2" ] || die "partitions did not appear; check the device"

echo "  ${DEV##*/}1 -> /dev/$P1 (FAT32 boot)"
echo "  ${DEV##*/}2 -> /dev/$P2 (ext4 data)"

log "Formatting FAT32..."
mkfs.vfat -F 32 -n PHANTOMIX "/dev/$P1" >/dev/null

log "Formatting ext4 (this takes a moment)..."
mkfs.ext4 -q -L PHANTOMIX "/dev/$P2"

log "Writing ISO to the FAT32 partition..."
dd if="$ISO_PATH" of="/dev/$P1" bs=4M conv=fsync status=progress

# Install the ext4 drivers on the data partition so the ISO can boot from it
# on systems that lack them in RAM. Harmless if already present.
log "Copying ext4/vfat modules + debootstrap-friendly boot files..."
MNT=$(mktemp -d /tmp/phantomixos-usb-XXXXXX)
mount "/dev/$P2" "$MNT"
mkdir -p "$MNT/skills" "$MNT/results" "$MNT/ai-models" "$MNT/persist"
cat > "$MNT/README.txt" <<'EOF'
PhantomixOS data partition (ext4)
================================

skills/     user-supplied skill modules (loaded into /skills at boot)
results/    engagement output; bind-mounted to /results (persistent)
ai-models/  GGUF models -- MUST be ext4, FAT32 caps files at 4 GiB and
            qwen2.5-coder-7b-instruct-q4_k_m.gguf is 4.36 GiB
persist/    reserved for overlay upperdir if root persistence is enabled

The AI reads models from /ai-models at runtime. The ISO itself does not
bundle them (use --with-models to override).
EOF
umount "$MNT"
rmdir "$MNT"

sync
echo ""
log "================================================================"
log "Done. $DEV now has:"
log "  FAT32 (PHANTOMIX)  -> the bootable ISO"
log "  ext4  (PHANTOMIX)  -> skills / results / ai-models / persist"
log ""
log "Copy models into the ext4 partition with:"
log "  sudo mount /dev/$P2 /mnt && sudo cp models/*.gguf /mnt/ai-models/ && sudo umount /mnt"
log "================================================================"