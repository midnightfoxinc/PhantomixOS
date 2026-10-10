# Memory Budget — 8 GB Target

Goal: keep the OS footprint small enough that the LLM has the memory it needs.
This document separates what actually consumes RAM from what only consumes
*disk*, because the two are routinely confused on a live ISO.

## The key distinction

A squashfs rootfs is **file-backed page cache**, not anonymous memory. When RAM
runs short the kernel simply evicts those clean pages and re-reads them from the
ISO on next access. So a 600 MB rootfs does **not** permanently cost 600 MB of
RAM. What genuinely has to stay resident is:

- the LLM's active working set (weights being decoded + KV cache)
- the kernel, initrd, and the running init/userspace
- whatever anonymous memory the tools allocate during a scan

This is why the rootfs was kept slim anyway: a smaller rootfs means fewer page
cache pages competing with the model, and much faster boot.

## Where the memory actually goes

### Rootfs (squashfs) — file-backed, evictable

Measured from the Debian bookworm package index (`Installed-Size` of the 94
packages in `scripts/build-rootfs.sh`, before `apt clean` and doc removal):

| Component | Size on disk | Notes |
|---|---|---|
| 94 direct packages | 333 MB | sum of `Installed-Size` |
| + shared dependencies | ~533 MB | typical 1.6x multiplier |
| after `apt clean` + doc/man removal | ~380–450 MB | what actually lands in squashfs |
| kernel + initrd (excluded from squashfs, loaded by GRUB) | ~120 MB | initrd is tmpfs → real RAM while booting |

No GUI, no desktop environment, no display manager, no audio stack. `nmap`,
`tshark`, `hashcat` etc. are CLI-only and sit idle until invoked.

### LLM — the dominant consumer

For `qwen2.5-7b-instruct-q4_k_m.gguf` at `llama-server` defaults:

| Item | Size | Type |
|---|---|---|
| Model weights (Q4_K_M, 7B) | ~4.68 GB | file-backed (mmap, evictable) |
| KV cache @ 8192 ctx | ~0.6 GB | anonymous, **not** evictable |
| Compute/scratch buffers | ~0.3 GB | anonymous |
| llama-server process overhead | ~50 MB | anonymous |
| **Active set** | **~5.6 GB** | |

### Full-system estimate at steady state

```
Total physical                                      8.0 GB
─────────────────────────────────────────────────────────
Kernel + initrd + systemd userspace                 0.25 GB   anonymous
Rootfs working set (hot pages only)                  0.40 GB   file-backed, evictable
Agent framework + skills (Python)                   0.10 GB   anonymous
llama-server active set (KV + buffers)              0.95 GB   anonymous
Model weights being decoded                        ~4.70 GB   file-backed, evictable
─────────────────────────────────────────────────────────
Headroom for scans (nmap buffers, pcap capture)     ~1.6 GB
```

## Rules enforced in the code

1. **One model resident at a time.** The orchestrator runs phases sequentially
   and does not hold two 7B models. Switching models is a process restart
   (~5–10 s), not a concurrent load.
2. **No `--mlock`.** Deliberately omitted — see the comment in
   `initramfs/scripts/phantomixos-ai-autostart`. mlock makes the model
   unswappable and OOM-kills the box on 8 GB.
3. **Context capped at 8192.** KV cache grows linearly with context; 8192 keeps
   it near 0.6 GB. Raise with `PHANTOMIXOS_LLM_CONTEXT` if you have headroom.
4. **All models on disk.** GGUF files live on the squashfs or on `/ai-models` on
   the USB. Nothing is copied into RAM at boot.
5. **Graceful degradation.** `phantomixos-ai-autostart` checks `MemAvailable`
   before starting and warns below 4.5 GB. The Coder model is not loaded unless
   explicitly requested.
6. **`--no-warmup` avoided.** A warmup pass costs a few seconds at start but
   avoids a cold first request mid-scan.

## Measured, not estimated

The numbers above for the rootfs are computed from package metadata. The LLM
figures are analytical. To get real numbers, boot the ISO and run:

```bash
free -h
# after starting the model:
ps -o pid,rss,vsz,cmd -C llama-server
grep -E 'VmRSS|VmSize' /proc/$(pgrep -f llama-server)/status
# drop page cache to see the floor:
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches
free -h
```

Record the post-drop figure — that is the true steady-state footprint, and it is
the number that decides whether a 7B model is viable on your specific 8 GB part.

## If you need more headroom

In order of effectiveness:

1. **Drop to a 3–4B model.** Qwen2.5-3B Q4_K_M is ~1.9 GB, leaving ~2.8 GB more
   for tools. Reasoning quality drops noticeably, but scanning still works.
2. **Reduce context to 4096.** Saves ~300 MB of KV cache.
3. **Stop the model between phases.** `kill $(cat /run/phantomixos/llama.pid)` while
   scanning, restart before reasoning.
4. **Use a 2B router model** (`gemma-2-2b-it` Q4_K_M, ~1.6 GB) for triage and
   escalate to the 7B only for findings that need real reasoning.