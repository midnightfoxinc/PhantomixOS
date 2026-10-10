# PhantomixOS - AI-Powered Offline Penetration Testing Live ISO
# Minimal, open-source, privacy-respecting, air-gapped capable

.PHONY: all help setup-deps llamacpp models pentest-tools build-rootfs build-iso verify clean distclean

# User-configurable variables
BUILD_DIR   := build
ISO_NAME    := PhantomixOS
VERSION     := 0.1.0
ARCH        := amd64
DEBIAN_SUITE:= bookworm
DEBIAN_MIRROR:= http://deb.debian.org/debian

# Directories
ROOTFS_DIR  := $(BUILD_DIR)/rootfs
LIVE_DIR    := $(BUILD_DIR)/live
OUTPUT_DIR  := $(BUILD_DIR)/output
MODEL_DIR   := models
SCRIPTS_DIR := scripts

# Default target
all: setup-deps models build-rootfs build-iso verify

# Help target
help:
	@echo "PhantomixOS Build Targets:
	@echo "  setup-deps   - Install build-time dependencies (requires sudo)"
	@echo "  llamacpp     - Build llama.cpp from source (CPU-only)"
	@echo "  models       - Download quantized GGUF models"
	@echo "  build-rootfs - Build Debian chroot rootfs (REQUIRES SUDO)"
	@echo "  build-iso    - Assemble hybrid ISO (UEFI+BIOS)"
	@echo "  verify       - Check ISO integrity + optional QEMU smoke test"
	@echo "  clean        - Remove build artifacts (keep models/)"
	@echo "  distclean    - Remove everything (including models/)"
	@echo ""
	@echo "Example workflow:"
	@echo "  make setup-deps"
	@echo "  make models"
	@echo "  sudo make build-rootfs"
	@echo "  make build-iso"
	@echo "  make verify"

# Install build-time dependencies (host system)
setup-deps:
	@echo "[*] Installing build-time dependencies..."
	sudo apt-get update && sudo apt-get install -y \
		debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin \
		mtools dosfstools python3 python3-pip git wget curl jq make gcc g++ \
		cpio parted fdisk
	@echo "[+] Build dependencies installed."

# Build llama.cpp (CPU-only, no blobs)
llamacpp:
	@echo "[*] Building llama.cpp (CPU-only, open-source)..."
	mkdir -p $(BUILD_DIR)
	if [ ! -d "$(BUILD_DIR)/llama.cpp" ]; then \
		echo "[*] Cloning llama.cpp..."; \
		git clone --depth 1 https://github.com/ggerganov/llama.cpp $(BUILD_DIR)/llama.cpp; \
	fi
	cd $(BUILD_DIR)/llama.cpp && \
		echo "[*] Compiling with make (no CUDA/OpenBLAS)..." && \
		make -j$$(nproc) LLAMA_CUBLAS=0 GPU=0 BLAS=None
	mkdir -p $(MODEL_DIR)/llama-binaries
	cp $(BUILD_DIR)/llama.cpp/bin/* $(MODEL_DIR)/llama-binaries/ 2>/dev/null || true
	@echo "[+] llama.cpp binaries copied to $(MODEL_DIR)/llama-binaries/"
	@ls -lh $(MODEL_DIR)/llama-binaries/llama-server $(MODEL_DIR)/llama-binaries/llama-cli 2>/dev/null | head -2

# Download quantized GGUF models
models: llamacpp
	@echo "[*] Downloading quantized GGUF models (target: 8GB RAM)..."
	mkdir -p $(MODEL_DIR)
	cd $(MODEL_DIR) && \
		wget --continue --show-progress https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m.gguf && \
		wget --continue --show-progress https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf && \
		wget --continue --show-progress https://huggingface.co/BAAI/bge-small-en-v1.5-GGUF/resolve/main/bge-small-en-v1.5-q4_k_m.gguf
	@echo "[+] Model download complete."
	@ls -lh $(MODEL_DIR)/*.gguf

# Build Debian chroot rootfs (REQUIRES ROOT)
build-rootfs: models
	@echo "[*] Building Debian $(DEBIAN_SUITE) rootfs (requires sudo)..."
	@if [ ! -f "/usr/sbin/debootstrap" ]; then \
		echo "[!] debootstrap not found. Run 'make setup-deps' first."; \
		exit 1; \
	fi
	sudo $(SCRIPTS_DIR)/build-rootfs.sh
	@echo "[+] Rootfs built at $(ROOTFS_DIR)"

# Assemble hybrid ISO (UEFI+BIOS friendly)
build-iso: build-rootfs
	@echo "[*] Building PhantomixOS $(VERSION) ISO..."
	sudo $(SCRIPTS_DIR)/build-iso.sh
	@echo "[+] ISO assembled at $(OUTPUT_DIR)/$(ISO_NAME)-$(VERSION)-$(ARCH).iso"

# Verify ISO integrity and run optional VM test
verify: build-iso
	@echo "[*] Verifying PhantomixOS $(VERSION)..."
	$(SCRIPTS_DIR)/verify-iso.sh $(OUTPUT_DIR)/$(ISO_NAME)-$(VERSION)-$(ARCH).iso
	@echo "[+] Verification complete."

# Clean build artifacts (keep models/)
clean:
	@echo "[*] Cleaning build artifacts..."
	sudo rm -rf $(BUILD_DIR)/rootfs $(BUILD_DIR)/live $(BUILD_DIR)/initramfs $(BUILD_DIR)/output
	@echo "[+] Cleaned build/ artifacts."

# Distclean (remove models too)
distclean: clean
	@echo "[*] Removing all build artifacts including models..."
	sudo rm -rf $(MODEL_DIR)/*
	@echo "[+] Cleaned models/ directory."

# Phony targets
.PHONY: all help setup-deps llamacpp models pentest-tools build-rootfs build-iso verify clean distclean