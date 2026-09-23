#!/bin/bash
# mamba-align-seed patch installer (vllm#53142). The tier's entrypoint calls
# this before vllm serve; it refuses boot on any failure.
#
# What it fixes (upstream vllm#53142, issue-only, no PR): in mamba "align"
# prefix-cache mode, MambaHybridModelState.add_request seeded the request's
# running mamba state index with (num_computed_tokens - 1) // cache_config
# .block_size — the KV block size. But that index is a MAMBA block index (the
# align pre-copy reads the mamba block table at that row), so on the first
# scheduling step of a request that RESUMES over a prefix-cache hit the wrong
# divisor plants a row outside the table and the fused pre-copy dereferences a
# garbage block id -> a CUDA illegal memory access that kills the engine on the
# 2nd large prefill. The patch divides by the mamba group's block size instead,
# threading the runner's kv_cache_config into add_request (the only home of the
# spec; there is no vllm_config/model-state field for it).
#
# Always-on: the seed is only reachable in align mode (mtp/nomtp ship it), so a
# tier that runs MAMBA_CACHE_MODE=none is simply unaffected. No env gate.
#
# Idempotent: an image that already carries the fix is a no-op.
#
# Authored against v0.28.0; re-anchored for the 0.29.0 rebase — the same hunks
# still apply (verified: dry-apply + both markers + py_compile all green on
# v0.29.0), so the bundle is unchanged and mounted on every mamba-align tier.

set -u
DIR=/etc/vllm-patches/mamba-align-seed
VLLM=/usr/local/lib/python3.12/dist-packages/vllm
MH=$VLLM/v1/worker/gpu/model_states/mamba_hybrid.py
MR=$VLLM/v1/worker/gpu/model_runner.py

if grep -q "mamba_block = mamba_spec.block_size" "$MH" 2>/dev/null \
   && grep -qF "isinstance(self.model_state, MambaHybridModelState)" "$MR" 2>/dev/null; then
    echo "[mamba-align-seed] already applied (image carries the fix) — skipping" >&2
    exit 0
fi

if ( cd "$VLLM" && patch -p1 --forward --batch \
        < "$DIR/53142-mamba-align-seed.patch" \
        > /tmp/mamba-align-seed.patch.log 2>&1 ); then
    if ! grep -q "mamba_block = mamba_spec.block_size" "$MH" \
       || ! grep -qF "isinstance(self.model_state, MambaHybridModelState)" "$MR"; then
        echo "[mamba-align-seed] patch reported success but a marker is missing — refusing boot:" >&2
        tail -20 /tmp/mamba-align-seed.patch.log >&2
        exit 1
    fi
    python3 -m py_compile "$MH" "$MR" \
        || { echo "[mamba-align-seed] py_compile failed — refusing boot" >&2; exit 1; }
    echo "[mamba-align-seed] applied: mamba-align pre-copy now seeds the running state index with the mamba block size (was the KV block size)" >&2
else
    echo "[mamba-align-seed] FAILED to apply 53142-mamba-align-seed.patch — refusing boot:" >&2
    tail -20 /tmp/mamba-align-seed.patch.log >&2
    exit 1
fi
