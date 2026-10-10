#!/bin/bash
# Pack the PhantomixOS initramfs into a GRUB-loadable initrd.img.
#
# Why we ship our own initrd instead of the kernel package's initrd.img:
# Debian's stock initramfs boots by mounting the block device named on the
# root= cmdline. Our root filesystem is a squashfs nested *inside* an ISO9660
# image, so there is no such device. The stock initrd therefore cannot bring
# up PhantomixOS no matter how the paths are spelled. (This is also why Debian's
# own ISO ships no /live tree -- it is an installer, not a live image. MX and
# Kali both ship live images and both solve this with their own boot initrd.)
#
# Ours is ~5 MB, brings up busybox + the 6 modules needed to read the ISO, and
# hands straight to /phantomixos-init in the squashfs.
#
# Usage: ./scripts/build-initramfs.sh
# Output: build/live/initrd.img

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
ROOTFS="$ROOT/build/rootfs"
# Output and staging paths default into build/, but are overridable so the
# initramfs can be rebuilt without root when build/ is owned by root (it is
# after any `sudo ./scripts/build-iso.sh`).
OUT="${INITRAMFS_OUT:-$ROOT/build/initrd.img}"
STAGE="${INITRAMFS_STAGE:-$ROOT/build/initramfs-stage}"

log() { echo "[initramfs] $*"; }

[ -d "$ROOTFS" ] || { log "ERROR: no rootfs at $ROOTFS — run build-rootfs.sh first"; exit 1; }
[ -x "$ROOTFS/bin/busybox" ] || { log "ERROR: busybox not found in rootfs"; exit 1; }

# The guest kernel must match the modules we ship, so take both from the rootfs.
KVER=$(ls "$ROOTFS/lib/modules" 2>/dev/null | head -1)
[ -n "$KVER" ] || { log "ERROR: no kernel modules in rootfs at $ROOTFS/lib/modules"; exit 1; }
MODSRC="$ROOTFS/lib/modules/$KVER"
log "using modules for kernel $KVER"

rm -rf "$STAGE"
mkdir -p "$STAGE"/{bin,sbin,proc,sys,dev/pts,newroot,cdrom,mnt,lib/modules}

# ---- busybox + its shared libraries ----
# busybox from Debian is dynamically linked, so it cannot run from a cpio
# archive alone -- the loader and its libs have to come along.
log "copying busybox and libraries"
cp "$ROOTFS/bin/busybox" "$STAGE/bin/busybox"

# Resolve deps by parsing ldd rather than hardcoding a list.
LDD_DEPS=$(ldd "$ROOTFS/bin/busybox" 2>/dev/null \
    | grep -oE '/[^ ]*\.so[^ ]*' | sort -u)

for lib in $LDD_DEPS; do
    [ -f "$lib" ] || continue
    # Preserve the path so the ELF interpreter's search still resolves.
    mkdir -p "$STAGE$(dirname "$lib")"
    cp -L "$lib" "$STAGE$lib"
done
log "  libraries: $(echo "$LDD_DEPS" | wc -l)"

# ---- applet symlinks ----
# busybox --list works fine without chroot, and chroot needs root.
log "creating applet symlinks"
for applet in $("$ROOTFS/bin/busybox" --list); do
    ln -sf /bin/busybox "$STAGE/bin/$applet"
done
# The initramfs PATH includes /sbin too, so mirror the applets there.
for applet in $(ls "$STAGE/bin"); do
    [ "$applet" = busybox ] && continue
    ln -sf /bin/busybox "$STAGE/sbin/$applet"
done
log "  applets: $(ls "$STAGE/bin" | wc -l)"

# ---- kernel modules ----
# Only what the boot path touches. fat/ext4/overlay are deliberately NOT
# included: /skills & co. are bind-mounted from the USB as vfat by
# phantomixos-init, in the real root, using the full module tree there.
#
# Dependencies are resolved from modules.dep rather than hand-listed. Loading
# sr_mod without scsi_mod.ko fails with a wall of "Unknown symbol scsi_*",
# and udf.ko without crc-itu-t.ko fails the same way -- so pull in the full
# transitive closure and let modprobe order the loads at boot.
MODULES="cdrom sr_mod loop isofs udf squashfs overlay sd_mod usb-storage ahci libata ata_piix virtio_pci virtio_blk virtio_scsi"

DEPFILE="$MODSRC/modules.dep"
[ -f "$DEPFILE" ] || { log "ERROR: modules.dep not found at $DEPFILE"; exit 1; }

STAGEMOD="$STAGE/lib/modules/$KVER"
mkdir -p "$STAGEMOD"

declare -A SEEN_MODS=()
LOAD_ORDER=()

# Depth-first: a module's dependencies are fully emitted (recursively) before
# the module itself. Flattening each module's dep list instead would inherit
# kmod's transitive ordering, which is not a valid symbol-resolution order --
# e.g. sr_mod's list has scsi_mod before scsi_common, yet scsi_mod imports
# scsi_normalize_sense from scsi_common and fails with "Unknown symbol"
# unless scsi_common is already resident.
copy_mod_rec() {
    local name="$1" line target src base
    [ -n "${SEEN_MODS[$name]:-}" ] && return 0
    SEEN_MODS[$name]=1

    line=$(grep -E "/${name}\.ko(\.[a-z0-9]+)?:" "$DEPFILE" 2>/dev/null | head -1)

    if [ -n "$line" ]; then
        # Recurse into each dependency before emitting anything ourselves.
        for base in ${line#*:}; do
            copy_mod_rec "$(basename "${base%%.ko*}")"
        done
        target="${line%%:*}"
    else
        # No modules.dep line: built into the kernel, or a leaf whose file we
        # still want if it happens to exist on disk.
        target=$(find "$MODSRC" -name "$name.ko*" -type f 2>/dev/null | head -1)
        [ -n "$target" ] && target="${target#$MODSRC/}"
    fi

    [ -n "$target" ] || { log "  warn: '$name' has no module file (built in?)"; return 0; }

    src="$MODSRC/$target"
    if [ -f "$src" ]; then
        mkdir -p "$STAGEMOD/$(dirname "$target")"
        cp "$src" "$STAGEMOD/$target"
        LOAD_ORDER+=("$target")
    fi
}

log "resolving kernel module dependencies"
for m in $MODULES; do
    copy_mod_rec "$m"
done

# Emit a flat, dependency-ordered load list. init insmods this directly
# instead of calling modprobe: Debian's busybox modprobe has no -d flag, so
# there is no way to point it at the staged tree, and it fails *silently*
# (exit 0, nothing loaded) when it cannot find the module.
: > "$STAGE/modules.load"
declare -A EMITTED=()
for f in "${LOAD_ORDER[@]}"; do
    [ -n "${EMITTED[$f]:-}" ] && continue
    EMITTED[$f]=1
    echo "$f" >> "$STAGE/modules.load"
done

COPIED=${#EMITTED[@]}
log "  modules staged: $COPIED (including dependencies)"
[ "$COPIED" -lt 6 ] && { log "ERROR: too few modules resolved -- boot will fail"; exit 1; }

# ---- init ----
cp "$ROOT/initramfs/init" "$STAGE/init"
chmod 0755 "$STAGE/init"

# ---- pack ----
mkdir -p "$(dirname "$OUT")"
log "packing cpio archive -> $OUT"
( cd "$STAGE" && find . -print0 \
    | cpio --null -o -H newc --quiet 2>/dev/null ) | gzip -9 > "$OUT"

log "initrd.img: $(du -h "$OUT" | cut -f1)"
log "(stock Debian initrd for comparison: $(du -h "$ROOTFS"/boot/initrd.img-* 2>/dev/null | head -1 | cut -f1))"

# Sanity: it must be a gzip'd newc cpio, or GRUB will refuse it.
if gzip -t "$OUT" 2>/dev/null; then
    log "  [ok] gzip integrity"
else
    log "  ERROR: output is not valid gzip"; exit 1
fi

log "=== initramfs build complete ==="