#!/usr/bin/env bash
# Smoke test for ksession_nvim_dirty.lua
# Verifies the plugin emits correct OSC 1337 SetUserVar sequences.
# Does NOT require a running kitty instance.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$SCRIPT_DIR/scripts/ksession_nvim_dirty.lua"

# --- Skip checks -----------------------------------------------------------

if ! command -v nvim &>/dev/null; then
    echo "SKIP: nvim not found in PATH"
    exit 0
fi

# Check nvim version >= 0.10 (needed for vim.base64)
NVIM_VER=$(nvim --version | head -1 | grep -oP '\d+\.\d+')
MAJOR=$(echo "$NVIM_VER" | cut -d. -f1)
MINOR=$(echo "$NVIM_VER" | cut -d. -f2)
if (( MAJOR == 0 && MINOR < 10 )); then
    echo "SKIP: nvim >= 0.10 required (found $NVIM_VER)"
    exit 0
fi

# --- Helpers ----------------------------------------------------------------

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

SOCK="$TMPDIR_TEST/nvim_test.sock"

# --- Test 1: VimEnter emits nvim_socket with base64-encoded servername ------

echo "=== Test 1: register_socket emits nvim_socket OSC 1337 on VimEnter ==="
OUTPUT=$(nvim --headless -u NONE \
    --listen "$SOCK" \
    -c "luafile $PLUGIN" \
    -c "doautocmd VimEnter" \
    -c "qa!" 2>/dev/null || true)

if echo "$OUTPUT" | grep -qP '\x1b\]1337;SetUserVar=nvim_socket='; then
    echo "PASS: nvim_socket OSC sequence found"
else
    echo "FAIL: nvim_socket OSC sequence not found in output"
    echo "Output (escaped): $(echo "$OUTPUT" | cat -v)"
    exit 1
fi

# Verify the payload is valid base64 that decodes to the exact socket path
# (i.e. matches vim.v.servername which equals the --listen argument).
B64_PAYLOAD=$(echo "$OUTPUT" | grep -oP '(?<=nvim_socket=)[A-Za-z0-9+/=]+')
DECODED=$(echo "$B64_PAYLOAD" | base64 -d 2>/dev/null || true)
if [[ "$DECODED" == "$SOCK" ]]; then
    echo "PASS: decoded socket path matches vim.v.servername exactly ($DECODED)"
else
    echo "FAIL: decoded payload '$DECODED' does not match expected '$SOCK'"
    exit 1
fi

# Clean up the socket for the next test invocation
rm -f "$SOCK"

# --- Test 2: BufWritePost emits nvim_dirty with base64-encoded timestamp ----

echo ""
echo "=== Test 2: emit_dirty emits nvim_dirty OSC 1337 on BufWritePost ==="
TMPFILE="$TMPDIR_TEST/testfile.txt"
OUTPUT=$(nvim --headless -u NONE \
    -c "luafile $PLUGIN" \
    -c "edit $TMPFILE" \
    -c "normal ihello" \
    -c "write" \
    -c "qa!" 2>/dev/null || true)

if echo "$OUTPUT" | grep -qP '\x1b\]1337;SetUserVar=nvim_dirty='; then
    echo "PASS: nvim_dirty OSC sequence found (BufWritePost)"
else
    echo "FAIL: nvim_dirty OSC sequence not found in output"
    echo "Output (escaped): $(echo "$OUTPUT" | cat -v)"
    exit 1
fi

# Verify the payload decodes to a numeric timestamp
B64_PAYLOAD=$(echo "$OUTPUT" | grep -oP '(?<=nvim_dirty=)[A-Za-z0-9+/=]+' | tail -1)
DECODED=$(echo "$B64_PAYLOAD" | base64 -d 2>/dev/null || true)
if [[ "$DECODED" =~ ^[0-9]+$ ]]; then
    echo "PASS: decoded timestamp is numeric ($DECODED)"
else
    echo "FAIL: decoded payload '$DECODED' is not a numeric timestamp"
    exit 1
fi

# --- Test 3: BufEnter also emits nvim_dirty (regression coverage) -----------

echo ""
echo "=== Test 3: emit_dirty emits nvim_dirty OSC 1337 on BufEnter ==="
OUTPUT=$(nvim --headless -u NONE \
    -c "luafile $PLUGIN" \
    -c "doautocmd BufEnter" \
    -c "qa!" 2>/dev/null || true)

if echo "$OUTPUT" | grep -qP '\x1b\]1337;SetUserVar=nvim_dirty='; then
    echo "PASS: nvim_dirty OSC sequence found (BufEnter)"
else
    echo "FAIL: nvim_dirty OSC sequence not found in output"
    echo "Output (escaped): $(echo "$OUTPUT" | cat -v)"
    exit 1
fi

B64_PAYLOAD=$(echo "$OUTPUT" | grep -oP '(?<=nvim_dirty=)[A-Za-z0-9+/=]+')
DECODED=$(echo "$B64_PAYLOAD" | base64 -d 2>/dev/null || true)
if [[ "$DECODED" =~ ^[0-9]+$ ]]; then
    echo "PASS: decoded timestamp is numeric ($DECODED)"
else
    echo "FAIL: decoded payload '$DECODED' is not a numeric timestamp"
    exit 1
fi

echo ""
echo "All tests passed."
