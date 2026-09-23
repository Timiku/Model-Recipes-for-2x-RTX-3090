# Model Recipes for 2x RTX 3090

Personal LLM recipes and startup scripts validated for my personal rig: **2× RTX 3090 Ti, 128 GB DDR4**, Windows + WSL2 + Docker. This package currently targets **Windows + WSL2**: the `.bat` files run on the Windows side and the `.sh`/`.ps1` scripts run inside your WSL distro (Docker lives there too). A Linux-native variant of the stack (Docker without WSL) is planned and will be validated later.

## What's in it

One folder per model, one subfolder per serving backend:

- **Qwen3.8-27B** — `vllm/`: four tiers across two KV lanes. MTP (the model's built-in drafter) and no-MTP on fp8 KV; then the int4-KV lane: `kvarntier` (MTP or drafter-off, the capacity tier), `kvarndflash2` (the zero-patch fallback). The `swift-mtp`/`swift-nomtp` pair serves a different checkpoint (the Swift W4A16 finetune with its own draft head) on the fp8-KV body. On Ampere (the 3090 class) the int4-KV lane is the best-performing one — fp8 KV's quantized paged path needs SM90+. Plus `llamacpp/`: the card for the native-Windows llama.cpp tier — the dependency-free fallback (no WSL, no Docker).
- **Gemma 4 31B** — `vllm/`: two tiers, MTP on (`SPEC_N=2`) and off, on the cyankiwi QAT-AWQ-INT4 checkpoint. The two windows (179K / 189K) are this pair's pool at 0.93 utilization. Pick by context: MTP wins near-empty decode speed by 2×, the plain tier wins near-full decode speed by 2×.
- **Qwen3.8-Flash-Next** — `vllm/`: two tiers (MTP depth 3, and the drafter-off K=0 arm) served in W4A16 with its 51B PLE n-gram table in FP8. The image is **built, not pulled** (the installer runs the build). Read its `MODEL.md` first: it is the one recipe here with a 128 GB+ RAM and ~121 GiB-weights class requirement.

Every model folder has the same shape:

- **`MODEL.md`** (the model root) — the model card: what the model is, its tiers and ports, the knobs, the headline numbers. The deep content (A/Bs, boot-failure records, tuning) lives in the source repo.
- **`install.bat`** — one click. Checks the prerequisites on your box, then does four stages in WSL: env, runtime area, image pull, weights (it downloads any weight folder that's missing; it shows the commands if it can't) - into the model's own `weights/` folder next to the model, or a store path of your choosing.
- **`start-*.bat`** — one per tier. Double-click, it boots the tier and tails the log in the same window. **Closing the window later is the stop signal.** A watchdog on the side kills the WSL VM when the serve process dies.
- **`stop.bat` / `/uninstall.bat`** — graceful down; uninstall removes the WSL runtime area and the pulled image (never your weights).
- **the machine deltas** (`<tier>.env`) — one per tier, beside its `start-<tier>.bat`: the box's overrides for that tier (weights path, model slugs, device pair, bind address, the max-ctx / concurrency shape). The tier's `package/<tier>.yml` template is the full default read underneath, and the delta wins key-by-key; nothing in one tier's delta can reach a sibling. The wizard's first run records your weights path and bind into all of a model's machine deltas.
- **`/package/`** — the compose ymls (one per tier) and the chat templates. `/baseline/` holds the stock 0.29.0 body each yml was derived from (sha-pinned, so every yml is always verifiable against its source); `/deltas/` is the re-derived diff the gate checks it against.


## Prerequisites

1. **WSL2, with a Linux distro in it.** If you don't have it: in a Windows terminal, `wsl --install`, then reboot. The scripts look for a distro named `Ubuntu`; if yours has another name (e.g. `Ubuntu-24.04`), set the env var `WSL_DISTRO` to that exact name (see Config). Docker and the nvidia container runtime go inside the distro — the installer does that part, not you.
2. **The NVIDIA driver** WSL2 drives the GPUs straight through it; nothing gets installed inside the distro for the GPUs. From a Windows terminal, `nvidia-smi` should list both of your cards.
3. **Git for Windows** — only to `git clone` this repo (the install itself never calls git; the distro brings its own). If you don't have it: [git-scm.com/download/win](https://git-scm.com/download/win).
4. **Python on Windows** — only for the benchmark bats (`bench.bat` etc.; the route gate is stdlib python, no packages). Booting and serving never need it. If you don't have it: [python.org/downloads](https://www.python.org/downloads/) — install with "Add python.exe to PATH" ticked. Docker and the tiers supply their own python inside the image.

The rest is setup, not install:

5. **Two GPU cards.** The recipes pin a *pair* of cards (default: 0 and 1 — the common two-card layout). A board wired differently: set `DEVICE_PAIR` (below).
6. **Disk for weights:** ~20 GB per model — flash-next is the outlier at ~121 GiB. The install downloads what's missing into the model's own `weights/` folder next to the recipe (the Windows side - the WSL distro stays lean), or a store path of your choice.
7. **RAM:** the WSL2 VM needs **64 GB+** for the 27B (the 31B wants about the same): one line in `C:\Users\<you>\.wslconfig` — `memory=64GB` under `[wsl2]`, then `wsl --shutdown` once. Nothing here touches that file. **flash-next wants 128 GB+ host RAM** and swap >= 32 GB (64 recommended); its root doc carries the box requirements.

No PowerShell execution-policy change or anything else on the system: every script that loads a PowerShell file carries its own per-invocation bypass, so a fresh box runs them as-is.

## Quick start

```
1.  `git clone` this repo

2.  Run  install.bat  from a normal window - it needs no admin rights; it gates on the prereqs and runs the four WSL stages
3.  (optional, only for LAN reach)  firewall.bat - adds the Windows inbound rules for the tier ports; it asks for its own admin rights, and the tier boots either way

4.  Boot a model tier with the bat file

5.  When you're done:  stop.bat | To tear the model out:  uninstall.bat
```

Things to know:

- **First boot takes 18–20 minutes** (patch apply, weight load, cudagraph capture; For Qwen3.8 Flash-Next: ~25 the first time — its 48.5 GiB PLE table writes through once — ~18 after). Later boots are much faster.
- **One model at a time.** The tiers both need both cards; the preflight refuses a boot while a card is busy (>4 GB held).
- **The weights live on the Windows side.** The wizard's first run points the recipe at the model's own `weights/` folder in this tree; the WSL distro carries only the runtime area (the JIT cache and the boot log), and stays lean.
- The tiers serve an OpenAI-compatible API at `PORT` (qwen **8113** MTP / no-MTP / swift, **8116** kvarntier, **8117** kvarndflash2; flash-next **8115** mtp / **8116** nomtp — the same numbers as the 27B's kvarntier and gemma's pair, harmless since exactly one tier runs at a time; gemma **8032** MTP and **8033** no-MTP). Which address you dial is the raw bind address the install wizard wrote to the tier config files (`BIND_HOST`, default `0.0.0.0` — every interface): inside the distro, `localhost`; from the Windows host, the distro's IP (a WSL2-NAT box: `wsl hostname -I`; a mirrored-mode WSL: Windows' own localhost). A `127.0.0.1` bind reaches only the loopback (on a mirrored-mode WSL, Windows' own localhost still does); a concrete IP reaches only that address.


## Benchmarks

Measured on the validation box (2×3090 Ti, 128 GB DDR4, Windows 11 + WSL 2.7.14.0), streaming 512-token generations, narrative and code prompts.

### Qwen3.8-27B

All rows: 262K ctx, same cards and same prompts. The full 262K window *fits* — KV is ~4 GiB/card because the hybrid-attention model only grows KV on its 16 full-attention layers.

| bat | what it boots | port | ctx / conc | decode: narrative | decode: code | authored here |
|---|---|---|---|---|---|---|
| `start-mtp.bat` | v0.29.0 stock image + the mounted patch bundle, built-in MTP drafter n=4 (thinking preset), fp8 KV | 8113 | 262K / 2 | **78.0** (thinking) · 93.2 (baseline payload) | **107.4** (thinking) · 165.3 (baseline payload) | the patch bundle (mamba-copy-bounds, spec-decode bounds + row-classification, draft-vocab, GDN async order, FlashInfer decode pin) + the yml delta |
| `start-nomtp.bat` | same image + bundle, drafter off (`SPEC_N=0`), fp8 KV | 8113 | 262K / 2 | **76.1** (thinking) · 74.5 (baseline payload) | **149.6** (thinking) · 152.8 (baseline payload) — 3-run medians | same bundle; the drafter-off stance in its own delta |
| `start-kvarndflash2.bat` | v0.29.0 + the KVarN bundle, external DFlash2 drafter n=7 on int4 KV | 8117 | 262K / 1 | — | **76.2** | the KVarN bundle (`_shared/patches/vllm-kvarn-0290`, from cpuchip's 0.29 port) + the DFlash2 W4A16 KV-dequant backport |
| `start-kvarntier.bat` / `start-kvarnmtp.bat` | v0.29.0 + the KVarN bundle, MTP n=4 or off on int4 KV | 8116 | 262K / 2 · 4 | the capacity lane | | the bundle + this repo's tier composition (ymls + stances) |

### Gemma 4 31B

| bat | tier | port | ctx / conc | near-empty ctx | near-full window | authored here |
|---|---|---|---|---|---|---|
| `start-gemma-dual.bat` | MTP on (SPEC_N=2) | 8032 | 179,040 / 2 | 92.6–116.8 tok/s | 13.1–15.0 tok/s at ~170K | the re-aimed yml: the source's shape rebased to this pair's pool (0.93 utilization, the 179040 window the first boot pinned) + the provenance-gated delta |
| `start-gemma-dual-nomtp.bat` | no MTP | 8033 | 189,000 / 2 | 57.5–57.9 tok/s | **28.8–29.0** tok/s at ~185K | same rebase; the source's proven no-MTP form at the pool this pair holds |

The interesting one: at near-full context the plain tier beats the MTP tier by 2×, and near-empty it's the other way around — run the one that matches your context. (TTFT at near-full is ~5.6–6 min; that's the 170–185K prefill, not the decode.)

### Qwen3.8-Flash-Next

Single stream only: the KV pool is exactly one full-window request (`MAX_NUM_SEQS=1`). Two concurrent streams were tested and collapse under WSL2.

| bat | tier | port | ctx / conc | short ctx | at the window edge | authored here |
|---|---|---|---|---|---|---|
| `start-mtp.bat` | MTP depth 3 | 8115 | 256,000 / 1 | **35.65 tok/s** (TTFT 2.5 s) | **35.97** at 251,904-in (TTFT ~520 s) | the built image (Dockerfile on the digest-pinned vendor base), the sha-guarded QSA overlay |
| `start-nomtp.bat` | drafter off (K=0) | 8116 | 256,000 / 1 | **26.36 tok/s** | **25.80** at 251,904-in | same stack; the K=0 shape (spec flag omitted) is a local delta — upstream has no drafter off |

Decode is flat to the 256K window edge — long ≈ short is the headline of this model, at a 256K-class TTFT no other recipe here reaches in 48 GiB of pool. The drafter buys **1.35–1.39x** over the K=0. For context: native-Linux host reads 86–89 tok/s at depth with the same stack; the gap is the WSL2 hypervisor tax on this model's per-step PLE/expert streaming (~2.4x decode, ~3.7x long-context wait) — measured, not configurable.


## Config params

Two levels. Windows-side env vars:

| var | what it does |
|---|---|
| `WSL_DISTRO` | your distro's name (every script defaults to `Ubuntu` if unset) |

Everything else lives in the **machine deltas** — one per tier, beside the bats, named `<tier>.env` (`mtp.env`, `gemma-dual-nomtp.env`, ...). Each is plain `KEY=value` (docker compose .env format) that overrides its tier's `package/<tier>.yml` template key-by-key, so a setting in one can't leak into a sibling tier; edit a line in place and a boot honors it. The wizard owns the file: a package update prompts keep-or-reset, and `WEIGHTS_DIR` is never touched.

| knob | where | what it does |
|---|---|---|
| `WEIGHTS_DIR` | all | where the checkpoints live (the wizard's first run points it at the model's own `weights/` folder in the tree; blank = the yml's tree-relative fallback, that same folder) |
| `TARGET_MODEL` | all | which checkpoint folder inside `WEIGHTS_DIR` to load |
| `DEVICE_PAIR` | all | which two cards the tiers run on (the yml's default is `0,1`; the wizard's device step writes it) |
| `BIND_HOST` | all | who may reach the API: the raw address the tier binds to — `0.0.0.0` (every interface, the default) / `127.0.0.1` (the loopback only) / a concrete IP (only that address) — the wizard's bind step writes it |
| `PORT` / `MAX_MODEL_LEN` / `GPU_MEMORY_UTILIZATION` | all | the API port / the context window / the VRAM fraction the pool takes (each tier's file carries its proven value) |
| `SPEC_N` / `MAX_NUM_SEQS` | 27b, gemma | how many draft tokens / concurrent streams (the MTP file documents the pool math for its stance; each gemma tier's file carries its own value, so no tier's drafter can be armed by its sibling) |
| `KV_CACHE_DTYPE` / `MAX_NUM_BATCHED_TOKENS` | 27b, gemma | KV dtype (blank = auto; `kvarn_k4v2_g128` on the int4 lane) / prefill chunk size |
| `DRAFTER_MODEL` | 27b DFlash2 + swift, gemma | which drafter checkpoint to load (the external-drafter tiers and gemma's MTP pair) |
| `W4A8` / `MAMBA_CACHE_MODE` / `PREFIX_MATCH_UNIT` | 27b | int8 activations (the shipped stance) / the GDN state alignment / the prefix-match granularity — measured stances, leave them |
| `TEMP` / `TOP_P` / `TOP_K` / `MIN_P` / `PRESENCE_PENALTY` | all | the sampler - the 27b files carry the model card's thinking row (the instruct row is reached by editing the lines); the gemma files carry the card's one standardized row |
| `ENABLE_THINKING` / `REASONING_EFFORT` | 27b | the thinking on/off switch and its effort level |
| `CHAT_TEMPLATE` | all | repoint the chat template (a `.jinja` name in the model's `vllm/templates/`; blank = the model's own canonical template) |

Each model folder's root doc (`MODEL.md` / `README.md`) carries the full knob record — what each line costs, measured.

## Upstream Repos

- [noonghunna/club-3090](https://github.com/noonghunna/club-3090) — the community dual-3090 slug the compose files derive from; every local deviation (the WSL2 fixes, the card pin, the chat template, the container names) is listed in the yml header and diffed against the archived source in `upstream/`.
- [syv-ai/HyperQwen](https://github.com/syv-ai/HyperQwen) (née syv-ai/qwen38-27b-rtx3090) — the qwen3.8-27b recipe line this package's MTP/nomtp tiers descend from: the W4A16 drafter and the `qwen3_dflash` KV-dequant (the DFlash2 lane), the mamba-align checkpoints patch, and the MTP + fp8-KV + flashinfer work the spec-decode tiers build on.
- [cpuchip/vllm](https://github.com/cpuchip/vllm) — the 0.29.0 patch exports behind the KVarN bundle: `kvarn-0.29.0` and `kvarn-v2-runner-0.29.0`, plus the `port-0.29` branch of the HyperQwen KVarN port.
- [huawei-csl/KVarN](https://github.com/huawei-csl/KVarN) — the int4-KV cache backend itself (the modules under `_shared/patches/vllm-kvarn-0290/files/`), Apache-2.0, sm_86-native.
- [AntonProkopyev/fa2-fp8kv-sm86](https://github.com/AntonProkopyev/fa2-fp8kv-sm86) — the FlashAttention-2 FP8-KV kernels for Ampere, consumed digest-pinned as a prebuilt image (the provenance lives in the patch README).
- [DominikBucko/qwen38-flash-next-2x3090](https://github.com/DominikBucko/qwen38-flash-next-2x3090)
  — the community 2x3090 flash-next line: the digest-pinned base image, the sha-guarded vLLM overlay, and the serve wrapper that `qwen38-flash-next-2x3090:locked` is built from.
