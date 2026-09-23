#!/bin/bash
# KVarN bundle installer (int4 KV cache: kvarn_k4v2_g128 / _g64, k4v4_*).
# The tier's entrypoint calls this before `vllm serve`; it refuses boot on any
# failure. Mounted read-only at /etc/vllm-patches/kvarn by the tier yml.
#
# What it does:
#   1. copies the 8 KVarN modules into the image's vllm package
#      (v1/attention/backends/kvarn_attn.py, v1/attention/ops/kvarn_{store,decode,
#       triton_kvarn_decode,triton_kvarn_sinkhorn}.py,
#       model_executor/layers/quantization/kvarn/{__init__,config,sinkhorn}.py);
#   2. applies kvarn-0.29.0.patch (the stock-file hunks that teach 0.29.0 the
#      new cache dtypes: CacheDType literals, KVQuantMode.KVARN, the dtype map,
#      the backend registry + priority, the attention-layer spec branch, the
#      packed slot via FullAttentionSpec(state_content_bytes=...), the
#      hybrid-model page-alignment branch);
#   3. applies kvarn-v2-runner-stock.patch (the five stock-file hunks of the
#      upstream v2-runner patch: attention-layer v2 hook, kv_cache_coordinator
#      sliding-window group tolerance, single_type_kv_cache_manager,
#      gpu/model_runner uniform-decode gating, mamba_hybrid _align_mode
#      block-size fix).
#
# NOT applied: parked/dflash2-hunks.patch (qwen3_dflash.py drafter dtype
# fallback + dflash2/speculator.py NaN guards). Those are for a dflash2 arm on
# KVarN; the drafter-off and MTP-first tiers do not need them. The DRIFTER is
# whoever boots the dflash2 arm: apply them only after the drafter itself runs
# on the tier, and re-anchor them against this pin first.
#
# Provenance: extracted from the KVarN fork (huawei-csl/KVarN, Apache-2.0,
# arXiv 2606.03458) via cpuchip's 0.29.0 port (syv-ai/qwen38-27b-rtx3090
# branch port-0.29, kvarn/). Upstreaming is in flight as vllm-project/vllm
# PR #46812 (dense/GQA path, head sizes 64/128/256). See README.md.
#
# Drift discipline: --fuzz 0 on both patches. A hunk that needs slack means
# this image is not the tree the patch was cut against (the pin moved, or one
# of our other bundles already touched the same lines) — refuse the boot, then
# re-cut against the new pin. `patch -N` cannot distinguish "already applied"
# from "does not apply" (both exit non-zero), so the exit code is never the
# signal: the applied result is checked directly (marker count + an import).
#
# Idempotent: an image that already carries the port skips the copy/patch and
# runs the same verification.

set -u
DIR=${KVARN_DIR:-/etc/vllm-patches/kvarn}
VLLM=${VLLM_DIR:-/usr/local/lib/python3.12/dist-packages/vllm}
PY=${PY:-python3}

[ -d "$DIR/files/vllm" ] || { echo "[kvarn] bundle not found at $DIR (check the yml mount)" >&2; exit 1; }
[ -d "$VLLM" ] || { echo "[kvarn] vllm package not found at $VLLM" >&2; exit 1; }

if grep -rqs "kvarn_k4v2_g128" "$VLLM/config/cache.py" 2>/dev/null; then
    echo "[kvarn] already applied (image carries the port) — verifying only" >&2
else
    cp -r "$DIR/files/vllm/." "$VLLM/"
    apply() { # $1 = patch file
        local out
        out=$(patch -p1 -N --fuzz 0 -r /dev/null -d "$VLLM" < "$DIR/$1" 2>&1) || true
        echo "$out"
        case "$out" in
            *FAILED*) echo "[kvarn] $1 has a hunk that does not apply to this vllm tree — refusing boot (re-cut it against the pin)" >&2; exit 1 ;;
        esac
    }
    apply kvarn-0.29.0.patch
    apply kvarn-v2-runner-stock.patch
fi

# The result check, not the exit code. Every v2-runner stock hunk adds a
# port(kvarn-v2) marker; a short count means a partial apply that a `|| true`
# above would otherwise have swallowed.
"$PY" - "$VLLM" "$DIR" <<'PY'
import sys
from pathlib import Path

sp, here = Path(sys.argv[1]), Path(sys.argv[2])
patch = here / "kvarn-v2-runner-stock.patch"
want, current = {}, None
for line in patch.read_text().splitlines():
    if line.startswith("+++ b/"):
        current = line[len("+++ b/"):].strip()
        want.setdefault(current, 0)
    elif current and line.startswith("+") and "port(kvarn-v2)" in line:
        want[current] += 1

short = []
for rel, expected in sorted(want.items()):
    target = sp / rel
    found = target.read_text().count("port(kvarn-v2)") if target.is_file() else 0
    if found < expected:
        short.append(f"  {rel}: {found}/{expected}")
if short:
    print("[kvarn] the v2-runner stock patch did not apply completely:", file=sys.stderr)
    print("\n".join(short), file=sys.stderr)
    sys.exit(1)
print(f"[kvarn] v2-runner markers ok ({sum(want.values())} across {len(want)} files)")
PY

# Import check: the dtype must exist and the backend must resolve, or the
# engine dies later at KV-cache init with a much worse error message.
"$PY" - <<'PY'
from typing import get_args
from vllm.config.cache import CacheDType
assert "kvarn_k4v2_g128" in get_args(CacheDType), "KVarN dtype literal missing from CacheDType"
from vllm.v1.attention.backends.registry import AttentionBackendEnum
print("[kvarn] backend:", AttentionBackendEnum.KVARN.get_class().get_name())
from vllm.model_executor.layers.quantization.kvarn.config import KVarNConfig
c = KVarNConfig.from_cache_dtype("kvarn_k4v2_g128", 256)
print(f"[kvarn] tile {c.tile_bytes} B -> {c.tile_bytes_aligned // c.group} B/token/head at head_dim 256 (fp8: 256 B)")
PY

echo "[kvarn] installed" >&2
