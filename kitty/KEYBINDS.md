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

## Physical layer (keyd) — home-row mods

`keyd/default.conf` (installed to `/etc/keyd/default.conf` by
`keyd/install.sh`) makes the home-row keys dual-role, mirrored on both hands
(pinky → index), so you never reach for Super/Alt/Shift/Ctrl. `hjkl` always
means a direction; the held mod picks the scope.

| Hold → | **Super** | **Alt** | **Shift** | **Ctrl** |
|---|---|---|---|---|
| Left hand | `a` | `s` | `d` | `f` |
| Right hand | `;` | `l` | `k` | `j` |

Tapping any of them types the letter. `Caps Lock` is plain `Esc`.

Use the mod on the *opposite* hand from the key it modifies; hold several to
stack them:

| Chord | Emits | Scope / action |
|---|---|---|
| `a + hjkl` | `Super+hjkl` | COSMIC: focus window left/down/up/right |
| `a + d + hjkl` | `Super+Shift+hjkl` | COSMIC: move window |
| `a`/`; + 1…9` (opposite hand), add `d`/`k` | `Super+N` / `Super+Shift+N` | COSMIC: go to / move window to workspace N |
| `a + n` / `p` | `Super+n` / `Super+p` | COSMIC: next / previous workspace (custom) |
| `a + [` / `]` | `Super+[` / `Super+]` | COSMIC: previous / next workspace on this monitor (custom) |
| `a + d + [` / `]` | `Super+Shift+[` / `]` | COSMIC: move window to previous / next workspace on this monitor (custom) |
| `; + q` / `a + m` / `; + s` / `; + g` / `a + o` | `Super+…` | COSMIC: close / maximize / stack / float / orientation |
| `a + Enter` | `Super+Return` | COSMIC: launch kitty (custom) |
| `a + Space` | `Super+space` | COSMIC: launcher (custom) |
| `; + k + b` | `Super+Shift+b` | COSMIC: bookmarks picker (`~/.local/bin/bookmarks --popup`, custom) |
| `a + f + hjkl` | `Super+Ctrl+hjkl` | COSMIC: prev/next workspace |
| `; + Tab` | `Super+Tab` | COSMIC: window switcher |
| `j + key` / `f + key` | `Ctrl+key` | `Ctrl+c/v/z/…`, `Ctrl+l` clear, `Ctrl+k` kill-line, fzf `Ctrl+j/k` |
| `j + k + c` / `v` | `Ctrl+Shift+c` / `v` | copy/paste in kitty |
| `s + hjkl` | `Alt+hjkl` | kitty: focus pane |
| `s + d + hjkl` | `Alt+Shift+hjkl` | kitty: swap pane |
| `s + \` / `-` | `Alt+\` / `Alt+-` | kitty: vertical / horizontal split |
| `l + x` / `z` | `Alt+x` / `Alt+z` | kitty: close pane / toggle stack (zoom) |
| `s + [` / `]` | `Alt+[` / `Alt+]` | kitty: previous / next tab |
| `s`/`l + 1…9` / `0` (opposite hand) | `Alt+1…9` / `Alt+0` | kitty: go to tab N / last-visited tab |
| `l + w` / `l + k + w` | `Alt+w` / `Alt+Shift+w` | kitty: pick pane by label / swap with picked pane |
| `l + k + t` / `l + k + x` | `Alt+Shift+t` / `Alt+Shift+x` | kitty: pane → new tab / pane → chosen tab |

Notes:

- Each mod is `lettermod(<mod>, <key>, 150, 200)`: struck within 150 ms of
  the previous letter it is always the letter (normal typing has no lag);
  otherwise it becomes the mod once held 200 ms or as soon as another key is
  tapped while it is down.
- Holding a home-row key for key-repeat no longer works (it becomes a mod).
- The real Super/Alt/Shift/Ctrl keys are untouched; `Tab`, `Space` and
  `Enter` are plain keys again.
- Panic exit if a config change wedges input: `Backspace+Esc+Enter` kills keyd.
- Reload after editing: `./keyd/install.sh apply` (or `sudo keyd reload`).
- swhkd is intentionally **not** used: COSMIC's own shortcut config already
  spawns commands (`Spawn("…")` entries in
  `~/.config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom`), so a
  second hotkey daemon grabbing the keyboard adds nothing.

### Navigation layers (held `v` / `n`)

Hold `v` or `n` and the *other* hand becomes arrows and paging keys,
finger-for-finger mirrored like the mods. Tapping `v` / `n` types the letter
(same `lettermod` timing as the home row).

| Emits → | Left | Down | Up | Right | PageUp | Home | End | PageDown |
|---|---|---|---|---|---|---|---|---|
| Hold `v` (`nav_r`) | `h` | `j` | `k` | `l` | `u` | `i` | `o` | `p` |
| Hold `n` (`nav_l`) | `g` | `f` | `d` | `s` | `r` | `e` | `w` | `q` |

- Keys a nav layer does not bind keep their `[main]` meaning, so the mods on
  the hand holding the layer key still stack: `v + d + h` = `Shift+Left`,
  `n + k + g` = `Shift+Left`, `v + a + l` = `Super+Right`.
- Ctrl is the exception: `f` shares a finger with `v` and `j` with `n`, so
  `Ctrl+arrow` needs the real Ctrl key.
- `nav_l` is a true mirror, so Left/Right and Home/End are spatially
  reversed on the left hand (`g` = Left, `s` = Right).

### Number and symbol layers (held `c` / `x`)

Hold `c` or `x` with the left hand and the right hand becomes a numpad or a
symbol block. Tapping `c` / `x` types the letter (same `lettermod` timing as
the home row). Adding `d` while `x` is held switches to the second symbol
tier.

| Key → | `y` | `u` | `i` | `o` | `p` | `h` | `j` | `k` | `l` | `;` | `n` | `m` | `,` | `.` | `/` |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Hold `c` (`num_r`) | `*` | `7` | `8` | `9` | `+` | `.` | `4` | `5` | `6` | `-` | `0` | `1` | `2` | `3` | `/` |
| Hold `x` (`sym_r`) | `~` | `_` | `{` | `}` | `$` | `=` | `(` | `)` | `"` | `:` | `#` | `-` | `,` | `.` | `/` |
| Hold `x + d` | `` ` `` | `^` | `[` | `]` | `%` | `+` | `&` | `*` | `'` | `!` | `\|` | `\` | `<` | `>` | `?` |

- `num_r` emits plain digits, so the left hand's mods stack: `c + a + m` =
  `Super+1` (workspace 1), `c + s + j` = `Alt+4` (kitty tab 4). `c` sits under
  the Shift finger, so there is no Shift in `num_r`.
- `sym_r` leaves `, . /` as themselves, so `",` `),` `):` and `~/` are typed
  without releasing `x`. The second tier is the partner of the first:
  `{ }` → `[ ]`, `=` → `+`, `"` → `'`, `~` → `` ` ``, `_` → `^`.
- A layer key struck within 150 ms of a letter is always the letter: pause
  before `x` for a mid-word `(` or `_`.
- Holding `x` or `c` for key-repeat no longer works (vim `x`: use a count).
- `@` and `;` are not on the symbol layer: number row and a plain tap.

## Custom bindings

### Leader chord (`ctrl+space > …`)

Defined in `kittens/which_key_spec.py`. The popup appears ~200ms after the
keypress (known keys typed within that window fire with no popup) and is
cancellable with `Esc` or `Backspace`. Its rows are grouped under headers —
Windows, Navigate, Tabs, Go to tab, Sessions, Tools — set by each entry's
`"section"` label in the spec (display only; the keystroke is still
`ctrl+space > key`). Tunable: `BUDGET_S` in `kittens/which_key_timing.py`;
the floor is the kitten's own spawn (~180ms).

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
| `ctrl+space > 1` … `9` | Go to tab N (tab titles are prefixed `N:`) |
| `ctrl+space > 0` | Go to last-visited tab (toggle between two tabs) |
| `ctrl+space > /` | Scrollback in nvim (kitty-scrollback.nvim) |
| `ctrl+space > [` | Copy mode: scrollback + screen in nvim, hybrid line numbers (`copy-mode.sh`) |
| `ctrl+space > ?` (`shift+/`) | Command palette |
| `ctrl+space > s` | Fuzzy session picker (fzf across all OS windows) |
| `ctrl+space > S` | Save current OS window as a named session (ksession) |
| `ctrl+space > f` | Fuzzy tab/split picker (fzf inside current OS window) |
| `ctrl+space > v` | View this window's saved scrollback (ksession `.ansi` dump) in `less` |
| `ctrl+space > o` | Load a project's session into the current kitty |

tmux equivalents of `s` / `S` / `f`, backed by `ksession tmux …` (needs
`make install` in `~/.config/kitty/scripts/ksession-rs` so
`~/.local/bin/ksession` has the `tmux` subcommand): `C-a s` session picker
(running + saved sessions; Enter switches/restores, `d` in normal mode
kills/removes after y/N and is refused on the current session), `C-a S`
save prompt, `C-a f` pane picker. Same modal keys as the kitty pickers
(type to filter; Esc → normal: `j`/`k`, `g`/`G`, `ctrl-d`/`ctrl-u`, `d`,
`i`, `q`/Esc). Bound and documented in `~/.config/tmux/tmux.conf`; full
key table in `scripts/ksession-rs/README.md` ("tmux session manager").

Pausing ~0.4 s after `C-a` (or `C-a Space`) opens a which-key panel for
tmux that mirrors the kitty kitten: a borderless popup across the bottom
of the whole window (`scripts/whichkey.sh`, no plugin) listing every
`C-a` key at once under Panes / Navigate / Windows / Sessions / Tools
headers packed into columns. Any key fires immediately (replayed as the
real binding); fast chords never show the panel. `r` descends into a
transient resize panel (`h`/`j`/`k`/`l` repeat, `BSpace` back); Esc/`q` close.

### Direct bindings — window navigation & splits

Bare `ctrl+h/j/k/l` is intentionally **not** bound: those keys reach zsh
(`ctrl+l` clear, `ctrl+k` kill-line), fzf (`ctrl+j/k`) and nvim unchanged.
Pane focus lives on the Alt layer (held `s` / `l`) and the leader.

| Key | Action |
|---|---|
| `ctrl+shift+h` / `j` / `k` / `l` | Swap window left/down/up/right |
| `ctrl+shift+\` (i.e. `ctrl+\|`) | Vertical split |
| `ctrl+shift+-` | Horizontal split |
| `ctrl+shift+w` | Close window |
| `ctrl+shift+r` | Rotate split orientation |
| `ctrl+shift+z` | Toggle stack (zoom/unzoom) |

### Direct bindings — Alt layer (held `s` / `l` via keyd)

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

### Copy mode (`scripts/copy-mode.sh`)

tmux-style: the window's scrollback + screen open in nvim on the same rows,
cursor on the terminal's cursor, hybrid line numbers in the gutter. Your
whole nvim config applies; the tabline and statusline stay and cover a row
each. Nothing is sent back to the window.

| Key | Action |
|---|---|
| `ctrl+shift+f3` / `ctrl+space > [` | Enter copy mode |
| `y…` (any yank to the clipboard) | Copy and leave; soft-wrapped rows are joined |
| `"ay…` (yank to a named register) | Yank and stay |
| `[[` / `]]` | Previous / next shell prompt |
| `q` / `Esc` (in Normal mode) | Leave |

The gutter takes columns the window used for text: rows wider than that
scroll sideways.

Images the window showed (kitty graphics protocol, e.g. `kitten icat`) are
shown too, each loaded when its rows are first drawn. This part relies on
kitty internals (`kittens/copy_mode_images.py`); if a kitty update breaks it,
the images are missing and the rest of copy mode is unaffected.

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
- **`copy-mode.sh`** + **`copy-mode.lua`** — bound to `ctrl+shift+f3` and
  `ctrl+space > [`. kitty's `launch --stdin-source=@screen_scrollback
  --stdin-add-formatting --stdin-add-line-wrap-markers` pipes the window's
  rows to the script; it moves them to fd 3 and starts nvim, which sources
  `copy-mode.lua` to put them in a read-only buffer, colouring each row
  when it is first drawn. The text needs neither `jq`, `fzf` nor remote
  control. Images are not in what kitty pipes: nvim asks kitty for them with
  `kitten @ kitten kittens/copy_mode_images.py` (remote control), which
  writes their pixels to `/dev/shm` for nvim to hand to the overlay window.

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

- **`hjkl` is always a direction; the held mod is the scope** (keyd):
  `a+hjkl` (Super) = COSMIC window, `s+hjkl` (Alt) = kitty split. Add `d`
  (Shift) to either to *move* instead of *focus*.
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
