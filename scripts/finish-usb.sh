#!/bin/bash
# Finish the PhantomixOS USB: write the rebuilt ISO, install models, boot-test.
# Everything here needs root.
#
#   sudo ./scripts/finish-usb.sh [DEVICE] [MODELSET]
#
#   DEVICE    boot USB, default /dev/sdb
#   MODELSET  qwen-instruct (default) | coder | all
#
# The data partition is ~6.6 GiB and all four models total 8.8 GiB, so they do
# not all fit. qwen-instruct (4.5 GiB incl. its second shard) + the 24 MiB
# embedding model is the set that fits and is what MEMORY_BUDGET.md targets for
# 8 GB RAM. `all` requires enlarging the ext4 partition first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
DEV="${1:-/dev/sdb}"
MODELSET="${2:-qwen-instruct}"
ISO="$ROOT/build/output/PhantomixOS-0.1.0-amd64.iso"
LOG=/tmp/px-boot.log

log() { echo "[finish-usb] $*"; }
die() { echo "[finish-usb] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -f "$ISO" ] || die "ISO not built: $ISO"
[ -b "$DEV" ] || die "$DEV is not a block device"

P1="${DEV}1"; P2="${DEV}2"
[ -b "$P1" ] || die "$P1 not found - re-run make-usb.sh partitioning first"

log "Unmounting anything on $DEV..."
umount "$P1" 2>/dev/null || true
umount "$P2" 2>/dev/null || true
sync

log "Writing ISO to $P1 (1.2 GB, takes a minute)..."
dd if="$ISO" of="$P1" bs=4M conv=fsync status=progress

log ""
log "=== Verifying boot partition ==="
mkdir -p /tmp/px-verify
mount -o ro,loop "$P1" /tmp/px-verify
ls -la /tmp/px-verify/live/
ls -la /tmp/px-verify/boot/grub/grub.cfg
umount /tmp/px-verify && rmdir /tmp/px-verify

log ""
log "=== Installing models to $P2:/ai-models (set: $MODELSET) ==="
case "$MODELSET" in
    qwen-instruct)
        # Both shards: llama.cpp resolves shard 2 from shard 1 by naming
        # convention, so copying only one of the pair gives an unloadable model.
        MODELS=(
            "qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf"
            "qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf"
            "bge-small-en-v1.5-q4_k_m.gguf"
        )
        ;;
    coder)
        MODELS=(
            "qwen2.5-coder-7b-instruct-q4_k_m.gguf"
            "bge-small-en-v1.5-q4_k_m.gguf"
        )
        ;;
    all)
        MODELS=()
        while IFS= read -r f; do MODELS+=("$(basename "$f")"); done \
            < <(ls "$ROOT"/models/*.gguf)
        ;;
    *)
        die "unknown MODELSET '$MODELSET' (use qwen-instruct, coder, or all)"
        ;;
esac

for m in "${MODELS[@]}"; do
    [ -f "$ROOT/models/$m" ] || die "missing model: $ROOT/models/$m"
done
NEED=$(du -ch "$ROOT"/models/ "${MODELS[@]/#/$ROOT/models/}" 2>/dev/null | tail -1 | cut -f1 || echo 0)

if mountpoint -q /mnt; then umount /mnt; fi
mkdir -p /mnt
mount "$P2" /mnt
mkdir -p /mnt/skills /mnt/results /mnt/ai-models /mnt/persist

AVAIL_KB=$(df --output=avail -k /mnt | tail -1 | tr -d ' ')
NEED_KB=$(du -ck "$ROOT"/models/ "${MODELS[@]/#/$ROOT/models/}" 2>/dev/null | tail -1 | cut -f1)
log "  need $(( NEED_KB / 1024 )) MiB, have $(( AVAIL_KB / 1024 )) MiB"
if [ "$NEED_KB" -gt "$AVAIL_KB" ]; then
    umount /mnt
    die "not enough space on $P2 for model set '$MODELSET' (need $((NEED_KB/1024)) MiB, have $((AVAIL_KB/1024)) MiB). Try a different MODELSET."
fi

# rsync if available (resumable across the 4 GiB+ files), else cp
if command -v rsync >/dev/null 2>&1; then
    for m in "${MODELS[@]}"; do
        rsync -ah --info=progress2 --partial "$ROOT/models/$m" /mnt/ai-models/
    done
else
    for m in "${MODELS[@]}"; do
        cp "$ROOT/models/$m" /mnt/ai-models/
    done
fi
sync
log "Models on stick:"
ls -lh /mnt/ai-models/
df -h /mnt | tail -1
umount /mnt

log ""
log "=== Final blkid ==="
blkid "$P1" || true
blkid "$P2" || true

log ""
log "============================================================"
log "USB READY. Booting in QEMU (240s timeout)..."
log "============================================================"
: > "$LOG"
timeout 240 qemu-system-x86_64 \
    -m 4096 -smp 2 \
    -enable-kvm -cpu host \
    -drive file="$DEV",format=raw,if=virtio \
    -boot n -no-reboot \
    -display none \
    -serial file:"$LOG" \
    -monitor none
echo "QEMU exit: $?"

log ""
log "=== Boot log (last 60 lines) ==="
wc -c "$LOG"
tail -60 "$LOG"

log ""
log "=== KEY MILESTONES (grep) ==="
grep -nE "INITRAMFS|PHANTOMIXOS-INIT|login:|Failed|error" "$LOG" | head -40 || echo "  (no matching lines - see full log above)"