#!/bin/bash
# ksession-trace-lib.sh — shared bash tracing library for ksession restore.
#
# Sourced by generated restore.sh scripts. Provides two helpers:
#
#   __trace_run  name args_json cmd...    — time+emit around a command
#   __trace_emit name dur_us args_json    — emit a pre-computed event
#
# When KSESSION_TRACE_DIR is unset (the common case), both helpers
# degenerate to running the command (or doing nothing for __trace_emit)
# with no tracing overhead — one variable test per call.
#
# Requires bash >= 5.0 for ${EPOCHREALTIME/./} microsecond timestamps
# without forking. On older bash, a one-line stderr warning is emitted
# and tracing is silently disabled (restore still succeeds).

# ---------- bash version gate ----------

__ksession_trace_available=1

if [[ "${BASH_VERSINFO[0]:-0}" -lt 5 ]]; then
    if [[ -n "${KSESSION_TRACE_DIR-}" ]]; then
        echo "ksession: trace: bash ${BASH_VERSION} < 5.0 — EPOCHREALTIME unavailable, tracing disabled" >&2
    fi
    __ksession_trace_available=0
fi

# ---------- helpers ----------

# __trace_run name args_json cmd...
#
# Run cmd with tracing. When KSESSION_TRACE_DIR is unset or bash < 5.0,
# pass through to the command with no overhead beyond one variable test.
__trace_run() {
    if [[ -z "${KSESSION_TRACE_DIR-}" ]] || [[ "$__ksession_trace_available" -eq 0 ]]; then
        shift 2
        "$@"
        return $?
    fi
    local __tr_name=$1 __tr_args=$2
    shift 2
    local __tr_t0=${EPOCHREALTIME/./}
    "$@"
    local __tr_rc=$?
    local __tr_t1=${EPOCHREALTIME/./}
    local __tr_dur=$(( __tr_t1 - __tr_t0 ))
    [[ -z "$__tr_args" ]] && __tr_args='{}'
    printf '{"name":"%s","ph":"X","ts":%d,"dur":%d,"pid":%d,"tid":%d,"args":%s}\n' \
        "$__tr_name" "$__tr_t0" "$__tr_dur" "$$" "$$" "$__tr_args" \
        >> "${KSESSION_TRACE_DIR}/tmux-${KSESSION_TRACE_SESS:-unknown}.jsonl"
    return $__tr_rc
}

# __trace_emit name dur_us args_json
#
# Emit a pre-computed trace event (no command execution). Useful for
# recording durations measured by other means.
__trace_emit() {
    if [[ -z "${KSESSION_TRACE_DIR-}" ]] || [[ "$__ksession_trace_available" -eq 0 ]]; then
        return 0
    fi
    local __te_name=$1 __te_dur=$2 __te_args=$3
    [[ -z "$__te_args" ]] && __te_args='{}'
    local __te_ts=${EPOCHREALTIME/./}
    # Adjust ts backwards by dur so the event covers the measured span.
    __te_ts=$(( __te_ts - __te_dur ))
    printf '{"name":"%s","ph":"X","ts":%d,"dur":%d,"pid":%d,"tid":%d,"args":%s}\n' \
        "$__te_name" "$__te_ts" "$__te_dur" "$$" "$$" "$__te_args" \
        >> "${KSESSION_TRACE_DIR}/tmux-${KSESSION_TRACE_SESS:-unknown}.jsonl"
}
