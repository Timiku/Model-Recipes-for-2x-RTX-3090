# qwen3.8-flash-next

**Qwen3.8-Flash-Next**, the first open model on the Qwen4 architecture: a 125B MoE with 6B active parameters per token, plus a 51B n-gram embedding table (PLE) and a 4B MTP head. Native context is 262K (1M with static YaRN), with GDN+QSA hybrid attention at about 24–25 KB of KV per token. It is the heaviest model in this repo.

On two consumer cards it decodes at **35.65 tok/s** single-stream, and that speed holds all the way to the 256K window edge. It runs on the community 2×3090 vLLM stack described below. A llama.cpp build is the lighter alternative; it isn't packaged in this repo.

## Quick start

1. Read **Hardware** below. The RAM requirement is real.
2. Run `vllm\install.bat` (Windows) or `vllm/install.sh` (Linux). It checks the machine, builds the image, and downloads the weights (~121 GiB; see Weights).
   On Linux, `install.sh` does not build the image yet and will stop with "pull failed". Build it first from the repo root: `docker build -t qwen38-flash-next-2x3090:locked qwen3.8-flash-next/vllm`
3. Run `vllm\start-mtp.bat` or `vllm/start-mtp.sh`. The first boot takes about 25 minutes (the PLE table is written out once), later boots about 18.
4. Point any OpenAI-compatible client at `http://127.0.0.1:8115/v1` with model name `qwen3.8-flash-next` (the value `SERVED_MODEL_NAME` ships with).

`stop.bat` / `stop.sh` stops it cleanly. On Windows, closing the start window also stops it: a watchdog tears the stack down.

## Hardware

| need | why |
|---|---|
| **2× RTX 3090 (24 GB)** | The settings (tensor + expert parallel, the vendor's tested KV pool size) are calibrated for this card class. The vendor targets the 3090 in general, not the Ti. |
| **128 GB+ host RAM** | The PLE table wants about 48.5 GiB of host page cache, and expert offload takes about 30 GiB per card. Also **swap ≥ 32 GB** (64 GB recommended). |
| **~250 GB free disk, in two places** | Weights ~121 GiB (on Windows, in the repo tree). The distro needs ~9 GB for the image and 48.5 GiB for the PLE table at first boot. |
| **WSL2 + the Windows NVIDIA driver** (Windows) | `install.bat` checks for them and installs Docker Engine and the NVIDIA runtime inside the distro if they are missing. |

## Tiers

| start script | files | port | container | setup |
|---|---|---|---|---|
| `start-mtp` | `package/mtp.yml` + `mtp.env` | 8115 | `qwen38-flashnext-serve` | MTP depth 3 on the variable-K scheduler. |
| `start-nomtp` | `package/nomtp.yml` + `nomtp.env` | 8116 | `qwen38-flashnext-nomtp-serve` | The same setup with `MTP_DEPTH=0`: drafter off. |

Shared by both tiers: tensor-parallel 2 across `DEVICE_PAIR`, one stream, a 256,000-token window, a 4.13 GiB bf16 KV pool, 30 GiB of expert offload per card, and 84 hot-cache slots under the dynamic LRU. Both use the locked image built by `vllm/Dockerfile` from the digest-pinned vendor base.

| tier | short context | at the window edge | TTFT |
|---|---|---|---|
| mtp | **35.65 tok/s** | **35.97** at 251,904 input tokens | 2.5 s short, ~520 s at the edge |
| nomtp | **26.36 tok/s** | **25.80** at 251,904 input tokens | |

Decode speed is flat to the window edge. The drafter adds 1.35–1.39×. Running with the drafter off is a local change; upstream has no such option.

**Vision is loaded in both tiers.** The community wrapper's `ENABLE_VISION` switch is on in both `.env` files, so the vision tower (333 `model.visual.*` tensors, ~600 MiB) is resident on every boot. Text requests never touch it; image requests just work. It is tested on 2×24 GB (the C4 boot plus an image round-trip). The tower can only be loaded when the model is built (`StageMissingLayer` in the fork's `model.py`), not added to a text-only boot later, so always-on is the only option. The 256K window is also the community's tower-tested setting. Each image uses 200–1,600 KV tokens.

**The image is built, not pulled.** This is the only model here whose image is modified: `install.bat` builds it at stage 0c (the Linux `install.sh` does not yet; see Quick start) and skips the build on reinstall. Its ymls carry the `provenance-class: modified-image` marker, and the provenance gate checks the locked-image pin and the vendor base digest instead of a stock image tag. There's no chat-template setting and no templates mount; the wrapper handles parsing.

Booting stays a manual step (a test plan decides acceptance). Only one tier runs at a time, and not alongside any other model. A first boot from weights on a hard disk runs well past the default 600 s boot timeout, so both `.env` files set `UP_PROBE_TIMEOUT=3600`.

The container names carry no user-specific parts (`qwen38-flashnext-*`). The shipped `.env` files carry no author-machine settings: `DEVICE_PAIR` ships the default `0,1` and the sampler row is the card's.

## Weights

`TARGET_MODEL` in the tier's `.env` names the folder the yml mounts at `/model`. A bare name is a folder under `WEIGHTS_DIR`; an absolute path is used as-is. The folder uses the Hugging Face repo layout. The 25-shard checkpoint includes the 48.5 GiB FP8 PLE table in its shards (`model-plefp8-*`) and the MTP drafter in `runtime/mtp-int4-g32/`, so the drafter always follows `TARGET_MODEL` and the yml never points at a separate one.

`WEIGHTS_DIR` is where the checkpoint lives. Blank means the model's own `weights/` folder in the repo. The installer downloads anything missing: 121 GiB, several hours. Set up swap first.

**The checkpoint pick.** The installer wizard asks which target checkpoint the tiers load (`TARGET_MODEL`, step 2b in `install.sh`/`install.bat`): the shipped default (`qwen3.8-flash-next`, the albucino W4A16-FP8PLE community checkpoint), a Hugging Face repo id (fetched on demand by `vllm/package/weights-source.sh`), or an already-provisioned folder path. The pick applies to all three tiers — `mtp`, `nomtp`, and `stock-mtp`, the Stage-2 Step-1 mainline arm on the stock vLLM image (port 8119).

## Settings

In the tier's `.env`.

| key | effect |
|---|---|
| `DEVICE_PAIR` | The two cards the tier uses. Ships as `0,1`. The installer's GPU question rewrites it. |
| `BIND_HOST` | The listen address. Not set in the shipped files, so the yml default applies: the vendor's `127.0.0.1`, loopback only. For LAN access set `0.0.0.0` (the installer's bind question does this) and run `firewall.bat` on Windows. |
| `PORT` | 8115 (mtp) / 8116 (nomtp). |
| `SERVED_MODEL_NAME` | The model name the API answers to. The shipped files set `qwen3.8-flash-next`, matching the folder name, which fixes 404s from clients that send the folder name. The yml default is the community's `Qwen3.8-Flash-Next`; set that if you use the community's own client. |
| `ENABLE_VISION` | Vision tower on (default). Limits: `VISION_MAX_IMAGES`, `VISION_MAX_PIXELS`. |
| `MAX_MODEL_LEN` / `KV_CACHE_MEMORY_BYTES` | Window size and KV budget. The budget must be **larger** than the window: a full-window request needs room for block rounding and the draft horizon, so a pool exactly equal to the window leaves long and boundary requests stuck waiting (measured). The shipped setting is a 256,000-token window with the vendor's 4,429,185,024 bytes (4.13 GiB), which is 275,801 tokens (1.08×) on mtp and 329,920 (1.29×) on nomtp. The difference is probably the drafter's per-sequence state (inferred, not measured). No equal-pool (1.00×) value ships. |
| `CPU_OFFLOAD_GB` / `VLLM_WNA16_STATIC_HOT_CACHE_SIZE` | Expert offload per card (30 GiB, tested against the WDDM pinned-memory cap) and GPU hot-cache slots (84; 88 can run the QSA prefill scratch out of memory at the window edge). If you hit OOM, reduce these, never the precision. |
| `MTP_DEPTH` / `VLLM_PREFIX_CACHE_RETENTION_INTERVAL` | Drafter depth (3 on mtp, measured acceptance length 2.07–2.39 of 3; 0 on nomtp) and its retention interval (1600 on both). The interval must be a multiple of the scheduler's block size or the KV manager refuses to boot. |
| `VLLM_WSL2_ENABLE_PIN_MEMORY=1` | Required for the WSL2 pinned-memory path; the V2 runner fails at startup without it. |
| `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:False` | A driver workaround for this WSL2 generation. Don't set it to `:True`: 11 of 11 boots on 09-03 died with it. |
| `VLLM_PLE_DISK_OFFLOAD_DIR=/ple-table` | Keeps the PLE table in a file under the `/ple-table` mount instead of RAM. **On in both tiers.** Measured at zero cost across twelve client runs; it frees 48.5 GiB of the WSL memory floor, and later boots skip re-reading the table's shards. The memory it uses is reclaimable page cache. Keep the file off a 9p mount. Blank the key to go back to keeping it in RAM (the old pinned-memory OOM there was fixed upstream in #10). |
| `SAMPLER` + `TEMP` / `TOP_P` / `TOP_K` / `MIN_P` / `PRESENCE_PENALTY` | Server-default sampler (wrapper change #3). `SAMPLER=card` adds no override, so the checkpoint's `generation_config.json` applies (temp 1.0 / top_p 0.95 / top_k 20); every benchmark here ran on it. `think` and `instruct` select the model family's card rows. The five value keys are blank by default and each overrides one value of the chosen row. Per-request parameters always win. Known gap: this build drops `presence_penalty` from server defaults ([vllm#50767](https://github.com/vllm-project/vllm/issues/50767)); the wrapper warns at boot if a row sets one. |

The KV cache is bf16: the model uses upstream's hard-coded `auto`. The yml has a dtype setting, but every shipped `.env` leaves it blank.

## Measured speed

| setup | result |
|---|---|
| This machine, WSL2, mtp tier, the vendor's client runs | short **35.65** / long **35.97** / boundary **34.4** tok/s decode (reciprocal mean); TTFT 2.5 s short, ~520 s at the window edge |
| This machine, WSL2, nomtp tier, same runs | short **26.36** / long **25.80** / boundary **25.62** tok/s; the drafter adds 1.35–1.39× |
| vLLM's own logs | 35 tok/s sustained single-stream decode (44.5 peak), TTFT ~3 s, acceptance 2.07–2.39 of 3 |
| The community's 2×3090 setup, native Linux, 128 GB (4.13 GiB KV, 84–88 hot slots, no experts on the GPUs) | 86.2–89.1 tok/s at depth: the reference without WSL2 |
| The closest 3090-class comparison found (3090 Ti + 3950X + 128 GB DDR4, full 262K) | ~16 tok/s |

The same recipe reads 86–89 tok/s on the community's native-Linux host. Their MTP gain sits on a target-only base of about 61.3 tok/s; this machine's target-only speed is about 17. The gap is the WSL2 hypervisor's cost on the per-step expert streaming, not a configuration difference; vLLM's own logs back the measurement. Compared to the 27B, this is the better model at a 4–10× speed cost (the model page has the table).

The architecture notes, research, the microstutter investigation and the test plan are in the author's source repo.

## Credits

- [DominikBucko/qwen38-flash-next-2x3090](https://github.com/DominikBucko/qwen38-flash-next-2x3090): the 2×3090 serving stack. The digest-pinned base image, the sha-checked vLLM overlay, the server wrapper that `qwen38-flash-next-2x3090:locked` is built from, and the token-exact benchmark client.
- [albucino/Qwen3.8-Flash-Next-W4A16-FP8PLE](https://huggingface.co/albucino/Qwen3.8-Flash-Next-W4A16-FP8PLE): the revision-pinned checkpoint, with weights, PLE table and MTP head in one folder.
- [vllm-project/vllm](https://github.com/vllm-project/vllm): the engine.
