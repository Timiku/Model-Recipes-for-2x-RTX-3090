#!/usr/bin/env bash
# env-setup.sh — the in-distro prerequisites (docker + the nvidia container
# runtime), installed through the distro's root account. The wizard's
# Windows side drives this as:
#
#     wsl -d <distro> -u root -- bash <repo>/_shared/scripts/env-setup.sh [username]
#
# WSL gives the Windows user a passwordless root: no Windows admin
# rights, no password prompt, no MOTW — which is exactly what makes the
# otherwise-"sudo" prerequisite auto-install work. Every step checks
# before it acts; re-running is a no-op.
#
# what it does:
#   docker              apt install docker.io when the CLI is missing
#   the docker daemon   started (systemd when running, else the init
#                       script service docker start)
#   the nvidia runtime  the NVIDIA WSL CUDA repo + nvidia-container-toolkit,
#                       nvidia-ctk runtime configure --runtime=docker, a
#                       docker restart
#   the docker group    the wizard's own user (that [username] argument)
#                       added to it - the daemon's socket admits only root
#                       and group members, and every wizard/bat session
#                       runs as that user
#   the compose plugin  installed from the distro's repos when this docker
#                       lacks it - a plugin-less docker reads `docker
#                       compose -f ... -f ...` as "unknown flag" and the
#                       tier's boots die before a container exists
#
# exit: 0 = everything in place; 1 = stopped, with the exact manual path
# the box still needs; 2 = not run as the distro's root.
[ "$#" -le 1 ] || { echo "      env-setup takes at most one argument (the user to add to the docker group)"; exit 2; }
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "      env-setup needs the distro's root account; the wizard drives"
  echo "      it as: wsl -d <distro> -u root -- bash <repo>/_shared/scripts/"
  echo "      env-setup.sh - run that, then re-run this stage."
  exit 2
fi

have_sysd() {
  command -v systemctl >/dev/null 2>&1 \
    && systemctl is-system-running >/dev/null 2>&1
}
# The docker daemon's socket only admits root and members of the docker
# group. A fresh WSL distro's user is neither, and every wizard/bat
# session runs as that user - so the wizard passes its own username
# ($1) and we add it to the group here, where we already are root.
ensure_docker_group() {
  local u="${1:-}"
  if [ -n "$u" ] && id -u "$u" >/dev/null 2>&1; then
    if id -nG "$u" | grep -qw docker; then
      echo "      docker group: $u is already a member"
    elif usermod -aG docker "$u" >/dev/null 2>&1; then
      echo "      docker group: added $u (the wizard's next wsl"
      echo "      session already sees it - no re-login from your side)"
    else
      echo "      adding $u to the docker group failed; in the distro:"
      echo "        usermod -aG docker $u    (then a new distro terminal)"
    fi
  elif [ -n "$u" ]; then
    echo "      (the passed user $u does not exist in this distro; if the"
    echo "      wizard's docker calls are refused: usermod -aG docker <you>)"
  fi
}

# ---- docker ----
if ! command -v docker >/dev/null 2>&1; then
  echo "      docker missing - apt install of docker.io, as root..."
  apt-get update -qq
  apt-get install -y -qq docker.io \
    || { echo "      FATAL: apt could not install docker.io (the lines above say why)"; exit 1; }
fi
if ! docker info >/dev/null 2>&1; then
  echo "      the docker daemon is not answering - starting it..."
  if have_sysd; then systemctl enable --now docker
  else service docker start; fi
fi
if ! docker info >/dev/null 2>&1; then
  echo "      FATAL: docker is installed but the daemon will not start."
  echo "      In the distro as root:  journalctl -u docker   or   service docker status"
  exit 1
fi
echo "      docker: OK"
ensure_docker_group "${1:-}"
# ---- the docker compose plugin ---------------------------------------------
# A fresh docker.io install does not always carry the compose plugin, and
# a docker without it parses `docker compose <flags>` as an unknown flag
# of its own - the tiers' compose calls are driven through `docker compose
# -f <yml> -f <machine delta>`, so the boot would die before any container existed.
if ! docker compose version >/dev/null 2>&1; then
  echo "      docker compose plugin missing - apt-get install docker-compose-v2"
  if ! apt-get install -y -qq docker-compose-v2; then
    fail "could not install the docker compose plugin (the docker-compose-v2 package)"
  fi
fi
if ! docker compose version >/dev/null 2>&1; then
  fail "the docker compose plugin is still missing after the install - that distro's repos do not carry docker-compose-v2; these recipes need a 22.04-class WSL Ubuntu distro"
fi
echo "      docker compose: OK"

# ---- the nvidia container runtime ----
if docker info 2>/dev/null | grep -q 'nvidia'; then
  echo "      nvidia runtime for docker: OK"
  exit 0
fi
echo "      nvidia runtime missing - the NVIDIA WSL repo + the toolkit..."
command -v curl >/dev/null 2>&1 || apt-get install -y -qq curl
if curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb \
     -o /tmp/cuda-keyring.deb \
   && dpkg -i /tmp/cuda-keyring.deb >/dev/null 2>&1 \
   && apt-get update -qq \
   && apt-get install -y -qq nvidia-container-toolkit \
   && nvidia-ctk runtime configure --runtime=docker; then
  if have_sysd; then systemctl restart docker; else service docker restart; fi
fi
if docker info 2>/dev/null | grep -q 'nvidia'; then
  echo "      nvidia runtime for docker: OK"
else
  echo "      FATAL: the nvidia-container-toolkit path did not complete; the"
  echo "      lines above say where. In the distro as root:"
  echo "        apt-get update && apt-get install -y nvidia-container-toolkit"
  echo "        nvidia-ctk runtime configure --runtime=docker"
  echo "        systemctl restart docker   (or: service docker restart)"
  exit 1
fi
