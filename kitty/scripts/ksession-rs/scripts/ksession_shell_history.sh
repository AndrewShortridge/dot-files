#!/usr/bin/env sh
# ksession_shell_history.sh — per-window command history capture for kitty
#
# Source this from your .bashrc or .zshrc:
#   . ~/.local/share/ksession/ksession_shell_history.sh
#
# Each kitty window gets its own history file at:
#   ~/.cache/ksession/hist/<KITTY_WINDOW_ID>
#
# This script does NOT modify the user's existing HISTFILE.

# Guard: no-op outside kitty terminals
[ -n "$KITTY_WINDOW_ID" ] || return 0

# Per-window history file
KSESSION_HIST_DIR="${HOME}/.cache/ksession/hist"
KSESSION_HIST_FILE="${KSESSION_HIST_DIR}/${KITTY_WINDOW_ID}"
export KSESSION_HIST_FILE

# Create the history directory on first invocation if absent
[ -d "$KSESSION_HIST_DIR" ] || mkdir -p "$KSESSION_HIST_DIR"

# ---------------------------------------------------------------------------
# Bash path
# ---------------------------------------------------------------------------
if [ -n "$BASH_VERSION" ]; then
    __ksession_hist_append() {
        builtin history -a "$KSESSION_HIST_FILE"
    }

    # Append to PROMPT_COMMAND without clobbering existing entries
    case "$PROMPT_COMMAND" in
        *__ksession_hist_append*) ;;  # already present
        *)
            if [ -n "$PROMPT_COMMAND" ]; then
                PROMPT_COMMAND="${PROMPT_COMMAND};__ksession_hist_append"
            else
                PROMPT_COMMAND="__ksession_hist_append"
            fi
            ;;
    esac

# ---------------------------------------------------------------------------
# Zsh path
# ---------------------------------------------------------------------------
elif [ -n "$ZSH_VERSION" ]; then
    __ksession_hist_precmd() {
        # Append the last command to the per-window history file
        fc -ln -1 >> "$KSESSION_HIST_FILE" 2>/dev/null
    }

    # Register the hook — prefer add-zsh-hook if available, fallback to
    # precmd_functions array
    if typeset -f add-zsh-hook > /dev/null 2>&1; then
        add-zsh-hook precmd __ksession_hist_precmd
    else
        # Guard against double-registration
        case " ${precmd_functions[*]} " in
            *" __ksession_hist_precmd "*)  ;;
            *)  precmd_functions+=(__ksession_hist_precmd) ;;
        esac
    fi
fi
