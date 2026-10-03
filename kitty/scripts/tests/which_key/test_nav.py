#!/usr/bin/env python3
# Fixture-table unit tests for the pure navigation + layout core (issue 03).
# Covers the STICKY nav reducer (nav_step: Descend/Dispatch/Pop/CANCEL/STAY,
# root-aware Backspace, stack purity) and the minimal single-column
# layout_block (groups-after-plain partition, declared-order preservation,
# aligned key column), plus the char_to_key / display_key maps.
#
# Asserts only via the public interface of which_key_nav + chord_trie. Stdlib
# unittest, no terminal / socket / real-time wait, so it runs under both
# miniconda python3 and kitty's bundled python.
import os
import sys
import unittest

# repo root on sys.path so `from kittens.* import ...` works.
sys.path.insert(
    0, os.path.join(os.path.dirname(__file__), "..", "..", "..")
)

from kittens.chord_trie import build, navigate, entries, Prefix  # noqa: E402
from kittens.which_key_nav import (  # noqa: E402
    nav_step, layout_block, char_to_key, display_key,
    Descend, Dispatch, Pop, CANCEL, STAY, KEY_ESC, KEY_BACKSPACE,
)

# A small fixture spec: leaves + one nested group with second-level leaves,
# in a deliberately non-alphabetical order to prove order is preserved.
FIXTURE_SPEC = [
    {"key": "c",     "action": "close_window", "desc": "close window"},
    {"key": "bar",   "action": "launch --location=vsplit --cwd=current",
     "desc": "split vertical"},
    {"key": "minus", "action": "launch --location=hsplit --cwd=current",
     "desc": "split horizontal"},
    {"key": "w", "group": "window", "children": [
        {"key": "h", "action": "neighboring_window left", "desc": "focus left"},
        {"key": "j", "action": "neighboring_window down", "desc": "focus down"},
        {"key": "k", "action": "neighboring_window up",   "desc": "focus up"},
    ]},
]


def _root_stack():
    return [build(FIXTURE_SPEC)]


def _group_stack():
    # [root, w] — descended one level into the "window" group.
    root = build(FIXTURE_SPEC)
    result = navigate(root, "w")
    assert isinstance(result, Prefix)
    return [root, result.node]


class NavStep(unittest.TestCase):
    def test_root_leaf_dispatches(self):
        # Leaf key at root -> Dispatch with the action string (close popup).
        cases = [
            ("c",     "close_window"),
            ("bar",   "launch --location=vsplit --cwd=current"),
            ("minus", "launch --location=hsplit --cwd=current"),
        ]
        for key, action in cases:
            with self.subTest(key=key):
                result = nav_step(_root_stack(), key)
                self.assertIsInstance(result, Dispatch)
                self.assertEqual(result.action, action)

    def test_root_group_descends(self):
        # Group key at root -> Descend; the node exposes the sub-entries.
        result = nav_step(_root_stack(), "w")
        self.assertIsInstance(result, Descend)
        self.assertEqual(
            [k for k, _, _ in entries(result.node)], ["h", "j", "k"]
        )

    def test_root_unbound_stays(self):
        self.assertIs(nav_step(_root_stack(), "z"), STAY)

    def test_root_esc_cancels(self):
        self.assertIs(nav_step(_root_stack(), KEY_ESC), CANCEL)

    def test_root_backspace_cancels(self):
        self.assertIs(nav_step(_root_stack(), KEY_BACKSPACE), CANCEL)

    def test_group_backspace_pops_to_root(self):
        stack = _group_stack()
        result = nav_step(stack, KEY_BACKSPACE)
        self.assertIsInstance(result, Pop)
        self.assertIs(result.node, stack[0])  # parent is the root node

    def test_group_leaf_dispatches(self):
        result = nav_step(_group_stack(), "h")
        self.assertIsInstance(result, Dispatch)
        self.assertEqual(result.action, "neighboring_window left")

    def test_group_unbound_stays(self):
        self.assertIs(nav_step(_group_stack(), "z"), STAY)

    def test_group_esc_cancels(self):
        self.assertIs(nav_step(_group_stack(), KEY_ESC), CANCEL)

    def test_does_not_mutate_stack(self):
        # Purity: nav_step never mutates the passed stack, whatever the result.
        for stack_factory, key in [
            (_root_stack, "c"),       # Dispatch
            (_root_stack, "w"),       # Descend
            (_root_stack, "z"),       # STAY
            (_root_stack, KEY_ESC),   # CANCEL
            (_group_stack, KEY_BACKSPACE),  # Pop
        ]:
            with self.subTest(key=key):
                stack = stack_factory()
                before_len = len(stack)
                before_ids = [id(n) for n in stack]
                nav_step(stack, key)
                self.assertEqual(len(stack), before_len)
                self.assertEqual([id(n) for n in stack], before_ids)


class LayoutBlock(unittest.TestCase):
    def test_groups_sorted_after_plain_order_preserved(self):
        # entries() returns declared order (c, bar, minus, w); layout_block
        # keeps the three plain rows first in declared order, then the group.
        root = build(FIXTURE_SPEC)
        lines = layout_block(entries(root))
        keycells = [line.split("  ")[0].strip() for line in lines]
        self.assertEqual(keycells, ["c", "|", "-", "+w"])

    def test_groups_after_plain_with_interleaved_input(self):
        # A group declared BEFORE some plain rows must still land after them.
        interleaved = [
            ("w", "window", True),
            ("c", "close window", False),
            ("bar", "split vertical", False),
        ]
        lines = layout_block(interleaved)
        keycells = [line.split("  ")[0].strip() for line in lines]
        self.assertEqual(keycells, ["c", "|", "+w"])

    def test_key_column_aligned(self):
        # The separator must appear at the same index on every line (the key
        # column is left-padded to a common width).
        root = build(FIXTURE_SPEC)
        lines = layout_block(entries(root))
        sep_positions = {line.index("->") for line in lines}
        self.assertEqual(len(sep_positions), 1)

    def test_group_label_prefixed_and_named(self):
        root = build(FIXTURE_SPEC)
        lines = layout_block(entries(root))
        group_line = [ln for ln in lines if ln.strip().startswith("+w")][0]
        self.assertTrue(group_line.strip().startswith("+w"))
        self.assertTrue(group_line.rstrip().endswith("window"))

    def test_leaf_shows_description(self):
        root = build(FIXTURE_SPEC)
        lines = layout_block(entries(root))
        c_line = [ln for ln in lines if ln.startswith("c")][0]
        self.assertTrue(c_line.rstrip().endswith("close window"))

    def test_empty_entries(self):
        self.assertEqual(layout_block([]), [])


class DisplayKey(unittest.TestCase):
    def test_display_key_map(self):
        cases = [
            ("bar", "|"),
            ("minus", "-"),
            ("slash", "/"),
            ("shift+slash", "?"),
            ("c", "c"),
            ("shift+h", "H"),
            ("shift+s", "S"),
            ("shift+f3", "shift+f3"),   # no single glyph: verbatim
        ]
        for key_name, expected in cases:
            with self.subTest(key_name=key_name):
                self.assertEqual(display_key(key_name), expected)


class CharToKey(unittest.TestCase):
    def test_char_to_key_map(self):
        cases = [
            ("|", "bar"),
            ("-", "minus"),
            ("a", "a"),
            ("", ""),
            # Shifted glyphs (the on_text / no-keyboard-protocol path): a shifted
            # key arrives as its glyph, which must still name the shift+ chord.
            ("?", "shift+slash"),
            ("H", "shift+h"),
            ("S", "shift+s"),
            ("Z", "shift+z"),
        ]
        for ch, expected in cases:
            with self.subTest(ch=ch):
                self.assertEqual(char_to_key(ch), expected)


if __name__ == "__main__":
    unittest.main()
