#!/bin/bash
# 50021-spec-decode-bounds patch installer (vllm#50021, Site 1). The mtp tier's
# entrypoint calls this before vllm serve; it refuses boot on any failure.
#
# What it fixes: speculative decoding yields a per-request accepted-token count,
# and each of the four kernels here turns that count into a state index WITHOUT
# bounding it. A zero count gives an index of -1 (a read before the request's
# row, and before the tensor for row 0); a stale or too-large count reads past
# the row. The loaded int is then multiplied by a state stride and dereferenced,
# faulting the SM (cudaErrorIllegalAddress / Xid 31 VIRT_WRITE) and killing the
# engine:
#   - fused_sigmoid_gating.py   the Qwen GDN decode kernel (i_t = n_accepted - 1)
#   - fused_recurrent.py        the FLA recurrent path (same shape)
#   - mamba_ssm.py              the selective-SSM init-lookup (bound was the
#                               column stride, not the row stride -> failed closed
#                               for every accepted count > 1)
#   - causal_conv1d.py          the conv state offset (unbounded n_accepted - 1)
# Each load is masked to the valid row (other=0 / other=-1) and an out-of-range
# index routes into the existing invalid-state early-return, zeroing the kernel's
# output for that row so it is never consumed uninitialized. No stream-ordering
# change, no device sync, TPS-neutral.
#
# This is the MTP-only half of #50021: every index derives from an accept count,
# which a drafter-OFF (nomtp) tier never produces, so this bundle is mounted on
# the mtp tier only. Sibling vllm-mamba-copy-bounds is the Site 2 half (the align
# pre-copy, both tiers); the async cross-stream race that ALSO lands here is
# vllm-gdn-mtp-async-spec-order.
#
# Idempotent: an image that already carries all four sentinels is a no-op.
#
# Authored from vllm#50021's four Site-1 hunks; re-anchored for the 0.29.0
# rebase (--fuzz=3 is belt-and-suspenders for line drift; a failed anchor is a
# loud boot refusal, never a silent unpatched kernel).

set -u
DIR=/etc/vllm-patches/50021-spec-decode-bounds
VLLM=/usr/local/lib/python3.12/dist-packages/vllm
FR=$VLLM/third_party/flash_linear_attention/ops/fused_recurrent.py
FSG=$VLLM/third_party/flash_linear_attention/ops/fused_sigmoid_gating.py
MSSM=$VLLM/model_executor/layers/mamba/ops/mamba_ssm.py
CC1D=$VLLM/model_executor/layers/mamba/ops/causal_conv1d.py

# Idempotency: all four sentinels present -> the image already carries the fix.
if grep -q "idx_in_row" "$FR" 2>/dev/null \
   && grep -q "idx_in_row" "$FSG" 2>/dev/null \
   && grep -q "valid_initial_token" "$MSSM" 2>/dev/null \
   && grep -q "num_accepted > seqlen" "$CC1D" 2>/dev/null; then
    echo "[50021-spec-decode-bounds] already applied (image carries the fix) - skipping" >&2
    exit 0
fi

if ( cd "$VLLM" && patch -p1 --forward --batch --fuzz=3 \
        < "$DIR/50021-spec-decode-bounds.patch" \
        > /tmp/50021-spec-decode-bounds.patch.log 2>&1 ); then
    # Every one of the four sentinels must now be present, or the file the
    # patch "applied" to is not the one the kernel will run -> refuse boot.
    if ! grep -q "idx_in_row" "$FR" || ! grep -q "idx_in_row" "$FSG"; then
        echo "[50021-spec-decode-bounds] patch reported success but a recurrent/sigmoid-gating marker is missing - refusing boot:" >&2
        tail -25 /tmp/50021-spec-decode-bounds.patch.log >&2
        exit 1
    fi
    if ! grep -q "valid_initial_token" "$MSSM"; then
        echo "[50021-spec-decode-bounds] mamba_ssm marker missing - refusing boot:" >&2
        tail -25 /tmp/50021-spec-decode-bounds.patch.log >&2
        exit 1
    fi
    if ! grep -q "num_accepted > seqlen" "$CC1D"; then
        echo "[50021-spec-decode-bounds] causal_conv1d marker missing - refusing boot:" >&2
        tail -25 /tmp/50021-spec-decode-bounds.patch.log >&2
        exit 1
    fi
    # Syntax gate on all four touched files.
    for f in "$FR" "$FSG" "$MSSM" "$CC1D"; do
        python3 -m py_compile "$f" \
            || { echo "[50021-spec-decode-bounds] py_compile failed on $f - refusing boot" >&2; exit 1; }
    done
    echo "[50021-spec-decode-bounds] applied: accepted-count-derived state lookups in the recurrent/sigmoid-gating/SSM/conv spec-decode kernels are now row-bounded (out-of-range -> zeroed early-return, not a wild write)" >&2
else
    echo "[50021-spec-decode-bounds] FAILED to apply 50021-spec-decode-bounds.patch - refusing boot:" >&2
    tail -25 /tmp/50021-spec-decode-bounds.patch.log >&2
    exit 1
fi
