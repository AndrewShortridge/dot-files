# Tag Hierarchy Visualization

## Problem Statement

The vault plugin tracks tags with hierarchical structure (e.g., `#project/alpha`,
`#status/in-progress`, `#type/meeting/standup`) throughout the indexing and
highlighting systems. The vault index already expands parent segments
(`project/alpha` produces both `project/alpha` and `project`), and
`tag_highlights.lua` colors tags by category prefix. However, the only way to
browse tags is the flat `fzf-lua` picker in `tags.lua:tags()`, which lists every
tag alphabetically without any indication of nesting depth, parent-child
relationships, or per-level file counts.

Obsidian's tag pane provides a collapsible tree view where:
- Top-level prefixes (e.g., `project`, `status`, `type`) appear as root nodes.
- Child segments nest under their parents with indentation.
- Each node shows the count of notes tagged at that level.
- Expanding a node reveals its children; collapsing hides them.
- Clicking a leaf tag opens a search for notes containing it.

The current flat picker loses all of this structural information. A user with
hundreds of tags organized into hierarchies has no way to explore the tag
taxonomy, see which branches are most populated, or drill down through levels.

## Current Architecture

### Tag Storage in the Vault Index

`vault_index.lua` is the single source of truth for tag data. The
`_parse_file()` method (line ~490) calls `extract_tags(fm_fields, body)` which:

1. Reads tags from YAML frontmatter (`tags:` field) and inline `#tag` patterns.
2. For each tag, calls `add_tag_with_parents(set, tag)` (line 303-311) which
   splits on `/` and stores every ancestor segment. So `#project/alpha/phase1`
   produces entries for `project/alpha/phase1`, `project/alpha`, and `project`.
3. Returns a sorted flat list of unique tag strings stored in
   `entry.tags` (a string array per file).

The `all_tags()` method (line 1248-1261) iterates all index entries, merges
their tag arrays into a deduplicated set, sorts, and returns a flat list of
strings.

**Key observation:** The parent-expansion already happens at index time. If
three files have `#project/alpha` and two have `#project/beta`, then `all_tags()`
returns `{"project", "project/alpha", "project/beta", ...}`. The hierarchical
structure is *implicit* in the `/`-separated strings -- it just needs to be
parsed and displayed.

### Current Tag Picker (`tags.lua`)

```lua
function M.tags()
  collect_tags(function(tags)
    if #tags == 0 then
      vim.notify("Vault: no tags found", vim.log.levels.INFO)
      return
    end
    local fzf = require("fzf-lua")
    fzf.fzf_exec(tags, {
      prompt = "Vault tags> ",
      actions = {
        ["default"] = function(selected)
          if selected and selected[1] then
            M.search_tag(selected[1])
          end
        end,
      },
    })
  end)
end
```

This is a flat string list passed to `fzf.fzf_exec`. No indentation, no file
counts, no tree structure.

### Tag Highlight Categories (`config.lua` + `tag_highlights.lua`)

`config.lua` defines category prefix -> highlight group mappings:

```lua
M.tag_highlights = {
  categories = {
    { prefix = "project/", highlight = "VaultTagProject" },
    { prefix = "status/",  highlight = "VaultTagStatus" },
    { prefix = "type/",    highlight = "VaultTagType" },
    { prefix = "person/",  highlight = "VaultTagPerson" },
  },
}
```

`tag_highlights.lua` uses these to color inline `#tag` text in buffers. The
hierarchy visualization can reuse these same color associations to give
consistent visual identity to tag categories across the picker and the editor.

### Existing Picker Patterns

The codebase uses `fzf-lua` exclusively for picker UIs. Key patterns:

- **ANSI-colored entries:** `connections.lua` uses `--ansi` + `--delimiter` +
  `--with-nth` to show formatted entries while keeping a hidden key for actions.
- **Multi-select:** Graph filter tag pickers use `--multi` for batch selection.
- **Two-step pickers:** `tags.lua` already implements a two-step flow (pick tag,
  then show matching notes via `search_tag()`).
- **No custom buffer pickers exist** -- all pickers use `fzf.fzf_exec()`.

## Proposed Solution

### Overview

Add a new **tag hierarchy picker** accessible via `:VaultTagTree` and
`<leader>vgt` (or a new binding to avoid collision with the existing tag
highlight toggle on `<leader>vgt`; see Key Design Decisions). The picker
presents tags in an indented tree view using `fzf-lua` with ANSI formatting.
Each entry shows:

```
▸ project                          (12)
  ▸ alpha                          (5)
    ○ phase1                       (2)
    ○ phase2                       (3)
  ▸ beta                           (7)
○ status                           (4)
  ○ in-progress                    (2)
  ○ complete                       (2)
```

Where `▸` indicates a node with children (expandable) and `○` indicates a leaf
node. The number in parentheses is the count of files tagged with that exact
tag (not including children).

### Core Data Structure: Tag Tree

Build a tree from the flat tag list:

```lua
---@class TagTreeNode
---@field name string       Segment name (e.g., "alpha", not "project/alpha")
---@field full_tag string   Full slash-separated path (e.g., "project/alpha")
---@field count number      Files directly tagged with this exact tag
---@field total number      Files tagged with this tag or any descendant
---@field children table<string, TagTreeNode>  Child nodes keyed by segment
---@field depth number      Nesting level (0 = root)
```

### Tree Building Algorithm

```lua
--- Build a tag tree from the vault index.
---@param idx VaultIndex
---@return table<string, TagTreeNode> root_children
---@return table<string, number> tag_counts  full_tag -> direct file count
local function build_tag_tree(idx)
  -- Step 1: Count files per tag (direct matches only)
  local tag_counts = {}
  for _, entry in pairs(idx.files) do
    for _, tag in ipairs(entry.tags) do
      tag_counts[tag] = (tag_counts[tag] or 0) + 1
    end
  end

  -- Step 2: Build tree structure
  local root = {}  -- table<string, TagTreeNode>

  for tag, count in pairs(tag_counts) do
    local segments = vim.split(tag, "/", { plain = true })
    local current_level = root
    local path_so_far = ""

    for i, segment in ipairs(segments) do
      path_so_far = i == 1 and segment or (path_so_far .. "/" .. segment)

      if not current_level[segment] then
        current_level[segment] = {
          name = segment,
          full_tag = path_so_far,
          count = 0,
          total = 0,
          children = {},
          depth = i - 1,
        }
      end

      local node = current_level[segment]
      if i == #segments then
        node.count = count
      end

      current_level = node.children
    end
  end

  -- Step 3: Compute totals (bottom-up)
  local function compute_totals(children)
    for _, node in pairs(children) do
      compute_totals(node.children)
      local child_total = 0
      for _, child in pairs(node.children) do
        child_total = child_total + child.total
      end
      node.total = node.count + child_total
    end
  end
  compute_totals(root)

  return root, tag_counts
end
```

### Flattening for fzf-lua Display

Since `fzf-lua` operates on a flat string list, the tree must be flattened into
indented, ANSI-colored strings with hidden metadata for action handling.

```lua
--- Flatten the tree into display entries for fzf-lua.
---@param root table<string, TagTreeNode>
---@param collapsed table<string, boolean>  Set of collapsed full_tags
---@return string[] entries   ANSI-formatted display strings
---@return table<number, TagTreeNode> entry_map  index -> node
local function flatten_tree(root, collapsed)
  local entries = {}
  local entry_map = {}

  -- Sort children alphabetically at each level
  local function sorted_keys(tbl)
    local keys = {}
    for k in pairs(tbl) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
  end

  local function walk(children, depth)
    for _, key in ipairs(sorted_keys(children)) do
      local node = children[key]
      local has_children = next(node.children) ~= nil
      local is_collapsed = collapsed[node.full_tag] or false

      -- Build display line
      local indent = string.rep("  ", depth)
      local icon = has_children
        and (is_collapsed and "▸ " or "▾ ")
        or "  "

      -- Color the tag name based on category
      local colored_name = colorize_tag(node.name, node.full_tag)

      -- Right-align the count
      local count_str = "(" .. node.count .. ")"
      if node.count ~= node.total then
        count_str = "(" .. node.count .. "/" .. node.total .. ")"
      end

      local entry = string.format(
        "%s\t%s%s%s  %s",
        node.full_tag,             -- hidden key (before delimiter)
        indent,
        icon,
        colored_name,
        dim(count_str)
      )

      entries[#entries + 1] = entry
      entry_map[#entries] = node

      -- Recurse into children if not collapsed
      if has_children and not is_collapsed then
        walk(node.children, depth + 1)
      end
    end
  end

  walk(root, 0)
  return entries, entry_map
end
```

### ANSI Color Helpers

```lua
local ANSI = {
  reset = "\27[0m",
  bold = "\27[1m",
  dim = "\27[2m",
  blue = "\27[34m",
  green = "\27[32m",
  yellow = "\27[33m",
  cyan = "\27[36m",
  magenta = "\27[35m",
  white = "\27[37m",
}

--- Map highlight group names to ANSI escape sequences.
local HL_TO_ANSI = {
  VaultTagProject = ANSI.blue .. ANSI.bold,
  VaultTagStatus  = ANSI.green .. ANSI.bold,
  VaultTagType    = ANSI.yellow .. ANSI.bold,
  VaultTagPerson  = ANSI.cyan .. ANSI.bold,
  VaultTag        = ANSI.magenta .. ANSI.bold,
}

--- Apply ANSI color to a tag name based on its category.
---@param name string   Display segment name
---@param full_tag string  Full tag path for category matching
---@return string
local function colorize_tag(name, full_tag)
  local config = require("andrew.vault.config")
  local categories = config.tag_highlights.categories
  local lower = full_tag:lower()

  for _, cat in ipairs(categories) do
    if lower:sub(1, #cat.prefix) == cat.prefix then
      local ansi = HL_TO_ANSI[cat.highlight] or (ANSI.magenta .. ANSI.bold)
      return ansi .. name .. ANSI.reset
    end
  end
  return (ANSI.magenta .. ANSI.bold) .. name .. ANSI.reset
end

local function dim(text)
  return ANSI.dim .. text .. ANSI.reset
end
```

### Picker Interaction Model

The picker supports two interaction modes:

**Mode 1: Static tree (recommended initial implementation)**

The tree is pre-flattened with all nodes expanded. Users filter with fzf's fuzzy
matching, which naturally narrows the visible tree. Selecting an entry triggers
`search_tag()` for that tag.

This is the simplest approach and integrates cleanly with fzf-lua's filtering.

```lua
function M.tag_tree()
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    vim.notify("Vault: index not ready", vim.log.levels.WARN)
    return
  end

  local root, tag_counts = build_tag_tree(idx)
  local entries, entry_map = flatten_tree(root, {})  -- all expanded

  if #entries == 0 then
    vim.notify("Vault: no tags found", vim.log.levels.INFO)
    return
  end

  local fzf = require("fzf-lua")
  fzf.fzf_exec(entries, {
    prompt = "Tag tree> ",
    fzf_opts = {
      ["--ansi"] = "",
      ["--delimiter"] = "\t",
      ["--with-nth"] = "2..",   -- hide the full_tag key
      ["--no-sort"] = "",       -- preserve tree ordering
    },
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          local full_tag = selected[1]:match("^([^\t]+)")
          if full_tag then
            M.search_tag(full_tag)
          end
        end
      end,
    },
  })
end
```

**Mode 2: Interactive collapse/expand (future enhancement)**

A custom buffer with keybindings for `zo`/`zc` (expand/collapse) and persistent
collapse state. This requires a scratch buffer approach instead of fzf-lua, and
is a significant additional complexity. Deferred to a follow-up improvement.

### New Vault Index Method: `tags_with_counts()`

Add a utility method to `vault_index.lua` that returns tag -> file count
mappings without requiring consumers to iterate all files:

```lua
--- Get all tags with their direct file counts.
---@return table<string, number>  tag -> count of files directly tagged
function M.VaultIndex:tags_with_counts()
  local counts = {}
  for _, entry in pairs(self.files) do
    for _, tag in ipairs(entry.tags) do
      counts[tag] = (counts[tag] or 0) + 1
    end
  end
  return counts
end
```

### New Vault Index Method: `files_for_tag()`

Add a method to retrieve files matching a specific tag (including descendant
tags):

```lua
--- Get all files that have a specific tag or any descendant tag.
---@param tag string  The tag to search for (e.g., "project")
---@param exact boolean|nil  If true, only match the exact tag (no descendants)
---@return VaultIndexEntry[]
function M.VaultIndex:files_for_tag(tag, exact)
  local results = {}
  local prefix = tag .. "/"
  for _, entry in pairs(self.files) do
    for _, t in ipairs(entry.tags) do
      if t == tag or (not exact and t:sub(1, #prefix) == prefix) then
        results[#results + 1] = entry
        break
      end
    end
  end
  return results
end
```

## Implementation Steps

### Step 1: Add `tags_with_counts()` and `files_for_tag()` to `vault_index.lua`

Add the two methods described above. These are pure read operations over the
existing index data with no structural changes.

**File:** `lua/andrew/vault/vault_index.lua`

### Step 2: Create the tree builder module

Create a new module `lua/andrew/vault/tag_tree.lua` containing:

- `build_tag_tree(idx)` -- builds the `TagTreeNode` hierarchy
- `flatten_tree(root, collapsed)` -- flattens to display entries
- `colorize_tag(name, full_tag)` -- ANSI color application
- Helper functions for ANSI codes and sorting

This module has no side effects and no `setup()` function -- it is a pure data
transformation library consumed by the picker.

```lua
-- lua/andrew/vault/tag_tree.lua
-- Tag hierarchy tree builder for the vault tag tree picker.

local M = {}

-- ANSI escape codes for fzf-lua display
local ANSI = {
  reset   = "\27[0m",
  bold    = "\27[1m",
  dim     = "\27[2m",
  blue    = "\27[34m",
  green   = "\27[32m",
  yellow  = "\27[33m",
  cyan    = "\27[36m",
  magenta = "\27[35m",
}

local HL_TO_ANSI = {
  VaultTagProject = ANSI.blue .. ANSI.bold,
  VaultTagStatus  = ANSI.green .. ANSI.bold,
  VaultTagType    = ANSI.yellow .. ANSI.bold,
  VaultTagPerson  = ANSI.cyan .. ANSI.bold,
  VaultTag        = ANSI.magenta .. ANSI.bold,
}

---@class TagTreeNode
---@field name string
---@field full_tag string
---@field count number
---@field total number
---@field children table<string, TagTreeNode>
---@field depth number

--- Determine ANSI color for a tag based on its category prefix.
---@param name string
---@param full_tag string
---@return string
function M.colorize_tag(name, full_tag)
  local ok, config = pcall(require, "andrew.vault.config")
  local categories = (ok and config.tag_highlights and config.tag_highlights.categories)
    or {}
  local lower = full_tag:lower()
  for _, cat in ipairs(categories) do
    if lower:sub(1, #cat.prefix) == cat.prefix then
      local ansi = HL_TO_ANSI[cat.highlight] or (ANSI.magenta .. ANSI.bold)
      return ansi .. name .. ANSI.reset
    end
  end
  return ANSI.magenta .. ANSI.bold .. name .. ANSI.reset
end

local function dim(text)
  return ANSI.dim .. text .. ANSI.reset
end

--- Build a tag tree from tag counts.
---@param tag_counts table<string, number>
---@return table<string, TagTreeNode>
function M.build_tree(tag_counts)
  local root = {}

  for tag, count in pairs(tag_counts) do
    local segments = vim.split(tag, "/", { plain = true })
    local current_level = root
    local path_so_far = ""

    for i, segment in ipairs(segments) do
      path_so_far = i == 1 and segment or (path_so_far .. "/" .. segment)
      if not current_level[segment] then
        current_level[segment] = {
          name = segment,
          full_tag = path_so_far,
          count = 0,
          total = 0,
          children = {},
          depth = i - 1,
        }
      end
      local node = current_level[segment]
      if i == #segments then
        node.count = count
      end
      current_level = node.children
    end
  end

  -- Bottom-up totals
  local function compute_totals(children)
    for _, node in pairs(children) do
      compute_totals(node.children)
      local child_total = 0
      for _, child in pairs(node.children) do
        child_total = child_total + child.total
      end
      node.total = node.count + child_total
    end
  end
  compute_totals(root)

  return root
end

--- Flatten the tree into fzf-lua display entries.
---@param root table<string, TagTreeNode>
---@param collapsed table<string, boolean>|nil
---@return string[] entries
function M.flatten(root, collapsed)
  collapsed = collapsed or {}
  local entries = {}

  local function sorted_keys(tbl)
    local keys = {}
    for k in pairs(tbl) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
  end

  local function walk(children, depth)
    for _, key in ipairs(sorted_keys(children)) do
      local node = children[key]
      local has_children = next(node.children) ~= nil
      local is_collapsed = collapsed[node.full_tag] or false

      local indent = string.rep("  ", depth)
      local icon
      if has_children then
        icon = is_collapsed and "▸ " or "▾ "
      else
        icon = "  "
      end

      local colored = M.colorize_tag(node.name, node.full_tag)

      -- Show "direct/total" when they differ, just "count" when equal
      local count_str
      if node.count ~= node.total and has_children then
        count_str = "(" .. node.count .. "/" .. node.total .. ")"
      else
        count_str = "(" .. node.count .. ")"
      end

      entries[#entries + 1] = string.format(
        "%s\t%s%s%s  %s",
        node.full_tag,
        indent,
        icon,
        colored,
        dim(count_str)
      )

      if has_children and not is_collapsed then
        walk(node.children, depth + 1)
      end
    end
  end

  walk(root, 0)
  return entries
end

return M
```

### Step 3: Add `tag_tree()` picker to `tags.lua`

Add the main `M.tag_tree()` function that ties the tree builder to the fzf-lua
picker.

```lua
--- Hierarchical tag tree picker.
--- Shows tags in an indented tree with file counts per level.
--- Selecting a tag runs search_tag() to find all notes with that tag.
function M.tag_tree()
  local vault_index = require("andrew.vault.vault_index")
  local tag_tree = require("andrew.vault.tag_tree")

  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    vim.notify("Vault: index not ready", vim.log.levels.WARN)
    return
  end

  local tag_counts = idx:tags_with_counts()
  if not next(tag_counts) then
    vim.notify("Vault: no tags found", vim.log.levels.INFO)
    return
  end

  local root = tag_tree.build_tree(tag_counts)
  local entries = tag_tree.flatten(root)

  local fzf = require("fzf-lua")
  fzf.fzf_exec(entries, {
    prompt = "Tag tree> ",
    fzf_opts = {
      ["--ansi"] = "",
      ["--delimiter"] = "\t",
      ["--with-nth"] = "2..",
      ["--no-sort"] = "",
      ["--header"] = "  ▸/▾ = has children  (direct/total)  Enter = search tag",
    },
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          local full_tag = selected[1]:match("^([^\t]+)")
          if full_tag then
            M.search_tag(full_tag)
          end
        end
      end,
    },
  })
end
```

### Step 4: Register command and keymap

In `tags.lua:setup()`, add:

```lua
vim.api.nvim_create_user_command("VaultTagTree", function()
  M.tag_tree()
end, {
  desc = "Browse vault tags in a hierarchical tree view",
})

vim.keymap.set("n", "<leader>vfT", function()
  M.tag_tree()
end, { desc = "Find: tag tree", silent = true })
```

The keybinding uses `<leader>vfT` (capital T) to sit alongside the existing
`<leader>vft` (lowercase t) for the flat tag picker.

### Step 5: Update config.lua with tag_tree configuration

Add a new config section:

```lua
-- ---------------------------------------------------------------------------
-- Tag tree picker
-- ---------------------------------------------------------------------------
M.tag_tree = {
  -- Show file counts as "direct/total" for branch nodes.
  -- When false, shows only direct count.
  show_totals = true,

  -- Sort order for tree nodes at each level.
  -- "alpha" = alphabetical, "count" = by file count (descending)
  sort = "alpha",

  -- Minimum file count to display a tag in the tree.
  -- Set to 0 to show all tags including those with 0 direct files.
  min_count = 0,
}
```

### Step 6: Integrate sort and min_count config into tree builder

Update `tag_tree.lua:flatten()` to respect the config options:

```lua
-- In sorted_keys():
local function sorted_keys(tbl)
  local keys = {}
  for k in pairs(tbl) do keys[#keys + 1] = k end

  local ok, config = pcall(require, "andrew.vault.config")
  local sort_mode = (ok and config.tag_tree and config.tag_tree.sort) or "alpha"

  if sort_mode == "count" then
    table.sort(keys, function(a, b)
      return tbl[a].total > tbl[b].total
    end)
  else
    table.sort(keys)
  end
  return keys
end

-- In walk(), skip nodes below min_count:
local min_count = (ok and config.tag_tree and config.tag_tree.min_count) or 0
if node.total < min_count and node.count < min_count then
  goto continue
end
```

## Key Design Decisions

### 1. UI Framework: fzf-lua (not custom buffer or telescope)

**Decision:** Use `fzf-lua` with ANSI formatting.

**Rationale:**
- Every other picker in the vault module uses fzf-lua. Consistency is paramount.
- fzf's fuzzy filtering works naturally on the flattened tree text, letting
  users type a tag name to narrow the view.
- The `--ansi` + `--delimiter` + `--with-nth` pattern is already proven in
  `connections.lua`.
- A custom scratch buffer would require implementing selection, scrolling,
  highlighting, and keybinding handling from scratch -- significant complexity
  for marginal gain in the initial implementation.
- Interactive collapse/expand can be added as a follow-up using a custom buffer
  if the fzf approach proves insufficient.

**Trade-off:** fzf cannot dynamically re-render the tree (no expand/collapse
interaction within a single picker invocation). The tree is displayed fully
expanded, and fzf's filtering substitutes for collapse. This is acceptable for
the initial implementation because:
- Most tag hierarchies are 2-3 levels deep (e.g., `project/alpha/phase1`).
- fzf filtering is faster than manual expand/collapse for finding a specific tag.
- The `--no-sort` flag preserves the tree ordering, so the visual structure
  remains intact even with filtering.

### 2. Count Display: direct/total

**Decision:** Show `(direct/total)` for branch nodes, `(count)` for leaf nodes.

Example:
```
▾ project   (3/15)     ← 3 files tagged exactly #project, 15 total including children
  ▾ alpha   (0/8)      ← no files tagged #project/alpha, 8 in children
    phase1  (5)         ← 5 files tagged exactly #project/alpha/phase1
    phase2  (3)
  beta      (7)
```

**Rationale:** The dual count answers two different questions:
- "How many files are tagged at this exact level?" (direct count)
- "How many files are in this entire branch?" (total count)

The parent-expansion in `add_tag_with_parents()` means that a file tagged
`#project/alpha` also has the `project` tag in its entry. The direct count
correctly reflects this: if 3 files have `#project` as an explicit tag (not
just via parent expansion), the direct count is 3.

However, because of parent expansion, the direct count for `project` already
includes files that have any `project/*` child tag. This means the "direct"
count for branch nodes is actually the total count of all files in that subtree.
The `total` computed by bottom-up aggregation would be redundant in this case.

**Important clarification:** Because `add_tag_with_parents()` stores parent
segments in each file's tag list, the `count` for a parent tag like `project`
already includes all files with any `project/*` descendant. This means:

- For **leaf tags** (no children): `count` is the number of files with that
  exact tag.
- For **branch tags**: `count` includes files tagged with that tag or any
  descendant (due to parent expansion).
- The `total` field (bottom-up sum of children) will often match `count` for
  branch nodes.

Given this, the implementation should detect when `count == total` and show
only `(count)` to avoid redundant display. The `(direct/total)` format is only
shown when they differ, which occurs when a tag has both direct uses and child
tags that have additional unique files.

### 3. Keybinding Namespace

**Decision:** Use `<leader>vfT` (capital T) for the tree picker.

**Rationale:**
- `<leader>vft` (lowercase) is already taken by the flat tag picker.
- `<leader>vf` is the "find" prefix in the vault keymap namespace.
- Capital T naturally suggests "Tree" while lowercase t suggests "tags".
- Both pickers serve different purposes and should coexist: the flat picker is
  faster for known tags; the tree picker is better for exploration.
- `<leader>vgt` is taken by the tag highlight toggle (in `tag_highlights.lua`).

### 4. Tree Icons

**Decision:** Use Unicode box-drawing-adjacent characters:
- `▾` (U+25BE) for expanded branch nodes
- `▸` (U+25B8) for collapsed branch nodes
- Two spaces (`  `) for leaf nodes

**Rationale:** These characters are widely supported in monospace fonts, render
at consistent widths, and are visually recognizable as tree disclosure triangles.
They match the convention used in many file explorers (VS Code, nvim-tree, etc.).

### 5. Sorting Strategy

**Decision:** Alphabetical by default, with a `config.tag_tree.sort` option for
count-based sorting.

**Rationale:** Alphabetical sorting preserves the natural taxonomy structure
(e.g., `status/blocked`, `status/complete`, `status/in-progress` appear in
order). Count-based sorting is useful for discovering which tags are most
populated but disrupts the logical grouping.

## Edge Cases

### Empty Tags

If the vault has no tags, `tag_counts` is empty, and the picker shows a
notification: "Vault: no tags found". No tree is built.

### Parent-Only Tags (Zero Direct Usage)

Due to parent expansion, a tag like `project` may appear in the index even
though no file explicitly uses `#project` -- it is always used as a prefix
(e.g., `#project/alpha`). In this case, `project` has a non-zero count because
parent expansion adds it to every file that has a `project/*` child tag. The
tree builder handles this correctly: the node exists with its real count.

If `min_count` is set to filter low-count tags, parent-only nodes should still
be shown if any of their children meet the threshold. The filtering should check
`node.total >= min_count` (not just `node.count`), ensuring that structural
parent nodes are preserved when they have qualifying children.

### Deeply Nested Hierarchies

Tags like `a/b/c/d/e/f` produce 6 levels of nesting. At 2 spaces per level,
this means 10 characters of leading indentation. With fzf's default window
width, this is manageable. However, the implementation should:

1. Not impose an artificial depth limit (the tag structure is user-defined).
2. Use consistent 2-space indentation that renders well at any depth.
3. Rely on fzf's horizontal scrolling for extremely wide entries.

### Tags with Special Characters

The tag extraction regex in `vault_index.lua` is:
```lua
for tag in clean_body:gmatch("#([%w_%-][%w_%-/]*)") do
```

This allows: alphanumeric, underscore, hyphen, and slash characters. Tags
cannot contain spaces, dots, or other special characters. The tree builder
inherits this constraint -- slashes are the only hierarchy separator, and no
special escaping is needed.

**Edge case: trailing slash.** A tag like `project/` (empty final segment)
would produce an empty string as a tree segment. The builder should skip empty
segments:

```lua
local segments = vim.split(tag, "/", { plain = true })
segments = vim.tbl_filter(function(s) return s ~= "" end, segments)
```

### Single-Segment Tags (No Hierarchy)

Tags without slashes (e.g., `meeting`, `draft`) appear as root-level leaf
nodes with no children. They display as:

```
  meeting    (8)
  draft      (3)
```

This is the same as the flat picker but with consistent formatting.

### Index Not Ready

If the vault index is still building when the user invokes the tree picker,
show a warning and return early. Do not fall back to the flat picker or block
waiting for the index.

### Very Large Tag Sets

A vault with 500+ unique tags will produce a long tree. fzf handles this well
natively -- the user can type to filter, scroll with arrows/mouse, and
`page-up`/`page-down`. No pagination is needed on the Lua side.

### Duplicate Segment Names in Different Branches

Tags like `project/alpha` and `status/alpha` produce separate `alpha` nodes
under different parents. The `full_tag` field disambiguates them, and the tree
structure naturally separates them into different branches.

## Files Modified

### New Files

1. **`lua/andrew/vault/tag_tree.lua`**
   Pure data transformation module. Contains tree building, flattening, and ANSI
   colorization. No side effects, no `setup()` function, no autocommands.

### Modified Files

2. **`lua/andrew/vault/vault_index.lua`**
   - Add `VaultIndex:tags_with_counts()` method (~10 lines)
   - Add `VaultIndex:files_for_tag(tag, exact)` method (~15 lines)

3. **`lua/andrew/vault/tags.lua`**
   - Add `M.tag_tree()` function (~35 lines)
   - Add `:VaultTagTree` command registration in `setup()` (~5 lines)
   - Add `<leader>vfT` keymap in `setup()` (~3 lines)

4. **`lua/andrew/vault/config.lua`**
   - Add `M.tag_tree` configuration section (~10 lines)

### Unchanged Files

- **`tag_highlights.lua`** -- No changes. The highlight groups and category
  mappings are read from `config.lua` by the tree builder; no coupling needed.
- **`pickers.lua`** -- No changes. This module handles project/area/domain
  pickers, not tag pickers.
- **`engine.lua`** -- No changes. The tree picker uses `vault_index` directly,
  not engine's fzf helpers (the tree entries are pre-formatted, not file paths).

## Testing Plan

### Manual Verification

1. **Basic tree rendering:**
   - Open a vault with hierarchical tags (e.g., `#project/alpha`,
     `#project/beta`, `#status/complete`, `#meeting`).
   - Run `:VaultTagTree`.
   - Verify the tree displays with correct indentation, icons, colors, and
     counts.
   - Verify root-level tags without children show as leaf nodes.
   - Verify multi-level hierarchies render with proper nesting.

2. **Tag selection action:**
   - Select a tag from the tree picker.
   - Verify `search_tag()` opens an fzf grep for that exact tag.
   - Verify selecting a parent tag (e.g., `project`) searches for `#project`.
   - Verify selecting a leaf tag (e.g., `project/alpha/phase1`) searches for
     the full tag.

3. **File count accuracy:**
   - For a known tag with a known number of files, verify the count shown in
     the tree matches the actual number of files.
   - Add a tag to a file, run `:VaultIndexRebuild`, reopen the tree picker, and
     verify the count incremented.
   - Remove a tag, rebuild, and verify the count decremented.

4. **fzf filtering:**
   - Open the tree picker and type a tag segment (e.g., "alpha").
   - Verify the fzf filter narrows to entries containing that text.
   - Verify the tree structure (indentation, icons) remains visually coherent
     in filtered results.

5. **Empty vault / no tags:**
   - In a vault with no tags, run `:VaultTagTree`.
   - Verify the "no tags found" notification appears.
   - Verify no error or empty picker window.

6. **ANSI color consistency:**
   - Verify `project/*` tags appear in blue (matching `VaultTagProject`).
   - Verify `status/*` tags appear in green (matching `VaultTagStatus`).
   - Verify uncategorized tags appear in the default magenta.
   - Compare colors with inline tag highlights in the buffer to confirm
     consistency.

7. **Config options:**
   - Set `config.tag_tree.sort = "count"` and verify tags are sorted by
     total count descending at each level.
   - Set `config.tag_tree.min_count = 2` and verify tags with fewer than 2
     files are hidden (but their parents are preserved if they have qualifying
     children).

### Automated Testing (Unit-Level)

8. **Tree builder correctness:**
   - Build a tree from known tag counts:
     ```lua
     local counts = {
       ["project"] = 3,
       ["project/alpha"] = 5,
       ["project/beta"] = 2,
       ["status"] = 4,
       ["status/done"] = 1,
       ["meeting"] = 8,
     }
     local root = tag_tree.build_tree(counts)
     ```
   - Assert: `root.project.count == 3`, `root.project.total == 10`,
     `root.project.children.alpha.count == 5`, `root.meeting.count == 8`,
     `root.meeting.total == 8`.

9. **Flatten output:**
   - Flatten the tree built in test 8.
   - Assert: entries are in alphabetical order within each level.
   - Assert: entries contain the correct hidden key before the tab delimiter.
   - Assert: leaf nodes have no `▾`/`▸` icon (just spaces).

10. **Edge case: empty segments:**
    - Build a tree from `{ ["project/"] = 1 }`.
    - Assert: the trailing empty segment is ignored; `project` is a leaf with
      count 1.

11. **Edge case: single tag:**
    - Build a tree from `{ ["standalone"] = 5 }`.
    - Assert: one root entry, no children, count 5.

12. **Performance benchmark:**
    - Generate 1000 unique tags with up to 4 levels of nesting.
    - Time `build_tree()` and `flatten()`.
    - Target: < 10ms combined for 1000 tags.
