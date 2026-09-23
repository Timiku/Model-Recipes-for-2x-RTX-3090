#!/usr/bin/env bash
# weights-source.sh — qwen3.8-27b: the documented source of the
# weights folders. Executed by install-core.sh stage 4, which passes the
# names of the MISSING slots it could not verify (its arguments):
#   target, drafter
# and the WEIGHTS_DIR / TARGET_MODEL / DRAFTER_MODEL of the tier's
# machine delta. Model-local knowledge lives here; the shared script carries
# no model facts (install runs this file in place from the Windows-side tree).
#
#   target  : Frozenlock/Qwen3.8-27B-int4-AutoRound
#             (~18 GB; AutoRound INT4 — the MTP speculative-decoding head
#             quantized and working; the checkpoint that replaced the Avuja
#             export 2026-08-20)
#   drafter : syvai/Qwen3.8-27B-DFlash2-W4A16
#             (~1.2 GB; the external DFlash2 block drafter, the DFlash2 tier)
#
# Both repos are public; a 401/403 below means one went gated in the
# meantime: accept its terms at https://huggingface.co/<repo>, export
# HF_TOKEN, and re-run.
#
# The hf CLI: bootstrapped user-level (get-pip --user, then pip --user; a
# PEP 668 "externally managed" python gets a --break-system-packages retry
# - ~/.local either way), no sudo, idempotent. Re-runs are resume-safe
# (hf continues partial files).
set -uo pipefail

[ -n "${WEIGHTS_DIR:-}" ] || { echo "      FATAL: WEIGHTS_DIR not set by install-core"; exit 1; }

SRC_target=Frozenlock/Qwen3.8-27B-int4-AutoRound
SRC_drafter=syvai/Qwen3.8-27B-DFlash2-W4A16
DEST_target=${TARGET_MODEL:-qwen3.8-27b-autoround-int4}
DEST_drafter=${DRAFTER_MODEL:-qwen3.8-27b-dflash2-w4a16}

have_hf() { command -v hf >/dev/null 2>&1 || command -v huggingface-cli >/dev/null 2>&1; }
# PEP 668 (Ubuntu 24.04 and up): the system python is "externally
# managed" and pip refuses even a --user install; --break-system-packages
# lifts the refusal while everything still lands in ~/.local
pip_install_hf() {
  python3 -m pip install -q --user $1 'huggingface_hub[hf_transfer]' hf_transfer >/dev/null 2>&1
}
if ! have_hf; then
  echo "      hf CLI missing - one user-level install attempt (no sudo needed)..."
  if ! python3 -m pip --version >/dev/null 2>&1; then
    # the distro strips pip and ensurepip; the get-pip bootstrap is
    # user-level and leaves the system python untouched
    if curl -fsSL --max-time 120 https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py 2>/dev/null; then
      python3 /tmp/get-pip.py --user -q >/dev/null 2>&1 || \
        python3 /tmp/get-pip.py --user --break-system-packages -q >/dev/null 2>&1 || true
      rm -f /tmp/get-pip.py
    fi
  fi
  if python3 -m pip --version >/dev/null 2>&1; then
    pip_install_hf "" || pip_install_hf "--break-system-packages" || true
    export PATH="$HOME/.local/bin:$PATH"
  fi
fi
if ! have_hf; then
  echo "      the hf CLI could not be installed automatically (no network, or"
  echo "      a system-managed python without pip). Manual, once:"
  echo "        sudo apt update && sudo apt install -y python3-pip"
  echo "        python3 -m pip install --user 'huggingface_hub[hf_transfer]'"
  echo "      refused with 'externally-managed-environment' (Ubuntu 24.04"
  echo "      and up)? that is PEP 668 - the same install with the flag:"
  echo "        python3 -m pip install --user --break-system-packages 'huggingface_hub[hf_transfer]'"
  echo "      (it still lands in ~/.local, nowhere near the system python),"
  echo "      then a fresh WSL terminal, then re-run install.bat - every"
  echo "      earlier stage is idempotent."
  exit 1
fi
HF_BIN=$(command -v hf || command -v huggingface-cli)

rc=0
for slot in "$@"; do
  case "$slot" in
    target)  SRC=$SRC_target;  DEST=$DEST_target ;;
    drafter) SRC=$SRC_drafter; DEST=$DEST_drafter ;;
    *) echo "      unknown missing slot: $slot"; rc=1; continue ;;
  esac
  DEST="$WEIGHTS_DIR/$DEST"
  echo "      $slot: hf download $SRC"
  echo "            -> $DEST   (resume-safe; a re-run continues partial files)"
  if "$HF_BIN" download "$SRC" --local-dir "$DEST"; then
    echo "        done: $SRC"
  else
    echo "        FAILED: $SRC"
    echo "        if the error is 401/403 (the repo went gated since the last"
    echo "        audit): accept its terms at https://huggingface.co/$SRC, export HF_TOKEN,"
    echo "        and re-run install.bat."
    rc=1
  fi
done
exit $rc
