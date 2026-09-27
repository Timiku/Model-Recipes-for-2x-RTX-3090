# vllm-mamba-copy-bounds

Vendors **`vllm-project/vllm#50021`** — the *mamba copy-column bounds* half (Site 2 of that PR: `_copy_mamba_state_block` in `v1/worker/mamba_utils.py`). This is the piece that protects the **align pre-copy** path (`MambaHybridModelState.preprocess_state` → `run_fused_precopy`), i.e. the path a drafter-OFF tier actually runs.

## The bug it closes

In `--mamba-cache-mode align`, a request that **resumes over a prefix-cache hit** has its mamba state pre-copied across block columns. The four block-table column loads in `_copy_mamba_state_block` were **unbounded** (stock v0.29.0):

```
dest_block_id       = tl.load(block_table_base + dst_col)
src_block_id        = tl.load(block_table_base + src_col)          # DS conv
src_block_id        = tl.load(block_table_base + src_col)           # SD conv
actual_src_block_id = tl.load(block_table_base + src_col + token_bias)
```

where `block_table_base = group_table + bt_row_idx * block_table_stride_req`. When such a resumed request is **batched with a concurrent prefill**, the shared-prefix / pre-copy bookkeeping can hand it a state column that falls *outside* its block-table row. The unbounded load then reads an arbitrary int32 from a neighbouring row, multiplies it by `state_block_stride` (the mamba page stride — which the code itself notes can exceed 2³¹ bytes), and `tl.store`s to that address: a **wild write** → `cudaErrorIllegalAddress` (Xid 31) → the engine dies.

That is precisely the **nomtp 2-concurrent deep-resume crash**: a ~200K prefix-cache resume batched with a ~100K prefill, both requests 500ing to `EngineDeadError` (reproduced deterministically on the .57 box, p113).

## The fix

`#50021` masks all four column loads to `[0, block_table_stride_req)` with `other=-1` and rejects any loaded block id `<= 0` (covering both the `-1` sentinel and `NULL_BLOCK_ID = 0`, the unallocated-slot marker). An out-of-range column thus routes into the existing no-copy early-return instead of producing an address. No stream-ordering change, no device sync, TPS-neutral.

## Provenance

- Upstream: `vllm-project/vllm#50021` — *"Bound accepted-token state lookups in GDN/KDA spec decode"*, author amittell, **OPEN** (not in any release). This bundle imports only its `mamba_utils.py` hunk (the align pre-copy half). Its companion hunk in the recurrent kernels (Site 1: the `num_accepted_tokens` index in `fused_recurrent` / `fused_sigmoid_gating`) is **MTP-only** and is *not* carried here — a drafter-OFF tier has no accept count to bound.
- Re-anchored to the **v0.29.0** base for the rebase: the hunk's context is byte-identical to `vllm/vllm-openai:v0.29.0`'s `mamba_utils.py`, so it applies clean (the installer uses `--fuzz=3` as a belt-and-suspenders for line drift).

## Why the seed fix alone was not enough

The other two mamba bundles on this tier are **necessary but distinct**:

| bundle | file | what it fixes |
|---|---|---|
| `vllm-mamba-align-seed` (#53142) | `mamba_hybrid.py` | the **seed** — `add_request` divided by the KV block size, not the mamba block size |
| `vllm-syv-mamba-align-ckpts` | `single_type_kv_cache_manager.py` | snapshot **eviction order** (periodic TTFT spikes), opt-in |
| **this bundle** (#50021 Site 2) | `mamba_utils.py` | the **copy** — unbounded block-table column loads |

The seed fix makes the running state index *sane*; it does not bound the pre-copy's column loads, which is why a bad column still reached the wild write and the tier still crashed on the 2nd large prefill. This bundle is the missing third line of defense.

## Gate

`install.sh` applies the hunk, then requires **all three** of `dst_col_ok`, `src_col_ok`, `tmp_col_ok` to be present and the file to `py_compile`, else it refuses boot — so a failed re-anchor is a loud boot failure, never a silent corruption. Re-assert with the tier's usual:

```
bash install.sh            # dry: reports already-applied / applies / refuses
python3 -m py_compile v1/worker/mamba_utils.py
```
