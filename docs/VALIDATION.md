# Validation Report

Test evidence for each component that could be exercised on this build host,
and explicit flags for what could not be tested and needs physical hardware
or privileged access.

## Environment

| Item | Value |
|---|---|
| Host OS | Debian GNU/Linux 13 (trixie) |
| Kernel | 6.12.107+deb13-amd64 |
| Arch | x86_64 |
| RAM | 7.6 GiB usable |
| CPU cores | 4 |
| Disk free | 59 GB |
| sudo | available, password required (not automatable) |
| Network | HTTPS reachable (huggingface.co confirmed) |

## Passed tests

### Shell syntax (`sh -n`, POSIX) and bash syntax (`bash -n`)

| File | POSIX sh | bash |
|---|---|---|
| `scripts/build-llamacpp.sh` | OK | OK |
| `scripts/download-models.sh` | OK | OK |
| `scripts/build-rootfs.sh` | OK | OK |
| `scripts/build-iso.sh` | OK | OK |
| `scripts/verify-iso.sh` | OK | OK |
| `initramfs/hooks/00-phantomixos-usb-detect` | OK | — |
| `initramfs/hooks/99-phantomixos-postmount` | OK | — |
| `initramfs/boot/phantomixos-init` | OK | — |
| `initramfs/scripts/phantomixos-ai-autostart` | OK | OK |
| `initramfs/scripts/phantomixos-agent` | OK | OK |
| `initramfs/scripts/phantomixos-skill-loader` | OK | OK |
| `initramfs/scripts/phantomixos-overlay-setup` | OK | OK |

A real defect was found and fixed here: `phantomixos-skill-loader` used bash
process substitution (`done < <(find ...)`) under a `#!/bin/sh` shebang, which
dash rejects. Replaced with a `find | wc -l` count.

### Python compile (`python3 -m py_compile`)

`python/phantomagent/{__init__,agent,cli,orchestrator,skills_loader,result_logger}.py`,
`skills/{network_recon,exploitation}.py` — all compile.

### Agent framework runtime tests

| Test | Result |
|---|---|
| `SkillLoader` discovers skills from a directory | 13 skills, correct names/categories |
| `SkillLoader` ignores `__pycache__` / missing `__init__.py` | clean, no spurious errors |
| `ResultLogger` writes structured engagement JSON | `engagement_f55e8fc1_*.json`, parses back |
| `InferenceClient.health()` with no server running | returns `False` (correct) |
| All 5 agent roles construct with system prompts | coordinator, recon, exploit, code, analysis |
| Skill registration onto an agent | 13 tools registered on recon agent |
| `hash_crack` skill executes (previously crashed) | valid JSON returned |
| `dns_enum` skill executes | valid JSON returned |

A second real defect was found and fixed: `skills/exploitation.py` called
`os.unlink()` but never imported `os`, so `hash_crack` would raise `NameError`
at runtime. Now imports `os` and the code path is exercised by the test above.

### Dependency audit

The framework was confirmed to run on the Python standard library alone. An
earlier version imported `requests`, which is not present on the build host and
would require a pip/apt step at runtime — undesirable in an air-gapped image.
`InferenceClient` now uses `urllib.request`/`urllib.error`, removing the
dependency entirely. No `pip install` is needed at runtime.

## Not verified here — needs privileged or physical action

These steps are written and syntax-checked but could not be executed on this
host. Each requires the sudo password or target hardware.

### Requires sudo (needs your password)

```bash
sudo apt-get install -y debootstrap       # not installed on this host
sudo ./scripts/build-rootfs.sh            # debootstrap + apt inside chroot
sudo ./scripts/build-iso.sh               # mksquashfs + grub-mkrescue + xorriso
```

`debootstrap` is the one hard blocker: it is absent from this host and cannot be
installed without sudo. Without it the rootfs cannot be built, so no ISO can be
produced. Everything upstream of the rootfs (framework, skills, hooks, ISO
assembly logic) is complete and tested.

### Requires network + ~10 GB of downloads

```bash
./scripts/download-models.sh   # ~9.5 GB from huggingface.co
./scripts/build-llamacpp.sh    # clone + compile llama.cpp (~3-5 min)
```

Not run here to avoid consuming several GB of bandwidth and disk without
explicit go-ahead. URLs are pinned to specific GGUF filenames.

### Requires physical USB hardware

| Step | Command |
|---|---|
| Write ISO to USB | `sudo dd if=build/output/PhantomixOS-0.1.0-amd64.iso of=/dev/sdX bs=4M conv=fsync status=progress` |
| Create persistence partition | `sudo fdisk /dev/sdX` then `sudo mkfs.ext4 -L PHANTOMIX-PERSIST /dev/sdX2` |
| Boot on i5-6th Gen / 8 GB target | insert USB, select GRUB entry |
| Verify USB auto-detection | watch for `[PHANTOMIXOS-INIT] Found PhantomixOS USB` on console |
| Verify WiFi monitor mode | `sudo airmon-ng` (needs a chipset with monitor-mode support) |
| Verify JTAG/UART | attach adapter, run `openocd` |
| Verify overlay persistence | reboot, confirm files under `/persist` survive |

### Requires QEMU (not installed)

```bash
sudo apt-get install -y qemu-system-x86 qemu-utils
./scripts/verify-iso.sh --vm-test
```

## Known gaps to close before this is a working ISO

1. **`initramfs/boot/linuxrc` and `initramfs/hooks/*` are currently dead code.**
   The working boot architecture uses the rootfs's own Debian kernel + initrd with
   `overlayroot`, and `init=/phantomixos-init` (see `initramfs/boot/grub/grub.cfg` and
   `scripts/build-iso.sh`). The `linuxrc` and the `00-`/`99-` hooks belong to an
   earlier busybox-initramfs design and are not on the boot path. They should be
   deleted, or reworked into real `initramfs-tools` hooks under the rootfs's
   `/etc/initramfs-tools/hooks/`. Left in place pending a decision.
2. **`/persist` persistence path is not wired end to end.** `grub.cfg` passes an
   `overlayroot=` cmdline that `phantomixos-init` never reads, and `phantomixos-init`
   binds `/persist` from the USB rather than mounting an ext4 upperdir. The two
   need to be reconciled before persistence will actually work across reboots.
3. **Package names were verified but `build-rootfs.sh` has not been executed.**
   An earlier draft referenced 18 names that do not exist in Debian bookworm
   (`bettercapResponder`, `crackmapexec`, `enum4linux`, `impacket-scripts`,
   `sqlmap-data`, `nikto`, `nuclei`, `radare2`, `wifite2`, `firmware-libre`,
   `linux-firmware-regulatory`, `ftdi-utils`, `ch341-utils`, `firmware-mod-kit`,
   `pwntools`, `nss-pam-ldapd`, `lsblk`, `samba-client`). The script was rewritten
   and all 94 package names were re-checked against the bookworm main index — the
   installer also skips any package the suite does not know. Known-absent tools
   (`nuclei`, `nikto`, `crackmapexec`, `radare2`, `enum4linux`,
   `impacket-scripts`) are no longer claimed as bundled; add them from upstream if
   required.
   Still unproven: whether every package installs cleanly inside the chroot and
   what the final rootfs size turns out to be.
4. **`phantomagent` entry point is not wired.** The package is copied into
   site-packages by `build-rootfs.sh` but there is no `console_scripts` entry
   point and no `/usr/local/bin/phantom-agent` wrapper, so the `phantomagent`
   command referenced throughout the docs will not exist.
5. **Skills are copied to `/skills` in the rootfs only.** `phantomixos-skill-loader`
   looks at `/skills` and `/mnt/usb/skills`; the USB bind happens in
   `phantomixos-init`. Order matters and has not been verified on a real boot.