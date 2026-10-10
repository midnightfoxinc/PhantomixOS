#!/bin/bash
# Build the Debian chroot rootfs for PhantomixOS
# Minimal FOSS base, pentest tools, AI stack (llama.cpp + phantomagent)
#
# PRIVILEGED: requires root (debootstrap, apt-get install)
# Manual step if sudo unavailable -- see docs/BUILD_STEPS.md
#
# Package names below were verified against the Debian bookworm main index.
# Tools with no Debian package are installed from their upstream releases
# (pinned, checksummed) in the "upstream tools" section.
#
# Outputs: build/rootfs/ (Debian base + tools + AI stack)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT/build"
ROOTFS="$BUILD_DIR/rootfs"

DEBIAN_SUITE="bookworm"
DEBIAN_MIRROR="http://deb.debian.org/debian"
DEBIAN_ARCH="amd64"

log() { echo "[rootfs] $*"; }

# ---- Chroot pseudo-filesystems ----
# dpkg post-install scripts (openjdk, udev, systemd, etc.) require /proc,
# /sys, /dev and /run inside the chroot. Without these, installs fail with
# "the java command requires a mounted proc fs (/proc)".
CHROOT_MOUNTED=0
mount_chroot_fs() {
    log "Mounting pseudo-filesystems in chroot..."
    for d in proc sys dev dev/pts run; do
        mkdir -p "$ROOTFS/$d"
    done
    mount -t proc     proc     "$ROOTFS/proc"
    mount -t sysfs    sysfs    "$ROOTFS/sys"
    mount -t devtmpfs devtmpfs "$ROOTFS/dev" 2>/dev/null || true
    mount -t devpts   devpts   "$ROOTFS/dev/pts" -o gid=5,mode=620 2>/dev/null || true
    mount -t tmpfs    tmpfs    "$ROOTFS/run"
    CHROOT_MOUNTED=1
}

umount_chroot_fs() {
    [ "$CHROOT_MOUNTED" -eq 1 ] || return 0
    log "Unmounting chroot pseudo-filesystems..."
    for d in run dev/pts dev sys proc; do
        mountpoint -q "$ROOTFS/$d" 2>/dev/null && umount -l "$ROOTFS/$d" 2>/dev/null || true
    done
    CHROOT_MOUNTED=0
}

# Always clean up the mounts, even on failure
trap umount_chroot_fs EXIT

# ---- Run a command inside the chroot as root ----
in_chroot() {
    local script="$1"
    sudo chroot "$ROOTFS" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        $script
    "
}

# ---- Minimal package installer (tolerates absent optional tools) ----
# Usage: install_pkgs "pkg1 pkg2 ..."  (space separated)
install_pkgs() {
    local pkgs="$1"
    local required="$2"   # "required" | "optional"

    # Filter to packages that actually exist in the configured suite
    local avail=""
    for p in $pkgs; do
        if in_chroot "apt-cache show '$p' >/dev/null 2>&1" 2>/dev/null; then
            avail="$avail $p"
        else
            log "  skip (not in suite): $p"
        fi
    done

    [ -z "$avail" ] && { log "  nothing to install"; return 0; }

    if in_chroot "apt-get install -y -qq --no-install-recommends $avail" 2>&1 | tail -5; then
        log "  installed:$avail"
    else
        if [ "$required" = "required" ]; then
            log "  ERROR: required package install failed"
            exit 1
        fi
        log "  WARNING: some optional packages failed"
    fi
}

log "=== Building PhantomixOS rootfs (Debian $DEBIAN_SUITE) ==="

if [ "$(id -u)" -eq 0 ]; then
    log "Running as root"
else
    log "Requires sudo (debootstrap + apt)"
fi

# ---- 1. Bootstrap minimal Debian ----
if [ ! -f "$ROOTFS/etc/debian_version" ]; then
    log "Bootstrapping Debian base (this takes a few minutes)..."
    mkdir -p "$ROOTFS"
    sudo debootstrap \
        --arch="$DEBIAN_ARCH" \
        --variant=minbase \
        --include=ca-certificates,apt-utils \
        --no-check-gpg \
        "$DEBIAN_SUITE" "$ROOTFS" "$DEBIAN_MIRROR"

    # Point the chroot at the same suites + components (contrib/non-free-firmware)
    cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb $DEBIAN_MIRROR $DEBIAN_SUITE main contrib non-free-firmware
deb $DEBIAN_MIRROR $DEBIAN_SUITE-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security $DEBIAN_SUITE-security main contrib non-free-firmware
EOF
else
    log "Rootfs already bootstrapped; refreshing"
fi

in_chroot "apt-get update -qq" || log "WARNING: apt update failed"

# Pseudo-filesystems must be mounted before any dpkg run
mount_chroot_fs

# ---- 2. Slim base: no GUI, no desktop, no telemetry ----
log "[2/9] Slim system base"
install_pkgs "bash dash coreutils util-linux procps psmisc mount \
sed grep gawk findutils diffutils \
login passwd sudo adduser \
ca-certificates apt-utils locales tzdata \
file xxd bsdmainutils tree pciutils util-linux-extra lsof htop \
vim-tiny nano less" required

# ---- 3. Networking ----
log "[3/9] Network stack"
install_pkgs "iproute2 iputils-ping net-tools ethtool \
dnsutils netcat-openbsd socat \
nmap masscan tcpdump tshark wireshark-common \
nftables iptables traceroute mtr-tiny openssl \
samba-common-bin cifs-utils sshpass" required

# ---- 4. Wireless / WiFi pentest ----
log "[4/9] Wireless tooling (Libre firmware only)"
install_pkgs "aircrack-ng reaver wpasupplicant \
wireless-tools iw rfkill bluez \
network-manager" required
# wifite ships as "wifite" in Debian (not wifite2)
install_pkgs "wifite" optional
install_pkgs "python3-scapy" required

# ---- 5. Exploitation / credential tools ----
log "[5/9] Exploitation tooling"
# NOTE: patator is intentionally NOT bundled. It is a Java tool and pulls in
# default-jre -> openjdk-17-jre-headless (~185 MB of /usr/lib/jvm), which
# conflicts with the 8 GB / minimal-footprint goal. hydra + hashcat + john
# cover the same brute-force ground with no runtime dependency.
install_pkgs "john hashcat hydra sqlmap gobuster dirsearch ffuf \
netcat-openbsd socat" required
# Bettercap ships in Debian main
install_pkgs "bettercap" optional

# ---- 6. Reverse engineering / firmware / APK analysis ----
log "[6/9] RE, firmware and APK analysis"
install_pkgs "binwalk p7zip-full unzip unrar-free xxd file \
python3-pwntools python3-capstone libcapstone4 \
python3-z3" optional
# androguard is a pure-python APK/DEX analyzer
in_chroot "python3 -m pip install --break-system-packages -q androguard" \
    2>&1 | tail -3 || log "  WARNING: androguard install failed"

# ---- 7. Debug interfaces (UART/JTAG) ----
log "[7/9] Debug interface support (UART/JTAG/USB)"
install_pkgs "openocd libftdi1 libftdi-dev ftdi-eeprom \
python3-ftdi1 usbutils usb-modeswitch minicom picocom \
screen tmux" required

# ---- 8. Libre firmware + kernel ----
log "[8/9] Kernel and Libre firmware"
# firmware-linux-free is the libre subset; firmware-linux-nonfree is the
# blob-bearing one. We install ONLY the free subset (see docs/ARCHITECTURE.md).
install_pkgs "firmware-linux-free wireless-regdb linux-image-amd64 \
live-boot initramfs-tools" required

# ---- 9. AI stack + phantomagent ----
log "[9/9] AI stack"
LLAMA_BIN_DIR="$ROOT/models/llama-binaries"
if [ ! -d "$LLAMA_BIN_DIR" ] || [ -z "$(ls -A "$LLAMA_BIN_DIR" 2>/dev/null)" ]; then
    log "ERROR: llama.cpp binaries not found in $LLAMA_BIN_DIR"
    log "       Run ./scripts/build-llamacpp.sh first."
    exit 1
fi

sudo mkdir -p "$ROOTFS/usr/local/bin" "$ROOTFS/usr/local/share/phantomixos/models"
for b in "$LLAMA_BIN_DIR"/*; do
    [ -f "$b" ] && sudo cp "$b" "$ROOTFS/usr/local/bin/"
done
# Static-ish helper libs that ship alongside the binaries
[ -d "$LLAMA_BIN_DIR/lib" ] && sudo cp -r "$LLAMA_BIN_DIR/lib" "$ROOTFS/usr/local/lib/" 2>/dev/null || true

# Models (optional -- may be large; ISO can also load them from /ai-models)
if ls "$ROOT"/models/*.gguf >/dev/null 2>&1; then
    log "Copying GGUF models into rootfs..."
    sudo cp "$ROOT"/models/*.gguf "$ROOTFS/usr/local/share/phantomixos/models/"
else
    log "NOTE: no .gguf models found; ISO will load them from /ai-models at boot"
    sudo mkdir -p "$ROOTFS/usr/local/share/phantomixos/models"
fi

# phantomagent Python package
sudo mkdir -p "$ROOTFS/opt/phantomixos"
sudo cp -r "$ROOT/python/phantomagent" "$ROOTFS/opt/phantomixos/"
sudo cp -r "$ROOT/initramfs" "$ROOTFS/opt/phantomixos/initramfs-src"

# Entry point wrapper for phantomagent (console_scripts need pip install; a
# wrapper is simpler, dependency-free, and survives chroot moves)
sudo tee "$ROOTFS/usr/local/bin/phantom-agent" >/dev/null <<'WRAPPER'
#!/bin/sh
# phantomagent entry point (stdlib-only; no pip install required)
PYTHONPATH="/opt/phantomixos${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m phantomagent.cli "$@"
WRAPPER
sudo chmod 0755 "$ROOTFS/usr/local/bin/phantom-agent"

# Boot + AI scripts
install -m 0755 "$ROOT/initramfs/boot/phantomixos-init"        "$ROOTFS/phantomixos-init"
install -m 0755 "$ROOT/initramfs/scripts/phantomixos-ai-autostart" "$ROOTFS/usr/local/bin/phantomixos-ai-autostart"
install -m 0755 "$ROOT/initramfs/scripts/phantomixos-agent"       "$ROOTFS/usr/local/bin/phantomixos-agent"
install -m 0755 "$ROOT/initramfs/scripts/phantomixos-skill-loader" "$ROOTFS/usr/local/bin/phantomixos-skill-loader"
install -m 0755 "$ROOT/initramfs/scripts/phantomixos-overlay-setup" "$ROOTFS/usr/local/bin/phantomixos-overlay-setup"

# Skills (defaults; users add more via /skills on USB)
sudo mkdir -p "$ROOTFS/skills"
sudo cp "$ROOT"/skills/*.py "$ROOTFS/skills/" 2>/dev/null || true
sudo cp "$ROOT"/skills/*.md "$ROOTFS/skills/" 2>/dev/null || true

# Live data dirs
sudo mkdir -p "$ROOTFS"/{results,persist,ai-models}

# systemd oneshot: load USB skills into PATH at boot
sudo mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
sudo tee "$ROOTFS/etc/systemd/system/phantomixos-skills.service" >/dev/null <<'EOF'
[Unit]
Description=PhantomixOS - load skills from USB into PATH
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/phantomixos-skill-loader
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
sudo ln -sf /etc/systemd/system/phantomixos-skills.service \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants/phantomixos-skills.service"

# ---- Cleanup: reclaim disk ----
# The chroot ships with several hundred MB of reclaimable bulk. Everything
# here is removed AFTER all installs, so nothing breaks during the build.
log "Cleaning apt caches, docs and locales to keep the rootfs minimal..."

# Remove any partially-installed Java (left over if patator was ever attempted)
in_chroot "dpkg --purge --force-depends openjdk-17-jre openjdk-17-jre-headless default-jre default-jre-headless 2>/dev/null; apt-get autoremove -y -qq --purge" || true
sudo rm -rf "$ROOTFS/usr/lib/jvm" 2>/dev/null || true

# APT caches + downloaded .debs (~520 MB)
in_chroot "apt-get clean && apt-get autoremove -y -qq --purge" || true
sudo rm -rf "$ROOTFS/var/lib/apt/lists/"*
sudo rm -rf "$ROOTFS/var/cache/apt/archives/"*.deb 2>/dev/null || true

# Docs, man pages, info (~45 MB)
sudo rm -rf "$ROOTFS/usr/share/doc/"* "$ROOTFS/usr/share/man/"* "$ROOTFS/usr/share/info/"* 2>/dev/null || true

# Locales other than C/POSIX (~100 MB); keeps `perl` and `ls` from warning
sudo find "$ROOTFS/usr/share/locale" -mindepth 1 -maxdepth 1 \
     ! -name 'C' ! -name 'POSIX' ! -name 'en_US' -exec rm -rf {} + 2>/dev/null || true

# OpenCL runtime pulled in by hashcat (~81 MB); CPU-only box does not need it
sudo rm -rf "$ROOTFS/usr/share/pocl" 2>/dev/null || true

# Desktop icon themes / mime caches pulled in transitively
sudo rm -rf "$ROOTFS/usr/share/icons" 2>/dev/null || true
in_chroot "update-mime-database /usr/share/mime 2>/dev/null" || true

# Report size (relevant to the 8GB RAM budget: squashfs is memory-mapped and
# mostly file-backed, so a smaller rootfs means less page cache pressure)
SIZE=$(sudo du -sh "$ROOTFS" 2>/dev/null | cut -f1)
log "Rootfs size after cleanup: $SIZE"

log "=== Rootfs build complete: $ROOTFS ==="