# qwen3.8-flash-next

**Qwen3.8-Flash-Next** — the first open model on the Qwen4 architecture: a 125B MoE (6B active per token) plus a 51B n-gram embedding table and a 4B MTP head, 262K native context (1M with static YaRN), GDN+QSA hybrid attention (~24-25KB KV per token). The heaviest model on this box. Headline: **35.65 tok/s** single-stream decode, flat all the way to the 256K window edge, from two consumer cards. The heavy path is the community's 2×3090 vLLM stack (the recipe below); the llama.cpp line is the light coexistence path (the dependency-free fallback, not in a recipe folder).

## Quick start

```
1.  Read Hardware below. The RAM one is not a suggestion.
2.  vllm\install.bat        preflights the box, builds the image, fetches the weights (~121 GiB — see Weights).
3.  vllm\start-mtp.bat      ~25 min first boot (the PLE table writes through once), ~18 min after.
4.  Point any OpenAI-compatible client at  http://127.0.0.1:8115/v1 with model name  Qwen3.8-Flash-Next .
```

`stop.bat` stops it cleanly. Closing the start window is also a stop signal — a watchdog tears the stack down.

## Hardware

| need | why |
|---|---|
| **2× RTX 3090 (24 GB)** | the shape (TP=2 + expert parallel, the vendor-validated KV-pool constant) is calibrated to this card class — the vendor's line is `2x3090`, not the Ti specifically |
| **128 GB+ host RAM** | the PLE table wants ~48.5 GiB of host page cache and expert offload takes ~30 GiB per card; **swap ≥ 32 GB** (64 recommended) |
| **~250 GB free disk, split** | weights ~121 GiB (Windows side); the distro takes ~9 GB for the image + 48.5 GiB for the PLE table at first boot |
| **WSL2 + Docker Desktop + Windows NVIDIA driver** | `install.bat` preflights all of it and names what's missing |

| tier | port | ctx | concurrency | short decode | at the window edge | authored here |
|---|---|---|---|---|---|---|
| **mtp** (`start-mtp.bat`) | 8115 | 256,000 | 1 stream | **35.65 tok/s** (TTFT 2.5 s) | **35.97** at 251,904-in | the built image (Dockerfile on the digest-pinned vendor base), the sha-guarded QSA overlay (score-chunk cap, graph-capture hooks), the serve wrapper (K=0 arm, samplers), deltas, the arm-probe, the wizard + watchdog |
| **nomtp** (`start-nomtp.bat`) | 8116 | 256,000 | 1 stream | **26.36 tok/s** | **25.80** at 251,904-in | same stack; the K=0 shape (spec flag omitted) is a local delta — upstream has no drafter-off |

Decode is flat to the 256K window edge (long ≈ short). The drafter buys 1.35–1.39x. Single stream by design (`MAX_NUM_SEQS=1`).

## Tiers (vllm/, the two-tier shape)

| bat | package yml + machine delta | port | container | shape |
|---|---|---|---|---|
| `vllm/start-mtp.bat` | `package/mtp.yml` + `mtp.env` (the locked image built by `vllm/Dockerfile` from the digest-pinned vendor base) | 8115 | `qwen38-flashnext-serve` | TP=2 on cards 0,2, single stream, MTP depth 3 (variable-K scheduler); 35 tok/s sustained decode, TTFT ~3 s at the 262K shape: 256,000 window, 4.13 GiB bf16 KV pool (the vendor constant 4,429,185,024 = 275,801 tokens, 1.08x — pool==window parks the full-window shapes), 30 GiB/rank expert offload, 84 hot slots under the dynamic LRU (88 can OOM the QSA prefill scratch at the window edge). The vision tower is loaded (see below). |
| `vllm/start-nomtp.bat` | `package/nomtp.yml` + `nomtp.env` | 8116 | `qwen38-flashnext-nomtp-serve` | the same shape with `MTP_DEPTH=0` + the coupled 1600 retention — the K=0 arm (decode 26.4 vs mtp's 35.7). The vision tower is loaded here too. |

**Vision lives in both tiers, not a third.** The community wrapper's `ENABLE_VISION` gate is on in both machine deltas, so the tower (333 `model.visual.*` tensors, ~600 MiB) is resident on every boot — text requests never call it, image requests just work. The tower on 2×24 GB is validated (C4 boot + the image round-trip). There is no mechanism to load the tower into a language-model-only boot later — it is construction-time (`StageMissingLayer` in the fork's `model.py`) — so always-on is the only integrated option. The C4 shape's 256K window is also the community's tower-validated line. One consequence: each image costs 200–1,600 KV tokens of its own.

This is the repo's one **modified-image** model: the image is built, not pulled (`install.bat` stage 0c runs the build; a re-install skips it), so its ymls carry the `provenance-class: modified-image` marker and the provenance guard checks the locked-image pin + the vendor base digest instead of the stock-image literal. There is no chat-template knob or templates mount — the wrapper owns the parsers.

The boot stays user-gated (a test plan gates the acceptance), and one tier runs at a time — mutually exclusive with every other tier on the box (they all want both cards). A first boot from HDD-resident weights runs well past the default 600 s boot window; the machine delta carries `UP_PROBE_TIMEOUT=3600`.

This folder is the release cut: the same ymls and scripts with box state neutralized. Container literals are persona-free (`qwen38-flashnext-*`).

## Weights

`TARGET_MODEL` in the tier's machine delta = the folder the yml mounts at `/model`: a bare name is a folder under `WEIGHTS_DIR`; an absolute path is used verbatim. The folder's top level is the Hugging Face repo layout, and the 25-shard checkpoint carries the 48.5 GiB FP8 PLE table in-shard (`model-plefp8-*`) and the MTP drafter folder `runtime/mtp-int4-g32/` — the drafter lives inside the folder, so it follows the knob, and the yml never points at an external one. `WEIGHTS_DIR` = where the checkpoint lives — on this box, the model's own weights/ folder in the repo tree (blank delta = that folder); the wizard fetches anything missing (a 121 GiB multi-hour fetch — the swapfile first).

## Knobs (the tier's machine delta — one per tier in vllm/, beside its start bat)

| knob | effect |
|---|---|
| `DEVICE_PAIR` | which two cards the tier runs on (`0,1` shipped; the flash-next box runs `0,2` — the wizard writes the box's pair) |
| `PORT` | the tier's port (8115 / 8116 shipped) |
| `ENABLE_VISION` | tower on (default); limits via `VISION_MAX_IMAGES` / `VISION_MAX_PIXELS` |
| `SERVED_MODEL_NAME=` | the name the API answers to — the 404 fix: a client that reads the folder name sends it, while the yml's default registers the community's HF-style casing (set that one if you run the community's own client) |
| `MAX_MODEL_LEN` / `KV_CACHE_MEMORY_BYTES` | the window shape — the KV budget must sit **above** the window: a full-window request needs block-rounding + draft-horizon slack to be admitted, so pool==window parks the long/boundary shapes Waiting-by-capacity (a measured admission requirement). The standing rung is a 256,000-token window at the vendor's 4,429,185,024 B (4.13 GiB = 275,801 tokens, 1.08x on mtp; the same bytes report 329,920 / 1.29x on nomtp — the drafter's per-sequence state claims the difference ^[inferred]). No equal-pool (1.00x) value is shipped — pool==window does not admit the full-window shapes |
| `CPU_OFFLOAD_GB` / `VLLM_WNA16_STATIC_HOT_CACHE_SIZE` | the expert tier (the proven 30 GiB/rank) against the WDDM pin cap, and the VRAM hot-cache slots (84 shipped; 88 can OOM the QSA prefill scratch at the window edge) — the OOM ladder trims these, never the precision |
| `MTP_DEPTH=3` / `VLLM_PREFIX_CACHE_RETENTION_INTERVAL=1600` | the drafter depth on the variable-K scheduler (measured acceptance length 2.07-2.39 of 3) and its coupled retention interval (a multiple of the scheduler's block size — the KV manager refuses a boot otherwise). The nomtp delta carries depth 0 / 1600. The KV cache is bf16 (`auto`); no other dtype is shipped. |
| `VLLM_WSL2_ENABLE_PIN_MEMORY=1` / `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:False` | the WSL2 pin path (the V2 runner hard-fails at init without it) / the driver-class fix for this box's WSL2 generation — do not re-enable `:True` (11/11 boots of 09-03 died on it) |
| `VLLM_PLE_DISK_OFFLOAD_DIR=/ple-table` | the PLE table's tier — **ON on both tiers** (measured zero cost across twelve client arms, 48.5 GiB of the WSL floor returned, reuse boots skip the table's shard reads): a file under the `/ple-table` mount instead of RAM (residency is reclaimable page-cache; keep the file off a 9p mount) — blank it to roll back to the RAM tier (the old pin-OOM was fixed upstream by #10) |
| `SAMPLER` + `TEMP`/`TOP_P`/`TOP_K`/`MIN_P`/`PRESENCE_PENALTY` | the server-default sampler (wrapper delta #3): `card` = no override flag, the checkpoint's `generation_config.json` rides (temp 1.0 / top_p 0.95 / top_k 20 — the box row; every ledger benchmark ran on it), `think` / `instruct` are the family card rows; the five keys blank-by-default and each overrides the picked row value-by-value (`TOP_P: "0.98"` widens the nucleus on the box, 09-18); per-request params always win. Known gap: this build drops `presence_penalty` from server defaults ([vllm#50767](https://github.com/vllm-project/vllm/issues/50767) — the wrapper warns at boot when a row carries one) |
| `BIND_HOST` | the host half of the published port (the package default is the vendor's loopback `127.0.0.1` — the installer wizard writes the box's choice, LAN reach is `0.0.0.0` plus `firewall.bat`) |

## Numbers (this rig)

| shape | line |
|---|---|
| this box, WSL2, mtp tier — the vendor's client arms | short **35.65** / long **35.97** / boundary **34.4** tok/s decode (recip-mean); TTFT 2.5 s short, ~520 s at the window edge |
| this box, WSL2, nomtp tier — same arms | short **26.36** / long **25.80** / boundary **25.62** tok/s — the drafter buys 1.35–1.39x |
| engine loggers | 35 tok/s sustained single-stream decode (44.5 peak), TTFT ~3 s, acceptance 2.07-2.39/3 |
| the community's published 2×3090 shape (their 128 GB native: 4.13 GiB KV, 84-88 hot slots, no experts on-card) | 86.2-89.1 at depth — the WSL2-free reference |
| the closest 3090-class sibling (3090Ti + 3950X + 128 GB DDR4, full 262K) | ~16 t/s |

The 35 is WSL2-honest: the same recipe on the community's native-Linux host reads 86-89 at depth (their MTP multiplier rides a ~61.3 target-only base; this box's target-only is ~17 — the hypervisor tax on the per-step expert streaming, not a configuration gap; the engine loggers carried the measurement). Against the 27B assistant it is the better model at a 4-10× speed tax (the model page carries the table).

**KV lane: bf16.** The cache dtype rides upstream's hardcoded `auto` (bf16 for this model); no other dtype is shipped — the knob exists in the yml but every shipped value leaves it blank.

The deep content — the architecture, the research corpus, the microstutter investigation, the test plan — lives in the source repo.

## Credits

- [DominikBucko/qwen38-flash-next-2x3090](https://github.com/DominikBucko/qwen38-flash-next-2x3090)
  — the 2x3090 serving line: the digest-pinned base image, the sha-guarded vLLM overlay, the serve wrapper that `qwen38-flash-next-2x3090:locked` is built from, and the token-exact bench client.
- [albucino/Qwen3.8-Flash-Next-W4A16-FP8PLE](https://huggingface.co/albucino/Qwen3.8-Flash-Next-W4A16-FP8PLE)
  — the revision-pinned checkpoint: weights + PLE table + MTP head in one folder.
- [vllm-project/vllm](https://github.com/vllm-project/vllm) — the engine.
