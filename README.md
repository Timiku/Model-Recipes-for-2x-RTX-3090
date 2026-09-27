# Model Recipes for 2x RTX 3090

LLM serving recipes and startup scripts tested on one machine: **2× RTX 3090 Ti, 128 GB DDR4**. There are two ways to run them, and both use the same compose files and the same per-tier config:

- **Windows + WSL2.** You double-click `.bat` files on Windows; they drive Docker inside your WSL distro. This is the path with the longest test history.
- **Native Linux.** Docker runs on the host, no WSL. Each model has `install.sh`, `start-<tier>.sh`, `stop.sh` and `uninstall.sh`.

## Models

Each model has its own folder, with one subfolder per serving backend.

**Qwen3.8-27B** (`qwen3.8-27b/`). Eight vLLM tiers in three groups:

- fp8 KV cache: `mtp` (the model's built-in MTP drafter), `nomtp` (drafter off) and `superfast` (the external DFlash2 drafter).
- int4 KV cache (KVarN): `kvarntier` (drafter off), `kvarnmtp` (MTP n=4) and `kvarndflash2` (DFlash2 drafter). On Ampere cards this is the best-performing group, because fp8 KV's quantized paged path needs SM90+.
- Swift: `swift-mtp` and `swift-nomtp` serve a different checkpoint, the Swift W4A16 finetune with its own draft head, on the fp8-KV setup.

There is also a `llamacpp/` card for running the model with stock llama.cpp on Windows, with no WSL or Docker.

**Gemma 4 31B** (`gemma4-31b/`). Two vLLM tiers on the cyankiwi QAT-AWQ-INT4 checkpoint: MTP on (`SPEC_N=2`, 179K window) and MTP off (189K window). Pick by how full your context runs: MTP is about 2× faster near an empty context, the plain tier about 2× faster near a full one.

**Qwen3.8-Flash-Next** (`qwen3.8-flash-next/`). Two vLLM tiers, MTP depth 3 and drafter off, served as W4A16 with its 51B PLE n-gram table in FP8. The installer **builds** this image instead of pulling it. Read its `MODEL.md` before installing: it needs 128 GB+ of RAM and about 121 GiB of disk for weights.

## Folder layout

Every model folder has the same shape:

| path | what it is |
|---|---|
| `MODEL.md` | The model card: tiers, ports, settings, measured speeds. Longer write-ups (A/B tests, boot-failure notes, tuning) live in the author's source repo, not here. |
| `vllm/install.bat` / `install.sh` | Checks prerequisites, asks three setup questions (which two GPUs, which network address to listen on, where the weights go), then sets up Docker, the runtime folder, the image and the weights. Missing weights are downloaded into the model's own `weights/` folder or a path you choose; where no download source is known, it prints the commands instead. |
| `vllm/start-<tier>.bat` / `.sh` | One per tier. Boots the tier and shows its log. **Windows:** closing the window stops the tier; a watchdog shuts the WSL VM down when the server process dies. **Linux:** Ctrl-C only detaches from the log and the container keeps running; use `stop.sh`. There is no watchdog on Linux. |
| `vllm/stop.bat` / `stop.sh` | Stops every tier of that model. |
| `vllm/uninstall.bat` / `uninstall.sh` | Removes the runtime folder and the Docker image. The image is kept if another model still uses it. The Windows uninstaller never deletes weights; the Linux one offers to delete the whole model folder at the end (see [Uninstalling](#uninstalling)). |
| `vllm/<tier>.env` | Your machine's settings for one tier: weights path, model names, GPU pair, listen address, context length and concurrency. |
| `vllm/package/<tier>.yml` | The compose file for the tier. It holds every default; a value in `<tier>.env` overrides it key by key. A setting in one tier's `.env` never affects another tier. |
| `vllm/baseline/`, `vllm/deltas/` | The reference compose files each package yml was derived from, and the list of allowed differences. `_shared/scripts/yml-provenance.py` checks one against the other. |

## Prerequisites

### Windows + WSL2

1. **WSL2 with a Linux distro.** If you don't have it, run `wsl --install` in a Windows terminal and reboot. The scripts look for a distro named `Ubuntu`. If yours is called something else (for example `Ubuntu-24.04`), set the Windows environment variable `WSL_DISTRO` to that exact name. You don't install Docker yourself: the installer puts Docker Engine and the NVIDIA container runtime inside the distro.
   - ⚠️ **WSL kernel warning:** kernels 6.18.33 and later (WSL 2.7.5 to 2.9.13) have an unfixed dxgkrnl GPU bug that causes CUDA "device not ready" errors and random GPU engine deaths with no Xid. Kernel 6.6.114.1 is fine. If you hit this, downgrade to [WSL 2.7.3](https://github.com/microsoft/WSL/releases/tag/2.7.3) and skip `wsl --update` until [the fix](https://github.com/microsoft/WSL/issues/41060) ships.
2. **The NVIDIA driver on Windows.** WSL2 uses it directly; nothing GPU-related goes inside the distro. `nvidia-smi` in a Windows terminal should list both cards.
3. **Git for Windows**, only to clone this repo. The installer never calls it. [git-scm.com/download/win](https://git-scm.com/download/win)
4. **Python 3.9 or newer on Windows**, only for the benchmark scripts (`bench.bat` and friends). They use the standard library only. Booting and serving don't need it. [python.org/downloads](https://www.python.org/downloads/); tick "Add python.exe to PATH".

No PowerShell execution-policy change is needed: every script that runs a `.ps1` passes its own per-call bypass.

### Native Linux

Docker, the Docker compose plugin, the NVIDIA container toolkit and the NVIDIA driver. `install.sh` checks exactly these. Its fix-it hints use `pacman` (Arch/CachyOS); on other distros use the equivalent packages.

### Hardware (both paths)

- **Two GPUs.** Every tier uses tensor parallelism across a pair of cards, `0,1` by default. If your cards are numbered differently, the installer's GPU question sets `DEVICE_PAIR` for you. 
- **Disk:** about 20 GB of weights per model, except Flash-Next at about 121 GiB. By default weights go into the model's own `weights/` folder in this repo (on Windows that keeps them out of the WSL distro).
- **RAM:** give the WSL2 VM at least 64 GB for the 27B and the 31B. Add `memory=64GB` under `[wsl2]` in `C:\Users\<you>\.wslconfig`, then run `wsl --shutdown` once. These scripts never edit that file. Flash-Next wants 128 GB+ of host RAM and at least 32 GB of swap (64 GB recommended); its `MODEL.md` has the details.

## Quick start

### Windows

1. `git clone` this repo.
2. Run `<model>\vllm\install.bat` from a normal (non-admin) window.
3. Optional, only if other machines on your network should reach the server: run `firewall.bat` in the same folder. It asks for admin rights itself. The tier boots either way.
4. Boot a tier by double-clicking its `start-<tier>.bat`.
5. When you're done, run `stop.bat`. To remove the model, run `uninstall.bat`.

### Linux

1. `git clone` this repo.
2. Run `<model>/vllm/install.sh`, for example `qwen3.8-27b/vllm/install.sh`.
3. Boot a tier with `<model>/vllm/start-<tier>.sh`. List the tiers with `ls <model>/vllm/start-*.sh` (the 27B has eight, Gemma and Flash-Next two each). Ctrl-C leaves the log; the container keeps running.
4. When you're done, run `stop.sh`. To remove the model, run `uninstall.sh`.

There is no firewall script on Linux. If you need network access, open the tier's port once, for example `sudo firewall-cmd --add-port=8113/tcp` or `sudo ufw allow 8113/tcp`.

The `.env` files use the same format on both platforms, so they work unchanged if you move the repo between Windows and Linux.

### Things to know

- **The first boot takes 18–20 minutes** (patching, weight load, CUDA graph capture). Flash-Next takes about 25 minutes the first time because it writes out its 48.5 GiB PLE table, then about 18. Later boots are much faster.
- **Run one tier at a time.** Every tier needs both cards. Before booting, the start script refuses if a card already holds more than 4 GB for a full minute, and waits up to 15 minutes if a just-stopped tier is still releasing memory.
- **Ports.** Each tier serves an OpenAI-compatible API:

  | model | tier | port |
  |---|---|---|
  | Qwen3.8-27B | mtp, nomtp, swift-mtp, swift-nomtp | 8113 |
  | Qwen3.8-27B | superfast | 8104 |
  | Qwen3.8-27B | kvarntier, kvarnmtp | 8116 |
  | Qwen3.8-27B | kvarndflash2 | 8117 |
  | Qwen3.8-Flash-Next | mtp | 8115 |
  | Qwen3.8-Flash-Next | nomtp | 8116 |
  | Gemma 4 31B | gemma-dual (MTP) | 8032 |
  | Gemma 4 31B | gemma-dual-nomtp | 8033 |

  Some tiers share a port. That's fine, since only one runs at a time.
- **Which address to connect to** depends on `BIND_HOST` in the tier's `.env`:
  - `0.0.0.0` (the default for the 27B and Gemma): every interface.
  - `127.0.0.1`: loopback only. Flash-Next uses this when `BIND_HOST` isn't set, which is the case in its shipped `.env` files.
  - A specific IP: only that address.

  Inside the WSL distro, use `localhost`. From Windows, use the distro's IP (`wsl hostname -I`) on a default NAT setup, or `localhost` if WSL runs in mirrored networking mode.

## Benchmarks

Measured on the test machine (2× 3090 Ti, 128 GB DDR4, Windows 11 + WSL 2.7.14.0) with streaming 512-token generations on narrative and code prompts. Numbers are decode speed in tokens per second.

### Qwen3.8-27B

All rows use a 262K context on the same cards and prompts. The full window fits because only the 16 full-attention layers of this hybrid model store KV, about 4 GiB per card. These numbers were measured on vLLM 0.28.0 / 0.27.1 builds of the tiers; the shipped tiers run v0.29.0.

| start script | setup | port | ctx / seqs | narrative | code | local work |
|---|---|---|---|---|---|---|
| `start-mtp` | v0.29.0 image + the mounted patch bundle, built-in MTP drafter n=4, fp8 KV | 8113 | 262K / 2 | **78.0** (thinking) · 93.2 (baseline payload) | **107.4** (thinking) · 165.3 (baseline payload) | the patch bundle (mamba-copy-bounds, spec-decode bounds and row classification, draft-vocab, GDN async order, FlashInfer decode pin) and the yml changes |
| `start-nomtp` | same image and patches, drafter off (`SPEC_N=0`), fp8 KV | 8113 | 262K / 2 | **76.1** (thinking) · 74.5 (baseline payload) | **149.6** (thinking) · 152.8 (baseline payload), medians of 3 runs | same patches; drafter-off settings |
| `start-kvarndflash2` | v0.29.0 + the KVarN bundle, external DFlash2 drafter n=7, int4 KV | 8117 | 262K / 1 | — | **76.2** | the KVarN bundle (`_shared/patches/vllm-kvarn-0290`, from cpuchip's 0.29 port) and the DFlash2 W4A16 KV-dequant backport |
| `start-kvarntier` / `start-kvarnmtp` | v0.29.0 + the KVarN bundle, drafter off / MTP n=4, int4 KV | 8116 | 262K / 2 · 4 | not benchmarked here; these are the high-concurrency tiers | | the bundle plus this repo's tier setup |

`superfast` and the two Swift tiers have no rows here; see `qwen3.8-27b/MODEL.md`.

### Gemma 4 31B

| start script | tier | port | ctx / seqs | near-empty context | near-full context | local work |
|---|---|---|---|---|---|---|
| `start-gemma-dual` | MTP on (`SPEC_N=2`) | 8032 | 179,040 / 2 | 92.6–116.8 | 13.1–15.0 at ~170K | the source recipe resized to this pair's memory; the first boot fixed the 179,040 window |
| `start-gemma-dual-nomtp` | MTP off | 8033 | 189,000 / 2 | 57.5–57.9 | **28.8–29.0** at ~185K | same resize, using the source's tested no-MTP setup |

Near a full context the plain tier is 2× faster than MTP; near an empty one it's the reverse, so run the one that matches your workload. Time to first token near a full window is about 5.6–6 minutes, which is the 170–185K prefill, not decode.

### Qwen3.8-Flash-Next

Single stream only: the KV pool holds exactly one full-window request (`MAX_NUM_SEQS=1`). Two concurrent streams were tested and collapse under WSL2.

| start script | tier | port | ctx / seqs | short context | at the window edge | local work |
|---|---|---|---|---|---|---|
| `start-mtp` | MTP depth 3 | 8115 | 256,000 / 1 | **35.65** (TTFT 2.5 s) | **35.97** at 251,904 input tokens (TTFT ~520 s) | the image build (Dockerfile on the digest-pinned vendor base) and the sha-checked QSA overlay |
| `start-nomtp` | drafter off (K=0) | 8116 | 256,000 / 1 | **26.36** | **25.80** at 251,904 input tokens | same stack; running with the drafter off is a local change, upstream has no such option |

Decode speed stays flat out to the 256K window edge. The drafter adds 1.35–1.39×. For comparison, the same stack on a native-Linux host reaches 86–89 tok/s at depth. The difference is the cost of running under the WSL2 hypervisor for this model's per-step PLE and expert streaming: about 2.4× on decode and 3.7× on long-context waits. It is measured, and no setting changes it.

## Settings

One Windows environment variable:

| variable | effect |
|---|---|
| `WSL_DISTRO` | Your distro's name. Every script defaults to `Ubuntu`. |

Everything else lives in each tier's `.env` file next to its start script (`mtp.env`, `gemma-dual-nomtp.env`, and so on). Each is plain `KEY=value` in Docker compose `.env` format. Edit a line and the next boot uses it. A blank value falls back to the yml default. The installer writes `DEVICE_PAIR`, `BIND_HOST` and `WEIGHTS_DIR` for you; everything else ships with the tested value.

| key | models | effect |
|---|---|---|
| `WEIGHTS_DIR` | all | Where the checkpoints live. Blank means the model's own `weights/` folder. |
| `TARGET_MODEL` | all | Which checkpoint folder inside `WEIGHTS_DIR` to load. A value containing `/` is used as-is (a Hugging Face repo ID or an absolute container path). The Swift tiers hard-code their checkpoint and ignore this key. |
| `DEVICE_PAIR` | all | The two GPUs the tier uses, by PCI bus order. Default `0,1`. |
| `BIND_HOST` | all | The address the API listens on: `0.0.0.0` (everything), `127.0.0.1` (loopback only) or a specific IP. |
| `PORT` / `MAX_MODEL_LEN` / `GPU_MEMORY_UTILIZATION` | all | API port, context window, and the share of VRAM vLLM may use. Each file ships its tested value. |
| `SPEC_N` / `MAX_NUM_SEQS` | 27B, Gemma | Draft tokens per step (0 = drafter off) and maximum concurrent requests. Flash-Next uses `MTP_DEPTH` instead of `SPEC_N`. |
| `KV_CACHE_DTYPE` / `MAX_NUM_BATCHED_TOKENS` | 27B | KV cache type (`fp8_e4m3`, or `kvarn_k4v2_g128` on the int4 tiers) and prefill chunk size. Gemma's KV key is `KV_DTYPE`. |
| `DRAFTER_MODEL` | 27B superfast + kvarndflash2, Gemma | Which drafter checkpoint to load. |
| `W4A8` / `MAMBA_CACHE_MODE` / `PREFIX_MATCH_UNIT` | 27B | int8 activations, GDN state caching mode, prefix-match granularity. These are measured choices; leave them unless you know why. |
| `TEMP` / `TOP_P` / `TOP_K` / `MIN_P` / `PRESENCE_PENALTY` | 27B, Flash-Next | Sampler defaults. Blank uses the model card's thinking-mode values. Gemma's file uses `REPEAT_PENALTY` in place of `PRESENCE_PENALTY` and ships the card values filled in. |
| `ENABLE_THINKING` / `REASONING_EFFORT` | 27B | Thinking on/off and its effort level. |
| `CHAT_TEMPLATE` | 27B, Gemma | A `.jinja` file name from the model's `vllm/templates/`. Blank = the model's own template. Flash-Next has no template setting; its server wrapper handles parsing. |

Each `MODEL.md` has the full list for that model, with what each setting costs.

## Uninstalling

- `uninstall.bat` / `uninstall.sh` removes one model's runtime folder and its image. The image stays if another model still names it.
- Neither uninstaller deletes weights or your model folders. The Linux `uninstall.sh` says this at the end.
- To remove everything on the machine, run `_shared/uninstall-all.bat` (Windows) or `_shared/uninstall-all.sh` (Linux). Both ask for confirmation. They remove only the images the package ymls name (including Flash-Next's built `qwen38-flash-next-2x3090:locked`).

## Upstream projects

- [noonghunna/club-3090](https://github.com/noonghunna/club-3090): the community dual-3090 recipes the compose files come from. Every local change (WSL2 fixes, GPU pinning, chat template, container names) is listed in each yml's header and checked against the reference copy in `vllm/baseline/`.
- [syv-ai/HyperQwen](https://github.com/syv-ai/HyperQwen) (formerly syv-ai/qwen38-27b-rtx3090): the Qwen3.8-27B recipe line the MTP/nomtp tiers descend from. Source of the W4A16 drafter, the `qwen3_dflash` KV dequant (the DFlash2 tiers), the mamba-align checkpoints patch, and the MTP + fp8-KV + FlashInfer work.
- [cpuchip/vllm](https://github.com/cpuchip/vllm): the vLLM 0.29.0 patch exports behind the KVarN bundle (`kvarn-0.29.0`, `kvarn-v2-runner-0.29.0`) and the `port-0.29` branch of the HyperQwen KVarN port.
- [huawei-csl/KVarN](https://github.com/huawei-csl/KVarN): the int4 KV cache backend (the modules under `_shared/patches/vllm-kvarn-0290/files/`). Apache-2.0, runs natively on sm_86.
- [AntonProkopyev/fa2-fp8kv-sm86](https://github.com/AntonProkopyev/fa2-fp8kv-sm86): FlashAttention-2 fp8-KV kernels for Ampere, used as a digest-pinned prebuilt image. Provenance is in that patch's README.
- [DominikBucko/qwen38-flash-next-2x3090](https://github.com/DominikBucko/qwen38-flash-next-2x3090): the community 2×3090 Flash-Next stack: the digest-pinned base image, the sha-checked vLLM overlay, and the server wrapper that `qwen38-flash-next-2x3090:locked` is built from.
