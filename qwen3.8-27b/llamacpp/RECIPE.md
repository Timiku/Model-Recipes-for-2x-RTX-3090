# qwen3.8-27b — llama.cpp (the light shape)

The dependency-free tier: stock, unmodified llama.cpp running natively on Windows — no WSL, no Docker. The recipe is how you point it at the model, not a stack. Measured rank: **#3 of the 4-way** (narrative 54.8 / code 70.9); its edge is zero WSL/docker dependency.

## Specs

- **Model:** Qwen3.8-27B — the **Unsloth UD Q4_K_M** GGUF (the dynamic quant the bench used; Q6_K_M and Q4_K_XL sit beside it in the same Hugging Face release)
- **Hardware:** 2× RTX 3090 Ti (24 GB each), 128 GB DDR4 — **both cards on the model** (TP=2), single slot
- **Backend:** stock llama.cpp, the official prebuilt **Windows CUDA** runtime (build b10451, CUDA 13.3), run as raw `llama-server`
- **Context:** the full 262144 window per slot (64K max-tokens reservation)

## The args (the measured run)

| knob | value |
|---|---|
| `--model` | the Q4_K_M GGUF above |
| `--port` | 5002 (any free port) |
| slot `n_ctx` | 262144 (64K max-tokens reservation) |
| GPUs | both 3090 Ti (TP=2) |
| `--template` | **froggeric's fixed Qwen chat templates** — [froggeric/Qwen-Fixed-Chat-Templates](https://huggingface.co/froggeric/Qwen-Fixed-Chat-Templates): the measured run pinned **v22.4** (the exact file, [archive/v22.4_chat_template.jinja](https://huggingface.co/froggeric/Qwen-Fixed-Chat-Templates/blob/main/archive/v22.4_chat_template.jinja); the repo root is the current release, v22.5). The repo's llama.cpp form: `--jinja --chat-template-file chat_template.jinja --reasoning-format deepseek` (the last flag moves `think` blocks into the `reasoning_content` field). The GGUF's own embedded template is the stock alternative (the vLLM side repoints the same way via `CHAT_TEMPLATE`) |
| sampler (the thinking row) | temp 1.0 / top_p 0.95 / top_k 20 / min_p 0.0 / pp 0.0 |
| speculative | configured but `types=none` (off for the bench) |

## Measured (2×3090 Ti)

- RAW (no-think), n=8: narrative **54.8** tok/s (50.4–57.8) · code **70.9** (62.0–86.8)
- CHAT (thinking stream, all tokens counted): narr ~78.6, code 258–641 (thinking-inflated — not comparable to the raw rows)
- 30K-token needle (code buried at ~25K depth): **PASS**; prefill ~770 tok/s on the 50.6K-token prompt

## Notes

- 4-way rank: #3 — behind MTP 28.0 and DFlash2 27.1; ahead of DFlash2
  28.0 on code.
- Different rounding than the vLLM side's AutoRound INT4 — no measurable recall regression at 25K depth (the needle above).
- **Capacity arithmetic, not a quant defect:** a one-shot prompt that exceeds the slot's free space (a 159K conversation still held + a 50.6K prompt + the 64K reservation > the 262K slot) gets truncated to the question.
- **Update flow:** one llama.cpp for all — a "new version" means a new prebuilt runtime; at that point re-run this card's launch + bench + needle and rewrite the Measured section. Nothing to diff, nothing to patch.
