#!/usr/bin/env bash
# gen-linux-entries.sh - regenerate the native-Linux entry scripts for every
# model. The entry scripts are uniform per model: the only per-model facts
# are MODEL, the tier list (TIER:PORT:CNAME triplets matching the start
# bats), and the bench defaults. Run this after adding a tier or a model;
# the output files are committed, so the repo stays self-contained.
#
#   bash _shared/scripts/gen-linux-entries.sh
set -eu

SRC=${MODEL_RECIPES_SRC:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}
GENS=$SRC/_shared/scripts/gen

emit() { # emit <relpath> ; content on stdin; sets the exec bit
  local out=$SRC/$1
  mkdir -p "$(dirname "$out")"
  # bash chokes on bare parens/semicolons/& in echo args. Any echo line
  # that carries a problem char and no quote char of its own gets
  # double-quote wrapped ($vars still expand). Lines carrying quotes or
  # apostrophes pass untouched and must be clean at the source.
  awk '
    /^[ \t]*echo / && !/["'"'"']/ && /[()&;]/ {
      sub(/^[ \t]*echo /, "&\"");
      sub(/\r?$/, "\"");
    }
    { print }
  ' > "$out"
  chmod +x "$out"
  echo "  wrote $1"
}

# ---------------------------------------------------------------- start-X.sh
gen_start() { # gen_start <model> <tier> <port> <cname> <banner-line...>
  local model=$1 tier=$2 port=$3 cname=$4; shift 4
  local bl="" l
  for l in "$@"; do bl+="echo  $l"$'\n'; done
  emit "$model/vllm/start-$tier.sh" <<EOF
#!/usr/bin/env bash
# start-$tier.sh - the native-Linux twin of start-$tier.bat: the banner,
# the port preflight, then serve.sh (which boots the tier and tails its
# log; Ctrl-C detaches, the container keeps running). The Windows bat's
# watchdog has no native role - there is no WSL distro to keep warm and no
# relay to babysit; the foreground tail IS the window.
set -eu
. "\$(dirname -- "\$0")/../../_shared/scripts/reporoot.sh"
MODEL=$model
TIER=$tier
YML=$tier.yml
PORT=$port
CNAME=$cname

echo ============================================================
echo  serve: \$MODEL / \$YML, the \$TIER tier
echo  port \$PORT, container \$CNAME
echo  stance notes:
${bl}
echo ============================================================
echo

# is the port already listening? another tier or a stale boot
if ss -ltn "( sport = :\$PORT )" 2>/dev/null | grep -q LISTEN; then
  echo
  echo Port \$PORT is already listening - stop the current tenant first
  echo with this model stop script.
  exit 1
fi

echo Booting - weight load + cudagraph capture; first boots run to
echo several minutes. Ctrl-C detaches from the log; the container keeps
echo running. Stop with stop.sh.
echo
bash "\$REPO/_shared/scripts/serve.sh" \$MODEL \$TIER

echo
echo ------------------------------------------------------------
echo The serve process has exited with code \$?. The verdict, as recorded
echo in the runtime area:
bash "\$REPO/_shared/scripts/verdict.sh" show \$MODEL \$TIER
echo ------------------------------------------------------------
echo Reading the verdict (the status file is quoted above):
echo   READY         - the probe answered and a 1-token generation worked;
echo                   the tier is serving (exit code 0).
echo   REFUSED       - a live tier holds this tier pair of cards: stop
echo                   it, then re-run.
echo   DRAIN-TIMEOUT - a just-stopped tier was still shedding VRAM after
echo                   the drain window: re-run once nvidia-smi is clear.
echo   FATAL         - the GPU stack never answered (driver, container
echo                   toolkit, or the pinned pair).
echo   BOOT FAILED / - the container log tail sits above this box; save
echo   TIMEOUT       the window output, then run stop.sh to clean up.
exit \$rc
EOF
}

# ------------------------------------------------------------------ stop.sh
gen_stop() { # gen_stop <model> [tiers...]
  local model=$1; shift
  emit "$model/vllm/stop.sh" <<EOF
#!/usr/bin/env bash
# stop.sh - the native-Linux twin of stop.bat: compose-down every tier of
# $model (package yml + its machine .env), verify the pinned cards and the
# ports release. No watchdog to kill on this side; down.sh is the whole job.
set -u
. "\$(dirname -- "\$0")/../../_shared/scripts/reporoot.sh"
MODEL=$model

echo ============================================================
echo  stop: every tier of \$MODEL
echo   compose-down each tier (package yml + its machine .env),
echo   verify the pinned cards and the ports release
echo ============================================================
echo
bash "\$REPO/_shared/scripts/down.sh" \$MODEL "\$@"
rc=\$?
echo
exit \$rc
EOF
}

# ---------------------------------------------------------------- bench.sh
# gen_bench <model> <nearfull-default> [sibling start list...]
gen_bench() {
  local model=$1 nearfull=$2 port_case=${3:-}
  emit "$model/vllm/bench.sh" <<EOF
#!/usr/bin/env bash
# bench.sh - the native-Linux twin of bench.bat: gate on the shared
# routecheck (a real HTTP request the tier must answer), then run the
# shared bench_speed.py. No WSL relay class exists here, so routecheck's
# exit-3 (listens, never answers) branch has no native cause; a dead
# listener is a dead listener, cleared by stop.sh.
# usage: bench.sh [port] [near-full] [full-out]
# The tier must already be UP; this script never boots anything.
set -u
. "\$(dirname -- "\$0")/../../_shared/scripts/reporoot.sh"
MODEL=$model
PORT=\${1:-}
NEARFULL=\${2:-}
FULLOUT=\${3:-512}
[ -n "\$FULLOUT" ] || FULLOUT=512

command -v python3 >/dev/null 2>&1 || { echo "python3 not found on PATH"; exit 1; }

# no port given: probe the .env-declared ports, take the first live one
if [ -z "\$PORT" ]; then
  for p in \$(sed -n 's/^PORT=\\([0-9][0-9]*\\)\\r\?\$/\\1/p' "\$REPO/\$MODEL/vllm/"*.env 2>/dev/null | LC_ALL=C sort -un); do
    if python3 "\$REPO/_shared/scripts/routecheck.py" "\$p" >/dev/null 2>&1; then PORT=\$p; break; fi
  done
fi
if [ -z "\$PORT" ]; then
  echo
  echo No \$MODEL tier is up: none of the .env-declared ports is answering.
  echo Boot one first (this model start script), then re-run, or pin the
  echo port: bench.sh PORT   (the example port comes from this model tier envs)
  exit 1
fi
if ! python3 "\$REPO/_shared/scripts/routecheck.py" "\$PORT" >/dev/null 2>&1; then
  echo
  echo [bench] port \$PORT is not accepting - the tier is down. Boot it
  echo         first, then re-run this script.
  exit 1
fi
echo [bench] port \$PORT answers - the tier is up; running the shared bench.
[ -n "\$NEARFULL" ] || case \$PORT in
${port_case:-}  *) NEARFULL=$nearfull ;;
esac

OUT=\$REPO/\$MODEL/vllm/logs/bench
mkdir -p "\$OUT"
TS=\$(date +%Y%m%d-%H%M%S)
OUTFILE=\$OUT/bench-\$MODEL-\$PORT-\$TS.txt

echo == bench: \$MODEL, port \$PORT, near-full \$NEARFULL, sample \$FULLOUT == > "\$OUTFILE"
echo    gate: routecheck - real HTTP - harness: shared bench_speed.py >> "\$OUTFILE"

echo
echo Writing the record to \$OUTFILE ...
echo The near-full runs each pay the full prefill; expect a few minutes each.
echo
python3 "\$REPO/_shared/scripts/bench_speed.py" \$PORT \$NEARFULL \$FULLOUT --label \$MODEL >> "\$OUTFILE" 2>&1

echo ------------------------------------------------------------
cat "\$OUTFILE"
echo ------------------------------------------------------------
echo Done - the record above is also at:
echo   \$OUTFILE
echo The tier is left exactly as found. When you are ready: stop.sh,
echo then the next tier start script.
exit 0
EOF
}

# -------------------------------------------------------- bench-parallel.sh
gen_bench_parallel() { # <model>
  local model=$1
  emit "$model/vllm/bench-parallel.sh" <<EOF
#!/usr/bin/env bash
# bench-parallel.sh - the native-Linux twin of bench-parallel.bat: the
# shared climber (bench_parallel.py) fires 2, 4, 8, ... concurrent
# completions at the live tier; a level that breaks is the ceiling.
# usage: bench-parallel.sh [port] [max-n] [tokens]
# The tier must already be UP; this script never boots anything.
set -u
. "\$(dirname -- "\$0")/../../_shared/scripts/reporoot.sh"
MODEL=$model
PORT=\${1:-0}
MAXN=\${2:-8}
TOK=\${3:-16000}

PORTS=\$(sed -n 's/^PORT=\\([0-9][0-9]*\\)\\r\?\$/\\1/p' "\$REPO/\$MODEL/vllm/"*.env 2>/dev/null | LC_ALL=C sort -un | paste -sd, -)

OUT=\$REPO/\$MODEL/vllm/logs/bench
mkdir -p "\$OUT"
TS=\$(date +%Y%m%d-%H%M%S)
OUTFILE=\$OUT/bench-parallel-\$MODEL-\$PORT-\$TS.txt

echo ============================================================
echo  bench-parallel: \$MODEL
echo  climbs concurrent streams 2, 4, 8, ... up to max-n \$MAXN.
echo  port: \$PORT   0 = whichever \$MODEL tier is up
echo  candidate ports: \$PORTS
echo  record: \$OUTFILE
echo ============================================================
echo
echo == bench-parallel: \$MODEL, port \$PORT, max-n \$MAXN, tokens \$TOK == > "\$OUTFILE"
python3 "\$REPO/_shared/scripts/bench_parallel.py" --port \$PORT --ports \$PORTS --max-n \$MAXN --tokens \$TOK --label \$MODEL >> "\$OUTFILE" 2>&1
echo ------------------------------------------------------------
cat "\$OUTFILE"
echo ------------------------------------------------------------
echo Done - the record above is also at:
echo   \$OUTFILE
exit 0
EOF
}

# ------------------------------------------------------------- uninstall.sh
gen_uninstall() { # <model>
  local model=$1
  emit "$model/vllm/uninstall.sh" <<EOF
#!/usr/bin/env bash
# uninstall.sh - the native-Linux twin of uninstall.bat: the model's
# tiers down, the runtime area and images removed (uninstall-core.sh),
# then done - the tree folder and the weights always stay.
set -eu
. "\$(dirname -- "\$0")/../../_shared/scripts/reporoot.sh"
MODEL=$model

echo ============================================================
echo  model-recipes uninstall: \$MODEL
echo   [1/2] down + runtime area + images (uninstall-core.sh)
echo   [2/2] the tree folder and weights stay (nothing else to remove)
echo ============================================================
echo
bash "\$REPO/_shared/scripts/uninstall-core.sh" \$MODEL
rc=\$?
echo
echo "  the tree folder (\$REPO/\$MODEL) stays, weights included -"
echo "  a re-install re-runs the wizard. Delete it by hand if you want the space."
exit \$rc
EOF
}

# ---------------------------------------------------------------- install.sh
gen_install() { # <model> [tiers...]
  local model=$1; shift
  local tiers="$*"
  emit "$model/vllm/install.sh" <<EOF
#!/usr/bin/env bash
# install.sh - the native-Linux twin of install.bat: the prereq gate, the
# machine-env wizard (device pair, serve bind, weights path - the same
# mcfg files the Windows bats own), then install-core.sh stages env,
# runtime area, images, weights, manifest. Every step is idempotent; a
# re-run keeps the standing answers unless you change them.
set -u
. "\$(dirname -- "\$0")/../../_shared/scripts/reporoot.sh"
MODEL=$model
VDIR=\$REPO/\$MODEL/vllm
MCFG="\$REPO/_shared/scripts/mcfg.sh"
TIERS="$tiers"

echo ============================================================
echo  model-recipes install: \$MODEL (native Linux)
echo   [1/3] the prereq gate
echo   [2/3] the machine-env wizard (DEVICE_PAIR, BIND_HOST, WEIGHTS_DIR)
echo   [3/3] install-core.sh (env, runtime area, images, weights, manifest)
echo ============================================================
echo

# ---- [1/3] the prereq gate (CachyOS/Arch-class pacman fixes) -------------
FAIL=0
if ! command -v docker >/dev/null 2>&1; then
  echo "  [NO] docker            fix: sudo pacman -S docker && sudo systemctl enable --now docker"
  FAIL=1
elif ! docker info >/dev/null 2>&1; then
  echo "  [NO] docker daemon     fix: sudo systemctl enable --now docker; add yourself: sudo usermod -aG docker \$USER"
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
if [ "\$FAIL" = 1 ]; then
  echo
  echo  fix the [NO] lines, then re-run this script; nothing was changed.
  exit 1
fi
echo "  [ok] prereqs"

# ---- [2/3] the machine-env wizard ----------------------------------------
# The device pair: two picks, written to every tier's machine .env.
echo
echo  device pair - the two cards every tier runs on (tensor-parallel-2
echo  needs both). Standing pair:
PAIR_STAND=\$(bash "\$MCFG" get "\$VDIR/${tiers%% *}.env" DEVICE_PAIR 2>/dev/null || true)
if [ -n "\$PAIR_STAND" ]; then echo "  \$PAIR_STAND  (a re-run keeps it unless you change it)"; else echo "  none set yet - the package default is 0,1"; fi
PICK=\$(bash "\$REPO/_shared/scripts/pickpair.sh" | tail -n1) || true
if [ -n "\${PICK:-}" ] && [ "\$PICK" != "PAIR_KEEP=1" ]; then
  PAIR=\${PICK#PAIR=}
  ok=1
  for t in $tiers; do bash "\$MCFG" set "\$VDIR/\$t.env" DEVICE_PAIR "\$PAIR" || ok=0; done
  if [ "\$ok" = 1 ]; then
    echo "  written DEVICE_PAIR=\$PAIR to all tier machine .envs"
  else
    echo "  WARNING: some tier .env writes failed - check DEVICE_PAIR in each \$VDIR/<tier>.env" >&2
  fi
fi

# The serve bind.
BIND_STAND=\$(bash "\$MCFG" get "\$VDIR/${tiers%% *}.env" BIND_HOST 2>/dev/null || true)
echo
echo  serve bind - the address the tier binds to when it is up:
echo    0.0.0.0    every interface (the package default; the LAN reaches it)
echo    127.0.0.1  the loopback only
echo    an IP      only that address
if [ -n "\$BIND_STAND" ]; then echo "  standing bind: \$BIND_STAND  (a re-run keeps it unless you change it)"; fi
printf '  [enter] keep   [o]pen 0.0.0.0  [l]ocal 127.0.0.1  [a] an address: '
IFS= read -r SB || SB=""
case "\$SB" in
  o|O) SB_VAL=0.0.0.0 ;;
  l|L) SB_VAL=127.0.0.1 ;;
  a|A) printf '  address (enter = 0.0.0.0): '; IFS= read -r ADDR || ADDR=""; SB_VAL=\${ADDR:-0.0.0.0} ;;
  *) SB_VAL="" ;;
esac
if [ -n "\$SB_VAL" ]; then
  for t in $tiers; do bash "\$MCFG" set "\$VDIR/\$t.env" BIND_HOST "\$SB_VAL"; done
  echo "  written BIND_HOST=\$SB_VAL to all tier machine .envs"
fi

# The firewall note (the bat's firewall.bat step; one manual line here).
# PORT may be unset at install time (tier-boot knob), so the note stays
# generic unless a standing port exists in the environment.
echo
echo  firewall - if the LAN must reach the tier and the firewall is on,
if [ -n "\${PORT:-}" ]; then
  echo  open the tier port once (e.g.: sudo firewall-cmd --add-port=\$PORT/tcp
  echo  or ufw allow \$PORT/tcp); the tier boots either way.
else
  echo  open the tier port once (the PORT key in the tier .env, e.g.
  echo  8113: sudo firewall-cmd --add-port=8113/tcp or ufw allow 8113/tcp);
  echo  the tier boots either way.
fi

# The weights path.
WD_STAND=\$(bash "\$MCFG" get "\$VDIR/${tiers%% *}.env" WEIGHTS_DIR 2>/dev/null || true)
echo
echo  weights download path - install-core verifies the weight folders here
if [ -n "\$WD_STAND" ]; then echo "  standing path: \$WD_STAND  (a re-run keeps it unless you change it)"; else echo "  no path set yet - stage 4 falls back to the model's own weights folder"; fi
printf '  [enter] keep the path    [c] change: '
IFS= read -r WD || WD=""
if [ "\${WD:0:1}" = "c" ] || [ "\${WD:0:1}" = "C" ]; then
  printf '  path (a Linux path, e.g. /home/<user>/models): '
  IFS= read -r WDPATH || WDPATH=""
  if [ -n "\$WDPATH" ]; then
    for t in $tiers; do bash "\$MCFG" set "\$VDIR/\$t.env" WEIGHTS_DIR "\$WDPATH"; done
    echo "  written WEIGHTS_DIR=\$WDPATH to all tier machine .envs"
  fi
fi

# ---- [3/3] the core install ----------------------------------------------
echo
bash "\$REPO/_shared/scripts/install-core.sh" \$MODEL
rc=\$?
echo
echo install exit code \$rc - 0 = the model is ready to boot; anything
echo else ends with the exact step that needs your hands.
exit \$rc
EOF
}

# =====================================================================
# The model registry. TIER:PORT:CNAME matches each model's start bats.
# The stance banner lines after each gen_start call are quoted from the
# bat, so the two entry surfaces say the same thing.
# =====================================================================

# ---- qwen3.8-27b: 8 tiers (incl. the Swift pair and the KVarN trio) ----
gen_install   qwen3.8-27b mtp nomtp superfast swift-mtp swift-nomtp kvarntier kvarndflash2 kvarnmtp
gen_start     qwen3.8-27b mtp 8113 qwen-27b-serve "stance: MTP - vllm/mtp.env carries SPEC_N=4 + the 09-08 window and seqs." "caveat: the drafter costs ~13% of the KV pool; #1096/#50021 both cut against sustained agent traffic." "the drafter-off tier is start-nomtp.sh: its own package yml + machine .env."
gen_start     qwen3.8-27b nomtp 8113 qwen-27b-nomtp-serve "stance: MTP off - the plain tier, the fallback when the drafter cuts against the traffic."
gen_start     qwen3.8-27b superfast 8104 qwen-27b-superfast-serve "stance: superfast - the speed-tuned tier."
gen_start     qwen3.8-27b swift-mtp 8113 qwen-27b-swift-serve "stance: swift + MTP."
gen_start     qwen3.8-27b swift-nomtp 8113 qwen-27b-swift-nomtp-serve "stance: swift, drafter off."
gen_start     qwen3.8-27b kvarntier 8116 qwen-27b-kvarn-serve "stance: kvarn tier."
gen_start     qwen3.8-27b kvarndflash2 8117 qwen-27b-kvarndflash2-serve "stance: dflash2 + w4a16."
gen_start     qwen3.8-27b kvarnmtp 8116 qwen-27b-kvarnmtp-serve "stance: kvarn + MTP."
gen_stop      qwen3.8-27b
gen_bench     qwen3.8-27b 250000
gen_bench_parallel qwen3.8-27b
gen_uninstall qwen3.8-27b

# ---- qwen3.8-flash-next: 2 tiers ----
gen_install   qwen3.8-flash-next mtp nomtp
gen_start     qwen3.8-flash-next mtp 8115 qwen38-flashnext-serve "stance: MTP at depth 3 (variable-K scheduler) - the proven rung t24, 35.65 tok/s sustained:" "the 256,000 window, the 4.13 GiB KV pool, the 30 GiB/rank expert offload, 84 hot LRU slots." "the drafter-off tier is start-nomtp.sh - port 8116."
gen_start     qwen3.8-flash-next nomtp 8116 qwen38-flashnext-nomtp-serve "stance: MTP off - the drafter-off sibling."
gen_stop      qwen3.8-flash-next
gen_bench     qwen3.8-flash-next 250000
gen_bench_parallel qwen3.8-flash-next
gen_uninstall qwen3.8-flash-next

# ---- gemma4-31b: 2 tiers ----
gen_install   gemma4-31b gemma-dual gemma-dual-nomtp
gen_start     gemma4-31b gemma-dual 8032 gemma-serve "stance: MTP drafter arm ON by default (SPEC_N=2); set SPEC_N=0 in its config to kill it." "every other tier on this box pins the same two cards - park them before this boot."
gen_start     gemma4-31b gemma-dual-nomtp 8033 gemma-serve-nomtp "stance: MTP off - the drafter-off sibling."
gen_stop      gemma4-31b
gen_bench     gemma4-31b 250000 '  8032) NEARFULL=170000 ;;
  8033) NEARFULL=185000 ;;
'
gen_bench_parallel gemma4-31b
gen_uninstall gemma4-31b

echo "done."
