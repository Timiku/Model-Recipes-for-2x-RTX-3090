# vllm-pr48375-mamba-drop-eagle-block

**Provenance:** re-anchored from the upstream PR [vllm#48375](https://github.com/vllm-project/vllm/pull/48375) (`@potto007`, *"Honor drop_eagle_block in MambaManager"*) to the v0.29.0 tree, in the **`max_length` form** that `@Karl0007` reported running in production on 0.29.x-era builds (see that PR thread, 2026-09-05). Vendored into the image — #48375 is still OPEN/BLOCKED upstream, so a bundle is the only path.

**Status: re-added 2026-09-13.** This bundle was **dropped** in the 0.29.0 rebase on the premise *"0.29.0 threads `drop_eagle_block` through every KV manager incl. MambaManager, so the fix is stock."* That premise is **false**: stock v0.29.0's `MambaManager.find_longest_cache_hit` takes `drop_eagle_block` in its signature and **never reads it** (verified: the one reference is the signature; the body has no pop, no `-= 1`, no use of the flag). So 0.29.0 carries the #48375 bug live, and this bundle is required again.

## What it fixes (vllm#48375)

In mamba **align** prefix-cache mode with a spec-decode drafter (MTP/EAGLE), `MambaManager.find_longest_cache_hit` is *supposed* to drop the final matched block of a cache hit, because that block's mamba recurrent-state snapshot was captured over draft tokens that verification later rejects. Full-attention and sliding-window managers honor `drop_eagle_block`; MambaManager accepted the flag and ignored it. Retaining the block is one half of the two-part root cause of the **`precopy_mamba_align_fused_kernel` illegal memory access** on a shared-prefix resume (vllm[#54173](https://github.com/vllm-project/vllm/issues/54173)); the other half is the state-seed divisor, which our [`vllm-mamba-align-seed`](../vllm-mamba-align-seed/) (#53142) already fixes. The two are a pair: #54173's independent reproducers (GB10, sm_120) apply both together and report ~13.5 h / 0 faults where the unpatched build crashes within ~20 min.

## The fix (and why this form)

When `drop_eagle_block` is set, lower the search ceiling by one mamba block:

```python
if drop_eagle_block: max_length = max(0, max_length - kv_cache_spec.block_size)
```

This is **not** a literal `.pop()` (upstream #48375's own reasoning): the mamba hit list is null-padded with the single real state block at the *end* (`[null, null, null, REAL]`), so popping would drop the only real state and leave an all-null hit claiming a shorter span — worse than the bug. Lowering the ceiling lands on the real earlier snapshot.

The upstream PR's form is `max_num_blocks -= 1` on the coarse loop. We use the **`max_length` form** instead because this tree's `MambaManager` has added a **fine-grained partial-unit search** (`max_num_partial_units = min(max_length // hash_block_size, …)`) that the `max_num_blocks` cut does not reach — with `hash_block_size < block_size`, a hit found there would still include the final block. Clamping `max_length` is arithmetically identical for the coarse loop (`(x-b)//b == x//b - 1`) and bounds both paths. This is exactly what `@Karl0007` measured in production.

## Why this tier hits it

The mtp tier runs MTP (a spec-decode drafter) + mamba **align** prefix caching at large context — the exact configuration #48375 describes. A cache-hit resume that extends a shared prefix is the trigger (a fresh or byte-identical repeat never faults), which is why a plain short-context smoke test cannot screen it.

## Delivery (house shape)

`install.sh` — the mtp tier's entrypoint calls `bash /etc/vllm-patches/pr48375/install.sh || exit 1`, boot-refusing:

1. **marker grep** on `single_type_kv_cache_manager.py` — an image that already carries the fix ⇒ no-op;
2. `patch -p1 --forward --batch` on the file;
3. **post-marker grep + `python3 -m py_compile`** — any failure refuses boot, patch-log tail on stderr. A re-pinned image can never serve unpatched silently.

## Drop trigger

When an image re-pin moves `MambaManager.find_longest_cache_hit` off these anchors (the `MambaSpec` assert + the `dcp`/`pcp` asserts + the `resolve_block_hashes(` call), `install.sh` refuses boot with the patch log on stderr — that is the gate. If #48375 lands upstream in a way that re-anchors elsewise, re-run `patch --dry-run` against the new pin, or drop the bundle and its mounts.
