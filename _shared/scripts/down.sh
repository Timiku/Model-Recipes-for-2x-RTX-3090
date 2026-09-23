#!/usr/bin/env bash
# down.sh — the stop brain of model-recipes. A stop.bat calls this with:
#
#   bash <repo>/_shared/scripts/down.sh <model> [yml-basename]
#
# It brings the tier(s) down and verifies the release. The contract:
# the yml's container_name is the name the release looks for, so the
# name that has to be free is read off the yml file, not hardcoded here.
# A tier the pinned compose down cannot reach (a container of another
# project that still claims the name — a boot from before this layout,
# by design) is removed by the name directly, guarded to the exact
# name.
#
# The two-tier model: each tier's package template (vllm/package/<tier>.yml) is
# the compose project, and its machine .env (vllm/<tier>.env, one folder
# up beside the bats) is passed via --env-file, so the down tears down exactly the
# project up.sh booted. A tier the wizard never ran for boots with only the
# package template, and the compose then renders just that; the yml's
# ${VAR:-...} defaults are the config.

set -u

if [ $# -lt 1 ]; then
  echo "usage: $0 <model> [yml-basename]" >&2
  exit 2
fi

MODEL=$1
TARGET=${2:-}
SRC=${MODEL_RECIPES_SRC:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}
# The WSL runtime area (overridable for the test suite): the boot log
# lives here. The release check below only reads nvidia-smi, so the
# area is not needed for the check itself.
ROOT=${MODEL_RECIPES_RT:-$HOME/model-recipes-rt}/$MODEL
# The package templates (vllm/package/<tier>.yml) are read in place; the box's
# machine .envs are one folder up, beside the bats. The install staged nothing
# on the WSL side but the runtime area.
YMLROOT=$SRC/$MODEL/vllm/package
# The compose project name is the yml's own dir (package/), because that is where
# docker compose resolves the first -f from - the same project up.sh booted.
COMPOSE_PROJECT_NAME=$(basename "$YMLROOT")

if [ -n "$TARGET" ]; then
  # The tier may arrive as the bare stem (the up.sh convention: down.sh
  # qwen3.8-27b nomtp) or as the yml filename; normalize to the filename
  # so the file test below and the compose -f both see a real file.
  case "$TARGET" in
    *.yml) ;;
    *) TARGET="$TARGET.yml" ;;
  esac
  YMLS="$TARGET"
else
  YMLS=$(cd "$YMLROOT" && ls *.yml 2>/dev/null | LC_ALL=C sort)
fi

if [ -z "$YMLS" ]; then
  echo "[down] no yml for this recipe under $YMLROOT (the tree should carry it - is this a complete copy of the package?)"
  exit 1
fi
# The yml's own directory is the working directory (the same rule
# up.sh follows before its compose call): the bat hands this loop bare
# names, so the -f test and the compose -f in it must resolve them
# against the tree, not against wherever the Windows side stood when
# it launched.
cd "$YMLROOT"

rc=0
PORTS=""
# host_port <yml> <env>: the first ports: entry's host side, resolved
# through the tier .env (the line is shell syntax:
# "${BIND_HOST:-0.0.0.0}:${PORT:-8113}:8000"). A subshell contains the
# sourcing so one tier's knobs never leak into the next yml's resolve.
host_port() {
  local line
  line=$(awk '/^[[:space:]]*ports:/{f=1;next} f && /^[[:space:]]*-/{sub(/^[[:space:]]*-[[:space:]]*/,""); gsub(/"/,""); print; exit}' "$1")
  [ -n "$line" ] || return 0
  ( set -a; [ -f "$2" ] && . "$2" 2>/dev/null; set +a; eval "SPEC=$line" 2>/dev/null; echo "${SPEC:-}" ) \
    | rev | cut -d: -f2 | rev
}
for y in $YMLS; do
  if [ ! -f "$y" ]; then
    echo "[down] $y: not found in the tree ($YMLROOT) — not stopped."
    rc=1
    continue
  fi
  NAME=$(sed -n 's/.*container_name:[[:space:]]*"\{0,1\}\([^"]*\).*/\1/p' "$y" | head -n1)
  # The two-file project, exactly as up.sh booted it: the package yml plus
  # the machine .env (one folder up, beside the bats; the yml stem names
  # it). The compose project name is package/ - the first -f's dir - so
  # this tears down the project the up built, not a drifted copy.
  STEM=${y%.yml}
  CF=(-f "$y")
  CFG=$YMLROOT/../$STEM.env
  if [ -f "$CFG" ]; then
    # Compose renders inside the tier .env (--env-file, the same file up.sh
    # sources), contained in a subshell so one tier's knobs never leak
    # into the next yml's render; a failed stop prints its own error.
    if COUT=$( ( set -a; [ -f "$CFG" ] && . "$CFG" 2>/dev/null; set +a; docker compose --env-file "$CFG" "${CF[@]}" down --remove-orphans --timeout 60 ) 2>&1 ); then
      stopped="compose"
    else
      printf '%s\n' "$COUT" | sed 's/^/    /' >&2
    fi
  else
    if COUT=$(docker compose "${CF[@]}" down --remove-orphans --timeout 60 2>&1); then
      stopped="compose"
    else
      # A failed stop must never be silent: the error is the diagnosis.
      printf '%s\n' "$COUT" | sed 's/^/    /' >&2
    fi
  fi
  # Remember the host port for the release check (first ports: entry -
  # the API port; a tier's sidecar ports follow their container down).
  HP=$(host_port "$y" "$CFG")
  [ -n "$HP" ] && PORTS="$PORTS $HP"
  # The name catch, unconditional (see the header): the pinned compose down
  # above exits 0 when its project holds nothing, so a name-holder of
  # another project would sail through unreported. A name held by this
  # model's own project (package/) — or an old pre-rebase dir-name project —
  # is removed; a name held by any OTHER model's project is reported, not
  # removed: the cards it holds are not this model's to release, and the
  # release check below still counts them.
  # (the tier name is the container_name read off the yml, never a guess)
  if [ -n "$NAME" ] && docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
    holder=$(docker inspect "$NAME" -f '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null || true)
    case "$holder" in
      "$COMPOSE_PROJECT_NAME"|"")
        if docker rm -f "$NAME" 2>/dev/null; then
          [ -n "$stopped" ] && stopped="$stopped + "
          stopped="${stopped}direct $NAME (project: ${holder:-none})"
          echo "[down] $y: removed name-holder $NAME"
        else
          echo "[down] $y: $NAME survived a forced removal - docker inspect $NAME" >&2
          rc=1
        fi
        ;;
      *)
        # A drifted project label does not make the container foreign: if
        # its compose working_dir sits inside THIS model's tree, it is a
        # boot this tree made (an old layout or a renamed yml) and this
        # model owns its release. Anything else stays another model's.
        WD=$(docker inspect "$NAME" -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || true)
        case "$WD" in
          "$SRC/$MODEL"/*)
            if docker rm -f "$NAME" 2>/dev/null; then
              [ -n "$stopped" ] && stopped="$stopped + "
              stopped="${stopped}direct $NAME (project: ${holder:-none}, tree-owned)"
              echo "[down] $y: removed drifted name-holder $NAME (project: $holder, working_dir under this model)"
            else
              echo "[down] $y: $NAME survived a forced removal - docker inspect $NAME" >&2
              rc=1
            fi
            ;;
          *)
            echo "[down] $y: name $NAME is held by compose project '$holder' - not this model's project (${COMPOSE_PROJECT_NAME}); left alone"
            rc=1
            ;;
        esac
        ;;
    esac
  fi
  # The label sweep (the yml-name catcher above is not enough): a container
  # whose compose working_dir is this model's own package dir belongs to this
  # model whatever name it carries — a boot made from tree contents that
  # later drifted (a rename reverted after the boot) keeps its creation-time
  # name and would otherwise outlive every compose down and every name match.
  # docker ps --format has no label accessor ({{.Label "…"}} renders empty),
  # so each id is inspected for the working_dir label.
  for h in $(docker ps -aq --format '{{.ID}}' 2>/dev/null); do
    docker inspect "$h" >/dev/null 2>&1 || continue
    [ "$(docker inspect "$h" -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)" = "$YMLROOT" ] || continue
    if docker rm -f "$h" 2>/dev/null >/dev/null; then
      [ -n "$stopped" ] && stopped="$stopped + "
      stopped="${stopped}label-swept $h"
      echo "[down] $y: removed tree-owned holder $h (compose working_dir = $YMLROOT)"
    else
      echo "[down] $y: $h survived a forced removal - docker inspect $h" >&2
      rc=1
    fi
  done
  if [ -n "$stopped" ]; then
    echo "[down] $y: down ($stopped)."
  else
    echo "[down] $y: FAILED to stop — its container may still hold its port; check docker ps."
    rc=1
  fi
done

# The ports: the same "released" contract the cards have. A held port is
# invisible to docker ps (no container behind it) and surfaces at the
# NEXT boot as a refused bind - the silent failure this check names.
echo "[down] port release check:"
if [ -n "$PORTS" ]; then
  for P in $(printf '%s\n' $PORTS | tr ' ' '\n' | sort -u); do
    [ -n "$P" ] || continue
    if HIT=$(ss -ltn 2>/dev/null | grep ":$P " | head -1); [ -n "$HIT" ]; then
      echo "      port $P is STILL HELD: $HIT"
      echo "      (a listener in the distro; run this stop once more, or"
      echo "       'wsl --shutdown' clears the distro as the last resort)"
      rc=1
    else
      echo "      port $P clear."
    fi
  done
fi

# The GPU stack can answer with momentary zeros when it wakes from an idle
# WSL session (the same flap stop.bat retries for). Two samples five seconds
# apart, per-card max of the pair: a flap reads low once, the real holder
# reads high twice; an idle card's max is its real low value.
echo "[down] release check - what the cards report after the stop:"
S1=$(nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits 2>/dev/null) || S1=""
sleep 5
S2=$(nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits 2>/dev/null) || S2=""
if [ -n "$S1" ] && [ -n "$S2" ]; then
  MAXMEM=$(printf '%s\n%s\n' "$S1" "$S2" | awk -F', ' '{m[$1]=($1 in m && m[$1]>$2)?m[$1]:$2} END {for (i in m) print i", "m[i]}' | sort -n)
  echo "$MAXMEM"
  # A card still above the ~2 GiB headroom rule (a live tier on the
  # pin, or a zombie context) is the "not released" verdict.
  if echo "$MAXMEM" | awk -F', ' '$2 > 2048 { found=1 } END { exit !found }'; then
    echo "      a card is still above ~2 GiB - a tier is still up on it (or a"
    echo "      zombie context); docker ps names the holder."
    rc=1
  else
    echo "      all pinned cards below ~2 GiB — released."
  fi
else
  echo "      nvidia-smi is not answering (the WSL GPU stack is down); the"
  echo "      release cannot be checked. The containers are down if the"
  echo "      lines above say so; the cards clear on the next WSL start."
  rc=1
fi
exit "$rc"
