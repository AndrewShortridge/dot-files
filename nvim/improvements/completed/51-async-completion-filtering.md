# 51 --- Async Completion Filtering with Cancellation and Debounce

## Motivation

The completion system (`completion.lua`, `completion_tags.lua`,
`completion_frontmatter.lua`, `completion_inline_fields.lua`) iterates the
full `vault_index.files` table synchronously when building completion items.
For large vaults (1000+ notes), this blocks the UI thread for noticeable
periods. Each keystroke that triggers completion (typing inside `[[`, typing
`#`, etc.) can cause the `build()` function to re-scan the entire index
synchronously before returning items to blink.cmp.

The current architecture has two synchronous bottlenecks:

1. **Item building** -- `build()` in each source iterates `pairs(idx.files)`
   in a tight loop, constructing completion items. For a vault with 2000 notes
   where many have aliases, this produces 3000+ items in a single uninterrupted
   Lua loop.
2. **Item re-building on cache miss** -- `completion_base.lua`'s
   `build_items_async()` is named "async" but its callback is invoked
   synchronously within the same `vim.schedule` tick when `opts.build()` calls
   `callback(items)` immediately (which it does when the vault index is ready).
   There is no yielding.

The result: a perceptible UI freeze (50-200ms depending on vault size) on the
first completion trigger after cache invalidation, and on every `build()` call
that must re-scan the index.

---

## Current State Analysis

### File: `lua/andrew/vault/completion_base.lua`

The `create_source()` factory produces blink.cmp-compatible source modules.
Key structure (130 lines):

| Component | Lines | Description |
|-----------|-------|-------------|
| `all_invalidators` | 5-13 | Global list of per-source cache invalidation callbacks |
| `engine.register_cache()` | 16-28 | Registers with central cache registry (name, module, invalidate, stats) |
| `create_source(opts)` | 33-112 | Factory: creates a blink.cmp source with caching, building, invalidation |
| `cached_items` / `cached_vault` | 35-36 | Per-source item cache and vault path guard |
| `building` / `build_generation` | 37-38 | Concurrent-build guard and invalidation counter |
| `build_items_async(callback)` | 50-68 | Calls `opts.build()`, wraps result in `vim.schedule` |
| `source:get_completions(ctx, cb)` | 81-102 | Entry point from blink.cmp; returns cached items or triggers build |
| `M.count_label(count)` | 117-119 | Formats "N note(s)" for label descriptions |
| `M.freq_sort_text(count, name)` | 125-127 | Frequency-based sortText (descending count, then name) |

The `build_items_async` function wraps `opts.build()` in a generation guard
but does **not** yield or chunk the work. When `opts.build()` calls
`callback()` synchronously (as it does for all vault index sources when the
index is ready), the entire build runs in one uninterrupted tick.

### File: `lua/andrew/vault/completion.lua`

The wikilink completion source (524 lines). The `build` function (lines
130-189) is the primary bottleneck:

```lua
build = function(vault_path, callback)
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()
  if idx and idx:is_ready() then
    local items = {}
    for _, entry in pairs(idx.files) do      -- <-- SYNCHRONOUS full scan
      -- ... build item for basename ...
      items[#items + 1] = { ... }
      -- ... build items for aliases ...
      if aliases then
        for _, alias in ipairs(alias_list) do
          items[#items + 1] = { ... }
        end
      end
    end
    callback(items)                            -- <-- returns synchronously
    return
  end
  callback({})
end,
```

For a vault with N notes and A total aliases, this loop creates N + A items
synchronously. Each item requires string formatting (`string.format`),
`link_utils.rel_to_stem()`, and `build_description()` calls.

The `get_completions` function (lines 191-364) handles context-dependent
completion (blocks, headings, note names). For the common case of note-name
completion (line 363), it passes the pre-built `items` array directly to the
callback -- this path is fast because filtering is done by blink.cmp's fuzzy
matcher. The bottleneck is purely in `build()`.

Additional helpers in this file:
- `get_blocks(lines)` (lines 7-9): Wrapper around `block_patterns.extract_from_lines`.
- `truncate_preview(text, max_len)` (lines 11-17): Truncates text with `...` suffix.
- `build_context_lines(lines, target_line, context_width)` (lines 19-29): Builds
  highlighted context (±context_width lines) with `>>> ` prefix for the target.
- `get_headings(lines)` (lines 31-61): Parses buffer headings with content
  preview (up to 8 lines).
- `build_description(fm, rel)` (lines 63-75): Formats "type | tags — rel".
- `resolve_note_via_index(name)` (lines 77-125): Resolves note names via
  vault index with proximity-based disambiguation for duplicate basenames.
- `resolve_item` (lines 366-516): Lazy-loads rich documentation for blocks
  (context lines), headings (section preview), and notes (frontmatter + body).
- Trigger characters: `{ "[", "#", "^" }` (lines 519-521).

### File: `lua/andrew/vault/completion_tags.lua`

The tag completion source (139 lines). Its `build` function (lines 8-63)
calls `idx:tags_with_counts()` (which iterates `idx.files` internally),
then sorts tags, pre-computes parent/child relationships via sorted scan,
and builds items. The `get_completions` function (lines 70-127) implements
hierarchical drill-down: when the typed prefix ends with `/`, it filters
to immediate children (with all-descendants fallback). Trigger characters:
`{ "#", "/" }`. For vaults with 500+ unique tags, this is a secondary
bottleneck.

### File: `lua/andrew/vault/completion_frontmatter.lua`

The frontmatter completion source (180 lines). Iterates `pairs(idx.files)`
to accumulate frontmatter field names and values via an internal
`accumulate_fields()` helper (lines 21-40). A `build_items()` helper
(lines 43-106) constructs two item sets: property names (`kind = 10`,
`insertText = name .. ": "`) and property values (`kind = 12`). Merges
known preset values from config (status, priority, type, maturity). The
`get_completions` function (lines 131-178) detects three contexts: scalar
value (after `key: `), list item value (after `- ` under a key), and
property name (default). Guards against invocation outside frontmatter via
`fm_parser.cursor_in_frontmatter()`. Smaller bottleneck than wikilinks
but still synchronous.

### File: `lua/andrew/vault/completion_inline_fields.lua`

The inline field completion source (182 lines). Similar to frontmatter but
targets inline fields: `[key:: value]`, `(key:: value)`, and standalone
`key:: value`. Iterates `entry.inline_fields` (not `entry.frontmatter`).
The `get_completions` function (lines 113-174) detects six contexts:
standalone value, bracketed value, parenthesized value (3 value contexts),
plus bracketed key (after `[`), parenthesized key (after `(`), and
standalone key at line start (3 key contexts). Standalone key requires ≥2
characters to avoid noise. Trigger character: `":"`. Also synchronous.

### File: `lua/andrew/plugins/blink-cmp.lua`

The blink.cmp configuration (201 lines) registers vault sources as
standard providers. Markdown filetype sources list (line 86):
`["wikilinks", "vault_tags", "vault_frontmatter", "vault_inline_fields", "lsp", "snippets", "path", "buffer", "spell"]`

```lua
wikilinks = {
  name = "Wikilinks",
  module = "andrew.vault.completion",
  min_keyword_length = 0,
  score_offset = 15,
  fallbacks = {},
  transform_items = function(_, items)
    for _, item in ipairs(items) do
      if item.data and item.data.completion_kind == "heading" then
        item.source_name = "Heading"
      elseif item.data and item.data.completion_kind == "block" then
        item.source_name = "Block"
      end
    end
    return items
  end,
},
vault_tags = {
  name = "VaultTags",
  module = "andrew.vault.completion_tags",
  min_keyword_length = 0,
  score_offset = 12,
  fallbacks = {},
},
vault_frontmatter = {
  name = "Frontmatter",
  module = "andrew.vault.completion_frontmatter",
  min_keyword_length = 0,
  score_offset = 14,
  fallbacks = {},
},
vault_inline_fields = {
  name = "Fields",
  module = "andrew.vault.completion_inline_fields",
  min_keyword_length = 0,
  score_offset = 11,
  fallbacks = {},
},
spell = {
  name = "Spell",
  module = "andrew.vault.completion_spell",
  min_keyword_length = 3,
  score_offset = -5,
  fallbacks = {},
},
```

No provider currently sets `async = true`. This means blink.cmp blocks
on each source's `get_completions` call and expects a synchronous or
near-synchronous callback.

The config also includes a custom `config` function (lines 177-196) that
monkey-patches blink.cmp's keyword module to include `;` and `/` in
`iskeyword` (desired: `@,48-57,_,-,;,/,192-255`) for proper snippet
trigger matching.

### blink.cmp Async Source API

Reading the blink.cmp source reveals the following async contract:

1. **`get_completions(ctx, callback)` may return a cancel function.** From
   `lua/blink/cmp/sources/lib/types.lua` (line 14):
   ```lua
   --- @field get_completions? fun(self, context, callback): (fun(): nil) | nil
   ```
   The return value is an optional `cancel` function. If non-nil, blink.cmp
   calls it when the context changes (from `list.lua` line 106:
   `if self.cancel_completions ~= nil then self.cancel_completions() end`).

2. **The `async` provider config flag** (from `sources.lua` line 33):
   ```lua
   --- @field async? boolean | fun(ctx): boolean
   ---   Whether we should show completions before this provider returns
   ```
   When `async = true`, blink.cmp immediately emits an empty/initial item
   list to the UI while waiting for the source's callback (from `list.lua`
   lines 54-55). This prevents the menu from being empty while the source
   works.

3. **The `timeout_ms` config** (default 2000ms): if a non-async source
   hasn't called back within this timeout, blink.cmp treats it as timed out
   and emits empty items.

4. **`is_incomplete_forward` / `is_incomplete_backward`** flags in the
   response control whether blink.cmp re-queries the source on further
   typing. Setting `is_incomplete_forward = true` causes re-fetching as the
   user types more characters (forward direction).

5. **Context validity** (`list.lua` lines 112-126): blink.cmp caches the
   previous list and checks if a new context is a prefix/extension of the
   old one. If the list is valid and not marked incomplete, it reuses cached
   items without re-calling `get_completions`.

**Key insight:** blink.cmp already has a built-in cancellation mechanism.
When the user types another character and the context changes, blink.cmp
calls `list:destroy()` which invokes the cancel function returned by
`get_completions`. This is the correct hook point for coroutine cancellation.

---

## Implementation

### Architecture Overview

The implementation introduces a **coroutine-based chunked builder** in
`completion_base.lua` that all vault completion sources inherit. The design:

```
User types [[  -->  blink.cmp calls get_completions(ctx, callback)
                            |
                    completion_base checks cache
                            |
                  +---------+---------+
                  |                   |
              Cache HIT           Cache MISS
              (gen match)         (or invalidated)
                  |                   |
            Return cached        Start debounce timer (100ms)
            items immediately          |
                                 Timer fires
                                       |
                                 Start coroutine
                                       |
                            +----------+----------+
                            |                     |
                      Process batch          vim.schedule()
                      of N entries           (yield to UI)
                            |                     |
                            +-----<---loop----<---+
                            |
                      Coroutine complete
                            |
                      Call callback(items)
                            |
                      Update cache

User types another char (while coroutine running)
        |
   blink.cmp calls cancel function
        |
   Cancel flag set on coroutine
        |
   Next yield detects cancel, coroutine exits
        |
   New get_completions call starts fresh
```

### Cancellation Mechanism

Each in-flight build gets a `cancelled` flag (a simple boolean in a table
reference). The coroutine checks this flag at each yield point. When
blink.cmp calls the cancel function (returned by `get_completions`), it sets
the flag to `true` and stops the debounce timer. The coroutine sees the flag
on its next `vim.schedule` resume and exits early.

```lua
-- Simplified cancellation flow:
local state = { cancelled = false }

-- The cancel function returned to blink.cmp:
local function cancel()
  state.cancelled = true
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

-- Inside the coroutine:
for i, entry in ipairs(entries) do
  -- ... process entry ...
  if i % batch_size == 0 then
    coroutine.yield()              -- yields to vim.schedule
    if state.cancelled then return end  -- check after resume
  end
end
```

### Result Caching Strategy

Three layers of caching:

1. **Generation-based full cache** -- The existing `cached_items` /
   `cached_vault` mechanism, extended with `cached_generation` tracking
   against `vault_index._generation`. If the generation matches, return
   cached items without any iteration.

2. **Prefix narrowing** -- If the user has typed more characters (prefix is
   a superset of the previous prefix), filter the cached result set
   client-side instead of re-scanning the index. This is purely a blink.cmp
   feature via `is_incomplete_forward = false` (telling blink.cmp it can
   narrow existing results).

3. **Debounce coalescing** -- Rapid keystrokes within the debounce window
   cancel previous timers and only start one build for the final state.

---

### Changes to `lua/andrew/vault/completion_base.lua`

#### Before (lines 33-112, verified against current code, 130 total lines):

```lua
function M.create_source(opts)
  local source = {}
  local cached_items = nil
  local cached_vault = nil
  local building = false
  local build_generation = 0

  local empty = { is_incomplete_forward = false, is_incomplete_backward = false, items = {} }

  local function invalidate()
    cached_items = nil
    build_generation = build_generation + 1
  end

  -- Register this source's invalidator for the shared autocmd
  all_invalidators[#all_invalidators + 1] = invalidate

  local function build_items_async(callback)
    if building then return end
    building = true
    local gen = build_generation
    local vault_path = engine.vault_path

    opts.build(vault_path, function(items)
      vim.schedule(function()
        building = false
        if gen ~= build_generation then
          if callback then callback({}) end
          return
        end
        cached_items = items
        cached_vault = vault_path
        if callback then callback(items) end
      end)
    end)
  end

  function source.new(source_opts)
    local self = setmetatable({}, { __index = source })
    self.opts = source_opts or {}
    build_items_async()
    return self
  end

  function source:enabled()
    return vim.bo.filetype == "markdown"
  end

  function source:get_completions(ctx, callback)
    -- If the source provides a custom get_completions, use it
    if opts.get_completions then
      if cached_items and cached_vault == engine.vault_path then
        opts.get_completions(self, ctx, cached_items, callback)
        return
      end
      build_items_async(function(items)
        opts.get_completions(self, ctx, items or {}, callback)
      end)
      return
    end

    -- Default: return all cached items
    if cached_items and cached_vault == engine.vault_path then
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = cached_items })
      return
    end
    build_items_async(function(items)
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items or {} })
    end)
  end

  -- Passthrough resolve_item if the source defines it
  if opts.resolve_item then
    function source:resolve(item, callback)
      opts.resolve_item(self, item, callback)
    end
  end

  return source
end
```

#### After:

```lua
function M.create_source(opts)
  local source = {}
  local cached_items = nil
  local cached_vault = nil
  local cached_index_gen = nil     -- vault_index._generation at last build
  local build_generation = 0       -- internal invalidation counter

  -- Active async build state (for cancellation)
  local active_state = nil         -- { cancelled: bool, timer: uv_timer|nil }

  local empty = { is_incomplete_forward = false, is_incomplete_backward = false, items = {} }

  -- Configuration
  local debounce_ms = (opts.debounce_ms ~= nil) and opts.debounce_ms or 100
  local batch_size = (opts.batch_size ~= nil) and opts.batch_size or 50

  local function invalidate()
    cached_items = nil
    cached_index_gen = nil
    build_generation = build_generation + 1
  end

  -- Register this source's invalidator for the shared autocmd
  all_invalidators[#all_invalidators + 1] = invalidate

  --- Check if the cached items are still valid against the vault index generation.
  local function cache_valid()
    if not cached_items or cached_vault ~= engine.vault_path then
      return false
    end
    -- Check vault index generation for staleness
    local vault_index = package.loaded["andrew.vault.vault_index"]
    if vault_index then
      local idx = vault_index.current()
      if idx and idx._generation ~= cached_index_gen then
        return false
      end
    end
    return true
  end

  --- Cancel any in-flight async build.
  local function cancel_active()
    if active_state then
      active_state.cancelled = true
      if active_state.timer then
        active_state.timer:stop()
        if not active_state.timer:is_closing() then
          active_state.timer:close()
        end
        active_state.timer = nil
      end
      active_state = nil
    end
  end

  --- Build items using a coroutine that yields every batch_size entries.
  --- @param callback fun(items: table[])
  --- @return fun() cancel  Cancel function for blink.cmp
  local function build_items_async(callback)
    cancel_active()

    local state = { cancelled = false, timer = nil }
    active_state = state

    local gen = build_generation
    local vault_path = engine.vault_path

    -- If the source provides a chunked build, use the coroutine path.
    -- Otherwise fall back to the original synchronous build.
    if not opts.build_iter then
      -- Legacy synchronous build (for sources that haven't migrated)
      state.timer = vim.uv.new_timer()
      state.timer:start(debounce_ms, 0, vim.schedule_wrap(function()
        if state.timer then
          state.timer:stop()
          if not state.timer:is_closing() then
            state.timer:close()
          end
          state.timer = nil
        end
        if state.cancelled or gen ~= build_generation then
          if callback then callback({}) end
          return
        end
        opts.build(vault_path, function(items)
          if state.cancelled or gen ~= build_generation then
            if callback then callback({}) end
            return
          end
          -- Update cache with generation tracking
          local vault_index = package.loaded["andrew.vault.vault_index"]
          if vault_index then
            local idx = vault_index.current()
            if idx then cached_index_gen = idx._generation end
          end
          cached_items = items
          cached_vault = vault_path
          active_state = nil
          if callback then callback(items) end
        end)
      end))
      return function() cancel_active() end
    end

    -- Coroutine-based chunked build
    state.timer = vim.uv.new_timer()
    state.timer:start(debounce_ms, 0, vim.schedule_wrap(function()
      if state.timer then
        state.timer:stop()
        if not state.timer:is_closing() then
          state.timer:close()
        end
        state.timer = nil
      end
      if state.cancelled or gen ~= build_generation then
        if callback then callback({}) end
        return
      end

      local items = {}
      local iter = opts.build_iter(vault_path)
      if not iter then
        cached_items = items
        cached_vault = vault_path
        active_state = nil
        if callback then callback(items) end
        return
      end

      local co = coroutine.create(function()
        local count = 0
        for item in iter do
          items[#items + 1] = item
          count = count + 1
          if count % batch_size == 0 then
            coroutine.yield()
          end
        end
      end)

      local function step()
        if state.cancelled or gen ~= build_generation then
          active_state = nil
          return
        end
        local ok, err = coroutine.resume(co)
        if not ok then
          vim.schedule(function()
            vim.notify("completion build error: " .. tostring(err), vim.log.levels.WARN)
          end)
          active_state = nil
          if callback then callback({}) end
          return
        end
        if coroutine.status(co) == "dead" then
          -- Coroutine finished: update cache and deliver items
          local vault_index = package.loaded["andrew.vault.vault_index"]
          if vault_index then
            local idx = vault_index.current()
            if idx then cached_index_gen = idx._generation end
          end
          cached_items = items
          cached_vault = vault_path
          active_state = nil
          if callback then callback(items) end
        else
          -- Yield: schedule next batch on the next event loop tick
          vim.schedule(step)
        end
      end

      step()
    end))

    return function() cancel_active() end
  end

  function source.new(source_opts)
    local self = setmetatable({}, { __index = source })
    self.opts = source_opts or {}
    -- Pre-warm the cache (fire and forget)
    build_items_async()
    return self
  end

  function source:enabled()
    return vim.bo.filetype == "markdown"
  end

  function source:get_completions(ctx, callback)
    -- If the source provides a custom get_completions, use it
    if opts.get_completions then
      if cache_valid() then
        opts.get_completions(self, ctx, cached_items, callback)
        return
      end
      local cancel = build_items_async(function(items)
        opts.get_completions(self, ctx, items or {}, callback)
      end)
      return cancel
    end

    -- Default: return all cached items
    if cache_valid() then
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = cached_items })
      return
    end
    local cancel = build_items_async(function(items)
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items or {} })
    end)
    return cancel
  end

  -- Passthrough resolve_item if the source defines it
  if opts.resolve_item then
    function source:resolve(item, callback)
      opts.resolve_item(self, item, callback)
    end
  end

  return source
end
```

**Key differences from the original:**

1. `cached_index_gen` tracks `vault_index._generation` so cache validity is
   checked without relying solely on the external `invalidate()` call. If
   the vault index rebuilds (incrementing `_generation`), the cache is
   automatically stale.

2. `cancel_active()` stops any in-flight debounce timer and sets the
   `cancelled` flag on the active coroutine state.

3. `build_items_async()` now returns a cancel function, which is propagated
   through `get_completions()` back to blink.cmp (matching the
   `(fun(): nil) | nil` return type in the blink.cmp source API).

4. The new `build_iter` option allows sources to provide an iterator-based
   builder that yields items one at a time, enabling coroutine chunking.
   Sources that only provide `build` continue to work via the legacy path
   (still debounced, still cancellable via the timer, but not chunked).

5. Debounce timer (default 100ms) prevents thrashing on rapid keystrokes.

---

### Changes to `lua/andrew/vault/completion.lua`

Add a `build_iter` alongside the existing `build` function. The factory in
`completion_base.lua` prefers `build_iter` when present.

#### Before (lines 129-189, the source creation, 524 total lines):

```lua
local source = base.create_source({
  build = function(vault_path, callback)
    -- Fast path: use vault index if ready
    local vault_index = require("andrew.vault.vault_index")
    local idx = vault_index.current()
    if idx and idx:is_ready() then
      local items = {}
      for _, entry in pairs(idx.files) do
        local rel = entry.rel_path
        local name = link_utils.rel_to_stem(rel)
        local basename = entry.basename
        local mtime = entry.mtime or 0
        local fm = entry.frontmatter

        items[#items + 1] = {
          label = basename,
          insertText = basename .. "]]",
          filterText = name,
          kind = 18,
          sortText = string.format("%010d", 9999999999 - mtime),
          labelDetails = {
            description = build_description(fm, rel),
          },
          data = {
            rel_path = rel,
            abs_path = entry.abs_path,
          },
        }

        -- Add alias completion items
        local aliases = entry.aliases
        if aliases then
          local alias_list = type(aliases) == "table" and aliases or { aliases }
          for _, alias in ipairs(alias_list) do
            alias = vim.trim(tostring(alias))
            if alias ~= "" and alias ~= basename then
              items[#items + 1] = {
                label = alias,
                insertText = basename .. "]]",
                filterText = alias .. " " .. name,
                kind = 18,
                sortText = string.format("%010d", 9999999999 - mtime),
                labelDetails = {
                  description = "(alias) " .. build_description(fm, rel),
                },
                data = {
                  rel_path = rel,
                  abs_path = entry.abs_path,
                },
              }
            end
          end
        end
      end
      callback(items)
      return
    end

    -- Index not ready yet; return empty
    callback({})
  end,
  -- ... get_completions, resolve_item ...
})
```

#### After:

```lua
local source = base.create_source({
  -- Legacy build retained for backward compatibility (used if build_iter
  -- is somehow unavailable, e.g., during testing).
  build = function(vault_path, callback)
    local vault_index = require("andrew.vault.vault_index")
    local idx = vault_index.current()
    if idx and idx:is_ready() then
      local items = {}
      for _, entry in pairs(idx.files) do
        local rel = entry.rel_path
        local name = link_utils.rel_to_stem(rel)
        local basename = entry.basename
        local mtime = entry.mtime or 0
        local fm = entry.frontmatter

        items[#items + 1] = {
          label = basename,
          insertText = basename .. "]]",
          filterText = name,
          kind = 18,
          sortText = string.format("%010d", 9999999999 - mtime),
          labelDetails = {
            description = build_description(fm, rel),
          },
          data = {
            rel_path = rel,
            abs_path = entry.abs_path,
          },
        }

        local aliases = entry.aliases
        if aliases then
          local alias_list = type(aliases) == "table" and aliases or { aliases }
          for _, alias in ipairs(alias_list) do
            alias = vim.trim(tostring(alias))
            if alias ~= "" and alias ~= basename then
              items[#items + 1] = {
                label = alias,
                insertText = basename .. "]]",
                filterText = alias .. " " .. name,
                kind = 18,
                sortText = string.format("%010d", 9999999999 - mtime),
                labelDetails = {
                  description = "(alias) " .. build_description(fm, rel),
                },
                data = {
                  rel_path = rel,
                  abs_path = entry.abs_path,
                },
              }
            end
          end
        end
      end
      callback(items)
      return
    end
    callback({})
  end,

  --- Iterator-based builder for coroutine chunking.
  --- Returns a stateful iterator that yields one completion item per call.
  --- Returns nil when the vault index is not ready.
  ---@param vault_path string
  ---@return (fun(): table|nil)|nil
  build_iter = function(vault_path)
    local vault_index = require("andrew.vault.vault_index")
    local idx = vault_index.current()
    if not idx or not idx:is_ready() then return nil end

    -- Snapshot the files table keys so pairs() ordering is deterministic
    -- and the iterator is safe against concurrent index mutations.
    local keys = {}
    for rel_path in pairs(idx.files) do
      keys[#keys + 1] = rel_path
    end

    local key_idx = 0
    local alias_queue = {}   -- pending alias items for the current entry
    local alias_qi = 0

    return function()
      -- Drain any pending alias items first
      while alias_qi < #alias_queue do
        alias_qi = alias_qi + 1
        return alias_queue[alias_qi]
      end

      -- Advance to next file entry
      key_idx = key_idx + 1
      if key_idx > #keys then return nil end

      local rel_path = keys[key_idx]
      local entry = idx.files[rel_path]
      if not entry then return nil end  -- entry removed mid-iteration

      local rel = entry.rel_path
      local name = link_utils.rel_to_stem(rel)
      local basename = entry.basename
      local mtime = entry.mtime or 0
      local fm = entry.frontmatter
      local desc = build_description(fm, rel)
      local sort = string.format("%010d", 9999999999 - mtime)

      -- Queue alias items for this entry
      alias_queue = {}
      alias_qi = 0
      local aliases = entry.aliases
      if aliases then
        local alias_list = type(aliases) == "table" and aliases or { aliases }
        for _, alias in ipairs(alias_list) do
          alias = vim.trim(tostring(alias))
          if alias ~= "" and alias ~= basename then
            alias_queue[#alias_queue + 1] = {
              label = alias,
              insertText = basename .. "]]",
              filterText = alias .. " " .. name,
              kind = 18,
              sortText = sort,
              labelDetails = {
                description = "(alias) " .. desc,
              },
              data = {
                rel_path = rel,
                abs_path = entry.abs_path,
              },
            }
          end
        end
      end

      -- Return the primary item for this entry
      return {
        label = basename,
        insertText = basename .. "]]",
        filterText = name,
        kind = 18,
        sortText = sort,
        labelDetails = {
          description = desc,
        },
        data = {
          rel_path = rel,
          abs_path = entry.abs_path,
        },
      }
    end
  end,

  get_completions = function(self, ctx, items, callback)
    -- ... unchanged from current implementation ...
  end,

  resolve_item = function(self, item, callback)
    -- ... unchanged from current implementation ...
  end,
})
```

The `get_completions` and `resolve_item` functions remain unchanged. Only
the item-building path is modified. The `build_iter` function returns a
stateful iterator that yields one completion item per call (primary item
first, then aliases). The coroutine in `completion_base.lua` calls this
iterator in a loop, yielding every `batch_size` items.

---

### Changes to `lua/andrew/vault/completion_tags.lua`

#### Before (lines 8-63, the build function, verified against current code, 139 total lines):

```lua
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

#### After:

```lua
local function build(vault_path, callback)
  -- Unchanged: tags_with_counts() is already an O(N) aggregation on the
  -- index and returns a flat table. The item-building loop over unique tags
  -- is typically small (hundreds, not thousands). Keep synchronous.
  -- The debounce and cancellation from completion_base.lua still apply.
  -- ... identical to current implementation ...
end
```

**Decision:** Tag completion does not need `build_iter` because
`tags_with_counts()` already aggregates internally and the resulting tag set
is typically 1-2 orders of magnitude smaller than the note count. The
debounce and cancellation from `completion_base.lua` still apply (via the
legacy `build` path), which is sufficient. If profiling later shows tag
builds are also slow, `build_iter` can be added at that time.

The same reasoning applies to `completion_frontmatter.lua` and
`completion_inline_fields.lua` -- their iteration is over `idx.files` but
the per-entry work is lighter than wikilinks (no alias expansion). The
debounce alone resolves most of the rapid-typing thrashing. Add `build_iter`
to these only if profiling shows a need.

---

### Changes to `lua/andrew/plugins/blink-cmp.lua`

#### Before (lines 96-112, 201 total lines):

```lua
wikilinks = {
  name = "Wikilinks",
  module = "andrew.vault.completion",
  min_keyword_length = 0,
  score_offset = 15,
  fallbacks = {},
  transform_items = function(_, items)
    for _, item in ipairs(items) do
      if item.data and item.data.completion_kind == "heading" then
        item.source_name = "Heading"
      elseif item.data and item.data.completion_kind == "block" then
        item.source_name = "Block"
      end
    end
    return items
  end,
},
```

#### After:

```lua
wikilinks = {
  name = "Wikilinks",
  module = "andrew.vault.completion",
  min_keyword_length = 0,
  score_offset = 15,
  fallbacks = {},
  async = true,
  timeout_ms = 3000,
  transform_items = function(_, items)
    for _, item in ipairs(items) do
      if item.data and item.data.completion_kind == "heading" then
        item.source_name = "Heading"
      elseif item.data and item.data.completion_kind == "block" then
        item.source_name = "Block"
      end
    end
    return items
  end,
},
```

Setting `async = true` tells blink.cmp to immediately show the completion
menu (possibly with items from other sources like LSP/buffer) while the
wikilinks source builds its items in the background. Without this flag,
blink.cmp would block the entire completion pipeline waiting for the
wikilink source's callback.

The `timeout_ms = 3000` gives the coroutine ample time to complete even for
very large vaults, while still providing a safety net.

No changes needed for `vault_tags`, `vault_frontmatter`, or
`vault_inline_fields` providers -- they remain synchronous (the debounce
timer in `completion_base.lua` adds a small delay but their `build`
functions return fast enough that the debounce is the dominant latency).

---

### Config Additions

#### File: `lua/andrew/vault/config.lua`

Currently has 42 config sections across 769 lines (dirs, frontmatter,
task_states, note_types, preview, embed, blockid, footnotes, template_vars,
user_templates, wikilink_highlights, tag_highlights, autolink, link_repair,
inline_fields, highlight_marks, callout_folds, autosave, temporal_aliases,
connections, status/priority/maturity values, scopes, tag_tree, index,
search, graph, list_continuation, carry_forward, calendar, sidebar, stats,
url_validation, kanban, timeline, hierarchy, task_notify, log, ui,
frontmatter_editor, command_palette). No `M.completion` section exists yet.

Add a new section after the existing `index` section:

```lua
-- ---------------------------------------------------------------------------
-- Completion
-- ---------------------------------------------------------------------------
M.completion = {
  -- Debounce interval (ms) before starting a completion build after cache
  -- invalidation. Prevents thrashing when vault_index updates rapidly
  -- (e.g., during initial async build). Set to 0 to disable debounce.
  debounce_ms = 100,

  -- Number of vault index entries to process per coroutine batch before
  -- yielding to the event loop. Higher = faster builds, lower = more
  -- responsive UI during builds. 50 is a good default for most systems.
  batch_size = 50,
}
```

The `completion_base.lua` factory would read these defaults:

```lua
-- At the top of create_source():
local cfg = require("andrew.vault.config")
local debounce_ms = (opts.debounce_ms ~= nil) and opts.debounce_ms
  or (cfg.completion and cfg.completion.debounce_ms) or 100
local batch_size = (opts.batch_size ~= nil) and opts.batch_size
  or (cfg.completion and cfg.completion.batch_size) or 50
```

Individual sources can override these via their `opts` table passed to
`create_source()`.

---

### Pattern for Other Completion Modules

Any vault completion module can opt into coroutine-based chunked building by
adding a `build_iter` function to its `create_source()` options:

```lua
base.create_source({
  -- Optional: synchronous fallback (retained for compatibility)
  build = function(vault_path, callback)
    -- ... existing synchronous logic ...
  end,

  -- New: iterator-based builder for async chunked processing
  build_iter = function(vault_path)
    local vault_index = require("andrew.vault.vault_index")
    local idx = vault_index.current()
    if not idx or not idx:is_ready() then return nil end

    local keys = vim.tbl_keys(idx.files)
    local i = 0

    return function()
      i = i + 1
      if i > #keys then return nil end
      local entry = idx.files[keys[i]]
      if not entry then return nil end

      -- Build and return one completion item
      return {
        label = entry.basename,
        -- ... other fields ...
      }
    end
  end,

  -- Optional: per-source overrides
  debounce_ms = 50,   -- faster debounce for this source
  batch_size = 100,    -- larger batches for this source
})
```

**Contract:**
- `build_iter(vault_path)` returns a stateful iterator function or `nil`
- The iterator returns one completion item per call, `nil` when exhausted
- The coroutine calls the iterator in a loop, yielding every `batch_size` items
- If `build_iter` is not provided, the legacy `build` path is used (still
  debounced, still cancellable via the timer, but not chunked)

---

## Performance Analysis

### Current Performance (synchronous)

For a vault with 2000 notes and 500 aliases (2500 total items):

| Operation | Time (est.) | Blocks UI |
|-----------|-------------|-----------|
| `build()` iteration | 80-150ms | Yes |
| `string.format` x 2500 | 15-25ms | Yes |
| `build_description()` x 2500 | 10-20ms | Yes |
| `link_utils.rel_to_stem()` x 2000 | 5-10ms | Yes |
| **Total** | **110-205ms** | **Yes** |

Each keystroke inside `[[` after cache invalidation incurs this full cost.
Even with caching, the first trigger after any vault change (FocusGained,
file save, index rebuild) pays the full price.

### Expected Performance (async with coroutine)

With `batch_size = 50` and `debounce_ms = 100`:

| Operation | Time (est.) | Blocks UI |
|-----------|-------------|-----------|
| Debounce wait | 100ms | No |
| Per batch (50 items) | 3-5ms | Yes (per batch) |
| UI yield between batches | ~0ms | No |
| Total batches (2500 / 50) | 50 batches | -- |
| **Total wall time** | **250-350ms** | **No (3-5ms per tick)** |
| Cache hit (subsequent) | **<1ms** | **No** |

The total wall-clock time is slightly longer due to scheduling overhead, but
**no single UI tick is blocked for more than 5ms**. The user perceives
instant response because:

1. The debounce absorbs rapid keystrokes (only one build per pause).
2. The `async = true` flag on blink.cmp shows the menu immediately with
   items from other sources.
3. As coroutine batches complete, blink.cmp would need to be called back
   once at the end (not per-batch), so the menu updates once with all items.

### Cache Hit Rate

In practice, the cache hit rate will be very high:

- **Normal typing:** After the first `[[` trigger builds the cache, all
  subsequent keystrokes reuse the cached items (blink.cmp handles fuzzy
  filtering client-side via `is_incomplete_forward = false`).
- **After vault change:** One rebuild per vault index generation change.
  The vault index typically updates once per file save (not per keystroke).
- **After focus return:** One rebuild per `FocusGained` event.

Expected cache hit rate during a typical editing session: >95%.

---

## Testing Instructions

### 1. Verify Cache Validity with Generation Tracking

1. Open a markdown file in a vault with 100+ notes.
2. Type `[[` to trigger wikilink completion. Items should appear.
3. Save a different vault file (from another terminal or editor instance)
   to trigger a vault index rebuild.
4. Type `[[` again. Items should rebuild (cache miss due to generation
   change). Verify no stale entries appear.
5. Type `[[` a third time without any vault changes. Items should appear
   instantly from cache (cache hit).

### 2. Verify Debounce Prevents Thrashing

1. Open a markdown file and type `[[` quickly followed by several
   characters: `[[some` in rapid succession.
2. Watch for UI freezes. The menu should appear smoothly without janking.
3. In a debug build, add a counter to `build_items_async` and verify that
   only one or two builds were started (not one per keystroke).

### 3. Verify Cancellation

1. Open a markdown file in a very large vault (1000+ notes).
2. Type `[[` to start completion.
3. Immediately press `<C-e>` (hide completion) or `<Esc>` to leave insert
   mode.
4. Verify no error messages appear. The in-flight build should be cancelled
   cleanly.
5. Re-enter insert mode and type `[[` again. Completion should work
   normally (a new build starts).

### 4. Verify Coroutine Chunking (build_iter)

1. Temporarily reduce `batch_size` to 5 in config:
   ```lua
   M.completion = { batch_size = 5 }
   ```
2. Open a markdown file and type `[[`.
3. Verify that items still appear (coroutine completes across many
   vim.schedule ticks).
4. Reset `batch_size` to 50.

### 5. Verify blink.cmp async Flag

1. Ensure `async = true` is set on the wikilinks provider in blink-cmp.lua.
2. Open a markdown file in a vault.
3. Invalidate the completion cache (`:lua require("andrew.vault.completion_base").invalidate_all()`).
4. Type `[[`. The completion menu should appear immediately (possibly empty
   or with items from other sources like buffer/path). After the debounce +
   coroutine completes, wikilink items should populate the menu.
5. Without `async = true`, the menu would wait for the full build before
   showing anything.

### 6. Verify Backward Compatibility

1. Verify that `completion_tags.lua`, `completion_frontmatter.lua`, and
   `completion_inline_fields.lua` still work normally (they use the legacy
   `build` path, not `build_iter`).
2. Type `#` for tag completion. Tags should appear as before.
3. Edit frontmatter and verify property name/value completion works.
4. Type `[` inside a note body and verify inline field completion works.

### 7. Performance Measurement

1. Enable timing measurement:
   ```lua
   -- Temporarily add to completion_base.lua build_items_async:
   local start = vim.uv.hrtime()
   -- ... at the end of the build ...
   local elapsed = (vim.uv.hrtime() - start) / 1e6
   vim.notify(string.format("completion build: %.1fms", elapsed))
   ```
2. Compare build times before and after the change. The total elapsed time
   may be similar or slightly longer, but the UI should remain responsive
   throughout.

---

## Post-Implementation Cleanup

After implementing these changes:

1. Remove the `building` boolean guard from `completion_base.lua` -- it is
   replaced by the `active_state` cancellation mechanism which is more
   robust (the old guard could deadlock if `building` was set but the
   callback never fired).

2. Update `MEMORY.md` with a new section noting that completion sources use
   coroutine-based async building with cancellation and debounce.

3. Consider adding a `:VaultCompletionDebug` command (similar to
   `:VaultEmbedDebug`) that reports:
   - Cache state (valid/stale, generation, item count)
   - Active build state (idle/debouncing/building, batch progress)
   - Last build duration

---

## Summary of Changes

| File | Lines Changed | Description |
|------|---------------|-------------|
| `lua/andrew/vault/completion_base.lua` (130 lines) | ~80 added/modified | Coroutine chunked builder, debounce timer, cancellation, generation tracking, `build_iter` support |
| `lua/andrew/vault/completion.lua` (524 lines) | ~60 added | New `build_iter` function alongside existing `build` |
| `lua/andrew/plugins/blink-cmp.lua` (201 lines) | 2 added | `async = true` and `timeout_ms = 3000` on wikilinks provider (preserve existing `transform_items`) |
| `lua/andrew/vault/config.lua` (770 lines) | ~10 added | New `M.completion` section with `debounce_ms` and `batch_size` |

No new files. No new dependencies. `completion_tags.lua` (139 lines),
`completion_frontmatter.lua` (180 lines), and
`completion_inline_fields.lua` (182 lines) are unchanged but benefit from
the debounce timer added to the legacy `build` path in
`completion_base.lua`. Note: `completion_spell.lua` (68 lines) does NOT
use `completion_base.create_source()` -- it implements the blink.cmp source
interface directly with its own `M.new()`, `M:enabled()`, and
`M:get_completions()` methods. It is therefore unaffected by these changes.
