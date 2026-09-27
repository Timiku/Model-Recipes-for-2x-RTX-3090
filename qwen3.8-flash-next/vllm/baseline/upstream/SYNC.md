# SYNC — the upstream diff anchor

The source is the community stack
[dominikbucko/qwen38-flash-next-2x3090](https://github.com/DominikBucko/qwen38-flash-next-2x3090),
pinned here by tree, not by branch:

- **tree pin:** `2adf47b` (re-pinned 2026-09-21 for the docs/bench
  refresh: #15 the dual-5090 report, #16 the faster full-context
  prefill + agent-cache results, #17 the headline re-lead — receipts
  copied to `newbench/`. **No runtime files changed
  `3fa7780..2adf47b`**, verified against the upstream diff before the
  re-pin; the prior re-pin `3fa7780` (2026-09-17) carried the
  long-context prefill wedge: #10 the PLE-capture hook, #11 the bound
  QSA prefill
  workspace — the 64 MiB score-chunk cap in `ops/qsa.py` this box needs,
  #13 the hot84 default, #14 the ENABLE_VISION opt-in gate; the previous
  pin `ceaa9fa` (2026-09-05) brought the `DISABLE_CUSTOM_ALL_REDUCE`
  0/1 case + `expandable_segments` parser, the pass-throughs, the
  existence checks, the P2P check; before that `44e6805`, the
  OOM-guidance commit.)
- **image pin:** `vllm/vllm-openai:qwen38-flash-next@sha256:fc120ece0a388cc0aa1caad4a9f1cd92113484ab7ec2fd0efadd62585be05bf8`
  (the `qwen38-flash-next` list digest, pushed 2026-08-26 — the pin
  **predates the 09-02 mainline merges** #54517 fused + #54722 FP8-scale;
  a rebase of the pin is a watch item, not a silent change. 2026-09-21:
  the tag still stands at this digest (Docker Hub re-checked).)
- **checkpoint pin:** `albucino/Qwen3.8-Flash-Next-W4A16-FP8PLE` @
  `ef554143369a706525336f6b42a09094835dc077` ("later documentation-only
  commits do not change model tensors")
- **the WSL clone of that tree:** `~/qwen38-flash-next-2x3090-repo`
  (the preflight's `make validate` / digest-assert worktree; the source of
  every verbatim copy below)

## The snapshots (verbatim at the pin)

`upstream/` holds the file the yml's header takes its delta list from:

| file | sha256 |
|---|---|
| `docker_serve.sh` | `d9b39dce0aa31567b99096e6df536c79fdf74d2aa67cc05cc35474d2480c7ea8` |
| `2x3090-128gb.env` | `e49042e664d1740e2ed0305c744c7d5cb53993bfba30c156b9d409b38143288a` (hot 88→84 + the ENABLE_VISION/VISION_MAX_* block) |
| `repro.lock.json` | `f39ca15f3d853c10fd50d622545c0905a8c77ab18332f3acf53f9dd73a5d73e5` (unchanged) |
| `serve-container.sh` | `1a6982463356caf5d3267198fae94eb162e28c4e9ccac3da50be9a4a51b05a9a` (gained the ENABLE_VISION case block) |
| `Dockerfile` | `486182d5e9b495c74aa9409296316074e441e569eb8ac27933827ad8a6276f05` |
| `compose.yaml` | `a0e0292e95a0eca68e2dfc50255bbc6e0632b270ebb2b4dc8165b70c839ab5bc` (hot 88→84 + the vision passthroughs) |
| `check_custom_all_reduce.py` | `527c4cbf96f78f5d97ae98619cf2e2c2bf0463de24ecd7e5dfd06c97cccb104c` |
| `test_qsa_exact_topk_cpu.py` | `03add2018e5a88d7c555d301b796521b1983f6ee381c8ea910b81a00926c1009` |

Plus the wrapper and the rankings in the recipe folder itself (the
Dockerfile consumes them from there). The recipe's `serve-container.sh`
is the tree-pin bytes plus the three local deltas below — the 09-17 re-pin
retired the box-side wrapper shape (the upstream guard + the case blocks
now ride verbatim) and the "drop `--language-model-only`" edit (#14 made
the upstream wrapper gate the tower itself; the machine delta sets
`ENABLE_VISION=1`):

1. the 09-06 conditional-spec delta (the K=0 arm): the
   `--speculative-config` flag is built into a `spec_args` array and
   is present only when `MTP_DEPTH` is a positive integer; the
   drafter-index preflight is wrapped in the same condition. The pin
   rejects `num_speculative_tokens=0` (probed in-image 09-06:
   pydantic greater-than-0), so the off-state is a shape - the
   arm boots with the flag entirely absent (the machine delta carries
   MTP_DEPTH=0). **Inert until the next image rebuild bakes this
   file** (the preflight's freshness gate surfaces that: a boot before
   the rebuild dies in the spec-config parse).
2. (removed 2026-09-22 — was the 09-05 KV_CACHE_DTYPE env pass-through;
   the flag is upstream's hardcoded `auto` again.)
3. the 09-18 default-sampler block (LOCAL DELTA #3, after spec_args):
   `SAMPLER` (card|think|instruct) + the five per-value knobs build an
   `--override-generation-config` flag; the `card` row with blank knobs
   emits NO flag (upstream's exact behavior — the block is inert at the
   seed). Rows from the Qwen3.8 family card; `presence_penalty` is
   dropped by this build's whitelist (upstream #50767) and the wrapper
   warns when a row carries a nonzero pp. Baked 09-18; re-baked 09-22
  (delta #2 removed — sha below).

| file | sha256 |
|---|---|
| `serve-container.sh` (local deltas above) | `8f8643a99aae33611ea8ca5e96ff58b65e89ffe702cf6ff4da9bde2cf05f45e9` (re-baked 09-22: delta #2 removed) |
| `static_hot_cache_rankings.json` | `1230c61ac2b725b1c3ecd0888d08b12743c5484639fc010fa5643fc4945cd8dc` |
## The derived assets (house shape, made from the pinned files)

- **`../../Dockerfile`** (model-level, beside the recipe folders) — the
  source's Dockerfile with its COPY paths re-pointed to the
  model-recipes build context (the overlay + installer from `../patches/`,
  the wrappers + the rankings + the profile env from the recipe folder).
  The single local delta of the whole serve layer; the file's own header
  lists it. Build: `docker build -t qwen38-flash-next-2x3090:locked
  -f <vllm>/Dockerfile <vllm>` (the preflight does it, from the mirror).
- **`serve-container-vision.sh`** — retired at the 09-16 merge; the tower
  is the upstream `ENABLE_VISION` gate's business now (delta note above);
- **`../patches/`** (model-level) — the pin's `runtime/vllm-overlay` tree +
  `install_overlay.py`, copied verbatim; sha-verified against the overlay's
  own `SHA256SUMS.json` — **30/30 as of the 09-17 re-pin** (29 upstream
  files at `3fa7780` — #10's new `v1/worker/gpu/cudagraph_utils.py` +
  `model_runner.py`, `ops/qsa.py` re-sha'd by #11 — plus the local
  `v1/attention/backends/short_conv_attn.py`; the 54070 worker hunk
  re-sha's the `worker.py` row). The same check runs at Dockerfile build
  time.
- **`arm-probe.py`** (recipe folder) — local, not source-derived: the
  WSL2 device re-arm probe the start bat runs before the boot (baked
  into the image at `/usr/local/bin/arm-probe.py`; the race it guards
  against is in the wiki's recipe page (the boot-shape section).

## The update flow (the house rule)

1. Re-fetch the anchored files at the new tree sha: `docker_serve.sh`,
   `serve-container.sh`, the rankings, `Dockerfile` — and the
   `runtime/vllm-overlay` tree (by its `SHA256SUMS.json` manifest, not by
   per-file sha).
2. Diff each against the snapshots above (instant, local).
3. Read the delta against `serve.yml`'s provenance delta list: which lines
   are ours (keep), which are the source's (candidates).
4. Apply what this rig needs; extend the header delta list.
5. Re-pin this file (tree sha, image digest, the shas), note it in
   `handoff.md`, and re-run the preflight (digest assert + the local build
   re-run + the overlay manifest check).

The preflight's `make validate` + digest assert (`preflight-post.sh`) is
the executable half of this rule: a source-side move that breaks the
overlay or moves the image shows there before any boot.
