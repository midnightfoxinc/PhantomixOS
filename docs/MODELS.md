# Model Selection for PhantomixOS (8GB RAM Target)

> Criteria: fully open weights (GGUF), permissive license, fits 8GB when quantized, strong reasoning/code abilities, offline capable.

---

## Why GGUF + llama.cpp?

| Requirement | Satisfied by |
|---|---|
| Fully open-source inference engine | llama.cpp (MIT) |
| No proprietary blobs / CUDA dependency | CPU-only build (BLAS=None) |
| Quantization for 8GB RAM | GGUF (Q4_K_M: 4-bit, ~50% size vs fp16) |
| Context length ≥ 8K for CoT + tools | 8192 tokens (llama.cpp default) |
| CPU-optimized (AVX2 on i5-6th Gen) | llama.cpp uses AVX2 if available |

---

## Candidate Models (all GGUF, Q4_K_M unless noted)

### Primary Reasoning Agent
1. **Qwen2.5-7B-Instruct** (Q4_K_M)  
   - Size: ~4.5 GB  
   - License: Apache 2.0  
   - Strengths: State-of-the-art 7B reasoning, 32K context (we use 8K), excellent instruction following, tool use, multilingual  
   - HuggingFace: `Qwen/Qwen2.5-7B-Instruct-GGUF`

2. **Phi-3-medium-128k-instruct** (Q4_K_M)  
   - Size: ~4.1 GB  
   - License: MIT  
   - Strengths: Microsoft's 14B→3.8B via grouping, strong reasoning, 128K context  
   - HF: `microsoft/Phi-3-medium-128k-instruct-GGUF`

3. **Mistral-Nemo-Instruct-2407** (Q4_K_M)  
   - Size: ~4.6 GB  
   - License: Apache 2.0  
   - Strengths: NVIDIA + Mistral, strong reasoning, tool use, 32K context  
   - HF: `TheBloke/Mistral-Nemo-Instruct-2407-GGUF`

### Code/Exploit Specialist
1. **Qwen2.5-Coder-7B-Instruct** (Q4_K_M) — **CHOSEN**  
   - Size: ~4.7 GB  
   - License: Apache 2.0  
   - Strengths: #1 on LiveCodeBench, excellent for exploit dev, reverse engineering, PoC generation, understands C/Python/asm/shell  
   - HF: `Qwen/Qwen2.5-Coder-7B-Instruct-GGUF`

2. **DeepSeek-Coder-V2-Instruct** (Q4_K_M)  
   - Size: ~6.1 GB (too big alone) → use Q6_K or split  
   - License: MIT  
   - Strengths: State-of-the-art code, but too large for 8GB with overhead  
   - HF: `deepseek-ai/deepseek-coder-v2-instruct`

3. **CodeLlama-7B-Instruct** (Q4_K_M)  
   - Size: ~4.1 GB  
   - License: Meta  
   - Strengths: Good code, but weaker than Qwen2.5-Coder  
   - HF: `TheBloke/CodeLlama-7B-Instruct-GGUF`

### Embeddings (for RAG over skills/docs)
1. **BAAI/bge-small-en-v1.5** (Q4_K_M) — **CHOSEN**  
   - Size: ~55 MB  
   - License: MIT  
   - Strengths: 384-dim, excellent retrieval, fast, small  
   - HF: `BAAI/bge-small-en-v1.5-GGUF`

2. **Snowflake/snowflake-arctic-embed-l** (Q4_K_M)  
   - Size: ~334 MB  
   - License: Apache 2.0  
   - Strengths: SOTA, but overkill for skill RAG  
   - HF: `Snowflake/snowflake-arctic-embed-l-GGUF`

---

## Final Selection (quantized GGUF)

| Role | Model | Size | Why |
|---|---|---|---|
| **Primary Agent** (reasoning, planning, tool use) | `qwen2.5-7b-instruct-q4_k_m.gguf` | 4.3 GB | Best 7B reasoning, strong instruction following, multilingual |
| **Code/Exploit Specialist** | `qwen2.5-coder-7b-instruct-q4_k_m.gguf` | 4.7 GB | Top-tier coding & exploit generation, understands binaries/network |
| **Embeddings** (skill/doc retrieval) | `bge-small-en-v1.5-q4_k_m.gguf` | 55 MB | Tiny, fast, excellent for RAG over skill descriptions |
| **Optional Router** (if space permits) | `gemma-2-2b-it-q4_k_m.gguf` | 1.6 GB | Fast classification, can route queries to specialists |

### Memory Footprint (llama.cpp + context)

```
Base engine (llama-server binary):     ~20 MB
Context buffer (8192 tokens * 2 bytes per token * n_layers * 2):  ~1.0 GB
Model weights (Q4_K_M, 7B):            ~4.5 GB
Runtime overhead (Python agent, skills): ~0.8 GB
---------------------------------------------------------
Peak RAM (one model resident):         ~6.3 GB
Available for tmpfs / tools:           ~1.5 GB
```

### Multi-Agent Strategy (to fit 8GB)

The orchestrator **never loads two 7B models simultaneously**:
1. **Phase 1 (Recon)**: Load reasoning agent (Qwen2.5-7B) → host/port scan.
2. **Phase 2 (Exploit)**: Unload reasoning, load coder agent → write/exploit.
3. **Phase 3 (Code)**: Keep coder agent loaded → PoC generation.
4. **Phase 4 (Analysis)**: Load reasoning agent → correlate/report.

Embeddings (BGE-small) stay resident (~55MB) for RAG over `/skills` docs.

All model weights live on USB (`/ai-models` or `/live/...`), so swapping is just a file copy + process restart (takes ~5s).

---

## Why Not Larger Models?

- **70B models**: Even Q4 = ~35 GB → impossible on 8GB
- **13B Q4**: ~7.5 GB → leaves almost no room for context/tools/OS
- **8-bit quantization (Q8_0)**: ~2x size of Q4 → defeats purpose

### Why Not Smaller (3B) Models?

- 3B Q4 = ~2 GB → fits easily, but:
  - Reasoning ability drops sharply for multi-step pentest planning
  - Code generation quality insufficient for exploit dev
  - Tool use (JSON/function calling) unreliable

The 7B Q4 is the **sweet spot**: sufficient for chain-of-thought reasoning, tool use, and code generation while fitting in 8GB with overhead.

---

## Licensing Compliance

All selected models:
- **Qwen2.5 series**: Apache 2.0 (permissive)
- **BGE-small**: MIT (permissive)
- **llama.cpp**: MIT
- **Debian base**: DFSG-free (GPL/Apache/MIT/BSD)
- **Pentest tools**: GPLv2/v3, MIT, BSD (all FOSS)

→ **100% FOSS, zero proprietary blobs or non-redistributable content**

---

## Performance Expectations (i5-6th Gen, 8GB)

| Metric | Estimate |
|---|---|
| Token generation (llama.cpp, 4 cores) | 20-40 tok/s (Q4_K_M) |
| Context load (8K tokens) | ~2-4s |
| Model swap (USB → RAM) | ~5-8s (USB 2.0) |
| Recon phase (full /24) | 2-5 min (nmap + tool use) |
| Exploit phase (per finding) | 30s-2min (PoC gen + test) |
| Full engagement (/24) | 15-45 min (depends on findings) |

Llama.cpp uses AVX2/AVX on Skylake (i5-6th Gen) for ~2x speedup vs fallback.

---