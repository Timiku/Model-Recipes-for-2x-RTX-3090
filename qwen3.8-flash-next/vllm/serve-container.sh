#!/usr/bin/env bash
set -euo pipefail

profile=/opt/qwen38/configs/2x3090-128gb.env
[[ -f "$profile" ]] || { echo "missing runtime profile: $profile" >&2; exit 2; }
# shellcheck source=/dev/null
source "$profile"

case "$ENABLE_VISION" in
  0) modality_args=(--language-model-only) ;;
  1)
    if ! [[ "$VISION_MAX_IMAGES" =~ ^[1-9][0-9]*$ && "$VISION_MAX_PIXELS" =~ ^[1-9][0-9]*$ ]]; then
      echo "VISION_MAX_IMAGES and VISION_MAX_PIXELS must be positive decimal integers" >&2
      exit 2
    fi
    if (( VISION_MAX_PIXELS < 65536 || VISION_MAX_PIXELS > 16777216 )); then
      echo "VISION_MAX_PIXELS must be between 65536 and 16777216" >&2
      exit 2
    fi
    modality_args=(
      --limit-mm-per-prompt "{\"image\":$VISION_MAX_IMAGES,\"video\":0}"
      --mm-processor-kwargs "{\"min_pixels\":65536,\"max_pixels\":$VISION_MAX_PIXELS}"
      --mm-encoder-tp-mode weights
    )
    ;;
  *) echo "ENABLE_VISION must be 0 or 1" >&2; exit 2 ;;
esac

case "$DISABLE_CUSTOM_ALL_REDUCE" in
  0) custom_all_reduce_arg= ;;
  1) custom_all_reduce_arg=--disable-custom-all-reduce ;;
  *)
    echo "DISABLE_CUSTOM_ALL_REDUCE must be 0 or 1" >&2
    exit 2
    ;;
esac

allocator_config=${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}
expandable_segments=
IFS=',' read -r -a allocator_options <<< "$allocator_config"
for option in "${allocator_options[@]}"; do
  compact_option=${option//[[:space:]]/}
  case "$compact_option" in
    expandable_segments:True|expandable_segments:true)
      expandable_segments=True
      ;;
    expandable_segments:False|expandable_segments:false)
      expandable_segments=False
      ;;
  esac
done
if [[ "$DISABLE_CUSTOM_ALL_REDUCE" == 0 && "$expandable_segments" == True ]]; then
  echo "DISABLE_CUSTOM_ALL_REDUCE=0 is incompatible with expandable_segments:True in this pinned runtime; set PYTORCH_CUDA_ALLOC_CONF=expandable_segments:False or keep DISABLE_CUSTOM_ALL_REDUCE=1" >&2
  exit 2
fi

model=${1:-/model}
mtp_model=${2:-"$model/runtime/mtp-int4-g32"}
rankings=/workspace/static_hot_cache_rankings.json

[[ -f "$model/model.safetensors.index.json" ]] || {
  echo "model checkpoint not found at $model" >&2
  exit 2
}
[[ -f "$rankings" ]] || { echo "missing hot-cache rankings: $rankings" >&2; exit 2; }
# LOCAL DELTA #1 (this box, vs the verbatim community file at tree pin
# 3fa7780): the K=0 arm. The pinned vLLM rejects num_speculative_tokens=0
# (pydantic greater-than-0, probed in-image 09-06), so the MTP off-state is
# a shape: the --speculative-config flag is omitted entirely and the drafter
# preflight (upstream's unconditional mtp_model existence check) is skipped
# with it; upstream keeps both unconditional. LOCAL DELTA #2 (the 09-05
# KV_CACHE_DTYPE env pass-through) was removed 2026-09-22; the flag is
# upstream's hardcoded `--kv-cache-dtype auto` again.
# LOCAL DELTA #3 (09-18) is the default-sampler block below the spec_args
# arm: the house sampler pattern (the 27B lane's entrypoint), the rows
# from the Qwen3.8 family card. The block is INERT at the default
# (SAMPLER=card + blank knobs = no flag = upstream's exact behavior).
# Apart from deltas #1 and #3 (delta #2 removed 09-22, see above), every
# byte is the verbatim community
# gate; the vendor limits ride along: VISION_MAX_IMAGES=1 /
# VISION_MAX_PIXELS=1048576, the docs/vision.md shape, validated here
# on the t22 round-trip at 448x448).
if [ -n "${MTP_DEPTH:-}" ] && [ "$MTP_DEPTH" -gt 0 ] 2>/dev/null; then
  [[ -f "$mtp_model/model.safetensors.index.json" ]] || {
    echo "compact MTP checkpoint not found at $mtp_model" >&2
    exit 2
  }
  spec_args=(--speculative-config "{\"method\":\"mtp\",\"num_speculative_tokens\":$MTP_DEPTH,\"use_local_argmax_reduction\":true,\"model\":\"$mtp_model\"}")
else
  echo "MTP off (MTP_DEPTH='${MTP_DEPTH:-blank}'): no speculative head on this boot (the K=0 arm)"
  spec_args=()
fi

# LOCAL DELTA #3 (09-18, house): default samplers. SAMPLER picks the
# boot's default row; the per-value knobs TEMP / TOP_P / TOP_K / MIN_P /
# PRESENCE_PENALTY override the picked row (blank = the row's value); a
# caller's per-request params always win over ALL of this —
# --override-generation-config only sets the server DEFAULTS.
#   card (unset)  no flag at all: the checkpoint's generation_config.json
#                 rides (temp 1.0 / top_p 0.95 / top_k 20) — today's
#                 effective setting, the byte-compatible default.
#   think         the family card's thinking row: 1.0 / 0.95 / 20 / 0 / 0
#   instruct      the family card's non-thinking row: 0.7 / 0.8 / 20 / 0 / 1.5
# Known gap (verified live 09-18 on the pin): PRESENCE_PENALTY (and any
# frequency_penalty) is DROPPED by this vLLM build — upstream #50767 (the
# get_diff_sampling_param whitelist omits it; fix PR #50769 open, not
# merged). The instruct row boots with pp 0 EFFECTIVE; the block warns at
# the boot when a nonzero pp is claimed. The other four fields ride the
# flag honestly. When #50769 lands in the pin, the flag works unchanged.
# Values must be JSON numbers (a non-numeric value fails the parse at
# boot, loudly). Sources: huggingface.co/Qwen/Qwen3.8-27B model card;
# the checkpoint's own generation_config.json (verified in-container
# 09-18: exactly the think row's first three).
case "${SAMPLER:-card}" in
  card)     _t=${TEMP:-}      _p=${TOP_P:-}   _k=${TOP_K:-} _m=${MIN_P:-} _pp=${PRESENCE_PENALTY:-} ;;
  think)    _t=${TEMP:-1.0}   _p=${TOP_P:-0.95} _k=${TOP_K:-20} _m=${MIN_P:-0.0} _pp=${PRESENCE_PENALTY:-0.0} ;;
  instruct) _t=${TEMP:-0.7}   _p=${TOP_P:-0.8}  _k=${TOP_K:-20} _m=${MIN_P:-0.0} _pp=${PRESENCE_PENALTY:-1.5} ;;
  *) echo "SAMPLER='${SAMPLER}': unknown row (card|think|instruct)" >&2; exit 2 ;;
esac
sampler_args=()
_sjson=""
for _kv in temperature:"$_t" top_p:"$_p" top_k:"$_k" min_p:"$_m" presence_penalty:"$_pp"; do
  _key=${_kv%%:*}; _val=${_kv#*:}
  [ -n "$_val" ] || continue
  [ -n "$_sjson" ] && _sjson="$_sjson, "
  _sjson="$_sjson\"$_key\": $_val"
done
if [ -n "$_sjson" ]; then
  sampler_args=(--override-generation-config "{$_sjson}")
  echo "[sampler] server defaults: {$_sjson} (SAMPLER=${SAMPLER:-card})" >&2
  if echo "$_sjson" | grep -q '"presence_penalty": [^0]'; then
    echo "[sampler] WARNING: presence_penalty above is DROPPED by this vLLM build (upstream #50767; #50769 pending) - the server runs pp 0 until the pin gains the fix" >&2
  fi
else
  echo "[sampler] SAMPLER=card, no knob set: no override flag - the checkpoint's generation_config.json rides (temp 1.0 / top_p 0.95 / top_k 20)" >&2
fi

export CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-0,1}
export PYTORCH_CUDA_ALLOC_CONF=$allocator_config
export VLLM_PLE_CPU_OFFLOAD=1
export VLLM_WNA16_DYNAMIC_LRU=1
export VLLM_WNA16_STATIC_HOT_CACHE_FILE=$rankings
export VLLM_WNA16_MIXED_VMM_HOT_CACHE=1
export VLLM_FORCE_DYNAMIC_SPEC_SCHEDULING=1

exec vllm serve "$model" \
  --served-model-name "$SERVED_MODEL_NAME" \
  --host 0.0.0.0 --port "$PORT" \
  --tensor-parallel-size 2 \
  --enable-expert-parallel \
  --all2all-backend allgather_reducescatter \
  --moe-backend humming \
  --dtype bfloat16 \
  "${modality_args[@]}" \
  --load-format safetensors \
  --safetensors-load-strategy lazy \
  --max-parallel-loading-workers "$MAX_PARALLEL_LOADING_WORKERS" \
  --offload-backend uva \
  --cpu-offload-gb "$CPU_OFFLOAD_GB" \
  --cpu-offload-params experts \
  --max-model-len "$MAX_MODEL_LEN" \
  --max-num-seqs "$MAX_NUM_SEQS" \
  --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" \
  --kv-cache-dtype auto \
  --kv-cache-memory-bytes "$KV_CACHE_MEMORY_BYTES" \
  --enable-chunked-prefill \
  --enable-prefix-caching \
  --mamba-cache-mode align \
  --no-async-scheduling \
  ${custom_all_reduce_arg:+"$custom_all_reduce_arg"} \
  --compilation-config '{"mode":0,"cudagraph_mode":"FULL_DECODE_ONLY"}' \
  --trust-remote-code \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder \
  --reasoning-parser qwen3 \
  "${spec_args[@]}" \
  "${sampler_args[@]}"
