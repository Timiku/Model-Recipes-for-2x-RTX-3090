#!/usr/bin/env bash
# bench-parallel.sh - the native-Linux twin of bench-parallel.bat: the
# shared climber (bench_parallel.py) fires 2, 4, 8, ... concurrent
# completions at the live tier; a level that breaks is the ceiling.
# usage: bench-parallel.sh [port] [max-n] [tokens]
# The tier must already be UP; this script never boots anything.
set -u
. "$(dirname -- "$0")/../../_shared/scripts/reporoot.sh"
MODEL=gemma4-31b
PORT=${1:-0}
MAXN=${2:-8}
TOK=${3:-16000}

PORTS=$(sed -n 's/^PORT=\([0-9][0-9]*\)\r\?$/\1/p' "$REPO/$MODEL/vllm/"*.env 2>/dev/null | LC_ALL=C sort -un | paste -sd, -)

OUT=$REPO/$MODEL/vllm/logs/bench
mkdir -p "$OUT"
TS=$(date +%Y%m%d-%H%M%S)
OUTFILE=$OUT/bench-parallel-$MODEL-$PORT-$TS.txt

echo ============================================================
echo  bench-parallel: $MODEL
echo  climbs concurrent streams 2, 4, 8, ... up to max-n $MAXN.
echo  port: $PORT   0 = whichever $MODEL tier is up
echo  candidate ports: $PORTS
echo  record: $OUTFILE
echo ============================================================
echo
echo == bench-parallel: $MODEL, port $PORT, max-n $MAXN, tokens $TOK == > "$OUTFILE"
python3 "$REPO/_shared/scripts/bench_parallel.py" --port $PORT --ports $PORTS --max-n $MAXN --tokens $TOK --label $MODEL >> "$OUTFILE" 2>&1
echo ------------------------------------------------------------
cat "$OUTFILE"
echo ------------------------------------------------------------
echo Done - the record above is also at:
echo   $OUTFILE
exit 0
