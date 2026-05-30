# Nested Tag Completion

## Problem Statement

The vault system supports hierarchical tags (e.g., `#project/alpha`,
`#status/in-progress`, `#type/meeting/standup`) throughout indexing, display,
and search. The vault index already stores parent-expanded tag hierarchies via
`add_tag_with_parents()`, and the tag tree picker (`tag_tree.lua`) renders them
as a collapsible hierarchy. However, the **completion system** treats tags as a
flat list with no hierarchy awareness.

When a user types `#project/`, the completion popup shows all tags sorted
alphabetically and filtered by blink.cmp's fuzzy matcher. It does **not**:

1. Show only the direct children of `project/` (e.g., `project/alpha`,
   `project/beta`) as prioritized completions.
2. Allow progressive drill-down (typing `#project/alpha/` to see
   `project/alpha/phase1`, `project/alpha/phase2`).
3. Distinguish between parent nodes (which have children) and leaf nodes.
4. Show the hierarchy structure or child counts to help navigate deep tag trees.

Obsidian provides nested tag completion: after typing `#project/`, only the
immediate children appear, and selecting one either inserts it or drills deeper
if it has sub-tags. The current flat approach becomes unusable as the tag
vocabulary grows beyond a few dozen hierarchical tags.

## Current Architecture

### Tag Completion Source (`completion_tags.lua`)

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/completion_tags.lua`

The tag completion source is built using the `completion_base.lua` factory
pattern (`base.create_source()`). It has two main components:

#### `build(vault_path, callback)` (lines 9-105)

Scans the vault for tags using two parallel ripgrep invocations:

1. **Inline tags:** `rg -o "(?:^|\\s)#([a-zA-Z][a-zA-Z0-9_/-]+)"` -- finds
   `#tag` patterns in markdown files.
2. **Frontmatter tags:** `rg -U` with a multiline pattern to find YAML list
   items under `tags:`.

Both results are merged into a `counts` table (`tag_name -> usage_count`), then
built into completion items:

```lua
items[#items + 1] = {
  label = "#" .. tag,
  insertText = tag,
  filterText = tag,
  kind = 14, -- Keyword
  sortText = base.freq_sort_text(count, tag),
  labelDetails = {
    description = base.count_label(count),
  },
}
```

Key observations:
- The `label` includes the `#` prefix (e.g., `#project/alpha`) for display.
- The `insertText` omits the `#` (e.g., `project/alpha`) because the `#` is
  already typed by the user.
- The `filterText` is the bare tag name, which blink.cmp fuzzy-matches against.
- Sorting is by frequency (most-used tags first), then alphabetically.
- **All tags are returned as a flat list.** There is no concept of "current
  depth" or "parent prefix."

#### `get_completions(self, ctx, items, callback)` (lines 112-131)

Custom trigger logic that only activates after a `#` that looks like a tag
start (not a heading):

```lua
if not before:match("[%s^]#[%w_/-]*$") and not before:match("^#[%w_/-]*$") then
  callback(empty)
  return
end
-- Exclude markdown headings
local trimmed = vim.trim(before)
if trimmed:match("^#+%s") or trimmed:match("^#+$") then
  callback(empty)
  return
end
callback({ ..., items = items })
```

This function does **not** inspect the text after `#` to determine a prefix for
filtering. It returns the entire `items` list and relies on blink.cmp's fuzzy
matcher to narrow results. The slash character `/` in a tag is just another
character in the `filterText` -- there is no special hierarchy handling.

### Completion Base Factory (`completion_base.lua`)

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/completion_base.lua`

The factory provides:
- **Caching:** Items are built once and cached until invalidated.
- **Invalidation:** Via `all_invalidators` registry, triggered by
  `engine.invalidate_all_caches()` on `FocusGained` / fs events.
- **Generation tracking:** `build_generation` increments on invalidation,
  preventing stale async builds from overwriting fresh data.
- **Async build:** `build_items_async()` calls `opts.build()` off the main
  thread, then schedules the callback on `vim.schedule`.

The factory calls `opts.get_completions(self, ctx, cached_items, callback)` for
each completion request, passing the pre-built `cached_items` array. The source
can filter, transform, or replace items before calling `callback`.

### blink.cmp Provider Registration

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/plugins/blink-cmp.lua`,
lines 111-117

```lua
vault_tags = {
  name = "VaultTags",
  module = "andrew.vault.completion_tags",
  min_keyword_length = 0,
  score_offset = 12,
  fallbacks = {},
},
```

The source is registered for `markdown` filetype at line 86. It has
`min_keyword_length = 0`, which means it triggers as soon as the `#` is typed
(combined with the custom trigger logic in `get_completions`).

### Tag Data in the Vault Index

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/vault_index.lua`

Tags are extracted in `extract_tags()` (line 332) which calls
`add_tag_with_parents()` (line 321) to expand parent segments:

```lua
local function add_tag_with_parents(set, tag)
  set[tag] = true
  local parent = tag
  while true do
    parent = parent:match("^(.+)/[^/]+$")
    if not parent then break end
    set[parent] = true
  end
end
```

So a file tagged `#project/alpha/phase1` gets three entries in its `tags` array:
`project/alpha/phase1`, `project/alpha`, and `project`.

Available query methods:
- `all_tags()` (line 1354): Returns a sorted flat list of all unique tags.
- `tags_with_counts()` (line 1371): Returns `tag -> file_count` mapping.
- `files_for_tag(tag, exact)` (line 1405): Returns entries matching a tag
  (with optional descendant matching).
- `tag_matches(tags, target, opts)` (line 1386): Static matcher with
  exact/descendant and case-insensitive options.

### Tag Tree Module (`tag_tree.lua`)

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/tag_tree.lua`

A pure data transformation module already used by the tag tree picker. It
provides:

- `build_tree(tag_counts)` (line 60): Builds a `TagTreeNode` hierarchy from a
  flat `tag -> count` mapping. Each node has `name`, `full_tag`, `count`,
  `total`, `children`, and `depth`.
- `flatten(root, collapsed)` (line 109): Flattens the tree into ANSI-formatted
  strings for fzf-lua display.
- `colorize_tag(name, full_tag)` (line 39): Applies ANSI colors based on
  config category prefixes.

The tree builder is exactly the data structure needed for hierarchical
completion. However, it currently outputs fzf-formatted strings, not completion
items. The tree-building logic itself is reusable.

### How blink.cmp Handles Filtering

blink.cmp performs fuzzy matching on `filterText` (or `label` if `filterText` is
absent). When the user types `#project/al`, blink.cmp fuzzy-matches `al` against
every item's `filterText`. Because `filterText` is the full tag string
(e.g., `project/alpha`), the `/` is just another character in the match -- it
does not serve as a hierarchy delimiter for the matcher.

This means typing `#project/` shows all tags containing `project/` somewhere in
their name, but also tags like `my-project/foo` or any fuzzy match against
`project/`. The results are not scoped to the immediate children of `project/`.

## Proposed Solution

### Overview

Modify `completion_tags.lua` to detect when the user has typed a `/`-terminated
prefix (e.g., `#project/`) and return **only the immediate next-level children**
of that prefix as completion items, instead of returning the entire flat tag
list. When no `/` is typed (e.g., just `#pro`), fall back to the current flat
behavior showing all tags.

This creates a progressive drill-down experience:
1. User types `#` -- sees all top-level tags and full tag paths (current behavior).
2. User types `#project/` -- sees only `project/alpha`, `project/beta`, etc.
3. User types `#project/alpha/` -- sees only `project/alpha/phase1`, etc.
4. User types `#project/al` (no trailing `/`) -- fuzzy matches against all tags
   starting with `project/` (filtering within the current level).

### Data Source Change: Use Vault Index Instead of Ripgrep

The `build()` function currently shells out to ripgrep to count tags. The vault
index already has this data available via `tags_with_counts()`. Switching to the
vault index as the data source:

1. Eliminates redundant shell-outs (two `rg` processes per build).
2. Provides consistency with the rest of the vault (single source of truth).
3. Gives access to structured tag data (parent/child relationships) without
   re-parsing.
4. Aligns with the pattern used by other completion sources
   (`completion.lua` uses the vault index for note names,
   `completion_frontmatter.lua` uses it for frontmatter fields).

### Core Change: Prefix-Aware Filtering in `get_completions()`

The `get_completions()` function gains the ability to detect a typed prefix and
filter items accordingly:

```lua
local function get_completions(self, ctx, items, callback)
  local before = ctx.line:sub(1, ctx.cursor[2])

  -- Trigger guard (existing logic, unchanged)
  if not before:match("[%s^]#[%w_/-]*$") and not before:match("^#[%w_/-]*$") then
    callback(empty)
    return
  end
  local trimmed = vim.trim(before)
  if trimmed:match("^#+%s") or trimmed:match("^#+$") then
    callback(empty)
    return
  end

  -- NEW: Extract the typed tag prefix (everything after #)
  local typed = before:match("#([%w_/-]*)$") or ""

  -- Check if the prefix ends with /  (user is drilling into a level)
  local parent_prefix = typed:match("^(.+/)$")

  if parent_prefix then
    -- Hierarchical mode: show only immediate children of this prefix
    local filtered = {}
    for _, item in ipairs(items) do
      local tag = item.filterText
      -- Item must start with the parent prefix
      if tag:sub(1, #parent_prefix) == parent_prefix then
        -- The remaining portion must NOT contain another /
        -- (i.e., it is an immediate child, not a grandchild)
        local remainder = tag:sub(#parent_prefix + 1)
        if remainder ~= "" and not remainder:find("/") then
          filtered[#filtered + 1] = item
        end
      end
    end

    -- If no children found at this level, fall back to showing all matches
    if #filtered == 0 then
      for _, item in ipairs(items) do
        if item.filterText:sub(1, #parent_prefix) == parent_prefix then
          filtered[#filtered + 1] = item
        end
      end
    end

    callback({
      is_incomplete_forward = false,
      is_incomplete_backward = false,
      items = filtered,
    })
  else
    -- Flat mode: return all items (current behavior)
    callback({
      is_incomplete_forward = false,
      is_incomplete_backward = false,
      items = items,
    })
  end
end
```

### Completion Item Enhancements

To improve the drill-down UX, completion items for tags that have children
should indicate this visually:

```lua
-- In build(), when constructing items:
local has_children = false
for other_tag, _ in pairs(counts) do
  if other_tag ~= tag and other_tag:sub(1, #tag + 1) == tag .. "/" then
    has_children = true
    break
  end
end

items[#items + 1] = {
  label = "#" .. tag,
  insertText = tag,
  filterText = tag,
  kind = has_children and 19 or 14, -- Folder (19) vs Keyword (14)
  sortText = base.freq_sort_text(count, tag),
  labelDetails = {
    description = has_children
      and base.count_label(count) .. " +"
      or base.count_label(count),
  },
  data = {
    has_children = has_children,
  },
}
```

The `+` suffix in the description and the `Folder` kind icon signal to the user
that selecting this tag has deeper levels available. The `Folder` kind (19)
renders with a folder icon in blink.cmp's kind_icon column, providing visual
differentiation without any custom rendering.

## Implementation Steps

### Step 1: Switch `build()` to use vault index

Replace the dual-ripgrep approach with a vault index lookup.

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/completion_tags.lua`

**Current** (lines 9-105): Two `vim.system()` calls to ripgrep, merging results
into a `counts` table.

**Proposed:**

```lua
local function build(vault_path, callback)
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    -- Index not ready; return empty and let base factory retry on next trigger
    callback({})
    return
  end

  local counts = idx:tags_with_counts()

  -- Pre-compute child existence for each tag
  local has_children_set = {}
  local all_tags = {}
  for tag, _ in pairs(counts) do
    all_tags[#all_tags + 1] = tag
  end
  table.sort(all_tags)

  for i, tag in ipairs(all_tags) do
    -- A tag has children if any subsequent sorted tag starts with tag .. "/"
    local prefix = tag .. "/"
    for j = i + 1, #all_tags do
      if all_tags[j]:sub(1, #prefix) == prefix then
        has_children_set[tag] = true
        break
      elseif all_tags[j] > prefix then
        -- Sorted order: no more matches possible
        break
      end
    end
  end

  -- Build completion items
  local items = {}
  for _, tag in ipairs(all_tags) do
    local count = counts[tag]
    local has_children = has_children_set[tag] or false

    items[#items + 1] = {
      label = "#" .. tag,
      insertText = tag,
      filterText = tag,
      kind = has_children and 19 or 14, -- Folder vs Keyword
      sortText = base.freq_sort_text(count, tag),
      labelDetails = {
        description = has_children
          and base.count_label(count) .. " +"
          or base.count_label(count),
      },
      data = {
        has_children = has_children,
      },
    }
  end

  callback(items)
end
```

**Why the child-existence pre-computation?** Since the tag list is sorted, we
can detect children in O(N) total by scanning forward from each tag. The
subsequent sorted tag starting with `tag .. "/"` must be a child. If the very
next sorted tag does not start with the prefix, no child exists. This avoids
an O(N^2) scan.

### Step 2: Add prefix-aware filtering to `get_completions()`

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/completion_tags.lua`

**Current** (lines 112-131): Returns all `items` unconditionally (after trigger
guard).

**Proposed:**

```lua
local function get_completions(self, ctx, items, callback)
  local before = ctx.line:sub(1, ctx.cursor[2])

  -- Only trigger after a # that looks like a tag start
  if not before:match("[%s^]#[%w_/-]*$") and not before:match("^#[%w_/-]*$") then
    callback(empty)
    return
  end

  -- Exclude markdown headings
  local trimmed = vim.trim(before)
  if trimmed:match("^#+%s") or trimmed:match("^#+$") then
    callback(empty)
    return
  end

  -- Extract the typed text after #
  local typed = before:match("#([%w_/-]*)$") or ""

  -- Detect if user is drilling into a hierarchy (typed prefix ends with /)
  local parent_prefix = typed:match("^(.+/)$")

  if parent_prefix then
    -- Hierarchical mode: return only immediate children of parent_prefix
    local filtered = {}
    for _, item in ipairs(items) do
      local tag = item.filterText
      if tag:sub(1, #parent_prefix) == parent_prefix then
        local remainder = tag:sub(#parent_prefix + 1)
        -- Immediate child: has content, no further slashes
        if remainder ~= "" and not remainder:find("/") then
          filtered[#filtered + 1] = item
        end
      end
    end

    -- Fallback: if no immediate children, show all descendants
    if #filtered == 0 then
      for _, item in ipairs(items) do
        if item.filterText:sub(1, #parent_prefix) == parent_prefix then
          filtered[#filtered + 1] = item
        end
      end
    end

    callback({
      is_incomplete_forward = false,
      is_incomplete_backward = false,
      items = filtered,
    })
  else
    -- Flat mode: return all items, let blink.cmp fuzzy filter
    callback({
      is_incomplete_forward = false,
      is_incomplete_backward = false,
      items = items,
    })
  end
end
```

### Step 3: Ensure `/` is included in blink.cmp keyword characters

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/plugins/blink-cmp.lua`

The blink-cmp config already monkey-patches the keyword module (lines 168-183)
to include additional characters in `iskeyword`:

```lua
local desired = '@,48-57,_,-,;,192-255'
```

This does **not** include `/`. When the user types `#project/`, blink.cmp may
treat the `/` as a keyword boundary and reset the completion context, losing the
prefix before the slash.

**Proposed:** Add `/` to the keyword character set:

```lua
local desired = '@,48-57,_,-,;,/,192-255'
```

**Risk assessment:** Adding `/` to `iskeyword` affects all completion sources
for all filetypes while blink.cmp is processing. However, the monkey-patch in
`with_constant_is_keyword` restores the original `iskeyword` after each
invocation, so the change is scoped to blink.cmp's internal matching and does
not leak into normal editing.

**Alternative (if `/` in `iskeyword` causes side effects):** Instead of
modifying `iskeyword`, configure the tag source to use `is_incomplete_forward =
true` when a prefix is detected, which tells blink.cmp to re-query the source
as the user types more characters. This is less efficient but avoids keyword
boundary issues.

**Verification needed:** Test whether blink.cmp already treats `/` as part of
the keyword for tag completion purposes. The `min_keyword_length = 0` setting
means the source triggers on any input, and the custom `get_completions`
function handles its own filtering. If blink.cmp's keyword extraction truncates
at `/`, the filtered items will not match. Adding `/` to `iskeyword` fixes this.

### Step 4: Add `get_trigger_characters()` to the tag source

Currently, the tag source does not define `get_trigger_characters()`. The
wikilink source defines it (returning `["[", "#", "^"]`). Adding `/` as a
trigger character for the tag source ensures that blink.cmp re-invokes
`get_completions` when the user types a `/` after a partial tag:

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/completion_tags.lua`

After `base.create_source()`, add:

```lua
local source = base.create_source({
  build = build,
  get_completions = get_completions,
})

function source:get_trigger_characters()
  return { "#", "/" }
end

return source
```

The `#` trigger ensures the source activates when the user starts a tag. The
`/` trigger ensures the source re-evaluates when the user drills into a
hierarchy level, refreshing the filtered items to show only children at the
new level.

**Note:** `base.create_source()` returns a source table. Adding
`get_trigger_characters` after creation works because blink.cmp looks up this
method on the source instance. The current `completion_tags.lua` structure
returns the result of `base.create_source()` directly (line 133-136):

```lua
return base.create_source({
  build = build,
  get_completions = get_completions,
})
```

This needs to be restructured to capture the source before returning:

```lua
local source = base.create_source({
  build = build,
  get_completions = get_completions,
})

function source:get_trigger_characters()
  return { "#", "/" }
end

return source
```

### Step 5: Update the `empty` sentinel's scope

The current `empty` variable is defined at module scope (line 3):

```lua
local empty = { is_incomplete_forward = false, is_incomplete_backward = false, items = {} }
```

This is shared between the `get_completions` function and any other code that
needs an empty response. No change needed -- it is reused in the new code.

## Complete Rewritten Module

For clarity, here is the full proposed `completion_tags.lua` after all changes:

```lua
local base = require("andrew.vault.completion_base")

local empty = { is_incomplete_forward = false, is_incomplete_backward = false, items = {} }

--- Build tag completion items from the vault index.
---@param vault_path string
---@param callback fun(items: table[])
local function build(vault_path, callback)
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    callback({})
    return
  end

  local counts = idx:tags_with_counts()

  -- Sorted tag list for efficient child detection
  local all_tags = {}
  for tag, _ in pairs(counts) do
    all_tags[#all_tags + 1] = tag
  end
  table.sort(all_tags)

  -- Pre-compute which tags have children (O(N) via sorted scan)
  local has_children_set = {}
  for i, tag in ipairs(all_tags) do
    local prefix = tag .. "/"
    for j = i + 1, #all_tags do
      if all_tags[j]:sub(1, #prefix) == prefix then
        has_children_set[tag] = true
        break
      elseif all_tags[j] > prefix then
        break
      end
    end
  end

  -- Build completion items
  local items = {}
  for _, tag in ipairs(all_tags) do
    local count = counts[tag]
    local has_children = has_children_set[tag] or false

    items[#items + 1] = {
      label = "#" .. tag,
      insertText = tag,
      filterText = tag,
      kind = has_children and 19 or 14,
      sortText = base.freq_sort_text(count, tag),
      labelDetails = {
        description = has_children
          and base.count_label(count) .. " +"
          or base.count_label(count),
      },
      data = {
        has_children = has_children,
      },
    }
  end

  callback(items)
end

--- Prefix-aware tag completion with hierarchical drill-down.
---@param self table
---@param ctx table
---@param items table[]
---@param callback fun(response: table)
local function get_completions(self, ctx, items, callback)
  local before = ctx.line:sub(1, ctx.cursor[2])

  -- Only trigger after a # that looks like a tag start
  if not before:match("[%s^]#[%w_/-]*$") and not before:match("^#[%w_/-]*$") then
    callback(empty)
    return
  end

  -- Exclude markdown headings
  local trimmed = vim.trim(before)
  if trimmed:match("^#+%s") or trimmed:match("^#+$") then
    callback(empty)
    return
  end

  -- Extract the typed text after #
  local typed = before:match("#([%w_/-]*)$") or ""

  -- Detect hierarchy drill-down: typed prefix ends with /
  local parent_prefix = typed:match("^(.+/)$")

  if parent_prefix then
    -- Show only immediate children of the typed prefix
    local filtered = {}
    for _, item in ipairs(items) do
      local tag = item.filterText
      if tag:sub(1, #parent_prefix) == parent_prefix then
        local remainder = tag:sub(#parent_prefix + 1)
        if remainder ~= "" and not remainder:find("/") then
          filtered[#filtered + 1] = item
        end
      end
    end

    -- Fallback: if no immediate children, show all descendants
    if #filtered == 0 then
      for _, item in ipairs(items) do
        if item.filterText:sub(1, #parent_prefix) == parent_prefix then
          filtered[#filtered + 1] = item
        end
      end
    end

    callback({
      is_incomplete_forward = false,
      is_incomplete_backward = false,
      items = filtered,
    })
  else
    -- Flat mode: return all items
    callback({
      is_incomplete_forward = false,
      is_incomplete_backward = false,
      items = items,
    })
  end
end

local source = base.create_source({
  build = build,
  get_completions = get_completions,
})

function source:get_trigger_characters()
  return { "#", "/" }
end

return source
```

## Key Design Decisions

### 1. Prefix-based filtering in `get_completions()` vs. restructured `build()`

**Decision:** Keep a flat item list in `build()` and filter it dynamically in
`get_completions()` based on the typed prefix.

**Rationale:** The `completion_base.lua` factory caches items from `build()` and
passes them to `get_completions()` on every keystroke. Building a tree structure
in `build()` would require restructuring the cache, and the factory would need
to understand tree navigation. Instead, filtering the flat list in
`get_completions()` is simpler and uses only string prefix matching (O(N) per
completion trigger, where N is the total tag count -- negligible for vaults
with < 1000 tags).

**Trade-off:** For vaults with 5000+ unique tags, the O(N) filter scan on
every keystroke could add latency. If this becomes an issue, the items could be
pre-indexed by prefix segments during `build()` for O(1) lookups. This
optimization is deferred.

### 2. Slash as hierarchy delimiter in filtering

**Decision:** Detect hierarchy drill-down by checking if the typed text ends
with `/` (e.g., `#project/`). When it does, show only immediate children.

**Rationale:** The slash is the natural and universally understood hierarchy
separator for tags (both in Obsidian and in general knowledge management). Users
expect that typing `#project/` scopes completions to that subtree. The
`/`-termination check is unambiguous: `#project/al` is "fuzzy matching within
the project/ subtree" while `#project/` is "show me what's under project/".

**Alternative considered:** Using blink.cmp's native `textEdit` with
`additionalTextEdits` to replace the entire tag. Rejected because it would
require complex cursor management and does not integrate with blink.cmp's
standard `insertText` flow.

### 3. Vault index as data source (replacing ripgrep)

**Decision:** Replace the dual-ripgrep `build()` with a vault index lookup.

**Rationale:**
- The vault index is the single source of truth for tag data, used by every
  other tag-related feature (`tags.lua`, `tag_tree.lua`, `search_filter.lua`,
  `graph_filter.lua`, `tag_highlights.lua`).
- The ripgrep approach runs two async shell processes, parses output line by
  line, and duplicates tag extraction logic already in the indexer.
- The vault index provides `tags_with_counts()` which returns exactly the
  data needed, already deduplicated and counted.
- Consistency with other completion sources: `completion.lua` (note names) and
  `completion_frontmatter.lua` (frontmatter fields) both use the vault index.

**Backward compatibility:** If the vault index is not ready when the source is
first built (e.g., on startup), `build()` returns `{}` and the factory's
`build_items_async()` is called again on the next `get_completions` trigger.
This matches the existing behavior in `completion.lua`.

### 4. `has_children` indicator via kind icon and description suffix

**Decision:** Use blink.cmp's `kind` field (19 = Folder for parent tags, 14 =
Keyword for leaves) and append ` +` to the description of parent tags.

**Rationale:** blink.cmp renders a `kind_icon` column that shows different icons
per item kind. Using `Folder` for parent tags provides a visual cue without any
custom rendering code. The ` +` suffix is a textual fallback for users who do
not display kind icons. Together, these signals tell the user "this tag has
subtags you can drill into by adding a `/`."

### 5. `/` as trigger character

**Decision:** Register `/` as an additional trigger character for the tag source
via `get_trigger_characters()`.

**Rationale:** Without `/` as a trigger character, typing `#project/` may not
re-invoke the completion source. blink.cmp re-evaluates completions when a
trigger character is typed, so adding `/` ensures that the drill-down happens
immediately when the user types the separator.

**Concern:** `/` is a common character that could trigger the tag source in
non-tag contexts. However, the `get_completions()` function already guards
against non-tag contexts with the `[%s^]#[%w_/-]*$` pattern check. If the
context before the cursor does not look like a tag, the source returns `empty`
regardless of the trigger character.

### 6. Fallback to all descendants when no immediate children exist

**Decision:** If the parent prefix has no immediate children, fall back to
showing all descendant tags at any depth.

**Rationale:** This handles an edge case where parent-expansion creates
intermediate nodes with no leaf children at a particular level. For example, if
the only tags are `a/b/c/d` and `a/b/c/e`, typing `#a/` would show no immediate
children (since `a/b` is an intermediate node, not a directly-used tag).
Falling back to show `a/b/c/d` and `a/b/c/e` is more useful than showing
nothing.

However, with `add_tag_with_parents()` in the vault index, intermediate nodes
*do* have entries (e.g., `a`, `a/b`, `a/b/c` all exist). So this fallback is
primarily a safety net for unusual tag structures.

## Edge Cases

### No tags in vault

If `idx:tags_with_counts()` returns an empty table, `build()` produces an empty
`items` list. The completion popup shows nothing. This matches current behavior.

### Vault index not ready

If the vault index is building when the user first types `#`, `build()` returns
`{}`. The factory's `build_items_async()` mechanism will retry on the next
completion trigger. Once the index is ready, items populate normally. This
matches the pattern used in `completion.lua` (lines 116-173).

### Single-segment tags (no hierarchy)

Tags without slashes (e.g., `meeting`, `draft`) are unaffected. They appear in
flat mode and have no `parent_prefix` detection. `has_children` is false for
these unless another tag starts with `meeting/` or `draft/`.

### Deeply nested hierarchies

A tag like `a/b/c/d/e` produces five index entries via parent expansion:
`a`, `a/b`, `a/b/c`, `a/b/c/d`, `a/b/c/d/e`. The drill-down works at every
level: `#a/` shows `a/b`, `#a/b/` shows `a/b/c`, etc. No depth limit is needed
because the user controls the drill-down.

### Tag prefix matching ambiguity

Consider tags `project` and `projection`. Typing `#project/` correctly limits
to children of `project/` because the prefix match requires the tag to start
with `project/` (with the trailing slash). `projection` starts with `project`
but not `project/`, so it is excluded.

### Tags with hyphens and underscores

The existing regex `#([%w_/-]*)$` in `get_completions()` already allows hyphens
(via the `-` in the character class). Tags like `in-progress` and `my_tag` are
correctly captured as the typed prefix.

**Note:** The original regex in `get_completions()` uses `[%w_/-]` which matches
word characters, underscore, forward slash, and hyphen. The hyphen must be at
the end of the character class or escaped to avoid being interpreted as a range.
In the current code (line 118), it is `[%w_/-]` where `-` is between `/` and
`]`, which in Lua patterns is interpreted as a literal hyphen (Lua patterns do
not support ranges with non-alphanumeric characters). This is correct.

### Trailing slash on leaf tags

If a user types `#meeting/` but `meeting` is a leaf tag with no children, the
`parent_prefix` detection triggers but `filtered` is empty. The fallback code
also finds no descendants (since no tag starts with `meeting/`). The result is
an empty completion list. This is correct behavior -- it signals to the user
that there are no subtags.

### Tags added/removed between completions

Tag changes are reflected after the completion cache is invalidated (on focus
gain, fs events, or `:VaultIndexRebuild`). This is the existing invalidation
behavior and is unchanged.

### Interaction with blink.cmp fuzzy matching

When `parent_prefix` is set, the `get_completions` function returns a
pre-filtered item list. blink.cmp then applies its own fuzzy matching on the
`filterText` of the returned items. Since `filterText` is the full tag string
(e.g., `project/alpha`), and the user has typed `project/` followed by partial
text (e.g., `al`), blink.cmp will fuzzy-match `al` against `project/alpha`.
This works correctly because the typed text after `#` matches against the
`filterText`.

**Potential issue:** blink.cmp's keyword extraction may truncate at `/` if `/`
is not in `iskeyword`. If so, blink.cmp would only match against `al` (the text
after the last keyword boundary), not `project/al`. Since `filterText` is
`project/alpha`, the match would fail unless blink.cmp matches substrings.

**Mitigation:** Step 3 (adding `/` to `iskeyword`) ensures that blink.cmp
treats `project/al` as a single keyword, matching correctly against
`project/alpha`.

## Files Modified

### Modified

1. **`/home/andrew-cmmg/.config/nvim/lua/andrew/vault/completion_tags.lua`**
   - Replace `build()`: Remove dual-ripgrep approach, use vault index
     `tags_with_counts()`. Add `has_children` pre-computation. (~50 lines
     replacing ~95 lines)
   - Replace `get_completions()`: Add prefix detection and hierarchical
     filtering. (~35 lines replacing ~20 lines)
   - Add `get_trigger_characters()`: Return `{ "#", "/" }`. (~3 lines)
   - Restructure module return to capture source before returning. (~5 lines)

2. **`/home/andrew-cmmg/.config/nvim/lua/andrew/plugins/blink-cmp.lua`**
   - Add `/` to the `iskeyword` string in the monkey-patch (line 175).
     Single character addition: `'@,48-57,_,-,;,/,192-255'`

### Unchanged

- **`completion_base.lua`** -- No changes. The factory pattern supports custom
  `get_completions` and `get_trigger_characters` without modification.
- **`vault_index.lua`** -- No changes. The existing `tags_with_counts()` method
  (line 1371) provides exactly the data needed.
- **`tag_tree.lua`** -- No changes. The tree builder is not used by completion
  (it outputs fzf-formatted strings, not completion items). The tag tree picker
  and tag completion are independent features.
- **`tags.lua`** -- No changes. The tag picker and tag operations are unrelated
  to the completion source.
- **`config.lua`** -- No new configuration needed. The hierarchical filtering is
  automatic based on the presence of `/` in the typed text.

## Testing Strategy

### Manual Testing

1. **Basic flat completion (regression):**
   - Open a vault markdown file. Type `#` followed by a few characters.
   - Verify that all tags appear in the completion popup, sorted by frequency.
   - Verify that fuzzy matching works (e.g., `#proj` matches `project/alpha`).
   - Accept a tag and verify the correct text is inserted.

2. **Hierarchical drill-down:**
   - Type `#project/` (with trailing slash).
   - Verify that only immediate children of `project/` appear (e.g.,
     `project/alpha`, `project/beta`), not deeper descendants like
     `project/alpha/phase1`.
   - Type `#project/alpha/` and verify only children of `project/alpha/` appear.
   - Type `#status/` and verify status subtags appear.

3. **Drill-down with partial text:**
   - Type `#project/al` and verify that `project/alpha` appears (fuzzy match
     within the prefix scope).
   - Verify that `project/beta` does not appear (it does not match `al`).

4. **Leaf tag with trailing slash:**
   - Type `#meeting/` where `meeting` has no subtags.
   - Verify an empty completion list (no errors, no stale results).

5. **has_children indicator:**
   - Observe that tags with children show a folder icon (kind = 19) and ` +` in
     the description.
   - Observe that leaf tags show a keyword icon (kind = 14) without ` +`.

6. **Trigger character re-evaluation:**
   - Type `#project` and observe flat completions.
   - Type `/` (making it `#project/`) and observe the completion list immediately
     refreshes to show only children.

7. **iskeyword interaction:**
   - Type `#project/alpha` and verify blink.cmp treats the entire string as a
     single keyword (no split at `/`).
   - Accept the completion and verify `project/alpha` is inserted correctly.

8. **Vault index not ready:**
   - Restart Neovim. Immediately type `#` before the index finishes building.
   - Verify empty completion (no errors).
   - Wait a moment, type `#` again, verify tags appear.

### Regression Testing

9. **Other completion sources unaffected:**
   - Type `[[` and verify wikilink completion still works.
   - Type `[[Note#` and verify heading completion still works.
   - Verify LSP completions work in non-markdown files.
   - Verify frontmatter completion (`type: `, `status: `) still works.

10. **iskeyword side effects:**
    - Verify that `w` motion in normal mode does not treat `/` as a word
      character (the monkey-patch restores `iskeyword` after each blink-cmp
      invocation).
    - Verify that other completion sources in markdown (snippets, path, buffer)
      are unaffected by `/` in `iskeyword`.

### Automated Verification

11. **Tag count accuracy:**
    - Run `:VaultIndexStatus` to verify tag counts.
    - Compare `tags_with_counts()` output with the completion items to ensure
      counts match.

12. **Child detection correctness:**
    - For a known tag hierarchy (e.g., `project` with children `project/alpha`,
      `project/beta`), verify that `has_children` is true for `project` and
      false for `project/alpha` (if it has no further children).

13. **Performance:**
    - With a vault containing 500+ unique tags, type `#` and measure time to
      popup. Target: < 50ms.
    - Type `#project/` and measure time to re-filter. Target: < 10ms.
