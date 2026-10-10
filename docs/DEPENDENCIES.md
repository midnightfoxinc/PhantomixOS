# PhantomixOS Build Dependencies

## Build-Time Tools (Host System)
These packages are required on the build host to create the ISO.
Install via: `sudo make setup-deps`

| Tool | Purpose | Package (Debian/Ubuntu) |
|------|---------|-------------------------|
| `debootstrap` | Create Debian chroot | `debootstrap` |
| `mksquashfs` | Compress rootfs → squashfs | `squashfs-tools` |
| `xorriso` | Create hybrid ISO (UEFI+BIOS) | `xorriso` |
| `grub-mkrescue` / `grub-install` | GRUB2 bootloader | `grub-pc-bin`, `grub-efi-amd64-bin` |
| `mtools` / `dosfstools` | FAT32 handling | `mtools`, `dosfstools` |
| `git`, `wget`, `curl`, `jq` | Source fetching | `git`, `wget`, `curl`, `jq` |
| `make`, `gcc`, `g++` | Compile llama.cpp | `make`, `gcc`, `g++` |
| `python3`, `python3-pip` | Agent framework | `python3`, `python3-pip` |
| `cpio` | Initramfs cpio archive | `cpio` |
| `parted`, `fdisk` | Partitioning (for docs) | `parted`, `fdisk` |

## Runtime Tools (Included in ISO)
These are installed into the Debian rootfs via `build-rootfs.sh`.
No host-system installation needed.

### Base System
- bash, dash, util-linux, procps, login, passwd, sudo
- openssh-client, ca-certificates, file, xxd, strings
- python3, python3-pip, python3-venv

### Pentest & Network Tools
*(package names verified against Debian bookworm main)*
- nmap, masscan, netcat-openbsd, tcpdump, tshark, socat
- dnsutils, iproute2, net-tools, ethtool, traceroute, mtr-tiny
- aircrack-ng, wifite, reaver, wpasupplicant, wireless-tools, iw, rfkill, bluez
- john, hashcat, hydra, patator, sqlmap, gobuster, dirsearch, ffuf
- bettercap, samba-common-bin, cifs-utils, sshpass
- python3-scapy

### Code & Reverse Engineering
- python3-pwntools, python3-capstone, libcapstone4, python3-z3
- binwalk, p7zip-full, unzip, unrar-free, file, xxd
- gdb, strace, ltrace
- androguard (pip, installed into the chroot)

### Debug & Hardware Interfaces
- openocd, libftdi1, libftdi-dev, ftdi-eeprom, python3-ftdi1
- usbutils, usb-modeswitch, minicom, picocom, screen, tmux

### Firmware
- firmware-linux-free (libre subset only)
- wireless-regdb (regulatory database, not a blob)
- linux-image-amd64, live-boot, initramfs-tools

### Deliberately excluded
The following have no Debian bookworm package and are NOT bundled:
`nuclei`, `nikto`, `crackmapexec`/`netexec`, `enum4linux`, `impacket-scripts`,
`radare2`, `wifite2`, `firmware-mod-kit`, `firmware-libre`.
Install from upstream if required — see docs/VALIDATION.md.

### System Utilities
- htop, iotop, vim, nano, tmux, screen
- psmisc, util-linux, bsdmainutils
- rsync, cpio, gzip, bzip2, xz-utils

## AI Stack (Models + Engine)
- **llama.cpp**: Compiled from source (`make LLAMA_CUBLAS=0 GPU=0 BLAS=None`)
- **GGUF Models**: Downloaded from HuggingFace (Apache 2.0 / MIT licensed)
  - `qwen2.5-7b-instruct-q4_k_m.gguf` (~4.3 GB)
  - `qwen2.5-coder-7b-instruct-q4_k_m.gguf` (~4.7 GB)
  - `bge-small-en-v1.5-q4_k_m.ggf` (~55 MB)

## Storage Requirements (Build Host)
- **Models:** ~9.5 GB (3 GGUF files)
- **Build workspace:** ~2 GB (rootfs, live, initramfs, output)
- **Total:** ~12 GB recommended free space

## Network Requirements
- HTTPS access to:
  - `deb.debian.org` (Debian packages)
  - `security.debian.org` (security updates)
  - `huggingface.co` (model downloads)
  - `github.com` (llama.cpp source)

## Verified Build Environments
- Debian 12 (bookworm) x86_64
- Debian 13 (trixie) x86_64
- Ubuntu 22.04 LTS x86_64
- Should work on any recent Debian-based distro with sudo access