#!/usr/bin/env python3
"""gap_probe.py - the WSL2 microstutter gap profiler.

Streams one generation from a running flash-next tier and timestamps
every SSE line, so the inter-arrival gaps of the decode can be
histogrammed. The point of the instrument:

  - REGULAR large gaps (one big gap roughly every step, i.e. every
    ~1-3 tokens) point at the per-step PLE CPU round-trip (suspect 1).
  - BURSTY gaps (runs of small gaps punctuated by one long one) point at
    UVA expert-miss fetches (suspect 2).

Usage (Windows side, the tier must be up):
    python gap_probe.py --port 8115 [--model qwen3.8-flash-next]
                        [--out-tokens 512] [--pad-tokens 0]
                        [--out RECORD.txt]

pad-tokens pads the prompt with a deterministic count-down so the probe
can run at mid-context as well (pad-tokens 60000 ~= a 60K-ctx run).

Instrument notes (kept honest, the syv-ai lesson): one SSE data line
carries ~1-3 tokens under spec decoding - the gap histogram is per SSE
line, and the SUMMARY line additionally reports token-true figures from
usage.completion_tokens. Do not read per-line rates as per-token rates.
The probe is read-only: it never boots, parks, or mutates the tier.
"""
import argparse
import json
import time
import urllib.request
from datetime import datetime

BUCKETS_MS = [1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500]


def make_prompt(pad_tokens: int) -> str:
    if pad_tokens <= 0:
        return "Count down from 999 to 1, one number per line."
    # the pad block is a digit stream, which tokenizes at ~0.97 tok/char on
    # this checkpoint (measured 09-04: 264127 chars -> 255993 tokens), NOT the
    # ~0.226 of prose; aiming prose-width chars at a digit block overshoots
    # ~4x and trips the 256K window. Aim in tokens, divide by the digit rate.
    target_chars = int(pad_tokens / 0.97)
    block = " ".join(map(str, range(9000, 9000 + 400)))  # 1999 chars, ~1940 tok
    reps = max(1, target_chars // len(block))
    return (
        "Read this number stream, then continue the count from where it "
        "leaves off, one number per line, for as many lines as requested: "
        + " ".join(" ".join(map(str, range(9000, 9000 + 400))) for _ in range(reps))
    )


def probe(port: int, model: str, out_tokens: int, pad_tokens: int) -> dict:
    url = f"http://127.0.0.1:{port}/v1/chat/completions"
    payload = {
        "model": model,
        "messages": [
            {"role": "user", "content": make_prompt(pad_tokens)}
        ],
        "max_tokens": out_tokens,
        "temperature": 1.0,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )

    t0 = time.perf_counter()
    ttft = None
    lines = []
    content_chars = 0
    usage = None
    with urllib.request.urlopen(req, timeout=1800) as r:
        for raw in r:
            if not raw.startswith(b"data: "):
                continue
            chunk = raw[6:].strip()
            now = time.perf_counter()
            if chunk == b"[DONE]":
                break
            try:
                d = json.loads(chunk)
            except ValueError:
                continue
            if d.get("usage"):
                usage = d["usage"]
            ch = d.get("choices") or []
            if not ch:
                continue
            delta = ch[0].get("delta") or {}
            piece = (
                delta.get("content")
                or delta.get("reasoning")
                or delta.get("reasoning_content")
            )
            if piece:
                if ttft is None:
                    ttft = now - t0
                lines.append(now - t0)
                content_chars += len(piece)
    t1 = time.perf_counter()

    gaps = [
        (b - a) * 1000.0
        for a, b in zip(lines, lines[1:])
    ]
    gen = (usage or {}).get("completion_tokens")
    summary = {
        "wall_s": round(t1 - t0, 2),
        "ttft_s": round(ttft, 3) if ttft is not None else None,
        "sse_lines": len(lines),
        "gen_tokens": gen,
        "content_chars": content_chars,
        "usage": usage,
        "decode_tok_s_wall": round(gen / (t1 - t0 - ttft), 1)
        if (gen is not None and ttft is not None and t1 - t0 > ttft)
        else None,
    }
    return {"summary": summary, "gaps_ms": gaps, "line_ts": lines}


def fmt_hist(gaps_ms, buckets) -> str:
    hist = []
    prev = 0
    for b in buckets:
        n = sum(1 for g in gaps_ms if prev < g <= b)
        hist.append(f"  {prev:>4}-{b:<5} ms: {n}")
        prev = b
    over = sum(1 for g in gaps_ms if g > buckets[-1])
    hist.append(f"  >{buckets[-1]:<6} ms: {over}")
    return "\n".join(hist)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=8115)
    ap.add_argument("--model", default="qwen3.8-flash-next")
    ap.add_argument("--out-tokens", type=int, default=512)
    ap.add_argument("--pad-tokens", type=int, default=0)
    ap.add_argument("--out", default=None, help="record file (default: stdout)")
    args = ap.parse_args()

    res = probe(args.port, args.model, args.out_tokens, args.pad_tokens)
    gaps = res["gaps_ms"]
    s = res["summary"]
    ordered = sorted(gaps)
    med = ordered[len(ordered) // 2] if ordered else 0.0
    p90 = ordered[int(len(ordered) * 0.9)] if ordered else 0.0
    mx = max(gaps) if gaps else 0.0
    big = [g for g in gaps if g > 100.0]
    out = [
        "== gap probe (WSL2 microstutter instrument) ==",
        f"when: {datetime.now().isoformat(timespec='seconds')}  "
        f"port {args.port}  model {args.model}  "
        f"pad {args.pad_tokens}  out {args.out_tokens}",
        f"wall {s['wall_s']} s  TTFT {s['ttft_s']} s  SSE lines {s['sse_lines']}  "
        f"gen {s['gen_tokens']} tok  decode(wall) {s['decode_tok_s_wall']} tok/s",
        f"gaps: n={len(gaps)}  median {med:.0f} ms  p90 {p90:.0f} ms  "
        f"max {mx:.0f} ms  >100ms count {len(big)} "
        f"({'%.1f%%' % (100.0 * len(big) / len(gaps)) if gaps else '0%'} of lines)",
        "-- gap histogram --",
        fmt_hist(gaps, BUCKETS_MS),
        "-- gaps > 100 ms, in stream order (the stutter pattern) --",
        " ".join(f"{g:.0f}" for g in gaps if g > 100.0)[:1200],
        "",
    ]
    text = "\n".join(out)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")
        print(f"record: {args.out}")
    print(text)


if __name__ == "__main__":
    main()
