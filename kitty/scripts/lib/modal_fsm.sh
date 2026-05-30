#!/usr/bin/env bash
# modal_fsm: tiny state machine for the session-picker's vim-modal UI.
#
# Sourceable; exposes one function:
#   picker_transition <mode> <key>   prints two lines: <next_mode> then
#                                    <side_effect>.
#
# Modes:
#   insert   — fzf in default mode; typing filters.
#   normal   — fzf --disabled; vim-style nav bindings.
#
# Keys: the values fzf surfaces via `--expect`. We only see a key here
# when fzf binds it via --expect; everything else stays in fzf's own
# filter buffer (insert) or is consumed by --bind navigation (normal).
#
# Transitions encoded:
#   (insert, enter) -> (quit,   open)
#   (insert, esc)   -> (normal, noop)
#   (normal, enter) -> (quit,   open)
#   (normal, i)     -> (insert, noop)
#   (normal, esc)   -> (quit,   noop)
#   (normal, q)     -> (quit,   noop)
#   (normal, d)     -> (normal, delete) # destructive: dispatch per-row-type
#
# Unknown (mode, key) pairs: stay in the current mode with a `noop`
# side effect. This is what fzf would deliver if --expect captured a
# key not in our binding table, e.g. `(insert, d)` if a future change
# bound `d` in insert mode by accident.
#
# No top-level side effects.

picker_transition() {
  local mode="${1:-}"
  local key="${2:-}"
  local next_mode side_effect

  # Default: stay put, no-op. Specific cases override below.
  next_mode="$mode"
  side_effect="noop"

  case "$mode" in
    insert)
      case "$key" in
        enter) next_mode="quit";   side_effect="open" ;;
        esc)   next_mode="normal"; side_effect="noop" ;;
        *)     : ;;  # unknown key -> (insert, noop)
      esac
      ;;
    normal)
      case "$key" in
        enter) next_mode="quit";   side_effect="open" ;;
        i)     next_mode="insert"; side_effect="noop" ;;
        esc)   next_mode="quit";   side_effect="noop" ;;
        q)     next_mode="quit";   side_effect="noop" ;;
        d)     next_mode="normal"; side_effect="delete" ;;
        *)     : ;;  # unknown key -> (normal, noop)
      esac
      ;;
    *)
      # Unknown mode: degrade to (insert, noop) so callers can recover.
      next_mode="insert"
      side_effect="noop"
      ;;
  esac

  printf '%s\n%s\n' "$next_mode" "$side_effect"
}
