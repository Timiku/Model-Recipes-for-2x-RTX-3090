#!/usr/bin/env bash
# mcfg.sh - the native-Linux twin of mcfg-get.ps1 / mcfg-set.ps1. Same file
# format as the machine .envs (plain KEY=value lines, one per tier, edited
# on either side of the fence), so the Windows ps1s and this script read
# and write the same files interchangeably.
#
#   mcfg.sh get  <file.env> <KEY>          # print the first non-empty value
#   mcfg.sh set  <file.env> <KEY> <VALUE>  # write KEY=<VALUE> (create file if absent)
#   mcfg.sh unset <file.env> <KEY>         # drop the KEY line
#
# get semantics match mcfg-get.ps1: the first non-empty value of KEY in the
# file, empty string (exit 1) if none. set semantics match mcfg-set.ps1: an
# existing KEY= line is replaced in place, KEY absent appends. Values are
# written bare (no quotes) exactly as the ps1s do; the readers (mcfg_get in
# install-core.sh, up.sh's source) strip none of it, so keep values shell-
# clean (no leading/trailing spaces).
set -u

usage() { echo "usage: mcfg.sh get|set|unset <file.env> <KEY> [VALUE]" >&2; exit 2; }

[ $# -ge 3 ] || usage
CMD=$1; FILE=$2; KEY=$3
[ -n "$KEY" ] || usage

case "$CMD" in
  get)
    [ -f "$FILE" ] || exit 1
    sed -n "s/^${KEY}=//p" "$FILE" | sed 's/[[:space:]]*$//' | grep -m1 -v '^$' || exit 1
    ;;
  set)
    [ $# -eq 4 ] || usage
    VAL=$4
    if [ -f "$FILE" ] && grep -q "^${KEY}=" "$FILE"; then
      # L4: awk with -v passes the value as data, not as code - '&', '\'
      # and '/' in a path survive verbatim (sed replacement semantics mangle
      # all three). The literal KEY match is a shell-quoted fixed string.
      awk -v key="$KEY=" -v val="$VAL" '
        index($0, key) == 1 { print key val; done = 1; next }
        { print }
        END { if (! done) print key val }
      ' "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"
    else
      printf '%s=%s\n' "$KEY" "$VAL" >> "$FILE"
    fi
    ;;
  unset)
    [ -f "$FILE" ] && sed -i "/^${KEY}=/d" "$FILE"
    ;;
  *)
    usage
    ;;
esac
