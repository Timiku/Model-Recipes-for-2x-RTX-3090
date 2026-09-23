#!/usr/bin/env bash
# serve.sh — boot a tier and tail its logs (a start bat calls this):
#   bash _shared/scripts/serve.sh <model> <tier> [extra-env-file]
#
# Two-tier: up.sh reads the package template (vllm/package/<tier>.yml) with the
# box's machine .env (vllm/<tier>.env, beside the bats) via --env-file, then
# tails the container's log. The WSL side holds only what a run produces (the
# JIT cache + the boot log) — the install staged that once; the yml and the
# machine .env live in the Windows-side tree and are read in place.
set -e

if [ $# -lt 2 ]; then
  echo "usage: $0 <model> <tier> [extra-env-file]" >&2
  echo "  e.g. $0 qwen3.8-27b mtp" >&2
  exit 2
fi

MODEL=$1
TIER=$2
EXTRA=${3:-}
SRC=${MODEL_RECIPES_SRC:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}
YML=$SRC/$MODEL/vllm/package/$TIER.yml
# The WSL runtime area: this model's folder under the canonical base
# (overridable via MODEL_RECIPES_RT, tests only) — the boot log lives there.
ROOT=${MODEL_RECIPES_RT:-$HOME/model-recipes-rt}/$MODEL

# ---- the arm probe (before the boot, before the watchdog arms) ----------
# The WSL2 nvidia driver re-arms each card's device state when the last
# CUDA user exits; a boot inside that window dies on its first real
# allocation - "CUDA driver error: device not ready". Models whose image
# carries /usr/local/bin/arm-probe.py (the flash-next locked image) get a
# throwaway-container probe on the tier's pinned pair first: the act of
# arming IS the fix. Other models' images lack the probe - skipped, no
# behavior change. The pair comes off the machine .env, the same key the
# yml interpolates; the default matches the yml seed.
CFGE=$SRC/$MODEL/vllm/$TIER.env
PAIR=$(sed -n "s/^DEVICE_PAIR=//p" "$CFGE" 2>/dev/null | head -n1 | sed "s/^['\"]//; s/['\"]\$//")
PAIR=${PAIR:-0,1}
IMG=$(sed -n 's/.*image:.*{VLLM_IMAGE:-\([^}]*\)}.*/\1/p' "$YML" | head -n1)
IMG=${IMG:-$(sed -n 's/.*image:[[:space:]]*"\{0,1\}\([^"]*\).*/\1/p' "$YML" | head -n1)}
if [ -n "$IMG" ] && docker image inspect "$IMG" >/dev/null 2>&1; then
  echo "[serve] arm probe: the pinned pair $PAIR, throwaway container"
  if docker run --rm --gpus all \
      -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
      -e CUDA_VISIBLE_DEVICES="$PAIR" \
      --entrypoint bash "$IMG" -c 'test -f /usr/local/bin/arm-probe.py' 2>/dev/null; then
    if ! docker run --rm --gpus all \
        -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
        -e CUDA_VISIBLE_DEVICES="$PAIR" \
        --entrypoint python3 "$IMG" /usr/local/bin/arm-probe.py; then
      echo "[serve] arm probe: the cards did not arm - the WSL GPU stack is"
      echo "        still recovering. Wait a minute, then re-run the bat."
      exit 1
    fi
  fi
fi


if ! bash "$SRC/_shared/scripts/up.sh" "$MODEL" "$TIER" "$EXTRA"; then
  echo
  echo "[serve] the boot ended without a ready tier; the verdict is above"
  echo "        (the full log: $ROOT/boot-failure.log, the WSL side)"
  exit 1
fi

NAME=$(sed -n 's/.*container_name:[[:space:]]*"\{0,1\}\([^"]*\).*/\1/p' "$YML" | head -n1)
if [ -z "$NAME" ]; then
  NAME=$TIER
fi

echo
echo "[serve] $NAME is up; tail its log (Ctrl-C detaches, the container keeps running):"
echo

# The container can take a few seconds before its first stdout line
# appears in docker's log stream (the vLLM entrypoint prints its banner
# after the arg-parsing phase). Poll briefly so a healthy boot that just
# has not flushed yet is not misread as a silent death — the same
# 'Processing /etc/fstab with mount -a failed' degraded cold-start that
# the up.sh preflight waits out is the usual cause, and a second run of
# this bat against the same tier succeeds without any of this.
for _i in 1 2 3 4 5; do
  first=$(docker logs --tail 1 "$NAME" 2>/dev/null | head -n1)
  if [ -n "$first" ]; then break; fi
  sleep 1
done
if [ -n "$first" ]; then
  echo "$first"
fi
if [ -n "$first" ]; then
  docker logs -f "$NAME"
else
  echo "(no container output captured yet; the docker logs follow - if this"
  echo " stays silent, the WSL VM is probably still cold-starting; re-run"
  echo " this bat once)"
  docker logs -f "$NAME"
fi
