# gemma4-31b

Google **Gemma 4 31B** — Dense 31B. The two 3090 Ti cards are mandatory: single-card vLLM doesn't boot it (24 GB holds the checkpoint with ~0 left for the KV pool), and the llama family is the separate coexistence path. The full 224K-class window fits the pair.

## Hardware

| need | why |
|---|---|
| **2× RTX 3090 (24 GB)** | mandatory: single-card vLLM doesn't boot it (24 GB holds the ~18 GB INT4 checkpoint with ~0 left for the KV pool) |
| **64 GB+ host RAM** | no expert offload; the host carries weights I/O and serving overhead |
| **~40 GB free disk** | weights ~18 GB (cyankiwi QAT-AWQ-INT4) + the 0.94 GB MTP drafter; image ~9 GB in the distro |
| **WSL2 + Docker Desktop + Windows NVIDIA driver** | `install.bat` preflights all of it and names what's missing |

| tier | port | ctx | concurrency | near-empty ctx | near-full window | authored here |
|---|---|---|---|---|---|---|
| **dual** (`start-gemma-dual.bat`) | 8032 | 179,040 | 2 seqs | ~93–117 tok/s | ~13–15 tok/s at ~170K ctx | the re-aimed yml (the source's shape rebased to this box's pool: 0.93 utilization, the 179040 window this pair's first boot pinned) + the provenance-gated delta |
| **dual-nomtp** (`start-gemma-dual-nomtp.bat`) | 8033 | 189,000 | 2 seqs | ~57.6 tok/s | **~28.9** at ~185K | same rebase; the source's proven no-MTP form hard-shipped at the pool this pair can hold |

Pick by context: MTP wins near-empty by 2x, the plain tier wins near-full by 2x.

## Tiers (vllm/)

| bat | yml (image) | port | container | shape |
|---|---|---|---|---|
| `vllm/start-gemma-dual.bat` | `gemma-dual.yml` (v0.29.0) | 8032 | `gemma-serve` | **MTP on** — the model's own 0.94 GB drafter, `SPEC_N=2` (the proven arm; `SPEC_N=0` / `SPEC=off` kills it) |
| `vllm/start-gemma-dual-nomtp.bat` | `gemma-dual-nomtp.yml` (v0.29.0) | 8033 | `gemma-serve-nomtp` | **MTP off**, the source's proven form re-aimed to this box and hard-shipped: `--max-model-len 189000` @ `--gpu-memory-utilization 0.93`, no knob (the source's 229376@0.95 cannot fit this pair's pool at any utilization) |

One tier at a time, and mutually exclusive with the qwen tiers (they all want both cards — the busy-card preflight refuses a boot into a held card).

## Weights

`TARGET_MODEL` in the tier's machine .env (`vllm/<tier>.env`, beside its start bat, one per tier) = the model the tier loads: the shipped value is the **cyankiwi QAT-AWQ-INT4** checkpoint — the only INT4 class that boots this model (lm_head excluded from the quant; the AutoRound family — the qwen quant's — is exactly what breaks Gemma 4). The knob is three-way: a bare name is a folder under `WEIGHTS_DIR`; a value containing a / is an HF repo ID or an absolute container path, used verbatim. `DRAFTER_MODEL` (same grammar) = the google 0.94 GB MTP assistant. `WEIGHTS_DIR` = where the folders live; the wizard's first run points it at this model's own `weights/` folder in the tree (the Windows side - the WSL distro stays lean); the wizard downloads anything missing.

## Knobs (the tier's machine .env — one per tier in vllm/, beside its start bat; it overrides the package template)

- `WEIGHTS_DIR` / `TARGET_MODEL` / `DRAFTER_MODEL` — storage and model selection: a bare name is a folder under `WEIGHTS_DIR`; a value containing a / is an HF repo ID or an absolute container path (verbatim) — the boot loads exactly what the line says.
- the 8032 tier runs the drafter on by design (`SPEC_N=2`); its delta's `SPEC_N` line is commented on purpose — a live line there would arm the no-MTP tier's drafter too (each tier's delta is separate, so a commented line stays off there).
- sampler block (`TEMP` / `TOP_P` / `TOP_K` / `MIN_P` / `PRESENCE_PENALTY`) — the card's one standardized row (1.0 / 0.95 / 64 / 0.0 / 1.0), live in the file.
- `CHAT_TEMPLATE` — the Google canonical template is the default (sha-anchored in `vllm/baseline/` with its SYNC note); repoint it by dropping another `.jinja` in `vllm/templates/` and naming it.

## Numbers (this rig, 2 runs per arm)

| tier | near-empty ctx | near-full window |
|---|---|---|
| MTP on (8032, 179K window) | ~93–117 tok/s | ~13–15 tok/s at ~170K ctx |
| no-MTP (8033, 189000) | ~57.6 tok/s | **~28.9** tok/s at ~185K ctx |

MTP wins near-empty by 2×; the plain tier wins near-full by 2× — run the one that matches your context. (The first boot is what pinned the 179040 MTP window: 229376 needs 12.27 GiB of KV; the MTP-on 0.93 pool holds 10.35.)

The deep content — the KV fit math, the quant landscape, the drafter story, the first-boot record, the open test battery — lives in the source repo.
