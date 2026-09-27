#!/usr/bin/env bash
# DFlash2 W4A16 drafter KV-dequant installer — runs in the container entrypoint
# before serve. 0.29.0 ships the DFlash2 drafter itself (the PR #52816 model +
# V2 speculator are stock in the image), so this no longer vendors the drafter.
# It adds the one 3090-specific piece 0.29.0 lacks: dequantizing a
# compressed-tensors W4A16 drafter qkv_proj to a dense bf16 matrix for the
# context-KV precompute (_dense_kv_rows in qwen3_dflash.py). That is what lets
# the drafter be W4A16 (~1.2 GB) beside the W4A8 27B and still precompute KV.
# Idempotent; refuses boot (exit 1) on apply failure so a re-pinned image cannot
# silently serve an un-quantized-drafter config. Re-anchored to v0.29.0.
set -u
DIR=/etc/vllm-patches/dflash2
VLLM=/usr/local/lib/python3.12/dist-packages/vllm
if python3 "$DIR/_check_applied.py" "$DIR/dflash2-backport.patch" "$VLLM" 2>/dev/null; then
  echo "[dflash2] W4A16 drafter KV-dequant already present — skipping" >&2; exit 0
fi
if ( cd "$VLLM" && patch -p1 --forward --batch < "$DIR/dflash2-backport.patch" >/tmp/dflash2.patch.log 2>&1 ); then
  echo "[dflash2] applied DFlash2 W4A16 drafter KV-dequant (0.29.0 slice)" >&2
else
  echo "[dflash2] FAILED to apply dflash2-backport.patch — refusing boot:" >&2
  tail -20 /tmp/dflash2.patch.log >&2; exit 1
fi
