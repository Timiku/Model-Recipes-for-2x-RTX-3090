"""House #8d: the packed-direct decode kernel.

For single-query decode steps (Lq == 1) on the head-512 global layers,
`_decode_path_slow` used to pay, per layer per step: the #7 gather (one
launch materializing seq_len x Hk x D fp16 K/V — the 09-21 timed boot
measured 241.5 ms/layer at a 100k context under production conditions;
the isolated probe's 15.7 ms does not survive contact with the GPU-PV
residency pressure of rewriting the ~840 MB pool wholesale every step)
plus the attention over it (177 ms/layer measured). This kernel reads
the packed int4 cache and the fp16 tail pools DIRECTLY, dequantizes in
register, and runs the online softmax in one launch — no fp16 K/V ever
materializes.

Provenance and validation: the kernel is the #8 prototype from
`.boxpatch/boxprobe/kvarn-prefill-probe.py` (same repo), which checked
bit-clean against gather+SDPA on an indexing-sensitive random state
(random nibbles, unit scales; max abs 9.8e-4, max rel 8.4e-4, 0 NaN —
after two probe-state bugs were fixed: V zp is GROUP-wide, and a
half-zeroed fp16 byte pair is a random exponent). Semantics for decode:
every column <= seq_len is visible (seq_len = cached_len + 1; no future
columns exist), which is exactly the probe's history-only shape — no
causal mask needed. The tail pool is read through the same
block_to_slot mapping the gather uses, so a live tail (the current
block's freshly stored tokens) is visible exactly as before.

The kernel is warm-compiled in `_warm_decode_kernels` (same constexpr
set as the serving launch), so the first deep request does not JIT
mid-step.
"""
import torch
import triton
import triton.language as tl


@triton.jit
def _kvarn_prefill_direct_kernel(
    Q_ptr,                 # [LQ, HQ, D] fp16 pre-rotated (token-major)
    Block_table_ptr,       # [1, max_blocks] int32 (this request's row)
    Seq_lens_ptr,          # [1] int32 - the full sequence length
    Block_to_slot_ptr,     # [lookup] int32 (-1 = in the int4 cache)
    KV_cache_ptr,          # [num_blocks, Hk, tile_bytes_aligned] uint8
    Tail_K_pool_ptr, Tail_V_pool_ptr,
    Out_ptr,               # [LQ, HQ, D] fp16, rotated frame
    scale,
    LQ,
    stride_q_t, stride_q_h,
    stride_bt_b,
    stride_kv_b, stride_kv_h,
    stride_pool_b, stride_pool_t, stride_pool_h,
    stride_o_t, stride_o_h,
    HQ: tl.constexpr, HK: tl.constexpr,
    D: tl.constexpr, GROUP: tl.constexpr,
    BLOCK_M: tl.constexpr, BLOCK_N: tl.constexpr,
    K_BITS: tl.constexpr, V_BITS: tl.constexpr,
    K_PACKED_OFFSET: tl.constexpr, K_S_COL_OFFSET: tl.constexpr,
    K_ZP_OFFSET: tl.constexpr, K_S_ROW_OFFSET: tl.constexpr,
    V_PACKED_OFFSET: tl.constexpr, V_S_COL_OFFSET: tl.constexpr,
    V_S_ROW_OFFSET: tl.constexpr, V_ZP_OFFSET: tl.constexpr,
    NUM_BLOCKS_LOOKUP: tl.constexpr,
):
    Q_PER_KV: tl.constexpr = HQ // HK
    R: tl.constexpr = BLOCK_M * Q_PER_KV      # rows per program
    t0 = tl.program_id(0) * BLOCK_M
    hk = tl.program_id(1)
    hq0 = hk * Q_PER_KV

    seq_len = tl.load(Seq_lens_ptr)
    n_blocks = (seq_len + GROUP - 1) // GROUP

    r = tl.arange(0, R)
    d_offs = tl.arange(0, D)
    tok = t0 + r // Q_PER_KV                   # absolute q token
    lane = r % Q_PER_KV                        # q-head lane within this kv head
    rmask = tok < LQ
    PACK_K: tl.constexpr = 8 // K_BITS
    PACK_V: tl.constexpr = 8 // V_BITS
    MASK_K: tl.constexpr = (1 << K_BITS) - 1
    MASK_V: tl.constexpr = (1 << V_BITS) - 1
    d_byte_v = d_offs // PACK_V
    d_shift_v = (d_offs % PACK_V) * V_BITS

    q = tl.load(Q_ptr + tok[:, None] * stride_q_t + (hq0 + lane)[:, None] * stride_q_h
                + d_offs[None, :], mask=rmask[:, None], other=0.0)

    m_i = tl.full([R], -float("inf"), dtype=tl.float32)
    l_i = tl.zeros([R], dtype=tl.float32)
    acc = tl.zeros([R, D], dtype=tl.float32)

    for k in range(0, n_blocks):
        rem = seq_len - k * GROUP
        n_tok = tl.minimum(tl.maximum(rem, 0), GROUP)
        block_id = tl.load(Block_table_ptr + k)
        in_range = (block_id >= 0) & (block_id < NUM_BLOCKS_LOOKUP)
        safe_bid = tl.where(in_range, block_id, 0)
        pool_slot = tl.load(Block_to_slot_ptr + safe_bid, mask=in_range, other=-1)
        tile_base = block_id.to(tl.int64) * stride_kv_b + hk * stride_kv_h
        safe_slot = tl.where(pool_slot >= 0, pool_slot, 0)
        pool_base = safe_slot.to(tl.int64) * stride_pool_b + hk * stride_pool_h

        ku16 = (KV_cache_ptr + tile_base).to(tl.pointer_type(tl.uint16))
        s_col_K = tl.load(ku16 + (K_S_COL_OFFSET // 2) + d_offs).to(tl.float16, bitcast=True)
        zp_K = tl.load(ku16 + (K_ZP_OFFSET // 2) + d_offs).to(tl.float16, bitcast=True)
        s_col_V = tl.load(ku16 + (V_S_COL_OFFSET // 2) + d_offs).to(tl.float16, bitcast=True)

        for c0 in range(0, GROUP, BLOCK_N):
            cols = c0 + tl.arange(0, BLOCK_N)
            cmask = cols < n_tok
            if pool_slot >= 0:
                src = pool_base + cols[:, None] * stride_pool_t + d_offs[None, :]
                Kc = tl.load(Tail_K_pool_ptr + src, mask=cmask[:, None], other=0.0)
                Vc = tl.load(Tail_V_pool_ptr + src, mask=cmask[:, None], other=0.0)
                K_dg = tl.trans(Kc)
            else:
                cb_k = cols // PACK_K
                cs_k = (cols % PACK_K) * K_BITS
                s_row_K = tl.load(ku16 + (K_S_ROW_OFFSET // 2) + cols).to(tl.float16, bitcast=True)
                k_addrs = (tile_base + K_PACKED_OFFSET + d_offs[:, None] * (GROUP // PACK_K) + cb_k[None, :])
                k_bytes = tl.load(KV_cache_ptr + k_addrs).to(tl.int32)
                q_K = ((k_bytes >> cs_k[None, :]) & MASK_K).to(tl.float16)
                K_dg = (q_K * s_col_K[:, None] + zp_K[:, None]) * s_row_K[None, :]
                s_row_V = tl.load(ku16 + (V_S_ROW_OFFSET // 2) + cols).to(tl.float16, bitcast=True)
                zp_V = tl.load(ku16 + (V_ZP_OFFSET // 2) + cols).to(tl.float16, bitcast=True)
                v_addrs = (tile_base + V_PACKED_OFFSET + cols[:, None] * (D // PACK_V) + d_byte_v[None, :])
                v_bytes = tl.load(KV_cache_ptr + v_addrs).to(tl.int32)
                q_V = ((v_bytes >> d_shift_v[None, :]) & MASK_V).to(tl.float16)
                Vc = (q_V * s_row_V[:, None] + zp_V[:, None]) * s_col_V[None, :]

            scores = tl.dot(q, K_dg)               # fp16 x fp16 -> fp32 [R, BN]
            scores = tl.where(cmask[None, :], scores * scale, -float("inf"))
            m_new = tl.maximum(m_i, tl.max(scores, axis=1))
            m_dead = m_new == -float("inf")
            p = tl.where(m_dead[:, None], 0.0, tl.exp(scores - m_new[:, None]))
            alpha = tl.where(m_dead, 0.0, tl.exp(m_i - m_new))
            l_i = l_i * alpha + tl.sum(p, axis=1)
            acc = acc * alpha[:, None] + tl.dot(p.to(tl.float16), Vc)
            m_i = m_new

    O = acc / tl.where(l_i > 0, l_i, 1.0)[:, None]
    tl.store(Out_ptr + tok[:, None] * stride_o_t + (hq0 + lane)[:, None] * stride_o_h
             + d_offs[None, :], O.to(tl.float16), mask=rmask[:, None])


# The serving launch config -- the sweep winner from check8d.py on the
# box (lq=512, ctx=4096, D=512): BM=4/BN=32/w=4/s=2 at 3.87 ms median.
# BM=8/BN=64 does not fit the SMEM at D=512 (102400 B required vs the
# 101376 limit); BN=64 configs are OutOfResources across warp counts.
DIRECT_BM, DIRECT_BN, DIRECT_WARPS, DIRECT_STAGES = 4, 32, 4, 2


def launch_prefill_direct(
    q_rot, block_table_row, seq_lens_one, block_to_slot,
    kv_cache, tail_k, tail_v, out, scale, LQ,
    *,
    num_heads, num_kv_heads, cfg, block_lookup_size,
):
    """One-launch decode attention over the packed cache (house #8d).

    q_rot: [LQ, HQ, D] fp16, token-major, PRE-rotated (the caller rotates
    with the same fp16 Hadamard as the store side). out: [LQ, HQ, D]
    fp16, rotated frame (the caller un-rotates). All strides are taken
    from the live tensors; the constexpr set matches
    `_warm_decode_kernels` exactly so the warm variant serves.
    """
    D = cfg.head_dim
    _kvarn_prefill_direct_kernel[(triton.cdiv(LQ, DIRECT_BM), num_kv_heads)](
        q_rot, block_table_row, seq_lens_one, block_to_slot,
        kv_cache, tail_k, tail_v, out, scale, LQ,
        q_rot.stride(0), q_rot.stride(1),
        block_table_row.stride(0),
        kv_cache.stride(0), kv_cache.stride(1),
        tail_k.stride(0), tail_k.stride(1), tail_k.stride(2),
        out.stride(0), out.stride(1),
        HQ=num_heads, HK=num_kv_heads,
        D=D, GROUP=cfg.group,
        BLOCK_M=DIRECT_BM, BLOCK_N=DIRECT_BN,
        num_warps=DIRECT_WARPS, num_stages=DIRECT_STAGES,
        K_BITS=cfg.key_bits, V_BITS=cfg.value_bits,
        NUM_BLOCKS_LOOKUP=block_lookup_size,
        K_PACKED_OFFSET=cfg.k_packed_offset, K_S_COL_OFFSET=cfg.k_s_col_offset,
        K_ZP_OFFSET=cfg.k_zp_offset, K_S_ROW_OFFSET=cfg.k_s_row_offset,
        V_PACKED_OFFSET=cfg.v_packed_offset,
        V_S_COL_OFFSET=cfg.v_s_col_offset,
        V_S_ROW_OFFSET=cfg.v_s_row_offset, V_ZP_OFFSET=cfg.v_zp_offset,
    )
