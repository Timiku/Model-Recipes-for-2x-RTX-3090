#!/usr/bin/env bash
# tierenv.sh - the one precedence rule for tier config files.
#
# Emits the ordered file list for a tier: the tracked shipping default
# (<tier>.env) first, then the box's local override (<tier>.local.env) when it
# exists. Local wins: the .local.env layer is this box's machine truth
# (DEVICE_PAIR, PORT, WEIGHTS_DIR, per-box tuning), gitignored, never shipped.
# A shipping-default change to the tracked .env cannot re-pin a box's
# hardware - the t34 lesson (cebb30d re-pinned the dev rig onto its display
# card through exactly that hole).
#
# Usage: FILES=$(tierenv.sh <path/to/vllm> <tier>)   # absolute paths, LF note
#        for f in $FILES; do ...; done
# Every reader of a tier's config MUST go through this helper - not its own
# sed/source of the bare .env - so there is one precedence rule, not four
# hand copies. All readers must be CRLF-safe: local files are created on the
# Windows side and .gitattributes eol=lf does not cover untracked files.
# (up.sh sources from _env_lf temp copies; down.sh must do the same; the
# arm-probe sed in serve.sh reads the emitted list in order, last match wins.)
#
# Precedence: LAST file emitted wins (up.sh sources in emitted order and
# passes --env-file in emitted order; compose later --env-file wins, and the
# shell source order matches).

set -eu
DIR=${1:?usage: tierenv.sh <vllm-dir> <tier>}
TIER=${2:?usage: tierenv.sh <vllm-dir> <tier>}

BASE="$DIR/$TIER.env"
LOCAL="$DIR/$TIER.local.env"

[ -f "$BASE" ] || { echo "tierenv: no base env $BASE" >&2; exit 1; }
printf '%s\n' "$BASE"
[ -f "$LOCAL" ] && printf '%s\n' "$LOCAL"
# nothing after this line: local must be last
