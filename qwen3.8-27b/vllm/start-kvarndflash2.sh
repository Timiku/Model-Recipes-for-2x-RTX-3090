#!/usr/bin/env bash
# start-kvarndflash2.sh - the native-Linux twin of start-kvarndflash2.bat: the banner,
# the port preflight, then serve.sh (which boots the tier and tails its
# log; Ctrl-C detaches, the container keeps running). The Windows bat's
# watchdog has no native role - there is no WSL distro to keep warm and no
# relay to babysit; the foreground tail IS the window.
set -eu
. "$(dirname -- "$0")/../../_shared/scripts/reporoot.sh"
MODEL=qwen3.8-27b
TIER=kvarndflash2
YML=kvarndflash2.yml
PORT=8117
CNAME=qwen-27b-kvarndflash2-serve

echo ============================================================
echo  serve: $MODEL / $YML, the $TIER tier
echo  port $PORT, container $CNAME
echo  stance notes:
echo  stance: dflash2 + w4a16.

echo ============================================================
echo

# is the port already listening? another tier or a stale boot
if ss -ltn "( sport = :$PORT )" 2>/dev/null | grep -q LISTEN; then
  echo
  echo Port $PORT is already listening - stop the current tenant first
  echo with this model stop script.
  exit 1
fi

echo "Booting - weight load + cudagraph capture; first boots run to"
echo "several minutes. Ctrl-C detaches from the log; the container keeps"
echo running. Stop with stop.sh.
echo
bash "$REPO/_shared/scripts/serve.sh" $MODEL $TIER

echo
echo ------------------------------------------------------------
echo The serve process has exited with code $?. The verdict, as recorded
echo in the runtime area:
bash "$REPO/_shared/scripts/verdict.sh" show $MODEL $TIER
echo ------------------------------------------------------------
echo "Reading the verdict (the status file is quoted above):"
echo "  READY         - the probe answered and a 1-token generation worked;"
echo "                  the tier is serving (exit code 0)."
echo   REFUSED       - a live tier holds this tier pair of cards: stop
echo                   it, then re-run.
echo   DRAIN-TIMEOUT - a just-stopped tier was still shedding VRAM after
echo                   the drain window: re-run once nvidia-smi is clear.
echo "  FATAL         - the GPU stack never answered (driver, container"
echo "                  toolkit, or the pinned pair)."
echo "  BOOT FAILED / - the container log tail sits above this box; save"
echo   TIMEOUT       the window output, then run stop.sh to clean up.
exit $rc
