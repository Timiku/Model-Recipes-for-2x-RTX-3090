#!/usr/bin/env bash
# uninstall-all.sh - the native-Linux twin of _shared/uninstall-all.bat: the
# box-level teardown. Calls uninstall-all-core.sh (every model's tiers down,
# every runtime area removed, every vllm image dropped); with the "deep"
# argument nothing extra happens on Linux - there is no distro to terminate,
# the argument is accepted so the two entry surfaces read the same.
#
# Will NOT touch: any user-set WEIGHTS_DIR (your data), the model folders in
# the tree (the package templates, the machine .envs, the patches, the
# weights) - you remove those yourself.
set -u
. "$(dirname -- "$0")/scripts/reporoot.sh"

echo ============================================================
echo  model-recipes UNINSTALL ALL - every model on this box
echo.
echo   will delete, for every model under the repo:
echo "    - the tiers (compose-down each, verified against the cards)"
echo "    - the runtime area  ~/model-recipes-rt/<model>/"
echo "    - the vllm images (all of them - this is the box-level nuke)"
echo   will NOT touch:
echo "    - any user-set WEIGHTS_DIR (your data)"
echo     - the model folders - the package templates, the machine .envs,
echo       the patches, the weights
echo "  (deep is accepted for parity with the Windows bat; on Linux there"
echo "  is no distro to terminate)"
echo ============================================================
echo
printf 'type y to run it: '
IFS= read -r A || A=""
[ "${A:0:1}" = "y" ] || { echo "aborted; nothing was changed."; exit 1; }

DEEP=""
[ "${1:-}" = "deep" ] && DEEP=deep
bash "$REPO/_shared/scripts/uninstall-all-core.sh" $DEEP
exit $?
