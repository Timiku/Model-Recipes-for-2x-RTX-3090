#!/bin/bash
# mtp-draft-vocab patch installer (vllm-mtp-draft-vocab). The mtp tier's
# entrypoint calls this before vllm serve; it refuses boot on any failure.
#
# What it enables: checkpoints built by HyperQwen's prepare/build_draft_vocab.py
# (e.g. liamwh/Swift-Qwen3.8-27B-W4A16-syv-fast) ship a vocab-truncated MTP
# drafter head: mtp.draft_lm_head.* tensors (25,879 rows for Swift, vs the full
# 248,320-row lm_head) plus an id map (mtp_draft_vocab_ids.pt). Stock vLLM has
# no consumer for them. The patch teaches the Qwen3.5/3.8 MTP model to create
# that head when the ids file is present, score the drafter over the reduced
# vocab, and scatter the logits back into a full-vocab -inf frame at the mapped
# ids. Speculative decoding stays exact (rejection sampling is the target
# model's); only the acceptance rate changes. Upstream measured Swift's
# tighter draft vocab at acceptance 0.660 vs 0.630 for the base-Qwen 40k list.
#
# Dormant on checkpoints without mtp_draft_vocab_ids.pt: the base qwen3.8-27b
# tiers boot byte-identical with this bundle mounted (the head is not created,
# the draft tensors are skipped in load_weights). Kill switch: MTP_DRAFT_VOCAB=0.
#
# Provenance: syv-ai/HyperQwen patches/qwen3_5-mtp-draft-vocab.patch (exported
# from cpuchip/vllm 4ee0f709b; validated against vLLM 0.28.0 upstream).
# Re-anchored for the 0.29.0 image here (--fuzz=3 is belt-and-suspenders for
# line drift; a failed anchor is a loud boot refusal, never a silent miss).
#
# Idempotent: the stock 0.29.0 qwen3_5_mtp.py contains no "draft_lm_head".

set -u
DIR=/etc/vllm-patches/mtp-draft-vocab
VLLM=/usr/local/lib/python3.12/dist-packages/vllm
MTP=$VLLM/model_executor/models/qwen3_5_mtp.py

# Idempotency: the sentinel cannot appear in the stock file (grep-verified).
if grep -q "draft_lm_head" "$MTP" 2>/dev/null; then
    echo "[mtp-draft-vocab] already applied - skipping" >&2
    exit 0
fi

if ( cd "$VLLM" && patch -p1 --forward --batch --fuzz=3 \
        < "$DIR/mtp-draft-vocab.patch" \
        > /tmp/mtp-draft-vocab.patch.log 2>&1 ); then
    # Both markers must now be present, or the file the patch "applied" to is
    # not the one the engine will run -> refuse boot.
    if ! grep -q "draft_logits_processor" "$MTP" || ! grep -q "index_copy_" "$MTP"; then
        echo "[mtp-draft-vocab] patch reported success but a marker is missing - refusing boot:" >&2
        tail -25 /tmp/mtp-draft-vocab.patch.log >&2
        exit 1
    fi
    python3 -m py_compile "$MTP" \
        || { echo "[mtp-draft-vocab] py_compile failed - refusing boot" >&2; exit 1; }
    echo "[mtp-draft-vocab] applied: the MTP drafter scores the checkpoint's truncated draft head when mtp_draft_vocab_ids.pt ships in the model dir (MTP_DRAFT_VOCAB=0 = full lm_head fallback)" >&2
else
    echo "[mtp-draft-vocab] FAILED to apply mtp-draft-vocab.patch - refusing boot:" >&2
    tail -25 /tmp/mtp-draft-vocab.patch.log >&2
    exit 1
fi
