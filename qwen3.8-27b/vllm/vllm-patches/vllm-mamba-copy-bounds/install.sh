#!/bin/bash
# mamba-copy-bounds patch installer (vllm#50021, Site 2). The tier's entrypoint
# calls this before vllm serve; it refuses boot on any failure.
#
# What it fixes: in mamba "align" prefix-cache mode the state pre-copy
# (_copy_mamba_state_block) read the request's block-table state columns
# (dst_col / src_col / src_col+token_bias) with NO bounds mask. A request that
# RESUMES over a prefix-cache hit, batched with a concurrent prefill, can be
# handed a state column outside its block-table row; the unbounded load then
# reads a garbage block id, multiplies it by the (large) mamba page stride, and
# tl.store()s to that address — a wild write that faults the SM
# (cudaErrorIllegalAddress / Xid 31) and kills the engine. This is the nomtp
# 2-concurrent deep-resume crash. The hunk masks all four column loads to the
# row and rejects block ids <= 0, routing an out-of-range column to the existing
# no-copy early-return. Complements vllm-mamba-align-seed (#53142, the seed)
# and is disjoint from vllm-syv-mamba-align-ckpts (eviction order).
#
# Always-on here: the pre-copy runs in align mode, which is this tier's
# MAMBA_CACHE_MODE, so any box that boots this yml in align mode is covered.
# (A MAMBA_CACHE_MODE=none boot never reaches the align pre-copy and is
# unaffected.) No env gate.
#
# Idempotent: an image that already carries the fix is a no-op.
#
# Authored from vllm#50021's mamba_utils.py hunk; re-anchored for the 0.29.0
# rebase (the context is byte-identical to vllm/vllm-openai:v0.29.0, so it
# applies clean; --fuzz=3 is belt-and-suspenders for any line drift).

set -u
DIR=/etc/vllm-patches/mamba-copy-bounds
VLLM=/usr/local/lib/python3.12/dist-packages/vllm
MU=$VLLM/v1/worker/mamba_utils.py

if grep -q "dst_col_ok" "$MU" 2>/dev/null \
   && grep -q "src_col_ok" "$MU" 2>/dev/null \
   && grep -q "tmp_col_ok" "$MU" 2>/dev/null; then
    echo "[mamba-copy-bounds] already applied (image carries the fix) — skipping" >&2
    exit 0
fi

if ( cd "$VLLM" && patch -p1 --forward --batch --fuzz=3 \
        < "$DIR/50021-mamba-copy-bounds.patch" \
        > /tmp/mamba-copy-bounds.patch.log 2>&1 ); then
    if ! grep -q "dst_col_ok" "$MU" \
       || ! grep -q "src_col_ok" "$MU" \
       || ! grep -q "tmp_col_ok" "$MU"; then
        echo "[mamba-copy-bounds] patch reported success but a marker is missing — refusing boot:" >&2
        tail -20 /tmp/mamba-copy-bounds.patch.log >&2
        exit 1
    fi
    python3 -m py_compile "$MU" \
        || { echo "[mamba-copy-bounds] py_compile failed — refusing boot" >&2; exit 1; }
    echo "[mamba-copy-bounds] applied: align pre-copy block-table columns are now row-bounded (out-of-range col -> no-copy, not a wild write)" >&2
else
    echo "[mamba-copy-bounds] FAILED to apply 50021-mamba-copy-bounds.patch — refusing boot:" >&2
    tail -20 /tmp/mamba-copy-bounds.patch.log >&2
    exit 1
fi
