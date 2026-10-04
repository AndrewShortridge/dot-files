#!/usr/bin/env bash
# Smoke tests for scripts/ksession-save-prompt.sh.
#
# The prompt is one `fzf --print-query` call: line 1 is the typed name,
# line 2 the highlighted existing session (if any). The stub fzf replays
# both, the stub ksession records the resulting `tmux save <name>` (or its
# absence). One PASS/FAIL line per assertion, summary at the bottom.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/harness.sh
source "$here/../lib/harness.sh"

require_tools
setup_env
PROMPT="$SCRIPTS_DIR/ksession-save-prompt.sh"
if [[ ! -x "$PROMPT" ]]; then
  echo "save prompt not found or not executable at $PROMPT" >&2
  exit 2
fi

canned_list $'existing\tdemo\t1\t1\t2026-10-03T10:00:00Z'

# ---- typed name → tmux save <name> -------------------------------------------
reset_stub_log
fzf_script $'\tfresh-name\t'
run_script "$PROMPT"
assert_eq "typed name exits 0" 0 "$rc"
assert_contains "typed name dispatches save" "$(stub_log)" "tmux save fresh-name"
assert_contains "typed name reports success" "$out" "saved"

# ---- default query = current tmux session name -------------------------------
# The stub echoes an empty query and no selection, which the prompt treats
# as "nothing typed": it must abort rather than save under some default.
reset_stub_log
fzf_script $'\t\t'
run_script "$PROMPT"
assert_eq "empty input exits 0" 0 "$rc"
assert_contains "empty input aborts" "$out" "aborted"
assert_not_contains "empty input saves nothing" "$(stub_log)" "tmux save"

# ---- invalid name rejected -----------------------------------------------------
reset_stub_log
fzf_script $'\tbad name!\t'
run_script "$PROMPT"
assert_eq "invalid name exits 1" 1 "$rc"
assert_contains "invalid name is reported" "$out" "invalid name"
assert_not_contains "invalid name saves nothing" "$(stub_log)" "tmux save"

# ---- selecting an existing row (empty query) → overwrite that name ----------
# KSESSION_PICKER_NO_CONFIRM=1 skips the y/N confirm, so the save fires.
reset_stub_log
fzf_script $'\t\texisting'
run_script "$PROMPT"
assert_eq "selected existing row exits 0" 0 "$rc"
assert_contains "selected existing row saves under its name" "$(stub_log)" "tmux save existing"

# ---- save failure surfaces ----------------------------------------------------
reset_stub_log
fzf_script $'\tfails\t'
STUB_RC=1 run_script "$PROMPT"
assert_eq "failed save exits 1" 1 "$rc"
assert_contains "failed save still dispatched" "$(stub_log)" "tmux save fails"
assert_contains "failed save is reported" "$out" "save failed"

finish
