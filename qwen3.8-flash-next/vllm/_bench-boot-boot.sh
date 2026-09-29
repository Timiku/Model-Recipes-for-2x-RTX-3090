#!/usr/bin/env bash
# bench-boot: one unattended boot of the mtp tier, log + verdict to the
# runtime area (survives distro restarts, unlike /tmp). The MRFlashBench
# scheduled task wraps this.
set -u
SRC=/mnt/e/Textgen/model-recipes/2x3090/package
RT=$HOME/model-recipes-rt/qwen3.8-flash-next
mkdir -p "$RT"
cd "$SRC/qwen3.8-flash-next/vllm"
bash "$SRC/_shared/scripts/up.sh" qwen3.8-flash-next mtp >> "$RT/bench-boot.log" 2>&1
echo "BENCH-BOOT rc=$? $(date -u '+%F %T')" >> "$RT/bench-boot.log"
tail -3 "$RT/boot-last-status" >> "$RT/bench-boot.log" 2>/dev/null || true
