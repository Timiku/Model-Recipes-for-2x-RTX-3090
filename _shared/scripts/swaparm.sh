#!/bin/bash
# swaparm.sh — run as root (the start bats call it via `wsl -u root`):
# WSL2's init does not self-activate /etc/fstab swap, so the box's anchored
# 64 GiB swapfile is armed here, idempotently, on every fresh VM, before the
# boot. The kernel's CommitLimit = swap + 50% RAM: 83 GiB on the 28 G
# default partition alone, 147 GiB with both the partition and the file up.
# The 9th-boot 401's leading candidate (the commit wall) rides on this
# number; the boot's own Committed_AS is traced to commit-trace by up.sh.
if [ -f /swapfile-mr ]; then
  swapon /swapfile-mr 2>/dev/null || true
fi
swapon --show
grep -E '^(CommitLimit|Committed_AS):' /proc/meminfo
