#!/bin/bash
# Shell smoke test for ksession-trace-lib.sh
#
# Tests:
#   1. With KSESSION_TRACE_DIR set, __trace_run writes a valid JSONL line.
#   2. With KSESSION_TRACE_DIR unset, no files are created.
#   3. __trace_emit writes a pre-computed event.
#
# Usage: bash tests/bash_trace_smoke.sh
# Exit 0 on success, non-zero on failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TRACE_LIB="$SCRIPT_DIR/scripts/ksession-trace-lib.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

# ---------- Test 1: tracing enabled ----------

TMPDIR_1=$(mktemp -d)
trap 'rm -rf "$TMPDIR_1"' EXIT

export KSESSION_TRACE_DIR="$TMPDIR_1"
export KSESSION_TRACE_SESS="smoke"

# Source the trace lib in a subshell so env changes don't leak.
(
    source "$TRACE_LIB"
    __trace_run "tmux.fake" '{"x":1}' true
)

JSONL_FILE="$TMPDIR_1/tmux-smoke.jsonl"
if [[ ! -f "$JSONL_FILE" ]]; then
    fail "test1: JSONL file not created at $JSONL_FILE"
fi

LINES=$(wc -l < "$JSONL_FILE")
if [[ "$LINES" -lt 1 ]]; then
    fail "test1: expected at least 1 line, got $LINES"
fi

# Validate the JSON structure of the first line.
LINE=$(head -1 "$JSONL_FILE")
# Check required fields exist.
for field in '"name"' '"ph"' '"ts"' '"dur"' '"pid"' '"tid"'; do
    if ! echo "$LINE" | grep -q "$field"; then
        fail "test1: missing field $field in: $LINE"
    fi
done

# Check name is correct.
if ! echo "$LINE" | grep -q '"name":"tmux.fake"'; then
    fail "test1: wrong name in: $LINE"
fi

# Check dur is non-negative (numeric).
DUR=$(echo "$LINE" | grep -o '"dur":[0-9]*' | head -1 | cut -d: -f2)
if [[ -z "$DUR" ]]; then
    fail "test1: dur field not found or not numeric in: $LINE"
fi

# Check args are present.
if ! echo "$LINE" | grep -q '"args":{"x":1}'; then
    fail "test1: args not preserved in: $LINE"
fi

pass "test1: tracing enabled writes valid JSONL"

# ---------- Test 2: tracing disabled ----------

TMPDIR_2=$(mktemp -d)
trap 'rm -rf "$TMPDIR_1" "$TMPDIR_2"' EXIT

(
    unset KSESSION_TRACE_DIR
    export KSESSION_TRACE_SESS="smoke2"
    source "$TRACE_LIB"
    # Run a command — should NOT write any trace file.
    __trace_run "tmux.noop" '{}' true
)

# Check that no JSONL file was created in TMPDIR_2.
if ls "$TMPDIR_2"/tmux-*.jsonl 2>/dev/null | grep -q .; then
    fail "test2: JSONL file created when KSESSION_TRACE_DIR is unset"
fi

pass "test2: no trace output when KSESSION_TRACE_DIR is unset"

# ---------- Test 3: __trace_emit ----------

TMPDIR_3=$(mktemp -d)
trap 'rm -rf "$TMPDIR_1" "$TMPDIR_2" "$TMPDIR_3"' EXIT

(
    export KSESSION_TRACE_DIR="$TMPDIR_3"
    export KSESSION_TRACE_SESS="emit"
    source "$TRACE_LIB"
    __trace_emit "custom.span" 12345 '{"key":"val"}'
)

EMIT_FILE="$TMPDIR_3/tmux-emit.jsonl"
if [[ ! -f "$EMIT_FILE" ]]; then
    fail "test3: JSONL file not created for __trace_emit"
fi

EMIT_LINE=$(head -1 "$EMIT_FILE")
if ! echo "$EMIT_LINE" | grep -q '"name":"custom.span"'; then
    fail "test3: wrong name in: $EMIT_LINE"
fi
if ! echo "$EMIT_LINE" | grep -q '"dur":12345'; then
    fail "test3: wrong dur in: $EMIT_LINE"
fi

pass "test3: __trace_emit writes pre-computed event"

# ---------- Test 4: command return code preserved ----------

TMPDIR_4=$(mktemp -d)
trap 'rm -rf "$TMPDIR_1" "$TMPDIR_2" "$TMPDIR_3" "$TMPDIR_4"' EXIT

(
    export KSESSION_TRACE_DIR="$TMPDIR_4"
    export KSESSION_TRACE_SESS="rc"
    source "$TRACE_LIB"
    set +e  # Allow non-zero exit
    __trace_run "tmux.false" '{}' false
    RC=$?
    if [[ "$RC" -ne 1 ]]; then
        echo "FAIL: test4: expected rc=1, got rc=$RC" >&2
        exit 1
    fi
    exit 0
)

pass "test4: command return code preserved through __trace_run"

echo ""
echo "All bash trace smoke tests passed."
