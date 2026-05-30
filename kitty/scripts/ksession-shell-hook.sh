# ksession-shell-hook.sh
#
# Sourced (not executed) from ~/.bashrc or ~/.zshrc. Each shell prompt this
# hook emits OSC 1337 SetUserVar sequences that kitty stores on the window
# and exposes via `kitty @ ls`. The ksession Rust adapter reads those user
# vars instead of scraping /proc/PID/environ, which is faster and works
# under sandboxes that hide /proc.
#
# The contract is exactly four keys:
#   ksession_venv   = $VIRTUAL_ENV
#   ksession_conda  = $CONDA_DEFAULT_ENV
#   ksession_oldpwd = $OLDPWD
#   ksession_direnv = $DIRENV_DIR
#
# Empty values are intentionally emitted so the adapter can tell
# "explicitly empty" apart from "key missing".
#
# Install hint:
#   Add to .bashrc/.zshrc: source ~/.config/kitty/scripts/ksession-shell-hook.sh

# Guard against double-sourcing.
if [ -n "${_KSESSION_HOOK_LOADED-}" ]; then
    return 0 2>/dev/null || true
fi
_KSESSION_HOOK_LOADED=1

# Bail out for shells that aren't bash or zsh: dash/ash parse the whole file
# at source time and would choke on zsh-only array syntax further down.
if [ -z "${BASH_VERSION:-}${ZSH_VERSION:-}" ]; then
    return 0 2>/dev/null || exit 0
fi

# Pick a base64 encoder once, at source time. Probe by *running* the encoder
# rather than parsing --help text, which varies between GNU/BSD/busybox.
if printf x | base64 -w0 >/dev/null 2>&1; then
    _ksession_b64() { printf %s "$1" | base64 -w0; }
elif printf x | base64 >/dev/null 2>&1; then
    _ksession_b64() { printf %s "$1" | base64 | tr -d '\n'; }
elif command -v openssl >/dev/null 2>&1; then
    if printf x | openssl base64 -A >/dev/null 2>&1; then
        _ksession_b64() { printf %s "$1" | openssl base64 -A; }
    else
        _ksession_b64() { printf %s "$1" | openssl base64 | tr -d '\n'; }
    fi
else
    _ksession_b64() { :; }
fi

# Per-key cache of the last emitted value. Sentinel '__unset__' (not empty
# string) so the first prompt always emits — empty payload is load-bearing,
# distinguishing "explicitly empty" from "key missing" for the Rust adapter.
_KSESSION_LAST_VENV='__unset__'
_KSESSION_LAST_CONDA='__unset__'
_KSESSION_LAST_OLDPWD='__unset__'
_KSESSION_LAST_DIRENV='__unset__'

_ksession_emit() {
    # $1=key, $2=value
    local key=$1 val=$2 enc
    enc=$(_ksession_b64 "$val")
    # Source-time probe ensures the encoder works in the steady state; this
    # guards against transient runtime failure (signal, OOM) where an empty
    # enc would silently overwrite the user_var with "" — turning "key
    # absent" into "explicitly empty" and suppressing the adapter's /proc
    # fallback. Also covers the no-op encoder branch (no base64 + no
    # openssl): every non-empty value is honestly left absent rather than
    # lying with "".
    if [ -n "$val" ] && [ -z "$enc" ]; then
        return
    fi
    printf '\033]1337;SetUserVar=%s=%s\a' "$key" "$enc"
}

_ksession_push() {
    if [ "${VIRTUAL_ENV-}" != "$_KSESSION_LAST_VENV" ]; then
        _ksession_emit ksession_venv "${VIRTUAL_ENV-}"
        _KSESSION_LAST_VENV=${VIRTUAL_ENV-}
    fi
    if [ "${CONDA_DEFAULT_ENV-}" != "$_KSESSION_LAST_CONDA" ]; then
        _ksession_emit ksession_conda "${CONDA_DEFAULT_ENV-}"
        _KSESSION_LAST_CONDA=${CONDA_DEFAULT_ENV-}
    fi
    if [ "${OLDPWD-}" != "$_KSESSION_LAST_OLDPWD" ]; then
        _ksession_emit ksession_oldpwd "${OLDPWD-}"
        _KSESSION_LAST_OLDPWD=${OLDPWD-}
    fi
    if [ "${DIRENV_DIR-}" != "$_KSESSION_LAST_DIRENV" ]; then
        _ksession_emit ksession_direnv "${DIRENV_DIR-}"
        _KSESSION_LAST_DIRENV=${DIRENV_DIR-}
    fi
}

# Wire into the shell's prompt hook without clobbering existing handlers.
if [ -n "${ZSH_VERSION-}" ]; then
    # zsh: precmd_functions is an array of names to call before each prompt.
    autoload -Uz add-zsh-hook 2>/dev/null
    typeset -ga precmd_functions  # ensure array exists for either branch below
    if command -v add-zsh-hook >/dev/null 2>&1; then
        add-zsh-hook precmd _ksession_push
    else
        # Fallback if add-zsh-hook is unavailable.
        case " ${precmd_functions[*]} " in
            *" _ksession_push "*) ;;
            *) precmd_functions+=(_ksession_push) ;;
        esac
    fi
elif [ -n "${BASH_VERSION-}" ]; then
    # bash 5.1+ allows PROMPT_COMMAND to be an array; modern frameworks
    # (starship/atuin) use that form. Prepending as a string would mangle
    # element [0], so detect the array case and prepend as a new element.
    _ksession_pc_attr=
    # eval-wrap @a so bash < 4.4 (e.g. macOS default 3.2) never sees it at
    # parse time. Gate by BASH_VERSINFO >= 5 to cover all real users.
    if [ "${BASH_VERSINFO[0]:-0}" -ge 5 ] && [ -n "${PROMPT_COMMAND+x}" ]; then
        eval '_ksession_pc_attr=${PROMPT_COMMAND@a}'
    fi
    if [[ "$_ksession_pc_attr" == *a* ]]; then
        case " ${PROMPT_COMMAND[*]} " in
            *" _ksession_push "*) ;;
            *) PROMPT_COMMAND=(_ksession_push "${PROMPT_COMMAND[@]}") ;;
        esac
    else
        case ";${PROMPT_COMMAND-};" in
            *";_ksession_push;"*) ;;
            *) PROMPT_COMMAND="_ksession_push${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
        esac
    fi
    unset _ksession_pc_attr
fi
