#!/bin/bash
# install.sh for vllm-56531-spec-row-classification
# Vendored vLLM PR #56531 ("Route every speculation-capable row through the
# speculative path so recurrent state stays consistent", @vadiklyutiy, OPEN),
# re-anchored to vLLM 0.29.1rc1.dev9+g2671fedfc (2026-09-13 nightly).
#
# Refuses boot unless the pre-state is verified and the patch applies cleanly
# and py-compiles — drift on a new base must stop the tier, never half-apply.
set -euo pipefail
V=/usr/local/lib/python3.12/dist-packages/vllm
DIR=$(cd "$(dirname "$0")" && pwd)
PATCH="$DIR/56531-spec-row-classification.patch"
cd /usr/local/lib/python3.12/dist-packages
echo "[spec-row-classification] verifying pre-state"
grep -F -q 'or num_decode_draft_tokens_cpu[spec_sequence_masks_cpu].sum().item()' \
  "$V/v1/attention/backends/gdn_attn.py" || { echo "  PRE-MARKER MISSING (gdn_attn.py) - base drift"; exit 1; }
if grep -F -q 'def compute_num_decode_draft_tokens(' \
  "$V/v1/worker/gpu/model_states/mamba_hybrid.py"; then
  echo "  ALREADY APPLIED? marker present pre-patch"
  exit 1
fi
grep -F -q 'use_spec_decode = len(scheduler_output.scheduled_spec_decode_tokens) > 0' \
  "$V/v1/worker/gpu_model_runner.py" || { echo "  PRE-MARKER MISSING (gpu_model_runner.py) - base drift"; exit 1; }

echo "[spec-row-classification] applying"
patch -p1 --forward --batch -i "$PATCH" || { echo "  patch FAILED"; exit 1; }

grep -F -q 'def compute_num_decode_draft_tokens(' \
  "$V/v1/worker/gpu/model_states/mamba_hybrid.py" || { echo "  POST-MARKER MISSING (function)"; exit 1; }
grep -F -q 'zero_draft_decode_mask' \
  "$V/v1/worker/gpu_model_runner.py" || { echo "  POST-MARKER MISSING (mask)"; exit 1; }
grep -F -q 'self.num_accepted_tokens.np.fill(1)' \
  "$V/v1/worker/gpu_model_runner.py" || { echo "  POST-MARKER MISSING (fill(1))"; exit 1; }
N=$(grep -cF 'use_spec_decode = self.speculative_config is not None' \
  "$V/v1/worker/gpu_model_runner.py" || true)
[ "$N" -ge 2 ] || { echo "  POST-MARKER MISSING (predicate, found $N/2)"; exit 1; }

python3 -m py_compile \
  "$V/v1/attention/backends/gdn_attn.py" \
  "$V/v1/worker/gpu/model_states/mamba_hybrid.py" \
  "$V/v1/worker/gpu_model_runner.py" || { echo "  py_compile FAILED"; exit 1; }
echo "[spec-row-classification] applied: spec-capable rows stay on the speculative path"
