#!/bin/bash
# verdict.sh <show|sig> <model> <recipe> — the start bats' verdict box,
# file-form (model-agnostic; runs from the Windows-side repo via the 9p mount).
#
# WHY FILE-FORM: a bat must not run `bash -c "...$VAR..."` through wsl.exe.
# The Windows CRT strips the inner quote pairs and the WSL2 interop
# re-parses the re-joined argument string in a shell inside the VM, so a
# "$F" arrives as an empty expansion (or, for a -c string with bare word
# splits, as the wrong program entirely) and the line dies with a parse
# error before it can say anything. The 2026-09-03 flash-next 8th-boot
# verdict box is that field failure. Every bat wsl-line is either a plain
# script call or a -c string with no shell metacharacters at all.
#
# modes:
#   show — print the run's own boot-last-status if present (up.sh writes
#          it on every exit path: READY / REFUSED / DRAIN-TIMEOUT / FATAL
#          / BOOT-FAILED / BOOT-TIMEOUT, each with the run's last error
#          lines); else the boot-failure.log tail; else a no-record note.
#          Fresh per run, so a successful boot can never be shadowed by
#          yesterday's 401.
#   sig  — exit 0 iff the status file carries the 'device not ready'
#          signature (the start bat's [re-arm] trigger); else exit 1.
MODE=${1:?usage: verdict.sh <show|sig> <model> <tier>}
MODEL=${2:?usage: verdict.sh <show|sig> <model> <tier>}
TIER=${3:-}
# One runtime area per model (up.sh writes its status there); the tier is carried
# for the record but not part of the path - a model's tiers are mutually exclusive,
# so the last boot's status is the one in this folder.
ROOT=${MODEL_RECIPES_RT:-$HOME/model-recipes-rt}/$MODEL

case "$MODE" in
  show)
    if [ -f "$ROOT/boot-last-status" ]; then
      cat "$ROOT/boot-last-status"
    elif [ -f "$ROOT/boot-failure.log" ]; then
      tail -n 5 "$ROOT/boot-failure.log"
    else
      echo '(no WSL-side record - the run predates the status file)'
    fi
    if [ -f "$ROOT/commit-trace" ]; then
      echo
      echo "-- the run's commit trace (2 s cadence, whole run):"
      awk '{
        c = 0; a = 0;
        for (i = 2; i <= NF; i++) {
          n = split($i, kv, "=");
          if (kv[1] == "Committed_AS")  c = kv[2] + 0;
          if (kv[1] == "MemAvailable")  a = kv[2] + 0;
        }
        if (c > cmax) cmax = c;
        if (a > 0 && (a < amin || amin == 0)) amin = a;
      }
      END {
        if (cmax > 0) printf "  Committed_AS peak: %d kB (%.1f GiB)\n", cmax, cmax / 1048576;
        if (amin > 0)  printf "  MemAvailable min:  %d kB (%.1f GiB)\n", amin, amin / 1048576;
      }' "$ROOT/commit-trace"
      grep -E '^CommitLimit:' /proc/meminfo 2>/dev/null | sed 's/^/  CommitLimit now:    /' || true
    fi
    ;;
  sig)
    grep -q "device not ready" "$ROOT/boot-last-status" 2>/dev/null
    ;;
  *)
    echo "verdict.sh: unknown mode '$MODE' (show|sig)" >&2
    exit 2
    ;;
esac
