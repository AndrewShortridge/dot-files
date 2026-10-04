#!/usr/bin/env bash
# whichkey.sh: a which-key panel for tmux, lying across the bottom of the
# whole window over every pane (a borderless full-width display-popup).
# Same look and rules as the kitty which-key kitten (kittens/which_key.py):
# every prefix key is shown at once under section headers packed into
# columns, and any key fires immediately.
#
#   whichkey.sh open <client>          open the panel on <client> now
#   whichkey.sh prefix <client>        called from the prefix key binding:
#                                      open the panel if the client is still
#                                      in the prefix table after $WK_DELAY s
#   whichkey.sh panel [name]           the panel itself (runs inside the popup)
#
# Entries are `section^key^desc^action`; section `_` means no header.
# Most actions are empty, which means "replay the real binding": after the
# popup closes the client is put in the prefix table and the key is fed to
# it with `send-keys -K`, so the panel can never run something other than
# what tmux.conf binds. Others:
#   >name    descend into panel `name` (shown as a +group, like kitty)
#   =cmd     run a tmux command on the pane now and keep the panel open
# Esc / q close; BSpace backs out of a group (or closes).
#
# Dependencies: bash >= 4.3, tmux, stty, sleep. Nothing is forked while the
# panel is open except the tmux calls that actions ask for.
set -u
export LC_ALL=C.UTF-8          # ${#s} and printf widths count characters

WK_DELAY=${WK_DELAY:-0.4}

# ---- Spec (keys are the prefix keys from tmux.conf) --------------------------
panel_root=(
  'Panes^|^split right^'
  'Panes^-^split below^'
  'Panes^c^close pane^'
  'Panes^m^zoom toggle^'
  'Panes^w^pick pane^'
  'Panes^e^equalize^'
  'Panes^o^rotate panes^'
  'Panes^r^resize^>resize'
  'Navigate^h^focus left^'
  'Navigate^j^focus down^'
  'Navigate^k^focus up^'
  'Navigate^l^focus right^'
  'Navigate^H^swap left^'
  'Navigate^J^swap down^'
  'Navigate^K^swap up^'
  'Navigate^L^swap right^'
  'Windows^t^new window^'
  'Windows^x^close window^'
  'Windows^R^rename window^'
  'Windows^n^next window^'
  'Windows^p^previous window^'
  'Windows^0^last window^'
  'Windows^N^move window right^'
  'Windows^P^move window left^'
  'Sessions^s^session picker^'
  'Sessions^S^save session^'
  'Sessions^f^pane picker^'
  'Sessions^d^detach^'
  'Sessions^$^rename session^'
  'Sessions^(^previous session^'
  'Sessions^)^next session^'
  'Tools^/^scrollback^'
  'Tools^?^list keys^'
  'Tools^C-r^reload config^'
)
# Transient: the panel stays open so h/j/k/l repeat.
panel_resize=(
  '_^h^left 5^=resize-pane -L 5'
  '_^j^down 3^=resize-pane -D 3'
  '_^k^up 3^=resize-pane -U 3'
  '_^l^right 5^=resize-pane -R 5'
  '_^0^equalize^=select-layout -E'
  '_^m^zoom toggle^=resize-pane -Z'
)

# ---- Styling (identical SGR to the kitty kitten; the palette is One Dark) ----
KEY_ON=$'\e[1;35m'      KEY_OFF=$'\e[22;39m'
HDR_ON=$'\e[1;4;97m'    HDR_OFF=$'\e[22;24;39m'
RULE_ON=$'\e[1;97m'     RULE_OFF=$'\e[22;39m'
SEP='→'  GUTTER=' │ '   # both width 1 per glyph
PAD=2
declare -A sec_cells          # section -> cell indices, shared by layout/pack

# ---- Layout (port of kittens/which_key_layout.py::layout_sections) -----------
# Input: spec entries; COLS. Output: OUT (rendered rows, styled).
# A labeled section is a header plus its rows and never splits across
# columns; headerless rows flow column-first. Groups sort after plain rows.
# Columns are packed greedily at the smallest height that fits the number of
# columns the width allows; each column is as wide as its own widest box.
layout() {
  local -a entries=("$@") secs=() c_sec=() c_key=() c_desc=() plain=() groups=()
  local -A seen=()
  local e sec key desc action i n=0 s
  sec_cells=()

  # Section order as declared; within a section plain rows, then '+group'.
  for e in "${entries[@]}"; do
    sec=${e%%^*}; [[ -z ${seen[$sec]+x} ]] && { seen[$sec]=1; secs+=("$sec"); }
    if [[ ${e##*^} == '>'* ]]; then groups+=("$e"); else plain+=("$e"); fi
  done
  for e in "${plain[@]}" "${groups[@]}"; do
    IFS='^' read -r sec key desc action <<<"$e"
    c_sec[n]=$sec; c_desc[n]=$desc
    if [[ $action == '>'* ]]; then c_key[n]="+$key"; else c_key[n]=$key; fi
    sec_cells[$sec]+="$n "; ((n++))
  done

  # Widest possible box: key + padding + separator + padding + desc.
  local keyw=0 descw=0 hdrw=0 total=0 tallest=0 rows
  for ((i = 0; i < n; i++)); do
    ((${#c_key[i]} > keyw)) && keyw=${#c_key[i]}
    ((${#c_desc[i]} > descw)) && descw=${#c_desc[i]}
  done
  for s in "${secs[@]}"; do
    [[ $s != _ ]] && ((${#s} > hdrw)) && hdrw=${#s}
    set -- ${sec_cells[$s]}; rows=$#
    [[ $s != _ ]] && ((rows++))
    ((total += rows)); ((rows > tallest)) && tallest=$rows
  done
  local boxw boxes fixed=$((keyw + PAD + 1 + PAD))
  local maxdesc=$((COLS - fixed))
  if ((maxdesc < 1)); then descw=0; boxes=1
  else
    ((descw > maxdesc)) && descw=$maxdesc
    boxw=$((fixed + descw)); ((hdrw > boxw)) && boxw=$hdrw
    boxes=$(((COLS + 3) / (boxw + 3))); ((boxes < 1)) && boxes=1; ((boxes > n)) && boxes=$n
  fi
  DESCW=$descw

  # Smallest column height at which the sections pack into `boxes` columns.
  H=$(((total + boxes - 1) / boxes)); ((H < tallest)) && H=$tallest; ((H < 1)) && H=1
  while :; do
    pack "${secs[@]}"
    ((${#CNT[@]} <= boxes)) && break
    ((H++))
  done

  # Per-column geometry: key width, desc width, box width.
  local c j kind payload kw dw bw
  local -a KW=() DW=() BW=()
  for ((c = 0; c < ${#CNT[@]}; c++)); do
    kw=0; dw=0; bw=0
    for ((j = OFF[c]; j < OFF[c] + CNT[c]; j++)); do
      kind=${LN[j]%%:*}; payload=${LN[j]#*:}
      case $kind in
        C) ((${#c_key[payload]} > kw)) && kw=${#c_key[payload]}
           ((${#c_desc[payload]} > dw)) && dw=${#c_desc[payload]} ;;
        H) ((${#payload} > bw)) && bw=${#payload} ;;
      esac
    done
    ((dw > DESCW)) && dw=$DESCW
    local b=$((kw + PAD + 1 + PAD + dw)); ((DESCW == 0)) && b=$kw
    ((b > bw)) && bw=$b
    KW[c]=$kw; DW[c]=$dw; BW[c]=$bw
  done

  # Render row by row; pad every box but the row's last to its column width.
  OUT=()
  local r maxrows=0 line plain styled last cell text
  for ((c = 0; c < ${#CNT[@]}; c++)); do ((CNT[c] > maxrows)) && maxrows=${CNT[c]}; done
  for ((r = 0; r < maxrows; r++)); do
    last=-1
    for ((c = 0; c < ${#CNT[@]}; c++)); do ((r < CNT[c])) && last=$c; done
    line=''
    for ((c = 0; c <= last; c++)); do
      plain=''; styled=''
      if ((r < CNT[c])); then
        j=$((OFF[c] + r)); kind=${LN[j]%%:*}; payload=${LN[j]#*:}
        case $kind in
          H) plain=${payload:0:BW[c]}; styled="$HDR_ON$plain$HDR_OFF" ;;
          C) key=${c_key[payload]}; desc=${c_desc[payload]:0:DW[c]}
             printf -v cell '%-*s' "${KW[c]}" "$key"
             if ((DESCW > 0)); then
               printf -v text '%*s%s%*s%s' "$PAD" '' "$SEP" "$PAD" '' "$desc"
             else text=''; fi
             plain="$cell$text"; styled="$KEY_ON$cell$KEY_OFF$text" ;;
        esac
      fi
      if ((c != last)); then
        printf -v styled '%s%*s%s' "$styled" $((BW[c] - ${#plain})) '' "$GUTTER"
      fi
      line+=$styled
    done
    OUT+=("${line%"${line##*[! ]}"}")
  done
}

# pack <sections...>: greedy column packing at height H.
# Fills LN (lines "H:label" / "C:index" / "B:"), OFF (column starts), CNT.
pack() {
  LN=(); OFF=(); CNT=()
  local s i first
  for s in "$@"; do
    set -- ${sec_cells[$s]}
    if [[ $s != _ ]]; then
      if ((${#CNT[@]} > 0)) && ((CNT[-1] + 1 + 1 + $# > H)); then newcol; fi
      put "H:$s" 1
      for i in "$@"; do put "C:$i" 0; done
    else
      first=1
      for i in "$@"; do put "C:$i" "$first"; first=0; done
    fi
  done
}
newcol() { OFF+=("${#LN[@]}"); CNT+=(0); }
put() {
  local gap=0
  ((${#CNT[@]} == 0)) && newcol
  ((CNT[-1] > 0 && $2)) && gap=1
  if ((CNT[-1] > 0 && CNT[-1] + gap + 1 > H)); then newcol
  elif ((gap)); then LN+=("B:"); ((CNT[-1]++)); fi
  LN+=("$1"); ((CNT[-1]++))
}

# render <name>: the full-width rule, the trail when inside a group, then
# the laid-out rows, from the top of the popup.
render() {
  local name=$1 rule
  printf -v rule '%*s' "$COLS" ''; rule=${rule// /━}
  printf '\e[H\e[2J%s%s%s\n' "$RULE_ON" "$rule" "$RULE_OFF"
  [[ $name != root ]] && printf 'which-key: %s\n' "$name"
  printf '%s\n' "${OUT[@]}"
}

# ---- Opening -----------------------------------------------------------------
# The popup must be given its height up front, so lay the root panel out for
# the client's width here and open a popup exactly that tall.
open_panel() {
  local client=$1
  COLS=$(tmux display -p -c "$client" '#{client_width}')
  layout "${panel_root[@]}"
  exec tmux display-popup -c "$client" -E -b none -x 0 -y S -w 100% -h $((1 + ${#OUT[@]})) \
    -s 'fg=#979eab,bg=#282c34' "$0 panel"
}

case ${1:-} in
  open) open_panel "$2"; exit ;;
  prefix)
    sleep "$WK_DELAY"
    [[ $(tmux display -p -c "$2" '#{client_key_table}') == prefix ]] && open_panel "$2"
    exit 0 ;;
  panel) ;;
  *) echo "usage: $0 open|prefix <client>" >&2; exit 2 ;;
esac

# ---- Panel (inside the popup) ------------------------------------------------
# $TMUX is set and an unqualified `tmux` resolves the invoking client and its
# active pane; pin them once so actions target the same pane even if focus
# moves while the panel is open.
read -r CLIENT PANE < <(tmux display -p '#{client_name} #{pane_id}')
read -r _ COLS < <(stty size </dev/tty)

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

# Replays a prefix key on the client. When the panel was opened by
# hesitating after the prefix the client is still in the prefix table, so
# set the table explicitly instead of sending the prefix key itself.
replay() {
  defer "tmux switch-client -c '$CLIENT' -T prefix \\; send-keys -K -c '$CLIENT' -- '$1'"
  exit 0
}

# Closing the panel must also leave the prefix table, or the next keystroke
# would be taken as a prefix command.
close() {
  tmux switch-client -c "$CLIENT" -T root
  exit 0
}

name=root
while :; do
  declare -n spec="panel_$name"
  layout "${spec[@]}"
  render "$name"
  read_key
  case $REPLY in
    Escape | q) close ;;
    BSpace) [[ $name == root ]] && close; name=root; continue ;;
  esac
  action=; found=
  for e in "${spec[@]}"; do
    IFS='^' read -r _ key _ action <<<"$e"
    [[ $key == "$REPLY" ]] && { found=1; break; }
  done
  [[ $found ]] || continue
  case $action in
    '')   replay "$REPLY" ;;
    '>'*) name=${action#>} ;;
    '='*) set -- ${action#=}; tmux "$1" -t "$PANE" "${@:2}" ;;
  esac
done
