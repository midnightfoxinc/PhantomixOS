# PhantomixOS — Manual Build Procedure

> **Everything is reproducible.** Every step is documented so you can run it manually or script it.
> **Root required:** `debootstrap`, `apt-get install`, `mount`, `xorriso` need sudo.

---

## Prerequisites (on build host)

```bash
# Debian/Ubuntu build host
sudo apt-get update && sudo apt-get install -y \
    debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin \
    mtools dosfstools python3 python3-pip git wget curl jq make gcc g++ \
    cpio parted fdisk
```

Verify:
```bash
for cmd in mksquashfs debootstrap cmake xorriso grub-mkrescue grub-mkstandalone; do
    command -v $cmd >/dev/null && echo "[OK] $cmd" || echo "[MISS] $cmd"
done
```

---

## Step 0 — Clone + Set Up Workspace

```bash
cd /mnt/storage/Projects
git clone <this-repo> PhantomixOS
cd PhantomixOS

# Create structure
mkdir -p build/{rootfs,live,initramfs,output} models skills/examples docs
```

---

## Step 1 — Build llama.cpp (CPU-only, no blobs)

```bash
cd /mnt/storage/Projects/PhantomixOS
./scripts/build-llamacpp.sh
```

**What it does:**
1. `git clone --depth 1 https://github.com/ggerganov/llama.cpp build/llama.cpp`
2. `cd build/llama.cpp && make -j$(nproc) LLAMA_CUBLAS=0 GPU=0 BLAS=None`
3. Copies binaries to `models/llama-binaries/`

**Expected:** `models/llama-binaries/llama-server`, `llama-cli`, `llama-embedding`

> **No cmake needed** — pure Make build avoids openblas/cuda dependencies.

---

## Step 2 — Download Quantized Models

```bash
./scripts/download-models.sh
```

**Downloads from HuggingFace:**
| Model | Size | Purpose |
|---|---|---|
| `qwen2.5-7b-instruct-q4_k_m.gguf` | 4.3 GB | Primary agent (reasoning + tool use) |
| `qwen2.5-coder-7b-instruct-q4_k_m.gguf` | 4.7 GB | Code/exploit specialist |
| `bge-small-en-v1.5-q4_k_m.gguf` | 55 MB | Embeddings (skill RAG) |

**Verify:**
```bash
ls -lh models/*.gguf
# Total ~9.5 GB
```

> These stay in `models/` and are **copied into the ISO** at `/live/usr/local/share/phantomixos/models/`.
> They can also be mounted at boot from `/ai-models` on the USB (runtime swap).

---

## Step 3 — Build Debian Rootfs (REQUIRES ROOT)

```bash
sudo ./scripts/build-rootfs.sh
```

**What it does:**
1. `debootstrap --variant=minbase bookworm build/rootfs http://deb.debian.org/debian`
2. Installs (all names verified against the bookworm main index):
   - **Slim base**: bash, dash, coreutils, util-linux, procps, file, xxd, lsof, htop
   - **Pentest**: nmap, masscan, aircrack-ng, wifite, reaver, bettercap, hashcat,
     hydra, patator, sqlmap, gobuster, dirsearch, ffuf, python3-scapy
   - **Hardware/debug**: openocd, libftdi1, ftdi-eeprom, usbutils, minicom, picocom
   - **RE/firmware**: binwalk, p7zip-full, python3-pwntools, python3-capstone, androguard
   - **Libre firmware**: `firmware-linux-free` + `wireless-regdb`
     (the blob-bearing `firmware-linux-nonfree` is deliberately NOT installed)
3. Copies:
   - llama.cpp binaries → `/usr/local/bin/`
   - `python/phantomagent/` → `/opt/phantomixos/` + `/usr/local/bin/phantom-agent` wrapper
   - `skills/` → `/skills/`

**Output:** `build/rootfs/` — a complete Debian chroot.

> **Disk use:** ~850 MB after apt clean.

---

## Step 4 — Assemble ISO

```bash
./scripts/build-iso.sh
```

**What it does:**
1. Builds `initramfs.cpio.gz` (includes `boot/linuxrc` USB-detection script)
2. Creates `grub.cfg` with 3 menu entries (Auto / Single / Debug)
3. `mksquashfs build/rootfs build/live/squashfs-root -comp zstd`
4. `xorriso` → hybrid ISO (UEFI + BIOS) at `output/PhantomixOS-0.1.0-amd64.iso`
5. `sha256sum` → `output/checksums-sha256.txt`

**Expected ISO size:** ~1.8–2.2 GB (fits on 4GB+ USB).

---

## Step 5 — Verify

```bash
./scripts/verify-iso.sh
```

Outputs SHA256 and runs a 60-second QEMU smoke test (if `qemu-system-x86_64` installed).

---

## Step 6 — Write to USB (target device)

```bash
# DANGEROUS: triple-check /dev/sdX
sudo dd if=output/PhantomixOS-0.1.0-amd64.iso of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

### Post-write: create persistent partition

```bash
# 1. Boot the USB on target machine
# 2. In live session, create a second partition on the USB for /persist
sudo fdisk /dev/sdX
#   n → p → 2 → [Enter] → [Enter] → w
# 3. Format as ext4 (label: PHANTOMIX-PERSIST)
sudo mkfs.ext4 -L PHANTOMIX-PERSIST /dev/sdX2
# 4. Mount and create directories
sudo mount /dev/sdX2 /mnt
mkdir -p /mnt/{persist,persist/work,results,skills,ai-models}
sudo umount /mnt
```

Now on next boot:
- `/persist` overlay upperdir = `/dev/sdX2` (ext4)
- `/skills`, `/results`, `/ai-models` bind from `/dev/sdX1` (FAT32) or `/dev/sdX2`

---

## Step 7 — Boot on Target (i5-6th Gen, 8GB)

1. Insert USB, power on
2. GRUB menu → "PhantomixOS - Automated Penetration Test"
3. Boot logs show USB detection, overlay mount
4. After ~15-20s: Debian login prompt
   - user: `root` (no password on live) or `hackin:iso`
5. Start AI stack:
   ```bash
   # Start inference server (single model, fits in RAM)
   llama-server -m /usr/local/share/phantomixos/models/qwen2.5-7b-instruct-q4_k_m.gguf \
       -c 8192 -t 4 -ngl 0 --host 127.0.0.1 --port 8080 -np 1 -cb &
   ```
6. Run an engagement:
   ```bash
   phantomagent run --target 192.168.1.0/24 --scope network
   ```

---

## Troubleshooting

| Issue | Fix |
|---|---|
| `debootstrap` fails: key error | Use `--no-check-gpg` or import Debian archive key |
| `cmake` not installed | Not needed — Makefile builds llama.cpp without it |
| ISO > 4 GB | ISO < 4GB; FAT32 handles up to 4GB single file. Use exFAT on USB if needed |
| QEMU smoke test fails | Install `qemu-system-x86 qemu-utils` |
| USB not detected | Check `blkid -s LABEL -o value` matches `PHANTOMIX` or `AI Dev ISO` |

---

## Rebuild from scratch

```bash
rm -rf build/rootfs build/live build/initramfs output/*.iso models/llama-binaries
# Re-run Steps 1-4
```

---

## Customization points

| File | Purpose |
|---|---|
| `scripts/build-rootfs.sh` | Add/remove apt packages |
| `python/phantomagent/orchestrator.py` | Change agent phases, add specialists |
| `skills/*.py` | Add external tools dynamically |
| `initramfs/hooks/00-phantomixos-usb-detect.sh` | Change USB label detection |
| `scripts/build-iso.sh` | Change GRUB menu, compression, kernel cmdline |