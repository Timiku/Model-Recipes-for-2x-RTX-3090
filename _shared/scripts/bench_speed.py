#!/usr/bin/env python3
"""bench_speed.py - the one speed bench every model runs (model-agnostic).

The unified contract, applied identically to qwen3.8-27b, gemma4-31b and
qwen3.8-flash-next: four arms - NARR and CODE, each at NEAR-EMPTY context
(the prompt alone) and NEAR-FULL context (padded to the tier's target) -
two runs per arm, so the record shows both the rate and its ctx behavior.
Each model's bench.bat is a thin launcher (its own tier ports, its own
near-full targets); everything below is shared.

Lineage: this is the hardened qwen harness (`bench_qwen.py`, retired into
here) - streaming measurement of TTFT + decode tok/s, `stream_options:
include_usage` so the token counts come from vLLM's usage (authoritative,
never client-side guessing), reasoning+content chunk counting (the tiers
run the thinking row, so output arrives on either channel), bad-chunk
resilience (a chunk with no choice object is counted and reported, not a
crash), and the cold/repeat split in the summary (the full cells repeat an
identical prompt, so run #2 is served from the prefix cache and its TTFT
measures the cache, not the tier). From the gemma harness it takes the
FULL_OUT escape: the near-full sample length is an argument, for the tiers
where a 512-token deep-ctx sample is structurally expensive (the gemma
KVarN head-512 slow path charges ~3.3 s/token at 100k, ~28 min a sample;
32 tokens prices the same rate in ~2 min). gen=N prints on every record
line, so a shortened run is always visible.

Usage:
  bench_speed.py <port> [near-full-token-target] [full-out] [--label NAME]

  near-full default 250000 (fits every 262144 tier; gemma's bats pass
  their curated depths: 170000 / 185000 / the KVarN 100000s). full-out
  default 512 everywhere - the same test by default; the override is per
  run and audited in the record.

Sampler: the card's standardized thinking row (temp 1.0 / top_p 0.95 /
top_k 20 / min_p 0.0), exactly as the ymls' override-generation-config
carries it into every request.

Stdlib only. Read-only on the tier: never boots, parks, or kills anything.
Run inside the WSL distro (the tier's port is WSL-internal); the bat relays
stdout into the model's vllm/logs/bench/ record.

Method notes:
- the near-full pad is sized with a one-shot calibration: a filler call
  yields the realized chars/token ratio for THIS tokenizer; the pad is
  then built to hit the target, and each full run's achieved prompt_tokens
  is reported so the estimate is auditable.
- the ymls have no enable_prefix_caching, so repeated near-full runs each
  pay the full prefill; the runs are independent measurements.
"""
import argparse
import json
import math
import sys
import time
import urllib.error
import urllib.request

# --- the harness prompts, verbatim since the first bench (comparability) --
NARR = ("Write a detailed 400-word explanation of how CPU caches work, "
        "covering L1/L2/L3, write policies, and cache coherence.")
CODE = ("Write a Python implementation of an LRU cache with a capacity "
        "parameter, get/set methods, and a short test main. Keep it "
        "complete and runnable.")

# neutral filler for the near-full pad (repeated; the prefill is real
# compute either way - this is a speed bench, not a quality probe)
FILL_UNIT = ("The same quiet morning came back to the harbor again, with the "
             "nets wet and the gulls early, and the fog stayed low over the "
             "water until the last boat had come in. ")

MAX_OUT = 512
TEMP = 1.0
TOP_P = 0.95
TOP_K = 20
MIN_P = 0.0
PRESENCE = 0.0
TIMEOUT = 1800

RESULTS = []


def parse_args():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("port", type=int, help="the live tier port")
    p.add_argument("near_full", type=int, nargs="?", default=250000,
                   help="near-full prompt-token target (default 250000)")
    p.add_argument("full_out", type=int, nargs="?", default=512,
                   help="near-full sample length in tokens (default 512)")
    p.add_argument("--label", default="tier",
                   help="model name for the header and the id needle")
    return p.parse_args()


class Ctx:
    pass


def http_open(ctx, path, payload, stream=False):
    req = urllib.request.Request(
        ctx.base + path, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=TIMEOUT)


def discover_model(ctx):
    with urllib.request.urlopen(ctx.base + "/v1/models", timeout=60) as r:
        obj = json.loads(r.read())
    ids = [m.get("id") for m in obj.get("data", [])]
    pref = [i for i in ids if i and ctx.needle in i.lower()]
    return (pref or ids or ["<unknown>"])[0], ids


def warmup(ctx, m):
    with http_open(ctx, "/v1/chat/completions",
                   {"model": m, "messages": [{"role": "user", "content": "Say: warm"}],
                    "max_tokens": 16, "temperature": 0.7, "top_p": 0.8}) as r:
        json.loads(r.read())
    print("warmup done.", flush=True)


def calibrate(ctx, m):
    fill = FILL_UNIT * 40  # ~7.2K chars, a couple of K tokens
    payload = {"model": m, "prompt": fill, "max_tokens": 1, "temperature": 0.0}
    with http_open(ctx, "/v1/completions", payload) as r:
        usage = json.loads(r.read()).get("usage") or {}
    n = usage.get("prompt_tokens")
    if not n:
        raise SystemExit("calibration failed: no usage.prompt_tokens in the "
                          "response (model %r)" % m)
    ratio = n / len(fill)  # tokens per char, realized for this tokenizer
    print("calibration: %d chars -> %d prompt tokens (ratio %.5f tok/char)"
          % (len(fill), n, ratio), flush=True)
    return ratio


def pad(prompt, target_tokens, ratio):
    need = int(target_tokens / ratio)
    units = max(0, -(-need // len(FILL_UNIT)) - 1)  # leave room for the prompt
    return prompt + " " + FILL_UNIT * units


def measure(ctx, tag, m, prompt, max_out=None):
    payload = {"model": m, "messages": [{"role": "user", "content": prompt}],
               "max_tokens": max_out or MAX_OUT, "temperature": TEMP,
               "top_p": TOP_P, "top_k": TOP_K, "min_p": MIN_P,
               "presence_penalty": PRESENCE, "stream": True,
               "stream_options": {"include_usage": True}}
    r = http_open(ctx, "/v1/chat/completions", payload)
    t0 = time.time()
    t_first = t_last = None
    n_chunks = n_content = n_bad = 0
    usage = None
    err_seen = None
    try:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data:"):
                continue
            d = line[5:].strip()
            if d == "[DONE]":
                break
            obj = json.loads(d)
            if not isinstance(obj, dict):
                n_bad += 1
                continue
            if obj.get("usage"):
                usage = obj["usage"]
            if obj.get("error") is not None:
                err_seen = str(obj["error"])[:200]
            ch = obj.get("choices") or []
            if ch and isinstance(ch[0], dict):
                d0 = ch[0].get("delta") or {}
            else:
                # A stream can carry a chunk with no choice object at all --
                # an error payload, or `choices: [null]`. Count it, say so on
                # the line, and keep reading: the run is still evidence.
                d0 = {}
                n_bad += 1
            # The tiers run the thinking row, so output tokens arrive on either
            # channel. Count both. Taking the first token from `content` alone
            # reported `nan` for a run that spent the whole budget reasoning
            # (512 tokens generated, zero content chunks), and timed the decode
            # span against visible tokens only, which inflated the rate whenever
            # the model thought before answering (95 tok/s at 250k ctx).
            c = d0.get("content")
            tok = c or d0.get("reasoning_content") or d0.get("reasoning")
            if tok:
                now = time.time()
                if t_first is None:
                    t_first = now
                t_last = now
                n_chunks += 1
            if c:
                n_content += 1
    finally:
        r.close()
    n = usage.get("completion_tokens") if usage else n_chunks
    ptok = usage.get("prompt_tokens")
    ttft = (t_first - t0) if t_first else float("nan")
    span = (t_last - t_first) if (t_first and t_last) else 0.0
    dec = (n - 1) / span if span > 0 else float("nan")
    note = "" if n_content else "  [NO visible content: all output was reasoning]"
    if n_bad:
        note += "  [%d chunk(s) carried no choice object]" % n_bad
    if err_seen:
        note += "  [server error: %s]" % err_seen
    print("%s: prompt=%s  gen=%d  TTFT=%.2fs  decode=%.1f tok/s  chunks r=%d c=%d%s"
          % (tag, ptok if ptok is not None else "?", n, ttft, dec,
             n_chunks - n_content, n_content, note), flush=True)
    RESULTS.append({"run": tag, "prompt_tokens": ptok, "gen_tokens": n,
                    "ttft_s": ttft, "decode_tps": dec, "ok": True,
                    "chunks_reasoning": n_chunks - n_content,
                    "chunks_content": n_content,
                    "bad_chunks": n_bad, "server_error": err_seen})


def fail(tag, err):
    body = ""
    if isinstance(err, urllib.error.HTTPError):
        try:
            body = err.read().decode(errors="replace")[:300]
        except Exception:
            pass
        print("%s: FAILED HTTP %s: %s" % (tag, err.code, body), flush=True)
    else:
        print("%s: FAILED: %s" % (tag, err), flush=True)
    RESULTS.append({"run": tag, "prompt_tokens": None, "gen_tokens": None,
                    "ttft_s": None, "decode_tps": None, "ok": False,
                    "error": repr(err)})


def main():
    a = parse_args()
    ctx = Ctx()
    ctx.base = "http://localhost:%d" % a.port
    # the needle is the model family: the leading alpha run of the label
    # ("qwen3.8-27b" -> "qwen", "gemma4-31b" -> "gemma")
    lead = ""
    for c in a.label.lower():
        if c.isalpha():
            lead += c
        elif lead:
            break
    ctx.needle = lead or a.label.lower()

    t_start = time.strftime("%Y-%m-%d %H:%M:%S")
    m, ids = discover_model(ctx)
    print("== bench_speed: %s ==", flush=True)
    print("started: %s   port: %d   near-full target: %d   near-full sample: %d tok   model: %s (served: %s)"
          % (t_start, a.port, a.near_full, a.full_out, m, ",".join(ids)), flush=True)
    print("arms: narr/code x near-empty/near-full, 2 runs per arm; the card's"
          " thinking row; usage-reported counts", flush=True)
    warmup(ctx, m)
    ratio = calibrate(ctx, m)
    narr_full = pad(NARR, a.near_full, ratio)
    code_full = pad(CODE, a.near_full, ratio)
    print("near-full pad: %d and %d chars (%.0f and %.0f tokens estimated)"
          % (len(narr_full), len(code_full),
             len(narr_full) * ratio, len(code_full) * ratio), flush=True)
    cells = [("narr-empty", NARR), ("code-empty", CODE),
             ("narr-full", narr_full), ("code-full", code_full)]
    for i in range(1, 3):
        for name, prompt in cells:
            tag = "%s#%d" % (name, i)
            try:
                mo = None if "empty" in name else a.full_out
                measure(ctx, tag, m, prompt, max_out=mo)
            except Exception as e:
                fail(tag, e)
    # --- summary -----------------------------------------------------------
    print("\n== summary (decode tok/s and TTFT, streaming; usage-reported counts) ==",
          flush=True)
    print("| run | prompt_tokens | gen_tokens | TTFT (s) | decode (tok/s) | chunks r/c |",
          flush=True)
    print("|---|---|---|---|---|---|", flush=True)
    for r in RESULTS:
        if r["ok"]:
            print("| %s | %s | %s | %.2f | %.1f | %d/%d%s |"
                  % (r["run"], r["prompt_tokens"], r["gen_tokens"],
                     r["ttft_s"], r["decode_tps"],
                     r["chunks_reasoning"], r["chunks_content"],
                     "" if r["chunks_content"] else " (all reasoning)"), flush=True)
        else:
            print("| %s | - | - | - | - (FAILED) | - |" % r["run"], flush=True)
    ok = [r for r in RESULTS if r["ok"]]
    if ok:
        fulls = [r for r in ok if r["prompt_tokens"] and r["prompt_tokens"] > 1000]
        empties = [r for r in ok if r["prompt_tokens"] and r["prompt_tokens"] <= 1000]

        def med(rows, k):
            v = sorted(r[k] for r in rows
                       if r.get(k) is not None and math.isfinite(r[k]))
            return v[len(v) // 2] if v else None
        # The full cells repeat an identical prompt, so their #2 run is served
        # from the prefix cache and its TTFT measures the cache, not the tier.
        # Report the two separately; the decode rate is comparable across both.
        cold = [r for r in fulls if r["run"].endswith("#1")]
        repeat = [r for r in fulls if r["run"].endswith("#2")]
        for label, rows in (("near-empty", empties),
                            ("near-full, cold (#1 runs)", cold),
                            ("near-full, repeat (#2 runs, cache-warm by design)", repeat)):
            if rows:
                print("median %s: TTFT %.2f s, decode %.1f tok/s (achieved prompt_tokens %s)"
                      % (label, med(rows, "ttft_s") or -1, med(rows, "decode_tps") or -1,
                         [r["prompt_tokens"] for r in rows]), flush=True)
    print("DONE", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
