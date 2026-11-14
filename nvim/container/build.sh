#!/usr/bin/env bash
# =============================================================================
# Build the Neovim Apptainer image
# =============================================================================
# Run from anywhere; the build context is always the repo root, because
# nvim.def's `%files` entries (init.lua, lua/, snippets/, doc/, tests/, ...)
# are paths relative to the current directory.
#
#   ./container/build.sh              -> container/nvim.sif
#   ./container/build.sh /tmp/foo.sif -> that path instead
#
# Needs apptainer with --fakeroot (no sudo). Most HPC sites do NOT allow
# building on login nodes: build on a workstation and scp the .sif over.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$REPO_ROOT/container/nvim.sif}"
DEF="$REPO_ROOT/container/nvim.def"

command -v apptainer >/dev/null || {
  echo "apptainer not found." >&2
  echo "  Ubuntu/Pop!_OS:  sudo add-apt-repository -y ppa:apptainer/ppa && sudo apt install -y apptainer" >&2
  echo "  HPC:             module load apptainer   (or singularity)" >&2
  exit 1
}

# -----------------------------------------------------------------------------
# Pick a rootless build strategy.
#
#   --fakeroot   the supported path. Needs newuidmap/newgidmap (the `uidmap`
#                package) when the user has /etc/subuid entries. This is what
#                you get on a cluster, and what UConn Storrs provides.
#
#   unshare      fallback for a workstation that has user namespaces but no
#                uidmap package. We become root in our own namespace, which is
#                enough for apptainer to run %post. Single-uid mapping only,
#                hence the APT::Sandbox::User workaround in the def file.
# -----------------------------------------------------------------------------
if command -v newuidmap >/dev/null 2>&1 || ! grep -q "^$(id -un):" /etc/subuid 2>/dev/null; then
  BUILD_MODE="fakeroot"
elif unshare --user --map-root-user true 2>/dev/null; then
  BUILD_MODE="unshare"
else
  echo "No rootless build path available." >&2
  echo "  Either install uidmap:  sudo apt install uidmap" >&2
  echo "  or enable unprivileged user namespaces." >&2
  exit 1
fi

echo "==> building $OUT"
echo "    context:  $REPO_ROOT"
echo "    strategy: $BUILD_MODE"
echo "    this pulls ~49 plugins, ~600MB of language servers and openmpi; expect 20-40 min"

: "${APPTAINER_TMPDIR:=${TMPDIR:-/tmp}/apptainer-$(id -u)}"
mkdir -p "$APPTAINER_TMPDIR"
export APPTAINER_TMPDIR

cd "$REPO_ROOT"
if [ "$BUILD_MODE" = "fakeroot" ]; then
  apptainer build --fakeroot --force "$OUT" "$DEF"
else
  unshare --user --map-root-user --mount \
    env PATH="$PATH" APPTAINER_TMPDIR="$APPTAINER_TMPDIR" \
    apptainer build --force "$OUT" "$DEF"
fi

echo "==> verifying"
apptainer test "$OUT"

echo
echo "==> done: $OUT ($(du -h "$OUT" | cut -f1))"
echo "    copy to the cluster:  scp $OUT user@hpc:~/bin/"
