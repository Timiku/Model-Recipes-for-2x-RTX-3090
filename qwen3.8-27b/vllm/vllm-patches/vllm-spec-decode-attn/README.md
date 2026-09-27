# vllm-spec-decode-attn

**EXPERIMENTAL — not a validated fix, not wired into any tier.** The sm_86 (3090) MTP / DFlash2 + FlashInfer + fp8-KV near-full IMA: a real, deep-researched fault, with a candidate fix authored here that passes an isolated numerics gate but did not survive the real model (see Status). Kept as provenance-anchored research, not shipped.

## Status (2026-09-13) — authored, numerics-validated, NOT validated on the model

- **Isolated numerics: PASS.** `dense_prefill` matches a naive causal GQA reference to bf16 precision on a synthetic pool (bf16 and fp8-dequant), in a 0.29.0 probe; the installer clean-applies to the real 0.29.0 `flashinfer.py` (idempotent, drift-gated).
- **On the real model: it does not engage, and when it tried it broke the boot.** On `qwen-27b` (0.29.0, sm_86, fp8 KV, MTP) two independent failures:
  1. **KV-head layout mismatch** — the dense core assumes the pool is `[num_blocks, num_kv_heads, page, D]`, but the pool's head dim does not equal the layer's `num_kv_heads` (observed 2 vs 16), so the gather/einsum cannot broadcast.
  2. **Out-of-bounds pool read on the profile's dummy data** — the block-table gather ran on the cudagraph-profile dummy forward before that shape error surfaced; the async OOB tripped a `device-side assert` at the next synchronize and killed the engine core at init (the tier never reached READY).
- **Consequence:** not wired into `mtp.yml`/`superfast.yml` (reverted to the pinned baseline; no `VLLM_SPEC_DECODE_ATTN` knob, no install call). The near-full IMA is **unfixed on this box** — same state as before this attempt.
- **Why hand-rolled, and why it's kept:** no merged upstream sm_86 fp8-KV flashinfer-prefill fix exists to import (vllm#55775/#37754, syv-ai#34 all open; the only merged attention change is SM12x-gated). A safe version needs a correct, arch-aware head-dim mapping and a bounds-checked gather before it can run on the model.

## The fault

On a large fp8 KV pool (a ~210K-token context), the *draft* (speculative-decode) attention is a small multi-query **paged prefill** that FlashInfer runs in its C++ `BatchPrefillWithPagedKVCacheWrapper`. That wrapper indexes the KV pool through a flattened `paged_kv_indices` list of physical block ids, and its kernel computes `block_id * per_block_stride + in_block_offset` **in int32**. For high block ids the product overflows int32 → out-of-bounds read → an async *illegal memory access* that surfaces at the next cudagraph/sync point. Reported across the 3090 community as the same crash:

- **syv-ai/qwen38-27b-rtx3090 #34** — MTP + fp8 KV + flashinfer, deterministic IMA in the flashinfer paged prefill.
- **syv-ai #86 / pull #91** — the same `blk * stride` int32 overflow in their Triton DFlash2 drafter; their fix was a one-line `blk.to(tl.int64)` (tested on 3090 + 4090).
- **vllm-project/vllm #55775 / #37754** — the same class, all **open**. The only merged attention change that addresses it (the SM12x XQA path) is **arch-gated away from sm_86**.
- **club-3090 #1139** — the community's interim mitigation (`--no-async-scheduling`) does **not** clear the fault (verified on this box); it only changes which request it lands on.

On sm_86 with fp8 KV, FlashInfer is the **only** usable attention backend (FLASH_ATTN needs sm90+, TRITON_ATTN needs sm89+), so there is no single-variable backend swap that avoids it.

## The candidate approach

Route the spec-decode (small multi-query, causal) paged prefill **off the FlashInfer paged wrapper and onto a vllm-side dense attention**. Three properties make it safe where a naive re-implementation is not:

1. **No paged index, no overflow.** The touched KV is gathered straight out of the fp8 pool with a torch advanced-index (`k_cache[blk, :, slot, :]`). No `block_id * stride` integer is ever computed, so the int32 overflow cannot exist here.
2. **fp8 dequant in torch, not Triton.** A Triton kernel cannot load fp8e4m3 scalars on sm_86; torch can. The gathered fp8 K/V are dequantized to bf16 by the model's scalar tensor scale (kFp8StaticTensorSym) — one multiply.
3. **Dense GQA causal attention.** A plain `q @ k` / softmax / `p @ v` over the dequantized KV (query at the KV tail), in the model's own dtype.

Gated by `VLLM_SPEC_DECODE_ATTN=1`. It engages only for a causal `1 < max_query_len ≤ 16` paged prefill with fp8 KV (the draft-verify shape) — never a big normal prefill, decode, bf16 KV, nvfp4, DCP, or cascade batch. On **any** internal error it falls back to the stock FlashInfer call unchanged, so it can never corrupt output.

Files:
- `spec_decode_attn_dispatch.py` — the guard (`spec_attn_maybe_run`) + the pure dense core (`dense_prefill`). Staged into `vllm/v1/attention/ops/` at boot.
- `patch_flashinfer_spec_attn.py` — the installer: stages the dispatch and makes three exact-anchored edits to `flashinfer.py` (import; stash the raw `block_table`/`seq_lens`/`qo_indptr` onto the metadata in `build()`; wrap the native FIPrefill `run` so the dispatch is offered first). Marker-gated, idempotent, hard-fails (exit 2) on any anchor drift.
- `spec_decode_attn_test.py` — the pre-trust numerical gate (below).

## Provenance

- The int64 block-math insight is **syv-ai/qwen38-27b-rtx3090 #86 + pull #91** (their Triton DFlash2 drafter fix, tested on a 3090 + 4090). We reach the same safety without a Triton kernel: dequant + gather in torch, attend densely, so the overflow-prone integer is never formed.
- The fp8-scalar-scale dequant mirrors the sm_86 path in 0.29.0's own `flashinfer` backend.
- The near-full MTP+FlashInfer IMA is the open class of vllm#55775 / #37754 / syv-ai #34; **no merged sm_86 fix exists as of 0.29.0** — which is why this is a hand-authored, provenance-anchored patch rather than an import.

## Validate before trusting the tier

The dense core is **unit-checked before the real tier is trusted** — run the self-check in a probe container on the box (`docker run --rm --gpus all --entrypoint bash -v <bundle>:/sd:ro vllm/vllm-openai:v0.29.0 -c '…'`):

```bash
python3 /sd/spec_decode_attn_test.py      # bf16 pool
python3 /sd/spec_decode_attn_test.py --fp8   # fp8 dequant
```

Each asserts `dense_prefill` matches an independent naive elementwise causal GQA reference (bf16 tight; fp8 within dequant rounding). Only after both pass is the tier benched for the near-full IMA.
