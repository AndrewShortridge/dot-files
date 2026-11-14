KSESSION_TRACE_LIB="${KSESSION_TRACE_LIB:-$HOME/.local/share/ksession/ksession-trace-lib.sh}"
if [[ -f "$KSESSION_TRACE_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$KSESSION_TRACE_LIB"
else
  # Trace lib not installed — define stub so __trace_run calls work.
  __trace_run() { shift 2; "$@"; }
fi

# If a live tmux session already exists by the captured name, the user
# probably wants the live one (the captured layout is stale). Hand the
# terminal to it: switch the calling client when run inside tmux, attach
# otherwise. To force-replay the captured layout instead, kill the live
# session first or pass KSESSION_FORCE=1.
if [[ -z "${KSESSION_FORCE:-}" ]] && tmux has-session -t "=$SESS" 2>/dev/null; then
  echo "ksession: tmux session $SESS already exists — attaching to live session (set KSESSION_FORCE=1 to rebuild)." >&2
  if [ -n "${TMUX:-}" ]; then exec tmux switch-client -t "=$SESS"; else exec tmux attach-session -t "=$SESS"; fi
fi

