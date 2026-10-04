#!/usr/bin/env bash
# whichkey.sh <menu>: a which-key panel for tmux, run inside
#   display-popup -E -b none -x 0 -y S -w 100%
# so it lies across the bottom of the whole window, over every pane.
#
# Menus are `key^label^action` tables below. Most actions are empty, which
# means "replay the real binding": after the popup closes the key is fed to
# the client as `C-a <key>` with `send-keys -K`, so the panel can never run
# something other than what tmux.conf binds. Other actions:
#   >name    open sub-menu `name` in this panel
#   @keys    replay these keys instead of `C-a <key>` (root-table bindings)
#   :cmd     run a tmux command after the popup closes
#   =cmd     run a tmux command on the pane now and keep the panel open
# Esc / q close; BSpace goes back to the root menu.
#
# Dependencies: bash, tmux, stty. Nothing is forked while the panel is open
# except the tmux calls that actions ask for.
set -u

# ---- Menus (keys are the prefix keys from tmux.conf) ------------------------
menu_root=(
  'p^+panes^>panes'
  'w^+windows^>windows'
  's^+sessions^>sessions'
  'r^+resize^>resize'
  '/^Scrollback (copy mode)^'
  '?^List prefix keys^'
  'C-r^Reload tmux.conf^'
)
menu_panes=(
  '|^Split right^'
  '-^Split below^'
  'c^Close pane^'
  'h^Focus left^'
  'j^Focus down^'
  'k^Focus up^'
  'l^Focus right^'
  'w^Pick pane by label^'
  'H^Swap left^'
  'J^Swap down^'
  'K^Swap up^'
  'L^Swap right^'
  'o^Rotate panes^'
  'm^Zoom toggle^'
  'e^Equalize^'
  'r^+resize^>resize'
  'T^Break to new window^@M-T'
  'X^Send to window...^@M-X'
)
menu_windows=(
  't^New window^'
  'x^Close window^'
  'R^Rename window...^'
  'n^Next window^'
  'p^Previous window^'
  '0^Last window^'
  'N^Move window right^'
  'P^Move window left^'
  'f^Pane picker^'
)
menu_sessions=(
  's^Session picker^'
  'S^Save session...^'
  'f^Pane picker^'
  "n^New session...^:command-prompt -p 'new session:' 'new-session -d -s \"%%\" ; switch-client -t \"%%\"'"
  '$^Rename session...^'
  ')^Next session^'
  '(^Previous session^'
  'd^Detach^'
)
# Transient: the panel stays open so h/j/k/l repeat.
menu_resize=(
  'h^Left 5^=resize-pane -L 5'
  'j^Down 3^=resize-pane -D 3'
  'k^Up 3^=resize-pane -U 3'
  'l^Right 5^=resize-pane -R 5'
  '0^Equalize^=select-layout -E'
  'm^Zoom toggle^=resize-pane -Z'
)

# ---- Palette (tmux.conf One Dark; truecolor, the popup is always RGB) --------
FG=$'\e[38;2;151;158;171m'          # $FG
DIM=$'\e[38;2;127;132;142m'         # $INACTIVE_FG
KEY=$'\e[1;38;2;86;182;194m'        # $ACTIVE_BG, bold
GROUP=$'\e[38;2;198;120;221m'       # $MAGENTA
TITLE=$'\e[1;38;2;171;178;191m'     # $BRIGHT, bold
RESET=$'\e[0m'

# ---- Context ------------------------------------------------------------------
# Inside display-popup $TMUX is set and an unqualified `tmux` resolves the
# invoking client and its active pane; pin them once so actions target the
# same pane even if focus moves while the panel is open.
read -r CLIENT PANE < <(tmux display -p '#{client_name} #{pane_id}')
read -r ROWS COLS < <(stty size </dev/tty)

# ---- Rendering ---------------------------------------------------------------
# Column-major grid of "key → label" cells, keys right-aligned.
render() {
  local name="$1"; shift
  local -a items=("$@")
  local n=${#items[@]} keyw=1 labw=1 key label i
  for i in "${items[@]}"; do
    key=${i%%^*}; label=${i#*^}; label=${label%%^*}
    ((${#key} > keyw)) && keyw=${#key}
    ((${#label} > labw)) && labw=${#label}
  done
  local cellw=$((keyw + 3 + labw + 2))
  local cols=$(((COLS - 1) / cellw)); ((cols < 1)) && cols=1
  local rows=$(((n + cols - 1) / cols))
  # Title row + items must fit the popup: trade label width for columns.
  local maxrows=$((ROWS - 1))
  if ((rows > maxrows && maxrows > 0)); then
    rows=$maxrows; cols=$(((n + rows - 1) / rows))
    cellw=$(((COLS - 1) / cols)); labw=$((cellw - keyw - 5)); ((labw < 1)) && labw=1
  fi
  printf '\e[H\e[2J'
  local hint='Esc close'; [[ $name != which-key ]] && hint="BSpace back  ·  $hint"
  printf ' %s%s%s%*s%s%s%s\n' "$TITLE" "$name" "$RESET" \
    $((COLS - ${#name} - ${#hint} - 3)) '' "$DIM" "$hint" "$RESET"
  local r c idx color
  for ((r = 0; r < rows; r++)); do
    for ((c = 0; c < cols; c++)); do
      idx=$((c * rows + r)); ((idx >= n)) && break
      key=${items[idx]%%^*}; label=${items[idx]#*^}; label=${label%%^*}
      color=$FG; [[ $label == +* ]] && color=$GROUP
      printf ' %s%*s%s %s→%s %s%-*.*s%s' "$KEY" "$keyw" "$key" "$RESET" "$DIM" "$RESET" \
        "$color" "$labw" "$labw" "$label" "$RESET"
    done
    printf '\n'
  done
}

# ---- Input -------------------------------------------------------------------
# Sets REPLY to the pressed key in tmux's spelling: printable chars as-is,
# control chars as C-x, Alt chords as M-x, Escape / BSpace / Enter by name.
read_key() {
  local k rest code
  IFS= read -rsn1 k || { REPLY=Escape; return; }
  case $k in
    $'\e')
      if IFS= read -rsn1 -t 0.02 rest; then REPLY="M-$rest"; else REPLY=Escape; fi ;;
    $'\x7f' | $'\b') REPLY=BSpace ;;
    '') REPLY=Enter ;;
    [[:cntrl:]])
      printf -v code '%d' "'$k"
      printf -v REPLY 'C-%b' "\\$(printf '%03o' $((code + 96)))" ;;
    *) REPLY=$k ;;
  esac
}

# Runs once the popup has closed: a key sent while the popup is still up is
# swallowed by its overlay instead of reaching the client's key tables.
defer() {
  tmux run-shell -b "sleep 0.05; $*"
}

# ---- Main loop ---------------------------------------------------------------
menu=${1:-root}
while :; do
  declare -n items="menu_$menu"
  title=$menu; [[ $menu == root ]] && title=which-key
  render "$title" "${items[@]}"
  read_key
  case $REPLY in
    Escape | q) exit 0 ;;
    BSpace) menu=root; continue ;;
  esac
  action=; found=
  for i in "${items[@]}"; do
    if [[ ${i%%^*} == "$REPLY" ]]; then action=${i#*^}; action=${action#*^}; found=1; break; fi
  done
  [[ $found ]] || continue
  case $action in
    '')   defer "tmux send-keys -K -c '$CLIENT' -- C-a '$REPLY'"; exit 0 ;;
    '>'*) menu=${action#>} ;;
    '@'*) defer "tmux send-keys -K -c '$CLIENT' -- '${action#@}'"; exit 0 ;;
    ':'*) defer "tmux ${action#:}"; exit 0 ;;
    '='*) set -- ${action#=}; tmux "$1" -t "$PANE" "${@:2}" ;;
  esac
done
