#!/usr/bin/env python3
"""gemma4-31b bench (Windows side; the gemma tier must be UP).

Same harness family as the qwen3.8-27b A/B harnesses
(`qwen3.8-27b/vllm/scripts/smoke/smoke_mtp280.py`, `dist_llama.py`):
the same NARR / CODE prompts (so the numbers are comparable with the
27B's narr ~75 / code ~103 class), the card's standardized sampler
(temp 1.0 / top_p 0.95, as the yml's override-generation-config carries
it into every request), streaming measurement of TTFT + decode tok/s,
and `stream_options: include_usage` for the true token counts.

The context-depth axis (what this bench adds over the 27B harnesses):
each arm runs NEAR-EMPTY (the prompt alone) and NEAR-FULL (the prompt
padded with neutral filler to ~the window), so the record shows how TTFT
and decode speed move with ctx on this box.

Usage:
  python bench_gemma.py [port] [near-full-token-target]
  default port 8032 (the MTP-on shape, window 179040; the bat passes
  target 170000), or for the nomtp/long-ctx shape:
      python bench_gemma.py 8032 185000   (nomtp window 189000, the 09-04 box-fit)
  the KVarN tiers share the windows of their fp8 twins:
      WINDOW=189000 python bench_gemma.py 8032   (the nomtp/KVarN-nomtp window)
      WINDOW=179040 python bench_gemma.py 8032  (the dual-MTP/KVarN-mtp window)
  (the KVarN tiers bench at near-full 100000: the head-512 SDPA envelope
   OOMs past ~150k, so 100k is the needle-proven deep depth)

Stdlib only. Read-only on the tier: it never boots, parks, or kills
anything; it streams a handful of chat completions and prints one line
per run plus a summary table to stdout (the bat redirects that to the
result file under vllm/logs/bench/).

Method notes:
- prompt_tokens / completion_tokens come from vLLM's usage (authoritative),
  never from client-side guessing.
- the near-full pad is sized with a one-shot calibration: a ~2.5K-token
  filler call yields the realized chars/token ratio for THIS tokenizer;
  the pad is then built to hit the target. The achieved prompt_tokens of
  each full run is reported so the estimate is auditable.
- the yml has no enable_prefix_caching, so repeated near-full runs each
  pay the full prefill; the runs are independent measurements.
- the near-full prompt + the 512-token output must fit the window:
  170000 + 512 + template overhead < 179040 (the 8032 shape);
  185000 + 512 < 189000 (the nomtp window, WINDOW=189000).
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8032
NEAR_FULL = int(sys.argv[2]) if len(sys.argv) > 2 else 170000
BASE = "http://localhost:%d" % PORT
# one port per model (09-19): the port no longer identifies the shape, so the
# window is a CLI arg (WINDOW=179040 or 189000); the old port-keyed map is
# retired ({8032: 179040, 8033: 189000, 8105: 189000, 8106: 179040}).
WINDOW = int(os.environ.get("WINDOW", "179040"))

MAX_OUT = 512
TEMP = 1.0
TOP_P = 0.95
PRESENCE = 0.0
TIMEOUT = 1800
# The near-full decode sample length. Default 512; the KVarN tiers' head-512
# slow path charges ~3.3 s/token at 100k ctx (0.3 tok/s), so a full 512-token
# sample costs ~28 min per run. Pass a smaller value (32) to sample the same
# structural rate inside a feasible envelope; every record line prints gen=,
# so the sample length is always on the record.
FULL_OUT = int(sys.argv[3]) if len(sys.argv) > 3 else MAX_OUT

# --- the 27B-harness prompts, verbatim (comparability across models) ----
NARR = ("Write a detailed 400-word explanation of how CPU caches work, "
        "covering L1/L2/L3, write policies, and cache coherence.")
CODE = ("Write a Python implementation of an LRU cache with a capacity "
        "parameter, get/set methods, and a short test main. Keep it "
        "complete and runnable.")

# neutral filler for the near-full pad (repeated; the prefill is real
# compute either way — this is a speed bench, not a quality probe)
FILL_UNIT = ("The same quiet morning came back to the harbor again, with the "
             "nets wet and the gulls early, and the fog stayed low over the "
             "water until the last boat had come in. ")

RESULTS = []


def http_open(path, payload, stream=False):
    req = urllib.request.Request(
        BASE + path, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=TIMEOUT)


def discover_model():
    with urllib.request.urlopen(BASE + "/v1/models", timeout=60) as r:
        obj = json.loads(r.read())
    ids = [m.get("id") for m in obj.get("data", [])]
    gemma = [i for i in ids if i and "gemma" in i]
    return (gemma or ids or ["<unknown>"])[0], ids


def warmup(m):
    with http_open("/v1/chat/completions",
                   {"model": m, "messages": [{"role": "user", "content": "Say: warm"}],
                    "max_tokens": 16, "temperature": 0.7, "top_p": 0.8}) as r:
        json.loads(r.read())
    print("warmup done.", flush=True)


def calibrate(m):
    fill = FILL_UNIT * 40  # ~7.2K chars, a couple of K tokens
    payload = {"model": m, "prompt": fill, "max_tokens": 1, "temperature": 0.0}
    with http_open("/v1/completions", payload) as r:
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
    text = prompt + " " + FILL_UNIT * units
    return text


def measure(tag, m, prompt, max_out=None):
    payload = {"model": m, "messages": [{"role": "user", "content": prompt}],
               "max_tokens": max_out or MAX_OUT, "temperature": TEMP, "top_p": TOP_P,
               "presence_penalty": PRESENCE, "stream": True,
               "stream_options": {"include_usage": True}}
    r = http_open("/v1/chat/completions", payload)
    t0 = time.time()
    t_first = t_last = None
    n_chunks = 0
    usage = None
    try:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data:"):
                continue
            d = line[5:].strip()
            if d == "[DONE]":
                break
            obj = json.loads(d)
            if obj.get("usage"):
                usage = obj["usage"]
            ch = obj.get("choices") or [{}]
            c = (ch[0].get("delta") or {}).get("content")
            if c:
                now = time.time()
                if t_first is None:
                    t_first = now
                t_last = now
                n_chunks += 1
    finally:
        r.close()
    n = usage.get("completion_tokens") if usage else n_chunks
    ptok = usage.get("prompt_tokens")
    ttft = (t_first - t0) if t_first else float("nan")
    span = (t_last - t_first) if (t_first and t_last) else 0.0
    dec = (n - 1) / span if span > 0 else float("nan")
    print("%s: prompt=%s  gen=%d  TTFT=%.2fs  decode=%.1f tok/s"
          % (tag, ptok if ptok is not None else "?", n, ttft, dec), flush=True)
    RESULTS.append({"run": tag, "prompt_tokens": ptok, "gen_tokens": n,
                    "ttft_s": ttft, "decode_tps": dec, "ok": True})


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
    t_start = time.strftime("%Y-%m-%d %H:%M:%S")
    m, ids = discover_model()
    print("== gemma4-31b bench ==", flush=True)
    print("started: %s   port: %d   window: %s   near-full target: %d   model: %s (served: %s)"
          % (t_start, PORT, WINDOW if WINDOW else "unknown for this port",
             NEAR_FULL, m, ",".join(ids)), flush=True)
    warmup(m)
    ratio = calibrate(m)
    narr_full = pad(NARR, NEAR_FULL, ratio)
    code_full = pad(CODE, NEAR_FULL, ratio)
    print("near-full pad: %d and %d chars (%.0f and %.0f tokens estimated)"
          % (len(narr_full), len(code_full),
             len(narr_full) * ratio, len(code_full) * ratio), flush=True)
    cells = [("narr-empty", NARR), ("code-empty", CODE),
             ("narr-full", narr_full), ("code-full", code_full)]
    for i in range(1, 3):
        for name, prompt in cells:
            tag = "%s#%d" % (name, i)
            try:
                mo = None if "empty" in name else FULL_OUT
                measure(tag, m, prompt, max_out=mo)
            except Exception as e:
                fail(tag, e)
    # --- summary -----------------------------------------------------------
    print("\n== summary (decode tok/s and TTFT, streaming; usage-reported counts) ==",
          flush=True)
    print("| run | prompt_tokens | gen_tokens | TTFT (s) | decode (tok/s) |",
          flush=True)
    print("|---|---|---|---|---|", flush=True)
    for r in RESULTS:
        if r["ok"]:
            print("| %s | %s | %s | %.2f | %.1f |"
                  % (r["run"], r["prompt_tokens"], r["gen_tokens"],
                     r["ttft_s"], r["decode_tps"]), flush=True)
        else:
            print("| %s | - | - | - | - (FAILED) |" % r["run"], flush=True)
    ok = [r for r in RESULTS if r["ok"]]
    if ok:
        fulls = [r for r in ok if r["prompt_tokens"] and r["prompt_tokens"] > 1000]
        empties = [r for r in ok if r["prompt_tokens"] and r["prompt_tokens"] <= 1000]
        def med(rows, k):
            v = sorted(r[k] for r in rows if r.get(k) is not None)
            return v[len(v) // 2] if v else None
        for label, rows in (("near-empty", empties), ("near-full", fulls)):
            if rows:
                print("median %s: TTFT %.2f s, decode %.1f tok/s (achieved prompt_tokens %s)"
                      % (label, med(rows, "ttft_s") or -1, med(rows, "decode_tps") or -1,
                         [r["prompt_tokens"] for r in rows]), flush=True)
    print("DONE", flush=True)


if __name__ == "__main__":
    main()
