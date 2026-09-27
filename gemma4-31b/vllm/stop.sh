#!/usr/bin/env bash
# stop.sh - the native-Linux twin of stop.bat: compose-down every tier of
# gemma4-31b (package yml + its machine .env), verify the pinned cards and the
# ports release. No watchdog to kill on this side; down.sh is the whole job.
set -u
. "$(dirname -- "$0")/../../_shared/scripts/reporoot.sh"
MODEL=gemma4-31b

echo ============================================================
echo  stop: every tier of $MODEL
echo "  compose-down each tier (package yml + its machine .env),"
echo   verify the pinned cards and the ports release
echo ============================================================
echo
bash "$REPO/_shared/scripts/down.sh" $MODEL "$@"
rc=$?
echo
exit $rc
