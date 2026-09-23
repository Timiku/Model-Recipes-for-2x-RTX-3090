# vllm-syv-mamba-align-ckpts

**Provenance:** vendored verbatim from [syv-ai/qwen38-27b-rtx3090](https://github.com/syv-ai/qwen38-27b-rtx3090), `patches/mamba-align-checkpoint-order.patch`. Fetched 2026-09-08. Upstream license: Apache-2.0.

```
sha256 515d9bf76e860c95d832d615bdab4a97b71e2b0412b4ccc2445f11535ddddf45
```
(re-hash the file to check for upstream drift)

The patch's own header declares it **written against vLLM 0.27.1**. The 09-08 scratch dry-apply against `vllm/vllm-openai:v0.28.0` (the mtp tier's pin) is also green (all four hunks, small negative offsets), so this bundle is mounted on both 27b tiers.

## What it fixes (their issue #52; upstream vllm#45238; gotcha 44)

In mamba **align** mode the prefix cache materializes roughly one usable mamba state snapshot per turn, and only ~22% of turns land it inside the EAGLE 448-token margin. Three composing behaviors then plant those snapshots at the **head** of the free block queue:

1. **geometry** — the snapshot a turn needs is the *previous* turn's;
2. **the CoW release pass** frees a snapshot's cached copy as soon as the copy-on-write that protected it completes;
3. **the eviction order** puts the resume-able blocks first in line.

So the first inter-turn traffic evicts the very snapshots the next turn resumes from: the conversation drops to **0% prefix hits at turns 4-5**, rewarms to ~5%, and stays there.

## The fix

Keep a small, bounded set of the most recent state blocks per running request per mamba group in the cache until request end, and free them **last**. Their verification (64k window / 65k pool — the same ~1.0× ratio as our 656,866 pool at 218,955 × 3): the no-hit rate drops from ~100% to ~13% at turn 6 and ~4% by turn 8; restored hit rate 87% at turn 6, 92% at turn 8. No-harm: p50 TTFT +0.07 ms, p99 +32 ms, C4 aggregate tok/s unchanged.

**The retention is opt-in, exactly as upstream ships it**: the new code paths activate only when `VLLM_MAMBA_ALIGN_KEEP_CHECKPOINTS=1` is set in the container env; unset (the default) is byte-for-byte the stock behavior. The winning regime is narrow (context comparable to the pool, light background traffic, many turns) — which is precisely the 09-08 3-concurrent shared-document stance, so enabling it on the box is a one-line `VLLM_MAMBA_ALIGN_KEEP_CHECKPOINTS=1` env pass-through, a user call, not a recipe change.

## Delivery (house shape)

`install.sh`, called by the tier yml's entrypoint before `vllm serve` (`bash /etc/vllm-patches/syv-mamba-ckpts/install.sh || exit 1`):

1. **marker grep** — `v1/core/single_type_kv_cache_manager.py` already carrying `_KEEP_ALIGN_CHECKPOINTS` ⇒ the image has the fix ⇒ no-op;
2. `patch -p1 --forward --batch` on the verbatim file;
3. **post-marker grep + `python3 -m py_compile`** — any failure refuses boot (exit 1), with the patch log's tail on stderr. A re-pinned image can never serve unpatched silently.

## Drop trigger

When an image re-pin moves `single_type_kv_cache_manager.py` off these anchors (the 0.27.1 → 0.28.0 drift is the first one to watch, since the patch declares 0.27.1), `install.sh` refuses boot with the patch log on stderr — that is the gate. Rebase the four hunks against the new pin's file and re-record the sha256, or drop the bundle and its mounts (a boot that refuses is visible in the log; nothing fails silently).
