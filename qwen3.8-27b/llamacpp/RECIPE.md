# qwen3.8-27b: llama.cpp

The no-dependency option: stock, unmodified llama.cpp running natively on Windows, with no WSL and no Docker. This card is just how to point llama.cpp at the model; there are no scripts. In the four-way comparison it ranked **#3** (narrative 54.8 / code 70.9 tok/s). Its advantage is needing nothing but llama.cpp itself.

## Setup

- **Model:** Qwen3.8-27B as the **Unsloth UD Q4_K_M** GGUF, the dynamic quant used in the benchmark. Q6_K_M and Q4_K_XL are in the same Hugging Face release.
- **Hardware:** 2× RTX 3090 Ti (24 GB each), 128 GB DDR4. **Both cards serve the model** (TP=2), one slot.
- **Backend:** stock llama.cpp, the official prebuilt **Windows CUDA** release (build b10451, CUDA 13.3), run as plain `llama-server`.
- **Context:** the full 262,144-token window per slot, with 64K reserved for output.

## Launch arguments (as benchmarked)

| setting | value |
|---|---|
| `--model` | the Q4_K_M GGUF above |
| `--port` | 5002 (any free port works) |
| slot `n_ctx` | 262144 (64K max-tokens reservation) |
| GPUs | both 3090 Ti (TP=2) |
| chat template | **froggeric's fixed Qwen chat templates**, [froggeric/Qwen-Fixed-Chat-Templates](https://huggingface.co/froggeric/Qwen-Fixed-Chat-Templates). The benchmark pinned **v22.4** ([archive/v22.4_chat_template.jinja](https://huggingface.co/froggeric/Qwen-Fixed-Chat-Templates/blob/main/archive/v22.4_chat_template.jinja)); the repo root is the current release, v22.5. Use it with `--jinja --chat-template-file chat_template.jinja --reasoning-format deepseek`; the last flag moves `think` blocks into the `reasoning_content` field. The GGUF's own embedded template is the stock alternative (the vLLM tiers switch templates the same way, via `CHAT_TEMPLATE`). |
| sampler (thinking row) | temp 1.0 / top_p 0.95 / top_k 20 / min_p 0.0 / presence penalty 0.0 |
| speculative decoding | configured but `types=none`, so off for the benchmark |

## Measured (2× 3090 Ti)

- Raw, no thinking, n=8: narrative **54.8** tok/s (range 50.4–57.8), code **70.9** (62.0–86.8).
- Chat with thinking, all tokens counted: narrative ~78.6, code 258–641. Thinking inflates these, so they aren't comparable to the raw rows.
- 30K-token needle test (code buried at ~25K depth): **pass**. Prefill ran at ~770 tok/s on the 50.6K-token prompt.

## Notes

- Ranking: #3 of four, behind MTP on vLLM 0.28 and DFlash2 on vLLM 0.27.1, ahead of DFlash2 on 0.28 for code.
- The quantization differs from the vLLM tiers' AutoRound INT4. The needle test above showed no recall loss at 25K depth.
- **A capacity limit, not a quantization bug:** a prompt that doesn't fit the slot's free space gets cut down to the question. Example: a 159K conversation still in the slot + a 50.6K prompt + the 64K reservation exceeds the 262K slot.
- **Updating:** there's one llama.cpp for everything, so a new version means a new prebuilt release. When you switch, re-run this card's launch, benchmark and needle test, and rewrite the Measured section. Nothing to diff or patch.
