# kittens/which_key_cache.py
# mtime-keyed load-or-build cache for the which-key trie (issue 05).
#
# Keeps the kitten's Python cold-start honest against the 100ms budget: the
# built trie is serialized to a single pickle under the user cache dir, keyed by
# the chord spec file's mtime. On a leader press the kitten calls load_or_build:
#   - mtime hit  -> deserialize the cached trie, NO rebuild.
#   - mtime miss -> rebuild from the spec and rewrite the cache (atomically).
#   - corrupt / unreadable cache, or stat/write failure -> fall back to a fresh
#     build and NEVER raise to the caller.
#
# PURE-ish: stdlib only (os, pickle, tempfile), NO kitty imports, no terminal,
# so it imports under plain python3 and is unit-testable with temp dirs and
# synthetic mtimes. The trie builder (chord_trie.build) and the cache-file path
# are INJECTED rather than imported, so the cache module needs no chord_trie
# import and tests can assert build-vs-no-build precisely against a temp dir.
#
# Serialization is pickle (default protocol): Node uses __slots__ and nests
# cleanly, pickle handles it natively in <1ms with no hand-written codec, and a
# class/version mismatch (e.g. a pickle written under the top-level `chord_trie`
# import name vs. the `kittens.chord_trie` name) simply surfaces as an
# unpickling exception that the broad load fallback already swallows -> a cache
# miss, never a crash.

import os
import pickle

DEFAULT_CACHE_NAME = "which_key_trie.pickle"


def cache_dir():
    """User cache dir for the kitten: $XDG_CACHE_HOME/which_key, or
    ~/.cache/which_key when XDG_CACHE_HOME is unset. Pure path computation —
    does NOT create the directory."""
    base = os.environ.get("XDG_CACHE_HOME")
    if not base:
        base = os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, "which_key")


def cache_path(cache_dir_path=None):
    """Absolute path to the trie cache file under the cache dir."""
    if cache_dir_path is None:
        cache_dir_path = cache_dir()
    return os.path.join(cache_dir_path, DEFAULT_CACHE_NAME)


def _atomic_write(cache_file, payload):
    """Best-effort atomic write of `payload` to `cache_file` via a temp file in
    the SAME directory + os.replace, so an interrupted/concurrent write never
    leaves a half-written pickle that would later read as corrupt. Swallows all
    errors (read-only dir, disk full): a write failure must not break the
    caller, which already holds the freshly built trie."""
    import tempfile  # lazy: only the (rare) rebuild path pays its ~5ms import
    target_dir = os.path.dirname(cache_file) or "."
    try:
        os.makedirs(target_dir, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=target_dir, suffix=".tmp")
        try:
            with os.fdopen(fd, "wb") as fh:
                pickle.dump(payload, fh)
            os.replace(tmp, cache_file)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
    except Exception:
        pass


def load_or_build(spec_path, spec, build_fn, cache_file=None):
    """mtime-keyed load-or-build of the trie. NEVER raises to the caller.

    Args:
        spec_path: path to the chord-spec module file to stat for mtime (the
            live driver passes which_key_spec.__file__).
        spec: the SPEC list, handed to build_fn on a miss / fallback.
        build_fn: the trie builder (chord_trie.build), INJECTED so this module
            needs no chord_trie import and tests can pass a spy.
        cache_file: optional explicit cache path; INJECTED by tests to point at
            a temp dir. Defaults to cache_path().

    Returns the built (or cached) trie.
    """
    cf = cache_file or cache_path()

    # Stat the spec for its mtime. If the spec itself can't be stat'd we can't
    # key the cache at all -> skip caching entirely and just build (defensive;
    # never raise).
    try:
        spec_mtime = os.stat(spec_path).st_mtime
    except Exception:
        return build_fn(spec)

    # Load attempt (mtime hit). Any failure — missing file, corrupt/truncated
    # pickle, cross-import-name unpickle error, missing keys, or an mtime
    # mismatch — falls through to a rebuild. Broad on purpose: a corrupt or
    # unreadable cache must degrade to a fresh parse, never crash.
    try:
        with open(cf, "rb") as fh:
            payload = pickle.load(fh)
        if payload["mtime"] == spec_mtime:
            return payload["trie"]
    except Exception:
        pass

    # Miss / changed / corrupt -> rebuild, then rewrite the cache best-effort.
    trie = build_fn(spec)
    _atomic_write(cf, {"mtime": spec_mtime, "trie": trie})
    return trie
