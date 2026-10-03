Run: `bash scripts/tests/which_key/run.sh` from the repo root (or execute the
script directly; `pytest scripts/tests/which_key` also works). This is the
repo's first Python test suite — `test_chord_trie.py` is a fixture-table
unittest (one `subTest` per row, in the spirit of `modal_fsm/transitions.tsv`)
covering the pure chord-trie module (`kittens/chord_trie.py`): `build()` shape
via `entries()`, `navigate()` hit/partial/miss, declared-order preservation,
sub-prefix group flagging, malformed-entry skip (build never aborts; each
skip is recorded on `root.warnings`), and `sections()` — `entries()` rows
grouped by the display-only `"section"` label (same label merges, first-
appearance order, `None` for unsectioned, never affects `navigate()`). Only
the pure, kitty-free core is
automated here; the overlay launch, raw-tty key read in `main()`, and
`boss.call_remote_control` dispatch are terminal-interactive and verified
manually (press the scratch trigger, then `|`/`-`/`c`/`w h`).

`test_nav.py` covers the pure STICKY navigation reducer (`nav_step`:
Descend/Dispatch/Pop/CANCEL/STAY, root-aware Backspace, stack purity) and the
minimal single-column `layout_block` (groups-after-plain, declared order
preserved, aligned key column) plus the `char_to_key`/`display_key` maps for
issue 03. The overlay render/anchor, raw key reads, and `kitty @ action`
dispatch remain terminal-interactive and are verified manually: trigger
`ctrl+shift+f3`, then descend `w`->`h`, `w`->Backspace->`c`, an unbound key
like `z` (ignored), and Esc.

`test_timing.py` covers the pure WAIT_FIRST->STICKY timing core
(`which_key_timing.run`) under a fake clock — the 100ms deadline is modeled as
an explicit `("deadline",)` event in a scripted key stream, so there is no
real-time wait. It asserts: the fast path (a key before the deadline runs
`nav_step` with NO `SHOW`, so the popup is never drawn — leaf dispatch and a
fast `w`->`h` descend both stay invisible), deadline->`SHOW`->STICKY,
descend-after-show with no second delay (exactly one `SHOW`), a stray
`("deadline",)` in STICKY being a no-op, Esc/Backspace/no-match delegation to
`nav_step` after `SHOW`, the deadline applying only to level 1, the injectable
clock helpers (`is_expired`/`deadline_at`, `DELAY_S == 0.100`), and
`remaining_delay` (the live driver's `BUDGET_S` is measured from the kitten's
process start, so spawn time counts against it and the result is never
negative), and `run()` stack purity. The real timer deferral feel, the overlay
render/anchor, raw-tty key reads, and `kitty @ action` dispatch remain manual:
press `ctrl+space` and type a known key fast (within ~200ms of the leader) for
no popup flash vs. wait longer for the popup, then descend with no second delay.

`test_cache.py` covers the mtime-keyed trie cache (`which_key_cache.
load_or_build` + `cache_dir`/`cache_path`): an mtime hit returns the cached trie
WITHOUT rebuilding (asserted via an injected build-spy call count), an mtime
change rebuilds and rewrites the on-disk envelope (assert the rewritten
`payload["mtime"]`), and a corrupt or unreadable cache falls back to a fresh
parse without raising (then repairs the file so the next call hits). It also
covers first-run build, a rewrite failure still returning a valid trie, an
unstattable spec path skipping the cache, and `cache_dir` resolving under
`$XDG_CACHE_HOME/which_key` or `~/.cache/which_key`. All under temp dirs with
synthetic `os.utime` mtimes and an injected `build_fn`/`cache_file` — no
terminal, socket, or real-time wait, and Node internals are never poked
(correctness asserted via `entries()`/`navigate()`). The cache feeds the live
cold start in `which_key.py` (`_TRIE = load_or_build(_spec_mod.__file__,
_spec_mod.SPEC, build)`), which remains terminal-interactive and is verified
manually: delete `~/.cache/which_key/which_key_trie.pickle`, trigger the leader
twice, and confirm the file appears and is reused.

`test_layout.py` covers the pure popup grid layout (`which_key_layout.
layout(entries, term_width) -> lines`, issue 06): column widths via a
stdlib-`unicodedata` display width (`char_width`/`str_width`) that is
wcwidth-equivalent for the relevant cases yet needs NO third-party dep
(asserted by literal expected columns — abc/CJK/fullwidth/combining/`→` — never
importing the `wcwidth` package, since kitty's bundled python lacks it);
width-aware `truncate` with a trailing `…` that never half-emits a wide glyph;
the groups-after-plain stable `sort_entries`; and the public `layout`'s
column-first multi-column packing & thresholds (`box_count = max(1,
(width+SPACING)//(box_width+SPACING))`, `height = ceil(n/box_count)`, fill
`col=i//height, row=i%height`, asserting the exact 1->2 column threshold),
separator alignment by DISPLAY width (incl. a wide `你` key cell — proving
width-aware padding, not `str.ljust`), `+group` rows sorted last even when
packed across columns, declared-order preservation, and narrow-terminal
truncation (no line exceeds the terminal; at the extreme floor the separator +
descriptions drop to a key-only column). All pure — stdlib `unittest`, no
terminal/socket/real-time wait, runs under both miniconda 3.13 and kitty's
bundled 3.14. `layout_sections(sections, term_width, key_sgr, header_sgr)` is
the headed variant the driver uses: each labeled section is a header line plus
its rows, never split across columns (height grows to the tallest section), a
blank line separates sections stacked in one column, unlabeled rows flow
column-first, and each column is only as wide as its own rows/header. The
tests pin `layout(e, w) == layout_sections([(None, e)], w)` at many widths, the
no-split rule at the exact two-box width, gutter continuity past short
columns, per-column widths, header truncation on narrow terminals, and that
`header_sgr` wraps labels only and is width-neutral. The overlay render/anchor
(`WhichKeyDriver.draw()` calls `layout_sections(sections(node), ...)` after
`filter_tab_entries` per section) stays terminal-interactive and is verified
manually: trigger `ctrl+shift+f3`, descend into a crowded prefix to see
multi-column packing, then shrink the window to watch descriptions truncate with
`…` rather than wrap.

`test_robustness.py` covers the issue-07 hardening contract across the existing
pure modules plus the new spawn-window / soft-bell logic. It asserts, all via
the public interface (`build`/`navigate`/`entries`, `load_or_build`,
`buffered_key_decision`) and never by poking Node fields: (1) a spec
interleaving good entries with every malformed shape (not-a-dict, missing/empty
`key`, neither-leaf-nor-prefix, empty `action`, an all-bad-children prefix, a
bad child inside a good group) still `build()`s without raising, and EVERY good
entry — including a nested group declared *after* a malformed entry — stays
reachable and dispatchable while the bad keys are `NO_MATCH` and the all-bad
prefix is absent; (2) a corrupt and an unreadable cache each fall back to a
fresh parse through the REAL kitten components — the live `which_key_spec.SPEC`
+ `chord_trie.build` via `load_or_build` (the same wiring as the module-scope
`_TRIE = load_or_build(...)`) — never raising, then repairing the file so the
next call hits; (3) the mandated pure `buffered_key_decision(stack, key) ->
(HONOR|DROP, result)` table — a bound leaf/prefix and Esc/Backspace are
honored (Dispatch/Descend/CANCEL/Pop), an unbound key is dropped rather than
mis-dispatched, and the call never mutates the stack; (4) the `SOFT_BELL`/`BEL`
policy constants. The terminal-dependent halves are verified manually:
- malformed spec: temporarily insert a bad entry (e.g. `{"key": "zz"}`) in
  `which_key_spec.py`, trigger `ctrl+shift+f3`, and confirm the rest of the
  popup still works (the bad key just isn't bound);
- corrupt cache: `printf 'garbage' > ~/.cache/which_key/which_key_trie.pickle`,
  trigger the leader, confirm it still works and the file is repaired;
- spawn-window key: trigger the leader and *immediately* type a fast second
  chord key, confirming it is honored (or cleanly dropped) and never
  mis-dispatched into the wrong action;
- soft bell: with the popup open, press an unbound key like `z` and confirm a
  soft bell rings while the popup stays open.

`test_cutover.py` covers the issue-08 cutover (rebinding `ctrl+space` to the
kitten and retiring the native `ctrl+space>…` chords). Two pure concerns:
(1) `resolve_key(candidates, matches_fn, text)` — the one new helper, which
resolves a live key-event to a spec key name by trying `matches_fn(candidate)`
in declared order first (handles `shift+h`, `slash`, `shift+slash`, plain
letters), then falling back to `char_to_key(text)` (`|`→`bar`, `-`→`minus`);
the table asserts shifted/named resolution, the glyph fallback, plain-letter
fallback, the empty/no-resolution case, first-declared-candidate precedence,
matches-before-glyph precedence, and that a raising `matches_fn` candidate is
skipped (the driver injects `key_event.matches`; tests inject a fake).
(2) Spec integrity / conf parity — `build(which_key_spec.SPEC)` produces no
warnings, the migration is the expected size (26 entries), and a 26-row
`CONF_CHORDS` fixture table — every native `ctrl+space>…` chord from the old
kitty.conf as `(key_path, expected_action)` — walks the trie via `navigate()`
and asserts the terminal `Leaf.action` equals the OLD action string exactly
(the data-level regression guard for "matching today's behavior exactly").
A dedicated case asserts the `slash` chord stores the **expanded** `kitten …`
scrollback invocation, NOT the `kitty_scrollback_nvim` action_alias (which
`kitty @ action` would not expand), and another asserts the migration is FLAT
(every key a top-level leaf — no synthetic group that would change keystrokes).
The live rebind, overlay launch, raw-tty key reads, and `kitty @ action`
dispatch are terminal-interactive / HITL — a human must trigger `ctrl+space`
and confirm every chord still fires: splits `|`/`-`, close `c`, focus
`h`/`j`/`k`, swaps `H`/`J`/`K`/`L`, maximize `m`, resize `r`, tabs
`t`/`x`/`n`/`p`/`N`/`P`/`R`, scrollback `/`, palette `?`, pickers
`s`/`S`/`f`/`v`/`o`; plus the fast-path no-flash (type a known key within
~200ms of the leader), the sticky popup after a longer pause, and Esc /
Backspace to cancel.
