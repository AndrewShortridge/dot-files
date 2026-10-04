#!/usr/bin/env bash
# ksession_save_prompt_dispatch.sh - shell test for ksession-save-prompt.sh's
# KSESSION_IMPL dispatch + validation.
#
# Covers three cases from PRD docs/prds/0001-v1-finish-line.md issue #08:
#   1. KSESSION_IMPL=/bin/true       -> script invokes /bin/true
#   2. KSESSION_IMPL=bash            -> rejected with bare-shell message
#   3. KSESSION_IMPL=/no/such/file   -> rejected with not-executable message
#
# Run under plain bash. Each case runs the prompt script under `bash -x` with
# xtrace redirected to /dev/null so the trace does not clutter test output.
# Self-contained: no test framework deps.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROMPT_SCRIPT="$SCRIPT_DIR/ksession-save-prompt.sh"

if [[ ! -x "$PROMPT_SCRIPT" ]]; then
  echo "FAIL: $PROMPT_SCRIPT is not executable" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d -t ksession-prompt-test.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Fresh sessions dir per run so the overwrite-confirm branch does not fire.
SESSIONS_DIR="$TMP_ROOT/sessions"
mkdir -p "$SESSIONS_DIR"

# Stub PATH: a fake fzf that prints a typed query (testname) so the prompt
# script believes the user typed "testname" and continues to the dispatch.
STUB_BIN="$TMP_ROOT/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
# Stub fzf: emit a single line (the typed query). The real fzf with
# --print-query would emit query on line 1 and selection on line 2; we only
# need line 1.
printf 'testname\n'
EOF
chmod +x "$STUB_BIN/fzf"

# Argv recorder: when invoked, append argv (NUL-separated) to a recorder file.
# We use this as the KSESSION_IMPL target in case 1 instead of literal
# /bin/true so we can assert the script actually invoked it (and with what).
RECORDER_LOG="$TMP_ROOT/recorder.log"
RECORDER_BIN="$TMP_ROOT/recorder.sh"
cat >"$RECORDER_BIN" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$RECORDER_LOG"
exit 0
EOF
chmod +x "$RECORDER_BIN"

PASS=0
FAIL=0

run_case() {
  local label="$1" expected_exit="$2" expected_stderr_pat="$3"
  shift 3
  local extra_env=("$@")

  local out_stdout="$TMP_ROOT/stdout.$$"
  local out_stderr="$TMP_ROOT/stderr.$$"

  # Run with </dev/null so the `read -rp "press enter..."` short-circuits with
  # EOF rather than blocking. Run under bash -x with xtrace redirected to
  # /dev/null per the PRD's testing decision.
  set +e
  env -i \
    HOME="$HOME" \
    PATH="$STUB_BIN:/usr/bin:/bin" \
    KITTY_PROJECT_SESSIONS_DIR="$SESSIONS_DIR" \
    "${extra_env[@]}" \
    bash -x "$PROMPT_SCRIPT" </dev/null >"$out_stdout" 2>"$out_stderr"
  local got_exit=$?
  set -e

  # bash -x emits xtrace to stderr; the test asserts substrings, which still
  # works, but to honor the PRD's "redirect xtrace to /dev/null" wording we
  # strip xtrace lines (start with '+') from the stderr fixture before
  # matching.
  local cleaned_stderr="$TMP_ROOT/stderr_clean.$$"
  grep -v '^+' "$out_stderr" >"$cleaned_stderr" || true

  local ok=1
  if [[ "$got_exit" != "$expected_exit" ]]; then
    ok=0
    echo "FAIL [$label]: exit $got_exit, expected $expected_exit" >&2
    echo "  --- stderr (cleaned) ---" >&2
    sed 's/^/  /' "$cleaned_stderr" >&2
  fi
  if [[ -n "$expected_stderr_pat" ]] && ! grep -qE "$expected_stderr_pat" "$cleaned_stderr"; then
    ok=0
    echo "FAIL [$label]: stderr did not match /$expected_stderr_pat/" >&2
    echo "  --- stderr (cleaned) ---" >&2
    sed 's/^/  /' "$cleaned_stderr" >&2
  fi

  if (( ok )); then
    echo "PASS [$label]"
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi

  rm -f "$out_stdout" "$out_stderr" "$cleaned_stderr"
}

# ----------------------------------------------------------------------------
# Case 1: KSESSION_IMPL points at an executable -> script dispatches to it.
# We point at $RECORDER_BIN (semantically equivalent to /bin/true for the
# script's purposes; exits 0) so we can also assert it was actually invoked
# with `save testname`.
# ----------------------------------------------------------------------------
: >"$RECORDER_LOG"
run_case "dispatch-to-executable" 0 "" "KSESSION_IMPL=$RECORDER_BIN"

if [[ ! -s "$RECORDER_LOG" ]]; then
  echo "FAIL [dispatch-to-executable]: recorder was not invoked" >&2
  FAIL=$((FAIL + 1))
  PASS=$((PASS - 1))
else
  expected_argv=$'save\ntestname'
  got_argv="$(cat "$RECORDER_LOG")"
  if [[ "$got_argv" != "$expected_argv" ]]; then
    echo "FAIL [dispatch-to-executable]: argv mismatch" >&2
    echo "  expected: $(printf %q "$expected_argv")" >&2
    echo "  got:      $(printf %q "$got_argv")" >&2
    FAIL=$((FAIL + 1))
    PASS=$((PASS - 1))
  fi
fi

# Also assert the literal `/bin/true` works (PRD acceptance criterion phrasing).
# /bin/true accepts and ignores all args.
run_case "dispatch-to-bin-true" 0 "" "KSESSION_IMPL=/bin/true"

# ----------------------------------------------------------------------------
# Case 2: KSESSION_IMPL=bash -> bare-shell rejection.
# ----------------------------------------------------------------------------
run_case "reject-bare-shell-bash" 1 \
  "bare shell name" \
  "KSESSION_IMPL=bash"

# Sanity: every banned shell name triggers the same rejection.
for sh_name in sh zsh dash fish; do
  run_case "reject-bare-shell-$sh_name" 1 \
    "bare shell name" \
    "KSESSION_IMPL=$sh_name"
done

# ----------------------------------------------------------------------------
# Case 3: KSESSION_IMPL=/no/such/file -> not-executable rejection.
# ----------------------------------------------------------------------------
run_case "reject-not-executable" 1 \
  "not executable" \
  "KSESSION_IMPL=/no/such/file"

# ----------------------------------------------------------------------------
# Bonus: unset KSESSION_IMPL resolves to the installed Rust binary at
# $HOME/.local/bin/ksession (no bash fallback). Run with a fake HOME so the
# real installed binary is never invoked; the default path then does not
# exist and the not-executable rejection must name it.
# ----------------------------------------------------------------------------
FAKE_HOME="$TMP_ROOT/fakehome"
mkdir -p "$FAKE_HOME"
default_err="$TMP_ROOT/default.err"
set +e
env -i HOME="$FAKE_HOME" PATH="$STUB_BIN:/usr/bin:/bin" \
  KITTY_PROJECT_SESSIONS_DIR="$SESSIONS_DIR" \
  bash -x "$PROMPT_SCRIPT" </dev/null >/dev/null 2>"$default_err"
default_exit=$?
set -e
default_clean="$(grep -v '^+' "$default_err" || true)"
if [[ "$default_exit" == "1" ]] && [[ "$default_clean" == *"$FAKE_HOME/.local/bin/ksession"* ]]; then
  echo "PASS [default-uses-installed-path]"
  PASS=$((PASS + 1))
else
  echo "FAIL [default-uses-installed-path]: exit=$default_exit" >&2
  echo "  stderr (cleaned): $default_clean" >&2
  FAIL=$((FAIL + 1))
fi

echo
echo "----"
echo "passed: $PASS"
echo "failed: $FAIL"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
