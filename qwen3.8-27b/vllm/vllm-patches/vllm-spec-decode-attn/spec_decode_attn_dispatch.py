"""
spec_decode_attn_dispatch -- vllm-spec-decode-attn

Hooks the FlashInfer native FIPrefill "run" site in
vllm/v1/attention/backends/flashinfer.py and, for the small multi-query
spec-decode (MTP / DFlash2) paged prefill, computes the attention in a
vllm-side DENSE torch path instead of flashinfer's paged kernel.

WHY (the load-bearing part)
===========================
On sm_86 (3090) with fp8 KV, FlashInfer is the only usable attention backend
(FLASH_ATTN needs sm90+, TRITON_ATTN needs sm89+). FlashInfer's
BatchPrefillWithPagedKVCacheWrapper indexes the KV pool via a flattened
``paged_kv_indices`` list of physical block ids, and its kernel computes
``block_id * per_block_stride + in_block_offset`` in int32. For the large KV
pools a near-full context produces (262K ctx here), a high block id times that
stride overflows int32 -> out-of-bounds read -> the async "illegal memory
access" that surfaces at the next cudagraph/sync point (same fault class as
vllm#50021 "Site 2", syv-ai #86/#91).

The fix: for the small multi-query prefill (1 < max query len <= QMAX -- the
spec-decode draft verify, NOT a big normal prefill), do the attention
ourselves:
  1. gather ONLY the touched KV blocks out of the fp8 pool with a torch
     advanced-index (no block_id*stride arithmetic -> no int32 overflow),
  2. dequant the gathered fp8 -> bf16 in torch (a Triton kernel cannot load
     fp8e4m3 scalars on sm_86; torch can),
  3. run a plain DENSE causal GQA attention over the dequantized KV (no paged
     index at all).
Everything else (big prefills, decode, bf16 KV, nvfp4, DCP, cascade) falls
through to the stock flashinfer run unchanged. Any error in the custom path
falls back to stock -- it never corrupts.

Gated by the VLLM_SPEC_DECODE_ATTN env var (set in the tier yml). Inert
without it.

Provenance
==========
The int64 block-math insight is syv-ai/qwen38-27b-rtx3090 #86 + pull #91
(their Triton DFlash2 drafter's int32 fix, validated on a 3090 + 4090). We
reach the same safety without a Triton kernel: we dequant + gather in torch
and attend densely, so no block-id-times-stride integer is ever computed. The
near-full MTP+FlashInfer IMA itself is the open class of vllm#55775 /
vllm#37754 / syv-ai #34; no merged sm_86 fix exists as of 0.29.0.
"""

import logging
import os

logger = logging.getLogger(__name__)

_QMAX = 16  # max query len per request for which we take over the prefill
_ENV = os.environ.get("VLLM_SPEC_DECODE_ATTN", "")
_STATE = {"n": 0}  # count of engage lines already logged (capped for noise)


def _engaged() -> bool:
    return _ENV in ("1", "true", "on", "yes", "1.0")


def _qmax_from_cpu(qo_indptr_cpu, lo, hi):
    """Max query length among requests [lo, hi), from the CPU indptr (no sync)."""
    d = qo_indptr_cpu[1 : hi + 1] - qo_indptr_cpu[lo : hi]
    if d.numel() == 0:
        return 0
    return int(d.max().item())


def dense_prefill(q, k_cache, v_cache, bt_row, kv_len, page,
                 k_scale, v_scale, scale, Hkv, G, D):
    """Dense causal GQA attention for one prefill request (the pure core).

    q          [q_len, Hq, D] bf16 (query already in the model dtype)
    k_cache    [num_blocks, Hkv, page, D] (fp8 or bf16)
    v_cache    [num_blocks, Hkv, page, D]
    bt_row     [max_blocks] physical block ids for this request
    kv_len     total KV length for the request
    Hq = Hkv*G

    Returns o [q_len, Hq, D] bf16. The query sits at the TAIL of the KV (the
    freshly drafted tokens), so query i attends to KV positions [0, off+i]
    where off = kv_len - q_len.
    """
    import torch
    dev = q.device
    q_len = q.shape[0]
    q4 = q.to(torch.bfloat16).contiguous().view(q_len, Hkv, G, D)

    pos = torch.arange(kv_len, device=dev, dtype=torch.int32)
    blk = bt_row[pos // page]
    slot = pos % page
    k_g = k_cache[blk, :, slot, :].to(torch.bfloat16).mul_(k_scale)  # [kv_len,Hkv,D]
    v_g = v_cache[blk, :, slot, :].to(torch.bfloat16).mul_(v_scale)  # [kv_len,Hkv,D]

    s = torch.einsum("ihgd,lhd->hgil", q4, k_g)  # [Hkv,G,q_len,kv_len]
    s.mul_(scale)
    off = kv_len - q_len
    ii = torch.arange(q_len, device=dev, dtype=torch.int64).view(1, 1, q_len, 1)
    ll = torch.arange(kv_len, device=dev, dtype=torch.int64).view(1, 1, 1, kv_len)
    s = s.masked_fill(ll > off + ii, float("-inf"))
    p = s.softmax(dim=-1)
    o = torch.einsum("hgil,lhd->hgid", p, v_g)  # [Hkv,G,q_len,D]
    o = o.permute(2, 0, 1, 3).reshape(q_len, Hkv * G, D)
    return o


def spec_attn_maybe_run(impl, attn_metadata, prefill_query, kv_cache_for_fi,
                        layer, out_prefill):
    """Run the spec-decode prefill attention in the vllm-side dense path.

    Returns True iff this call was handled here (the stock flashinfer run
    must then be skipped); False means fall back to the stock run.

    Signature mirrors the native FIPrefill run site in flashinfer.py
    forward() (the non-sink, non-DCP branch):
        prefill_wrapper.run(prefill_query, kv_cache_for_fi,
                            q_scale=..., k_scale=..., v_scale=...,
                            out=out_prefill, kv_cache_sf=...)
    """
    if not _engaged():
        return False

    # --- only the fp8-KV case is the one we fix -------------------------
    try:
        kvt = impl.kv_cache_dtype
    except Exception:
        return False
    if kvt not in ("fp8", "fp8_e4m3", "fp8_e5m2", "float8_e4m3fn"):
        return False
    if getattr(impl, "is_kvcache_nvfp4", False):
        return False
    if getattr(impl, "dcp_world_size", 1) > 1:
        return False
    if getattr(attn_metadata, "use_cascade", False):
        return False

    num_decodes = attn_metadata.num_decodes
    num_prefills = attn_metadata.num_prefills
    if num_prefills <= 0:
        return False
    num_reqs = num_decodes + num_prefills

    # --- need the raw vllm tensors stashed by the build() patch ----------
    bt = getattr(attn_metadata, "_sd_block_table", None)
    sl = getattr(attn_metadata, "_sd_seq_lens", None)
    qoi = getattr(attn_metadata, "_sd_qo_indptr", None)
    qoi_cpu = getattr(attn_metadata, "_sd_qo_indptr_cpu", None)
    page_md = getattr(attn_metadata, "_sd_page_size", None)
    if (bt is None or sl is None or qoi is None or qoi_cpu is None
            or page_md is None):
        return False

    # --- only the small multi-query (spec-decode) prefill ----------------
    qmax = _qmax_from_cpu(qoi_cpu, num_decodes, num_reqs)
    if qmax < 2 or qmax > _QMAX:
        return False

    if not isinstance(kv_cache_for_fi, tuple) or len(kv_cache_for_fi) != 2:
        return False
    k_cache, v_cache = kv_cache_for_fi  # each [num_blocks, Hkv, page, D]

    try:
        Hq = impl.num_heads
        Hkv = impl.num_kv_heads
        D = impl.head_size
        page = int(page_md)
        G = Hq // Hkv
        scale = impl.scale
        k_scale = float(getattr(layer, "_k_scale_float", 1.0)) or 1.0
        v_scale = float(getattr(layer, "_v_scale_float", 1.0)) or 1.0

        outs = []
        max_kv = 0
        for r in range(num_decodes, num_reqs):
            q_start = int(qoi_cpu[r])
            q_end = int(qoi_cpu[r + 1])
            q_len = q_end - q_start
            if q_len <= 0:
                continue
            kv_len = int(sl[r].item())
            if kv_len <= 0:
                continue
            max_kv = max(max_kv, kv_len)
            o = dense_prefill(prefill_query[q_start:q_end], k_cache, v_cache,
                               bt[r], kv_len, page, k_scale, v_scale, scale,
                               Hkv, G, D)
            outs.append((q_start, q_end, o))

        for (qs, qe, o) in outs:
            out_prefill[qs:qe].copy_(o)
        if _STATE["n"] < 10:
            logger.info("vllm-spec-decode-attn: dense spec-decode prefill "
                        "ENGAGED #%d (n_prefills=%d qmax=%d max_kv=%d)",
                        _STATE["n"] + 1, num_prefills, qmax, max_kv)
            _STATE["n"] += 1
        return True
    except Exception as e:  # noqa: BLE001 - defensive: fall back to stock
        logger.warning("vllm-spec-decode-attn: dense path failed (%s); "
                       "falling back to stock flashinfer", e)
        return False
