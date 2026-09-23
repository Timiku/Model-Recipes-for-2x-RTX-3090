# vllm-mtp-draft-vocab

**What it enables:** checkpoints with a vocab-truncated MTP drafter head, built by [HyperQwen](https://github.com/syv-ai/HyperQwen)'s `prepare/build_draft_vocab.py`. The drafter scores a reduced head (`mtp.draft_lm_head.*` — 25,879 rows for Swift, vs the full 248,320-row `lm_head`) plus an id map (`mtp_draft_vocab_ids.pt`); the patch creates that head when the ids file is present, scores the drafter over the reduced vocab, and scatters the logits back into a full-vocab `-inf` frame at the mapped ids.

**Why it is exact:** rejection sampling always scores the target model's full head; the drafter only proposes. A reduced draft vocab changes the acceptance rate, never the output distribution.

**Measured (upstream, RTX 3090, syv stack):** Swift's tighter draft vocab gives acceptance 0.660 / 2.98 tok/step vs 0.630 / 2.90 for the base-Qwen 40,960-row list, held-out coverage 99.81% vs 96.69%.

**Dormant by default:** the base qwen3.8-27b checkpoints ship no `mtp_draft_vocab_ids.pt`, so the base tiers boot byte-identical with this bundle mounted. Kill switch: `MTP_DRAFT_VOCAB=0` (falls back to the full lm_head; the draft tensors are then skipped at load).

**Provenance:** upstream patch `syv-ai/HyperQwen/patches/qwen3_5-mtp-draft-vocab.patch`, exported from `cpuchip/vllm` at `4ee0f709b` (qwen3_5-mtp-draft-vocab), validated against vLLM 0.28.0. **Re-anchored here for the 0.29.0 image** — same four semantic edits (head creation in `Qwen3_5MultiTokenPredictor.__init__`, the outer draft logits processor, the compute-logits scatter, the load-weights skip) at the 0.29.0 line positions; stock-file absence of `draft_lm_head` verified as the idempotency sentinel.

**Applies to:** the mtp tier (the Swift probe rides `swift-mtp.env`). Files: `mtp-draft-vocab.patch`, `install.sh`.
