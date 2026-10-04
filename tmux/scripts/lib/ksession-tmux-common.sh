#!/usr/bin/env bash
# ksession-tmux-common: helpers shared by the tmux-side ksession scripts
# (ksession-picker.sh, ksession-save-prompt.sh). Both run inside
# `tmux display-popup -E`, where $TMUX is set and plain `tmux` reaches the
# invoking client, so no socket plumbing is needed here.
#
# Sourceable; no top-level side effects beyond defining functions and the
# ANSI palette. Call `ksession_tmux_init <tool-name>` first: it normalises
# PATH and the fzf environment, resolves the log path and records the
# tool name used to prefix every diagnostic.
#
# Environment knobs (all optional):
#   KSESSION_IMPL               ksession binary        (~/.local/bin/ksession)
#   KSESSION_SCRIPT_LIB         kitty shared bash libs (~/.config/kitty/scripts/lib)
#   KSESSION_TMUX_LOG           diagnostics log        (~/.cache/ksession.log)
#   KSESSION_PICKER_NO_CONFIRM  "1" answers yes to every y/N prompt (headless tests)

# ---- Palette (ANSI-16 only: the terminal's table is the One Dark theme) ------
# Same codes as the kitty pickers so a session reads identically on both
# surfaces: green ● running, blue ○ saved, bold magenta * current, dim ·.
ANSI_RESET=$'\033[0m'
ANSI_DIM=$'\033[2m'
ANSI_BOLD=$'\033[1m'
ANSI_GREEN=$'\033[32m'
ANSI_BLUE=$'\033[34m'
ANSI_MAGENTA_B=$'\033[1;35m'

BULLET_RUNNING="${ANSI_GREEN}●${ANSI_RESET}"
BULLET_SAVED="${ANSI_BLUE}○${ANSI_RESET}"
MARK_CURRENT="${ANSI_MAGENTA_B}*${ANSI_RESET}"
MARK_NONE=" "
SEP="  ${ANSI_DIM}·${ANSI_RESET}  "

# ---- Bootstrap ---------------------------------------------------------------

# ksession_tmux_init <tool-name>
ksession_tmux_init() {
  TOOL="$1"
  # display-popup runs us from the server's environment, not from an
  # interactive shell, so the usual user bins may be missing from PATH.
  export PATH="$PATH:/usr/local/bin:/usr/bin:$HOME/.local/bin:$HOME/miniconda3/bin"
  # Interactive fzf defaults (--border, --height 50%, ...) leak into the
  # popup through the server environment and fight the explicit flags the
  # scripts pass; the kitty overlays never see them, so drop them here too.
  unset FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE
  LOG="${KSESSION_TMUX_LOG:-$HOME/.cache/ksession.log}"
  mkdir -p "$(dirname "$LOG")"
}

log_line() {
  printf '%s %s: %s\n' "$(date -Is)" "$TOOL" "$*" >>"$LOG"
}

# Keep the popup open until Enter so a message can be read: with
# `display-popup -E` the popup vanishes the instant we exit. Reads stdin
# (the popup's tty) so a headless caller with stdin=/dev/null never hangs.
wait_for_enter() {
  read -rp "press enter to close..." _ || true
  printf '\n' >&2
}

# notify_and_hold <message...>: diagnostic on stderr, wait for Enter.
notify_and_hold() {
  printf '%s: %s\n' "$TOOL" "$*" >&2
  wait_for_enter
}

# fail_and_close <message...>: notify_and_hold, then exit 1.
fail_and_close() {
  notify_and_hold "$@"
  exit 1
}

require_inside_tmux() {
  [[ -n "${TMUX:-}" ]] || fail_and_close "not inside tmux (run from a tmux client, e.g. via display-popup)."
}

require_cmd() {
  command -v "$1" >/dev/null || fail_and_close "$1 is required."
}

# source_shared_lib <file>: pull one of the kitty picker libs
# (frecency.sh, modal_fsm.sh) so both surfaces share one implementation.
source_shared_lib() {
  local dir="${KSESSION_SCRIPT_LIB:-$HOME/.config/kitty/scripts/lib}"
  local file="$dir/$1"
  [[ -r "$file" ]] || fail_and_close "shared lib '$file' not found (set KSESSION_SCRIPT_LIB)."
  # shellcheck disable=SC1090
  source "$file"
}

# Resolve $KSESSION. No fallback: a missing binary is a hard error, and a
# bare shell name (fat-fingered KSESSION_IMPL) would silently misroute
# saves to /bin/bash, so refuse it outright.
require_ksession_binary() {
  KSESSION="${KSESSION_IMPL:-$HOME/.local/bin/ksession}"
  if [[ "$(basename "$KSESSION")" =~ ^(bash|sh|zsh|dash|fish)$ ]]; then
    fail_and_close "KSESSION_IMPL='$KSESSION' looks like a bare shell name; refusing to dispatch."
  fi
  if [[ ! -x "$KSESSION" ]]; then
    printf '%s: ksession binary %q is missing or not executable.\n' "$TOOL" "$KSESSION" >&2
    fail_and_close "run 'make install' in ~/.config/kitty/scripts/ksession-rs to install it."
  fi
}

# ---- Prompts -----------------------------------------------------------------

# confirm_yes_no <question>: 0 only on y/Y; Enter, EOF or anything else
# cancels. KSESSION_PICKER_NO_CONFIRM=1 answers yes without prompting so
# headless tests can drive the destructive paths.
confirm_yes_no() {
  local reply=""
  [[ "${KSESSION_PICKER_NO_CONFIRM:-0}" == "1" ]] && return 0
  printf '%s [y/N] ' "$1" >&2
  IFS= read -rsn1 reply || true
  printf '\n' >&2
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ---- tmux / ksession queries -------------------------------------------------

# The session the popup was opened from. $TMUX is "<socket>,<pid>,<sid>"
# and tmux stamps the client's session id into it when it spawns the
# popup, so this is deterministic even without a tty (headless tests).
current_tmux_session() {
  local sid="${TMUX##*,}"
  tmux display-message -p -t "\$$sid" '#{session_name}'
}

# `ksession tmux list --porcelain` rows: name, session, windows, panes,
# created_at (tab-separated, sorted by name). A failing binary degrades
# to "no saved sessions" (ADR 0001) and leaves its stderr in the log.
list_saved_sessions() {
  "$KSESSION" tmux list --porcelain 2>>"$LOG" || log_line "ksession tmux list failed with rc=$?"
}

# ---- Row display formatting --------------------------------------------------

# count_noun <n> <noun>: "1 window" / "3 windows"
count_noun() {
  if (( $1 == 1 )); then
    printf '%s %s' "$1" "$2"
  else
    printf '%s %ss' "$1" "$2"
  fi
}

# running_session_display <mark> <name> <windows> <attached-clients>
#   "<mark> ● <name>  ·  <N windows>  ·  attached|detached"
running_session_display() {
  local mark="$1" name="$2" windows="$3" clients="$4" state="detached"
  (( clients > 0 )) && state="attached"
  printf '%s %s %s%s%s%s%s' "$mark" "$BULLET_RUNNING" "$name" \
    "$SEP" "$(count_noun "$windows" window)" "$SEP" "$state"
}

# saved_session_display <mark> <bullet> <name> <session> <windows> <panes>
#   "<mark> <bullet> <name>  ·  <session>  ·  <N windows>  ·  <P panes>"
# The tmux session name is omitted when it equals the saved name, which
# is the common case and would only add noise.
saved_session_display() {
  local mark="$1" bullet="$2" name="$3" session="$4" windows="$5" panes="$6"
  local session_part=""
  if [[ "$session" != "$name" ]]; then
    session_part="${SEP}${session}"
  fi
  printf '%s %s %s%s%s%s%s%s' "$mark" "$bullet" "$name" "$session_part" \
    "$SEP" "$(count_noun "$windows" window)" "$SEP" "$(count_noun "$panes" pane)"
}
