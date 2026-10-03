# Kitty Keybind Reference

Generated from `~/.config/kitty/kitty.conf` and kitty's built-in defaults
(extracted via `kitty +runpy` against the installed version). `kitty_mod` =
`ctrl+shift`.

Reload after editing config: `ctrl+shift+f5` (or `kitty @ load-config`).

---

## Conventions used below

- **Leader** = `ctrl+space` chord prefix. Tap and release `ctrl+space`, then
  tap the next key. No need to hold. The leader is now driven by the
  **which-key kitten** plus a declarative chord spec
  (`kittens/which_key_spec.py`), not by native `map ctrl+space>…` lines.
  Pressing `ctrl+space` arms a ~200ms budget measured from the keypress: a
  known chord key typed within that window fires immediately with no popup;
  otherwise a which-key
  popup appears at the bottom of the window listing the continuations and stays
  open (sticky) until you pick a leaf, press `Esc`, or `Backspace` out. To
  add/change a chord, edit `kittens/which_key_spec.py`.
- "Shadowed" = a default kitty binding that this config replaces with
  something else. The default action is no longer reachable on that key.

---

## Physical layer (keyd) — Caps / Tab / Space

`keyd/default.conf` (installed to `/etc/keyd/default.conf` by
`keyd/install.sh`) makes two home-row keys dual-role so you never reach for
Super/Alt/Ctrl. `hjkl` always means a direction; the held key picks the scope.

| Key | Tap | Hold |
|---|---|---|
| `Caps Lock` | `Esc` | **Super** → COSMIC window / workspace layer |
| `Tab` | `Tab` | **Alt** → kitty pane layer |
| `Space` | `Space` | **Ctrl**, but *only* while Caps or Tab is already held |
| `Enter` | `Enter` | **Ctrl** (single-hold Ctrl for the right hand) |

Composition (physical `Shift` stacks on top of all of these):

| Chord | Emits | Scope / action |
|---|---|---|
| `Caps + hjkl` | `Super+hjkl` | COSMIC: focus window left/down/up/right |
| `Caps + Shift + hjkl` | `Super+Shift+hjkl` | COSMIC: move window |
| `Caps + 1…9` / `Shift+1…9` | `Super+N` / `Super+Shift+N` | COSMIC: go to / move window to workspace N |
| `Caps + n` / `p` | `Super+n` / `Super+p` | COSMIC: next / previous workspace (custom) |
| `Caps + q` / `m` / `s` / `g` / `o` | `Super+…` | COSMIC: close / maximize / stack / float / orientation |
| `Caps + Enter` | `Super+Return` | COSMIC: launch kitty (custom) |
| `Caps + Space` (tap) | `Super+space` | COSMIC: launcher (custom) |
| `Caps + Shift + b` | `Super+Shift+b` | COSMIC: bookmarks picker (`~/.local/bin/bookmarks --popup`, custom) |
| `Caps + Space + key` | `Ctrl+key` | plain Ctrl: `Ctrl+c/v/z/…`, `Ctrl+l` clear, `Ctrl+k` kill-line, fzf `Ctrl+j/k` |
| `Enter + key` | `Ctrl+key` | single-hold Ctrl for the right hand: `Enter+c` Ctrl+C, … |
| `Enter + Shift + key` | `Ctrl+Shift+key` | e.g. `Enter+Shift+c/v` copy/paste in kitty |
| `Tab + hjkl` | `Alt+hjkl` | kitty: focus pane |
| `Tab + Shift + hjkl` | `Alt+Shift+hjkl` | kitty: swap pane |
| `Tab + \` / `-` | `Alt+\` / `Alt+-` | kitty: vertical / horizontal split |
| `Tab + x` / `z` | `Alt+x` / `Alt+z` | kitty: close pane / toggle stack (zoom) |
| `Tab + [` / `]` | `Alt+[` / `Alt+]` | kitty: previous / next tab |
| `Tab + 1…9` / `0` | `Alt+1…9` / `Alt+0` | kitty: go to tab N / last-visited tab |
| `Tab + w` / `Shift+w` | `Alt+w` / `Alt+Shift+w` | kitty: pick pane by label / swap with picked pane |
| `Tab + Shift + t` / `Shift+x` | `Alt+Shift+t` / `Alt+Shift+x` | kitty: pane → new tab / pane → chosen tab |
| `Tab + Space` (tap) | `Alt+space` | COSMIC: launcher (custom) |
| `Tab + Space + key` | `Ctrl+key` | plain Ctrl, same as above |
| `Caps + Tab` | `Super+Tab` | COSMIC: window switcher |
| `Caps + Ctrl + hjkl` (physical Ctrl) | `Super+Ctrl+hjkl` | COSMIC: prev/next workspace |

Notes:

- `Caps+Space+key` / `Tab+Space+key` is *plain* Ctrl for letters, digits,
  punctuation, Enter/Backspace/Esc/arrows/F-keys (explicit composite-layer
  bindings). Any key not in that list falls through to `Super+Ctrl+key` /
  `Alt+Ctrl+key`.
- A Caps/Tab held longer than 400 ms and released with no other key emits
  nothing (no stray `Esc`/`Tab`): `overload_tap_timeout` in `[global]`.
- Holding `Tab` or `Enter` for key-repeat no longer works (they are Alt / Ctrl
  while held). An `Enter` held >400 ms and released alone also emits nothing
  (same `overload_tap_timeout`).
- The real Super/Alt/Ctrl keys are untouched; `Alt+Space` launcher and the
  bare-`Super`-tap workspace overview still work.
- Panic exit if a config change wedges input: `Backspace+Esc+Enter` kills keyd.
- Reload after editing: `./keyd/install.sh apply` (or `sudo keyd reload`).
- swhkd is intentionally **not** used: COSMIC's own shortcut config already
  spawns commands (`Spawn("…")` entries in
  `~/.config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom`), so a
  second hotkey daemon grabbing the keyboard adds nothing.

## Custom bindings

### Leader chord (`ctrl+space > …`)

Defined in `kittens/which_key_spec.py`. The popup appears ~200ms after the
keypress (known keys typed within that window fire with no popup) and is
cancellable with `Esc` or `Backspace`. Tunable: `BUDGET_S` in
`kittens/which_key_timing.py`; the floor is the kitten's own spawn (~180ms).

| Chord | Action |
|---|---|
| `ctrl+space > \|` (`bar`) | Vertical split |
| `ctrl+space > -` (`minus`) | Horizontal split |
| `ctrl+space > c` | Close window (split) |
| `ctrl+space > h` / `j` / `k` / `l` | Focus neighbor left/down/up/right |
| `ctrl+space > H` / `J` / `K` / `L` | Swap window left/down/up/right |
| `ctrl+space > m` | Toggle maximize (stack layout) |
| `ctrl+space > w` | Pick a pane by overlay label (`focus_visible_window`) |
| `ctrl+space > r` | Interactive resize mode (arrows nudge, Enter commits, Esc cancels) |
| `ctrl+space > t` | New tab in current cwd |
| `ctrl+space > x` | Close tab |
| `ctrl+space > n` | Next tab |
| `ctrl+space > p` | Previous tab |
| `ctrl+space > N` | Move tab forward |
| `ctrl+space > P` | Move tab backward |
| `ctrl+space > R` | Rename current tab |
| `ctrl+space > /` | Scrollback in nvim (kitty-scrollback.nvim) |
| `ctrl+space > ?` (`shift+/`) | Command palette |
| `ctrl+space > s` | Fuzzy session picker (fzf across all OS windows) |
| `ctrl+space > S` | Save current OS window as a named session (ksession) |
| `ctrl+space > f` | Fuzzy tab/split picker (fzf inside current OS window) |
| `ctrl+space > v` | View this window's saved scrollback (ksession `.ansi` dump) in `less` |
| `ctrl+space > o` | Load a project's session into the current kitty |

### Direct bindings — window navigation & splits

Bare `ctrl+h/j/k/l` is intentionally **not** bound: those keys reach zsh
(`ctrl+l` clear, `ctrl+k` kill-line), fzf (`ctrl+j/k`) and nvim unchanged.
Pane focus lives on the Alt layer (held `Tab`) and the leader.

| Key | Action |
|---|---|
| `ctrl+shift+h` / `j` / `k` / `l` | Swap window left/down/up/right |
| `ctrl+shift+\` (i.e. `ctrl+\|`) | Vertical split |
| `ctrl+shift+-` | Horizontal split |
| `ctrl+shift+w` | Close window |
| `ctrl+shift+r` | Rotate split orientation |
| `ctrl+shift+z` | Toggle stack (zoom/unzoom) |

### Direct bindings — Alt layer (held `Tab` via keyd)

Same actions as above, reachable without Ctrl. `alt+n`/`alt+p` are left
unbound on purpose: nvim uses `<A-n>`/`<A-p>` (Snacks.words).

| Key | Action |
|---|---|
| `alt+h` / `j` / `k` / `l` | Focus neighbor left/down/up/right |
| `alt+shift+h` / `j` / `k` / `l` | Swap window left/down/up/right |
| `alt+\` | Vertical split |
| `alt+-` | Horizontal split |
| `alt+x` | Close window |
| `alt+z` | Toggle stack (zoom/unzoom) |
| `alt+[` / `alt+]` | Previous / next tab |
| `alt+1` … `alt+9` | Go to tab N (tab titles are prefixed `N:`) |
| `alt+0` | Go to last-visited tab (toggle between two tabs) |
| `alt+w` | Pick a pane by overlay label (`focus_visible_window`) |
| `alt+shift+w` | Swap current pane with a picked pane |
| `alt+shift+t` | Detach current pane into a new tab |
| `alt+shift+x` | Detach current pane into a chosen tab (`detach_window ask`) |

Layouts are `splits,stack` (`enabled_layouts`): `--location=vsplit/hsplit`
only works in `splits`, and `toggle_layout stack` only works when `stack` is
enabled.

Shadowed readline/zle bindings on these keys (now intercepted by kitty):
`alt+l` downcase-word, `alt+x` (unbound), `alt+-` negative digit argument,
`alt+\` delete-horizontal-space, `alt+]` character-search.

### Direct bindings — resize (held-modifier)

| Key | Action |
|---|---|
| `ctrl+alt+h` / `l` | Narrower / wider |
| `ctrl+alt+k` / `j` | Taller / shorter |
| `ctrl+alt+0` | Reset size |

### Direct bindings — tabs

| Key | Action |
|---|---|
| `ctrl+shift+t` | New tab in current cwd |
| `ctrl+shift+q` | Close tab |
| `ctrl+tab` | Next tab |
| `ctrl+shift+tab` | Previous tab |

### Direct bindings — prompt navigation & last command output

Require shell integration (enabled). Clearing the screen is plain `ctrl+l`
(zsh) again.

| Key | Action |
|---|---|
| `ctrl+shift+up` / `down` | Jump to previous / next shell prompt |
| `ctrl+shift+x` | Jump to next prompt (kitty default, no longer shadowed) |
| `ctrl+shift+f4` | Copy last command's output to clipboard |

### Scrollback (kitty-scrollback.nvim)

| Key | Action |
|---|---|
| `ctrl+shift+f1` | Browse full scrollback in nvim |
| `ctrl+shift+f2` | Browse last command's output in nvim |
| `ctrl+shift+right-click` on a prompt | Open that command's output in nvim |

---

## Helper scripts (invoked by leader bindings)

Located in `~/.config/kitty/scripts/`. Both require `jq` and `fzf` on PATH
and use kitty's remote control socket.

- **`session-picker.sh`** — bound to `ctrl+space > s`. Lists every kitty
  OS window with its active tab title, tab count, and cwd. fzf preview
  shows the active window's screen. Selection runs
  `kitty @ focus-window` (which also raises the containing tab and OS
  window).
- **`tab-picker.sh`** — bound to `ctrl+space > f`. Lists every tab + split
  inside the **current** OS window, formatted as `[tab.win] tab_title ›
  window_title · cwd`. Same fzf preview pattern. Detects current OS window
  via `KITTY_WINDOW_ID`.
- **`scrollback-viewer.sh`** — bound to `ctrl+space > v`. Opens the current
  window's **saved** scrollback (the `.ansi` dump captured by `ksession
  save`) in `less -R +G`. Resolves the window's `ksession_id` user var via
  `kitty @ ls`, finds the matching entry across `sessions/*.state/
  manifest.json` (newest generation wins), and errors gracefully if the
  window has no saved session or the dump is missing/empty. Needs `jq`;
  fzf not required.

---

## Kitty defaults (still active)

These are kitty's built-in bindings that this config does **not** override,
so they still work.

### Clipboard

| Key | Action |
|---|---|
| `ctrl+shift+c` | Copy to clipboard |
| `ctrl+shift+v` | Paste from clipboard |
| `ctrl+shift+s` | Paste from selection |
| `shift+insert` | Paste from selection |
| `ctrl+shift+o` | Pass selection to program |

### Scrolling (in the kitty pager / terminal)

| Key | Action |
|---|---|
| `ctrl+shift+page_up` | Scroll one page up |
| `ctrl+shift+page_down` | Scroll one page down |
| `ctrl+shift+home` | Scroll to top |
| `ctrl+shift+end` | Scroll to bottom |
| `ctrl+shift+g` | Show last command output |
| `ctrl+shift+/` | Search scrollback |

### Window / OS-window

| Key | Action |
|---|---|
| `ctrl+shift+enter` | New kitty window in current tab |
| `ctrl+shift+n` | New OS window |
| `ctrl+shift+]` / `[` | Next / previous window |
| `ctrl+shift+f` / `b` | Move window forward / backward |
| `` ctrl+shift+` `` | Move window to top |
| `ctrl+shift+1` … `9` / `0` | Focus 1st … 9th / 10th window (tabs are `alt+N`) |
| `ctrl+shift+F7` | Focus visible window (picker; also `alt+w`) |
| `ctrl+shift+F8` | Swap with window (picker; also `alt+shift+w`) |

### Tabs

| Key | Action |
|---|---|
| `ctrl+shift+right` / `left` | Next / previous tab |
| `ctrl+shift+.` / `,` | Move tab forward / backward |
| `ctrl+shift+alt+t` | Rename current tab |

### Font size

| Key | Action |
|---|---|
| `ctrl+shift+=` / `+` / `kp_add` | Font size +2 |
| `ctrl+shift+kp_subtract` | Font size −2 (see shadow note below) |
| `ctrl+shift+backspace` | Reset font size |

### Hints / picker

| Key | Action |
|---|---|
| `ctrl+shift+e` | Open URL with hints |
| `ctrl+shift+p` | Hints menu — path/line/word/hash/linenum/hyperlink, choose-files, choose-dir |

### Miscellaneous

| Key | Action |
|---|---|
| `ctrl+shift+F1` | Show kitty docs (overview) |
| `ctrl+shift+F2` | Edit config file |
| `ctrl+shift+F3` | Command palette |
| `ctrl+shift+F5` | Reload config file |
| `ctrl+shift+F6` | Show debug config |
| `ctrl+shift+F10` | Toggle maximized |
| `ctrl+shift+F11` | Toggle fullscreen |
| `ctrl+shift+u` | Unicode input |
| `ctrl+shift+escape` | Open kitty shell in new window |
| `ctrl+shift+a` | Background opacity submenu (`+0.1` / `−0.1` / `1` / default) |
| `ctrl+shift+delete` | Clear terminal (full reset) |

---

## Defaults shadowed by this config

| Key | What it used to do | What it does now |
|---|---|---|
| `ctrl+shift+up` | Scroll one line up | Scroll to previous prompt |
| `ctrl+shift+down` | Scroll one line down | Scroll to next prompt |
| `ctrl+shift+h` | Show scrollback in pager (`less`) | Swap window left |
| `ctrl+shift+j` | Scroll line down | Swap window down |
| `ctrl+shift+k` | Scroll line up | Swap window up |
| `ctrl+shift+l` | Next layout | Swap window right |
| `ctrl+shift+r` | Start interactive resize | Rotate split orientation (use `ctrl+space > r` for resize, via the which-key kitten) |
| `ctrl+shift+z` | Scroll to previous prompt | Toggle stack layout |
| `ctrl+shift+\` | (no default) | Vertical split |
| `ctrl+shift+-` (`minus`) | Font size −2 | Horizontal split (use `ctrl+shift+kp_subtract` to decrement font) |
| `ctrl+shift+t` | New tab | New tab in current cwd |
| `ctrl+shift+q` | Close tab (same) | Close tab |

---

## Mental model

- **`hjkl` is always a direction; the held key is the scope** (keyd):
  `Caps+hjkl` = COSMIC window, `Tab+hjkl` = kitty split. Add `Shift` to
  either to *move* instead of *focus*.
- **Bare `ctrl+hjkl` reaches the shell/nvim** — kitty does not intercept it.
- **`ctrl+shift+hjkl`** / **`alt+shift+hjkl`** = swap splits.
- **`alt+N`** = tab N (titles show the number); **`alt+0`** = last tab;
  **`alt+w`** = jump to any visible pane by label.
- **`ctrl+shift+up/down`** = walk shell prompts; **`ctrl+shift+f2`/`f4`** =
  last command's output in nvim / to clipboard.
- **`ctrl+alt+hjkl`** = resize splits (hold to repeat).
- **`ctrl+space` leader** = everything tab-related, command palette, pickers,
  and a mirror of split/window actions for when single-tap chords feel
  awkward. Driven by the **which-key kitten** (`kittens/which_key.py`) over the
  chord spec (`kittens/which_key_spec.py`): a short pause shows a popup of the
  available continuations; a fast known key fires with no popup.
- **`ctrl+space > ?`** opens the command palette — searchable list of every
  action kitty knows, even those without a keybinding.
