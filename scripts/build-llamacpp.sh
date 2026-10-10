#!/bin/bash
# Build llama.cpp from source (CPU-only, fully open-source).
#
# NOTE: upstream removed the Makefile build in favour of CMake; the repo's
# Makefile is now a stub that aborts with "Build system changed". CMake is
# therefore required. Only cmake + a C++ compiler are needed -- no CUDA, no
# BLAS, no OpenSSL.
#
# Usage:
#   ./scripts/build-llamacpp.sh
#   LLAMA_PIN=b<tag> ./scripts/build-llamacpp.sh   # build a specific ref

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
LLAMA_SRC="$ROOT/build/llama.cpp"
BIN_OUT="$ROOT/models/llama-binaries"

log() { echo "[llama] $*"; }

# ---- Preflight ----
for tool in cmake git make; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        log "ERROR: '$tool' not found."
        if [ "$tool" = "cmake" ]; then
            log "       Install it with:  sudo apt-get install -y cmake"
        fi
        exit 1
    fi
done

# A C++ compiler is required (llama.cpp is C++)
if ! command -v c++ >/dev/null 2>&1 && ! command -v g++ >/dev/null 2>&1; then
    log "ERROR: no C++ compiler found. Install with:  sudo apt-get install -y g++"
    exit 1
fi

log "=== Building llama.cpp (CPU-only, open-source) ==="

# ---- Fetch source ----
if [ -d "$LLAMA_SRC/.git" ]; then
    log "Reusing existing clone at build/llama.cpp"
    if [ -n "${LLAMA_PIN:-}" ]; then
        log "Checking out pinned ref: $LLAMA_PIN"
        git -C "$LLAMA_SRC" fetch --depth 1 origin "$LLAMA_PIN" || \
            log "  WARNING: could not fetch ref $LLAMA_PIN"
        git -C "$LLAMA_SRC" checkout "$LLAMA_PIN" || \
            log "  WARNING: could not check out $LLAMA_PIN"
    fi
else
    [ -d "$LLAMA_SRC" ] && rm -rf "$LLAMA_SRC"
    log "Cloning llama.cpp (shallow)..."
    if [ -n "${LLAMA_PIN:-}" ]; then
        git clone --depth 1 --branch "$LLAMA_PIN" \
            https://github.com/ggml-org/llama.cpp "$LLAMA_SRC"
    else
        git clone --depth 1 https://github.com/ggml-org/llama.cpp "$LLAMA_SRC"
    fi
fi

log "Source revision: $(git -C "$LLAMA_SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# ---- Configure ----
BUILD_DIR="$LLAMA_SRC/build-phantomixos"
log "Configuring (CPU-only, no CUDA/BLAS/OpenSSL)..."
cmake -S "$LLAMA_SRC" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=ON \
    -DLLAMA_CURL=OFF \
    -DGGML_CUDA=OFF \
    -DGGML_VULKAN=OFF \
    -DGGML_HIPBLAS=OFF \
    -DGGML_METAL=OFF \
    -DGGML_BLAS=OFF \
    -DGGML_OPENMP=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=ON \
    2>&1 | tail -8

# ---- Build ----
# NOTE: there is no llama-embedding target any more. Upstream dropped
# tools/embedding and folded embedding extraction into the server, which
# exposes /embedding, /embeddings and /v1/embeddings. So the three targets
# below are the complete set; asking for llama-embedding fails the build with
# "No rule to make target".
log "Compiling with $(nproc) threads (a few minutes)..."
cmake --build "$BUILD_DIR" --config Release -j"$(nproc)" \
    --target llama-server llama-cli llama-bench 2>&1 | tail -15

# ---- Stage binaries ----
rm -rf "$BIN_OUT"
mkdir -p "$BIN_OUT"

FOUND=0
for name in llama-server llama-cli llama-bench; do
    # CMake puts executables either directly in build/ or in build/bin/
    src="$(find "$BUILD_DIR" -maxdepth 2 -type f -name "$name" -perm -u+x 2>/dev/null | head -1)"
    if [ -n "$src" ]; then
        cp "$src" "$BIN_OUT/"
        FOUND=$((FOUND + 1))
    else
        log "  WARNING: $name not produced by this build"
    fi
done

if [ "$FOUND" -eq 0 ]; then
    log "ERROR: no llama.cpp binaries were produced."
    log "Build tree contents:"
    find "$BUILD_DIR" -maxdepth 2 -type f -perm -u+x 2>/dev/null | head -20
    exit 1
fi

# Copy any shared libs next to the binaries so the ISO can run them
SHLIB_DIR="$BUILD_DIR/bin"
if [ -d "$SHLIB_DIR" ]; then
    mkdir -p "$BIN_OUT/lib"
    find "$SHLIB_DIR" -name "*.so*" -exec cp {} "$BIN_OUT/lib/" \; 2>/dev/null || true
    find "$BUILD_DIR" -maxdepth 1 -name "*.so*" -exec cp {} "$BIN_OUT/lib/" \; 2>/dev/null || true
fi

log ""
log "Built binaries:"
ls -lh "$BIN_OUT" | sed 's/^/  /'
log ""
log "Total: $(du -sh "$BIN_OUT" | cut -f1)"
log "=== llama.cpp build complete ==="