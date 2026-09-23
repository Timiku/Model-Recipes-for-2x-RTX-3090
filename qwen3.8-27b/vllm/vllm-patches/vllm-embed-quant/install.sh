#!/bin/bash
# embed-quant patch installer (vllm-embed-quant). The mtp tier's entrypoint
# calls this before vllm serve; it refuses boot on any failure.
#
# What it enables: Swift-class checkpoints (HyperQwen requant pipeline) ship
# int8 pack-quantized embeddings (embed_tokens.weight_packed/scale/shape —
# e.g. liamwh/Swift-Qwen3.8-27B-W4A16-syv-fast: "Embeddings: int8 g128").
# Stock vLLM's VocabParallelEmbedding accepts only a plain weight, so load
# dies with "There is no module or parameter named 'embed_tokens.weight_packed'".
# The quantized-embedding kernel (CompressedTensorsEmbeddingWNA16Int) exists
# upstream — the qwen3_5 model code just never passes quant_config. This patch
# wires it at both construction sites (main model + MTP draft module).
#
# Pairs with vllm-mtp-draft-vocab for the Swift-class checkpoints. Apply order
# in the entrypoint: mtp-draft-vocab FIRST (it inserts below the MTP embed
# block), then embed-quant (it edits inside the block) — both hunks then match
# exactly.
#
# Provenance: syv-ai/HyperQwen patches/qwen3_5-embed-quant.patch (exported
# from cpuchip/vllm 4ef3da407; validated against vLLM 0.28.0 upstream).
# Re-anchored here for the 0.29.0 image.
#
# Idempotent: the stock 0.29.0 files carry no "embed_tokens" prefix kwarg on
# their VocabParallelEmbedding calls.

set -u
DIR=/etc/vllm-patches/embed-quant
VLLM=/usr/local/lib/python3.12/dist-packages/vllm
MAIN=$VLLM/model_executor/models/qwen3_5.py
MTP=$VLLM/model_executor/models/qwen3_5_mtp.py

# Idempotency: the sentinel cannot appear in the stock files (grep-verified).
if grep -q 'prefix=maybe_prefix(prefix, "embed_tokens")' "$MAIN" 2>/dev/null \
   && grep -q 'prefix=maybe_prefix(prefix, "embed_tokens")' "$MTP" 2>/dev/null; then
    echo "[embed-quant] already applied - skipping" >&2
    exit 0
fi

if ( cd "$VLLM" && patch -p1 --forward --batch --fuzz=3 \
        < "$DIR/embed-quant.patch" \
        > /tmp/embed-quant.patch.log 2>&1 ); then
    if ! grep -q 'quant_config=self.quant_config' "$MAIN" \
       || ! grep -q 'quant_config=vllm_config.quant_config' "$MTP"; then
        echo "[embed-quant] patch reported success but a marker is missing - refusing boot:" >&2
        tail -25 /tmp/embed-quant.patch.log >&2
        exit 1
    fi
    python3 -m py_compile "$MAIN" "$MTP" \
        || { echo "[embed-quant] py_compile failed - refusing boot" >&2; exit 1; }
    echo "[embed-quant] applied: quantized int8 embeddings (Swift-class checkpoints) now load through CompressedTensorsEmbeddingWNA16Int" >&2
else
    echo "[embed-quant] FAILED to apply embed-quant.patch - refusing boot:" >&2
    tail -25 /tmp/embed-quant.patch.log >&2
    exit 1
fi
