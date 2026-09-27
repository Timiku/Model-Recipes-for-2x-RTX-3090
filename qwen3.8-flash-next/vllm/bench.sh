#!/usr/bin/env bash
# bench.sh - the native-Linux twin of bench.bat: gate on the shared
# routecheck (a real HTTP request the tier must answer), then run the
# shared bench_speed.py. No WSL relay class exists here, so routecheck's
# exit-3 (listens, never answers) branch has no native cause; a dead
# listener is a dead listener, cleared by stop.sh.
# usage: bench.sh [port] [near-full] [full-out]
# The tier must already be UP; this script never boots anything.
set -u
. "$(dirname -- "$0")/../../_shared/scripts/reporoot.sh"
MODEL=qwen3.8-flash-next
PORT=${1:-}
NEARFULL=${2:-}
FULLOUT=${3:-512}
[ -n "$FULLOUT" ] || FULLOUT=512

command -v python3 >/dev/null 2>&1 || { echo "python3 not found on PATH"; exit 1; }

# no port given: probe the .env-declared ports, take the first live one
if [ -z "$PORT" ]; then
  for p in $(sed -n 's/^PORT=\([0-9][0-9]*\)\r\?$/\1/p' "$REPO/$MODEL/vllm/"*.env 2>/dev/null | LC_ALL=C sort -un); do
    if python3 "$REPO/_shared/scripts/routecheck.py" "$p" >/dev/null 2>&1; then PORT=$p; break; fi
  done
fi
if [ -z "$PORT" ]; then
  echo
  echo No $MODEL tier is up: none of the .env-declared ports is answering.
  echo "Boot one first (this model start script), then re-run, or pin the"
  echo "port: bench.sh PORT   (the example port comes from this model tier envs)"
  exit 1
fi
if ! python3 "$REPO/_shared/scripts/routecheck.py" "$PORT" >/dev/null 2>&1; then
  echo
  echo [bench] port $PORT is not accepting - the tier is down. Boot it
  echo         first, then re-run this script.
  exit 1
fi
echo "[bench] port $PORT answers - the tier is up; running the shared bench."
[ -n "$NEARFULL" ] || case $PORT in
  *) NEARFULL=250000 ;;
esac

OUT=$REPO/$MODEL/vllm/logs/bench
mkdir -p "$OUT"
TS=$(date +%Y%m%d-%H%M%S)
OUTFILE=$OUT/bench-$MODEL-$PORT-$TS.txt

echo == bench: $MODEL, port $PORT, near-full $NEARFULL, sample $FULLOUT == > "$OUTFILE"
echo    gate: routecheck - real HTTP - harness: shared bench_speed.py >> "$OUTFILE"

echo
echo Writing the record to $OUTFILE ...
echo "The near-full runs each pay the full prefill; expect a few minutes each."
echo
python3 "$REPO/_shared/scripts/bench_speed.py" $PORT $NEARFULL $FULLOUT --label $MODEL >> "$OUTFILE" 2>&1

echo ------------------------------------------------------------
cat "$OUTFILE"
echo ------------------------------------------------------------
echo Done - the record above is also at:
echo   $OUTFILE
echo The tier is left exactly as found. When you are ready: stop.sh,
echo then the next tier start script.
exit 0
