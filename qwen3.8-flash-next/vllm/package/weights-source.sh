#!/usr/bin/env bash
# weights-source.sh — qwen3.8-flash-next / dominikbucko-2x3090: the
# documented source of the weights folder. Executed by install-core.sh
# stage 4, which passes the names of the MISSING slots it could not
# verify (its arguments):
#   target
# and the WEIGHTS_DIR / TARGET_MODEL of the recipe's config.env.
# Recipe-local knowledge lives here; the shared script carries no model
# facts (the mirror copy of this file is what install runs).
#
#   target : albucino/Qwen3.8-Flash-Next-W4A16-FP8PLE
#            (the community 2x3090 checkpoint, revision-pinned below:
#            Intel AutoRound W4A16 weights (GPTQ-pack INT4, group 128,
#            sym) + the NVFP4-repo PLE n-gram table (FP8 E4M3FN) + the
#            3-stage MTP draft head; ~121 GiB, 27 files)
#
# The repo is public and UNGATED (the community-published checkpoint;
# audited at the 09-02 preflight). No HF token is needed; a 401/403
# below means it went gated in the meantime and the user accepts its
# terms + exports HF_TOKEN.
#
# The layout contract (the house rule): the folder's top level is the
# Hugging Face repo layout — `hf download --local-dir` puts the repo's
# root files one level under the folder; nothing re-nested, no
# cache indirection. The post-fetch shape check below enforces the
# file count.
#
# The hf CLI: bootstrapped user-level (get-pip --user + pip --user), no
# sudo, idempotent. Re-runs are resume-safe (hf continues partial
# files). The 121 GiB fetch is a multi-hour job: run it when the box
# is free, and with the swap file in place (see the README).
set -uo pipefail

[ -n "${WEIGHTS_DIR:-}" ] || { echo "      FATAL: WEIGHTS_DIR not set by install-core"; exit 1; }

SRC_target=albucino/Qwen3.8-Flash-Next-W4A16-FP8PLE
REV_target=ef554143369a706525336f6b42a09094835dc077
DEST_target=${TARGET_MODEL:-qwen3.8-flash-next}
# the revision-pinned set: 25 assembled safetensors + 2 MTP + index/config
# (the count the shape check waits for)
EXPECT_FILES=27

have_hf() { command -v hf >/dev/null 2>&1 || command -v huggingface-cli >/dev/null 2>&1; }
if ! have_hf; then
  echo "      hf CLI missing - one user-level install attempt (no sudo needed)..."
  if ! python3 -m pip --version >/dev/null 2>&1; then
    # the distro strips pip and ensurepip; the get-pip bootstrap is
    # user-level and leaves the system python untouched
    if curl -fsSL --max-time 120 https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py 2>/dev/null; then
      python3 /tmp/get-pip.py --user -q >/dev/null 2>&1 || true
      rm -f /tmp/get-pip.py
    fi
  fi
  if python3 -m pip --version >/dev/null 2>&1; then
    python3 -m pip install -q --user 'huggingface_hub[hf_transfer]' hf_transfer >/dev/null 2>&1 || true
    export PATH="$HOME/.local/bin:$PATH"
  fi
fi
if ! have_hf; then
  echo "      the hf CLI could not be installed automatically (no network, or"
  echo "      a system-managed python without pip). Manual, once (needs your"
  echo "      sudo for the first line):"
  echo "        sudo apt update && sudo apt install -y python3-pip"
  echo "        python3 -m pip install --user 'huggingface_hub[hf_transfer]'"
  echo "      then re-run install-dual.bat - every earlier stage is idempotent."
  exit 1
fi
HF_BIN=$(command -v hf || command -v huggingface-cli)

rc=0
for slot in "$@"; do
  case "$slot" in
    target) SRC=$SRC_target; DEST="$WEIGHTS_DIR/$DEST_target" ;;
    *) echo "      unknown missing slot: $slot"; rc=1; continue ;;
  esac
  echo "      $slot: hf download $SRC"
  echo "            -> $DEST   (resume-safe; a re-run continues partial files)"
  echo "            (revision-pinned: $REV_target)"
  if "$HF_BIN" download "$SRC" --revision "$REV_target" --local-dir "$DEST"; then
    n=$(find "$DEST" -type f 2>/dev/null | wc -l)
    if [ "$n" -lt "$EXPECT_FILES" ]; then
      echo "        the folder is short of files ($n/$EXPECT_FILES) - the fetch"
      echo "        ended early; re-run the install to resume."
      rc=1
    else
      echo "        done: $SRC ($n files of the pinned set)"
    fi
  else
    echo "        FAILED: $SRC"
    echo "        if the error is 401/403 (the repo went gated since the audit):"
    echo "        accept its terms at https://huggingface.co/$SRC, export HF_TOKEN,"
    echo "        and re-run install-dual.bat."
    rc=1
  fi
done
exit $rc
