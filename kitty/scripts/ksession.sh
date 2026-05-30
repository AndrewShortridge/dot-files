#!/usr/bin/env bash
# ksession - save and restore kitty terminal sessions
#
# Captures the current kitty OS window's tab/window/layout shape plus
# per-window program state (nvim buffers via mksession, less/man read
# position, shell venv/conda/direnv context). Writes a kitty .conf into
# ~/.config/kitty/sessions/<name>.conf so the existing project-launcher,
# session-picker, and project-loader scripts can restore it.
#
# Sidecar state lives in ~/.config/kitty/sessions/<name>.state/.
#
# Usage:
#   ksession save <name> [--all]   # current OS window; --all = every OS window
#   ksession restore <name>         # spawn fresh kitty --session
#   ksession load <name>            # hint about project-loader.sh
#   ksession list
#   ksession show <name>
#   ksession rm <name>

set -euo pipefail
shopt -s nullglob

# Kitty may launch this without sourcing .bashrc.
export PATH="${PATH}:/usr/local/bin:/usr/bin:/home/andrew/miniconda3/bin:/home/andrew/.local/bin:/opt/nvim-linux-x86_64/bin"

SESSIONS_DIR="${KITTY_PROJECT_SESSIONS_DIR:-$HOME/.config/kitty/sessions}"
LOG="${HOME}/.cache/ksession.log"
mkdir -p "$(dirname "$LOG")" "$SESSIONS_DIR"

log() { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG"; }

need() {
  for c in "$@"; do
    command -v "$c" >/dev/null || { echo "ksession: missing dependency: $c" >&2; exit 1; }
  done
}

validate_name() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ksession: invalid name '$1' (use [A-Za-z0-9._-])" >&2; exit 1; }
}

# Quote one arg for a kitty session-file launch line. Kitty parses launch args
# with shlex semantics after ${VAR} expansion; single-quotes disable both.
kq() {
  local s=$1
  if [[ "$s" =~ ^[A-Za-z0-9_./@:=+,-]+$ ]]; then
    printf '%s' "$s"
  else
    printf "'%s'" "${s//\'/\'\\\'\'}"
  fi
}

# Emit a launch line: $1 = directive name (verbatim), rest = args, quoted.
emit_launch() {
  local first=1 arg
  for arg in "$@"; do
    if (( first )); then printf '%s' "$arg"; first=0
    else printf ' %s' "$(kq "$arg")"; fi
  done
  printf '\n'
}

# ---------- /proc helpers ----------

proc_exe_base() { # $1=pid -> basename of /proc/PID/exe
  local t
  t=$(readlink -f "/proc/$1/exe" 2>/dev/null) || return 1
  basename "$t"
}

proc_env() {      # $1=pid $2=varname -> value (empty if unset)
  [[ -r "/proc/$1/environ" ]] || return 0
  tr '\0' '\n' < "/proc/$1/environ" \
    | awk -v k="$2=" 'index($0,k)==1 { print substr($0, length(k)+1); exit }'
}

# Walk descendants of a pid via /proc/PID/task/*/children.
proc_descendants() {  # $1=root pid -> pids on stdout, deepest leaves last
  local root=$1
  local -a stack=( "$root" )
  local -a out=()
  while ((${#stack[@]})); do
    local p=${stack[-1]}; unset 'stack[-1]'
    out+=( "$p" )
    local kids=""
    for f in /proc/"$p"/task/*/children; do
      [[ -r "$f" ]] || continue
      kids+=" $(<"$f")"
    done
    local k
    for k in $kids; do
      [[ -n "$k" ]] && stack+=( "$k" )
    done
  done
  printf '%s\n' "${out[@]}"
}

# ---------- nvim adapter ----------

nvim_socket_for_pid() {  # $1=pid -> socket path or empty
  local pid=$1 s candidate
  # Honor explicit env address if set.
  s=$(proc_env "$pid" NVIM_LISTEN_ADDRESS)
  if [[ -n "$s" && -S "$s" ]]; then echo "$s"; return; fi
  local rt=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
  # Direct patterns keyed on the given pid.
  for candidate in \
    "$rt/nvim.$pid.0" \
    "$rt/nvim.$pid".* \
    "$rt/nvim.${USER:-$(id -un)}"/*/"nvim.$pid".* ; do
    [[ -S "$candidate" ]] && { echo "$candidate"; return; }
  done
  # Fallback: walk descendants of the given pid (covers cases where
  # foreground_processes[-1] is a child process — e.g., nvim is the parent
  # of an LSP/term job, or shell didn't exec). Any nvim.<descendant>.* match wins.
  local kid
  for kid in $(proc_descendants "$pid"); do
    [[ "$kid" == "$pid" ]] && continue
    for candidate in \
        "$rt/nvim.$kid.0" \
        "$rt/nvim.$kid".* \
        "$rt/nvim.${USER:-$(id -un)}"/*/"nvim.$kid".* ; do
      [[ -S "$candidate" ]] && { echo "$candidate"; return; }
    done
  done
  # Last resort: scan every nvim.*.0 socket and keep one whose pid is in
  # the window's process tree.
  local tree=" $(proc_descendants "$pid" | tr '\n' ' ') "
  for candidate in "$rt"/nvim.*.0 "$rt/nvim.${USER:-$(id -un)}"/*/nvim.*.0; do
    [[ -S "$candidate" ]] || continue
    local base=${candidate##*/}
    local cand_pid=${base#nvim.}
    cand_pid=${cand_pid%.*}
    [[ "$tree" == *" $cand_pid "* ]] && { echo "$candidate"; return; }
  done
}

# Drive :mksession! on the given socket; write to $2. Poll up to 3s.
nvim_capture_to_file() {  # $1=socket $2=output .vim path
  local sock=$1 out=$2
  mkdir -p "$(dirname "$out")"
  rm -f "$out"
  nvim --server "$sock" --remote-send "<C-\\><C-N>:mksession! $out<CR>" >/dev/null 2>&1 || return 1
  local i
  for i in $(seq 1 15); do
    [[ -s "$out" ]] && return 0
    sleep 0.2
  done
  return 1
}

# ---------- less adapter ----------

# Print "<file>\t<offset>" for a less/man process, or nothing.
less_state() {  # $1=pid
  local pid=$1 fd target n pos
  for fd in /proc/"$pid"/fd/*; do
    [[ -L "$fd" ]] || continue
    target=$(readlink "$fd" 2>/dev/null) || continue
    [[ "$target" == /* && -f "$target" ]] || continue
    case "$target" in
      /dev/*|/proc/*|/sys/*|*/usr/share/terminfo/*|*/locale-archive) continue ;;
    esac
    n=${fd##*/}
    pos=$(awk '/^pos:/{print $2; exit}' "/proc/$pid/fdinfo/$n" 2>/dev/null || echo "")
    printf '%s\t%s\n' "$target" "${pos:-0}"
    return 0
  done
}

# Append a buffer-restore function + per-buffer calls to a session.vim,
# after dumping modified buffer contents via writefile() over RPC.
# $1=socket  $2=session_vim_path  $3=dumps_dir
nvim_dump_modified_buffers() {
  local sock=$1 session_vim=$2 dumps_dir=$3
  mkdir -p "$dumps_dir"

  # Pull metadata for buffers worth dumping: &modified=1, no special buftype.
  local meta
  meta=$(nvim --server "$sock" --remote-expr \
    "json_encode(map(filter(nvim_list_bufs(), {_, b -> getbufvar(b, '&modified') == 1 && getbufvar(b, '&buftype') == ''}), {_, b -> {'buf': b, 'name': bufname(b), 'modified': getbufvar(b, '&modified'), 'filetype': getbufvar(b, '&filetype')}}))" \
    2>/dev/null) || return 0
  [[ -z "$meta" || "$meta" == "[]" || "$meta" == "null" ]] && return 0

  local restore_block="" count=0
  local buf name modified filetype
  # Use \x01 as the field separator: tab would be treated as IFS-whitespace
  # and bash would collapse adjacent tabs (eating empty fields like a blank
  # buffer name). \x01 cannot appear in paths and is non-whitespace.
  while IFS=$'\x01' read -r buf name modified filetype; do
    [[ -z "$buf" ]] && continue
    local dump_path="$dumps_dir/buf-$buf.txt"
    if ! nvim --server "$sock" --remote-expr \
        "writefile(nvim_buf_get_lines($buf, 0, -1, v:false), '${dump_path//\'/\'\'}')" \
        >/dev/null 2>&1; then
      log "    dump failed for buf=$buf name='$name'"
      continue
    fi
    count=$((count + 1))
    log "    dumped buf=$buf name='$name' ft='$filetype' -> $dump_path"
    local en=${name//\'/\'\'}
    local edp=${dump_path//\'/\'\'}
    local eft=${filetype//\'/\'\'}
    restore_block+="call s:KsessionRestoreBuffer('$en', '$edp', $modified, '$eft')"$'\n'
  done < <(jq -r '.[] | [.buf, .name, .modified, .filetype] | join("")' <<<"$meta")

  (( count == 0 )) && return 0

  cat >> "$session_vim" <<'VIMRESTORE'

" ---- ksession: restore modified/unnamed buffer contents ----
function! s:KsessionRestoreBuffer(name, dump_path, modified, filetype) abort
  let l:bnr = -1
  if !empty(a:name)
    let l:bnr = bufnr(a:name)
    if l:bnr <= 0
      let l:bnr = bufadd(a:name)
    endif
    call bufload(l:bnr)
  else
    let l:bnr = nvim_create_buf(v:true, v:false)
  endif
  let l:lines = readfile(a:dump_path)
  call nvim_buf_set_lines(l:bnr, 0, -1, v:false, l:lines)
  if a:modified
    call setbufvar(l:bnr, '&modified', 1)
  endif
  if !empty(a:filetype)
    call setbufvar(l:bnr, '&filetype', a:filetype)
  endif
endfunction
VIMRESTORE

  printf '%s' "$restore_block" >> "$session_vim"
  log "    appended buffer restore for $count buffer(s) to $session_vim"
}

# ---------- tmux adapter ----------

# Build a shell-command string that, when typed into a fresh pane's shell,
# restores the program that was running in that pane. Used by send-keys.
# Args: $1=pane_pid  $2=pane_uid (digits)  $3=per-pane state dir  $4=current_command
capture_pane_program_cmd() {
  local pid=$1 uid=$2 pdir=$3 cmd=$4
  local exe_base
  exe_base=$(proc_exe_base "$pid" 2>/dev/null || echo "$cmd")
  case "$exe_base" in
    bash|zsh|fish|dash|sh|ash)
      # Shell: if there's activation context, wrap in `<shell> -c '...; exec <shell>'`
      # so the pane survives after the activation runs. If nothing to activate,
      # emit nothing — tmux will fall back to its default-shell.
      local venv conda oldpwd direnv parts="" shell=$exe_base
      [[ "$shell" =~ ^(bash|zsh|fish|dash|sh|ash)$ ]] || shell=bash
      venv=$(proc_env "$pid" VIRTUAL_ENV)
      conda=$(proc_env "$pid" CONDA_DEFAULT_ENV)
      oldpwd=$(proc_env "$pid" OLDPWD)
      direnv=$(proc_env "$pid" DIRENV_DIR)
      if [[ -n "$venv" && -f "$venv/bin/activate" ]]; then
        parts+="source $(printf %q "${venv}/bin/activate")"
      elif [[ -n "$conda" && "$conda" != "base" ]]; then
        parts+="conda activate $(printf %q "${conda}")"
      fi
      [[ -n "$oldpwd" ]] && parts+="${parts:+; }export OLDPWD=$(printf %q "${oldpwd}")"
      if [[ -n "$parts" ]]; then
        printf '%s -c %s' "$shell" "$(printf %q "${parts}; exec ${shell}")"
      fi
      # Else: empty -> tmux uses default-shell, user gets their normal shell.
      ;;
    nvim)
      local sock outvim
      sock=$(nvim_socket_for_pid "$pid")
      outvim="$pdir/nvim/win-$uid.vim"
      mkdir -p "$pdir/nvim"
      if [[ -n "$sock" ]] && nvim_capture_to_file "$sock" "$outvim"; then
        nvim_dump_modified_buffers "$sock" "$outvim" "$pdir/nvim/win-$uid.dumps" || true
        printf 'nvim -S %s' "$outvim"
      else
        printf 'nvim'
      fi
      ;;
    less|more|most|pg|man)
      local info file pos size pct
      info=$(less_state "$pid") || true
      if [[ -n "$info" ]]; then
        file=${info%%$'\t'*}
        pos=${info##*$'\t'}
        size=$(stat -c '%s' -- "$file" 2>/dev/null || echo 0)
        pct=0
        if (( size > 0 )); then
          pct=$(( pos * 100 / size ))
          (( pct > 99 )) && pct=99
        fi
        printf '%s +%d%%%% -- %s' "$exe_base" "$pct" "$file"
      else
        printf '%s' "$exe_base"
      fi
      ;;
    *)
      if [[ -r "/proc/$pid/cmdline" ]]; then
        tr '\0' ' ' < "/proc/$pid/cmdline" | sed 's/ *$//'
      else
        printf '%s' "$cmd"
      fi
      ;;
  esac
}

# Emit a tmux session restore script + capture per-pane state.
# Args: $1=tmux client pid  $2=window_id (kitty's)  $3=state_dir
# Prints argv tokens (one per line) for the kitty launch line.
capture_tmux_window() {
  local pid=$1 wid=$2 state=$3

  if ! command -v tmux >/dev/null; then
    log "  tmux adapter: tmux not in PATH; bare launch"
    printf '%s\n' tmux
    return
  fi

  # Find the session this client is attached to.
  local sess
  sess=$(tmux list-clients -F '#{client_pid} #{session_name}' 2>/dev/null \
         | awk -v p="$pid" '$1==p {print $2; exit}')
  if [[ -z "$sess" ]]; then
    log "  tmux pid=$pid: no attached session; bare launch"
    printf '%s\n' tmux
    return
  fi
  log "  tmux pid=$pid attached to session='$sess'"

  local tmux_dir="$state/tmux/$sess"
  mkdir -p "$tmux_dir"
  local restore_sh="$tmux_dir/restore.sh"

  {
    echo '#!/usr/bin/env bash'
    echo "# Auto-generated by ksession. Recreates tmux session '$sess'."
    echo 'set -e'
    printf 'ORIG_SESS=%q\n' "$sess"
    echo 'SESS="$ORIG_SESS"'
    echo
    echo '# If a live tmux session already exists by the captured name, the user'
    echo '# probably wants the live one (the captured layout is stale). Attach.'
    echo '# To force-replay the captured layout instead, kill the live session'
    echo '# first or pass KSESSION_FORCE=1.'
    echo 'if [[ -z "${KSESSION_FORCE:-}" ]] && tmux has-session -t "$SESS" 2>/dev/null; then'
    echo '  echo "ksession: tmux session $SESS already exists — attaching to live session (set KSESSION_FORCE=1 to rebuild)." >&2'
    echo '  exec tmux attach-session -t "$SESS"'
    echo 'fi'
    echo
    echo '# Restore path: ensure no stale session of this name exists.'
    echo 'if tmux has-session -t "$SESS" 2>/dev/null; then'
    echo '  tmux kill-session -t "$SESS"'
    echo 'fi'
    echo
  } > "$restore_sh"

  local active_win="" active_pane=""
  local first_win=1 win_idx
  # tmux escapes non-printable bytes in -F output, so any delimiter approach
  # is fragile. Iterate by index and query each field with display-message.
  while IFS= read -r win_idx; do
    [[ -z "$win_idx" ]] && continue
    local win_name win_layout win_active
    win_name=$(tmux display-message -p -t "$sess:$win_idx" '#{window_name}' 2>/dev/null)
    win_layout=$(tmux display-message -p -t "$sess:$win_idx" '#{window_layout}' 2>/dev/null)
    win_active=$(tmux display-message -p -t "$sess:$win_idx" '#{window_active}' 2>/dev/null)
    [[ "$win_active" == "1" ]] && active_win=$win_idx

    local win_dir="$tmux_dir/win-$win_idx"
    mkdir -p "$win_dir"

    local first_pane=1 pane_id
    while IFS= read -r pane_id; do
      [[ -z "$pane_id" ]] && continue
      local pane_idx pane_pid pane_cwd pane_cmd pane_active
      pane_idx=$(tmux  display-message -p -t "$pane_id" '#{pane_index}'           2>/dev/null)
      pane_pid=$(tmux  display-message -p -t "$pane_id" '#{pane_pid}'             2>/dev/null)
      pane_cwd=$(tmux  display-message -p -t "$pane_id" '#{pane_current_path}'    2>/dev/null)
      pane_cmd=$(tmux  display-message -p -t "$pane_id" '#{pane_current_command}' 2>/dev/null)
      pane_active=$(tmux display-message -p -t "$pane_id" '#{pane_active}'        2>/dev/null)
      [[ "$pane_active" == "1" ]] && active_pane="$win_idx.$pane_idx"

      local uid=${pane_id#%}
      local pane_dir="$win_dir/pane-$uid"
      mkdir -p "$pane_dir"

      local prog_cmd
      prog_cmd=$(capture_pane_program_cmd "$pane_pid" "$uid" "$pane_dir" "$pane_cmd")
      log "    tmux pane $win_idx.$pane_idx pid=$pane_pid cmd='$pane_cmd' restore='$prog_cmd'"

      if (( ${KSESSION_SCROLLBACK:-1} )); then
        tmux capture-pane -p -e -S - -t "$pane_id" >"$pane_dir/scrollback.ansi" 2>/dev/null \
          && [[ ! -s "$pane_dir/scrollback.ansi" ]] && rm -f "$pane_dir/scrollback.ansi"
      fi

      # Pass the program as the pane's command argv directly (avoids the
      # send-keys race where keys can be lost or eaten by the shell's rc).
      if (( first_win )) && (( first_pane )); then
        if [[ -n "$prog_cmd" ]]; then
          printf 'tmux new-session -d -s "$SESS" -n %q -c %q %q\n' \
            "$win_name" "$pane_cwd" "$prog_cmd" >> "$restore_sh"
        else
          printf 'tmux new-session -d -s "$SESS" -n %q -c %q\n' \
            "$win_name" "$pane_cwd" >> "$restore_sh"
        fi
        first_win=0
      elif (( first_pane )); then
        if [[ -n "$prog_cmd" ]]; then
          printf 'tmux new-window -t "$SESS:%s" -n %q -c %q %q\n' \
            "$win_idx" "$win_name" "$pane_cwd" "$prog_cmd" >> "$restore_sh"
        else
          printf 'tmux new-window -t "$SESS:%s" -n %q -c %q\n' \
            "$win_idx" "$win_name" "$pane_cwd" >> "$restore_sh"
        fi
      else
        if [[ -n "$prog_cmd" ]]; then
          printf 'tmux split-window -t "$SESS:%s" -c %q %q\n' \
            "$win_idx" "$pane_cwd" "$prog_cmd" >> "$restore_sh"
        else
          printf 'tmux split-window -t "$SESS:%s" -c %q\n' \
            "$win_idx" "$pane_cwd" >> "$restore_sh"
        fi
      fi
      first_pane=0
    done < <(tmux list-panes -t "$sess:$win_idx" -F '#{pane_id}' 2>/dev/null)

    if [[ -n "$win_layout" ]]; then
      printf 'tmux select-layout -t "$SESS:%s" %q\n' "$win_idx" "$win_layout" >> "$restore_sh"
    fi
  done < <(tmux list-windows -t "$sess" -F '#{window_index}' 2>/dev/null)

  {
    echo
    [[ -n "$active_win"  ]] && printf 'tmux select-window -t "$SESS:%s"\n' "$active_win"
    [[ -n "$active_pane" ]] && printf 'tmux select-pane -t "$SESS:%s"\n' "$active_pane"
    echo 'exec tmux attach-session -t "$SESS"'
  } >> "$restore_sh"

  chmod +x "$restore_sh"
  log "  tmux session '$sess' restore script: $restore_sh"
  printf '%s\n' /bin/bash "$restore_sh"
}

# ---------- per-window adapters (emit argv tokens, one per line) ----------

capture_nvim_window() {  # $1=nvim_pid $2=window_id $3=state_dir $4=window_root_pid
  local pid=$1 wid=$2 state=$3 wroot=${4:-$1}
  local outvim="$state/nvim/win-$wid.vim"
  local dumps_dir="$state/nvim/win-$wid.dumps"
  local sock=""
  sock=$(nvim_socket_for_pid "$pid") || true
  if [[ -z "$sock" && "$wroot" != "$pid" ]]; then
    sock=$(nvim_socket_for_pid "$wroot") || true
  fi
  log "  capture_nvim_window pid=$pid wroot=$wroot wid=$wid sock=${sock:-<none>}"
  if [[ -n "$sock" ]] && nvim_capture_to_file "$sock" "$outvim"; then
    log "    mksession ok -> $outvim ($(stat -c %s "$outvim" 2>/dev/null) bytes)"
    nvim_dump_modified_buffers "$sock" "$outvim" "$dumps_dir" || true
    printf '%s\n' nvim -S "$outvim"
  else
    log "    no socket or mksession failed; replaying bare 'nvim' (cursor will not restore)"
    printf '%s\n' nvim
  fi
}

capture_less_window() {  # $1=pid $2=basename
  local pid=$1 b=$2 info file pos size pct
  info=$(less_state "$pid") || true
  if [[ -n "$info" ]]; then
    file=${info%%$'\t'*}
    pos=${info##*$'\t'}
    size=$(stat -c '%s' -- "$file" 2>/dev/null || echo 0)
    pct=0
    if (( size > 0 )); then
      pct=$(( pos * 100 / size ))
      (( pct > 99 )) && pct=99
    fi
    log "  $b pid=$pid file=$file pos=$pos pct=${pct}%"
    printf '%s\n' "$b" "+${pct}%" -- "$file"
  else
    printf '%s\n' "$b"
  fi
}

capture_shell_window() {  # $1=shell pid
  local pid=$1 venv conda direnv oldpwd shell pre
  venv=$(proc_env "$pid" VIRTUAL_ENV)
  conda=$(proc_env "$pid" CONDA_DEFAULT_ENV)
  direnv=$(proc_env "$pid" DIRENV_DIR)
  oldpwd=$(proc_env "$pid" OLDPWD)
  shell=$(proc_exe_base "$pid" 2>/dev/null || echo bash)
  [[ "$shell" =~ ^(bash|zsh|fish|dash|sh)$ ]] || shell=bash

  pre=""
  if [[ -n "$venv" && -f "$venv/bin/activate" ]]; then
    pre+="source ${venv}/bin/activate; "
    log "  shell pid=$pid venv=$venv"
  elif [[ -n "$conda" && "$conda" != "base" ]]; then
    pre+="conda activate ${conda}; "
    log "  shell pid=$pid conda=$conda"
  fi
  [[ -n "$oldpwd" ]] && pre+="export OLDPWD=${oldpwd}; "
  [[ -n "$direnv" ]] && log "  shell pid=$pid direnv=$direnv (cwd will retrigger)"

  if [[ -n "$pre" ]]; then
    printf '%s\n' "/bin/$shell" -l -c "${pre} exec $shell"
  else
    printf '%s\n' "/bin/$shell" -l
  fi
}

# ---------- emit one launch line per window ----------

emit_launch_for_window() {  # $1=window_json $2=idx $3=tab_layout $4=state $5=out
  local w_json=$1 idx=$2 layout=$3 state=$4 out=$5

  local w_id w_pid w_cwd fg_pid fg_exe
  w_id=$(jq -r '.id'         <<<"$w_json")
  w_pid=$(jq -r '.pid'       <<<"$w_json")
  w_cwd=$(jq -r '.cwd // ""' <<<"$w_json")

  fg_pid=$(jq -r '.foreground_processes[-1].pid // ""' <<<"$w_json")
  # When the shell has been exec-replaced (e.g. `exec tmux attach`) kitty
  # reports no foreground processes. Fall back to the window's root pid so
  # we can still identify what's running.
  if [[ -z "$fg_pid" ]]; then
    fg_pid=$w_pid
  fi
  fg_exe=""
  if [[ -n "$fg_pid" ]]; then
    fg_exe=$(proc_exe_base "$fg_pid" 2>/dev/null || echo "")
  fi
  # If the foreground is just a shell, walk the window's process tree for
  # known interactive programs. Catches cases where kitty's foreground_processes
  # under-reports (e.g., a tmux client that's daemonized or in an unusual pgrp).
  case "$fg_exe" in
    bash|zsh|fish|dash|sh|ash)
      fg_exe=""
      local kid kid_exe
      for kid in $(proc_descendants "$w_pid"); do
        [[ "$kid" == "$w_pid" ]] && continue
        kid_exe=$(proc_exe_base "$kid" 2>/dev/null || echo "")
        case "$kid_exe" in
          tmux|nvim|less|man|more|most|pg)
            log "    descendant scan: found $kid_exe (pid=$kid) under w_pid=$w_pid"
            fg_pid=$kid
            fg_exe=$kid_exe
            break
            ;;
        esac
      done
      ;;
  esac
  log "  window id=$w_id w_pid=$w_pid fg_pid=$fg_pid fg_exe='${fg_exe:-shell}'"

  local -a args=( launch )
  if (( idx > 0 )) && [[ "$layout" == "splits" ]]; then
    if (( idx % 2 == 1 )); then args+=( --location=vsplit )
    else                          args+=( --location=hsplit )
    fi
  fi
  [[ -n "$w_cwd" ]] && args+=( --cwd "$w_cwd" )
  args+=( --var "ksession_idx=$idx" --var "ksession_win=$w_id" )

  local -a cmd_argv=()
  case "$fg_exe" in
    nvim)
      mapfile -t cmd_argv < <(capture_nvim_window "$fg_pid" "$w_id" "$state" "$w_pid")
      ;;
    tmux)
      mapfile -t cmd_argv < <(capture_tmux_window "$fg_pid" "$w_id" "$state")
      ;;
    less|more|most|pg|man)
      mapfile -t cmd_argv < <(capture_less_window "$fg_pid" "$fg_exe")
      ;;
    "")
      mapfile -t cmd_argv < <(capture_shell_window "$w_pid")
      ;;
    *)
      mapfile -t cmd_argv < <(jq -r '.foreground_processes[-1].cmdline | (. // [])[]' <<<"$w_json")
      ;;
  esac
  (( ${#cmd_argv[@]} == 0 )) && cmd_argv=( /bin/bash -l )

  emit_launch "${args[@]}" "${cmd_argv[@]}" >> "$out"

  # Optional: capture scrollback as ANSI text for reference (not replayed
  # on restore — terminal scrollback can't be stuffed back into a fresh pty).
  if (( ${KSESSION_SCROLLBACK:-1} )); then
    local sb_dir="$state/scrollback"
    mkdir -p "$sb_dir"
    if kitty @ get-text --match "id:$w_id" --extent all --ansi \
        >"$sb_dir/win-$w_id.ansi" 2>/dev/null; then
      local sb_bytes
      sb_bytes=$(stat -c %s "$sb_dir/win-$w_id.ansi" 2>/dev/null || echo 0)
      if (( sb_bytes > 0 )); then
        log "  scrollback win=$w_id -> $sb_dir/win-$w_id.ansi ($sb_bytes bytes)"
      else
        rm -f "$sb_dir/win-$w_id.ansi"
      fi
    fi
  fi
}

# ---------- save ----------

save_session() {
  local name="" all=0
  # Scrollback default: on. Override via env or --no-scrollback.
  : "${KSESSION_SCROLLBACK:=1}"
  while (($#)); do
    case "$1" in
      --all)           all=1 ;;
      --no-scrollback) KSESSION_SCROLLBACK=0 ;;
      --scrollback)    KSESSION_SCROLLBACK=1 ;;
      -*)              echo "ksession save: unknown flag $1" >&2; exit 1 ;;
      *)               [[ -z "$name" ]] && name=$1 || { echo "ksession save: extra arg $1" >&2; exit 1; } ;;
    esac
    shift
  done
  [[ -n "$name" ]] || { echo "usage: ksession save <name> [--all] [--no-scrollback]" >&2; exit 1; }
  validate_name "$name"
  export KSESSION_SCROLLBACK
  need jq kitty

  local conf="$SESSIONS_DIR/$name.conf"
  local state="$SESSIONS_DIR/$name.state"
  local tmp_conf="$conf.tmp.$$"
  rm -rf "$state"
  mkdir -p "$state/nvim"

  log "save '$name' all=$all KITTY_WINDOW_ID=${KITTY_WINDOW_ID:-?}"

  local ls_json
  ls_json=$(kitty @ ls --all-env-vars 2>/dev/null) || {
    echo "ksession: kitty @ ls failed (is allow_remote_control on?)" >&2; exit 1
  }

  local target_filter=".[]"
  if (( ! all )); then
    if [[ -n "${KITTY_WINDOW_ID:-}" ]]; then
      local osw
      osw=$(jq --argjson w "$KITTY_WINDOW_ID" \
            '.[] | select(any(.tabs[].windows[]; .id == $w)) | .id' \
            <<<"$ls_json" | head -n1)
      [[ -n "$osw" ]] || { echo "ksession: cannot locate KITTY_WINDOW_ID=$KITTY_WINDOW_ID" >&2; exit 1; }
      target_filter=".[] | select(.id == $osw)"
    else
      target_filter=".[] | select(.is_focused)"
    fi
  fi

  {
    echo "# Description: ksession save '$name' at $(date -Is)"
    echo "# Generated by ksession.sh — re-save to refresh; restore with: kitty --session this-file"
    echo
  } > "$tmp_conf"

  local osw_count=0 osw_json
  while IFS= read -r osw_json; do
    [[ -z "$osw_json" ]] && continue
    osw_count=$((osw_count + 1))
    (( osw_count > 1 )) && echo "new_os_window" >> "$tmp_conf"

    local tab_count ti
    tab_count=$(jq '.tabs | length' <<<"$osw_json")
    for ti in $(seq 0 $((tab_count - 1))); do
      local tab_json tab_title tab_layout win_count win_idx
      tab_json=$(jq ".tabs[$ti]" <<<"$osw_json")
      tab_layout=$(jq -r '.layout // "splits"' <<<"$tab_json")
      # Prefer a non-overlay window's title; tab's own .title can be polluted by
      # an active overlay (e.g., the ksession-save-prompt overlay itself).
      tab_title=$(jq -r '
        [.windows[]
          | select((.is_self // false) | not)
          | select(.overlay_parent == null or .overlay_parent == 0)
          | .title] | first // ""
      ' <<<"$tab_json")

      # Filter out overlays (self-window running ksession, plus any other
      # overlay windows) before counting/indexing so split placement is correct.
      local filtered_json
      filtered_json=$(jq '[.windows[] | select((.is_self // false) | not)
                                       | select(.overlay_parent == null or .overlay_parent == 0)]' \
                       <<<"$tab_json")

      # If any window in the tab is running tmux (often via `exec tmux …`),
      # the captured tab_title is the stale shell command line. Blank it so
      # the restored tab title comes from whatever set-titles tmux applies.
      local tab_pids
      tab_pids=$(jq -r '.[] | .pid' <<<"$filtered_json")
      local tp tp_exe
      for tp in $tab_pids; do
        tp_exe=$(proc_exe_base "$tp" 2>/dev/null || echo "")
        if [[ "$tp_exe" == "tmux" ]]; then
          log "  tab has tmux window — blanking polluted title '$tab_title'"
          tab_title=""
          break
        fi
      done

      # Also blank tab titles that look like a stale shell command — these
      # are set by the shell's title escape when the user typed a command,
      # and persist even after the command exits. Restoring a polluted title
      # is misleading (tab says 'tmux attach -t 0' but tab actually runs bash).
      case "$tab_title" in
        tmux\ *|exec\ *|nvim\ *|less\ *|man\ *|vim\ *|sudo\ *|ssh\ *|cd\ *|ls\ *)
          log "  blanking polluted tab title that looks like a stale command: '$tab_title'"
          tab_title=""
          ;;
      esac

      echo "" >> "$tmp_conf"
      if [[ -n "$tab_title" ]]; then
        printf 'new_tab %s\n' "$tab_title" >> "$tmp_conf"
      else
        echo "new_tab" >> "$tmp_conf"
      fi
      echo "layout $tab_layout" >> "$tmp_conf"
      win_count=$(jq 'length' <<<"$filtered_json")
      if (( win_count == 0 )); then
        log "  tab has no non-overlay windows; emitting bare shell"
        emit_launch launch /bin/bash -l >> "$tmp_conf"
        continue
      fi
      for win_idx in $(seq 0 $((win_count - 1))); do
        local w_json
        w_json=$(jq ".[$win_idx]" <<<"$filtered_json")
        emit_launch_for_window "$w_json" "$win_idx" "$tab_layout" "$state" "$tmp_conf"
      done

      local active_idx
      active_idx=$(jq '[.[] | .is_active] | index(true) // 0' <<<"$filtered_json")
      if [[ "$active_idx" != "0" && -n "$active_idx" ]]; then
        echo "focus_matching_window var:ksession_idx=$active_idx" >> "$tmp_conf"
      fi
    done
  done < <(jq -c "$target_filter" <<<"$ls_json")

  if (( osw_count == 0 )); then
    rm -f "$tmp_conf"
    echo "ksession: no OS windows matched" >&2
    exit 1
  fi

  mv "$tmp_conf" "$conf"
  log "wrote $conf (OS windows: $osw_count)"
  echo "ksession: saved '$name' -> $conf"
  echo "ksession:   sidecar state in $state"
}

# ---------- restore / load / list / show / rm ----------

restore_session() {
  local name=${1:-}
  [[ -n "$name" ]] || { echo "usage: ksession restore <name>" >&2; exit 1; }
  validate_name "$name"
  local conf="$SESSIONS_DIR/$name.conf"
  [[ -f "$conf" ]] || { echo "ksession: no session '$name' (looked at $conf)" >&2; exit 1; }
  log "restore '$name'"
  exec kitty --detach --class "kitty-project-$name" --session "$conf"
}

load_session() {
  local name=${1:-}
  [[ -n "$name" ]] || { echo "usage: ksession load <name>" >&2; exit 1; }
  validate_name "$name"
  local conf="$SESSIONS_DIR/$name.conf"
  [[ -f "$conf" ]] || { echo "ksession: no session '$name' (looked at $conf)" >&2; exit 1; }
  echo "ksession: to fold '$name' into the current OS window, run project-loader.sh:"
  echo "         $HOME/.config/kitty/scripts/project-loader.sh"
  echo "         and pick '$name'. Or use 'ksession restore $name' for a fresh process."
}

list_sessions() {
  local f n d
  for f in "$SESSIONS_DIR"/*.conf; do
    n=$(basename "$f" .conf)
    d=$(grep -m1 -iE '^# *Description:' "$f" | sed -E 's/^# *[Dd]escription: *//' || true)
    printf '%-30s %s\n' "$n" "$d"
  done
}

show_session() {
  local name=${1:-}
  [[ -n "$name" ]] || { echo "usage: ksession show <name>" >&2; exit 1; }
  validate_name "$name"
  local conf="$SESSIONS_DIR/$name.conf" state="$SESSIONS_DIR/$name.state"
  [[ -f "$conf" ]] || { echo "ksession: no session '$name'" >&2; exit 1; }
  echo "=== $conf ==="
  cat -- "$conf"
  if [[ -d "$state" ]]; then
    echo
    echo "=== sidecars in $state ==="
    find "$state" -type f -printf '%p (%s bytes)\n' | sort
  fi
}

rm_session() {
  local name=${1:-}
  [[ -n "$name" ]] || { echo "usage: ksession rm <name>" >&2; exit 1; }
  validate_name "$name"
  rm -f -- "$SESSIONS_DIR/$name.conf"
  rm -rf -- "$SESSIONS_DIR/$name.state"

  # Drop the frecency entry too, so the store doesn't accumulate stale keys
  # that point at nonexistent .conf files. Best-effort: a missing lib (the
  # frecency feature is optional) MUST NOT fail the rm — the rm itself has
  # already succeeded by this point. Use path-relative resolution so the
  # source works regardless of how this script was invoked.
  local _frec_lib
  _frec_lib="$(dirname "${BASH_SOURCE[0]}")/lib/frecency.sh"
  if [[ -f "$_frec_lib" ]]; then
    # shellcheck source=lib/frecency.sh
    source "$_frec_lib"
    frecency_remove "$name" 2>>"$LOG" || \
      log "rm '$name': frecency_remove returned non-zero (ignored)"
  else
    log "rm '$name': frecency lib not found at $_frec_lib (skipping cleanup)"
  fi

  echo "ksession: removed '$name'"
}

usage() {
  cat <<EOF
ksession - kitty session state manager

Usage:
  ksession save <name> [--all] [--no-scrollback]
                                  Capture current OS window (or every OS window with --all).
                                  Scrollback is captured by default; pass --no-scrollback to skip.
  ksession restore <name>         Spawn a fresh kitty process from the saved session
  ksession load <name>            Hint: use the project-loader picker to load into current kitty
  ksession list                   List saved sessions
  ksession show <name>            Dump the .conf and list sidecar files
  ksession rm <name>              Delete session + sidecars

Adapters (Phase 1):
  nvim     :mksession over RPC socket; restored via 'nvim -S sidecar.vim'
  less/man fdinfo pos: -> '+<pct>%' on restore
  shell    VIRTUAL_ENV / CONDA_DEFAULT_ENV / OLDPWD captured; direnv via cwd
EOF
}

cmd=${1:-help}
shift || true
case "$cmd" in
  save)    save_session "$@" ;;
  restore) restore_session "$@" ;;
  load)    load_session "$@" ;;
  list)    list_sessions ;;
  show)    show_session "$@" ;;
  rm)      rm_session "$@" ;;
  help|-h|--help|"") usage ;;
  *) echo "ksession: unknown command '$cmd'" >&2; usage; exit 1 ;;
esac
