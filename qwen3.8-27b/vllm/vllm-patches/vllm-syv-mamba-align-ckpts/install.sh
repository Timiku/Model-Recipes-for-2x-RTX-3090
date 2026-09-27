#!/bin/bash
# syv-ai mamba align-checkpoint-order patch installer (the tier's entrypoint
# calls this before vllm serve; it refuses boot on any failure).
#
# What it fixes (their issue #52; upstream vllm#45238; gotcha 44): in mamba
# align mode the prefix cache holds ~one usable mamba state snapshot per
# turn (~22% of turns land it inside the EAGLE 448-token margin). Three
# behaviors plant those snapshots at the head of the free queue, so the
# FIRST inter-turn traffic evicts them: the conversation drops to 0% prefix
# hits at turns 4-5, rewarms to ~5%, and stays there. The patch keeps a small
# bounded set of the most recent state blocks per running request per mamba
# group in the cache until request end, and frees them last.
#
# The retention is OPT-IN: it does nothing unless
# VLLM_MAMBA_ALIGN_KEEP_CHECKPOINTS=1 is set in the container env. Upstream
# ships it default-off because the winning regime is narrow (context
# comparable to the pool, light background traffic, many turns); their
# no-harm A/B: p50 TTFT +0.07 ms, p99 +32 ms, C4 aggregate tok/s unchanged.
#
# Idempotent: an image that already carries the fix is a no-op.
#
# Upstream: github.com/syv-ai/qwen38-27b-rtx3090 (Apache-2.0); the patch
# file in this dir is vendored verbatim (see README.md).

set -u
DIR=/etc/vllm-patches/syv-mamba-ckpts
VLLM=/usr/local/lib/python3.12/dist-packages/vllm
TARGET=$VLLM/v1/core/single_type_kv_cache_manager.py

if grep -q "_KEEP_ALIGN_CHECKPOINTS" "$TARGET" 2>/dev/null; then
    echo "[syv-mamba-ckpts] already applied (image carries the fix) — skipping" >&2
    exit 0
fi

if ( cd "$VLLM" && patch -p1 --forward --batch \
        < "$DIR/mamba-align-checkpoint-order.patch" \
        > /tmp/syv-mamba-ckpts.patch.log 2>&1 ); then
    if ! grep -q "_KEEP_ALIGN_CHECKPOINTS" "$TARGET"; then
        echo "[syv-mamba-ckpts] patch reported success but the marker is missing — refusing boot:" >&2
        tail -20 /tmp/syv-mamba-ckpts.patch.log >&2
        exit 1
    fi
    python3 -m py_compile "$TARGET" \
        || { echo "[syv-mamba-ckpts] py_compile failed — refusing boot" >&2; exit 1; }
    echo "[syv-mamba-ckpts] applied: align-mode state snapshots now survive inter-turn eviction (retention is opt-in: VLLM_MAMBA_ALIGN_KEEP_CHECKPOINTS=1)" >&2
else
    echo "[syv-mamba-ckpts] FAILED to apply mamba-align-checkpoint-order.patch — refusing boot:" >&2
    tail -20 /tmp/syv-mamba-ckpts.patch.log >&2
    exit 1
fi
