# PhantomixOS

> ⚠️ **EDUCATIONAL USE ONLY — LOCAL HARDWARE ONLY**

This project is published **solely for educational and defensive security research purposes.**

- **Local hardware only.** PhantomixOS is intended for use on machines and networks that you own or have **explicit written authorization** to test. Do not run it against third-party systems, infrastructure, or accounts you have no permission to assess.
- **Authorized testing only.** Using this software against any system without the owner's consent may violate computer fraud and abuse laws (e.g. 18 U.S.C. §1030, Computer Misuse Act, equivalents in other jurisdictions) and can carry criminal liability. **You are solely responsible for ensuring you have authorization.**
- **No warranty, no liability.** The authors and contributors accept no responsibility for any damage, data loss, or legal consequences arising from use of this software. It is provided "as is", for learning.
- **Defensive focus.** The intended use is understanding how software and hardware can be attacked, so it can be defended better.

By using this software you agree that you will only use it on systems you own or are authorized to test, and that you accept all responsibility for your use of it.

---

> 🛡️ A minimal, fully open-source, privacy-respecting live ISO for **AI-powered automated penetration testing research**.
> Built for air-gapped environments — zero telemetry, no cloud, 100% offline.

## Overview

PhantomixOS is a live boot ISO that combines:
- **Debian 12 (bookworm) minimal base** — no GUI, no telemetry
- **Libre firmware only** — `firmware-linux-free`, no proprietary blobs
- **Quantized open-weight LLM** — Qwen2.5-7B (Q4_K_M) via llama.cpp for reasoning + code
- **Multi-agent orchestration** — recon → exploit → code → analysis pipeline
- **Dynamic skill injection** — tools/plugins loaded at runtime from `/skills` on USB
- **Persistent USB overlay** — read-only squashfs root, R/W overlay on FAT32/ext4 partitions

## Target Hardware

| Component | Spec |
|---|---|
| CPU | Intel i5+, 6th Gen+ |
| RAM | 8 GB |
| Disk | USB 8GB+ (FAT32 + ext4 partitions) |

## Quick Start

### Build all (requires root)
```bash
make setup-deps
make models
make build-rootfs
make build-iso
make verify
```

### Or step-by-step
```bash
./scripts/build-llamacpp.sh      # Step 1: compile llama.cpp
./scripts/download-models.sh      # Step 2: download GGUF models
sudo ./scripts/build-rootfs.sh    # Step 3: build Debian rootfs (needs root)
./scripts/build-iso.sh            # Step 4: assemble ISO
./scripts/verify-iso.sh           # Step 5: verify
```

→ Final ISO: `output/PhantomixOS-0.1.0-amd64.iso`

## Partition Layout (on boot USB)

```
┌──────────────────────────────────────────────┐
│ Partition 1 (FAT32): PHANTOMIX volume           │
│   ├── /boot                (ISO + GRUB)     │
│   ├── /skills              (external tools)  │
│   ├── /results             (logs/exploits)   │
│   └── /ai-models           (weights)        │
│                                              │
│ Partition 2 (ext4): PHANTOMIX-PERSIST          │
│   ├── /persist             (overlay upper)   │
│   └── /persist/work                         │
└──────────────────────────────────────────────┘
```

## After Boot (on your own hardware)

> Reminder: only run this against systems you own or have written authorization to test.

```bash
# Start inference (single model, fits in 8GB)
llama-server \
    -m /usr/local/share/phantomixos/models/qwen2.5-7b-instruct-q4_k_m.gguf \
    -c 8192 -t 4 -ngl 0 \
    --host 127.0.0.1 --port 8080 &

# Run an authorized engagement
phantom-agent run --target 192.168.1.0/24 --scope network
```

All results saved to `/results/` (persistent on USB).

## Documentation

| Doc | Purpose |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Full architecture, component map |
| [docs/BUILD_STEPS.md](docs/BUILD_STEPS.md) | Step-by-step manual build procedure |
| [docs/MODELS.md](docs/MODELS.md) | Model selection rationale + memory budget |

## Key Design Decisions (8GB RAM)

1. **No GUI** — headless CLI/textui only (~250MB rootfs)
2. **Q4_K_M quantization** — 4-bit, 7B models at ~4.5GB instead of ~14GB
3. **Single model at a time** — multi-agent orchestrator swaps models via llama.cpp (5s reload)
4. **Read-only squashfs root** — ISO is immutable; `/persist` overlay for R/W
5. **USB auto-detection** — initramfs scans for `PHANTOMIX`-labeled FAT32 volume at boot

## Tool Stack (FOSS only)

**Network:** nmap, masscan, netcat-openbsd, tcpdump, tshark, dnsutils, socat
**WiFi:** aircrack-ng, wifite, reaver, wpasupplicant, bettercap, python3-scapy
**Web:** gobuster, dirsearch, ffuf, sqlmap
**Bruteforce:** hydra, patator, john, hashcat
**Code/Debug:** gdb, binwalk, python3-pwntools, python3-capstone, androguard
**Hardware:** openocd, libftdi1, ftdi-eeprom, usbutils, minicom, picocom

## License

- **llama.cpp**: MIT
- **Qwen2.5 models**: Apache 2.0
- **BGE embeddings**: MIT
- **Pentest tools**: GPLv2/v3, MIT, BSD (all FOSS)
- **PhantomixOS scripts**: MIT

---

## Project Layout

```
PhantomixOS/
├── Makefile                          # Top-level build orchestration
├── README.md                         # This file
├── scripts/
│   ├── build-llamacpp.sh             # Compile llama.cpp (make, no cmake)
│   ├── download-models.sh            # Pull GGUF models from HuggingFace
│   ├── build-rootfs.sh               # debootstrap + apt (REQUIRES ROOT)
│   ├── build-iso.sh                  # squashfs + xorriso ISO assembly
│   └── verify-iso.sh                 # SHA256 + QEMU smoke test
├── python/phantomagent/               # Multi-agent framework
│   ├── __init__.py
│   ├── cli.py                        # CLI: run | server | skills
│   ├── agent.py                      # Agent + InferenceClient
│   ├── orchestrator.py               # recon→exploit→code→analysis phases
│   ├── skills_loader.py              # Dynamic /skills loader
│   └── result_logger.py              # Structured JSON → /results
├── initramfs/hooks/
│   └── 00-phantomixos-usb-detect.sh    # USB media detection + overlay
├── skills/                           # Example skill templates
│   └── EXAMPLE_SKILL.md
├── docs/
│   ├── ARCHITECTURE.md               # Full architecture reference
│   ├── BUILD_STEPS.md                # Manual build procedure
│   └── MODELS.md                    # Model selection + memory budget
└── output/                           # Build artifacts (generated)
    └── PhantomixOS-0.1.0-amd64.iso     # FINAL ISO
```
