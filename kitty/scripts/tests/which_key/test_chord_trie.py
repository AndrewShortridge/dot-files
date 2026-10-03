#!/usr/bin/env python3
# Fixture-table unit tests for the pure chord-trie module (issue 02).
# Covers the 7th AC + PRD testing decisions: build shape, navigate
# hit/partial/miss, declared-order preservation, group flagging, malformed
# skip. Asserts only via the public interface (build/navigate/entries) — never
# pokes Node internals. Stdlib unittest, no terminal / socket / real-time wait,
# so it runs under both miniconda python3 and kitty's bundled python.
import os
import sys
import unittest

# repo root on sys.path so `from kittens.chord_trie import ...` works.
sys.path.insert(
    0, os.path.join(os.path.dirname(__file__), "..", "..", "..")
)

from kittens.chord_trie import (  # noqa: E402
    build, navigate, entries, sections, Leaf, Prefix, NO_MATCH,
)

# A small fixture spec exercising leaves, one real nested group, and a
# deliberately non-alphabetical declared order ("c" before "bar" before the
# group) to prove order is preserved verbatim.
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

# (key, expected kind, expected payload) — payload is the action for leaves.
NAV_CASES = [
    ("c",     "leaf",    "close_window"),
    ("bar",   "leaf",    "launch --location=vsplit --cwd=current"),
    ("minus", "leaf",    "launch --location=hsplit --cwd=current"),
    ("w",     "prefix",  None),
    ("z",     "nomatch", None),
    ("",      "nomatch", None),
]


class ChordTrieBuild(unittest.TestCase):
    def test_entries_shape(self):
        # entries() returns the expected (key, desc, is_group) rows.
        root = build(FIXTURE_SPEC)
        self.assertEqual(
            entries(root),
            [
                ("c",     "close window",     False),
                ("bar",   "split vertical",   False),
                ("minus", "split horizontal", False),
                ("w",     "window",           True),
            ],
        )

    def test_nested_group_builds(self):
        # Navigate into the group, then list its children's entries.
        root = build(FIXTURE_SPEC)
        result = navigate(root, "w")
        self.assertIsInstance(result, Prefix)
        self.assertEqual(
            entries(result.node),
            [
                ("h", "focus left", False),
                ("j", "focus down", False),
                ("k", "focus up",   False),
            ],
        )

    def test_declared_order_preserved(self):
        # entries() preserves the authored (non-alphabetical) order verbatim;
        # it does NOT sort groups-last (that is the layout module, issue 06).
        root = build(FIXTURE_SPEC)
        self.assertEqual(
            [k for k, _, _ in entries(root)],
            ["c", "bar", "minus", "w"],
        )

    def test_group_flagging(self):
        root = build(FIXTURE_SPEC)
        rows = {k: (desc, is_group) for k, desc, is_group in entries(root)}
        # Group row: is_group True, desc is the group label.
        self.assertEqual(rows["w"], ("window", True))
        # Leaf rows: is_group False.
        self.assertFalse(rows["c"][1])
        self.assertFalse(rows["bar"][1])


class ChordTrieNavigate(unittest.TestCase):
    def test_navigate_table(self):
        root = build(FIXTURE_SPEC)
        for key, kind, payload in NAV_CASES:
            with self.subTest(key=key):
                result = navigate(root, key)
                if kind == "leaf":
                    self.assertIsInstance(result, Leaf)
                    self.assertEqual(result.action, payload)
                elif kind == "prefix":
                    self.assertIsInstance(result, Prefix)
                elif kind == "nomatch":
                    self.assertIs(result, NO_MATCH)
                else:  # pragma: no cover - guards a bad fixture row
                    self.fail("unknown kind %r" % kind)

    def test_navigate_into_prefix_reaches_leaf(self):
        # Partial match -> Prefix; one more step -> Leaf.
        root = build(FIXTURE_SPEC)
        prefix = navigate(root, "w")
        self.assertIsInstance(prefix, Prefix)
        leaf = navigate(prefix.node, "h")
        self.assertIsInstance(leaf, Leaf)
        self.assertEqual(leaf.action, "neighboring_window left")
        # Miss inside the group.
        self.assertIs(navigate(prefix.node, "z"), NO_MATCH)


class ChordTrieMalformed(unittest.TestCase):
    # Story 21 / AC 6: a malformed entry is skipped at build time without
    # aborting the whole trie. Good entries survive, bad ones are absent,
    # build never raises, and each skip is recorded on root.warnings.
    MALFORMED_SPEC = [
        {"key": "a", "action": "act_a", "desc": "good a"},   # good leaf
        "not-a-dict",                                         # bad: not a dict
        {"action": "no_key", "desc": "missing key"},         # bad: no key
        {"key": "x", "desc": "neither leaf nor prefix"},     # bad: no action/children
        {"key": "y", "action": "", "desc": "empty action"},  # bad: empty action
        {"key": "g", "group": "empty group", "children": []},  # bad: no usable children
        {"key": "b", "action": "act_b", "desc": "good b"},   # good leaf
        {"key": "p", "group": "ok group", "children": [      # good prefix
            {"key": "1", "action": "act_p1", "desc": "p one"},
        ]},
    ]

    def test_build_does_not_raise_and_keeps_good_entries(self):
        root = build(self.MALFORMED_SPEC)  # must not raise
        keys = [k for k, _, _ in entries(root)]
        # Good entries present, in declared order.
        self.assertEqual(keys, ["a", "b", "p"])

    def test_malformed_entries_absent(self):
        root = build(self.MALFORMED_SPEC)
        self.assertIs(navigate(root, "x"), NO_MATCH)  # neither leaf nor prefix
        self.assertIs(navigate(root, "y"), NO_MATCH)  # empty action
        self.assertIs(navigate(root, "g"), NO_MATCH)  # empty group
        # Good ones still navigable.
        self.assertIsInstance(navigate(root, "a"), Leaf)
        self.assertIsInstance(navigate(root, "p"), Prefix)

    def test_warnings_recorded(self):
        root = build(self.MALFORMED_SPEC)
        # One warning per skipped entry: not-a-dict, missing key, no
        # action/children, empty action, empty group = 5.
        self.assertEqual(len(root.warnings), 5)


class ChordTrieSections(unittest.TestCase):
    # "section" is a display-only label. sections() groups entries() rows by
    # it: same label -> one section (even if declared apart), sections in order
    # of first appearance, rows in declared order, None for unsectioned rows.
    SECTIONED_SPEC = [
        {"key": "t", "action": "new_tab", "desc": "new tab", "section": "Tabs"},
        {"key": "c", "action": "close_window", "desc": "close",
         "section": "Windows"},
        {"key": "x", "action": "close_tab", "desc": "close tab",
         "section": "Tabs"},
        {"key": "q", "action": "quit", "desc": "quit"},            # unsectioned
        {"key": "w", "group": "window", "section": "Windows", "children": [
            {"key": "h", "action": "left", "desc": "left"},
        ]},
        {"key": "z", "action": "zz", "desc": "bad label", "section": 7},
        {"key": "e", "action": "ee", "desc": "empty label", "section": ""},
    ]

    def test_groups_by_label_in_first_appearance_order(self):
        root = build(self.SECTIONED_SPEC)
        self.assertEqual(root.warnings, [])
        self.assertEqual(
            sections(root),
            [
                ("Tabs", [("t", "new tab", False), ("x", "close tab", False)]),
                ("Windows", [("c", "close", False), ("w", "window", True)]),
                (None, [("q", "quit", False), ("z", "bad label", False),
                        ("e", "empty label", False)]),
            ],
        )

    def test_section_never_changes_navigation(self):
        # Labels are display-only: every key is still a direct child of root.
        root = build(self.SECTIONED_SPEC)
        self.assertEqual(
            [k for k, _, _ in entries(root)],
            ["t", "c", "x", "q", "w", "z", "e"],
        )
        self.assertIsInstance(navigate(root, "t"), Leaf)
        self.assertIsInstance(navigate(root, "w"), Prefix)
        self.assertIs(navigate(root, "Tabs"), NO_MATCH)

    def test_unsectioned_spec_is_one_headerless_section(self):
        root = build(FIXTURE_SPEC)
        self.assertEqual(sections(root), [(None, entries(root))])

    def test_children_sections_independent_of_parent(self):
        # A group's children carry their own (here absent) labels.
        root = build(self.SECTIONED_SPEC)
        w = navigate(root, "w")
        self.assertEqual(sections(w.node), [(None, [("h", "left", False)])])


if __name__ == "__main__":
    unittest.main()
