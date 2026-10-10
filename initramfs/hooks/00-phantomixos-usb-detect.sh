#!/bin/sh
# initramfs hook: Detect PhantomixOS USB media at boot
# Mounts /skills, /results, /ai-models, /persist from persistent USB partition
#
# Boot-time detection sequence:
# 1. Scan all block devices for FAT32 partitions
# 2. Look for label PHANTOMIX or the "AI Dev ISO" FAT volume
# 3. Mount the FAT partition read-only to /mnt/usb initially
# 4. Identify data subdirectories (skills/results/ai-models/persist)
# 5. Mount /persist as overlay upperdir for rootfs persistence
#
# Called from /etc/initramfs-tools/hooks/* during mkinitramfs
# Also sourced by /boot/phantomixos-premount for pre-root setup

set -e

# Log to console for debugging on live boot
log() {
    echo "[PHANTOMIXOS-USB] $*" | tee -a /tmp/phantomixos-usb.log
}

# Scan block devices; return list of FAT32 partitions
scan_fat32() {
    # lsblk provides device+mount+fs+label
    lsblk -n -o NAME,FSTYPE,LABEL,MOUNTPOINT,UUID 2>/dev/null | \
        awk '$2=="vfat" || $2=="ntfs" {print $1}' || true
}

# Get label of a device
get_label() {
    blkid -s LABEL -o value /dev/"$1" 2>/dev/null || true
}

# Check if this is PhantomixOS USB media
is_hackin_iso() {
    local dev label
    for dev in $(scan_fat32); do
        label=$(get_label "$dev")
        case "$label" in
            PHANTOMIX|PHANTOMIXOS|PHANTOMIX-ISO)
                return 0
                ;;
        esac
        # Also accept FAT volume named "AI Dev ISO" (from ISO extraction)
        case "$label" in
            AI\ Dev\ ISO)
                return 0
                ;;
        esac
    done
    return 1
}

# Set up overlay for persistence
setup_persist_overlay() {
    local upper=/persist
    local work=/persist/work
    local lower=/live  # squashfs read-only root
    local merged=/mnt/persist-root
    local opts=lowerdir="$lower",upperdir="$upper",workdir="$work"

    if [ -d "$upper" ]; then
        log "Setting up persistence overlay: lower=$lower upper=$upper work=$work"
        mkdir -p "$work" "$merged"
        mount -t overlay overlay -o "$opts" "$merged"
        # Return merged path for later use by /etc/initramfs/post-mount or overlayroot
        echo "persist-overlay-mounted"
        return 0
    fi
    return 1
}

# Install dynamic tools from /skills (copied at boot or lazily via LD_LIBRARY_PATH)
setup_skills_loader() {
    local src="$1"
    local dst="$2"  # e.g. /usr/local/bin

    if [ -d "$src" ]; then
        log "Loading tools from $src"
        find "$src" -type f -perm +111 -print0 | while IFS= read -r -d f tool; do
            ln -sf "$tool" "$dst/" 2>/dev/null || true
        done
        # Also add Python skill tools to PATH
        find "$src" -name "*.py" -path "*tools*" -exec ln -sf {} "/usr/local/bin/" \; 2>/dev/null || true
    fi
}

# Copy /ai-models weights into ISO model dir (read-only) for llama.cpp
setup_ai_models() {
    local src="$1"
    local dst="/usr/local/share/phantomixos/models"

    if [ -d "$src" ]; then
        log "Loading AI models from $src"
        mkdir -p "$dst"
        for f in "$src"/*.gguf; do
            [ -f "$f" ] && cp -n "$f" "$dst/" 2>/dev/null
        done
    fi
}

# Main detection logic (run at initramfs boot)
detect_and_mount() {
    if is_hackin_iso; then
        FATDEV=$(scan_fat32 | head -1)
        FATMOUNT="/mnt/usb-phantomixos"

        log "Detected PhantomixOS USB media on /dev/$FATDEV"
        mkdir -p "$FATMOUNT"
        mount -o ro "$FATDEV" "$FATMOUNT" || mount -o ro,noatime "$FATDEV" "$FATMOUNT"

        # Record for overlayroot / post-mount scripts
        echo "$FATDEV" > /tmp/phantomixos-usb-device
        echo "$FATMOUNT" > /tmp/phantomixos-usb-mount

        [ -d "$FATMOUNT/skills" ] && setup_skills_loader "$FATMOUNT/skills" "/usr/local/bin"
        [ -d "$FATMOUNT/ai-models" ] && setup_ai_models "$FATMOUNT/ai-models"
        [ -d "$FATMOUNT/persist" ] && setup_persist_overlay
        [ -d "$FATMOUNT/results" ] && {
            mkdir -p /results
            mount --bind "$FATMOUNT/results" /results || cp -rn "$FATMOUNT/results"/* /results/ 2>/dev/null
        }
    else
        log "No PhantomixOS USB media detected; running on internal storage only"
        # Fallback: create dirs for /results on internal storage
        mkdir -p /results /persist /ai-models /skills
    fi
}

# Entry point: auto-detect if run directly
detect_and_mount
