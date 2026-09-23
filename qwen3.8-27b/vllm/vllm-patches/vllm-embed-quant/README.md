# vllm-embed-quant

**What it enables:** Swift-class checkpoints with int8 pack-quantized embeddings (HyperQwen requant pipeline — `prepare/quant_embed.py`; e.g. liamwh/Swift-Qwen3.8-27B-W4A16-syv-fast ships `embed_tokens.weight_packed`). Stock vLLM's `VocabParallelEmbedding` accepts only a plain weight, so the load dies with "There is no module or parameter named 'embed_tokens.weight_packed'". The quantized-embedding kernel (`CompressedTensorsEmbeddingWNA16Int`) exists upstream — the qwen3_5 model code just never passes `quant_config` to the embedding constructor. The patch wires it at both sites: the main model (`qwen3_5.py`) and the MTP draft module (`qwen3_5_mtp.py`) — without the second, the MTP tier crashes on load (the drafter builds its own embedding).

**Pairs with `vllm-mtp-draft-vocab`** (Swift-class serving). Apply order in the entrypoint: mtp-draft-vocab first, then embed-quant — the draft bundle inserts below the MTP embed block, this bundle edits inside it, so that order matches both hunks exactly.

**Dormant on base checkpoints?** No gate needed: the base checkpoints ship plain embeddings, and the patch only adds constructor kwargs (the quantized path engages only when the checkpoint declares quantized embeddings). The base tier boots byte-identical.

**Provenance:** upstream patch `syv-ai/HyperQwen/patches/qwen3_5-embed-quant.patch`, exported from `cpuchip/vllm` at `4ef3da407` (qwen3_5-embed-quant), validated against vLLM 0.28.0. **Re-anchored here for the 0.29.0 image** (the embed constructions are verbatim identical; `self.quant_config`/`vllm_config` are in scope at both sites).

**Applies to:** the mtp tier. Files: `embed-quant.patch`, `install.sh`.
