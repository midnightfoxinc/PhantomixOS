#!/bin/bash
# Verify the PhantomixOS ISO: checksum, structure, optional QEMU boot smoke test.
#
# Usage:
#   ./scripts/verify-iso.sh [ISO_PATH] [--vm-test] [--boot-timeout SECONDS]
#
# Bug fixed: the previous version read the ISO path from $1 unconditionally, so
# `./verify-iso.sh --vm-test` tried to verify a file literally named
# "--vm-test" and reported "[!] ISO not found at --vm-test".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$ROOT/build/output"
VERSION="0.1.0"
ARCH="amd64"
ISO_NAME="PhantomixOS-$VERSION-$ARCH.iso"

ISO_PATH=""
VM_TEST=0
BOOT_TIMEOUT=90

for arg in "$@"; do
    case "$arg" in
        --vm-test)          VM_TEST=1 ;;
        --boot-timeout=*)   BOOT_TIMEOUT="${arg#*=}" ;;
        --boot-timeout)     shift; BOOT_TIMEOUT="${1:-90}" ;;
        -h|--help)
            echo "Usage: $0 [ISO_PATH] [--vm-test] [--boot-timeout SECONDS]"
            exit 0 ;;
        -*)                 echo "Unknown option: $arg" >&2; exit 2 ;;
        *)                  ISO_PATH="$arg" ;;
    esac
done

# Fall back to the default build output
if [ -z "$ISO_PATH" ]; then
    ISO_PATH="$OUTPUT_DIR/$ISO_NAME"
fi

log() { echo "[verify] $*"; }

log "=== Verifying PhantomixOS ==="

if [ ! -f "$ISO_PATH" ]; then
    log "ISO not found: $ISO_PATH"
    log ""
    log "Available .iso files under build/ and output/:"
    find "$ROOT" -maxdepth 3 -name '*.iso' -not -name '*.iso.tmp' 2>/dev/null \
        -exec ls -lh {} \; | sed 's/^/  /'
    log ""
    log "Nothing built yet? Run:  sudo ./scripts/build-iso.sh"
    exit 1
fi

log "ISO: $ISO_PATH"
log "Size: $(du -h "$ISO_PATH" | cut -f1)"

# ---- 1. Checksum ----
log ""
log "[1/3] SHA256 verification"
CHECKSUM_FILE="$(dirname "$ISO_PATH")/checksums-sha256.txt"
if [ -f "$CHECKSUM_FILE" ]; then
    if ( cd "$(dirname "$ISO_PATH")" && sha256sum -c "$(basename "$CHECKSUM_FILE")" 2>&1 ); then
        log "  checksum matches recorded value"
    else
        log "  WARNING: checksum MISMATCH (ISO may be corrupt)"
    fi
else
    log "  no checksum file; recording current value"
    ( cd "$(dirname "$ISO_PATH")" && sha256sum "$(basename "$ISO_PATH")" > checksums-sha256.txt )
fi
sed 's/^/  /' "$CHECKSUM_FILE" 2>/dev/null || true

# ---- 2. ISO structure ----
log ""
log "[2/3] ISO structure"
if command -v xorriso >/dev/null 2>&1; then
    log "  boot files:"
    xorriso -indev "$ISO_PATH" -find /boot -maxdepth 2 2>/dev/null \
        | grep -v '^$' | sed 's/^/    /' | head -15
    log "  live files:"
    xorriso -indev "$ISO_PATH" -find /live -maxdepth 2 2>/dev/null \
        | grep -v '^$' | sed 's/^/    /' | head -15

    # Confirm the two things GRUB cannot boot without
    for required in /boot/grub/grub.cfg /live/vmlinuz /live/initrd.img /live/filesystem.squashfs; do
        if xorriso -indev "$ISO_PATH" -find "$required" 2>/dev/null | grep -q "$required"; then
            log "  [ok] $required"
        else
            log "  [MISSING] $required  <-- ISO will not boot"
        fi
    done
else
    log "  xorriso not installed; skipping structure check"
fi

# ---- 3. Optional QEMU boot smoke test ----
if [ "$VM_TEST" -eq 1 ]; then
    log ""
    log "[3/3] QEMU boot smoke test (${BOOT_TIMEOUT}s)"

    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        log "  SKIPPED: qemu-system-x86_64 not installed"
        log "  Install with:  sudo apt-get install -y qemu-system-x86 qemu-utils"
        exit 0
    fi
    if ! [ -e /dev/kvm ]; then
        log "  NOTE: /dev/kvm absent; booting without KVM (slow but works)"
    fi

    LOGFILE=$(mktemp /tmp/phantomixos-boot-XXXXXX.log)
    # -cdrom (not -drive) so QEMU treats it as read-only optical media
    set +e
    timeout "$BOOT_TIMEOUT" qemu-system-x86_64 \
        -m 2048 -smp 2 \
        -enable-kvm 2>/dev/null || true \
        -cdrom "$ISO_PATH" \
        -boot d \
        -nographic -serial mon:stdio \
        -display none \
        -no-reboot \
        2>&1 | tee "$LOGFILE"
    set -e

    log "  captured $(wc -l < "$LOGFILE") lines of boot output"
    log ""
    log "  Signals to look for:"
    log "    - 'Loading Linux' / kernel version banner"
    log "    - '[PHANTOMIXOS-INIT] Starting PhantomixOS live environment'"
    log "    - '[PHANTOMIXOS-INIT] Scanned for PhantomixOS USB media'"
    log "    - the banner box from phantomixos-init"
    if grep -q "PHANTOMIXOS-INIT" "$LOGFILE"; then
        log "  [ok] phantomixos-init was reached"
    else
        log "  [warn] phantomixos-init not seen; inspect $LOGFILE"
        log "         (a timeout with no banner usually means GRUB or the"
        log "          kernel/initrd failed to load, not the init script)"
    fi
    log ""
    log "  Full boot log: $LOGFILE"
else
    log ""
    log "[3/3] Boot test skipped (pass --vm-test to run it)"
fi

log ""
log "=== Verification complete ==="