# qwen3.8-27b

**Qwen3.8-27B**, the general assistant model. It is dense, with 64 layers of hybrid attention: 16 full-attention layers and 48 linear-attention (GDN) layers. Only the 16 full-attention layers store KV, so the **full 262K window fits in about 4 GiB per card**. It is served as the Frozenlock AutoRound INT4 checkpoint (~18 GiB).

## Hardware

| need | why |
|---|---|
| **2× RTX 3090 (24 GB)** | Every tier runs tensor-parallel across both cards. One card is not enough: the ~18 GiB INT4 checkpoint plus a KV pool won't fit in 24 GB. |
| **64 GB+ host RAM** | No expert offload on this model; host RAM covers weight loading and serving overhead. |
| **~40 GB free disk** | Weights ~18 GiB, plus ~1.2 GiB for the external DFlash2 drafter (superfast and kvarndflash2 tiers), plus ~9 GB for the image. |
| **WSL2 + the Windows NVIDIA driver** (Windows) | `install.bat` checks for them, and installs Docker Engine and the NVIDIA container runtime inside the distro if they are missing. |

## Tiers

All tiers run the stock vLLM v0.29.0 image with patch bundles mounted at boot. Only one tier runs at a time.

| start script | KV cache | drafter | port | seqs | container |
|---|---|---|---|---|---|
| `start-mtp` | fp8 | built-in MTP, n=4 | 8113 | 2 | `qwen-27b-serve` |
| `start-nomtp` | fp8 | off (`SPEC_N=0`) | 8113 | 2 | `qwen-27b-nomtp-serve` |
| `start-superfast` | fp8 | external DFlash2 (1.2 GB W4A16), n=7 | 8104 | 1 | `qwen-27b-superfast-serve` |
| `start-kvarntier` | KVarN int4 | off | 8116 | 2 | `qwen-27b-kvarn-serve` |
| `start-kvarnmtp` | KVarN int4 | built-in MTP, n=4 | 8116 | 4 | `qwen-27b-kvarnmtp-serve` |
| `start-kvarndflash2` | KVarN int4 | external DFlash2, n=7 | 8117 | 1 | `qwen-27b-kvarndflash2-serve` |

The start script refuses to boot while a card holds more than 4 GB. Four tiers share port 8113 and two share 8116; that's fine because only one tier runs at a time.

**Patches.** The fp8 tiers mount the patch bundle: mamba-copy-bounds, spec-decode bounds and row classification, draft-vocab, GDN async order, and the FlashInfer decode pin. The KVarN tiers use the KVarN bundle (`_shared/patches/vllm-kvarn-0290`, from cpuchip's 0.29 port); kvarndflash2 adds the DFlash2 W4A16 KV-dequant backport. The int4 tier setup (which bundle, which ymls, which settings) is this repo's own.

**KV precision and GPU generation.** The fp8-KV tiers (`mtp`, `nomtp`, `superfast`) use FlashInfer's quantized paged path, which needs SM90+. On Ampere (SM86, the 3090 class), FlashAttention and fp8 KV can't be combined, and FlashInfer's paged prefill under MTP hits an upstream fault with no merged SM86 fix. The KVarN tiers avoid this: int4 KV through the port's own patched attention path, with no FlashInfer dependency. On Ampere they are also the fastest tiers. The fp8 tiers pay the FlashInfer prefill cost at long context, while the int4 tiers hold full 262K windows and more concurrent streams.

**The Swift pair (retired 09-29).** The `swift-mtp` / `swift-nomtp` tiers — the Swift W4A16 finetune (`liamwh/Swift-Qwen3.8-27B-W4A16-syv-fast`, ~15 GB, own 25,879-row draft head and int8 embeddings) — are out of the package. Their decode record stays valid and is worth keeping in mind: swift-mtp was the only tier measured with no depth cliff (TPOT flat 22–27 ms from 4k to 210k). The tier files live in git history; restoring them is a checkout away. The wizard's checkpoint pick (step 2b) covers pulling a different target checkpoint instead.

**The checkpoint pick.** The installer wizard asks which target checkpoint the tiers load (`TARGET_MODEL`, step 2b in `install.sh`/`install.bat`): the shipped default (Frozenlock AutoRound INT4), a Hugging Face repo id (fetched on demand by `vllm/package/weights-source.sh`), or an already-provisioned folder path. The pick applies to all six tiers - the fp8 and KVarN shapes share the checkpoint.

### KVarN tiers at long context

Treat the KVarN tiers as single-stream at long context. One stream at 259,983 tokens is clean; two streams work up to about 130K each; four at 65K crash. Two separate problems cause this:

- **Out of memory.** The port's materialize scratch buffer was capped at 262,144 rows. The Layer-3 fix removes that: an over-cap batch stays on the fast path (measured: 2× 260K in 638.7 s, needles 2/2, 0 faults).
- **Illegal memory access.** A nondeterministic wild access in the compiled model region. It is not in the port's kernels and is tracked upstream. It affects the whole family: all eight qwen tiers pass the same `--compilation-config`.

Keep `MAX_NUM_SEQS` as shipped, and use the fp8 tiers for concurrent long-context work until that fault is fixed.

## Weights

Set in the tier's `.env` (`vllm/<tier>.env`, next to its start script):

- `TARGET_MODEL`: the checkpoint to load. Ships as the AutoRound INT4 folder. A bare name is a folder under `WEIGHTS_DIR`; a value containing `/` is a Hugging Face repo ID or an absolute container path, used as-is. It can point at a different model, not just a different folder.
- `DRAFTER_MODEL`: same rules. The DFlash2 drafter for `superfast` and `kvarndflash2`. The MTP tiers use the checkpoint's built-in head and have no drafter setting.
- `WEIGHTS_DIR`: where the folders live. The installer points it at this model's own `weights/` folder (on Windows that keeps it out of the WSL distro). Point it at an existing store to skip the download.

## Settings

In the tier's `.env`. Each value overrides the package yml.

| key | effect |
|---|---|
| `SPEC_N=0` or `SPEC=off` | Turns the drafter off. Use it to work around the open GDN wild-write bug (#50021), or to trade the drafter for concurrency (about +27% batch throughput). A non-numeric `SPEC_N` stops the boot with an error rather than silently turning the drafter off. |
| `W4A8=0` | Uses the W4A16 path (no int8 activations). Costs the measured +41.8% prefill / −28.6% TTFT at 10K that int8 activations buy. |
| `MAX_NUM_SEQS` | Lower it if long-context concurrency runs out of memory. |
| `MAMBA_CACHE_MODE=none` | Turns off prefix caching, losing its 15–38% cut in time-to-first-token between turns. |
| `LONG_PREFILL_TOKEN_THRESHOLD=0` | Turns off interleaving of long prefills with other requests. |
| `TEMP` / `TOP_P` / `TOP_K` / `MIN_P` / `PRESENCE_PENALTY` | Sampler defaults. Blank uses the model card's thinking-mode row. For the instruct row, set `TEMP=0.7`, `TOP_P=0.80`, `PRESENCE_PENALTY=1.5`. |
| `CHAT_TEMPLATE` | A `.jinja` file from `vllm/templates/`. Blank uses the vendored native 3.8 template. |

The full table, with measured costs, the W4A8 gate and open issues (the #1096 context cliff, re-verifying #50021, the restart trap), is in the author's source repo (the club3090 recipe tree).

## Measured speed

This machine, 262K context, same cards and prompts. Measured on vLLM 0.28.0 / 0.27.1. Tokens per second.

| start script | narrative | code |
|---|---|---|
| `start-mtp` (thinking preset) | **78.0** (93.2 on the baseline payload) | **107.4** (165.3 on the baseline payload) |
| `start-nomtp` (thinking preset) | **76.1** (74.5 on the baseline payload) | **149.6** (152.8 on the baseline payload), medians of 3 runs |
| `start-kvarndflash2` | — | **76.2** |

`kvarnmtp` was measured separately on 09-14: 47.6 / 59.7 / 60.8 tok/s at 2 / 4 / 8 concurrent streams, a 1,113,340-token pool with the drafter, acceptance on par with fp8, and +0.5% perplexity.

For the two 8113 tiers, single-stream speed differs by only a few percent. An older sweep showed the drafter costing 18% (narrative) and 46% (code); that never reproduced on 0.28.0. For comparison, a native-Windows llama.cpp build of the same model reaches 54.8 / 70.9 (n=8); its card is `llamacpp/RECIPE.md`.

## Drafter vs. concurrency

The drafter raises single-stream peak speed. What it costs is KV pool space, which is what concurrent requests draw from:

- The drafter takes about 13% of the KV pool: about 563K tokens at n=4 versus about 647K at n=0 (2.15× versus 2.47× the 262K window).
- An older 8-sequence MTP setup only held at short and moderate context. At 16K prompts, n=4 with W4A8 already used 23,872 MiB per card (over budget) at 2 sequences, so a long-context MTP workload wants 2–4 sequences.
- Two open issues both hurt sustained agent traffic: #1096 (decode slows sharply once accumulated context passes about 17–21K on MTP, worse on Ampere) and #50021 (GDN spec-decode wild write). The pinned build carries both mitigating patches, but the async-spec race fix was last fully soak-tested on the 0.27.1 runner.

With the drafter off, three 200K streams (600K tokens) fit the measured 656,866-token pool (2.51×); a stream that doesn't fit waits instead of forcing recomputation. That sizing is for `MAX_NUM_SEQS=3`; the shipped `nomtp.env` uses 2.

As concurrency rises, the drafter-off tier overtakes the drafter at about C=8 (211 vs 201 tok/s aggregate). Its measured ceiling is about 306–308 aggregate tok/s at C=32, against about 241 with the drafter on; past the crossover the drafter is pure overhead on a compute-bound batch. Single-stream, the drafter-off medians sit about 3% below the n=4 thinking row on narrative and within run-to-run noise on code. At deep context the drafter hurts: at 184.9K context the drafter-on tier ran 14.6 tok/s against 28.9 with it off.

**In short:** `start-mtp` is the fastest single-stream tier; `start-nomtp` is the concurrent tier and within a few percent of it single-stream. The full curve and table are in the author's source repo.
