#!/usr/bin/env bash
# install-core.sh - the WSL half of a model's install.bat. The bat runs this
# runs this in the chosen distro (the Windows stage 0 verified the
# prereqs): env, the WSL runtime area, images, weights.
#
#   bash _shared/scripts/install-core.sh <model>
#
# Two-tier config, no mirror to sync: the package templates (vllm/package/
# <tier>.yml), the patch bundles, and the chat templates all live in the
# Windows-side tree (this folder's ancestor three up) and are read in place;
# the box's machine .envs (vllm/<tier>.env, one folder up beside the
# bats) carry the box's WEIGHTS_DIR / pin. This script reads (never writes)
# those deltas; [4/4] verifies the weights against whatever a delta names, and
# [5/5] refreshes the bump-aware INSTALL.json manifest. The WSL distro holds
# only what the container needs at runtime: the JIT-cache dir (staged once
# here) + the boot log.

set -u

if [ $# -lt 1 ]; then
  echo "usage: $0 <model>" >&2
  exit 2
fi

MODEL=$1
SRC=${MODEL_RECIPES_SRC:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}
SCRIPTS=$SRC/_shared/scripts
# The package templates (vllm/package/<tier>.yml) are the ymls this stages; the
# box's machine .envs (vllm/<tier>.env, beside the bats) are read, never
# written, here - the wizard owns those.
YDIR=$SRC/$MODEL/vllm/package
# mcfg_get KEY: the first non-empty value of KEY across the model's machine
# .envs (plain KEY=value, grep-read); empty if none set it.
mcfg_get() {
  local k=$1 f v
  for f in "$YDIR/.."/*.env; do
    [ -f "$f" ] || continue
    v=$(grep -m1 "^$k=" "$f" 2>/dev/null | sed "s/^$k=//")
    case $v in
      \"*\") v=${v#\"}; v=${v%\"} ;;
      \'*\') v=${v#\'}; v=${v%\'} ;;
    esac
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done
  return 1
}

# INSTALL.json: the per-model install manifest (the bump-aware record). It lives
# in the model's vllm/ dir (Windows side, written through the 9p mount). A
# re-run diffs the recorded image version against the package's current one: a
# version change clears the JIT cache below (it is version-specific), and the
# end-of-run refresh rewrites the manifest with the current template shas.
INSTALL_JSON=$YDIR/../INSTALL.json
OLD_IMG=""
if [ -f "$INSTALL_JSON" ]; then
  OLD_IMG=$(sed -n 's/.*"vllm_image"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$INSTALL_JSON" | head -n1)
fi

echo "==================================================================="
echo " model-recipes install — $MODEL"
echo " expect: image pulls dominate (30–90 min), then weight verification"
echo "==================================================================="

echo "[1/5] environment (docker, the nvidia runtime, the compose plugin)"
# The distro's docker + nvidia runtime + compose plugin. The Windows
# stage 0 already checked each and told the user which are missing; this
# is the backstop that installs the missing ones. The install runs as
# root when the bat's wsl -u root channel is available (no password, no
# admin rights); a non-root shell without that channel prints the manual
# command instead of dying silently.
if ! command -v docker >/dev/null 2>&1 || ! docker info 2>/dev/null | grep -q 'nvidia'; then
  echo "      docker or the nvidia runtime is missing - the root channel"
  echo "      (wsl -u root: no password, no Windows admin rights)..."
  if [ "$(id -u)" -eq 0 ]; then
    bash "$SCRIPTS/env-setup.sh"
  elif [ -x /mnt/wsl/wsl.exe ] && [ -n "${WSL_DISTRO_NAME:-}" ]; then
    /mnt/wsl/wsl.exe -d "${WSL_DISTRO_NAME}" -u root -- bash "$SCRIPTS/env-setup.sh"
  else
    echo "      no root channel from here; the wizard's Windows side drives"
    echo "      it as: wsl -d <distro> -u root -- bash <repo>/_shared/scripts/"
    echo "      env-setup.sh - run that, then re-run this stage."
  fi
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "      FATAL: docker still missing after the root-channel attempt."
  echo "      Manual: wsl -d <distro> -u root -- bash <repo>/_shared/scripts/"
  echo "      env-setup.sh  (no password, no Windows admin rights needed)"
  echo "      (WSL2 + the nvidia-container-toolkit checklist: the wizard's"
  echo "      Windows stage 0 told you if any were missing)"
  exit 1
fi
echo "      ok"

# ---- [2/4] the WSL runtime area ----
# The distro's only claim on this model. The install stages it once:
# the JIT-cache dir (the container's entrypoint fills it on first boot;
# the next boot reuses it, which is why the dir lives in the distro -
# the weights/patches/templates side of the yml's mounts never leaves
# the Windows tree) and the boot log up.sh appends to. Nothing else in
# the tree is mirrored, and nothing here is edited by the boot.
echo "[2/5] the WSL runtime area (the JIT cache + the boot log - the"
echo "      only thing this model ever has in the distro)"
RTBASE=${MODEL_RECIPES_RT:-$HOME/model-recipes-rt}
RTDIR=$RTBASE/$MODEL
if [ -d "$RTDIR" ]; then
  echo "      present: $RTDIR (nothing to stage)"
else
  mkdir -p "$RTDIR/cache" && touch "$RTDIR/cache/.keep"
  echo "      staged: $RTDIR/cache (the torch_compile/triton JIT cache) + the"
  echo "               boot log"
fi

# ---- [3/4] images ----
# The tier's own ymls name the image in their env block (the ${VLLM_IMAGE:-...}
# default); the set of ymls in the recipe dir is the set of images to
# have. A re-run of this stage finds every named image already present
# and does no work.
echo "[3/5] images (the set named in the model's package ymls)"
YIMGS=""
for f in "$YDIR"/*.yml; do
  [ -f "$f" ] || continue
  img=$(grep -m1 -E '^[[:space:]]*image: vllm/vllm-openai:' "$f" 2>/dev/null | sed -E 's/^[[:space:]]*image:[[:space:]]*//')
  # modified-image recipes name a locally built tag via the ${VLLM_IMAGE:-tag}
  # form (the bat's build stage produces it; this stage only verifies it).
  [ -n "$img" ] || img=$(sed -n 's/.*image:.*${VLLM_IMAGE:-\([^}]*\)}.*/\1/p' "$f" | head -n1)
  [ -n "$img" ] && YIMGS="$YIMGS $img"
done
# dedupe per WORD (tier count must not read as a version change; sort -u
# alone compares lines and would keep the duplicates on one line)
YIMGS=$(printf '%s\n' $YIMGS | LC_ALL=C sort -u | paste -sd' ' -)
NEW_IMG=$YIMGS
if [ -n "$OLD_IMG" ] && [ -n "$NEW_IMG" ] && [ "$NEW_IMG" != "$OLD_IMG" ]; then
  echo "      image set changed ($OLD_IMG -> $NEW_IMG): clearing the JIT cache (it is version-specific)"
  rm -rf "$RTDIR/cache" 2>/dev/null
  if [ -d "$RTDIR/cache" ] && [ -n "$(ls -A "$RTDIR/cache" 2>/dev/null)" ]; then
    # The container writes the cache as root (uid 0); a plain-user rm cannot
    # clear it. Not fatal - the cache keys include the image version, so a
    # stale entry recompiles - but say the exact remedy, per the box scar.
    echo "      NOTE: some cache files are uid-0-owned and survived the clear."
    echo "            Harmless (the keys recompile), or clean fully with:"
    echo "              wsl -d <distro> -u root -- rm -rf $RTDIR/cache"
  fi
  mkdir -p "$RTDIR/cache" && touch "$RTDIR/cache/.keep"
fi
if [ -z "$YIMGS" ]; then
  echo "      no VLLM_IMAGE default found in $YDIR/*.yml — nothing to pull (the ymls were not copied? re-copy the model folder)."
else
  for im in $YIMGS; do
    if docker image inspect "$im" >/dev/null 2>&1; then
      echo "      present: $im"
    else
      echo "      pulling: $im (this is the long part)"
      docker pull "$im" || { echo "      FATAL: pull failed for $im"; exit 1; }
    fi
  done
fi

# ---- [4/4] weights ----
# The weights live in the Windows-side tree: the wizard writes each tier's
# WEIGHTS_DIR into that tier's machine .env (vllm/<tier>.env, one file
# per tier, beside the bats), defaulting to the model's own weights/ folder; a
# later re-run reads the standing line.
# A folder missing from WEIGHTS_DIR is fetched here (the
# model-specific weights-source.sh, if the model ships one) before the
# install reports ready.
echo "[4/5] weights"
# The machine delta is the live WEIGHTS_DIR / TARGET source (the wizard keeps the
# tier files in step, so any one is a fair sample); a missing value falls to the
# model's own weights/ folder in the tree.
WEIGHTS=$(mcfg_get WEIGHTS_DIR)
[ -n "$WEIGHTS" ] || WEIGHTS=$SRC/$MODEL/weights
TARGET=$(mcfg_get TARGET_MODEL)
[ -n "$TARGET" ] || TARGET=$(grep -h 'TARGET_MODEL' "$YDIR"/*.yml 2>/dev/null | grep -o '\${TARGET_MODEL:-[^}"]*' | sed 's/.*:-//' | grep -v '^[[:space:]]*$' | head -n1)
[ -n "$TARGET" ] || TARGET="?"
echo "      effective WEIGHTS_DIR: $WEIGHTS"
check_folder() { # $1=folder $2=what-it-is
  local dir=$1 what=$2
  if [ -f "$dir/MANIFEST.sha256" ]; then
    echo "      $what: $dir — verifying against its MANIFEST.sha256"
    if (cd "$dir" && sha256sum --check --quiet MANIFEST.sha256); then
      echo "        ok (manifest-verified)."
      return 0
    fi
    echo "        FAIL: manifest mismatch — re-provision this folder."
    return 1
  fi
  local n
  n=$(find "$dir" -name '*.safetensors' 2>/dev/null | wc -l)
  if [ -f "$dir/config.json" ] && [ "$n" -gt 0 ]; then
    echo "      $what: $dir — ok by shape (config.json + $n safetensors; no manifest shipped)."
    return 0
  fi
  echo "      $what: MISSING or unusable at $dir (need config.json + safetensors, or a MANIFEST.sha256)."
  return 1
}

rc=0
check_folder "$WEIGHTS/$TARGET" "target ($TARGET)" || rc=1

# the DFlash2 tier wants the drafter; the MTP-only install does not.
# The tier's config file wins (it is the file the user tunes); the yml
# default is the fallback — the passthrough form `${DRAFTER_MODEL:-}`
# extracts empty and is filtered, so the real default (the
# --speculative-config line) wins the sweep.
DRAFTER=$(mcfg_get DRAFTER_MODEL)
[ -n "$DRAFTER" ] || DRAFTER=$(grep -h 'DRAFTER_MODEL' "$YDIR"/*.yml 2>/dev/null | grep -o '\${DRAFTER_MODEL:-[^}"]*' | sed 's/.*:-//' | grep -v '^[[:space:]]*$' | head -n1)
if [ -n "$DRAFTER" ]; then
  case "$DRAFTER" in
    qwen3.8-27b-dflash2-w4a16)
      if ! check_folder "$WEIGHTS/$DRAFTER" "drafter ($DRAFTER)"; then
        echo "        source (documented): hf download syvai/Qwen3.8-27B-DFlash2-W4A16"
        echo "          --local-dir $WEIGHTS/$DRAFTER   (~1.2 GB; the uv+hf CLI"
        echo "          install is the old install_hf.sh pattern, or pip install 'huggingface-hub[hf_transfer]')"
        rc=1
      fi
      ;;
    *)
      if ! check_folder "$WEIGHTS/$DRAFTER" "drafter ($DRAFTER)"; then
        if [ -f "$YDIR/weights-source.sh" ]; then
          echo "      drafter: $DRAFTER — the model documents the source (vllm/package/weights-source.sh); the fetch follows below."
        else
          echo "      drafter: $DRAFTER — no documented download source for this model; provision the folder yourself, then re-run."
        fi
        rc=1
      fi
      ;;
  esac
fi

if [ $rc -ne 0 ]; then
  # A missing folder the recipe documents a source for is fetched on the spot:
  # vllm/<recipe>/weights-source.sh is a recipe-local file (the shared script
  # carries no model knowledge; no such file = the stopped-with-instructions
  # below). It receives the missing slot names as arguments.
  #
  # folder_ok: the quiet twin of check_folder (manifest-sha when shipped,
  # else shape) for computing that slot list
  folder_ok() {
    local dir=$1 n
    if [ -f "$dir/MANIFEST.sha256" ]; then
      (cd "$dir" && sha256sum --check --quiet MANIFEST.sha256) && return 0
      return 1
    fi
    [ -f "$dir/config.json" ] && n=$(find "$dir" -name '*.safetensors' 2>/dev/null | wc -l) && [ "$n" -gt 0 ]
  }
  SLOTS=""
  folder_ok "$WEIGHTS/$TARGET" || SLOTS="$SLOTS target"
  if [ -n "$DRAFTER" ]; then folder_ok "$WEIGHTS/$DRAFTER" || SLOTS="$SLOTS drafter"; fi
  if [ -f "$YDIR/weights-source.sh" ]; then
    echo
    echo "      missing: $SLOTS — the model documents their source (vllm/package/"
    echo "      weights-source.sh); fetching now (resume-safe):"
    if WEIGHTS_DIR="$WEIGHTS" TARGET_MODEL="$TARGET" DRAFTER_MODEL="$DRAFTER" \
         bash "$YDIR/weights-source.sh" $SLOTS; then
      # re-verify what the fetch produced with the same checks
      rc=0
      check_folder "$WEIGHTS/$TARGET" "target ($TARGET) — re-verified after fetch" || rc=1
      if [ -n "$DRAFTER" ]; then
        check_folder "$WEIGHTS/$DRAFTER" "drafter ($DRAFTER) — re-verified after fetch" || rc=1
      fi
    fi
  fi
  if [ $rc -ne 0 ]; then
    echo
    echo "install paused: provision the missing folder(s) above, then re-run"
    echo "install.bat - every earlier stage is idempotent and will skip."
    exit 1
  fi
fi

# ---- [5/5] the install manifest ----
# The bump-aware record: the image version + each tier's package-yml sha256 +
# whether its machine delta is present. A future run re-diffs this: a new
# version cleared the JIT cache above; a changed sha means the package was
# re-cut and the wizard's keep-or-reset prompts are warranted.
echo "[5/5] the install manifest (INSTALL.json)"
python3 - "$MODEL" "$NEW_IMG" "$YDIR" "$INSTALL_JSON" <<'PY'
import sys, os, hashlib, json, datetime
model, img, ydir, out = sys.argv[1:5]
parent = os.path.dirname(ydir)
tiers = {}
for name in sorted(os.listdir(ydir)):
    if not name.endswith('.yml'):
        continue
    p = os.path.join(ydir, name)
    if not os.path.isfile(p):
        continue
    stem = name[:-4]
    cfgp = os.path.isfile(os.path.join(parent, stem + '.env'))
    with open(p, 'rb') as fh:
        h = hashlib.sha256(fh.read()).hexdigest()
    tiers[stem] = {'yml': 'package/' + name, 'sha256': h,
                   'config': stem + '.env', 'config_present': cfgp}
doc = {'model': model,
       'updated': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
       'vllm_image': img or '',
       'tiers': tiers}
with open(out, 'w', encoding='utf-8') as fh:
    fh.write(json.dumps(doc, indent=2) + '\n')
print('      written: %s (image %s; %d tier template(s))' % (out, img or '?', len(tiers)))
PY

echo "==================================================================="
echo " ready: the $MODEL install is complete."
echo "   each tier's machine .env (vllm/<tier>.env, beside"
echo "   the bats) is the only knob surface; the start bats boot it from"
echo "   the tree, the WSL side holds only the runtime area."
echo "==================================================================="
exit 0
