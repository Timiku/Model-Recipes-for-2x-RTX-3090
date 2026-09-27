#!/usr/bin/env python3
"""
spec_decode_attn_test.py -- pre-trust numerical gate for vllm-spec-decode-attn.

Runs in a probe container (vllm/vllm-openai, needs a GPU). It does NOT import
vllm -- only torch. It checks the shipped dense path
(spec_decode_attn_dispatch.dense_prefill) against an independent naive
elementwise reference:

  * bf16        : K/V pool is bf16, dequant is a no-op (scale=1).
  * --fp8       : K/V pool is fp8_e4m3, gathered then dequantized by a scalar
                   scale, exactly as the sm_86 fp8 KV path does in the model.

For each request it asserts the dense GQA causal attention (query at the KV
tail) matches the reference. This is the anti-corruption gate: if the gather
indexing, the dequant, or the causal mask were wrong, this fails BEFORE the
real tier is trusted. The dense path has no block_id*stride integer at all, so
there is no int32 overflow to exercise -- the point is that the numbers are
right, not that they survive a huge pool.
"""
import sys
from pathlib import Path

import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from spec_decode_attn_dispatch import dense_prefill  # noqa: E402

torch.manual_seed(0)
DEV = "cuda"


def build_pool(num_blocks, Hkv, page, D, fp8, scale):
    """Return (k_cache, v_cache) in the model's HND+KV-split layout."""
    base = torch.randn(num_blocks, Hkv, page, 2 * D, dtype=torch.float32,
                       device=DEV)
    if fp8:
        pool = (base / scale).to(torch.float8_e4m3fn)
    else:
        pool = base.to(torch.bfloat16)
    return pool[..., :D], pool[..., D:]


def reference_out(q, k_ref, v_ref, Hkv, G, D, scale, kv_len):
    """Naive causal GQA attention (fp32), query at the tail of the KV."""
    q_len, Hq = q.shape[0], q.shape[1]
    off = kv_len - q_len
    O = torch.zeros(q_len, Hq, D, dtype=torch.float32, device=DEV)
    for i in range(q_len):
        for h in range(Hq):
            hk = h // G
            sc = torch.full((kv_len,), float("-inf"), dtype=torch.float32,
                             device=DEV)
            for l in range(off + i + 1):
                sc[l] = scale * (q[i, h].float() @ k_ref[l, hk, :])
            p = torch.softmax(sc, dim=-1)
            O[i, h, :] = p @ v_ref[:, hk, :]
    return O


def one_case(fp8, scale, D, Hkv, G, page, reqs):
    Hq = Hkv * G
    att = 1.0 / (D ** 0.5)  # realistic attention scale (the model's 1/sqrt(D))
    per_req_blocks = [(kv_len + page - 1) // page for (kv_len, _) in reqs]
    num_blocks = sum(per_req_blocks) + 4   # pool a bit larger than used
    max_b = max(per_req_blocks)
    k_cache, v_cache = build_pool(num_blocks, Hkv, page, D, fp8, scale)

    bt = torch.zeros(len(reqs), max_b, dtype=torch.int32, device=DEV)
    nb = 1
    for r, _ in enumerate(reqs):
        for b in range(per_req_blocks[r]):
            bt[r, b] = nb
            nb += 1

    qo_indptr = [0]
    for (_, q) in reqs:
        qo_indptr.append(qo_indptr[-1] + q)
    query = torch.randn(sum(q for (_, q) in reqs), Hq, D,
                        dtype=torch.bfloat16, device=DEV)

    max_err = 0.0
    for r, (kv_len, q_len) in enumerate(reqs):
        q_start = qo_indptr[r]
        qreq = query[q_start:q_start + q_len]
        got = dense_prefill(qreq, k_cache, v_cache, bt[r], kv_len, page,
                            scale, scale, att, Hkv, G, D).float()
        pos = torch.arange(kv_len, device=DEV)
        blk = bt[r, pos // page]
        slot = pos % page
        k_ref = k_cache[blk, :, slot, :].float() * scale
        v_ref = v_cache[blk, :, slot, :].float() * scale
        ref = reference_out(qreq, k_ref, v_ref, Hkv, G, D, att, kv_len)
        err = (got - ref).abs().max().item()
        max_err = max(max_err, err)
        print("   case req%d q_len=%d kv_len=%d blocks=%d: max_err=%.5f"
              % (r, q_len, kv_len, per_req_blocks[r], err))
    return max_err


def main():
    fp8 = "--fp8" in sys.argv
    label = "fp8" if fp8 else "bf16"
    # realistic head shapes; small kv_len keeps the naive reference fast
    D, Hkv, G, page = 128, 8, 4, 16   # Hq = 32
    scale = 128.0 if fp8 else 1.0
    reqs = [(60, 5), (81, 3), (40, 4), (24, 2), (17, 2)]
    print("[%s] D=%d Hkv=%d G=%d Hq=%d page=%d scale=%s"
          % (label, D, Hkv, G, Hkv * G, page, scale))
    max_err = one_case(fp8, scale, D, Hkv, G, page, reqs)
    thr = 5e-2
    ok = max_err < thr
    print("[%s] max_err=%.5f thr=%.3f  ->  %s"
          % (label, max_err, thr, "PASS" if ok else "FAIL"))
    if not ok:
        print("RESULT: FAIL")
        sys.exit(1)
    print("RESULT: PASS")


if __name__ == "__main__":
    main()
