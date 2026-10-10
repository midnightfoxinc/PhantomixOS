#!/bin/bash
# Generate the PhantomixOS hybrid ISO (UEFI + legacy BIOS)
#
# Boot architecture (standard live-ISO layout, as used by MX Linux / Kali):
#   GRUB  ->  /live/vmlinuz  +  /live/initrd.img   (our initramfs)
#   /init finds the boot media, loop-mounts /live/filesystem.squashfs,
#   switch_roots into it and execs /phantomixos-init
#   ->  phantomixos-init mounts the USB data dirs, then exec /sbin/init
#
# There is no root= device anywhere in this chain: the root is a squashfs
# inside the ISO image, not a block device the kernel could mount itself.
#
# Usage: ./scripts/build-iso.sh
# Outputs: build/output/PhantomixOS-0.1.0-amd64.iso + checksums-sha256.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT/build"
ROOTFS_DIR="$BUILD_DIR/rootfs"
LIVE_DIR="$BUILD_DIR/live"
ISO_STAGE="$BUILD_DIR/iso"
OUTPUT_DIR="$BUILD_DIR/output"
MODEL_DIR="$ROOT/models"

ISO_NAME="PhantomixOS"
VERSION="0.1.0"
ARCH="amd64"
VOLID="PHANTOMIXOS"

log() { echo "[ISO] $*"; }

# ---- Preflight ----
for tool in mksquashfs grub-mkrescue sha256sum install cpio gzip; do
    command -v "$tool" >/dev/null 2>&1 || {
        log "ERROR: '$tool' not found (install build deps: sudo make setup-deps)"
        exit 1
    }
done
if [ ! -d "$ROOTFS_DIR" ]; then
    log "ERROR: rootfs not found at $ROOTFS_DIR — run 'sudo ./scripts/build-rootfs.sh' first"
    exit 1
fi

mkdir -p "$LIVE_DIR" "$ISO_STAGE" "$OUTPUT_DIR"

# ---- 1. Install boot scripts into the rootfs ----
# These live INSIDE the squashfs and run in the real root (post-pivot_root)
log "Installing boot scripts into rootfs..."
install -m 0755 "$ROOT/initramfs/boot/phantomixos-init" "$ROOTFS_DIR/phantomixos-init"
install -m 0755 "$ROOT/initramfs/scripts/phantomixos-ai-autostart" "$ROOTFS_DIR/usr/local/bin/phantomixos-ai-autostart"
install -m 0755 "$ROOT/initramfs/scripts/phantomixos-agent" "$ROOTFS_DIR/usr/local/bin/phantomixos-agent"
install -m 0755 "$ROOT/initramfs/scripts/phantomixos-skill-loader" "$ROOTFS_DIR/usr/local/bin/phantomixos-skill-loader"
install -m 0755 "$ROOT/initramfs/scripts/phantomixos-overlay-setup" "$ROOTFS_DIR/usr/local/bin/phantomixos-overlay-setup"

# Register the skill loader as a systemd oneshot so /skills is live at boot
mkdir -p "$ROOTFS_DIR/etc/systemd/system"
cat > "$ROOTFS_DIR/etc/systemd/system/phantomixos-skills.service" <<'EOF'
[Unit]
Description=PhantomixOS - Load skills from USB into PATH
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/phantomixos-skill-loader
RemainAfterExit=yes
# An absent USB stick means no skills, which is a normal state, not an error.
# Never let this unit block the boot.
SuccessExitStatus=0 1 2

[Install]
WantedBy=multi-user.target
EOF

ln -sf /etc/systemd/system/phantomixos-skills.service \
       "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/phantomixos-skills.service" 2>/dev/null || {
    mkdir -p "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants"
    ln -sf /etc/systemd/system/phantomixos-skills.service \
           "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/phantomixos-skills.service"
}

# ---- 2. Ensure a kernel exists in the rootfs ----
# We need the kernel IMAGE and its MODULES. We do NOT use the kernel's own
# initrd.img -- build-initramfs.sh packs ours instead.
log "Checking for kernel in rootfs..."
KERNEL_IN_ROOTFS=$(find "$ROOTFS_DIR/boot" -maxdepth 1 -name 'vmlinuz-*' -type f 2>/dev/null | sort | head -1)
if [ -z "$KERNEL_IN_ROOTFS" ]; then
    log "No kernel in rootfs — installing linux-image-amd64 inside chroot..."
    chroot "$ROOTFS_DIR" /bin/bash -c '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends linux-image-amd64
    '
else
    log "Found kernel: $(basename "$KERNEL_IN_ROOTFS")"
fi

# ---- 3. Install llama.cpp binaries into the rootfs ----
# These go INSIDE the squashfs (not just alongside it on the ISO) because the
# initramfs releases the boot media once it has handed over; only a bind mount
# of /live/models survives that, and 48 MB of binaries is cheap to carry.
LLAMA_BIN=""
[ -d "$MODEL_DIR/llama-binaries" ] && LLAMA_BIN="$MODEL_DIR/llama-binaries"
[ -z "$LLAMA_BIN" ] && [ -d "$BUILD_DIR/llama.cpp/build-phantomixos/bin" ] && \
    LLAMA_BIN="$BUILD_DIR/llama.cpp/build-phantomixos/bin"

if [ -n "$LLAMA_BIN" ] && [ -f "$LLAMA_BIN/llama-server" ]; then
    log "Installing llama.cpp binaries into rootfs..."
    install -m 0755 "$LLAMA_BIN"/llama-server "$ROOTFS_DIR/usr/local/bin/"
    [ -f "$LLAMA_BIN/llama-cli" ]   && install -m 0755 "$LLAMA_BIN/llama-cli"   "$ROOTFS_DIR/usr/local/bin/"
    [ -f "$LLAMA_BIN/llama-bench" ] && install -m 0755 "$LLAMA_BIN/llama-bench" "$ROOTFS_DIR/usr/local/bin/"
    log "  llama-server installed to /usr/local/bin ($(du -h "$ROOTFS_DIR/usr/local/bin/llama-server" | cut -f1))"
else
    log "WARNING: llama-server binary not found."
    log "         The AI stack will not start until you run:"
    log "           ./scripts/build-llamacpp.sh && sudo ./scripts/build-iso.sh"
fi

# ---- 4. Build our initramfs ----
# Must happen BEFORE the squashfs is built? No -- the initramfs lives outside
# the squashfs, on the ISO alongside the kernel. But it pulls busybox out of
# the rootfs, so it has to run before we mksquashfs and lock that tree up.
log "Building PhantomixOS initramfs..."
"$SCRIPT_DIR/build-initramfs.sh" || {
    log "ERROR: initramfs build failed"; exit 1;
}

# ---- 5. Build the squashfs ----
log "Building squashfs (zstd, level 5)..."
rm -f "$LIVE_DIR/filesystem.squashfs"
# NOTE: -Xdict-size is an *xz* option and zstd rejects it outright
# ("Unrecognised compressor option -Xdict-size"), aborting the build. For zstd
# the equivalent knob is -Xcompression-level (1..22, default 15).
mksquashfs "$ROOTFS_DIR" "$LIVE_DIR/filesystem.squashfs" \
    -noappend \
    -comp zstd \
    -Xcompression-level 5 \
    -b 1M \
    -no-progress \
    -processors "$(nproc)" \
    -e "proc/*" "sys/*" "dev/*" "run/*" "tmp/*" \
       "var/cache/apt/*" "var/lib/apt/lists/*" \
       "boot/vmlinuz-*" "boot/initrd.img-*" "boot/initramfs/*" \
       "var/log/*"
log "Squashfs size: $(du -h "$LIVE_DIR/filesystem.squashfs" | cut -f1)"

# ---- 6. Stage the ISO tree ----
# Layout follows Debian live convention so GRUB paths match:
#   /boot/grub/grub.cfg
#   /live/vmlinuz
#   /live/initrd.img
#   /live/filesystem.squashfs
log "Staging ISO tree..."
rm -rf "$ISO_STAGE"
mkdir -p "$ISO_STAGE"/{boot/grub,live}

# Pick exactly one kernel: a glob would expand to every kernel in the tree if
# more than one were ever installed, and cp would then fail on the extras.
KERNEL_IMG=$(find "$ROOTFS_DIR/boot" -maxdepth 1 -name 'vmlinuz-*' -type f 2>/dev/null | sort | head -1)
[ -n "$KERNEL_IMG" ] || { log "ERROR: no kernel image found in $ROOTFS_DIR/boot"; exit 1; }
cp "$KERNEL_IMG" "$ISO_STAGE/live/vmlinuz"
log "  kernel: $(basename "$KERNEL_IMG")"

# Our own initramfs, not the kernel package's.
cp "$BUILD_DIR/initrd.img" "$ISO_STAGE/live/initrd.img"
log "  initrd: $(du -h "$ISO_STAGE/live/initrd.img" | cut -f1)"

cp "$ROOT/initramfs/boot/grub/grub.cfg" "$ISO_STAGE/boot/grub/grub.cfg"
cp "$LIVE_DIR/filesystem.squashfs" "$ISO_STAGE/live/filesystem.squashfs"

# NOTE: llama.cpp binaries are installed INSIDE the squashfs at
# /usr/local/bin (step 3), not here. The initramfs releases the boot media
# after handing over, so anything that must stay reachable at runtime has to
# live in the rootfs. The only thing still staged from the ISO at runtime is
# /live/models, which the initramfs bind-mounts to /opt/phantomixos/models.

# Models are NOT bundled by default. Bundling all four is 8.8 GB, which makes
# the ISO unwritable to FAT32 (max file 4 GiB, and the ISO image itself would
# exceed what most tools will handle) and duplicates the whole point of the
# /ai-models partition on the USB stick.
#
# The AI stack reads models from /ai-models on the stick at runtime, which is
# the documented design. Pass --with-models to bundle anyway (e.g. for a
# single-file ISO on a large USB drive that supports UDF/exFAT).
BUNDLE_MODELS=0
for arg in "$@"; do
    case "$arg" in
        --with-models) BUNDLE_MODELS=1 ;;
        -h|--help)
            echo "Usage: $0 [--with-models]"
            echo "  --with-models  bundle the .gguf models into the ISO (adds ~8.8 GB)"
            exit 0 ;;
    esac
done

if [ "$BUNDLE_MODELS" -eq 1 ] && [ -d "$MODEL_DIR" ]; then
    mkdir -p "$ISO_STAGE/live/models"
    # glob *.gguf also picks up shard 2 of a split model (-00002-of-00002.gguf)
    if ls "$MODEL_DIR"/*.gguf >/dev/null 2>&1; then
        cp "$MODEL_DIR"/*.gguf "$ISO_STAGE/live/models/"
        log "  models staged: $(ls "$MODEL_DIR"/*.gguf | wc -l) file(s)"
    else
        log "  NOTE: no .gguf models found in $MODEL_DIR"
    fi
else
    log "  models: not bundled (read from /ai-models on the USB at runtime)"
    if [ "$BUNDLE_MODELS" -eq 0 ]; then
        log "           to bundle them: sudo $0 --with-models"
    fi
    mkdir -p "$ISO_STAGE/live/models"
fi

# Empty data dirs so the boot script has somewhere to bind-mount
mkdir -p "$ISO_STAGE/live"/{skills,results,ai-models,persist}

ls -lh "$ISO_STAGE/live/"
echo "---"
du -sh "$ISO_STAGE"

# ---- 7. Build the hybrid ISO with grub-mkrescue ----
log "Assembling hybrid ISO (UEFI + BIOS)..."
ISO_OUT="$OUTPUT_DIR/${ISO_NAME}-${VERSION}-${ARCH}.iso"
rm -f "$ISO_OUT"

# grub-mkrescue's --locales is picky: it wants the locale spelled exactly as
# the C library spells it, and Debian ships "en_US.utf8" (glibc normalises the
# codeset to lowercase), which GRUB 2.12 rejects with
#   error: cannot find locale `en_US.UTF-8'
# Probing first and degrading to a locale-less image avoids the whole class of
# problem -- a live ISO with an ASCII VGA console gains nothing from a UTF-8
# locale anyway.
GRUB_LOCALES=()
for loc in en_US.UTF-8 en_US.utf8; do
    if grub-mkrescue --locales="$loc" -o /dev/null "$ISO_STAGE" >/dev/null 2>&1; then
        GRUB_LOCALES=(--locales="$loc")
        log "Using GRUB locale: $loc"
        break
    fi
done
if [ "${#GRUB_LOCALES[@]}" -eq 0 ]; then
    log "No usable GRUB locale found; building without one (ASCII console)"
fi

# The DejaVu font gives GRUB a readable menu; fall back to the built-in font
# if the host does not ship it.
GRUB_FONT="/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
GRUB_FONT_ARGS=()
if [ -f "$GRUB_FONT" ]; then
    GRUB_FONT_ARGS=(--fonts="$GRUB_FONT")
else
    log "DejaVu font not found; GRUB will use its built-in font"
fi

if ! grub-mkrescue \
    -o "$ISO_OUT" \
    --volid "$VOLID" \
    "${GRUB_LOCALES[@]}" \
    "${GRUB_FONT_ARGS[@]}" \
    "$ISO_STAGE" 2>&1 | tail -20; then
    log "ERROR: grub-mkrescue failed"
    exit 1
fi

if [ ! -f "$ISO_OUT" ]; then
    log "ERROR: grub-mkrescue produced no ISO at $ISO_OUT"
    exit 1
fi

# ---- 8. Checksums ----
log "Generating SHA256 checksums..."
( cd "$OUTPUT_DIR" && sha256sum "${ISO_NAME}-${VERSION}-${ARCH}.iso" > checksums-sha256.txt )
cat "$OUTPUT_DIR/checksums-sha256.txt"

log "ISO size: $(du -h "$ISO_OUT" | cut -f1)"
log "Output:  $ISO_OUT"
log "=== ISO build complete ==="