# STEP 2 — InitramFS Hooks

> Step 2 implements:
> 1. USB auto-detection hook script (`00-phantomixos-usb-detect.sh`)
> 2. `/skills` dynamic loader (Python/C — implemented as shell for initramfs portability)
> 3. Overlay filesystem configuration for persistent storage

## 2.1 InitramFS Build Architecture

```
build/initramfs/                    # Initramfs build directory (copied into cpio)
├── boot/                           # Boot files loaded by kernel
│   ├── linuxrc                     # Entry point after initramfs mount
│   └── phantomixos-premount.sh       # Pre-root hook (optional, for GRUB)
├── hooks/                          # Hooks installed into chroot /etc/initramfs-tools
│   ├── 00-phantomixos-usb-detect     # USB detection hook (mkinitramfs)
│   └── 99-phantomixos-postmount      # Post-overlay mount hook
├── scripts/                        # Initramfs scripts installed to rootfs
│   ├── phantomixos-usb-detect        # Standalone USB detection (also as module)
│   ├── phantomixos-skill-loader      # /skills dynamic loader
│   └── phantomixos-overlay-setup     # Overlay filesystem setup
├── etc/                            # Config passed to rootfs
│   ├── environment
│   └── mount-phantomixos.conf
└── usr/local/bin/                  # Boot-time helpers
    ├── phantomixos-setup-persist
    └── phantomixos-verify
```

## 2.2 Hook: USB Auto-Detection (`/etc/initramfs-tools/hooks/00-phantomixos-usb-detect`)

This hook is invoked during `mkinitramfs` and embeds the script into the initramfs.
It runs early at boot — before the root filesystem is mounted — and:
1. Scans all block devices for FAT32 partitions
2. Matches the label `PHANTOMIX` or fallback `AI Dev ISO`
3. Mounts the volume read-only at `/mnt/usb`
4. Exposes the mount path via `/run/phantomixos-usb` for later hooks

### Hook Content

```bash
#!/bin/sh
# phantomixos hook — embedded into initramfs
# Runs during mkinitramfs to check for PHANTOMIX USB media

set -e

# Export functions for later use
PHANTOMIXUSBDIR="/run/phantomixos"
mkdir -p "$PHANTOMIXUSBDIR"

scan_hackin_iso() {
    local dev label
    for dev in $(blkid -t TYPE=vfat -o device 2>/dev/null); do
        label=$(blkid -s LABEL -o value "$dev" 2>/dev/null)
        case "$label" in
            PHANTOMIX|PHANTOMIXOS|AI\ Dev\ ISO)
                echo "$dev"
                return 0
                ;;
        esac
    done
    return 1
}

# Export detected device for post-mount hook
USBDEV=$(scan_hackin_iso)
if [ -n "$USBDEV" ]; then
    echo "$USBDEV" > "$PHANTOMIXUSBDIR/device"
    echo "PHANTOMIXUSB: detected on $USBDEV"
fi
```

## 2.3 `/skills` Dynamic Loader (`/usr/local/bin/phantomixos-skill-loader`)

This script runs **after root is mounted** and:
1. Finds the mounted FAT32 volume (`/mnt/usb` or from persist overlay)
2. Scans `/skills` and `/ai-models` and `/results`
3. Copies executable binaries into `/usr/local/bin` (lazy tool loading)
4. Adds Python skill paths to `PYTHONPATH` for dynamic import
5. Creates symlinks for common command-line tools

### Loader Content

```python
#!/usr/bin/env python3
"""
/phantomixos-skill-loader — Dynamic /skills dynamic loader
Runs after root mount; populates /usr/local/bin and PYTHONPATH.
"""
import os, sys, glob, subprocess

SKILLS_DIR = "/skills"
AI_MODELS_DIR = "/ai-models"
RESULTS_DIR = "/results"

def load_binaries():
    """Load executables from /skills into /usr/local/bin lazily."""
    if not os.path.isdir(SKILLS_DIR):
        return
    for path in glob.glob(os.path.join(SKILLS_DIR, "**", "*"), recursive=True):
        if os.path.isfile(path) and os.access(path, os.X_OK):
            base = os.path.basename(path)
            target = os.path.join("/usr/local/bin", base)
            if not os.path.exists(target):
                os.symlink(path, target)
                print(f"[PHANTOMIXOS-SKILLS] loaded {base}")

def setup_env():
    """Add skills to environment."""
    if os.path.isdir(SKILLS_DIR):
        sys.path.insert(0, SKILLS_DIR)
    os.environ["PHANTOMIXOS_SKILLS_DIR"] = SKILLS_DIR
    os.environ["PHANTOMIXOS_AI_MODELS_DIR"] = AI_MODELS_DIR
    os.environ["PHANTOMIXOS_RESULTS_DIR"] = RESULTS_DIR

if __name__ == "__main__":
    load_binaries()
    setup_env()
```

## 2.4 Overlay Filesystem Configuration

### Overlay Root (`/usr/local/share/phantomixos/overlayfs`)

The overlay configuration is embedded in the initramfs and activates at boot:

```bash
#!/bin/sh
# phantomixos-overlay-setup — persistent rootfs overlay
# lowerdir=/live (squashfs), upperdir=/persist (ext4), workdir=/persist/work
# Merges at /run/phantomixos/merged-root
```

### Mount Configuration

```
/ -> overlay
    lowerdir: /live (squashfs, R/O)
    upperdir: /persist (ext4, R/W)
    workdir:  /persist/work

/skills -> /usr/local/bin (symlink)
/results -> /results (bind mount)
/ai-models -> /ai-models (bind mount)
```

## 2.5 Boot Chain (initramfs)

```
Kernel (vmlinuz) → linuxrc → /etc/init → /usr/local/bin/phantomixos-setup (chain)
   ├─ usb-detect.sh (scan + mount FAT32 at /mnt/usb)
   ├─ overlay-setup.sh (mount overlay on /persist → /run/phantomixos/merged-root)
   ├─ skill-loader.sh (load /skills into /usr/local/bin, PYTHONPATH)
   └─ postmount (resume normal boot via systemd/sysvinit)
```

## 2.6 Persistence Overlay Filesystem

The overlay rootfs configuration is:
```
mount -t overlay overlay \
    -o lowerdir=/live,upperdir=/persist,workdir=/persist/work \
    /run/phantomixos/merged-root
```

Where:
- `/live` = squashfs image (read-only rootfs from ISO)
- `/persist` = ext4 partition on USB (R/W upper)
- `/persist/work` = overlay workdir (internal, cannot be bind-mounted)

## 2.7 Documentation & Testing

All scripts are placed in the `initramfs/` tree and copied to the `build/initramfs` directory during `build-iso.sh`.

Test via QEMU smoke test:
```bash
./scripts/verify-iso.sh --vm-test
```

Verify hook integrity before packaging:
```bash
cd build/initramfs && find . -type f | sort
```

## 2.8 Files Created in This Step

| File | Purpose |
|------|---------|
| `initramfs/hooks/00-phantomixos-usb-detect` | USB detection hook (mkinitramfs) |
| `initramfs/hooks/99-phantomixos-postmount` | Post-overlay mount hook |
| `initramfs/scripts/phantomixos-skill-loader` | `/skills` dynamic loader (Python) |
| `initramfs/scripts/phantomixos-usb-detect` | Standalone USB detection module |
| `initramfs/scripts/phantomixos-overlay-setup` | Overlay filesystem setup |
| `initramfs/boot/linuxrc` | Initramfs entry point |
| `initramfs/boot/phantomixos-premount.sh` | Pre-root hook (optional) |
| `initramfs/etc/mount-phantomixos.conf` | Overlay configuration |

## 2.9 Deployment in `build-iso.sh`

The `build-iso.sh` script assembles the initramfs by:
1. Copying `initramfs/` tree to `build/initramfs`
2. Building cpio archive with `find . -print0 | cpio -o -H newc --null`
3. Gzipping: `gzip -n < initramfs.cpio > initramfs.cpio.gz`
4. Including in ISO at `/boot/initramfs.cpio.gz`

## 2.10 Security Notes

- Initramfs is **read-only** by default (kernel command line `initramfs ro`)
- Overlay uses `noatime,nodiratime` mount options for wear-leveling on USB
- Persistent data is stored in `/persist` only; `/results` is a separate bind mount
- No network access required during initramfs (offline-capable)
EOF
echo "Step 2 docs created"