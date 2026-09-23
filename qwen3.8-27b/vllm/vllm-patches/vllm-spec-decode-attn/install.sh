#!/usr/bin/env bash
# vllm-spec-decode-attn installer — runs in the container entrypoint before
# `vllm serve`.
#
# Stages the dense dispatch and patches flashinfer.py so the spec-decode
# (draft) paged prefill runs on a vllm-side dense attention -- torch
# fp8->bf16 dequant of the touched KV, then a plain dense causal GQA
# attention, no paged block-index -- instead of the FlashInfer paged
# wrapper (the sm_86 int32 block-id*stride overflow site).
#
# - Idempotent: marker-gated; safe to run every boot.
# - No-op-ish when the flag is off: with VLLM_SPEC_DECODE_ATTN unset the
#   dispatch returns immediately and the stock FlashInfer path is byte-identical.
# - Hard-fails (exit 2) on anchor drift so the compose refuses to boot a
#   half-patched flashinfer.py.
set -u
python3 /etc/vllm-patches/spec-decode-attn/patch_flashinfer_spec_attn.py
