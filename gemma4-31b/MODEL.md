# gemma4-31b

Google **Gemma 4 31B**, a dense 31B model. It needs both 3090 cards: single-card vLLM can't boot it, because 24 GB holds the ~18 GB INT4 checkpoint with almost nothing left for the KV pool.

## Hardware

| need | why |
|---|---|
| **2× RTX 3090 (24 GB)** | Required; see above. |
| **64 GB+ host RAM** | No expert offload; host RAM covers weight loading and serving overhead. |
| **~40 GB free disk** | Weights ~18 GB (cyankiwi QAT-AWQ-INT4), the 0.94 GB MTP drafter, and ~9 GB for the image. |
| **WSL2 + the Windows NVIDIA driver** (Windows) | `install.bat` checks for them, and installs Docker Engine and the NVIDIA container runtime inside the distro if they are missing. |

## Tiers

Both tiers run vLLM v0.29.0. Only one tier runs at a time, and neither can run alongside a qwen tier, since they all need both cards.

| start script | yml | port | container | window | seqs | setup |
|---|---|---|---|---|---|---|
| `start-gemma-dual` | `gemma-dual.yml` | 8032 | `gemma-serve` | 179,040 | 2 | **MTP on**: the model's own 0.94 GB drafter at `SPEC_N=2`, the tested setting. |
| `start-gemma-dual-nomtp` | `gemma-dual-nomtp.yml` | 8033 | `gemma-serve-nomtp` | 189,000 | 2 | **MTP off**: the source recipe's tested no-MTP setup, resized to this machine. The source's 229,376-token window at 0.95 utilization can't fit this pair's memory at any utilization. |

Both `.env` files ship `GPU_MEMORY_UTILIZATION=0.9390`.

Each tier has its own `.env`, so `SPEC_N` in one can't turn on the drafter in the other. `gemma-dual.env` ships `SPEC_N=2`; `gemma-dual-nomtp.env` ships `SPEC_N=0`. Setting `SPEC_N=0` (or `SPEC=off`) in `gemma-dual.env` turns its drafter off.

## Weights

Set in the tier's `.env`:

- `TARGET_MODEL`: the checkpoint. Ships as **cyankiwi QAT-AWQ-INT4**, the only INT4 variant that boots this model. Its `lm_head` is left unquantized. AutoRound quants, which the qwen models use, break Gemma 4.
- `DRAFTER_MODEL`: Google's 0.94 GB MTP assistant.
- `WEIGHTS_DIR`: where the folders live. The installer points it at this model's own `weights/` folder and downloads anything missing.

For `TARGET_MODEL` and `DRAFTER_MODEL`, a bare name is a folder under `WEIGHTS_DIR`; a value containing `/` is a Hugging Face repo ID or an absolute container path, used as-is.

**The checkpoint pick.** The installer wizard asks which target checkpoint the tiers load (`TARGET_MODEL`, step 2b in `install.sh`/`install.bat`): the shipped default (cyankiwi QAT-AWQ-INT4), a Hugging Face repo id (fetched on demand by `vllm/package/weights-source.sh`), or an already-provisioned folder path. The pick applies to both tiers.

## Settings

- `TEMP` / `TOP_P` / `TOP_K` / `MIN_P` / `REPEAT_PENALTY`: the model card's standard sampler values (1.0 / 0.95 / 64 / 0.0 / 1.0), filled in in both files.
- `KV_DTYPE`: KV cache type (`auto`).
- `CHAT_TEMPLATE`: blank uses Google's template, which is sha-pinned in `vllm/baseline/` with its sync note. To use another, put a `.jinja` file in `vllm/templates/` and name it here.

## Measured speed

This machine, 2 runs per tier, tokens per second.

| tier | near-empty context | near-full context |
|---|---|---|
| MTP on (8032, 179K window) | ~93–117 | ~13–15 at ~170K |
| MTP off (8033, 189K window) | ~57.6 | **~28.9** at ~185K |

MTP is about 2× faster near an empty context; the plain tier is about 2× faster near a full one. Run the one that matches your workload.

The first boot is what set the MTP window to 179,040: a 229,376-token window needs 12.27 GiB of KV, and the MTP-on pool holds 10.35 GiB.

The KV fit math, the quantization comparison, the drafter history, the first-boot record and the open test list are in the author's source repo.
