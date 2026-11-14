#!/usr/bin/env bash
# Smoke tests for scripts/ksession-picker.sh.
#
# Drives the picker against a scratch tmux server with a stub `ksession`
# (records argv) and a stub `fzf` that replays scripted keys, then asserts
# which `ksession tmux …` / tmux dispatch (if any) the picker made. A
# control-mode client sits on `demo` so switch-client has something to
# move. One PASS/FAIL line per assertion, summary at the bottom.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/harness.sh
source "$here/../lib/harness.sh"

require_tools
setup_env
attach_control_client
PICKER="$SCRIPTS_DIR/ksession-picker.sh"
if [[ ! -x "$PICKER" ]]; then
  echo "picker not found or not executable at $PICKER" >&2
  exit 2
fi

frecency_keys() { jq -r '.entries | keys[]' "$FRECENCY_STORE" 2>/dev/null; }

# Saved sessions the stub reports. `proj-a` is not running on the scratch
# server, so it must surface as a restorable row.
canned_list \
  $'proj-a\tproj-a\t2\t3\t2026-10-03T10:00:00Z' \
  $'proj-b\tproj-b\t1\t1\t2026-10-03T11:00:00Z'

# ---- Enter on a saved row → tmux restore <name> -------------------------------
reset_stub_log
fzf_script $'enter\t\tproj-a'
run_script "$PICKER"
assert_eq "enter on saved row exits 0" 0 "$rc"
assert_contains "enter on saved row dispatches restore" "$(stub_log)" "tmux restore proj-a"
assert_not_contains "enter on saved row does not rm" "$(stub_log)" "tmux rm"
assert_contains "enter on saved row bumps the saved: frecency key" "$(frecency_keys)" "saved:proj-a"

# ---- Enter on a running row → switch-client -----------------------------------
tmux -L "$TMUX_SOCK" new-session -d -s target
reset_stub_log
fzf_script $'enter\t\ttarget'
run_script "$PICKER"
assert_eq "enter on running row exits 0" 0 "$rc"
assert_eq "enter on running row switches the client" "target" "$(client_session)"
assert_not_contains "enter on running row does not restore" "$(stub_log)" "tmux restore"
assert_contains "enter on running row bumps the running: frecency key" "$(frecency_keys)" "running:target"
assert_not_contains "running and saved keys do not collide" "$(frecency_keys)" "saved:target"
tmux -L "$TMUX_SOCK" switch-client -t =demo
tmux -L "$TMUX_SOCK" kill-session -t =target

# ---- d on a saved row (normal mode) → tmux rm <name>, then q quits ------------
reset_stub_log
fzf_script $'esc\t\tproj-b' $'d\t\tproj-b' $'q\t\t'
run_script "$PICKER"
assert_eq "d on saved row then q exits 0" 0 "$rc"
assert_contains "d on saved row dispatches rm" "$(stub_log)" "tmux rm proj-b"
assert_not_contains "d on saved row does not restore" "$(stub_log)" "tmux restore"

# ---- d on a saved row whose rm fails keeps the row ----------------------------
# The row is still selectable afterwards: Enter on it dispatches restore
# (which the stub also fails, hence rc=1 — the dispatch is the evidence).
reset_stub_log
fzf_script $'esc\t\tproj-b' $'d\t\tproj-b' $'enter\t\tproj-b'
STUB_RC=1 run_script "$PICKER"
assert_contains "failed rm is reported" "$out" "delete 'proj-b' failed (rc=1)"
assert_contains "failed rm still dispatched" "$(stub_log)" "tmux rm proj-b"
assert_contains "failed rm keeps the row selectable" "$(stub_log)" "tmux restore proj-b"

# ---- d on a running row → tmux kill-session ----------------------------------
tmux -L "$TMUX_SOCK" new-session -d -s victim
reset_stub_log
fzf_script $'esc\t\tvictim' $'d\t\tvictim' $'q\t\t'
run_script "$PICKER"
assert_eq "d on running row then q exits 0" 0 "$rc"
if tmux -L "$TMUX_SOCK" has-session -t =victim 2>/dev/null; then
  bad "d on running row kills the tmux session" "session 'victim' still alive"
else
  ok "d on running row kills the tmux session"
fi
if tmux -L "$TMUX_SOCK" has-session -t =demo 2>/dev/null; then
  ok "d on running row leaves other sessions alone"
else
  bad "d on running row leaves other sessions alone" "session 'demo' was killed"
fi
assert_not_contains "d on running row never calls ksession rm" "$(stub_log)" "tmux rm"

# ---- d on the current session is refused -------------------------------------
# Killing it would detach the client (detach-on-destroy); the picker must
# say so, keep the row and stay open (q afterwards still quits cleanly).
reset_stub_log
fzf_script $'esc\t\tdemo' $'d\t\tdemo' $'q\t\t'
run_script "$PICKER"
assert_eq "d on current session then q exits 0" 0 "$rc"
assert_contains "d on current session is refused" "$out" "refusing to kill the current session 'demo'"
if tmux -L "$TMUX_SOCK" has-session -t =demo 2>/dev/null; then
  ok "d on current session leaves it alive"
else
  bad "d on current session leaves it alive" "session 'demo' was killed"
fi
assert_eq "d on current session keeps the client attached" "demo" "$(client_session)"

# ---- Deleting the last deletable row exits 0 ---------------------------------
# With no saved sessions and one other running session, its deletion
# leaves only the (undeletable) current row; the picker must carry on.
canned_list
tmux -L "$TMUX_SOCK" new-session -d -s lonely
reset_stub_log
fzf_script $'esc\t\tlonely' $'d\t\tlonely' $'q\t\t'
run_script "$PICKER"
assert_eq "deleting the last deletable row exits 0" 0 "$rc"
if tmux -L "$TMUX_SOCK" has-session -t =lonely 2>/dev/null; then
  bad "deleting the last deletable row kills it" "session 'lonely' still alive"
else
  ok "deleting the last deletable row kills it"
fi

# ---- Blank / malformed porcelain lines are ignored ---------------------------
canned_list "" $'proj-c\tproj-c\t1\t1\t2026-10-03T12:00:00Z' "junk"
reset_stub_log
fzf_script $'enter\t\tproj-c'
run_script "$PICKER"
assert_eq "blank porcelain line does not kill the picker" 0 "$rc"
assert_contains "rows after a blank porcelain line still dispatch" "$(stub_log)" "tmux restore proj-c"
canned_list \
  $'proj-a\tproj-a\t2\t3\t2026-10-03T10:00:00Z' \
  $'proj-b\tproj-b\t1\t1\t2026-10-03T11:00:00Z'

# ---- Ctrl-C / exhausted input → exit 0, no dispatch --------------------------
reset_stub_log
fzf_script
run_script "$PICKER"
assert_eq "ctrl-c exits 0" 0 "$rc"
assert_not_contains "ctrl-c dispatches nothing" "$(stub_log)" "tmux restore"
assert_not_contains "ctrl-c removes nothing" "$(stub_log)" "tmux rm"

# ---- Saved sessions are listed through the binary ----------------------------
assert_contains "picker enumerates saved sessions via list --porcelain" "$(stub_log)" "tmux list --porcelain"

# ---- --panes: every pane is a row; Enter jumps to it --------------------------
# `other` gets two windows and a split; the client is parked on demo and
# other's active window/pane are moved away from the target first so the
# select-window/select-pane dispatch is observable.
tmux -L "$TMUX_SOCK" new-session -d -s other
tmux -L "$TMUX_SOCK" new-window -t other
tmux -L "$TMUX_SOCK" split-window -t other:1
tmux -L "$TMUX_SOCK" select-pane -t other:1.0
tmux -L "$TMUX_SOCK" select-window -t other:0
target_pane="$(tmux -L "$TMUX_SOCK" display-message -p -t other:1.1 '#{pane_id}')"
reset_stub_log
fzf_script $'enter\t\t[other:1.1]'
run_script "$PICKER" --panes
assert_eq "panes: enter exits 0" 0 "$rc"
assert_eq "panes: enter switches the client to the pane's session" "other" "$(client_session)"
assert_eq "panes: enter selects the pane's window" "1" "$(tmux -L "$TMUX_SOCK" display-message -p -t other '#{window_index}')"
assert_eq "panes: enter selects the pane" "$target_pane" "$(tmux -L "$TMUX_SOCK" display-message -p -t other:1 '#{pane_id}')"
assert_not_contains "panes: enter never calls ksession restore" "$(stub_log)" "tmux restore"
tmux -L "$TMUX_SOCK" switch-client -t =demo

# ---- --panes: d is a no-op -----------------------------------------------------
reset_stub_log
fzf_script $'esc\t\t[other:0.0]' $'d\t\t[other:0.0]' $'q\t\t'
run_script "$PICKER" --panes
assert_eq "panes: d then q exits 0" 0 "$rc"
if tmux -L "$TMUX_SOCK" has-session -t =other 2>/dev/null; then
  ok "panes: d leaves the session alone"
else
  bad "panes: d leaves the session alone" "session 'other' was killed"
fi
assert_eq "panes: d leaves the pane count alone" "3" "$(tmux -L "$TMUX_SOCK" list-panes -t other -s | wc -l)"
assert_not_contains "panes: d never calls ksession rm" "$(stub_log)" "tmux rm"

finish
