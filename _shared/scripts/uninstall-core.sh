#!/usr/bin/env bash
# uninstall-core.sh — the WSL half of a model's uninstall.bat. The bat
# runs this in the chosen distro (the Windows stage 0 verified the
# prereqs): down, the WSL runtime area, images, report.
#
#   bash _shared/scripts/uninstall-core.sh <model> [deep]
#
# It does NOT touch the model's Windows-side folder (the package templates,
# the machine deltas, the patches, the weights - all of it stays; the [1/4]
# down reads the package ymls + their machine deltas in place but writes
# nothing) and it does NOT touch the Windows-side tree at all - that deletion
# is the bat's own last step, the only part a user should be asked to confirm
# first. What it removes is exactly what the install put in the distro: the
# tier's containers (via the yml, read from the tree - the runtime area is
# gone by the time this runs, so the tree's copy is the only one left), the
# runtime area, and the image the package ymls name, pruned only when no
# other model still references that exact tag (uninstall-all is the nuke).

set -u

if [ $# -lt 1 ]; then
  echo "usage: $0 <model> [deep]" >&2
  exit 2
fi

MODEL=$1
DEEP=${2:-}
SRC=${MODEL_RECIPES_SRC:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}
RTBASE=${MODEL_RECIPES_RT:-$HOME/model-recipes-rt}
RTDIR=$RTBASE/$MODEL
# The compose project name is the package dir (package/), where docker compose
# resolves the first -f from. The mirror is gone by now; this yml is read from
# the Windows-side tree, in place.
YDIR=$SRC/$MODEL/vllm/package
COMPOSE_PROJECT_NAME=$(basename "$YDIR")

echo "==================================================================="
echo " model-recipes uninstall — $MODEL"
echo "==================================================================="

# ---- [1/4] down ----
echo "[1/4] down (the tier's containers, via the yml in the tree)"
cd "$SRC"
if [ -d "$YDIR" ]; then
  for y in "$YDIR"/*.yml; do
    [ -f "$y" ] || continue
    # The two-file project, as up.sh booted it: the package yml plus the
    # machine .env (--env-file; one folder up, beside the bats; the yml stem
    # names it). Absolute -f paths keep the compose project name = package/.
    STEM=${y%.yml}
    CF=(-f "$y")
    docker compose "${CF[@]}" down --remove-orphans --timeout 60 2>/dev/null || true
    NAME=$(sed -n 's/.*container_name:[[:space:]]*"\{0,1\}\([^"]*\).*/\1/p' "$y" | head -n1)
    if [ -n "$NAME" ] && docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
      holder=$(docker inspect "$NAME" -f '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null || true)
      if [ "$holder" = "$COMPOSE_PROJECT_NAME" ] || [ -z "$holder" ]; then
        docker rm -f "$NAME" 2>/dev/null || true
        echo "      removed $y's container ($NAME)"
      else
        echo "      $y's name $NAME is held by another project ($holder); left for its own uninstall"
      fi
    fi
  done
else
  echo "      no yml in $YDIR — nothing to bring down (the tier was never installed?)"
fi

# ---- [2/4] the WSL runtime area ----
# The distro's only claim on this model: the JIT cache + the boot log
# (the install staged it). The tree's own folders — the ymls, the
# config files, the weights, the patches — live on the Windows side and
# are never touched here.
echo "[2/4] the WSL runtime area (the JIT cache + the boot log; the"
echo "      tree's folders stay on the Windows side)"
if [ -d "$RTDIR" ]; then
  rm -rf "$RTDIR"
  echo "      removed: $RTDIR"
else
  echo "      nothing to remove ($RTDIR is not present)"
fi

# ---- [3/4] images ----
echo "[3/4] images (the tag the package ymls name, if present)"
IMG=$(grep -h -E '^[[:space:]]*image: vllm/vllm-openai:' "$YDIR"/*.yml 2>/dev/null | sed -E 's/^[[:space:]]*image:[[:space:]]*//' | LC_ALL=C sort -u | head -n1)
[ -n "$IMG" ] || IMG=$(sed -n 's/.*image:.*${VLLM_IMAGE:-\([^}]*\)}.*/\1/p' "$YDIR"/*.yml 2>/dev/null | LC_ALL=C sort -u | head -n1)
if [ -n "$IMG" ]; then
  # per-version refcount: prune only if no OTHER model's package ymls still name
  # this exact tag; otherwise the shared image outlives this model (the box-level
  # uninstall-all.bat prunes it when the last referencing model is gone).
  refs=$(grep -l -F "$IMG" "$SRC"/*/vllm/package/*.yml 2>/dev/null | grep -v "/$MODEL/vllm/package/" | wc -l)
  if docker image inspect "$IMG" >/dev/null 2>&1; then
    if [ "$refs" -eq 0 ]; then
      docker rmi "$IMG" 2>/dev/null || true
      echo "      removed: $IMG (no other model references it)"
    else
      echo "      kept: $IMG ($refs other model(s) still name it; uninstall-all.bat prunes it last)"
    fi
  else
    echo "      not present: $IMG (nothing to remove)"
  fi
else
  echo "      no image line in $YDIR/*.yml - nothing to remove"
fi

# ---- [4/4] report ----
echo "==================================================================="
echo " WSL side done. The Windows-side model folder (the package templates,"
echo " the machine deltas, the weights, the patches) is yours - the bat"
echo " removes it if you confirm, and a re-install of the model re-runs the"
echo " wizard; it never copies your weights back from anywhere."
echo "==================================================================="
exit 0
