#!/usr/bin/env bash
# =============================================================================
# Shadow the cluster's /usr/bin/vi with the containerised Neovim
# =============================================================================
# Install on the cluster as ~/bin/nvim, then point the classic names at it:
#
#   mkdir -p ~/bin
#   cp hpc-vi-wrapper.sh ~/bin/nvim && chmod +x ~/bin/nvim
#   ln -sf nvim ~/bin/vi
#   ln -sf nvim ~/bin/vim
#   ln -sf nvim ~/bin/view
#
# See container/README.md for PATH setup (and for the noexec case, where these
# are called as `bash ~/bin/nvim` from shell functions instead).
#
# A wrapper, not a shell alias: aliases exist only in interactive shells, so
# they are invisible to git, crontab, sbatch, mutt and anything else that
# execs $EDITOR.
#
# -----------------------------------------------------------------------------
# This script stays deliberately small. Everything that CAN live in the image
# does -- see nvim.def:
#
#   XDG_RUNTIME_DIR   %environment drops the host value, which names a
#                     /run/user path Apptainer never binds, so Neovim falls
#                     back to its own private /tmp dir
#   fdfind            a symlink onto conda's `fd`, plus name resolution in
#                     lua/andrew/plugins/fzf-lua.lua
#   CONDA_PREFIX      set to /opt/conda so formatter paths resolve
#   mason's bin dir   put on PATH
#
# What is left here is only what must happen on the HOST, before the container
# exists: find apptainer, find the image, decide the bind list, and pick
# read-only mode from the name the user typed.
# -----------------------------------------------------------------------------
set -euo pipefail

SIF="${NVIM_SIF:-$HOME/bin/nvim.sif}"

# Load apptainer if it is behind a module and not already on PATH.
#
# `module` is a shell FUNCTION defined by the site's profile script, and shell
# functions do not survive into a non-interactive script. So source the modules
# init file first; otherwise `command -v module` fails here and the wrapper
# falls back to /usr/bin/vi even though apptainer is perfectly available.
if ! command -v apptainer >/dev/null 2>&1; then
  if ! command -v module >/dev/null 2>&1; then
    for init in "${MODULESHOME:-}/init/bash" /usr/share/Modules/init/bash /etc/profile.d/modules.sh; do
      [ -f "$init" ] && . "$init" && break
    done
  fi
  if command -v module >/dev/null 2>&1; then
    module load apptainer/1.5.3 >/dev/null 2>&1 \
      || module load apptainer >/dev/null 2>&1 \
      || module load singularity >/dev/null 2>&1 || true
  fi
fi

if ! command -v apptainer >/dev/null 2>&1; then
  echo "${0##*/}: apptainer not available; falling back to /usr/bin/vi" >&2
  exec /usr/bin/vi "$@"
fi

if [ ! -f "$SIF" ]; then
  echo "${0##*/}: image not found at $SIF (set NVIM_SIF to override)" >&2
  exec /usr/bin/vi "$@"
fi

# Bind the filesystems that actually hold work. $HOME, $PWD and /tmp are
# automatic. Only pass paths that exist, or apptainer refuses to start.
BINDS=""
for d in /scratch /work /project /gpfs /shared; do
  [ -d "$d" ] && BINDS="${BINDS:+$BINDS,}$d"
done

# `view` should open read-only, matching the system tool it replaces. This has
# to be decided out here: inside the container there is no way to tell which
# name the user actually invoked.
case "${0##*/}" in
  view) set -- -R "$@" ;;
esac

exec apptainer run ${BINDS:+--bind "$BINDS"} "$SIF" "$@"
