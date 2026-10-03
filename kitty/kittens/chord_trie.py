# kittens/chord_trie.py
# Pure chord-trie module — the deep, testable core of the which-key kitten.
# Modeled on Helix's KeyTrieNode: each node carries its children (key -> node),
# a parallel declared-order list, and an optional group label / action.
#
# PURE: no kitty imports, no terminal, no I/O. Stdlib only, so it imports under
# plain python3 and the unit tests run with zero third-party deps. (No wcwidth
# here — width measurement is the layout module, issue 06.)
#
# Public interface (the three behaviors issue 02 mandates):
#   build(spec)      -> root Node      (malformed entries skipped, not raised)
#   navigate(node, key) -> Prefix | Leaf | NO_MATCH   (one O(1) descent step)
#   entries(node)    -> [(key, desc, is_group)]       (declared order)


class Node:
    """A trie node. Internal struct — tests assert via entries()/navigate(),
    never by poking these fields directly (per PRD testing decisions)."""
    __slots__ = ("children", "order", "group", "action", "desc", "warnings")

    def __init__(self, group=None, action=None, desc=None):
        self.children = {}      # dict[str, Node]: key -> child node
        self.order = []         # list[str]: declared key order at this level
        self.group = group      # str | None: group label if this is a prefix
        self.action = action    # str | None: kitty action if this is a leaf
        self.desc = desc        # str | None: human description / row label
        self.warnings = []      # list[str]: malformed entries skipped at build


# --- navigation result types ----------------------------------------------
# navigate() returns a small tagged result (NOT a raw node) so the descent
# driver (issues 03/04) can branch cleanly.

class Prefix:
    """navigate() result: the key led to a sub-prefix with children."""
    __slots__ = ("node",)

    def __init__(self, node):
        self.node = node


class Leaf:
    """navigate() result: the key led to an action leaf."""
    __slots__ = ("action",)

    def __init__(self, action):
        self.action = action


class _NoMatch:
    """Singleton sentinel: the key is unbound at this node."""
    __slots__ = ()

    def __repr__(self):
        return "NO_MATCH"


NO_MATCH = _NoMatch()


# --- build -----------------------------------------------------------------

def build(spec):
    """Build the trie from a spec list. Returns the root Node.

    Malformed entries are SKIPPED (recorded on root.warnings), never raised —
    one bad entry must not abort the whole trie. Basic handling only; full
    robustness / user-facing surfacing is issue 07.

    A prefix entry whose children are all malformed (yields no usable child)
    is itself skipped and recorded.
    """
    root = Node()
    _populate(root, spec, root.warnings, path="")
    return root


def _populate(node, spec, warnings, path):
    """Fill `node` from `spec` (a list of entries). Append skip reasons to
    `warnings`. `path` is a human-readable breadcrumb for warning messages."""
    if not isinstance(spec, (list, tuple)):
        warnings.append(
            "spec at %r is not a list (got %s); skipped"
            % (path or "<root>", type(spec).__name__)
        )
        return

    for index, entry in enumerate(spec):
        here = "%s[%d]" % (path, index)

        if not isinstance(entry, dict):
            warnings.append(
                "entry %s is not a dict (got %s); skipped"
                % (here, type(entry).__name__)
            )
            continue

        key = entry.get("key")
        if not isinstance(key, str) or not key:
            warnings.append("entry %s missing/invalid 'key'; skipped" % here)
            continue

        keypath = "%s.%s" % (path, key) if path else key

        has_children = "children" in entry
        has_action = "action" in entry

        if has_children:
            # Prefix node. Recurse; skip the whole prefix if it yields nothing.
            child = Node(
                group=entry.get("group"),
                desc=entry.get("group", key),
            )
            _populate(child, entry.get("children"), warnings, keypath)
            if not child.order:
                warnings.append(
                    "prefix entry %r has no usable children; skipped" % keypath
                )
                continue
            _attach(node, key, child)
        elif has_action:
            # Leaf node.
            action = entry.get("action")
            if not isinstance(action, str) or not action:
                warnings.append(
                    "leaf entry %r has missing/invalid 'action'; skipped"
                    % keypath
                )
                continue
            child = Node(action=action, desc=entry.get("desc", key))
            _attach(node, key, child)
        else:
            warnings.append(
                "entry %r is neither a leaf (no 'action') nor a prefix "
                "(no 'children'); skipped" % keypath
            )
            continue


def _attach(node, key, child):
    """Attach `child` under `key`, preserving declared order. A duplicate key
    overwrites the node but keeps its original position in `order`."""
    if key not in node.children:
        node.order.append(key)
    node.children[key] = child


# --- navigate --------------------------------------------------------------

def navigate(node, key):
    """One O(1) descent step from `node` on `key`.

    Returns:
        Prefix(child)        if `key` maps to a sub-prefix (has children)
        Leaf(child.action)   if `key` maps to an action leaf
        NO_MATCH             if `key` is unbound at this node
    """
    child = node.children.get(key)
    if child is None:
        return NO_MATCH
    if child.children:
        return Prefix(child)
    return Leaf(child.action)


# --- entries ---------------------------------------------------------------

def entries(node):
    """Rows for the layout module, in declared order:
        [(key, desc, is_group), ...]
    is_group is True for sub-prefixes; for a group row the desc is its group
    label. Pure declared order — groups-last sorting is issue 06's job."""
    rows = []
    for key in node.order:
        child = node.children[key]
        is_group = bool(child.children)
        rows.append((key, child.desc, is_group))
    return rows
