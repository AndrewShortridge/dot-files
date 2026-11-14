#!/usr/bin/env python3
# Fixture-table unit tests for the mtime-keyed trie cache (issue 05).
# Covers which_key_cache.load_or_build + cache_dir/cache_path: mtime hit returns
# the cached trie WITHOUT rebuild (asserted via an injected build-spy call
# count), mtime change rebuilds and rewrites the on-disk envelope, corrupt /
# unreadable cache falls back to a fresh parse without raising, first-run build,
# and a rewrite-failure still returning a valid trie. All over temp dirs with
# synthetic os.utime mtimes — no terminal, no socket, no real-time wait — so it
# runs under both miniconda python3 and kitty's bundled python.
import os
import pickle
import sys
import tempfile
import unittest
from unittest import mock

# repo root on sys.path so `from kittens.* import ...` works.
sys.path.insert(
    0, os.path.join(os.path.dirname(__file__), "..", "..", "..")
)

from kittens.which_key_cache import (  # noqa: E402
    load_or_build, cache_path, cache_dir, DEFAULT_CACHE_NAME,
)
from kittens.chord_trie import build, entries, navigate, Prefix  # noqa: E402

# Same fixture shape as test_chord_trie.py: leaves + one real nested group, so
# the deserialized trie's correctness is asserted via the public interface
# (entries()/navigate()) — never by poking Node fields.
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

EXPECTED_ROOT_ENTRIES = [
    ("c",     "close window",     False),
    ("bar",   "split vertical",   False),
    ("minus", "split horizontal", False),
    ("w",     "window",           True),
]


class _BuildSpy:
    """Wraps chord_trie.build, counting calls so a test can assert rebuild vs.
    no-rebuild precisely. Passed as build_fn into load_or_build."""

    def __init__(self):
        self.calls = 0

    def __call__(self, spec):
        self.calls += 1
        return build(spec)


def _assert_correct_trie(test, trie):
    """The (possibly deserialized) trie matches a fresh build via the public
    interface only."""
    test.assertEqual(entries(trie), EXPECTED_ROOT_ENTRIES)
    result = navigate(trie, "w")
    test.assertIsInstance(result, Prefix)
    test.assertEqual(
        [k for k, _, _ in entries(result.node)], ["h", "j", "k"],
    )


class CacheLoadOrBuild(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmpdir = self._tmp.name
        # A real on-disk spec file to stat for mtime; contents are irrelevant
        # (the spec list is injected separately), only its mtime matters.
        self.spec_path = os.path.join(self.tmpdir, "which_key_spec.py")
        with open(self.spec_path, "w") as fh:
            fh.write("SPEC = []\n")
        self.cache_file = os.path.join(self.tmpdir, "cache", DEFAULT_CACHE_NAME)

    def _set_mtime(self, t):
        os.utime(self.spec_path, (t, t))

    # 1. mtime hit deserializes without rebuilding (AC: hit / story 22).
    def test_build_then_hit_no_rebuild(self):
        self._set_mtime(1000.0)
        spy = _BuildSpy()
        first = load_or_build(self.spec_path, FIXTURE_SPEC, spy, self.cache_file)
        self.assertEqual(spy.calls, 1)
        self.assertTrue(os.path.exists(self.cache_file))
        _assert_correct_trie(self, first)

        # Same mtime -> hit, build_fn NOT called again.
        second = load_or_build(self.spec_path, FIXTURE_SPEC, spy, self.cache_file)
        self.assertEqual(spy.calls, 1)
        _assert_correct_trie(self, second)

    # 2. mtime change rebuilds AND rewrites (AC: change-rebuild / story 23).
    def test_mtime_change_rebuilds_and_rewrites(self):
        self._set_mtime(1000.0)
        spy = _BuildSpy()
        load_or_build(self.spec_path, FIXTURE_SPEC, spy, self.cache_file)
        self.assertEqual(spy.calls, 1)

        # Newer synthetic mtime -> miss -> rebuild.
        self._set_mtime(2000.0)
        trie = load_or_build(self.spec_path, FIXTURE_SPEC, spy, self.cache_file)
        self.assertEqual(spy.calls, 2)
        _assert_correct_trie(self, trie)

        # The on-disk envelope now carries the NEW mtime (proves rewrite, not
        # just an in-memory rebuild).
        with open(self.cache_file, "rb") as fh:
            payload = pickle.load(fh)
        self.assertEqual(payload["mtime"], 2000.0)

    # 3. corrupt cache falls back, never raises, and is repaired (AC / story 24)
    def test_corrupt_cache_falls_back(self):
        self._set_mtime(1000.0)
        os.makedirs(os.path.dirname(self.cache_file), exist_ok=True)
        with open(self.cache_file, "wb") as fh:
            fh.write(b"not a pickle\x00\x01garbage")

        spy = _BuildSpy()
        trie = load_or_build(self.spec_path, FIXTURE_SPEC, spy, self.cache_file)
        self.assertEqual(spy.calls, 1)  # corrupt -> fell back to a build
        _assert_correct_trie(self, trie)

        # The corrupt file was overwritten with a valid cache -> next call hits.
        again = load_or_build(self.spec_path, FIXTURE_SPEC, spy, self.cache_file)
        self.assertEqual(spy.calls, 1)
        _assert_correct_trie(self, again)

    # 4. unreadable cache falls back, never raises (AC / story 24).
    def test_unreadable_cache_falls_back(self):
        self._set_mtime(1000.0)
        os.makedirs(os.path.dirname(self.cache_file), exist_ok=True)
        with open(self.cache_file, "wb") as fh:
            pickle.dump({"mtime": 1000.0, "trie": build(FIXTURE_SPEC)}, fh)
        os.chmod(self.cache_file, 0)
        # Skip if the test user can read regardless of perms (e.g. root).
        if os.access(self.cache_file, os.R_OK):
            os.chmod(self.cache_file, 0o600)
            self.skipTest("permissions not enforced for this user")

        spy = _BuildSpy()
        try:
            trie = load_or_build(
                self.spec_path, FIXTURE_SPEC, spy, self.cache_file,
            )
        finally:
            os.chmod(self.cache_file, 0o600)  # let TemporaryDirectory clean up
        self.assertEqual(spy.calls, 1)  # unreadable -> fell back to a build
        _assert_correct_trie(self, trie)

    # 5. first run, no cache file -> builds + creates the file (AC: built trie
    #    via on-disk cache under the cache dir).
    def test_missing_cache_first_run_builds(self):
        self._set_mtime(1000.0)
        self.assertFalse(os.path.exists(self.cache_file))
        spy = _BuildSpy()
        trie = load_or_build(self.spec_path, FIXTURE_SPEC, spy, self.cache_file)
        self.assertEqual(spy.calls, 1)
        self.assertTrue(os.path.exists(self.cache_file))
        _assert_correct_trie(self, trie)

    # 6. rewrite failure still returns a valid trie (AC: never raises, even on
    #    write failure).
    def test_write_failure_still_returns_trie(self):
        self._set_mtime(1000.0)
        # Parent of the cache dir is an existing FILE, so makedirs/replace fail.
        blocker = os.path.join(self.tmpdir, "blocker")
        with open(blocker, "w") as fh:
            fh.write("x")
        unwritable_cache = os.path.join(blocker, "sub", DEFAULT_CACHE_NAME)

        spy = _BuildSpy()
        trie = load_or_build(
            self.spec_path, FIXTURE_SPEC, spy, unwritable_cache,
        )  # must not raise
        self.assertEqual(spy.calls, 1)
        _assert_correct_trie(self, trie)
        self.assertFalse(os.path.exists(unwritable_cache))

    # Defensive: an unstattable spec path skips caching and just builds.
    def test_unstattable_spec_path_builds(self):
        spy = _BuildSpy()
        missing_spec = os.path.join(self.tmpdir, "does-not-exist.py")
        trie = load_or_build(missing_spec, FIXTURE_SPEC, spy, self.cache_file)
        self.assertEqual(spy.calls, 1)
        _assert_correct_trie(self, trie)
        self.assertFalse(os.path.exists(self.cache_file))


class CacheDir(unittest.TestCase):
    # 7. cache dir resolves under the user cache dir (AC: "under the user cache
    #    dir"). Pure path assertions, no I/O.
    def test_cache_dir_under_xdg(self):
        with mock.patch.dict(os.environ, {"XDG_CACHE_HOME": "/xdg/cache"}):
            self.assertEqual(cache_dir(), os.path.join("/xdg/cache", "which_key"))
            self.assertEqual(
                cache_path(),
                os.path.join("/xdg/cache", "which_key", DEFAULT_CACHE_NAME),
            )

    def test_cache_dir_under_home_when_xdg_unset(self):
        env = dict(os.environ)
        env.pop("XDG_CACHE_HOME", None)
        with mock.patch.dict(os.environ, env, clear=True):
            expected = os.path.join(
                os.path.expanduser("~"), ".cache", "which_key",
            )
            self.assertEqual(cache_dir(), expected)
            self.assertEqual(
                cache_path(), os.path.join(expected, DEFAULT_CACHE_NAME),
            )

    def test_cache_path_honors_explicit_dir(self):
        self.assertEqual(
            cache_path("/some/dir"),
            os.path.join("/some/dir", DEFAULT_CACHE_NAME),
        )


if __name__ == "__main__":
    unittest.main()
