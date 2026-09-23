# vllm-dflash2-backport — DFlash2 W4A16 drafter KV-dequant (v0.29.0 slice)

On the **v0.29.0** base the DFlash2 drafter is **stock**: the image ships the `DFlash2DraftModel` (grouped dynamic convolution + candidate selector, upstream [vllm-project/vllm#52816](https://github.com/vllm-project/vllm/pull/52816)), the V2-runner `DFlash2Speculator`, the `DFlash2DraftModel` registry entry, and the `spec_decode/__init__.py` dispatch that routes a `DFlash2DraftModel` to it. The pre-rebase form of this bundle (a 13-file syv-ai v0.27.1 backport) vendored all of that; re-anchoring to 0.29.0 found every one of those files already present, so they are **dropped**. What 0.29.0 does *not* ship is support for a **quantized** drafter, and that is the whole of this bundle now.

## What it adds

One function, `_dense_kv_rows`, in `model_executor/models/qwen3_dflash.py`, plus a one-line re-point of the drafter's `_build_context_kv_buffers`. The drafter's context-KV precompute reads the `[q_size:]` rows of each layer's `qkv_proj`; stock slices a plain 2-D weight, but a compressed-tensors **W4A16** `qkv_proj` stores pack-quantized weights, so this dequantizes them (`weight_packed * weight_scale`) to a dense bf16 matrix at load time, before the Marlin repack. Two hunks, one file.

## Why it matters here

The box serves the drafter as **W4A16** (`syvai/Qwen3.8-27B-DFlash2-W4A16`, ~1.2 GB) so it fits beside the W4A8 27B at 262K ctx / 0.90 utilization on 2×3090, and it shares the target's int8-Marlin lm_head. A stock 0.29.0 drafter assumes a bf16 `qkv_proj`, so a W4A16 drafter would precompute garbage KV without this dequant. (0.29.0's `LogitsProcessor._apply_head` already routes a quantized lm_head through `quant_method.apply()`, so the shared-head side needed no patch.)

The 3090 stack's other DFlash2 additions — the small-k top-k (`k_max`) sampler path and the selector's top-k/top-p proposal truncation — are **not** in this bundle: they are speed-only, and the box's default sampler (top-k 20 / top-p 0.95) does not exercise the small-k path. The conv+selector acceptance gain — the reason DFlash2 beats the built-in MTP drafter — is entirely stock in 0.29.0.

## Provenance / attribution

The DFlash2 drafter and this dequant derive from [syv-ai/qwen38-27b-rtx3090](https://github.com/syv-ai/qwen38-27b-rtx3090) (the W4A16 drafter and the `qwen3_dflash` KV-dequant). The drafter model + selector are upstream vLLM's (#52816). Attribution is kept here, not in the patch body.

## Delivery

Idempotent `install.sh` (mount at `/etc/vllm-patches/dflash2`, called in the tier's entrypoint before serve): a `_check_applied.py` present-check, else `patch -p1 --forward` from the `vllm/` package dir. Refuses boot on failure. Applies clean on stock `vllm/vllm-openai:v0.29.0` (verified by dry-run against the v0.29.0 tag's `qwen3_dflash.py`). On any other base the `kv_weights` anchor moves and the apply is a red "re-anchor to a newer base" signal, not a hunk to hand-nudge.
