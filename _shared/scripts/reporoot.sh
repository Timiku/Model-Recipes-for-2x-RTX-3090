#!/usr/bin/env bash
# reporoot.sh - the native-Linux twin of reporoot.ps1. Sourced, not run:
#
#   . "$(dirname -- "${BASH_SOURCE[0]}")/../.."  # no - use reporoot directly
#
# Sourcing contract (mirrors reporoot.ps1's KEY=value output):
#
#   . _shared/scripts/reporoot.sh     # sets REPO and REPO_LINUX in this shell
#
# The script's own location: _shared/scripts/, so the repo root is two
# levels up. REPO is the plain Linux path; there is no WSL /mnt form here -
# that is reporoot.ps1's job, and it stays the Windows path's translator.

_REPORN="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO="$_REPORN"
export REPO_LINUX="$_REPORN"
unset _REPORN
