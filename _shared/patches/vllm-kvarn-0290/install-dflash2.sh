#!/bin/bash
# KVarN <-> DFlash2 drafter compat installer (the kvarndflash2 arm only).
# The tier's entrypoint calls this AFTER dflash2/install.sh (the compat patch
# edits a file that the W4A16 KV-dequant bundle also patches) and AFTER
# install.sh (the base port). Refuses boot on any failure.
#
# What it fixes (both hunks are cpuchip's, re-anchored for 0.29.0):
#   1. qwen3_dflash.py — the drafter's sliding-window layers have no KVarN
#      backend, so they must keep the native cache dtype while the target's
#      full-attention layers take kvarn_k4v2_g128. Without this the drafter
#      asks for a KVarN SW cache that does not exist.
#   2. dflash2/speculator.py — degenerate scores guard (a NaN can produce an
#      out-of-range top-k index) and zero-initialised selector tokens instead
#      of uninitialised torch.empty.
#
# Drift discipline: --fuzz 0, and the applied result is checked directly (a
# marker grep + a module import), never the patch exit code.

set -u
DIR=${KVARN_DIR:-/etc/vllm-patches/kvarn}
VLLM=${VLLM_DIR:-/usr/local/lib/python3.12/dist-packages/vllm}
MARK="KVarN has no sliding-window backend"
DRAFTER="$VLLM/model_executor/models/qwen3_dflash.py"

[ -f "$DIR/dflash2-compat.patch" ] || { echo "[kvarn-dflash2] patch not found at $DIR (check the yml mount)" >&2; exit 1; }
[ -f "$DRAFTER" ] || { echo "[kvarn-dflash2] $DRAFTER missing — this tier needs the DFlash2 backport installer first" >&2; exit 1; }

if grep -qs "$MARK" "$DRAFTER"; then
    echo "[kvarn-dflash2] compat already applied — verifying only" >&2
else
    out=$(patch -p1 -N --fuzz 0 -r /dev/null -d "$VLLM" < "$DIR/dflash2-compat.patch" 2>&1) || true
    echo "$out"
    case "$out" in
        *FAILED*) echo "[kvarn-dflash2] a hunk does not apply to this tree — refusing boot (re-cut it against the pin)" >&2; exit 1 ;;
    esac
fi

grep -qs "$MARK" "$DRAFTER" || { echo "[kvarn-dflash2] drafter marker missing after apply — refusing boot" >&2; exit 1; }
grep -qs "torch.zeros(" "$VLLM/v1/worker/gpu/spec_decode/dflash2/speculator.py" || { echo "[kvarn-dflash2] speculator guard missing after apply — refusing boot" >&2; exit 1; }
python3 -c "import vllm.model_executor.models.qwen3_dflash, vllm.v1.worker.gpu.spec_decode.dflash2.speculator" || {
    echo "[kvarn-dflash2] import check failed — refusing boot" >&2; exit 1; }
echo "[kvarn-dflash2] drafter compat installed (SW layers native dtype, speculator guarded)" >&2
