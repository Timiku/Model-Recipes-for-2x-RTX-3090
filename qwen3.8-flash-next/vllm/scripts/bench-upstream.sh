#!/usr/bin/env bash
# bench-upstream.sh — run the UPSTREAM token-exact bench client
# (DominikBucko/qwen38-flash-next-2x3090 scripts/benchmark_serving.py) against
# a live flash-next tier. The three arms are the repo's own published shapes
# (docs/performance.md), so our numbers sit directly beside theirs:
#
#   short-decode  128 in + 4096 out,   1 warmup + 3 runs   (their 77.3 @native)
#   long-decode   (W-4096) in + 4096 out, 0 warmup + 3 runs (their 75.6 @native)
#   boundary      (W-128) in + 128 out,  0 warmup + 1 run   (their 54.5 @native)
#
# W = the tier's MAX_MODEL_LEN: on the C4 line (256,000) the long arm reaches
# exactly the window, like their 258,048+4,096 does at 262,144.
#
# usage: bash bench-upstream.sh <run-dir> <port> <window> <label>
#   <run-dir>  where the JSONs land (created if missing)
#   <label>    a short tier tag written into the result filenames' notes
#
# The clone is the tree anchor (3fa7780). The client is pure stdlib; it
# validates streamed counts against the API usage and salts every prompt
# against prefix-cache reuse.

set -u

if [ $# -ne 4 ]; then
  echo "usage: $0 <run-dir> <port> <window> <label>" >&2
  exit 2
fi
RUN=$1; PORT=$2; WIN=$3; LABEL=$4
PIN=3fa7780
REPO=~/qwen38-flash-next-2x3090-repo
HWNOTE="local 2x3090 Ti pair under WSL2 (model-recipes, tier=$LABEL)"

mkdir -p "$RUN"

if [ ! -d "$REPO/.git" ]; then
  echo "[upbench] cloning the upstream tree at the anchor..."
  git clone -q https://github.com/DominikBucko/qwen38-flash-next-2x3090 "$REPO" || {
    echo "[upbench] CLONE FAILED - no bench"; exit 1; }
fi
if [ "$(git -C "$REPO" rev-parse HEAD)" != "$(git -C "$REPO" rev-parse "$PIN^{commit}")" ]; then
  echo "[upbench] the clone moved off the tree pin - checking out $PIN"
  git -C "$REPO" fetch -q origin 2>/dev/null || true
  git -C "$REPO" checkout -q "$PIN" || { echo "[upbench] CHECKOUT FAILED"; exit 1; }
fi

arm() { # name in out warm runs tout
  echo "[upbench] arm $1 (in=$2 out=$3 warmup=$4 runs=$5)..."
  ( cd "$REPO" && python3 scripts/benchmark_serving.py \
      --base-url "http://127.0.0.1:$PORT" --model qwen3.8-flash-next \
      --prompt-style repo-chat --input-tokens "$2" --output-tokens "$3" \
      --warmup "$4" --runs "$5" --timeout "$6" \
      --hardware-note "$HWNOTE" \
      --output "$RUN/$1.json" ) 2>&1 | tail -n 2
}

LONGIN=$((WIN - 4096))
BOUNDIN=$((WIN - 128))
arm short-decode 128 4096 1 3 900
arm long-decode "$LONGIN" 4096 0 3 3600
arm boundary "$BOUNDIN" 128 0 1 3600

python3 - "$RUN" <<'EOF'
import json, pathlib, sys
for name in ("short-decode", "long-decode", "boundary"):
    p = pathlib.Path(sys.argv[1]) / f"{name}.json"
    if not p.exists():
        print(f"{name}: NO RESULT"); continue
    d = json.loads(p.read_text())
    s = d.get("summary", {})
    measured = [r for r in d.get("runs", []) if r.get("phase") == "measured"]
    ok = [r for r in measured if r.get("status") == "ok"]
    if not ok:
        print(f"{name}: all {len(measured)} measured runs INVALID"); continue
    rec = s.get("reciprocal_mean_api_observed_tpot_tokens_per_second") or 0.0
    e2e = [r["end_to_end_output_tokens_per_second"] for r in ok]
    e2e_mean = len(e2e) / sum(1.0 / x for x in e2e)
    line = (f"{name}: decode {rec:.1f} tok/s (recip-mean TPOT) | "
            f"e2e {e2e_mean:.1f} tok/s | {len(ok)}/"
            f"{s.get('requested_measured_runs', '?')} valid")
    ttfts = [r["ttft_seconds"] for r in ok if r.get("ttft_seconds") is not None]
    if len(ttfts) == len(ok):
        line += f" | TTFT {min(ttfts):.1f}-{max(ttfts):.1f} s"
    print(line)
EOF
echo "[upbench] done - JSONs in $RUN"
