# PhantomixOS - Architecture Documentation

> AI-Powered Automated Penetration Testing Live ISO
> Minimal FOSS Linux · Libre Firmware Only · Air-Gapped Capable · Fully Offline AI

## 0. Design Rationale (8GB RAM Constraint)

This is the **hard constraint** that drives every architectural decision.

| Component | Size | Notes |
|---|---|---|
| Debian slim rootfs (no GUI) | ~250 MB | No X11, no desktop, no GNOME/KDE, no telemetry |
| Pentest tools | ~600 MB | Minimal, FOSS only — no proprietary scanner suites |
| llama.cpp (CPU build) | ~20 MB | Bare binary, no extras |
| **One quantized model (7B Q4_K_M)** | **~4.5 GB** | **Peak RAM usage** |
| System overhead (tmpfs, context) | ~1.0 GB | |
| **Total peak** | **~6.4 GB** | Fits in 8GB; swap acts as buffer |

**Critical rules enforced:**
1. **Debian slim only** — rootfs stripped of everything not needed for pentesting + AI.
2. **Single model at a time** — multi-agent framework serializes context; never 2 models resident.
3. **Q4_K_M quantization** — 7B model is 4.5GB vs ~14GB unquantized.
4. **USB-persistent /persist** — settings and learned weights don't consume live RAM.
5. **Read-only root squashfs** — the ISO is immutable; /persist is the only R/W area.

---

## 1. Target Hardware Profile

```
CPU:  Intel i5-6th Gen (Skylake, x86_64)     → CPU-only inference, no CUDA
RAM:  8 GB                                    → Q4_K_M quantization mandatory
Disk: 59 GB free (host)                       → models + build workspace fit
```

Inference runs on llama.cpp CPU backend (BLAS=None). 4 cores = ~25-50 tok/s for 7B Q4.

---

## 2. Partition Layout (on boot USB)

```
┌──────────────────────────────────────────────┐
│ /boot/firmware      (FAT32, ISO image)       │  bootable
│ ┌──────────────────────────────────────────┐ │
│ │ /live            (ISO squashfs, R/O)     │ │  Debian rootfs
│ │ ├ /usr/local/share/phantomixos/llama.cpp   │ │
│ │ ├ /usr/local/bin/llama-server, llama-cli │ │
│ │ └ /usr/local/lib/python3.*/site-packages │ │
│ └──────────────────────────────────────────┘ │
│                                              │
│ /skills          (FAT32, writable tools)     │  dynamic loader
│ /results         (FAT32, writable logs)      │  all outputs
│ /ai-models       (FAT32, writable models)    │  spare/fallback models
│ /persist         (ext4, R/W overlay upper)   │  settings + learned weights
└──────────────────────────────────────────────┘
```

Boot flow: **FAT32 (PHANTOMIX) → GRUB → initramfs → detect USB → overlay /persist → launch agent**.

---

## 3. Build Components

### 3.1 Base OS
- **Debian 12 (bookworm) netinst** — minimal, FOSS, zero telemetry.
- `firmware-linux-free` is the libre firmware subset; `firmware-linux-nonfree` (the
  blob-bearing package) is deliberately **not** installed.
- Regulatory DB: `wireless-regdb` + `crda` (regulatory rules, not firmware blobs).

### 3.2 Core Pentest Tools
Package names below are verified against the Debian bookworm main index.

| Category | Tools (Debian package names) |
|---|---|
| Recon | `nmap`, `masscan`, `netcat-openbsd`, `tcpdump`, `tshark`, `dnsutils` |
| Network attack | `aircrack-ng`, `wifite`, `reaver`, `bettercap`, `hydra`, `patator` |
| Web | `gobuster`, `dirsearch`, `ffuf`, `sqlmap`, `socat` |
| RE / firmware | `binwalk`, `p7zip-full`, `python3-pwntools`, `python3-capstone`, `androguard` (pip) |

Not in Debian main and therefore **not** bundled: `nuclei`, `nikto`,
`crackmapexec`/`netexec`, `enum4linux`, `impacket-scripts`, `radare2`. Add these
from upstream if needed — see docs/VALIDATION.md.

### 3.3 Hardware Hacking
| Interface | Tooling |
|---|---|
| WiFi (libre) | aircrack-ng, bettercap, wpa-supplicant, iw, wireless-tools |
| Debug (UART/JTAG) | openocd, libftdi1, ftdi-utils, ch341-utils, usbutils |
| Peripherals | usbutils, usbmon, blkid, lsblk, parted, mtools |

### 3.4 AI Stack
| Layer | Technology |
|---|---|
| Inference engine | **llama.cpp** (open-source C; compiles with `make`, no cmake/blobs) |
| Quantization format | **GGUF** (Q4_K_M = 4-bit, high fidelity) |
| Reasoning model | Qwen2.5-7B-Instruct (~4.5GB) — strong CoT + tool use |
| Code/exploit model | Qwen2.5-Coder-7B-Instruct (~4.7GB) — best 7B for exploits |
| Embeddings | BGE-small-en-v1.5 (~55MB) — RAG over skill docs |
| Agent framework | **phantomagent** (Python, multi-agent: recon/exploit/code/analysis) |
| Skill injection | `/skills/**/*.py` loaded at runtime → registered as agent tools |
| Persistence | writes to `/results`, learns into `/persist` |

---

## 4. Agent Framework (phantomagent)

```
python/phantomagent/
├── agent.py        # Agent class + InferenceClient (llama.cpp HTTP)
├── orchestrator.py # Multi-agent: recon/exploit/code/analysis phases
├── skills_loader.py# Dynamic /skills scan, registers tools at runtime
├── result_logger.py# Structured JSON results → /results
└── cli.py          # CLI: run | server | skills
```

### Agent lifecycle per engagement:
1. **ReconAgent** — host discovery → ports → service versions → HTTP enum → DNS.
2. **ExploitAgent** — targets findings (hydra, sqlmap, ffuf, dirsearch, bettercap).
3. **CodeAgent** — writes/executes PoC exploits in sandbox.
4. **AnalysisAgent** — correlates, rates CVSS-style, produces report.

All phases share **skill tools** (dynamic plugins from /skills) and write everything to `/results`.

### Thinking (CoT) mechanism
System prompts instruct step-by-step chain-of-thought; llama.cpp `n_ctx=8192` keeps CoT + tool logs in context. Multi-agent round-robin with `n_predict=2048` per round (controls memory per turn).

---

## 5. Initramfs Boot Flow (air-gapped capable)

```
Kernel → linuxrc (initramfs)
   ├─ scan all block devices for FAT32 partitions
   ├─ match label: PHANTOMIX | PHANTOMIXOS | AI Dev ISO
   ├─ mount FAT32 (PHANTOMIX) read-only → /mnt/usb
   ├─ if /persist exists on USB:
   │     mount overlay: lowerdir=/live upperdir=/persist workdir=/persist/work
   │   else: tmpfs /persist (RAM-only, lost on reboot)
   ├─ bind-mount /results, /ai-models from USB (or create RAM-only dirs)
   ├─ copy /skills executables into /usr/local/bin (dynamic loader)
   └─ exec /sbin/init → Debian userspace → agents ready
```

USB persistence survives reboots via overlayfs; internal storage is R/O squashfs.

---

## 6. Build Directory Map

```
PhantomixOS/
├── scripts/
│   ├── build-llamacpp.sh    # clone llama.cpp + `make`
│   ├── download-models.sh   # HuggingFace GGUF downloads
│   ├── build-rootfs.sh      # debootstrap + apt (REQUIRES ROOT)
│   ├── build-iso.sh         # squashfs + xorriso ISO assembly
│   └── verify-iso.sh        # sha256 + QEMU smoke test
├── build/
│   ├── rootfs/              # Debian chroot (R/W during build)
│   ├── live/                # /live squashfs
│   ├── initramfs/           # initramfs.cpio.gz
│   └── llama.cpp/           # compiled engine
├── models/
│   ├── llama-binaries/      # built llama.cpp binaries
│   └── *.gguf               # quantized weights
├── skills/                  # example skill templates
├── python/phantomagent/      # multi-agent framework (Python 3.11+)
├── initramfs/hooks/         # USB-detection hook
├── Makefile
├── README.md
├── docs/ARCHITECTURE.md
├── docs/BUILD_STEPS.md      # fully manual repro steps
└── iso/PhantomixOS-0.1.0-amd64.iso   # FINAL ARTIFACT
```

---

## 7. Model Memory Budget

| Model | Precision | GGUF | Peak RAM w/ engine |
|---|---|---|---|
| Qwen2.5-7B-Instruct | Q4_K_M | ~4.5 GB | 4.5 + overhead |
| Qwen2.5-Coder-7B-Instruct | Q4_K_M | ~4.7 GB | 4.7 + overhead |
| BGE-small | Q4_K_M | ~55 MB | 0.06 GB |
| Gemma-2-2B (opt) | Q4_K_M | ~1.6 GB | 1.6 + overhead |

**Rule:** run **one** 7B model in memory; the other can sit on USB and be swapped in on demand. llama.cpp context at 8192 tokens = ~6MB per layer KV cache — acceptable for 8GB.
