#!/usr/bin/env bash
# Shared harness for the ksession tmux script tests.
#
# Sourced by tests/*/run.sh. Provides:
#   - a scratch `tmux -L` server (config-free, killed on exit),
#   - a stub `ksession` (KSESSION_IMPL) that records argv and answers
#     `tmux list --porcelain` from a canned file,
#   - a stub `fzf` first on PATH that replays a scripted key/query/selection
#     sequence (fzf is modal, so --filter/--select-1 can't drive it),
#   - PASS/FAIL bookkeeping in the style of kitty/scripts/tests/*/run.sh.
#
# Everything lives under a per-run tempdir; HOME is redirected there so
# logs, frecency stores and caches never touch the real home directory.

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HARNESS_DIR/../.." && pwd)"
KITTY_LIB_DIR="${KSESSION_SCRIPT_LIB:-$HOME/.config/kitty/scripts/lib}"

pass=0
fail=0
failed_names=()

ok()   { echo "PASS $1"; pass=$((pass + 1)); }
bad()  { local label="$1"; shift; echo "FAIL $label"; printf '       %s\n' "$@"; fail=$((fail + 1)); failed_names+=("$label"); }

# assert_eq <label> <want> <got>
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    ok "$label"
  else
    bad "$label" "want: $want" "got:  $got"
  fi
}

# assert_contains <label> <haystack> <needle>
assert_contains() {
  local label="$1" hay="$2" needle="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    ok "$label"
  else
    bad "$label" "missing: $needle" "in: $hay"
  fi
}

# assert_not_contains <label> <haystack> <needle>
assert_not_contains() {
  local label="$1" hay="$2" needle="$3"
  if [[ "$hay" != *"$needle"* ]]; then
    ok "$label"
  else
    bad "$label" "unexpected: $needle" "in: $hay"
  fi
}

finish() {
  echo
  echo "Results: $pass passed, $fail failed."
  if (( fail > 0 )); then
    printf '  - %s\n' "${failed_names[@]}"
    exit 1
  fi
  exit 0
}

# ---- scratch environment -----------------------------------------------------

require_tools() {
  local missing=()
  for t in tmux jq; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if (( ${#missing[@]} )); then
    echo "skip: missing ${missing[*]}" >&2
    exit 0
  fi
  if [[ ! -f "$KITTY_LIB_DIR/modal_fsm.sh" ]]; then
    echo "skip: kitty script lib not found at $KITTY_LIB_DIR" >&2
    exit 0
  fi
}

# setup_env: creates $T (tempdir), redirects HOME, installs the stubs and
# starts a scratch tmux server with one session `demo`. Exports the env
# the scripts under test read.
setup_env() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/ksession-tmux-test.XXXXXX")"
  export HOME="$T/home"
  mkdir -p "$HOME/.cache" "$T/bin" "$T/root"

  export KSESSION_SCRIPT_LIB="$KITTY_LIB_DIR"
  export KSESSION_TMUX_SESSIONS_DIR="$T/root"
  export KSESSION_PICKER_NO_CONFIRM=1
  export FRECENCY_STORE="$T/frecency.json"
  export FRECENCY_LOG="$T/frecency.log"
  export KSESSION_TMUX_LOG="$T/ksession.log"

  export STUB_LOG="$T/ksession-argv.log"
  export STUB_LIST="$T/list.porcelain"
  : > "$STUB_LIST"
  export KSESSION_IMPL="$T/bin/ksession"
  install_stub_ksession

  export FZF_STUB_SCRIPT="$T/fzf.script"
  export FZF_STUB_COUNTER="$T/fzf.counter"
  : > "$FZF_STUB_SCRIPT"
  install_stub_fzf
  export PATH="$T/bin:$PATH"

  TMUX_SOCK="ksession-script-test-$$"
  tmux -f /dev/null -L "$TMUX_SOCK" new-session -d -s demo -x 120 -y 40
  local sock_path pid sid
  sock_path="$(tmux -L "$TMUX_SOCK" display-message -p '#{socket_path}')"
  pid="$(tmux -L "$TMUX_SOCK" display-message -p '#{pid}')"
  # #{session_id} is "$N"; the real $TMUX carries the bare number.
  sid="$(tmux -L "$TMUX_SOCK" display-message -p -t demo '#{session_id}')"
  export TMUX="$sock_path,$pid,${sid#\$}"
  trap teardown_env EXIT
}

teardown_env() {
  [[ -n "${CONTROL_FIFO:-}" ]] && exec 3>&-
  tmux -L "$TMUX_SOCK" kill-server 2>/dev/null || true
  rm -rf "$T"
}

# attach_control_client: attaches a control-mode client (`tmux -C`) to
# `demo` so `switch-client` has a client to act on — the scratch server
# has no tty otherwise. fd 3 holds the client's stdin open until teardown.
attach_control_client() {
  CONTROL_FIFO="$T/control.fifo"
  mkfifo "$CONTROL_FIFO"
  tmux -L "$TMUX_SOCK" -C attach-session -t demo <"$CONTROL_FIFO" >/dev/null 2>&1 &
  exec 3>"$CONTROL_FIFO"
  local _i
  for _i in $(seq 1 50); do
    [[ -n "$(client_session)" ]] && return 0
    sleep 0.1
  done
  echo "control client did not attach to the scratch server" >&2
  exit 2
}

# client_session: the session the control client is currently attached to.
client_session() {
  tmux -L "$TMUX_SOCK" list-clients -F '#{client_session}' 2>/dev/null
}

# Stub binary named `ksession` (the scripts reject bare shell names and
# non-executables). Appends one line per invocation to $STUB_LOG with the
# argv joined by spaces, and answers the read-only subcommands. STUB_RC
# fails only the mutating subcommands (save/restore/rm) so a test of the
# failure path still sees the saved-session list.
install_stub_ksession() {
  cat >"$KSESSION_IMPL" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
case "$1 $2" in
  "tmux list")
    cat "$STUB_LIST"
    ;;
  "tmux show")
    printf 'session: %s\n' "$3"
    ;;
  "tmux save"|"tmux restore"|"tmux rm")
    exit "${STUB_RC:-0}"
    ;;
esac
exit 0
EOF
  chmod +x "$KSESSION_IMPL"
}

# Stub fzf. Each invocation consumes the next line of $FZF_STUB_SCRIPT:
#   <key>\t<query>\t<match>
# and prints what real fzf would:
#   - the query line when --print-query is present,
#   - the key line when --expect is present,
#   - the first stdin row containing <match> (empty line when no match).
# Exit 0 when a key or a row was produced, 130 (Ctrl-C) when the script
# is exhausted so a looping picker terminates instead of spinning.
install_stub_fzf() {
  cat >"$T/bin/fzf" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  [[ "$a" == "--version" ]] && { echo "0.67.0 (stub)"; exit 0; }
done
rows="$(cat)"
n=0
[[ -f "$FZF_STUB_COUNTER" ]] && n="$(cat "$FZF_STUB_COUNTER")"
step="$(sed -n "$((n + 1))p" "$FZF_STUB_SCRIPT")"
echo $((n + 1)) >"$FZF_STUB_COUNTER"
if [[ -z "$step" ]]; then
  exit 130
fi
# `read` would collapse adjacent tabs (IFS whitespace), so split with cut.
key="$(printf '%s\n' "$step" | cut -f1)"
query="$(printf '%s\n' "$step" | cut -f2)"
match="$(printf '%s\n' "$step" | cut -f3)"
want_query=0; want_key=0
for a in "$@"; do
  [[ "$a" == "--print-query" ]] && want_query=1
  [[ "$a" == --expect* ]] && want_key=1
done
row=""
if [[ -n "$match" ]]; then
  row="$(printf '%s\n' "$rows" | grep -F -m1 -- "$match" || true)"
fi
(( want_query )) && printf '%s\n' "$query"
(( want_key )) && printf '%s\n' "$key"
printf '%s\n' "$row"
if [[ -n "$key" || -n "$row" ]]; then exit 0; fi
exit 1
EOF
  chmod +x "$T/bin/fzf"
}

# fzf_script <line>... : program the stub (one "<key>\t<query>\t<match>"
# line per fzf invocation) and reset its step counter.
fzf_script() {
  printf '%s\n' "$@" >"$FZF_STUB_SCRIPT"
  rm -f "$FZF_STUB_COUNTER"
}

# canned_list [<row>...] : rows the stub returns for `tmux list --porcelain`
# (name\tsession\twindows\tpanes\tcreated_at). No rows = no saved sessions
# (an empty file, not a blank line); pass "" explicitly to inject one.
canned_list() {
  : >"$STUB_LIST"
  if (( $# )); then
    printf '%s\n' "$@" >>"$STUB_LIST"
  fi
}

reset_stub_log() { : >"$STUB_LOG"; }
stub_log() { cat "$STUB_LOG" 2>/dev/null || true; }

# run_script <path> [args...] : run a script under test with stdin from
# /dev/null, capturing stdout+stderr into $out and the exit code into $rc.
# Callers run without `set -e`, so a non-zero rc is data, not a failure.
run_script() {
  out="$("$@" </dev/null 2>&1)"
  rc=$?
}
