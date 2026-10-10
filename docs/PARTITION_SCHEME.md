# PhantomixOS Partition Scheme (Target USB)

> **Recommended layout: FAT32 boot partition + ext4 data partition.**
> This is not a preference — it is required to store the models. See the
> constraint below.

## Hard constraint: FAT32 cannot hold the models

FAT32 has a **4 GiB maximum file size** (4,294,967,295 bytes). Two facts collide:

| File | Bytes | Fits FAT32? |
|---|---|---|
| `qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf` | 3,993,201,344 | yes |
| `qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf` | 689,872,288 | yes |
| `qwen2.5-coder-7b-instruct-q4_k_m.gguf` | **4,683,073,536** | **no — 388 MB over** |
| `bge-small-en-v1.5-q4_k_m.gguf` | 24,808,576 | yes |

`qwen2.5-coder-7b-instruct-q4_k_m.gguf` **cannot be written to a FAT32 partition at
all**, by any filesystem driver. `/ai-models` must therefore live on ext4 (or
exFAT, which has no file-size cap — but exFAT still lacks xattrs, see below).

A second, independent reason to prefer ext4: **overlayfs requires an upperdir with
xattr support, and neither FAT32 nor exFAT provide xattrs.** Any design that puts an
overlay upperdir on a FAT32 or exFAT partition cannot work. ext4 can.

## Recommended: Dual-Partition Mode

```
Device     Start       End   Sectors   Size Type
/dev/sdX1      2048  16775167  16773120     8G  EFI System (FAT32, hybrid ISO, label PHANTOMIX)
/dev/sdX2   16775168  67108863  50333696    24G  Linux filesystem (ext4, label PHANTOMIX)
```

### Partition 1: FAT32 — boot only
- **Filesystem:** FAT32 (broadest UEFI/BIOS compatibility)
- **Label:** `PHANTOMIX` (detected by `phantomixos-init`)
- **Contents:** the bootable hybrid ISO image, plus small text assets only.

### Partition 2: ext4 — models, results, skills, persistence
- **Filesystem:** ext4
- **Label:** `PHANTOMIX` (same label; detection is by label, and both work)
- **Contents:**
  - `/ai-models/` — GGUF models. **Must be ext4** for the coder model to fit.
  - `/results/` — engagement output, pcaps, reports
  - `/skills/` — user-supplied skill modules
  - `/persist/` — overlay upperdir + workdir, if root persistence is wanted

`phantomixos-init` accepts either filesystem and uses whichever partition carries a
`PHANTOMIX*` label, so a single-partition FAT32 stick still boots (models simply will
not fit).

## Single-Partition Mode (ISO-only, degraded)
Writing the ISO straight to USB (`dd if=PhantomixOS.iso of=/dev/sdX`) still boots.
On FAT32 you get persistence for `/skills` and `/results` only; `/ai-models` must
hold a model under 4 GiB (the 7B-Instruct shards fit; the 7B-Coder single file does
not).

## Dual-Partition Mode (Recommended for Persistence)
After writing ISO, create second partition for persistent storage:
```
Device     Start       End   Sectors   Size Type
/dev/sdX1      2048  16775167  16773120     8G  EFI System (FAT32, hybrid ISO)
/dev/sdX2   16775168  33550335  16775168     8G  Linux filesystem (ext4, PHANTOMIX-PERSIST)
```

### Partition 1: FAT32 (Primary, bootable)
- **Size:** Matches ISO size (typically 1.8-2.2 GB for PhantomixOS)
- **Filesystem:** FAT32 (for broad UEFI/BIOS compatibility)
- **Label:** `PHANTOMIX` (used by initramfs for detection)
- **Contents:**
  - `/boot/` → GRUB files, ISO boot image
  - `/skills/` → External tools (Python scripts, binaries) → loaded into `/usr/local/bin/` at boot
  - `/results/` → Engagement logs, proofs, reports → persistent across boots
  - `/ai-models/` → Optional spare GGUF models (user can copy here)
  - `/persist/` → Optional directory for persistence overlay (if formatted as ext4)

### Partition 2: ext4 (Optional, persistent overlay)
- **Size:** User-defined (suggested: 4-8 GB+)
- **Filesystem:** ext4
- **Label:** `PHANTOMIX-PERSIST` (used by initramfs for overlay detection)
- **Contents:**
  - `/` → Overlay upperdir for `/` (when combined with read-only squashfs)
  - `/work/` → Overlay workdir
  - Can also bind-mount `/skills`, `/results`, `/ai-models` from here if desired

## Boot-Time Detection Logic (initramfs)
The initramfs script (`00-phantomixos-usb-detect.sh`) performs:
1. Scan all block devices for FAT32 partitions
2. Check partition label for `PHANTOMIX` or `AI Dev ISO` (fallback)
3. Mount first matching partition read-only at `/mnt/usb`
4. If `/mnt/usb/persist` exists and is ext4:
   - Setup overlay: `lowerdir=/live` (squashfs), `upperdir=/mnt/usb/persist`, `workdir=/persist/work`
   - Mount overlay at `/mnt/persist-root` (pivot_root will use this)
5. Always bind-mount (if exist):
   - `/mnt/usb/skills` → `/usr/local/bin/` (for dynamic tool loading)
   - `/mnt/usb/results` → `/results`
   - `/mnt/usb/ai-models` → `/ai-models`
6. If no persistence overlay, `/persist` becomes a tmpfs (RAM-only, lost on reboot)

## Why This Scheme?
- **Single partition:** Simple, works out-of-the-box with `dd`
- **Dual partition:** Optional persistence without remastering ISO
- **FAT32:** Universally supported by UEFI and BIOS firmware
- **ext4 overlay:** Persistent state with negligible performance cost
- **Label-based detection:** Robust against device naming changes (/dev/sdX vs /dev/mmcblkX)