#!/usr/bin/env bash
# Runner for the which_key Python test suite (the repo's first Python tests).
# Mirrors scripts/tests/modal_fsm/run.sh: runnable directly, zero third-party
# deps, uses the kitty-bundled python3 via stdlib unittest discovery.
#
# Run: `bash scripts/tests/which_key/run.sh` from the repo root, or execute
# this script directly. (pytest also collects these files if preferred:
# `pytest scripts/tests/which_key`.)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -m unittest discover -s "$here" -p 'test_*.py' -v
