#!/usr/bin/env bash
# uninstall-all-core.sh - the box-level teardown. Brings down every model's
# tiers, removes every model's WSL runtime area, and drops every vllm image
# (this is the blunt instrument: no "other model still needs it" caveat, because
# we are taking the whole box down). The careful per-version image refcount
# lives in uninstall-core.sh, which the per-model uninstall.bat calls.
#
# It does NOT touch the Windows-side model folders (the package templates, the
# machine deltas, the weights, the patches) - those stay; the user removes them.
# A user-set WEIGHTS_DIR is user property, however much else this runs.
#
#   bash _shared/scripts/uninstall-all-core.sh [deep]

set -u

SRC=${MODEL_RECIPES_SRC:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}
RTBASE=${MODEL_RECIPES_RT:-$HOME/model-recipes-rt}

echo "==================================================================="
echo " model-recipes UNINSTALL ALL - every model on this box"
echo "==================================================================="

# [1/3] down every model's tiers (package yml + its machine delta, two-file,
# from the package dir so the compose project name is package/), then
# [2/3] remove each model's runtime area (the distro's only claim).
for mdir in "$SRC"/*/; do
  [ -d "$mdir" ] || continue
  model=$(basename "$mdir")
  YDIR="$mdir/vllm/package"
  [ -d "$YDIR" ] || continue
  echo "[1/3] $model - down the tiers"
  cd "$YDIR"
  for y in *.yml; do
    [ -f "$y" ] || continue
    stem=${y%.yml}
    # H3: per-model compose project
    MRPROJ="mr-$(echo "$model" | tr '.' '-' | tr 'A-Z' 'a-z')"
    CF=(-p "$MRPROJ" -f "$y")
    if docker compose "${CF[@]}" down --remove-orphans --timeout 60 2>/dev/null; then
      echo "      down: $stem"
    else
      echo "      $stem: compose down reported a problem; checking the name holder"
    fi
  done
  # Name catch: any container still holding a tier name of a compose project
  # that is no longer a live model is removed by name, guarded to vllm tier
  # names only (never another product's container).
  for y in *.yml; do
    [ -f "$y" ] || continue
    NAME=$(sed -n 's/.*container_name:[[:space:]]*"\{0,1\}\([^"]*\).*/\1/p' "$y" | head -n1)
    if [ -n "$NAME" ] && docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
      holder=$(docker inspect "$NAME" -f '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null || true)
      case "$holder" in
        "package"|"")
          docker rm -f "$NAME" 2>/dev/null && echo "      removed name-holder $NAME"
        ;;
      esac
    fi
  done
  RTDIR="$RTBASE/$model"
  if [ -d "$RTDIR" ]; then
    rm -rf "$RTDIR"
    echo "      removed runtime area: $RTDIR"
  else
    echo "      runtime area already clean ($RTDIR absent)"
  fi
done

# [3/3] drop every vllm image (the box-level nuke; the per-model path is the
# one that prunes by refcount).
echo "[3/3] prune the images the package ymls name (only what this repo created)"
# H5: derive the tag list from the ymls (the same extraction install-core
# uses, incl. the ${VLLM_IMAGE:-...} form), not a machine-wide sweep - images
# pulled for other projects stay. Flash-Next's built image is named too.
found_img=0
for mdir in "$SRC"/*/; do
  [ -d "$mdir/vllm/package" ] || continue
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    found_img=1
    if docker rmi "$img" 2>/dev/null; then
      echo "      removed: $img"
    else
      echo "      could not remove: $img (still in use?)"
    fi
  done < <(sed -n 's/.*image:[[:space:]]*\(.*\)/\1/p' "$mdir/vllm/package/"*.yml 2>/dev/null \
    | sed 's/\${VLLM_IMAGE:-\([^}]*\)}.*/\1/; s/[" ]//g' | LC_ALL=C sort -u)
done
if [ "$found_img" -eq 0 ]; then
  echo "      no package images present - nothing to remove"
fi

echo "==================================================================="
echo " WSL side done. The Windows-side model folders (the package templates,"
echo " the machine deltas, the weights, the patches) are yours to remove."
echo "==================================================================="
exit 0
