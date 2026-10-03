#!/usr/bin/env python3
# Fixture-table unit tests for the issue-07 robustness contract.
#
# Consolidates the four degradation cases the kitten must survive, automating
# every pure/testable part and pinning the policy constants:
#   1. MalformedSpecPartialTrie - a spec mixing good + several malformed entries
#      still builds, and EVERY good entry stays reachable/dispatchable (the
#      end-to-end framing of issue 02's build-level skip: "the rest of the trie
#      remains usable").
#   2. CorruptCacheKittenPath - a corrupt / unreadable cache falls back to a
#      fresh parse through the REAL kitten components (the live SPEC + the real
#      chord_trie.build via load_or_build), never raising.
#   3. BufferedKeyDecision - the mandated pure unit test of the spawn-window
#      buffered_key_decision(stack, key) -> (HONOR|DROP, result) reducer.
#   4. SoftBellPolicy - pins the SOFT_BELL / BEL policy constants.
#
# Stdlib unittest only; no terminal, socket, or real-time wait — runs under both
# miniconda python3 and kitty's bundled python. The terminal-dependent halves
# (the overlay drain through the real Loop, and the audible bell) are verified
# manually per the README.
import os
import pickle
import sys
import tempfile
import unittest

# repo root on sys.path so `from kittens.* import ...` works.
sys.path.insert(
    0, os.path.join(os.path.dirname(__file__), "..", "..", "..")
)

from kittens.chord_trie import (  # noqa: E402
    build, navigate, entries, Prefix, Leaf, NO_MATCH,
)
from kittens.which_key_cache import (  # noqa: E402
    load_or_build, DEFAULT_CACHE_NAME,
)
from kittens.which_key_spec import SPEC as LIVE_SPEC  # noqa: E402
from kittens.which_key_nav import (  # noqa: E402
    nav_step, buffered_key_decision,
    HONOR, DROP, SOFT_BELL, BEL,
    Descend, Dispatch, Pop, CANCEL, STAY, KEY_ESC, KEY_BACKSPACE,
)


# A spec that interleaves several GOOD entries with several MALFORMED ones of
# every shape build() recognizes, plus a nested group whose own children mix
# good + bad, and a prefix whose children are ALL bad (so the prefix itself is
# dropped). The good entries are deliberately positioned AFTER bad ones to prove
# a skip never aborts the rest of the build.
MALFORMED_SPEC = [
    "not-a-dict",                                  # bad: entry not a dict
    {"action": "orphan", "desc": "no key"},        # bad: missing 'key'
    {"key": "", "action": "empty_key"},            # bad: empty 'key'
    {"key": "c", "action": "close_window", "desc": "close window"},  # GOOD leaf
    {"key": "x"},                                  # bad: neither leaf nor prefix
    {"key": "e", "action": "", "desc": "empty"},   # bad: empty 'action'
    {"key": "bar", "action": "vsplit", "desc": "split"},  # GOOD leaf (after bad)
    {"key": "dead", "group": "dead", "children": [        # bad: all-bad children
        "not-a-dict",
        {"key": "q"},                              # neither leaf nor prefix
    ]},
    {"key": "w", "group": "window", "children": [  # GOOD nested prefix
        {"key": "h", "action": "neighboring_window left", "desc": "left"},
        {"key": "z"},                              # bad child, sibling survives
        {"key": "j", "action": "neighboring_window down", "desc": "down"},
    ]},
]


# Same fixture shape as test_nav.py, reused for the buffered-key decision table.
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


class MalformedSpecPartialTrie(unittest.TestCase):
    """AC 1 (end-to-end): a malformed/partial entry is skipped while the rest of
    the trie still builds and remains usable — asserted via navigate()/entries(),
    never by poking Node fields."""

    def test_build_does_not_raise(self):
        # The whole point: one (or many) bad entries must not abort the build.
        build(MALFORMED_SPEC)  # must not raise

    def test_good_entries_all_reachable(self):
        root = build(MALFORMED_SPEC)
        # Every GOOD top-level leaf still dispatches.
        for key, action in [("c", "close_window"), ("bar", "vsplit")]:
            with self.subTest(key=key):
                result = navigate(root, key)
                self.assertIsInstance(result, Leaf)
                self.assertEqual(result.action, action)

    def test_good_nested_prefix_after_malformed_still_navigates(self):
        # The 'w' group sits AFTER a malformed entry and an all-bad prefix; it
        # must still build and its surviving children still navigate.
        root = build(MALFORMED_SPEC)
        w = navigate(root, "w")
        self.assertIsInstance(w, Prefix)
        # The good children survive; the bad sibling ('z') is gone.
        self.assertEqual(
            [k for k, _, _ in entries(w.node)], ["h", "j"],
        )
        self.assertIsInstance(navigate(w.node, "h"), Leaf)
        self.assertIs(navigate(w.node, "z"), NO_MATCH)

    def test_bad_keys_are_no_match(self):
        root = build(MALFORMED_SPEC)
        # The malformed entries left NO bindings behind.
        for key in ["x", "e", "dead", ""]:
            with self.subTest(key=key):
                self.assertIs(navigate(root, key), NO_MATCH)

    def test_all_bad_prefix_dropped_not_present(self):
        root = build(MALFORMED_SPEC)
        # The 'dead' prefix had only malformed children -> the prefix itself is
        # skipped, so it appears nowhere in the usable trie.
        keys = [k for k, _, _ in entries(root)]
        self.assertNotIn("dead", keys)
        # Only the three GOOD top-level entries survive, in declared order.
        self.assertEqual(keys, ["c", "bar", "w"])

    def test_skips_are_recorded_as_warnings(self):
        # build records every skip so the kitten could surface them; here we
        # just confirm the partial-build left a non-empty audit trail.
        root = build(MALFORMED_SPEC)
        self.assertTrue(root.warnings)


class _BuildSpy:
    """Wraps the REAL chord_trie.build, counting calls so a test can assert
    rebuild vs. no-rebuild. The kitten's module-scope _TRIE uses this same
    build + load_or_build pairing."""

    def __init__(self):
        self.calls = 0

    def __call__(self, spec):
        self.calls += 1
        return build(spec)


class CorruptCacheKittenPath(unittest.TestCase):
    """AC 2: a corrupt / unreadable cache falls back to a fresh parse through the
    REAL kitten components (the live which_key_spec.SPEC + chord_trie.build via
    load_or_build) — the same wiring as `_TRIE = load_or_build(...)` — without a
    terminal, and never raising."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmpdir = self._tmp.name
        # A real on-disk spec file to stat for mtime (contents irrelevant: the
        # live SPEC list is injected separately).
        self.spec_path = os.path.join(self.tmpdir, "which_key_spec.py")
        with open(self.spec_path, "w") as fh:
            fh.write("SPEC = []\n")
        os.utime(self.spec_path, (1000.0, 1000.0))
        self.cache_file = os.path.join(self.tmpdir, "cache", DEFAULT_CACHE_NAME)

    def _assert_live_trie(self, trie):
        # The fallback build produced a working trie over the LIVE spec.
        # Post-cutover (issue 08) the live spec is FLAT — every native chord is
        # a top-level leaf — so assert a representative leaf dispatches its
        # exact action. Asserted via the public interface only.
        result = navigate(trie, "bar")
        self.assertIsInstance(result, Leaf)
        self.assertEqual(result.action, "launch --location=vsplit --cwd=current")

    def test_corrupt_cache_falls_back_through_live_spec(self):
        os.makedirs(os.path.dirname(self.cache_file), exist_ok=True)
        with open(self.cache_file, "wb") as fh:
            fh.write(b"not a pickle\x00\x01garbage")

        spy = _BuildSpy()
        trie = load_or_build(self.spec_path, LIVE_SPEC, spy, self.cache_file)
        self.assertEqual(spy.calls, 1)  # corrupt -> fresh parse of LIVE_SPEC
        self._assert_live_trie(trie)

        # File was repaired -> the next call hits the cache (no rebuild).
        again = load_or_build(self.spec_path, LIVE_SPEC, spy, self.cache_file)
        self.assertEqual(spy.calls, 1)
        self._assert_live_trie(again)

    def test_unreadable_cache_falls_back_through_live_spec(self):
        os.makedirs(os.path.dirname(self.cache_file), exist_ok=True)
        with open(self.cache_file, "wb") as fh:
            pickle.dump({"mtime": 1000.0, "trie": build(LIVE_SPEC)}, fh)
        os.chmod(self.cache_file, 0)
        if os.access(self.cache_file, os.R_OK):
            os.chmod(self.cache_file, 0o600)
            self.skipTest("permissions not enforced for this user")

        spy = _BuildSpy()
        try:
            trie = load_or_build(
                self.spec_path, LIVE_SPEC, spy, self.cache_file,
            )
        finally:
            os.chmod(self.cache_file, 0o600)  # let TemporaryDirectory clean up
        self.assertEqual(spy.calls, 1)  # unreadable -> fresh parse, no raise
        self._assert_live_trie(trie)


class BufferedKeyDecision(unittest.TestCase):
    """AC 3 (mandated pure unit test): buffered_key_decision(stack, key) decides
    HONOR vs. DROP for a key found already buffered at spawn time, delegating to
    nav_step. Bound transitions + explicit cancels are honored; an unbound key is
    dropped rather than mis-dispatched."""

    def test_bound_leaf_honored_as_dispatch(self):
        decision, result = buffered_key_decision(_root_stack(), "c")
        self.assertEqual(decision, HONOR)
        self.assertIsInstance(result, Dispatch)
        self.assertEqual(result.action, "close_window")

    def test_bound_prefix_honored_as_descend(self):
        decision, result = buffered_key_decision(_root_stack(), "w")
        self.assertEqual(decision, HONOR)
        self.assertIsInstance(result, Descend)

    def test_unbound_key_dropped(self):
        for key in ["z", ""]:
            with self.subTest(key=key):
                decision, result = buffered_key_decision(_root_stack(), key)
                self.assertEqual(decision, DROP)
                self.assertIs(result, STAY)

    def test_esc_honored_as_cancel(self):
        decision, result = buffered_key_decision(_root_stack(), KEY_ESC)
        self.assertEqual(decision, HONOR)
        self.assertIs(result, CANCEL)

    def test_backspace_at_root_honored_as_cancel(self):
        decision, result = buffered_key_decision(_root_stack(), KEY_BACKSPACE)
        self.assertEqual(decision, HONOR)
        self.assertIs(result, CANCEL)

    def test_backspace_in_group_honored_as_pop(self):
        stack = _group_stack()
        decision, result = buffered_key_decision(stack, KEY_BACKSPACE)
        self.assertEqual(decision, HONOR)
        self.assertIsInstance(result, Pop)
        self.assertIs(result.node, stack[0])  # pops back to the root

    def test_does_not_mutate_stack(self):
        # Purity: deciding a key never mutates the passed stack.
        for stack_factory, key in [
            (_root_stack, "c"),             # HONOR/Dispatch
            (_root_stack, "w"),             # HONOR/Descend
            (_root_stack, "z"),             # DROP
            (_root_stack, KEY_ESC),         # HONOR/CANCEL
            (_group_stack, KEY_BACKSPACE),  # HONOR/Pop
        ]:
            with self.subTest(key=key):
                stack = stack_factory()
                before = [id(n) for n in stack]
                buffered_key_decision(stack, key)
                self.assertEqual([id(n) for n in stack], before)

    def test_agrees_with_nav_step_on_honored_keys(self):
        # The honored result IS exactly what nav_step would return — the
        # decision adds only the HONOR/DROP gate, no re-interpretation. Dispatch/
        # Descend lack a value __eq__, so compare type + the carried payload.
        cases = [
            ("c", Dispatch, lambda r: r.action),
            ("w", Descend, lambda r: [k for k, _, _ in entries(r.node)]),
            (KEY_ESC, _Cancel := type(CANCEL), lambda r: r),
        ]
        for key, expected_type, payload in cases:
            with self.subTest(key=key):
                _, got = buffered_key_decision(_root_stack(), key)
                want = nav_step(_root_stack(), key)
                self.assertIsInstance(got, expected_type)
                self.assertIsInstance(want, expected_type)
                self.assertEqual(payload(got), payload(want))


class SoftBellPolicy(unittest.TestCase):
    """AC 4 (pure portion): pin the soft-bell policy constants. The emission
    through the tty (driver._soft_bell writing BEL on an unbound STICKY key) is
    terminal-interactive and verified manually."""

    def test_soft_bell_default_on(self):
        self.assertIs(SOFT_BELL, True)

    def test_bel_is_ascii_bell(self):
        self.assertEqual(BEL, "\a")
        self.assertEqual(BEL, "\x07")


if __name__ == "__main__":
    unittest.main()
