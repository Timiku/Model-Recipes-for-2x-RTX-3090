#!/usr/bin/env python3
"""bench_parallel.py - model-agnostic concurrent-stream stability harness.

Each model's bench-parallel.bat (the sibling of its bench.bat) drives this.
It finds a live vLLM tier on one of the model's candidate ports, then climbs
the number of concurrent completion streams in powers of two (2, 4, 8, 16,
...), and at each level verifies every stream returns cleanly and the engine
is still answering. The first level that fails is reported and the climb
stops, so the record reads "the tier holds N stable concurrent streams."

Stdlib only (no third-party deps). The endpoint is the WSL-internal
localhost:PORT (docker publishes its tiers there), so this runs inside the
distro - the bat just relays stdout to the record:

    wsl -d <distro> -- python bench_parallel.py \
        --ports 8113,8115,8116,8117 --max-n 8 --tokens 16000 --label qwen-27b
"""
import argparse
import concurrent.futures as cf
import json
import socket
import sys
import time
import urllib.request

BASE_LINE = (
    "The observatory log for the night reads, entry after entry, a steady "
    "record of clear sky, low cloud to the north, and the instrument holding "
    "its pointing. "
)


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--base", default="127.0.0.1",
                   help="host to reach the tier on (WSL-internal localhost)")
    p.add_argument("--port", type=int, default=0,
                   help="explicit live port; 0 = probe the --ports list")
    p.add_argument("--ports", default="",
                   help="comma list of candidate ports to probe")
    p.add_argument("--max-n", type=int, default=8,
                   help="top concurrency; the climb is 2,4,8,... up to this")
    p.add_argument("--tokens", type=int, default=16000,
                   help="prompt size, approx tokens, per stream")
    p.add_argument("--decode", type=int, default=32,
                   help="max output tokens per stream")
    p.add_argument("--model", default="", help="served model id (else read it)")
    p.add_argument("--label", default="tier", help="label for the record header")
    a = p.parse_args()
    a.max_n = max(2, a.max_n)
    return a


def url(host, port, path):
    return "http://%s:%d%s" % (host, port, path)


def http_json(host, port, path, payload=None, timeout=300):
    data = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url(host, port, path), data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, json.loads(r.read().decode("utf-8", "ignore"))


def reachable(host, port, timeout=3):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except Exception:
        return False


def read_model(host, port, timeout=10):
    try:
        st, j = http_json(host, port, "/v1/models", timeout=timeout)
        if st == 200 and j.get("data"):
            return j["data"][0]["id"]
    except Exception:
        pass
    return ""


def resolve(host, a):
    """Return (port, model_id) for a live tier, or (None, '')."""
    tried = []
    if a.port:
        tried.append(a.port)
    tried += [int(x) for x in a.ports.split(",") if x.strip().isdigit()]
    for port in tried:
        if not reachable(host, port):
            continue
        model = read_model(host, port)
        if model:
            return port, model
    return None, ""


def make_prompt(tokens):
    target = max(200, int(tokens) * 4)
    return (BASE_LINE * (target // len(BASE_LINE) + 1))[:target]


def one_stream(host, port, model, prompt, decode, timeout):
    try:
        st, j = http_json(host, port, "/v1/completions",
                          {"model": model, "prompt": prompt,
                           "max_tokens": decode, "temperature": 0.0},
                          timeout=timeout)
        ct = (j.get("usage") or {}).get("completion_tokens")
        return st, ct
    except Exception as e:
        return 0, repr(e)


def engine_alive(host, port):
    try:
        st, _ = http_json(host, port, "/v1/models", timeout=15)
        return st == 200
    except Exception:
        return False


def run_batch(host, port, model, prompt, n, decode, timeout):
    t0 = time.time()
    res = []
    with cf.ThreadPoolExecutor(max_workers=max(1, n)) as ex:
        futs = [ex.submit(one_stream, host, port, model, prompt, decode, timeout)
                for _ in range(n)]
        for f in cf.as_completed(futs):
            res.append(f.result())
    return time.time() - t0, res


def main():
    a = parse_args()
    host = a.base
    port, auto_model = resolve(host, a)
    if port is None:
        cands = a.ports or str(a.port)
        print("no %s tier is up: none of %s is answering /v1/models."
              % (a.label, cands))
        print("boot one first, then re-run; the record ends here.")
        return 1

    model = a.model or auto_model or "default"
    prompt = make_prompt(a.tokens)
    per_timeout = min(300, 30 + max(0, a.tokens) // 100)

    print("=" * 60)
    print(" bench-parallel: %s" % a.label)
    print("  resolved port %d | model %s | %s" % (port, model, host))
    print("  climb: 2,4,8,... up to %d (max-n); prompt ~%d tokens, %d out tok"
          % (a.max_n, a.tokens, a.decode))
    print("  verdict: STABLE = every stream 200 and the engine still answers")
    print("=" * 60)

    levels = []
    n = 2
    highest_stable = 0
    while n <= a.max_n:
        wall, res = run_batch(host, port, model, prompt, n, a.decode, per_timeout)
        ok = sum(1 for s, _ in res if s == 200)
        alive = engine_alive(host, port)
        stable = (ok == n) and alive
        if not stable:
            if ok < n:
                reason = "%d/%d streams returned non-200" % (n - ok, n)
            else:
                reason = "engine stopped answering after the batch"
        else:
            reason = ""
        levels.append((n, wall, ok, n, alive, stable, reason))
        flag = "STABLE" if stable else "FAIL  "
        print("  n=%-3d  wall=%6.1fs  ok=%d/%d  engine-alive=%s  => %s %s"
              % (n, wall, ok, n, str(alive).lower(), flag, reason))
        if not stable:
            for i, (s, c) in enumerate(res, 1):
                if s != 200:
                    print("      stream %d: status=%s detail=%s"
                          % (i, s, c if isinstance(c, str) else ""))
            break
        highest_stable = n
        n *= 2

    print("-" * 60)
    print(" highest stable concurrency: %s"
          % (str(highest_stable) if highest_stable
             else "none - it failed at the first level (n=2)"))
    print("  levels measured: "
          + ", ".join("%d:%s" % (lv[0], "OK" if lv[5] else "FAIL") for lv in levels))
    return 0


if __name__ == "__main__":
    sys.exit(main())
