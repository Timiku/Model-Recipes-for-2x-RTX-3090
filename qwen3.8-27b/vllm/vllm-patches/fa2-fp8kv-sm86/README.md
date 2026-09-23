# fa2-fp8kv-sm86 — FlashAttention-2 with FP8 KV on Ampere

A **prebuilt** vLLM attention-backend plugin: it registers `FLASH_ATTN` through vLLM's public backend API so the full-attention layers compute in **BF16** while the KV cache stays **FP8 E4M3** — the one thing stock vLLM refuses on sm_86 (Ampere has no native FP8 arithmetic, so stock `FLASH_ATTN` defers a quantized KV dtype to an FA3/SM90+ capability check and falls through to FlashInfer). This is the sm_86 answer to the FlashInfer paged prefill that wild-writes at large context under the mtp tier.

## Provenance (do not remove)
- **club-3090 [PR #1274](https://github.com/noonghunna/club-3090/pull/1274)** —
  *feat(qwen38): use prebuilt FlashAttention FP8 KV in ultramax* (@AntonProkopyev).
- Kernels + plugin source: [`AntonProkopyev/fa2-fp8kv-sm86@0fa02cb`](https://github.com/AntonProkopyev/fa2-fp8kv-sm86/tree/0fa02cbb760fbcc4a94ba1ee376e89825f8f43f4) (upstream FA2 `28e862d` + a reviewable 4-header patch; CUTLASS `62750a2b`).
- Delivered as a **digest-pinned prebuilt image**: `ghcr.io/antonprokopyev/fa2-fp8kv-sm86@sha256:da040941fa048fd5fdfce520503341c0beda4ce41436a1c1fecaf3f8a99777c7`. No source is downloaded or compiled at boot; the installer only verifies + installs.

## The contract `install_artifact.py` enforces (fail-closed, at boot)
Before it will install the plugin wheel it requires, in order:
1. `--tp` selected GPUs exist, and **all are the same architecture**;
2. the arch is SM **8.6 / 8.9 / 12.0** (SM90/SM100 short-circuit to native FlashAttention, no plugin);
3. `FA2_ARTIFACT_ID` (env) is a 64-hex id, **== the manifest's `artifact_id` == the sha256 of the canonical manifest JSON**, and `schema == 1`;
4. the **runtime ABI equals the manifest's** `abi` (torch, cuda, python SOABI, machine, system, C++11 ABI);
5. the arch is in the manifest's `compiled_sm`;
6. **every** payload file's sha256 matches `manifest.files` and stays inside its dir;
7. vLLM's `FlashAttentionMetadata` exposes the 7 required fields and `KVCacheLayout.LBNHC.layer_view_order == (0,2,1,3)`. Only then does it `pip install --no-index --no-deps` the single wheel and write `/etc/club3090/fa2-runtime.env` (the two `FA2_FP8KV*_LIBRARY` paths the plugin dlopens).

The pinned payload's `abi` is **torch 2.13.0+cu130 / CUDA 13.0 / CPython-3.12 / x86_64 / C++11-true** — an exact match for `vllm/vllm-openai:v0.29.0`. `compiled_sm` is `[8.6, 8.9, 12.0]`; **SM86 is the only one with GPU validation** (8.9/12.0 are compile-only targets).

## Head geometry — what the compiled kernels cover
The FA2 kernels ship for `(head_dim, local_kv_heads)` = **(256,1) / (256,2) / (128,4)** and reject DCP, attention sinks and other geometries. This model's 16 full-attention layers are `head_dim 256`, `num_attention_heads 24`, **`num_key_value_heads 4`** → at TP=2 that is **`(256, 2)` — in range**. (The 48 GDN/linear-attention layers are a separate kernel family the plugin does not touch.)

## Scope and limits
- **Full-attention only.** GDN (DeltaNet/SSM) layers, the conv/ssm state, and vision are unchanged. So whether this retires the mtp near-full IMA depends on that fault being in the full-attention FlashInfer paged prefill (it is not cured if the fault is in the GDN paged path) — the boot + near-full bench is the test.
- KV stays `fp8_e4m3`; compute is BF16. Native FA2 prefill unpacks one bounded KV block at a time and merges partials in FP32; on a workspace-alloc failure it falls back to paged FA2 for the same request.
- TP=2, homogeneous arch required; tested at one sequence. It is a decode-speed + full-attention-path change, not a capacity change (capacity still comes from the KV pool).

## Mounts (the yml side)
| host path (this bundle, on the box) | container path | mode |
|---|---|---|
| `vllm-patches/fa2-fp8kv-sm86/` | `/etc/club3090/fa2` | `:ro` |
| `vllm-patches/fa2-fp8kv-sm86/artifacts/` | `/opt/club3090/fa2-artifacts` | `:ro` |

The entrypoint runs `bash /etc/club3090/fa2/install.sh` (then `source /etc/club3090/fa2-runtime.env`) **before** `vllm serve`, and the serve command carries `--attention-backend FLASH_ATTN`. Both paths keep the upstream `/etc/club3090` + `/opt/club3090` prefixes verbatim so the vendored files stay byte-identical to #1274.

## The payload is NOT in git
`artifacts/` is gitignored. The two `.so`, the plugin wheel, `manifest.json`, LICENSE/NOTICE and the three license files total ~8 MB and are **compiled third-party binaries** — they are staged per-machine by [`stage-artifacts.sh`](stage-artifacts.sh) (pull the pinned image, extract `/artifacts/`, verify every sha256) and mounted read-only, exactly like weights. A machine that has not staged `artifacts/<id>/` will **refuse the boot** at the gate, not silently serve a half-wired config.
