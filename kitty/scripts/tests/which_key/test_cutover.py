#!/usr/bin/env python3
# Fixture-table unit tests for the issue-08 cutover. Two concerns:
#
#   1. resolve_key — the one new pure helper the cutover adds (which_key_nav).
#      It resolves a live key-event to a spec key name: first via an injected
#      matches_fn (the driver passes key_event.matches; here a fake), then via
#      the char_to_key glyph fallback. This is what lets the migrated spec's
#      shifted/named keys (shift+h, slash, shift+slash, ...) resolve, while
#      bar/minus keep going through the glyph map.
#
#   2. Spec integrity / conf parity — the migrated which_key_spec.SPEC must
#      build cleanly (no warnings) and every native ctrl+space>... chord from
#      the OLD kitty.conf must remain reachable and dispatch the EXACT same
#      action string. The 27-row CONF_CHORDS table below is the regression
#      guard for "matching today's behavior exactly" at the data level — it
#      catches a typo'd action or a dropped chord without needing a terminal.
#
# Asserts only via the public interface (resolve_key / char_to_key, build /
# navigate, Leaf). Stdlib unittest, no terminal / socket / real-time wait, so
# it runs under both miniconda python3 and kitty's bundled python.
import os
import sys
import unittest

# repo root on sys.path so `from kittens.* import ...` works.
sys.path.insert(
    0, os.path.join(os.path.dirname(__file__), "..", "..", "..")
)

from kittens.chord_trie import build, navigate, sections, Leaf  # noqa: E402
from kittens.which_key_nav import resolve_key  # noqa: E402
from kittens import which_key_spec as spec_mod  # noqa: E402


# A matches_fn fake: matches() is True only for the key names in `truthy`.
def _fake_matches(truthy):
    truthy = set(truthy)
    return lambda candidate: candidate in truthy


class ResolveKey(unittest.TestCase):
    def test_shifted_key_resolves_via_matches(self):
        # candidates declare shift+h; the event matches shift+h; text "H" is
        # irrelevant because matches wins first.
        got = resolve_key(["shift+h"], _fake_matches(["shift+h"]), "H")
        self.assertEqual(got, "shift+h")

    def test_named_keys_resolve_via_matches(self):
        cases = [
            (["slash"], "slash", "/"),
            (["shift+slash"], "shift+slash", "?"),
        ]
        for candidates, name, text in cases:
            with self.subTest(name=name):
                got = resolve_key(candidates, _fake_matches([name]), text)
                self.assertEqual(got, name)

    def test_glyph_fallback_when_no_candidate_matches(self):
        # No candidate matches -> char_to_key(text): | -> bar, - -> minus.
        all_false = _fake_matches([])
        self.assertEqual(resolve_key(["bar", "minus"], all_false, "|"), "bar")
        self.assertEqual(resolve_key(["bar", "minus"], all_false, "-"), "minus")

    def test_plain_letter_fallback(self):
        # A plain letter not surfaced by matches still resolves via the glyph
        # fallback (char_to_key returns it verbatim).
        got = resolve_key(["c"], _fake_matches([]), "c")
        self.assertEqual(got, "c")

    def test_no_resolution_returns_empty(self):
        # No match and no usable text -> "" (driver treats as STAY/no-op).
        self.assertEqual(resolve_key(["c"], _fake_matches([]), ""), "")
        self.assertEqual(resolve_key([], _fake_matches([]), ""), "")

    def test_first_declared_candidate_wins(self):
        # When matches_fn would be True for several candidates, the FIRST in
        # declared order is returned (drives `for candidate in candidates`).
        got = resolve_key(
            ["shift+h", "h"], _fake_matches(["shift+h", "h"]), "H"
        )
        self.assertEqual(got, "shift+h")

    def test_matches_precedes_glyph_fallback(self):
        # If a candidate matches, the glyph fallback is NOT consulted even when
        # text would map to a different key.
        got = resolve_key(["bar"], _fake_matches(["bar"]), "-")
        self.assertEqual(got, "bar")

    def test_bad_candidate_name_is_skipped(self):
        # A matches_fn that raises on one candidate must not abort resolution.
        def matches(candidate):
            if candidate == "boom":
                raise ValueError("bad key name")
            return candidate == "c"
        got = resolve_key(["boom", "c"], matches, "c")
        self.assertEqual(got, "c")


# The 26 native ctrl+space>... chords from the OLD kitty.conf, plus
# ctrl+space>l (focus right), which the old conf never defined and was added
# after cutover so the leader nav set matches bare ctrl+hjkl, as
# (key_path, expected_action). key_path is the sequence of spec key names to
# walk from the root (flat migration -> every path is a single key). The
# scrollback action is the EXPANDED kitten form (NOT the kitty_scrollback_nvim
# alias) — kitty @ action does not expand action_alias.
_SCROLLBACK = (
    "kitten "
    "/home/andrew/.local/share/nvim/lazy/kitty-scrollback.nvim/"
    "python/kitty_scrollback_nvim.py"
)

CONF_CHORDS = [
    (["bar"],   "launch --location=vsplit --cwd=current"),
    (["minus"], "launch --location=hsplit --cwd=current"),
    (["c"],     "close_window"),
    (["h"],     "neighboring_window left"),
    (["j"],     "neighboring_window down"),
    (["k"],     "neighboring_window up"),
    (["l"],     "neighboring_window right"),
    (["shift+h"], "move_window left"),
    (["shift+j"], "move_window down"),
    (["shift+k"], "move_window up"),
    (["shift+l"], "move_window right"),
    (["m"], "toggle_layout stack"),
    (["w"], "focus_visible_window"),  # added post-cutover (pane picker)
    (["r"], "start_resizing_window"),
    (["t"], "new_tab_with_cwd"),
    (["x"], "close_tab"),
    (["n"], "next_tab"),
    (["p"], "previous_tab"),
    (["shift+n"], "move_tab_forward"),
    (["shift+p"], "move_tab_backward"),
    (["shift+r"], "set_tab_title"),
    (["1"], "goto_tab 1"),  # added post-cutover (numbered tabs)
    (["2"], "goto_tab 2"),
    (["3"], "goto_tab 3"),
    (["4"], "goto_tab 4"),
    (["5"], "goto_tab 5"),
    (["6"], "goto_tab 6"),
    (["7"], "goto_tab 7"),
    (["8"], "goto_tab 8"),
    (["9"], "goto_tab 9"),
    (["0"], "goto_tab -1"),
    (["slash"], _SCROLLBACK),
    (["shift+slash"], "command_palette"),
    (["s"], "launch --type=overlay --cwd=current "
            "/home/andrew/.config/kitty/scripts/session-picker.sh"),
    (["shift+s"], "launch --type=overlay --cwd=current "
                  "/home/andrew/.config/kitty/scripts/ksession-save-prompt.sh"),
    (["f"], "launch --type=overlay --cwd=current "
            "/home/andrew/.config/kitty/scripts/tab-picker.sh"),
    (["v"], "launch --type=overlay --cwd=current "
            "/home/andrew/.config/kitty/scripts/scrollback-viewer.sh"),
    (["o"], "launch --type=overlay --cwd=current "
            "/home/andrew/.config/kitty/scripts/project-loader.sh"),
]


class SpecIntegrity(unittest.TestCase):
    def test_build_has_no_warnings(self):
        # A well-formed migrated spec builds with zero skipped entries.
        root = build(spec_mod.SPEC)
        self.assertEqual(root.warnings, [])

    def test_all_conf_chords_present(self):
        # Guard against silently dropping (or adding) a chord: the 27 migrated
        # chords plus `w` (pane picker) and `1`-`9`/`0` (numbered tabs), both
        # added after the cutover.
        self.assertEqual(len(CONF_CHORDS), 38)
        self.assertEqual(len(spec_mod.SPEC), 38)

    def test_every_conf_chord_dispatches_exact_action(self):
        # Walk the trie per key in each path; the terminal node must be a Leaf
        # whose action equals the OLD conf action string exactly.
        root = build(spec_mod.SPEC)
        for key_path, expected in CONF_CHORDS:
            with self.subTest(chord=">".join(key_path)):
                node = root
                result = None
                for key in key_path:
                    result = navigate(node, key)
                    if hasattr(result, "node"):
                        node = result.node
                self.assertIsInstance(
                    result, Leaf,
                    "chord %r did not resolve to a leaf" % ">".join(key_path),
                )
                self.assertEqual(result.action, expected)

    def test_scrollback_stores_expanded_alias_not_the_alias_name(self):
        # Finding #2 as a test: the slash chord must NOT store the
        # kitty_scrollback_nvim action_alias (kitty @ action won't expand it).
        root = build(spec_mod.SPEC)
        result = navigate(root, "slash")
        self.assertIsInstance(result, Leaf)
        self.assertTrue(result.action.startswith("kitten "))
        self.assertNotIn("kitty_scrollback_nvim ", result.action + " ")
        self.assertEqual(result.action, _SCROLLBACK)

    def test_spec_is_flat_no_groups(self):
        # The faithful migration is flat: every native chord is a top-level
        # leaf, so navigate(root, key) yields a Leaf for every spec key (never
        # a Prefix). This encodes the "matching today's keystrokes exactly"
        # decision — no synthetic w/t group that would change keystrokes.
        # Popup grouping is the display-only "section" label instead.
        root = build(spec_mod.SPEC)
        for key in root.order:
            with self.subTest(key=key):
                self.assertIsInstance(navigate(root, key), Leaf)

    def test_every_chord_has_a_popup_section(self):
        # Every row renders under a header: no unsectioned (None) run, and
        # the headers come out in the declared reading order.
        secs = sections(build(spec_mod.SPEC))
        self.assertEqual(
            [label for label, _ in secs],
            ["Windows", "Navigate", "Tabs", "Go to tab", "Sessions", "Tools"],
        )
        self.assertEqual(sum(len(rows) for _, rows in secs), len(CONF_CHORDS))
        # The numbered-tab rows live together so filter_tab_entries trims one
        # section, never leaving a header over an empty block.
        goto = dict(secs)["Go to tab"]
        self.assertEqual([k for k, _, _ in goto], list("1234567890"))


if __name__ == "__main__":
    unittest.main()
