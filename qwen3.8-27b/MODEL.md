# qwen3.8-27b

**Qwen3.8-27B** — the assistant model. Dense 64 layers with hybrid attention: 16 full-attention + 48 linear-attention (GDN) layers, so KV only grows on the 16 — the full **262K window fits in ~4 GiB per card**. Served as the Frozenlock AutoRound INT4 checkpoint (~18 GiB) on the two "Ti" cards.

## Hardware

| need | why |
|---|---|
| **2× RTX 3090 (24 GB)** | every tier runs TP=2 across the pair; single-card doesn't fit (the ~18 GiB INT4 checkpoint + KV pool exceeds 24 GB) |
| **64 GB+ host RAM** | no expert offload on this model; the host carries weights I/O and serving overhead |
| **~40 GB free disk** | weights ~18 GiB + the external DFlash2 drafter ~1.2 GiB (the kvarndflash2 tier); image ~9 GB in the distro |
| **WSL2 + Docker Desktop + Windows NVIDIA driver** | `install.bat` preflights all of it and names what's missing |

| tier | port | ctx | concurrency | narrative decode | code decode | authored here |
|---|---|---|---|---|---|---|
| **mtp** (`start-mtp.bat`) | 8113 | 262K | 2 seqs | **78.0** (thinking) · 93.2 | **107.4** (thinking) · **165.3** | the patch bundle (mamba-copy-bounds, spec-decode bounds/row-classification, draft-vocab, GDN async order, FlashInfer decode pin) mounted into the stock image at boot, plus the yml delta |
| **nomtp** (`start-nomtp.bat`) | 8113 | 262K | 2 seqs | 76.1 · 74.5 | 149.6 · 152.8 | same bundle; the drafter-off stance lives in its own delta |
| **kvarndflash2** (`start-kvarndflash2.bat`) | 8117 | 262K | 1 seq | — | **76.2** | the KVarN bundle (_shared/patches/vllm-kvarn-0290, ported from cpuchip's 0.29 port) + the DFlash2 W4A16 KV-dequant backport |
| **kvarn / kvarnmtp** (`start-kvarntier.bat` / `start-kvarnmtp.bat`) | 8116 | 262K | 2 / 4 seqs | see tier table | | the KVarN bundle again; the int4 capacity lane is this repo's composition (bundle + tier ymls + stances) |
| **swift-mtp / swift-nomtp** (`start-swift-mtp.bat` / `start-swift-nomtp.bat`) | 8113 | 262K | 4 seqs | — | — | a different checkpoint, not a different lane: the Swift W4A16 finetune (its own 25,879-row draft head + int8 embeddings) on the mtp/nomtp body via the draft-vocab + embed-quant bundles; fp8 KV, same port as mtp (one at a time). Weights: `liamwh/Swift-Qwen3.8-27B-W4A16-syv-fast`, ~15 GB — provision into the weights folder yourself |

Numbers measured on vLLM 0.28.0/0.27.1; full tables in the root README.

**The Swift pair is a tier family, not a lane.** `swift-mtp` / `swift-nomtp` sit beside the five tiers above on the same fp8-KV body: same 0.29.0 image, same patch bundles plus the draft-vocab + embed-quant pair, pointed at the Swift W4A16 checkpoint (its own draft head, int8 embeddings). Same port as mtp (8113) — exactly one of the four runs at a time.

**KV precision splits along GPU capability.** The fp8-KV tiers (`mtp`, `nomtp`, `superfast`) ride FlashInfer's quantized paged path, which needs SM90+; on Ampere (SM86, the 3090 class) FlashAttention and fp8 KV are mutually exclusive and the FlashInfer paged prefill under MTP hits a real upstream fault with no merged SM86 fix. The **KVarN tiers are the Ampere answer**: int4 KV through the port's own patched attention path, no FlashInfer dependency — on Ampere they are also the best-performing tiers (the fp8 lanes pay the FlashInfer prefill tax at long context; the int4-KV lane holds full 262K windows and the concurrency capacity).

## Tiers (vllm/)

| bat | image | drafter | port | container |
|---|---|---|---|---|
| `vllm/start-mtp.bat` | vLLM v0.29.0 | built-in **MTP n=4** (the tier's machine delta: SPEC_N=4 + the window), fp8 KV | 8113 | `qwen-27b-serve` |
| `vllm/start-nomtp.bat` | vLLM v0.29.0 | **off** — the tier's stance in its own delta (SPEC_N=0, 3 seqs), fp8 KV | 8113 | `qwen-27b-nomtp-serve` |
| `vllm/start-superfast.bat` | vLLM v0.29.0 | external **DFlash2** drafter (1.2 GB W4A16), fp8 KV | 8104 | `qwen-27b-superfast-serve` |
| `vllm/start-kvarndflash2.bat` | vLLM v0.29.0 | external **DFlash2** n=7 on **KVarN int4 KV** | 8117 | `qwen-27b-kvarndflash2-serve` |
| `vllm/start-kvarntier.bat` | vLLM v0.29.0 | MTP n=4 or **off**, on **KVarN int4 KV** (the capacity tier) | 8116 | `qwen-27b-kvarn-serve` |
| `vllm/start-kvarnmtp.bat` | vLLM v0.29.0 | built-in **MTP n=4** on **KVarN int4 KV** (the concurrent capacity tier) | 8116 | `qwen-27b-kvarnmtp-serve` |

Exactly one tier runs at a time (the preflight refuses a boot while a card holds >4 GB). Each yml names its own container; the two 8113 tiers share the port (and the cards) and so do the two 8116 KVarN tiers (their ymls, the drafter stance being the difference), the superfast tier has 8104, every other tier its own port and name.

**The KVarN tiers are single-stream at long context.** A second concurrent 260K request dies: one stream at 259,983 tokens is clean, two streams work to ~130K each, four at 65K crash. Two separate binders sit under that. The **OOM** was the port's materialize scratch capped at 262,144 rows, and the Layer-3 fix removes it: an over-cap batch stays on the fast path (measured 2×260k 638.7 s, needles 2/2, 0 faults). The **illegal access** is a nondeterministic wild access in the compiled model region (NOT the port's kernels, and NOT a matrix of the GPU curve — see upstream-tracked), and it is **family-wide**: all six qwen tiers pass the same `--compilation-config`. Keep `MAX_NUM_SEQS` as shipped and put long-ctx concurrency on the fp8 tiers until that fault is closed.

## Weights

`TARGET_MODEL` in the tier's machine .env (`vllm/<tier>.env`, beside its start bat, one per tier) = the model the tier loads: the shipped value is the AutoRound INT4 checkpoint. The knob is three-way: a bare name is a folder under `WEIGHTS_DIR`; a value containing a / is an HF repo ID or an absolute container path, used verbatim — so the line can point at a different model, not just a different folder. `DRAFTER_MODEL` (same grammar) = the DFlash2 drafter, the superfast tier only: the MTP tier's drafter is the checkpoint's own built-in MTP head, which that tier ignores. `WEIGHTS_DIR` = where the folders live; the wizard's first run points it at this model's own `weights/` folder in the tree (the Windows side - the WSL distro stays lean); point it at an existing store to skip the download.

## Knobs (the tier's machine .env — one per tier in vllm/, beside its start bat; it overrides the package template)

| knob | effect |
|---|---|
| `SPEC_N=0` / `SPEC=off` | drafter off — the mitigation for the open GDN wild-write (#50021), and the way to trade the drafter for concurrency (~+27% batch aggregate). Non-numeric is a hard boot error, never a silent "off" |
| `W4A8=0` | the W4A16 path (drops int8 activations; costs the measured +41.8% prefill / −28.6% TTFT@10K) |
| `MAX_NUM_SEQS=…` | lower it when long-ctx concurrency OOMs |
| `MAMBA_CACHE_MODE=none` / `LONG_PREFILL_TOKEN_THRESHOLD=0` | off prefix caching (costs the 15–38% between-turn TTFT cut) / off head-of-line prefill interleaving |
| sampler block (`TEMP`/`TOP_P`/`TOP_K`/`MIN_P`/`PRESENCE_PENALTY`) | the model card's thinking row, live in the file (the instruct row is reached by editing the three lines: `TEMP=0.7`, `TOP_P=0.80`, `PRESENCE_PENALTY=1.5`) |
| `CHAT_TEMPLATE=…jinja` | repoint the template (the file ships blank = the vendored native 3.8 template) |

The full table (with the measured cost of each, the W4A8 gate, and the watch items: the #1096 ctx cliff, the #50021 re-verify, the restart trap) lives in the source repo (the club3090 recipe tree).

## Numbers (this rig, 262K ctx, same cards + prompts)

> Measured on vLLM 0.28.0 / 0.27.1.

| bat | decode: narrative | decode: code |
|---|---|---|
| `start-mtp.bat` (thinking preset) | **78.0** (93.2 baseline payload) | **107.4** (165.3 baseline payload) |
| `start-nomtp.bat` (thinking preset) | **76.1** (74.5 baseline payload) | **149.6** (152.8 baseline payload) — 3-run medians |

The two 8113 tiers trade a few percent on the single-stream rows (the old sweep's −18%/−46% drafter cost never reproduced on 0.28.0 — see the medians above); the drafter-off stance is the concurrent and long-ctx safe side (the section below). A llama.cpp native-Windows build of the same model sits at 54.8 / 70.9 (n=8) — the dependency-free fallback; its card is in this folder (`llamacpp/RECIPE.md`: the specs and the args).

## Concurrency (why the drafter is off in the default stance)

The drafter buys the single-stream peak; what it pays is the pool that concurrency is measured against:

- ~13% of the KV pool goes to the drafter (n=4: ~563K → n=0: ~647K tokens; ~2.15x → ~2.47x of the 262K ceiling).
- The old 8-seq MTP stance holds at short/moderate ctx only: at 16K prompts, n=4 under W4A8 hit 23,872 MiB/card (over budget) already at N=2 — a long-ctx MTP workload wants 2–4 seqs there.
- #1096's accumulated-ctx decode cliff (~17–21K on MTP, severe on Ampere) and the still-open #50021 (GDN spec-decode wild write) both cut against sustained agent traffic; the 28.0 pin carries the two mitigating patches, but the async-spec race fix was last formally soaked on the 0.27.1 runner.

The nomtp tier's stance (`SPEC_N=0`, `MAX_NUM_SEQS=3`) is sized on the n=0 pool: three 200K streams (600K tokens) fit the measured 656,866-token pool (2.51x); a stream that cannot fit waits — it does not force a recompute cascade. Past the spec crossover the aggregate flips to the drafter-off side at C≈8 (211 vs 201), and its measured ceiling is ~306–308 aggregate tok/s at C=32, versus ~241 with the drafter on: above the crossover the drafter is pure overhead on a compute-bound batch. The measured price is small: the 3-run medians sit ~3% below the n=4 thinking row on narrative and within run-to-run spread on code (the old 27.1 sweep's −18%/−46% never carried over). What the drafter actually costs is the pool (13% of KV) and the deep-ctx tax: in the deep-ctx boots, at 184.9K ctx the drafter-on tier ran 14.6 tok/s to 28.9 drafter-off — a 2x tax, not a win. So: `start-mtp.bat` is the peak single-stream tier; `start-nomtp.bat` is the concurrent tier, within a few percent of it single-stream. The full curve and table: the source repo's tier comparison.

