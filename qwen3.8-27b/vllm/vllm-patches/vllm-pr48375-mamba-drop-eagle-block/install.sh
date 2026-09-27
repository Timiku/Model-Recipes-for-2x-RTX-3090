#!/bin/bash
# 48375 mamba drop-eagle-block installer (vllm#48375). The tier's entrypoint
# calls this before vllm serve; it refuses boot on any failure.
#
# What it fixes (upstream vllm#48375; the pair with #53142 fixes the
# precopy_mamba_align_fused_kernel IMA on a shared-prefix resume, #54173):
# MambaManager.find_longest_cache_hit took drop_eagle_block in its signature
# but never read it, so a MTP/EAGLE prefix-cache resume returned the final
# matched block whose mamba recurrent-state snapshot was taken over draft
# tokens verification may reject. The patch lowers the search ceiling by one
# mamba block when drop_eagle_block is set (the max_length form, which also
# bounds the fine-grained partial-unit search this tree has added).
#
# Only relevant to spec-decode (MTP/EAGLE) tiers that use mamba align prefix
# caching; a drafter-OFF tier never passes drop_eagle_block=True to the mamba
# group, so it is simply unaffected. No env gate.
#
# Idempotent: an image that already carries the fix is a no-op.
#
# Authored against v0.29.0 (the mtp rebase pin); re-anchored to this tree's
# MambaManager, which carries the fine-grained partial-unit search the naive
# "max_num_blocks -= 1" form does not bound.
set -u
DIR=/etc/vllm-patches/pr48375
VLLM=/usr/local/lib/python3.12/dist-packages/vllm
STM=$VLLM/v1/core/single_type_kv_cache_manager.py

MARKER='max_length = max(0, max_length - kv_cache_spec.block_size)'

if grep -qF "$MARKER" "$STM" 2>/dev/null; then
    echo "[pr48375] already applied (image carries the fix) — skipping" >&2
    exit 0
fi

if ( cd "$VLLM" && patch -p1 --forward --batch \
        < "$DIR/48375-mamba-drop-eagle-block.patch" \
        > /tmp/pr48375.patch.log 2>&1 ); then
    if ! grep -qF "$MARKER" "$STM"; then
        echo "[pr48375] patch reported success but the marker is missing — refusing boot:" >&2
        tail -20 /tmp/pr48375.patch.log >&2
        exit 1
    fi
    python3 -m py_compile "$STM" \
        || { echo "[pr48375] py_compile failed — refusing boot" >&2; exit 1; }
    echo "[pr48375] applied: MambaManager now drops the final matched block on a spec-decode resume (drop_eagle_block)" >&2
else
    echo "[pr48375] FAILED to apply 48375-mamba-drop-eagle-block.patch — refusing boot:" >&2
    tail -20 /tmp/pr48375.patch.log >&2
    exit 1
fi
