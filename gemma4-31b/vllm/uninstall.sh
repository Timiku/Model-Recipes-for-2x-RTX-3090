#!/usr/bin/env bash
# uninstall.sh - the native-Linux twin of uninstall.bat: the model's
# tiers down, the runtime area and images removed (uninstall-core.sh),
# then done - the tree folder and the weights always stay.
set -eu
. "$(dirname -- "$0")/../../_shared/scripts/reporoot.sh"
MODEL=gemma4-31b

echo ============================================================
echo  model-recipes uninstall: $MODEL
echo "  [1/2] down + runtime area + images (uninstall-core.sh)"
echo "  [2/2] the tree folder and weights stay (nothing else to remove)"
echo ============================================================
echo
bash "$REPO/_shared/scripts/uninstall-core.sh" $MODEL
rc=$?
echo
echo "  the tree folder ($REPO/$MODEL) stays, weights included -"
echo "  a re-install re-runs the wizard. Delete it by hand if you want the space."
exit $rc
