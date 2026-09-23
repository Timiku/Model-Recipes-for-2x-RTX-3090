# vllm-mamba-align-seed

**Provenance:** authored against `vllm/vllm-openai:v0.28.0` (this repo's mtp
+ nomtp pin), 2026-09-11, so it is mounted on **all three** 27b tiers. **Not** vendored from syv-ai — this is our own patch for [vllm#53142](https://github.com/vllm-project/vllm/issues/53142), which is an *issue with no upstream PR*, so vendoring into the image is the only path.

## What it fixes (vllm#53142)

In mamba **align** prefix-cache mode, `MambaHybridModelState.add_request` seeded the request's running mamba state index with `(num_computed_tokens - 1) // cache_config.block_size` — the **KV** cache block size. But that index is a **mamba** block index: the align pre-copy (`preprocess_state → run_fused_precopy`, driven by `MAMBA_BLOCK_SIZE = mamba_spec.block_size`) reads the *mamba* block table at that row. On the **first scheduling step of a request that resumes over a prefix-cache hit** (`num_computed_tokens > 0`), the wrong divisor seeds a row far outside the mamba block table, so the fused pre-copy dereferences a garbage block id → **CUDA illegal memory access** that kills the engine on the **2nd large prefill** (the 1st request is immune: `num_computed == 0` seeds −1). On this rig: KV block 128 vs mamba block 2176, so a 100096-token resume seeded row **781** instead of **45**.

## The fix

Divide by the mamba group's block size instead. The spec only lives on a `MambaSpec` inside `kv_cache_config.kv_cache_groups[*]` — there is no `vllm_config` field or model-state slot carrying it — and the runner's `add_request` runs **before** the first `preprocess_state` (where `_mamba_spec` is resolved). So the naive "use `self._mamba_spec.block_size`" fix is wrong on the very first resumed request (the spec is still `None`). The patch threads `kv_cache_config` in:

- `v1/worker/gpu/model_states/mamba_hybrid.py` — `add_request` takes an optional `kv_cache_config` and, in align mode, resolves `mamba_spec = _get_mamba_group_info(kv_cache_config)` and seeds `(num_computed_tokens - 1) // mamba_spec.block_size`. The old `cache_config.block_size` survives only as the `kv_cache_config is None` fallback (a state that cannot occur through the runner, so the hot path is always the mamba size).
- `v1/worker/gpu/model_runner.py` — the single `model_state.add_request(...)` call site passes `self.kv_cache_config`, but only for `MambaHybridModelState` (an `isinstance` branch), so the shared base `ModelState.add_request` signature is untouched and non-mamba tiers are unaffected.

## Why this tier hits it (box confirm pending)

The 09-09 `.57` crash was a GDN-IMA on the **2nd large prefill** (210K/262K die; 150K survives), eager- and compile-independent, with no Xid/OOM/paravisor in dmesg. This patch is the leading hypothesis for that exact fault (a resumed request mis-seeding the mamba align index). **Not yet confirmed on the box** — a held boot + 210K bench on `.57` will pull the deepest worker fault frame and confirm `cache_config.block_size != mamba_spec.block_size` here. Until that runs, treat this as the fix to apply, not a proven one.

## Delivery (house shape)

`install.sh` — the tier yml's entrypoint calls `bash /etc/vllm-patches/mamba-align-seed/install.sh || exit 1`, boot-refusing:

1. **marker grep** on both target files — an image that already carries the fix
   ⇒ no-op;
2. `patch -p1 --forward --batch` on the file;
3. **post-marker grep (both files) + `python3 -m py_compile` (both)** — any failure refuses boot, patch-log tail on stderr. A re-pinned image can never serve unpatched silently.

## Drop trigger

When an image re-pin moves `mamba_hybrid.py::add_request` or `model_runner.py::add_requests` off these anchors, `install.sh` refuses boot with the patch log on stderr — that is the gate. Rebase the two hunks against the new pin's files (and re-run `patch --dry-run` against it), or drop the bundle and its mounts (a boot that refuses is visible in the log; nothing fails silently).
