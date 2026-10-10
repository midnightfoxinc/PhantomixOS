#!/bin/bash
# Download quantized open-weight GGUF models for the 8 GB RAM constraint.
#
# URLs below were verified against the HuggingFace API. Note that
# qwen2.5-7b-instruct q4_k_m is SHARDED upstream into two files -- a single
# -00001-of-00002 filename does not exist and returns HTTP 404.
#
# Models are optional in the ISO: the boot script falls back to /ai-models on
# the USB if these are absent. Use --optional to skip failures gracefully.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
MODEL_DIR="$ROOT/models"

OPTIONAL=0
[ "${1:-}" = "--optional" ] && OPTIONAL=1

FAILED=0

log() { echo "[models] $*"; }

download_model() {
    local url="$1"
    local dest="$2"
    local desc="$3"
    local minsize="${4:-0}"

    if [ -s "$dest" ]; then
        log "already present: $(basename "$dest")"
        return 0
    fi

    log "downloading: $desc"
    if ! wget --continue -q --show-progress "$url" -O "$dest.tmp"; then
        log "  FAILED (HTTP error): $url"
        rm -f "$dest.tmp"
        FAILED=$((FAILED + 1))
        return 1
    fi

    # Guard against a truncated or error-page download saved as the file
    local actual
    actual=$(stat -c%s "$dest.tmp" 2>/dev/null || echo 0)
    if [ "$actual" -lt "$minsize" ]; then
        log "  FAILED: got $actual bytes, expected >= $minsize (truncated?)"
        rm -f "$dest.tmp"
        FAILED=$((FAILED + 1))
        return 1
    fi

    mv "$dest.tmp" "$dest"
    log "  ok: $(basename "$dest") ($((actual / 1024 / 1024)) MB)"
}

mkdir -p "$MODEL_DIR"

log "=== Downloading GGUF models (target: 8 GB RAM) ==="

# ---- Primary reasoning agent: Qwen2.5-7B-Instruct ----
# q4_k_m is split into 2 shards (3.72 GB + 0.64 GB = 4.36 GB total).
# llama.cpp reads the -00001-of-00002 file and finds shard 2 automatically.
Q_BASE="https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main"
download_model "$Q_BASE/qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf" \
    "$MODEL_DIR/qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf" \
    "Qwen2.5-7B-Instruct Q4_K_M shard 1/2" 3500000000
download_model "$Q_BASE/qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf" \
    "$MODEL_DIR/qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf" \
    "Qwen2.5-7B-Instruct Q4_K_M shard 2/2" 500000000

# ---- Code / exploit specialist: Qwen2.5-Coder-7B-Instruct ----
# This one IS a single file (verified).
C_BASE="https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main"
download_model "$C_BASE/qwen2.5-coder-7b-instruct-q4_k_m.gguf" \
    "$MODEL_DIR/qwen2.5-coder-7b-instruct-q4_k_m.gguf" \
    "Qwen2.5-Coder-7B-Instruct Q4_K_M" 3500000000

# ---- Embeddings for skill/document RAG ----
# BAAI/bge-small-en-v1.5-GGUF has NO .gguf files; CompendiumLabs mirrors it.
E_BASE="https://huggingface.co/CompendiumLabs/bge-small-en-v1.5-gguf/resolve/main"
download_model "$E_BASE/bge-small-en-v1.5-q4_k_m.gguf" \
    "$MODEL_DIR/bge-small-en-v1.5-q4_k_m.gguf" \
    "BGE-small-en-v1.5 Q4_K_M (embeddings)" 20000000

echo ""
log "=== Summary ==="
ls -lh "$MODEL_DIR"/*.gguf* 2>/dev/null || echo "  (no model files)"
echo ""
TOTAL=$(du -sh "$MODEL_DIR" 2>/dev/null | cut -f1)
log "Total downloaded: $TOTAL"

if [ "$FAILED" -gt 0 ]; then
    echo ""
    log "WARNING: $FAILED download(s) failed."
    if [ "$OPTIONAL" -eq 1 ]; then
        log "Continuing (--optional). The ISO will load models from /ai-models instead."
    else
        log "Re-run with --optional to continue anyway, or retry the download."
        exit 1
    fi
fi

cat <<'EOF'

Memory notes (llama.cpp, 8192 context, one model at a time):
  qwen2.5-7b-instruct  q4_k_m   4.36 GB
  qwen2.5-coder-7b     q4_k_m   ~4.68 GB
  bge-small           q4_k_m   ~0.03 GB
  KV cache + buffers            ~0.9 GB
  ------------------------------------------------------
  Peak with ONE 7B resident    ~5.6 GB   (fits 8 GB)

Do not run both 7B models at once. The orchestrator runs phases
sequentially and swaps the server process between them.
EOF