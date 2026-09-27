#!/usr/bin/env bash
# pickpair.sh - the native-Linux twin of pickpair.bat: the tickbox-style GPU
# picker, shared by the install scripts. Prints the box's cards as a numbered
# list, takes TWO picks (tensor-parallel-2 needs exactly two distinct cards;
# a single-card install is not a supported configuration), confirms, then
# prints the pair as PAIR=a,b - the caller captures it:
#
#   PAIR=$(bash "$(dirname ...)/pickpair.sh") || PAIR_KEEP=1
#
# Prints PAIR=<a>,<b> on stdout on confirm; PAIR_KEEP=1 and exit 1 when the
# user keeps the standing pair (empty first pick) or nvidia-smi fails.
# The card list comes from nvidia-smi -L, the same source the boot's card
# gate queries, so every offered index is real.

pickpair_valid() { # a bare card index, a number, nothing else
  case "$1" in
    ''|*[!0-9]*) echo "  that is not a card index - pick a number from the list" >&2; return 1 ;;
  esac
  return 0
}

echo >&2
echo " this box reports:" >&2
if ! nvidia-smi -L >&2; then
  echo " nvidia-smi failed - no card list to offer. Set DEVICE_PAIR by" >&2
  echo " hand in the tier .envs if you know the indexes." >&2
  exit 1
fi

while :; do
  echo >&2
  printf '  pick the FIRST card [index, enter=keep the standing pair]: ' >&2
  IFS= read -r C1 || C1=""
  [ -n "$C1" ] || { echo "PAIR_KEEP=1"; exit 1; }
  pickpair_valid "$C1" || continue
  echo "  picked card $C1 - now the second, a different one" >&2
  while :; do
    echo >&2
    printf '  pick the SECOND card [index, enter=start over]: ' >&2
    IFS= read -r C2 || C2=""
    [ -n "$C2" ] || break
    pickpair_valid "$C2" || continue
    if [ "$C2" = "$C1" ]; then
      echo "  card $C2 is already picked - pick a different one" >&2
      continue
    fi
    echo >&2
    echo "  selected pair: $C1,$C2" >&2
    printf '  [enter] write this pair   [n] start over: ' >&2
    IFS= read -r OK || OK=""
    [ "${OK:0:1}" = "n" ] && break
    echo "PAIR=$C1,$C2"
    exit 0
  done
done
