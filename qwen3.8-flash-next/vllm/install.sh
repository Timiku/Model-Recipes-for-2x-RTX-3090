#!/usr/bin/env bash
# install.sh - the native-Linux twin of install.bat: the prereq gate, the
# machine-env wizard (device pair, serve bind, weights path - the same
# mcfg files the Windows bats own), then install-core.sh stages env,
# runtime area, images, weights, manifest. Every step is idempotent; a
# re-run keeps the standing answers unless you change them.
set -u
. "$(dirname -- "$0")/../../_shared/scripts/reporoot.sh"
MODEL=qwen3.8-flash-next
VDIR=$REPO/$MODEL/vllm
MCFG="$REPO/_shared/scripts/mcfg.sh"
TIERS="mtp nomtp"

echo ============================================================
echo " model-recipes install: $MODEL (native Linux)"
echo   [1/3] the prereq gate
echo "  [2/3] the machine-env wizard (DEVICE_PAIR, BIND_HOST, WEIGHTS_DIR)"
echo "  [3/3] install-core.sh (env, runtime area, images, weights, manifest)"
echo ============================================================
echo

# ---- [1/3] the prereq gate (CachyOS/Arch-class pacman fixes) -------------
FAIL=0
if ! command -v docker >/dev/null 2>&1; then
  echo "  [NO] docker            fix: sudo pacman -S docker && sudo systemctl enable --now docker"
  FAIL=1
elif ! docker info >/dev/null 2>&1; then
  echo "  [NO] docker daemon     fix: sudo systemctl enable --now docker; add yourself: sudo usermod -aG docker $USER"
  FAIL=1
fi
if command -v docker >/dev/null 2>&1 && ! docker info 2>/dev/null | grep -q nvidia; then
  echo "  [NO] nvidia runtime    fix: sudo pacman -S nvidia-container-toolkit"
  echo "                              sudo nvidia-ctk runtime configure --runtime=docker"
  echo "                              sudo systemctl restart docker"
  FAIL=1
fi
if command -v docker >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
  echo "  [NO] compose plugin    fix: sudo pacman -S docker-compose"
  FAIL=1
fi
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "  [NO] NVIDIA driver     fix: install the nvidia driver + utils (nvidia-smi must work)"
  FAIL=1
fi
echo "  [--] GPU layout - the tiers run cards 0,1 by default; repoint via the DEVICE_PAIR step below:"
nvidia-smi -L 2>/dev/null || echo "       (nvidia-smi failed - fix the driver first)"
echo "  [--] disk - the image pulls + the weights want ~40 GB headroom"
df -h / | sed -n 2p
if [ "$FAIL" = 1 ]; then
  echo
  echo " fix the [NO] lines, then re-run this script; nothing was changed."
  exit 1
fi
echo "  [ok] prereqs"

# ---- [2/3] the machine-env wizard ----------------------------------------
# The device pair: two picks, written to every tier's machine .env.
echo
echo " device pair - the two cards every tier runs on (tensor-parallel-2"
echo " needs both). Standing pair:"
PAIR_STAND=$(bash "$MCFG" get "$VDIR/mtp.env" DEVICE_PAIR 2>/dev/null || true)
if [ -n "$PAIR_STAND" ]; then echo "  $PAIR_STAND  (a re-run keeps it unless you change it)"; else echo "  none set yet - the package default is 0,1"; fi
PICK=$(bash "$REPO/_shared/scripts/pickpair.sh" | tail -n1) || true
if [ -n "${PICK:-}" ] && [ "$PICK" != "PAIR_KEEP=1" ]; then
  PAIR=${PICK#PAIR=}
  ok=1
  for t in mtp nomtp; do bash "$MCFG" set "$VDIR/$t.env" DEVICE_PAIR "$PAIR" || ok=0; done
  if [ "$ok" = 1 ]; then
    echo "  written DEVICE_PAIR=$PAIR to all tier machine .envs"
  else
    echo "  WARNING: some tier .env writes failed - check DEVICE_PAIR in each $VDIR/<tier>.env" >&2
  fi
fi

# The serve bind.
BIND_STAND=$(bash "$MCFG" get "$VDIR/mtp.env" BIND_HOST 2>/dev/null || true)
echo
echo  serve bind - the address the tier binds to when it is up:
echo "   0.0.0.0    every interface (the package default; the LAN reaches it)"
echo    127.0.0.1  the loopback only
echo    an IP      only that address
if [ -n "$BIND_STAND" ]; then echo "  standing bind: $BIND_STAND  (a re-run keeps it unless you change it)"; fi
printf '  [enter] keep   [o]pen 0.0.0.0  [l]ocal 127.0.0.1  [a] an address: '
IFS= read -r SB || SB=""
case "$SB" in
  o|O) SB_VAL=0.0.0.0 ;;
  l|L) SB_VAL=127.0.0.1 ;;
  a|A) printf '  address (enter = 0.0.0.0): '; IFS= read -r ADDR || ADDR=""; SB_VAL=${ADDR:-0.0.0.0} ;;
  *) SB_VAL="" ;;
esac
if [ -n "$SB_VAL" ]; then
  for t in mtp nomtp; do bash "$MCFG" set "$VDIR/$t.env" BIND_HOST "$SB_VAL"; done
  echo "  written BIND_HOST=$SB_VAL to all tier machine .envs"
fi

# The firewall note (the bat's firewall.bat step; one manual line here).
# PORT may be unset at install time (tier-boot knob), so the note stays
# generic unless a standing port exists in the environment.
echo
echo  firewall - if the LAN must reach the tier and the firewall is on,
if [ -n "${PORT:-}" ]; then
  echo " open the tier port once (e.g.: sudo firewall-cmd --add-port=$PORT/tcp"
  echo " or ufw allow $PORT/tcp); the tier boots either way."
else
  echo " open the tier port once (the PORT key in the tier .env, e.g."
  echo " 8113: sudo firewall-cmd --add-port=8113/tcp or ufw allow 8113/tcp);"
  echo  the tier boots either way.
fi

# The weights path.
WD_STAND=$(bash "$MCFG" get "$VDIR/mtp.env" WEIGHTS_DIR 2>/dev/null || true)
echo
echo  weights download path - install-core verifies the weight folders here
if [ -n "$WD_STAND" ]; then echo "  standing path: $WD_STAND  (a re-run keeps it unless you change it)"; else echo "  no path set yet - stage 4 falls back to the model's own weights folder"; fi
printf '  [enter] keep the path    [c] change: '
IFS= read -r WD || WD=""
if [ "${WD:0:1}" = "c" ] || [ "${WD:0:1}" = "C" ]; then
  printf '  path (a Linux path, e.g. /home/<user>/models): '
  IFS= read -r WDPATH || WDPATH=""
  if [ -n "$WDPATH" ]; then
    for t in mtp nomtp; do bash "$MCFG" set "$VDIR/$t.env" WEIGHTS_DIR "$WDPATH"; done
    echo "  written WEIGHTS_DIR=$WDPATH to all tier machine .envs"
  fi
fi

# ---- [3/3] the core install ----------------------------------------------
echo
bash "$REPO/_shared/scripts/install-core.sh" $MODEL
rc=$?
echo
echo "install exit code $rc - 0 = the model is ready to boot; anything"
echo else ends with the exact step that needs your hands.
exit $rc
