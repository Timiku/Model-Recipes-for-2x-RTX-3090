# vllm-50021-spec-decode-bounds

Vendors the **Site 1** half of **`vllm-project/vllm#50021`** — *"Bound accepted-token state lookups in GDN/KDA spec decode"* — the four accepted-count-derived index loads in the recurrent / sigmoid-gating / selective-SSM / causal-conv spec-decode kernels. Sibling to `vllm-mamba-copy-bounds` (Site 2, the align pre-copy); together the two carry the full #50021 runtime set.

## The bug it closes

Speculative decoding produces a per-request **accepted-token count**. Each of the four kernels below turns that count into a state index **without bounding it**, so a count that is zero, stale, or too large indexes outside its tensor; the returned garbage int is multiplied by a state stride and dereferenced:

| file | the unbounded expression |
|---|---|
| `fused_sigmoid_gating.py` (the Qwen GDN decode kernel) | `i_t = num_accepted_tokens - 1` |
| `fused_recurrent.py` (the FLA recurrent path) | `i_t = num_accepted_tokens - 1` |
| `mamba_ssm.py` (selective-SSM init lookup) | `init_token_idx` vs the *column* stride, not the *row* stride — fails closed for every count > 1 |
| `causal_conv1d.py` (conv state offset) | `conv_state_token_offset = num_accepted_tokens - 1` |

A zero count → `i_t == -1` (a read before this request's row, and before the tensor for `i_n == 0`); a stale or too-large count reads past the row. The existing `state_idx <= 0` guard only rejects non-positive values, so an out-of-range read returning a *garbage positive* int flows into the state-address math and faults the SM — a **wild write** (`Xid 31 VIRT_WRITE`) that kills the engine. This is the **MTP** crash half of #50021: it fires only when a drafter is on (the count exists), which is why this bundle is mounted on the **mtp** tier only.

**The fix** masks each load to the valid row (`other=0` / `other=-1`) and routes an out-of-range index into the kernel's existing invalid-state early-return, zeroing the output for that row so it is never consumed uninitialized. No stream-ordering change, no device sync, TPS-neutral.

## Why Site 1 and Site 2 are split across two bundles

`vllm-mamba-copy-bounds` (Site 2, the align pre-copy) is required by **both** the nomtp and mtp tiers, because the align pre-copy runs whenever `MAMBA_CACHE_MODE=align` regardless of the drafter. Site 1 is **MTP-only** (it derives from an accept count a drafter-OFF tier never produces), so it is a separate bundle mounted on the mtp tier alone. The third, distinct defect that also lands in this path — the **async-scheduling cross-stream race** on `num_accepted_tokens` — is `vllm-gdn-mtp-async-spec-order`. The three bound the **decode-side** state lookups and the async race that also lands here — a hardening, **not a cure for the separate large-prefill IMA** (the ~210K GDN + dense-GQA FlashInfer paged prefill on sm_86+fp8 KV under MTP), which is tracked upstream and has no merged sm_86 fix. None of the three is in a pinned vllm release (#50021 is **OPEN / BLOCKED** on a maintainer gate).

## Provenance

- Upstream: `vllm-project/vllm#50021`, author **amittell**, **OPEN** (merge-conflict
  + maintainer `verified`-gate pending; not in any release). This bundle imports its four Site-1 runtime hunks verbatim (the Qwen path is the `fused_sigmoid_gating.py` one, per the PR's own review: *"speculative multi-query attention calls `fused_sigmoid_gating_delta_rule_update` … not this recurrent implementation"*).
- Re-anchored to the **v0.29.0** base for the rebase (the same treatment as the Site-2 sibling; `--fuzz=3` absorbs line drift, a failed anchor is a loud boot refusal). The Kimi-K3 KDA and test-file hunks of the PR are **not** carried — they are not on the Qwen path.
- Community confirmation that the bounds are load-bearing and sufficient for the light/decode face: seanyourhighness's red/green regressions and the 900-request / ~84%-acceptance soak (see club-3090 #838 / the #50021 thread).

## Gate

`install.sh` applies the patch, then requires **all four** sentinels (`idx_in_row` ×2, `valid_initial_token`, `num_accepted > seqlen`) to be present and all four files to `py_compile`, else it refuses boot — a failed re-anchor is a loud failure, never a silently-unpatched kernel. Re-assert with the tier's usual:

```
bash install.sh            # dry: reports already-applied / applies / refuses
python3 -m py_compile <the four files>
```
