#!/usr/bin/env bash
# up.sh — the boot brain of model-recipes. A start-*.bat calls this with:
#
#   bash <repo>/_shared/scripts/up.sh <model> <tier> [extra-env-file]
#
# It brings up one model's vLLM tier and waits for the served model to
# answer a probe before it returns. The same brain backs every backend:
# the llama.cpp / ik_llama.cpp bats shell out to plain CLI tools, the
# vllm bats shell into here. Two-tier config: the tier's package template
# (vllm/package/<tier>.yml) is the compose project and the provenance anchor;
# the box's machine .env (vllm/<tier>.env, beside the bats) overrides
# it key-by-key and is the only knob source. Both live in the Windows-side
# tree and are read in place; the WSL distro holds only the runtime area (the
# JIT cache + the boot log), staged once at install.
#
#   1. The card gate: the yml's own pin (CUDA_VISIBLE_DEVICES=...) is the
#      contract. If the bat passed no explicit pair, this preflight
#      refuses to boot when any pinned card holds more than 4 GiB of
#      foreign VRAM (the >1 GiB threshold of the earlier draft is dead:
#      the WSL2/WDDM baseline alone is ~1.4 GiB/card, so a 1 GiB cutoff
#      refused its own healthy stack and a boot that never got the
#      nvidia-smi probe). The gate is a state machine, not a two-state
#      check: it polls nvidia-smi every GATE_TICK seconds (5 by default,
#      overridable via env for the test suite) and distinguishes two
#      busy shapes — a card that is SHEDding usage (a just-stopped tier
#      draining) keeps a 12-tick stable counter reset every time its
#      usage drops, so a draining card is never mistaken for a live
#      occupant, and a card that holds its level for 12 straight ticks is
#      REFUSED with the verdict. The gate waits at most
#      UP_CARD_DRAIN_TIMEOUT seconds (900 by default; the machine .env
#      may raise it with UP_CARD_DRAIN_TIMEOUT=<n> for a
#      heavy model's long drain) before giving up as DRAIN-TIMEOUT —
#      that is the "the previous tier will never die on this box" case,
#      and the verdict says so instead of hanging.
#   2. The card release: compose -f <yml> down --remove-orphans, with
#      the yml's container_name read off the file so an orphan
#      container from a previous run that still holds the tier's NAME is
#      removed before the up (the yml is the source of truth for the
#      name, not this script).
#   3. The boot: docker compose --env-file <tier>.env -f <package yml> up -d.
#      The package template's every machine-tunable value is a
#      ${VAR:-default} interpolation; the box's vllm/<tier>.env (plain
#      docker compose .env format, beside the bats) is sourced into this
#      shell's environment AND passed to compose via --env-file, so those
#      forms interpolate to the box's real values at compose time; no default
#      lives in this script, only in those ${VAR:-...} forms.
#   4. The generation probe: the yml's own PORT, with a 600 s cap on the
#      whole wait — the window that shows the verdict is the window that
#      closes, and a model that is not ready in ten minutes is not
#      going to be ready in ten hours. On a cold start, vLLM's first
#      JIT compile is the usual long pole; the timeout exists to bound
#      that, not to second-guess a slow box.
#
#   The WSL side of the boot: the yml's relative mounts (the weights,
#   the patch set, the templates, detect_nvlink.sh — all in this model's
#   own tree, under vllm/) resolve against the yml's own directory, and
#   this script cds into that directory before the compose call, so the
#   yml is read from the tree it was copied from, not from any mirror.
#   The one WSL-side hold is the JIT cache (the torch_compile / triton
#   bind under ${HOME}/model-recipes-rt/<model>/cache/), which the
#   container's entrypoint writes on first boot and reuses on the
#   next: it stays in the distro so the first boot's JIT does not
#   re-run, and the boot log (below) lands in the same runtime area.
#
#   Verdicts land in three places, in order of immediacy: the console
#   (the line the operator reads), a per-run status file, and — for
#   boot failures — a full-container-log append. The status file is
#   fresh per boot (it carries this run's verdict, not the history's),
#   so a start bat can grep it for the reason a boot failed and
#   re-prompt for a retry without re-reading a log that also contains
#   yesterday's failure. The boot log itself accumulates in the WSL
#   runtime area, one file per model, across boots:
#     ${MODEL_RECIPES_RT:-$HOME/model-recipes-rt}/<model>/boot-failure.log
#   (overridable for the test suite via MODEL_RECIPES_RT; the default
#   base is the same $HOME/model-recipes-rt base the install stages,
#   and this script only ever writes boot-failure.log into it — it
#   never stages anything else, the install does that.)
#   boot-last-status lives beside it in the same area and is the
#   per-run file (see above).
set -e

if [ $# -lt 2 ]; then
  echo "usage: $0 <model> <tier> [extra-env-file]" >&2
  exit 2
fi

MODEL=$1
TIER=$2
EXTRA=${3:-}
SRC=${MODEL_RECIPES_SRC:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}
# Two-tier config: vllm/package/<tier>.yml is the full package default (every
# machine-tunable value a ${VAR:-default} interpolation); the box's
# vllm/<tier>.env (beside the bats, plain docker compose .env format) is
# sourced into this shell's env and passed to compose via --env-file, so the
# package yml's ${KEY} forms (ports, volumes, the command's --flags, the
# container env) resolve to the box's values. A new tier is one package
# yml + one .env, no more.
PKGDIR=$SRC/$MODEL/vllm/package
YML=$PKGDIR/$TIER.yml
YMLBASE=$TIER.yml
CFG=$SRC/$MODEL/vllm/$TIER.env
ROOT=${MODEL_RECIPES_RT:-$HOME/model-recipes-rt}/$MODEL
cd "$PKGDIR"

# The runtime area (the distro's only claim on this model: JIT cache + boot log) is
# created up front so the very first verdict write can land; a failed mkdir must not
# kill the script - the echo in the window is the source of truth, the log is the
# record for the bat's box.
mkdir -p "$ROOT" 2>/dev/null || true

# Read the machine .env into this shell's env (plain KEY=value,
# shell-sourceable) so the package yml's ${KEY} interpolations take the box's
# values; a stance/EXTRA file, when given, overrides the .env for this boot.
# CRLF-safe: source from a temp LF copy. These files are edited on the
# Windows side (mcfg-set, hand edits) and a CRLF line puts a literal \r into
# every value ('BIND_HOST=0.0.0.0\r' -> compose 'invalid IP address').
_env_lf() { sed 's/\r$//' "$1" > "$ROOT/.env.lf.$$"; echo "$ROOT/.env.lf.$$"; }
_LF=$(_env_lf "$CFG"); set -a; [ -f "$_LF" ] && . "$_LF" 2>/dev/null; set +a; rm -f "$_LF"
if [ -n "$EXTRA" ]; then
  [ -f "$EXTRA" ] || { echo "[up] FATAL: no extra env file $EXTRA" >&2
    echo "[up] $(date -u '+%F %T') FATAL: no extra env file $EXTRA" >> "$ROOT/boot-failure.log" 2>/dev/null || true
    exit 1; }
  _LF=$(_env_lf "$EXTRA"); set -a; . "$_LF"; set +a; rm -f "$_LF"
  echo "[up] stance: $EXTRA (its vars override the .env for this boot)"
fi
ENVF=$CFG

[ -f "$YML" ] || { echo "[up] FATAL: no $YML (the tree should carry this file - is this a complete copy of the package?)" >&2
  echo "[up] $(date -u '+%F %T') FATAL: no $YML (the tree should carry this file - is this a complete copy of the package?)" >> "$ROOT/boot-failure.log" 2>/dev/null || true
  exit 1; }

PORT="${PORT:-8113}"
NAME=$(sed -n 's/.*container_name:[[:space:]]*"\{0,1\}\([^"]*\).*/\1/p' "$YML" | head -n1)
MODEL_NAME=$(grep -A1 -- '--served-model-name' "$YML" | sed -n '2p' | sed 's/^[[:space:]]*-[[:space:]]*//; s/[[:space:]]*$//' || true)
# Wrapper-based ymls (flash-next) carry the name as an env var, not a flag
# pair - the generation probe must send the registered name or it 404s.
[ -n "$MODEL_NAME" ] || MODEL_NAME=${SERVED_MODEL_NAME:-}
# The card gate judges the pair the machine .env exports (PCI bus order); the
# package yml's own ${DEVICE_PAIR:-0,1} default is the fallback if it set none.
CARDS="${DEVICE_PAIR:-0,1}"

if [ -n "$CARDS" ]; then
  IFS=',' read -ra CARD_ARR <<< "$CARDS"
  # The gate reads nvidia-smi itself, pinned to this tier's cards: every
  # query below carries --id="$CARDS", so only the selected GPUs are
  # asked - and only they are printed, logged, or judged. A just-cold-
  # started WSL VM - or a degraded init (the 'mount -a failed' line at the
  # top of the window is the tell; a broken fstab line causes it) - may not
  # answer yet: retry briefly, and when it still does not, say so. The
  # old shape died here under set -e with no output at all (the silent
  # refusal).
  NSMI_RC=0
  NSMI=$(nvidia-smi --id="$CARDS" --query-gpu=index,memory.used --format=csv,noheader,nounits 2>&1) || NSMI_RC=$?
  tries=1
  while { [ "$NSMI_RC" -ne 0 ] || [ -z "$NSMI" ]; } && [ "$tries" -le 5 ]; do
    sleep 5
    NSMI_RC=0
    NSMI=$(nvidia-smi --id="$CARDS" --query-gpu=index,memory.used --format=csv,noheader,nounits 2>&1) || NSMI_RC=$?
    tries=$((tries + 1))
    echo "[up] nvidia-smi not answering yet (rc=$NSMI_RC) - retry $tries of 5, 5 s apart..."
  done
  if [ "$NSMI_RC" -ne 0 ] || [ -z "$NSMI" ]; then
    { echo "[up] $(date -u '+%F %T') FATAL: nvidia-smi not answering (rc=$NSMI_RC) - the WSL GPU"
      echo "    stack is not up (a degraded cold start). Raw output:"
      echo "$NSMI"
    } >> "$ROOT/boot-failure.log" 2>/dev/null || true
    echo "[up] FATAL: nvidia-smi is not answering (rc=$NSMI_RC) - the WSL GPU stack is not up."
    echo "    If the top of the window shows 'mount -a failed', the fstab is still broken -"
    echo "    fix that line first: a degraded init half-loads the nvidia driver."
    echo "    Raw nvidia-smi output:"
    echo "$NSMI" | sed 's/^/      /'
    exit 1
  fi
  echo "[up] card gate - nvidia-smi reports:"
  echo "$NSMI" | sed 's/^/      /'

  # The drain state machine. A busy card that sheds more than 256 MiB
  # between ticks is DRAINING (reset its stable counter and keep waiting);
  # one that does not is one tick closer to the REFUSED verdict. GATE_TICK
  # (env, tests only) shortens the tick; the real default is 5 s.
  THRESH=4000
  STABLE_TICKS=12
  DRAIN=900
  [ -f "$ENVF" ] && DRAIN=$(sed -n "s/^[[:space:]]*UP_CARD_DRAIN_TIMEOUT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$ENVF" | head -n1)
  [ -n "$DRAIN" ] || DRAIN=900
  TICK=${GATE_TICK:-5}
  declare -a PREV STABLE
  for i in "${!CARD_ARR[@]}"; do PREV[$i]=""; STABLE[$i]=0; done
  gate_wait=0
  while :; do
    NSMI_RC=0
    NSMI=$(nvidia-smi --id="$CARDS" --query-gpu=index,memory.used --format=csv,noheader,nounits 2>&1) || NSMI_RC=$?
    if [ "$NSMI_RC" -ne 0 ] || [ -z "$NSMI" ]; then
      { echo "[up] $(date -u '+%F %T') FATAL: nvidia-smi stopped answering mid-gate (rc=$NSMI_RC)"
        echo "    raw nvidia-smi:"
        echo "$NSMI"
      } >> "$ROOT/boot-failure.log" 2>/dev/null || true
      echo "[up] FATAL: nvidia-smi stopped answering mid-gate (rc=$NSMI_RC) - the WSL GPU stack died under us."
      exit 1
    fi
    allclear=1
    refused=""
    for i in "${!CARD_ARR[@]}"; do
      c=${CARD_ARR[$i]}
      used=$(awk -F', ' -v w="$c" '$1 == w { print $2 }' <<< "$NSMI")
      [ -n "${used:-}" ] || continue
      if [ "$used" -le "$THRESH" ]; then
        PREV[$i]="$used"; STABLE[$i]=0
        continue
      fi
      allclear=0
      if [ -n "${PREV[$i]}" ] && [ $(( ${PREV[$i]} - used )) -gt 256 ]; then
        STABLE[$i]=0
      else
        STABLE[$i]=$(( STABLE[$i] + 1 ))
      fi
      PREV[$i]="$used"
      if [ "${STABLE[$i]}" -ge "$STABLE_TICKS" ]; then
        refused="$refused card$c=${used}MiB(held-stable)"
      elif [ $(( (STABLE[$i] - 1) % 6 )) -eq 0 ]; then
        echo "[up] gate: card$c=${used}MiB, still shedding (stable ${STABLE[$i]}x${TICK}s of ${STABLE_TICKS}x${TICK}s) - a just-stopped tier is being waited out"
      fi
    done
    if [ "$allclear" -eq 1 ]; then
      echo "[up] cards clear - proceeding."
      break
    fi
    if [ -n "$refused" ]; then
      { echo "[up] $(date -u '+%F %T') REFUSED: GPU(s) held stable-above ${THRESH} MiB:$refused"
        echo "    raw nvidia-smi:"
        echo "$NSMI"
      } >> "$ROOT/boot-failure.log" 2>/dev/null || true
      echo "[up] REFUSED: GPU(s) held stable-above ${THRESH} MiB:$refused"
      echo "[up] (a live tier is up on the $CARDS pin; stop it - its stop.bat - then re-run this bat)"
      exit 1
    fi
    gate_wait=$((gate_wait + TICK))
    if [ "$gate_wait" -ge "$DRAIN" ]; then
      { echo "[up] $(date -u '+%F %T') DRAIN-TIMEOUT: cards still busy after ${gate_wait}s of waiting (raw table below)"
        echo "    raw nvidia-smi:"
        echo "$NSMI"
      } >> "$ROOT/boot-failure.log" 2>/dev/null || true
      echo "[up] DRAIN-TIMEOUT: the cards were still shedding a just-stopped tier's VRAM after ${gate_wait}s."
      echo "[up] (re-run this bat once nvidia-smi shows the pin below ${THRESH} MiB; if it never does,"
      echo "     a killed process is holding a zombie context - check the nvidia-smi process table)"
      exit 1
    fi
    sleep "$TICK"
  done
else
  echo "[up] NOTE: no derivable card pin in $YML; the preflight is skipped" >&2
fi

# The card release. A "down" of this tier is exactly the two-file project: the
# package template plus the machine .env (--env-file), which names the
# container. --remove-orphans also sweeps a container the yml's container_name
# still claims but the project no longer lists (a renamed yml, an old run under
# the old name). The .env's values are also in this shell's env, so the
# ${KEY} forms interpolate identically on either path.
ENVC=()
[ -f "$CFG" ] && ENVC=(--env-file "$CFG")
CF=(-f "$YMLBASE")
docker compose "${ENVC[@]}" "${CF[@]}" down --remove-orphans --timeout 60 2>/dev/null || true

# The tier's NAME can still be held by a container of another compose
# project - a boot from before this layout (the yml's provenance header
# names the contract; it retires when this boot replaces it). The compose
# down above only clears this project. Remove whatever claims the name,
# guarded to the exact name, so a replacement boot never collides.
if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
  echo "[up] removing leftover container $NAME (held by another project)"
  docker rm -f "$NAME"
fi

echo "[up] starting $NAME (port $PORT, model $MODEL_NAME)..."
UP=0
docker compose "${ENVC[@]}" "${CF[@]}" up -d || UP=1
if [ "$UP" != 0 ]; then
  # set -e would die here without a trace: on a just-cold-started WSL VM the
  # usual cause is the nvidia runtime not ready yet (look for the
  # 'Processing /etc/fstab with mount -a failed' line at the top of the window -
  # a broken fstab line degrades the cold start).
  { echo "[up] $(date -u '+%F %T') compose up -d FAILED before container creation"
    echo "    the docker error printed above is the verdict"
  } >> "$ROOT/boot-failure.log" 2>/dev/null
  { echo "RUN=$(date -u '+%F %T')"
    echo "VERDICT=COMPOSE-FAILED"
    echo "    the docker error above is the verdict"
  } > "$ROOT/boot-last-status" 2>/dev/null || true
  if ! docker compose version >/dev/null 2>&1; then
    echo "[up] this docker has no compose plugin."
    echo "    On an Ubuntu distro:  sudo apt update && sudo apt install -y docker-compose-v2"
    echo "    then re-run this bat. (docker --version / docker compose version name the build.)"
  else
    echo "[up] compose up -d failed (the docker error is above); if the top"
    echo "    of the window shows the cold-WSL 'mount -a failed' line, re-run"
    echo "    the start bat once - the second attempt finds a warm VM."
  fi
  exit 1
fi

# The log tail and the WDDM watch run in parallel. The tail is the
# operator's window into the boot (docker logs -f, Ctrl-C detaches);
# the watch is the box's WDDM accounting for the whole boot, one
# line every 2 s of Committed_AS, MemCommitLimit, CommitLimit
# against the kernel's CommitLimit, and MemAvailable. The 401's two
# remaining candidates (the commit wall; the RAM-pressure dxgk fault) are
# both readable off $ROOT/commit-trace after any outcome.
: > "$ROOT/commit-trace"
( while :; do
    echo "$(date '+%H:%M:%S') $(grep -E '^(MemAvailable|Committed_AS):' /proc/meminfo | awk '{printf "%s=%s ", $1, $2}')" >> "$ROOT/commit-trace"
    sleep 2
  done
  ) &
TRACEPID=$!
teardown() { kill "$LOGPID" 2>/dev/null || true; kill "$TRACEPID" 2>/dev/null || true; }
trap teardown EXIT
fail() {
  echo "[up] BOOT FAILED:"
  docker logs --tail 40 "$NAME" 2>/dev/null || true
  # The window that showed the tail is the one that closes: the full
  # container log is persisted to the WSL runtime area for post-mortem.
  docker logs "$NAME" >> "$ROOT/boot-failure.log" 2>/dev/null \
    || echo "[up] (the container log could not be captured)"
  echo "[up] full container log: $ROOT/boot-failure.log (the WSL side)"
  # Per-run status for the start bat: this run's verdict + the last real
  # error lines. boot-failure.log is cumulative across runs, so a bat
  # grep against it matches yesterday's failure; this file is fresh.
  { echo "RUN=$(date -u '+%F %T')"
    echo "VERDICT=BOOT-FAILED"
    docker logs "$NAME" 2>/dev/null | grep -E 'ERROR|OutOfMemory' | tail -n 3
  } > "$ROOT/boot-last-status" 2>/dev/null || true
  exit 1
}

# The probe window: 600 s by default; the tier's config file may raise it
# (UP_PROBE_TIMEOUT) when a heavy model's first boot runs longer.
PROBE=600
[ -f "$ENVF" ] && PROBE=$(sed -n "s/^[[:space:]]*UP_PROBE_TIMEOUT[[:space:]]*=[[:space:]]*'\{0,1\}\([0-9][0-9]*\)'\{0,1\}.*/\1/p" "$ENVF" | head -n1)
[ -n "$PROBE" ] || PROBE=600
echo "[up] waiting for http://localhost:${PORT}/v1/models (timeout ${PROBE}s)..."
ready=0
for ((i = 0; i < $PROBE; i++)); do
  st=$(docker inspect --format '{{.State.Status}}' "$NAME" 2>/dev/null || true)
  if [ "$st" = "exited" ] || [ "$st" = "dead" ]; then fail; fi
  if curl -sf "http://localhost:${PORT}/v1/models" >/dev/null 2>&1; then
    if curl -sf -m 90 "http://localhost:${PORT}/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"${MODEL_NAME}\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}" \
        >/dev/null 2>&1; then
      echo "[up] generation probe ok — READY (${i}s)"
      ready=1
      break
    fi
  fi
  sleep 1
done

trap - EXIT
teardown
if [ "$ready" != 1 ]; then
  echo "[up] TIMEOUT after ${PROBE} s waiting for ready:"
  docker logs --tail 40 "$NAME" 2>/dev/null || true
  docker logs "$NAME" >> "$ROOT/boot-failure.log" 2>/dev/null \
    || echo "[up] (the container log could not be captured)"
  echo "[up] full container log: $ROOT/boot-failure.log (the WSL side)"
  { echo "RUN=$(date -u '+%F %T')"
    echo "VERDICT=BOOT-TIMEOUT"
    docker logs "$NAME" 2>/dev/null | grep -E 'ERROR|OutOfMemory' | tail -n 3
  } > "$ROOT/boot-last-status" 2>/dev/null || true
  exit 1
fi
if [ "$ready" = 1 ]; then
  { echo "RUN=$(date -u '+%F %T')"
    echo "VERDICT=READY"
    echo "MODEL=$MODEL_NAME PORT=$PORT"
  } > "$ROOT/boot-last-status" 2>/dev/null || true
fi
