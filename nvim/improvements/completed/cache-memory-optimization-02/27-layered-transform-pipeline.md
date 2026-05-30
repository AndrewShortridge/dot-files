# 27. Layered Transform Pipeline

**Priority:** MEDIUM
**Phase:** 3 (Architecture)
**Dependencies:** Document 11 (Autocmd Event Batching), Document 14 (Cooperative Yielding), Document 22 (Chunked Pipeline Processing)
**Inspired by:** Zed's display map layer chain (`display_map.rs:98-122`): Buffer → InlayMap → FoldMap → TabMap → WrapMap → BlockMap

---

## Problem

Multiple vault modules independently scan the same buffer content on every edit event. Despite `highlight_coordinator.lua` consolidating autocmd registration, debounce scheduling, and sharing code exclusion data via `link_scan.build_code_exclusion()`, each registered updater still performs its own full line scan and pattern matching against the buffer. Modules outside the coordinator (`embed.lua`, `linkdiag.lua`, `task_hierarchy.lua`) operate on independent event/debounce cycles with further redundant passes.

### Current Buffer Scan Inventory

| Module | Trigger | Priority | Scans | Pattern(s) |
|--------|---------|----------|-------|------------|
| `wikilink_highlights.lua` | hl_coord (pri 30) | 30 | Visible lines | Iterative `line:find("%[%[", pos)` + `line:find("]]", open+2, true)` + `line:sub(open+2, close-1)` → `link_utils.parse_target()` (no code exclusion applied) |
| `tag_highlights.lua` | hl_coord (pri 40) | 40 | Visible lines | `#[a-zA-Z][a-zA-Z0-9_/-]*` with prefix validation + code exclusion + frontmatter skip |
| `highlights.lua` | hl_coord (pri 50) | 50 | Visible lines | `==[^=]+==` (Lua `string.find`) |
| `footnotes.lua` | hl_coord (pri 70) | 70 | Full buffer (always) | `%[%^([%w_-]+)%]` (refs) + `^%[%^([%w_-]+)%]:%s?(.*)` (defs) |
| `embed.lua` | event_dispatch: TextChanged+InsertLeave / BufEnter (50ms defer) / WinScrolled (80ms debounce) / BufReadPost (150ms defer) (independent) | — | Full buffer (lazy visible-first) | `!%[%[.-%]%]` via `embed_state.find_embed_spans()` + `iterate_embeds()` |
| `linkdiag.lua` | BufEnter/VaultCacheInvalidate (independent) | — | Full buffer | `()%[%[(.-)%]%]()` via `string.gmatch` |
| `task_hierarchy.lua` | event_dispatch: TextChanged+TextChangedI (independent, 500ms debounce) | — | Vault index data (not direct buffer scan) | `^%s*[-*] %[(.)%] ` (parsed in `vault_index_parser.lua`) |

### Redundancy Analysis

A single-character edit on line 42 of a 500-line buffer triggers:

```
highlight_coordinator fires (debounced 30ms full / 200ms viewport via resource_cleanup.debounce()):
  → arena_scope = render_arena.begin_scope()
  → code_excl = link_scan.build_code_exclusion(bufnr) (cached per changedtick)
  → wikilink_highlights (pri 30): nvim_buf_get_lines(visible_range) + %[%[(.-)%]%] pattern + parse_target (no code_excl)
  → tag_highlights (pri 40):      nvim_buf_get_lines(visible_range) + # char search + tag regex
  → highlights (pri 50):          nvim_buf_get_lines(visible_range) + ==...== regex
  → footnotes (pri 70):           nvim_buf_get_lines(0, -1) + footnote ref/def regex (full buffer always)
  → render_arena.end_scope()

embed.lua fires (separate debounce, 150ms render_delay / 80ms scroll / 500ms self_debounce):
  → nvim_buf_get_lines(0, -1) + embed pattern scan → build_descriptors()
  → Lazy: renders visible first, then async batches remaining
  → Request coalescer deduplicates concurrent render_embeds() calls

task_hierarchy fires (separate 500ms debounce):
  → Reads from vault_index entry.tasks (NOT direct buffer scan)
  → render_completion_vtext() applies virtual text for parent tasks

linkdiag fires (on BufEnter or VaultCacheInvalidate):
  → nvim_buf_get_lines(0, -1) + wikilink gmatch → vault_index resolution

Total: 5 nvim_buf_get_lines calls (4 coordinator + 1 embed), 5 pattern passes
Only line 42 actually changed.
```

The `link_scan.lua` module caches code exclusion closures and frontmatter boundaries per changedtick (O(1) position lookups via precomputed row sets), but the actual line content is re-fetched and re-parsed by every consumer independently.

### Pattern Duplication Across Modules

The wikilink pattern appears in multiple forms across the codebase:

| Module | Pattern | Style |
|--------|---------|-------|
| `wikilink_highlights.lua` | Iterative `line:find("%[%[", pos)` / `line:find("]]", open+2, true)` / `line:sub(open+2, close-1)` + `link_utils.parse_target()` | Iterative find/sub (NOT single gmatch) |
| `linkdiag.lua` | `()%[%[(.-)%]%]()` | `string.gmatch` with position captures |
| `embed.lua` / `embed_state.lua` | `!%[%[.-%]%]` | `string.find` pattern |
| `completion.lua` | Trigger chars `[`, `#`, `^`; patterns `!?%[%[(.-)%^[^%]]*$`, `!?%[%[(.-)#[^%]]*$`, `!?%[%[(.-)$` | Context-specific (triggers + partial match) |
| `autolink.lua` | Via `link_scan.scan_buffer_names()` (3-phase: multi-word longest-first, single-word hash lookup) | Name matching (different approach) |

Each module maintains its own pattern string and parsing logic with slightly different capture groups and validation rules.

### Zed's Approach

Zed's display map (`display_map.rs:98-122`) chains five transformation layers, each holding an immutable snapshot. The module documentation (lines 1-18) describes the hierarchy:

```rust
// display_map.rs:98-122 (actual current definition)
pub struct DisplayMap {
    buffer: Entity<MultiBuffer>,
    buffer_subscription: BufferSubscription,
    inlay_map: InlayMap,        // Inlay hints placement
    fold_map: FoldMap,          // Fold indicators + collapsed regions
    tab_map: TabMap,            // Hard tab tracking
    wrap_map: Entity<WrapMap>,  // Soft wrapping (async via GPUI Entity)
    block_map: BlockMap,        // Custom blocks (diagnostics, headers)
    text_highlights: TextHighlights,
    inlay_highlights: InlayHighlights,
    crease_map: CreaseMap,      // Explicit foldable ranges
    pub(crate) fold_placeholder: FoldPlaceholder,
    pub clip_at_line_ends: bool,
    pub(crate) masked: bool,
    pub(crate) diagnostics_max_severity: DiagnosticSeverity,
}
```

The snapshot method (lines 167-177) shows the incremental edit chain:

```rust
// display_map.rs:167-177 - edit propagation chain
pub fn snapshot(&mut self, cx: &mut Context<Self>) -> DisplaySnapshot {
    let buffer_snapshot = self.buffer.read(cx).snapshot(cx);
    let edits = self.buffer_subscription.consume().into_inner();
    let (inlay_snapshot, edits) = self.inlay_map.sync(buffer_snapshot, edits);
    let (fold_snapshot, edits) = self.fold_map.read(inlay_snapshot.clone(), edits);
    let tab_size = Self::tab_size(&self.buffer, cx);
    let (tab_snapshot, edits) = self.tab_map.sync(fold_snapshot.clone(), edits, tab_size);
    let (wrap_snapshot, edits) = self
        .wrap_map
        .update(cx, |map, cx| map.sync(tab_snapshot.clone(), edits, cx));
    let block_snapshot = self.block_map.read(wrap_snapshot.clone(), edits).snapshot;
    // ... DisplaySnapshot construction
}
```

Each layer receives the previous layer's snapshot + edits, transforms them, and emits new edits. The edit type chain is:

| Layer | Input Edit Type | Output Edit Type | Data Structure |
|-------|----------------|-----------------|----------------|
| Buffer → Inlay | `text::Edit<usize>` | `InlayEdit = Edit<InlayOffset>` | `SumTree<Transform>` (Transform enum: Isomorphic/Inlay variants) |
| Inlay → Fold | `InlayEdit` | `FoldEdit = Edit<FoldOffset>` | `SumTree<Transform>` + `SumTree<Fold>` + `TreeMap<FoldId, FoldMetadata>` |
| Fold → Tab | `FoldEdit` | `TabEdit = Edit<TabPoint>` | Stateless (TabSnapshot embeds FoldSnapshot directly, no separate transforms) |
| Tab → Wrap | `TabEdit` | `Patch<u32>` (row edits) | `SumTree<Transform>` + `VecDeque<(TabSnapshot, Vec<TabEdit>)>` for pending edits + async `Task<()>` background task |
| Wrap → Block | `Patch<u32>` | `BlockSnapshot` | `SumTree<Transform>` (in `RefCell`) + `TreeMap<CustomBlockId, Arc<CustomBlock>>` |

Key properties:
- **Incremental**: Each layer recomputes only the region affected by the upstream diff (via `SumTree` cursor-based seeking)
- **Composable**: Layers are independent and can be cached/invalidated separately (InlayMap, FoldMap, TabMap have explicit `version: usize` counters; WrapMap uses `interpolated: bool` flag + indirect version via TabSnapshot; BlockMap inherits version through WrapSnapshot)
- **Single source**: Buffer content is read once; downstream layers consume upstream output
- **Diff-based**: Each layer emits a patch, not a full rebuild
- **Async-capable**: WrapMap runs background wrapping tasks with interpolated edits to avoid UI blocking (uses `VecDeque` for deferred edit processing)
- **Interior mutability**: BlockMap uses `RefCell` for transforms and wrap_snapshot, allowing `&self` read methods to perform lazy sync

---

## Solution

Introduce a three-layer transform pipeline between raw buffer content and the rendering modules.

### Architecture

```
                    TextChanged (line 42)
                          │
                    event_dispatch.lua
                          │
              highlight_coordinator.schedule(bufnr, opts)
                          │
                    resource_cleanup.debounce()
                     (30ms full / 200ms viewport)
                          │
                          ▼
              ┌───────────────────────┐
              │  Layer 0: Buffer      │  nvim_buf_get_lines (ONCE)
              │  Tracks changed lines │  via on_bytes or changedtick diff
              └───────────┬───────────┘
                          │ changed_lines = {42}
                          ▼
              ┌───────────────────────┐
              │  Layer 1: Line Parse  │  Tokenize ONLY changed lines
              │  Cache               │  Output: token[] per line
              │                      │  (replaces 5 independent scans)
              └───────────┬───────────┘
                          │ changed_tokens for line 42
                          ▼
              ┌───────────────────────┐
              │  Layer 2: Semantic    │  Resolve ONLY changed tokens
              │  Resolution          │  link→path, tag→valid, task→state
              │                      │  Invalidated by vault_index._generation
              └───────────┬───────────┘
                          │ resolved_tokens for line 42
                          ▼
              ┌───────────────────────┐
              │  Layer 3: Render      │  Diff extmark specs, apply delta
              │  Instructions        │  Only changed extmarks set/deleted
              │                      │  Uses render_arena for temporaries
              └───────────────────────┘
```

### Layer 0: Change Tracking

Track which lines changed since the last pipeline run. Two strategies:

```lua
-- line_tracker.lua

local M = {}

--- Per-buffer dirty line tracking.
---@type table<number, { tick: number, dirty: table<number, true>, full: boolean }>
local _buffers = {}

--- Attach on_bytes callback to a buffer for fine-grained change tracking.
---@param bufnr number
function M.attach(bufnr)
  if _buffers[bufnr] then return end
  _buffers[bufnr] = { tick = 0, dirty = {}, full = true }

  vim.api.nvim_buf_attach(bufnr, false, {
    on_bytes = function(_, buf, tick, start_row, _, _, old_end_row, _, _, new_end_row, _, _)
      local state = _buffers[buf]
      if not state then return true end -- detach

      state.tick = tick

      if old_end_row ~= new_end_row then
        -- Line count changed: mark everything from start_row onward as dirty
        -- (line numbers shifted, cached tokens for later lines are stale)
        state.full = true
      else
        -- In-place edit: only mark affected lines
        for row = start_row, start_row + math.max(old_end_row, new_end_row) do
          state.dirty[row] = true
        end
      end
    end,

    on_detach = function(_, buf)
      _buffers[buf] = nil
    end,
  })
end

--- Get dirty lines since last consume, then clear dirty set.
--- Returns nil if a full reparse is needed (line count changed).
---@param bufnr number
---@return number[]|nil dirty_lines nil means full reparse needed
function M.consume(bufnr)
  local state = _buffers[bufnr]
  if not state then return nil end

  if state.full then
    state.full = false
    state.dirty = {}
    return nil -- caller must do full parse
  end

  local lines = vim.tbl_keys(state.dirty)
  table.sort(lines)
  state.dirty = {}
  return lines
end

return M
```

When `on_bytes` reports a multi-line insertion or deletion (line count changes), the tracker signals a full reparse. For single-line edits (the common case during typing), only the affected line numbers are marked dirty.

### Layer 1: Line Parse Cache

A single tokenizer produces all token types from one pass per line. This replaces the 5 independent pattern scans run by the coordinator updaters and embed.lua.

**Important**: The patterns here must match the actual patterns used by current modules. Several modules use manual character scanning rather than simple regex patterns:

```lua
-- line_parse_cache.lua

local M = {}

---@class LineToken
---@field type string "wikilink"|"tag"|"task"|"embed"|"footnote"|"heading"|"block_id"|"highlight"
---@field start_col number 0-indexed byte offset
---@field end_col number 0-indexed byte offset (exclusive)
---@field text string raw matched text
---@field subtype? string e.g. "embed_image", "embed_note", "task_done", "task_open"
---@field captures? table type-specific parsed fields (from link_utils.parse_target, etc.)

---@type table<number, { tick: number, lines: table<number, LineToken[]> }>
local _cache = {}

-- Combined pattern table: order matters (longer/more-specific matches first).
-- Patterns must be kept in sync with actual module patterns:
--   embed.lua:        "!%[%[.-%]%]"  (embed_state.find_embed_spans / iterate_embeds)
--   wikilink_hl:      "%[%[(.-)%]%]" Lua pattern (NO code exclusion applied)
--   footnotes.lua:    "%[%^([%w_-]+)%]" (refs), "^%[%^([%w_-]+)%]:%s?(.*)" (defs)
--   highlights.lua:   "==[^=]+==" (HIGHLIGHT_PATTERN), code exclusion + frontmatter skip
--   tag_highlights:   "#[a-zA-Z][a-zA-Z0-9_/-]*" + valid_tag_start() + is_hex_color()
--   task (index):     "^%s*[-*] %[(.)%] " (vault_index_parser)
-- NOTE: wikilink_highlights does NOT apply code_excl, and footnotes also does NOT
-- apply code_excl (_code_excl accepted but unused). The tokenizer must handle this
-- per-type: code_excl should be checked for tags/highlights but NOT wikilinks/footnotes.
-- This means the code_excl check in tokenize_line() needs a per-pattern skip flag.
local TOKEN_PATTERNS = {
  { pattern = "!%[%[(.-)%]%]",       type = "embed",    skip_code_excl = true },
  { pattern = "%[%[(.-)%]%]",        type = "wikilink", skip_code_excl = true },
  { pattern = "%[%^([%w_-]+)%]",     type = "footnote", skip_code_excl = true },
  { pattern = "==[^=]+==",             type = "highlight" },
  -- Tags require special handling: # must be preceded by whitespace/punctuation,
  -- must start with a letter, and hex colors (#fff, #ff00aa) must be excluded.
  -- tag_highlights.lua uses valid_tag_start() + is_hex_color() checks.
  { pattern = "#([a-zA-Z][a-zA-Z0-9_/-]*)", type = "tag", validate = "tag" },
  { pattern = "^(#+)%s",             type = "heading" },
  { pattern = "^%s*[-*] %[([ xX/-])%]", type = "task" },
  { pattern = "%^(blk%-[%w]+)$",     type = "block_id" },
}

-- Tag validation (mirrors tag_highlights.lua logic)
local function valid_tag_start(line, pos)
  if pos <= 1 then return true end
  local prev = line:sub(pos - 1, pos - 1)
  return prev:match("[%s%(%)%[%]{},;:\"']") ~= nil
end

local function is_hex_color(tag)
  if not tag:match("^[0-9a-fA-F]+$") then return false end
  local len = #tag
  return len == 3 or len == 6 or len == 8
end

--- Tokenize a single line, producing all token types.
--- Code-excluded regions are skipped via the provided exclusion function.
---@param line_text string
---@param line_nr number 0-indexed line number
---@param code_excl fun(row: number, col: number): boolean
---@return LineToken[]
function M.tokenize_line(line_text, line_nr, code_excl)
  local tokens = {}
  -- Track consumed byte ranges to prevent overlapping matches
  local consumed = {} -- sorted list of {start, end} pairs

  -- Skip heading lines for tag scanning (mirrors tag_highlights.lua)
  local is_heading_line = line_text:match("^#+ ") ~= nil

  for _, def in ipairs(TOKEN_PATTERNS) do
    -- Tag patterns should skip heading lines
    if def.validate == "tag" and is_heading_line then
      goto continue
    end

    local search_start = 1
    while true do
      local s, e, cap1, cap2 = line_text:find(def.pattern, search_start)
      if not s then break end
      search_start = e + 1

      -- Skip if overlapping with already-consumed range
      local col0 = s - 1 -- convert to 0-indexed
      local col1 = e      -- exclusive end, 0-indexed
      local overlaps = false
      for _, r in ipairs(consumed) do
        if col0 < r[2] and col1 > r[1] then
          overlaps = true
          break
        end
      end

      -- Additional tag validation
      if not overlaps and def.validate == "tag" then
        if not valid_tag_start(line_text, s) or is_hex_color(cap1) then
          overlaps = true -- reuse flag to skip
        end
      end

      if not overlaps and (def.skip_code_excl or not code_excl(line_nr, col0)) then
        consumed[#consumed + 1] = { col0, col1 }
        tokens[#tokens + 1] = {
          type = def.type,
          start_col = col0,
          end_col = col1,
          text = line_text:sub(s, e),
          captures = { cap1, cap2 },
        }
      end
    end
    ::continue::
  end

  -- Sort by position for consistent downstream processing
  table.sort(tokens, function(a, b) return a.start_col < b.start_col end)
  return tokens
end

--- Get cached tokens for a line, re-parsing only if stale.
---@param bufnr number
---@param line_nr number 0-indexed
---@param line_text string
---@param code_excl fun(row: number, col: number): boolean
---@return LineToken[]
function M.get_line_tokens(bufnr, line_nr, line_text, code_excl)
  local buf_cache = _cache[bufnr]
  if not buf_cache then
    buf_cache = { tick = 0, lines = {} }
    _cache[bufnr] = buf_cache
  end
  -- Tokens are populated by update(); direct access returns cached or empty
  return buf_cache.lines[line_nr] or {}
end

--- Re-parse specific lines and update the cache.
--- Called by the pipeline coordinator after Layer 0 identifies dirty lines.
---@param bufnr number
---@param line_nrs number[] 0-indexed line numbers to re-parse (nil = all)
---@param code_excl fun(row: number, col: number): boolean
function M.update(bufnr, line_nrs, code_excl)
  local buf_cache = _cache[bufnr]
  if not buf_cache then
    buf_cache = { tick = 0, lines = {} }
    _cache[bufnr] = buf_cache
  end
  buf_cache.tick = vim.api.nvim_buf_get_changedtick(bufnr)

  if not line_nrs then
    -- Full parse: get all lines
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    buf_cache.lines = {}
    for i, text in ipairs(lines) do
      buf_cache.lines[i - 1] = M.tokenize_line(text, i - 1, code_excl)
    end
  else
    -- Incremental: only re-parse dirty lines
    for _, ln in ipairs(line_nrs) do
      local text = vim.api.nvim_buf_get_lines(bufnr, ln, ln + 1, false)[1]
      if text then
        buf_cache.lines[ln] = M.tokenize_line(text, ln, code_excl)
      else
        buf_cache.lines[ln] = nil -- line was deleted
      end
    end
  end
end

--- Invalidate all cached data for a buffer.
---@param bufnr number
function M.invalidate(bufnr)
  _cache[bufnr] = nil
end

--- Iterate all cached tokens of a given type for a buffer.
---@param bufnr number
---@param token_type string
---@return fun(): number?, LineToken? iterator yielding (line_nr, token)
function M.iter_tokens(bufnr, token_type)
  local buf_cache = _cache[bufnr]
  if not buf_cache then return function() end end

  local line_nrs = vim.tbl_keys(buf_cache.lines)
  table.sort(line_nrs)
  local li, ti = 1, 0

  return function()
    while li <= #line_nrs do
      local ln = line_nrs[li]
      local tokens = buf_cache.lines[ln]
      ti = ti + 1
      while ti <= #tokens do
        if tokens[ti].type == token_type then
          return ln, tokens[ti]
        end
        ti = ti + 1
      end
      li = li + 1
      ti = 0
    end
  end
end

return M
```

### Layer 2: Semantic Resolution

Resolves parsed tokens against vault state (index, filesystem). Cached separately because resolution can be invalidated independently of parsing (e.g., when `vault_index._generation` changes).

The vault index uses a singleton pattern (`vault_index.current()`) and provides:
- `resolve_name(name)` → returns array of absolute paths (checks `_name_index` then `_alias_index`)
- `tag_matches(entry.tags, target_tag, opts)` → hierarchical tag matching
- `_generation` → incremented on every mutation for staleness detection

```lua
-- semantic_resolution.lua

local M = {}

---@class ResolvedToken
---@field token LineToken the source token from Layer 1
---@field line_nr number 0-indexed
---@field status string "valid"|"broken"|"external"|"ambiguous"|"unknown"
---@field target? string resolved file path or anchor
---@field metadata? table additional type-specific data

---@type table<number, { gen: number, resolved: table<number, ResolvedToken[]> }>
local _cache = {}

--- Resolve a single wikilink token against the vault index.
--- Must match wikilink_highlights.lua resolution logic:
---   uses link_utils.parse_target() for name/heading/block_id/alias extraction,
---   wikilinks.resolve_link() for cached resolution,
---   linkdiag.get_headings() for heading validation.
---@param token LineToken
---@param index table vault_index instance
---@param link_utils table link_utils module (passed to avoid circular require)
---@return ResolvedToken
local function resolve_wikilink(token, index, link_utils)
  local link_text = token.captures[1]
  if not link_text then
    return { token = token, status = "unknown" }
  end

  -- Skip URL-like content (wikilink_highlights.lua checks target:match("^https?://"))
  if link_text:match("^https?://") then
    return { token = token, status = "external" }
  end

  -- Use link_utils.parse_target() for consistent parsing with all other modules.
  -- Returns { name, heading?, block_id?, alias? }
  -- Self-references: [[#Heading]] or [[^blockid]] have name = ""
  local parsed = link_utils.parse_target(link_text)
  local target = parsed.name
  local heading = parsed.heading
  local block_id = parsed.block_id
  local alias = parsed.alias

  -- Self-reference (empty target)
  if not target or target == "" then
    return { token = token, status = "valid", metadata = { self_ref = true, heading = heading, block_id = block_id, alias = alias } }
  end

  local resolved_paths = index:resolve_name(target)
  if resolved_paths and #resolved_paths > 0 then
    local status = #resolved_paths > 1 and "ambiguous" or "valid"
    return {
      token = token,
      status = status,
      target = resolved_paths[1],
      metadata = { heading = heading, block_id = block_id, alias = alias, paths = resolved_paths },
    }
  else
    return { token = token, status = "broken", metadata = { link_text = target, heading = heading, block_id = block_id, alias = alias } }
  end
end

--- Resolve a tag token: check if tag exists in index.
--- tag_highlights.lua uses category-based coloring (project/, status/, type/, person/ prefixes)
--- but doesn't validate tag existence against the index.
local function resolve_tag(token, index)
  local tag_name = token.captures[1]
  -- Determine tag category for highlight group selection
  local category = nil
  if tag_name then
    if tag_name:sub(1, 8) == "project/" then category = "project"
    elseif tag_name:sub(1, 7) == "status/" then category = "status"
    elseif tag_name:sub(1, 5) == "type/" then category = "type"
    elseif tag_name:sub(1, 7) == "person/" then category = "person"
    end
  end
  return { token = token, status = "valid", metadata = { tag = tag_name, category = category } }
end

--- Resolve all tokens for specific lines.
---@param bufnr number
---@param line_nrs number[]|nil lines to resolve (nil = all cached)
---@param parse_cache table Line parse cache (Layer 1)
---@param index table vault_index instance
function M.resolve(bufnr, line_nrs, parse_cache, index)
  local buf = _cache[bufnr]
  if not buf then
    buf = { gen = 0, resolved = {} }
    _cache[bufnr] = buf
  end
  buf.gen = index._generation or 0

  local lu = require("andrew.vault.link_utils")

  local resolve_line = function(ln)
    local tokens = parse_cache.get_line_tokens(bufnr, ln)
    local resolved = {}
    for _, tok in ipairs(tokens) do
      if tok.type == "wikilink" then
        resolved[#resolved + 1] = resolve_wikilink(tok, index, lu)
      elseif tok.type == "tag" then
        resolved[#resolved + 1] = resolve_tag(tok, index)
      else
        -- Passthrough: tasks, embeds, footnotes, headings don't need index resolution
        resolved[#resolved + 1] = { token = tok, status = "valid", line_nr = ln }
      end
    end
    buf.resolved[ln] = resolved
  end

  if line_nrs then
    for _, ln in ipairs(line_nrs) do
      resolve_line(ln)
    end
  else
    -- Resolve all cached lines (used when index generation changes)
    for ln in pairs(parse_cache._cache[bufnr] and parse_cache._cache[bufnr].lines or {}) do
      resolve_line(ln)
    end
  end
end

--- Get resolved tokens for a line.
---@param bufnr number
---@param line_nr number
---@return ResolvedToken[]
function M.get_resolved(bufnr, line_nr)
  local buf = _cache[bufnr]
  if not buf then return {} end
  return buf.resolved[line_nr] or {}
end

--- Check if resolution cache is stale (index generation changed).
---@param bufnr number
---@param current_gen number
---@return boolean
function M.is_stale(bufnr, current_gen)
  local buf = _cache[bufnr]
  return not buf or buf.gen ~= current_gen
end

function M.invalidate(bufnr)
  _cache[bufnr] = nil
end

return M
```

### Layer 3: Render Instruction Diffing

Generate extmark specifications from resolved tokens, then diff against the previous set to minimize API calls. Must support the multi-part extmark patterns used by current modules:

- **wikilink_highlights.lua**: 4 extmarks per link (open bracket, close bracket, target text, heading/alias text) with separate highlight groups per resolution status (`VaultWikiLinkBracket`, `VaultWikiLinkValid`, `VaultWikiLinkBroken`, `VaultWikiLinkSelf`, `VaultWikiLinkHeading`, `VaultWikiLinkHeadingBroken`, `VaultWikiLinkAlias`), all priority 200
- **tag_highlights.lua**: 2 extmarks per tag (hash `VaultTagHash` + text `VaultTag`/`VaultTagProject`/`VaultTagStatus`/`VaultTagType`/`VaultTagPerson`), priority 190
- **highlights.lua**: 3 extmarks per highlight (open `==` `VaultHighlightDelim`, close `==` `VaultHighlightDelim`, content `VaultHighlight`), priority 195
- **footnotes.lua**: Virtual text lines (`virt_lines`) with `VaultFootnoteBorder`/`VaultFootnoteContent`/`VaultFootnoteOrphan`, rendered below references

```lua
-- render_diff.lua

local M = {}

---@class ExtmarkSpec
---@field ns number namespace id
---@field line number 0-indexed
---@field col number 0-indexed start column
---@field opts table extmark options (hl_group, virt_text, end_col, priority, mode, etc.)
---@field key string unique identity for diffing (ns:line:col:type)

---@type table<number, table<string, ExtmarkSpec>> -- bufnr -> key -> spec
local _prev_specs = {}

--- Compute a unique key for an extmark spec (for diffing).
---@param spec ExtmarkSpec
---@return string
local function spec_key(spec)
  return string.format("%d:%d:%d:%s", spec.ns, spec.line, spec.col,
    spec.opts.hl_group or spec.opts.virt_text and "vt" or spec.opts.virt_lines and "vl" or "other")
end

--- Compare two extmark option tables for equality.
---@return boolean
local function opts_equal(a, b)
  -- Fast path: identical hl_group and end_col covers most highlight extmarks
  if a.hl_group ~= b.hl_group then return false end
  if a.end_col ~= b.end_col then return false end
  if a.end_row ~= b.end_row then return false end
  if a.priority ~= b.priority then return false end
  -- Deep compare for virt_text/virt_lines if present
  if a.virt_text or b.virt_text then
    return vim.deep_equal(a.virt_text, b.virt_text)
  end
  if a.virt_lines or b.virt_lines then
    return vim.deep_equal(a.virt_lines, b.virt_lines)
  end
  return true
end

--- Apply only the delta between old and new extmark specs for given lines.
---@param bufnr number
---@param new_specs ExtmarkSpec[] new specifications for changed lines
---@param changed_lines table<number, true> set of lines that changed
function M.apply_diff(bufnr, new_specs, changed_lines)
  local prev = _prev_specs[bufnr] or {}
  local next_prev = {}

  -- Index new specs by key
  local new_by_key = {}
  for _, spec in ipairs(new_specs) do
    local key = spec_key(spec)
    new_by_key[key] = spec
    next_prev[key] = spec
  end

  -- Remove old extmarks on changed lines that are no longer present
  for key, old_spec in pairs(prev) do
    if changed_lines[old_spec.line] then
      if not new_by_key[key] then
        -- Extmark was on a changed line and is no longer needed: delete
        pcall(vim.api.nvim_buf_del_extmark, bufnr, old_spec.ns, old_spec._id)
      end
    else
      -- Unchanged line: carry forward
      next_prev[key] = old_spec
    end
  end

  -- Set new/updated extmarks on changed lines
  for key, spec in pairs(new_by_key) do
    local old = prev[key]
    if not old or not opts_equal(old.opts, spec.opts) then
      local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, spec.ns, spec.line, spec.col, spec.opts)
      if ok then spec._id = id end
    else
      spec._id = old._id -- reuse existing extmark id
    end
  end

  _prev_specs[bufnr] = next_prev
end

function M.invalidate(bufnr)
  _prev_specs[bufnr] = nil
end

return M
```

### Pipeline Coordinator

Orchestrates the three layers. Integrates with `highlight_coordinator.lua`'s existing infrastructure: priority-based updater dispatch, `render_arena` scope management, factory functions (`make_toggle`, `make_jump`, `make_coordinated_update`), and debounce via `resource_cleanup.debounce()`.

```lua
-- transform_pipeline.lua

local line_tracker = require("andrew.vault.line_tracker")
local line_parse = require("andrew.vault.line_parse_cache")
local semantic = require("andrew.vault.semantic_resolution")
local render = require("andrew.vault.render_diff")
local link_scan = require("andrew.vault.link_scan")
local vault_index = require("andrew.vault.vault_index")
local config = require("andrew.vault.config")
local log = require("andrew.vault.vault_log").scope("pipeline")

local M = {}

---@class RenderConsumer
---@field name string
---@field token_types string[] which token types this consumer cares about
---@field ns number extmark namespace
---@field priority number rendering priority (matches coordinator priority)
---@field render fun(line_nr: number, resolved: ResolvedToken[]): ExtmarkSpec[]

---@type RenderConsumer[]
local _consumers = {}

--- Register a render consumer (replaces per-module buffer scanning).
function M.register_consumer(consumer)
  _consumers[#_consumers + 1] = consumer
  -- Sort by priority to maintain consistent rendering order
  table.sort(_consumers, function(a, b) return (a.priority or 50) < (b.priority or 50) end)
end

--- Run the pipeline for a buffer.
--- Called by highlight_coordinator's run_all() in place of per-updater dispatch.
--- Receives the same opts table: { full, arena, code_excl }
---@param bufnr number
---@param code_excl fun(row: number, col: number): boolean
---@param opts table coordinator options
function M.run(bufnr, code_excl, opts)
  -- Layer 0: determine what changed
  local dirty_lines = line_tracker.consume(bufnr)
  local index = vault_index.current()

  -- Layer 1: re-parse changed lines (or all if dirty_lines is nil)
  line_parse.update(bufnr, dirty_lines, code_excl)

  -- Layer 2: re-resolve changed tokens
  local index_gen = index and index._generation or 0
  if semantic.is_stale(bufnr, index_gen) then
    -- Index changed: re-resolve everything
    semantic.resolve(bufnr, nil, line_parse, index)
    dirty_lines = nil -- force full render diff
  else
    semantic.resolve(bufnr, dirty_lines, line_parse, index)
  end

  -- Layer 3: compute render instructions and apply diff
  local line_set = {}
  if dirty_lines then
    for _, ln in ipairs(dirty_lines) do line_set[ln] = true end
  else
    -- Full: all cached lines are "changed" for diffing purposes
    local total = vim.api.nvim_buf_line_count(bufnr)
    for i = 0, total - 1 do line_set[i] = true end
  end

  local all_specs = {}
  for _, consumer in ipairs(_consumers) do
    for ln in pairs(line_set) do
      local resolved = semantic.get_resolved(bufnr, ln)
      -- Filter to token types this consumer handles
      local relevant = {}
      for _, rt in ipairs(resolved) do
        for _, tt in ipairs(consumer.token_types) do
          if rt.token.type == tt then
            relevant[#relevant + 1] = rt
            break
          end
        end
      end

      if #relevant > 0 then
        local specs = consumer.render(ln, relevant)
        for _, spec in ipairs(specs) do
          spec.ns = consumer.ns
          all_specs[#all_specs + 1] = spec
        end
      end
    end
  end

  render.apply_diff(bufnr, all_specs, line_set)

  log.debug("pipeline run", {
    bufnr = bufnr,
    dirty_lines = dirty_lines and #dirty_lines or "full",
    specs = #all_specs,
    consumers = #_consumers,
  })
end

--- Attach pipeline to a buffer (called once per buffer).
function M.attach(bufnr)
  line_tracker.attach(bufnr)
end

--- Full invalidation (buffer closed, etc.)
function M.detach(bufnr)
  line_parse.invalidate(bufnr)
  semantic.invalidate(bufnr)
  render.invalidate(bufnr)
end

return M
```

---

## Integration Points

### Migrating highlight_coordinator.lua

The existing `highlight_coordinator.lua` already provides:
- **Priority-based updater registry**: `_updaters` array sorted by priority, each with `fn`, `name`, `priority`, `enabled()`
- **Consolidated event dispatch**: via `event_dispatch.lua` (BufEnter via coalescer with adaptive delay, TextChanged+TextChangedI → coordinator.schedule + task_hierarchy._schedule_render, TextChanged+InsertLeave → embed.on_text_changed, WinScrolled → embed scroll handler, BufWritePost → coordinator.on_buf_write, VimLeavePre → teardown)
- **Shared code exclusion**: Single `link_scan.build_code_exclusion(bufnr)` call passed to all updaters
- **Arena allocation**: `render_arena.begin_scope()` → scope_id / `end_scope(scope_id)` wrapping all updaters (also provides `alloc_table(scope_id)`, `alloc_array(scope_id, capacity)` with LuaJIT `table.new` optimization, `with_scope(fn)`, pool stats via `stats()`); pool config: `config.arena.initial_pool_size=200`, `max_pool_size=2000`, `debug_validation=false`
- **Factory functions**: `make_toggle()`, `make_jump()`, `make_coordinated_update()`, `make_scan_nav()`, `make_scanner_nav()`, `make_refresh_command()`, `cached_positions()`, `cached_value()`, `clear_extmarks()`, `setup_buf_cleanup()`, `register_nav_keymaps()`
- **Error isolation**: Each updater in `run_all()` is wrapped in `pcall()` so one updater's failure doesn't block others
- **Debounce**: `resource_cleanup.debounce(existing, delay_ms, callback)` with 30ms for full renders, 200ms for viewport-only; returns `uv_timer_t` for per-buffer storage in `_timers[bufnr]`
- **Event coalescing**: BufEnter dispatched via `event_coalescer` with `config.events.buf_enter_coalesce_ms=16`, `config.events.rapid_switch_threshold_ms=50`, `config.events.rapid_switch_delay_ms=200`, `config.events.max_batch_size=32`; coalescer supports `adaptive=true` mode
- **Viewport config**: `config.viewport.padding_lines=50`, `full_buffer_threshold=200` (lines threshold for full vs viewport render), `scroll_debounce_ms=50`, `gc_interval_ms=5000`

The pipeline replaces the _updater dispatch loop_ inside `run_all()`:

```lua
-- Before: coordinator calls each updater with raw buffer access
function run_all(bufnr, opts)
  local code_excl = link_scan.build_code_exclusion(bufnr)
  local arena_scope = render_arena.begin_scope()
  opts.arena = arena_scope

  for _, updater in ipairs(_updaters) do
    if updater.enabled() then
      updater.fn(bufnr, code_excl, opts)
    end
  end

  render_arena.end_scope(arena_scope)
end

-- After: coordinator calls the pipeline once (arena still managed by coordinator)
function run_all(bufnr, opts)
  local code_excl = link_scan.build_code_exclusion(bufnr)
  local arena_scope = render_arena.begin_scope()
  opts.arena = arena_scope
  opts.code_excl = code_excl

  if config.pipeline.enable then
    pipeline.run(bufnr, code_excl, opts)
  else
    -- Fallback: legacy per-updater dispatch
    for _, updater in ipairs(_updaters) do
      if updater.enabled() then
        updater.fn(bufnr, code_excl, opts)
      end
    end
  end

  render_arena.end_scope(arena_scope)
end
```

Each current updater module migrates from "scan buffer + apply extmarks" to "register a render consumer":

```lua
-- wikilink_highlights.lua (before): iterative find/sub + link_utils.parse_target + per-link extmarks
-- NOTE: wikilink_highlights does NOT apply code_excl — all wikilinks are highlighted regardless of context
function M.coordinated_update(bufnr, code_excl, opts)
  -- Delegates to apply_range() which uses iterative find/sub (NOT gmatch):
  local lines = vim.api.nvim_buf_get_lines(bufnr, start, stop, false)
  for i, line in ipairs(lines) do
    local pos = 1
    while true do
      local open = line:find("%[%[", pos, false)
      if not open then break end
      local is_embed = open > 1 and line:sub(open - 1, open - 1) == "!"
      local close = line:find("]]", open + 2, true)
      if not close then break end
      pos = close + 2
      if is_embed then goto continue end
      local inner = line:sub(open + 2, close - 1)
      local parsed = link_utils.parse_target(inner)
      -- Apply 4+ extmarks: open bracket, close bracket, target, heading/alias (all priority 200)
      vim.api.nvim_buf_set_extmark(bufnr, ns, ...)  -- VaultWikiLinkBracket (open)
      vim.api.nvim_buf_set_extmark(bufnr, ns, ...)  -- VaultWikiLinkBracket (close)
      vim.api.nvim_buf_set_extmark(bufnr, ns, ...)  -- VaultWikiLink{Valid|Broken|Self}
      vim.api.nvim_buf_set_extmark(bufnr, ns, ...)  -- VaultWikiLink{Heading|Alias} (conditional)
      ::continue::
    end
  end
end

-- wikilink_highlights.lua (after): register consumer, receive pre-parsed tokens
pipeline.register_consumer({
  name = "wikilinks",
  token_types = { "wikilink" },
  ns = vim.api.nvim_create_namespace("vault_wikilink_hl"),
  priority = 30,
  render = function(line_nr, resolved_tokens)
    local specs = {}
    for _, rt in ipairs(resolved_tokens) do
      local tok = rt.token
      local open_col = tok.start_col
      local close_col = tok.end_col

      -- Bracket extmarks (open and close)
      specs[#specs + 1] = {
        line = line_nr, col = open_col,
        opts = { end_col = open_col + 2, hl_group = "VaultWikiLinkBracket", priority = 200, hl_mode = "combine" },
      }
      specs[#specs + 1] = {
        line = line_nr, col = close_col - 2,
        opts = { end_col = close_col, hl_group = "VaultWikiLinkBracket", priority = 200, hl_mode = "combine" },
      }

      -- Content highlight based on resolution status
      local hl_group
      if rt.metadata and rt.metadata.self_ref then
        hl_group = "VaultWikiLinkSelf"
      elseif rt.status == "broken" then
        hl_group = "VaultWikiLinkBroken"
      else
        hl_group = "VaultWikiLinkValid"
      end

      specs[#specs + 1] = {
        line = line_nr, col = open_col + 2,
        opts = { end_col = close_col - 2, hl_group = hl_group, priority = 200, hl_mode = "combine" },
      }
    end
    return specs
  end,
})
```

### Modules to Migrate

| Module | Consumer token_types | Priority | Namespace | Extmark Style | Notes |
|--------|---------------------|----------|-----------|---------------|-------|
| `wikilink_highlights.lua` | `{"wikilink"}` | 30 | `vault_wikilink_hl` | 4+ extmarks/link (brackets + target + heading/alias conditional), all priority 200 | Uses iterative find/sub (not gmatch); resolution status for broken/valid/self styling; heading validation via `linkdiag.get_headings()`; alias highlighting conditional on `|` pipe; **does NOT apply code exclusion** — pipeline tokenizer must skip code_excl for wikilinks; uses `make_toggle` + `make_refresh_command` (no `make_coordinated_update` — direct impl) |
| `tag_highlights.lua` | `{"tag"}` | 40 | `vault_tag_hl` | 2 extmarks/tag (hash `VaultTagHash` priority 190 + text by category priority 190) | Category-based colors (project/status/type/person); code exclusion via `code_excl(row, hash_pos - 1)`; hex color filtering; frontmatter range skip; heading line skip; uses `make_toggle` + `make_coordinated_update` + `make_scan_nav` |
| `highlights.lua` | `{"highlight"}` | 50 | `vault_highlight_hl` | 3 extmarks/mark (open delim + content + close delim), all priority 195 | Code exclusion applied; uses `make_toggle` + `make_coordinated_update` + `make_scan_nav` |
| `footnotes.lua` | `{"footnote"}` | 70 | `VaultFootnote` | Virtual text lines (`virt_lines`) below refs with `VaultFootnoteBorder`/`VaultFootnoteContent`/`VaultFootnoteOrphan`/`VaultFootnoteRef` | Always scans full buffer (defs can be anywhere); continuation lines (`4-space indent` or `\t`); `config.footnotes.max_lines = 5`, `config.footnotes.border_width`; **does NOT apply code exclusion** (`_code_excl` accepted but unused); conditional coordinator registration (only if `config.footnotes.render and config.footnotes.auto_render`); uses `cached_value()` for changedtick-validated footnote map; complex — see special handling below |
| `linkdiag.lua` | `{"wikilink"}` | — | `vault_linkdiag` | Diagnostics (not extmarks): `_type` = `"broken_note"` / `"broken_heading"` / `"dead_url"`, with `_target`, `_heading`, `_filepath`, `_url` fields | Shares resolution with wikilink_highlights; produces `vim.diagnostic` entries, not extmarks; skips embeds via `line:sub(open-1, open-1) == "!"`; per-validate heading cache (`filepath → slug_set`); async URL validation |
| `embed.lua` | `{"embed"}` | — | `VaultEmbed` | Virtual text + image placements | Most complex: async content loading, lazy visible-first rendering, embed_sync live updates, table pools, request coalescer |
| `task_hierarchy.lua` | `{"task"}` | — | `vault_task_hierarchy` | Virtual text (`[done/total pct%]`) on parent tasks; hl groups `VaultHierarchyComplete` (100%) / `VaultHierarchyProgress` (partial) | Does NOT scan buffer directly — reads from vault_index `entry.tasks`; `config.hierarchy.debounce_ms = 500`; generation-cached tree building via `filter_utils.is_cache_gen_valid()` + `task_utils.gen_cache()` |

### footnotes.lua Special Handling

Footnotes are more complex than simple pattern highlights because:
1. **Full buffer scan required**: Definitions (`[^id]: text`) can be at the end of the file, far from references
2. **Multi-line definitions**: Continuation lines (4-space indent or tab) extend definitions
3. **Virtual text rendering**: Uses `virt_lines` (not highlights) with border + content lines
4. **Bidirectional mapping**: Each reference needs its definition content for rendering
5. **Orphan detection**: Reports refs without defs and defs without refs

The pipeline can handle Layer 1 tokenization of footnote references (`[^id]`), but the definition parsing and content assembly must remain in the footnotes module. The consumer would read tokens from the pipeline for reference positions, then use its own `parse_all_footnotes_cached()` for definition content:

```lua
pipeline.register_consumer({
  name = "footnotes",
  token_types = { "footnote" },
  ns = vim.api.nvim_create_namespace("VaultFootnote"),
  priority = 70,
  render = function(line_nr, resolved_tokens)
    -- Footnote rendering is too complex for simple spec generation.
    -- References positions come from pipeline; definition content comes from
    -- footnotes.parse_all_footnotes_cached() which does its own full-buffer scan.
    -- Return empty specs; footnotes.lua handles its own extmark lifecycle.
    return {}
  end,
})

-- footnotes.lua reads reference positions from pipeline instead of scanning:
function M.render_footnotes(opts)
  local fn_map = parse_all_footnotes_cached(bufnr)  -- still needed for definitions
  -- Use pipeline tokens for reference positions instead of re-scanning
  for line_nr, token in line_parse.iter_tokens(bufnr, "footnote") do
    local id = token.captures[1]
    local info = fn_map[id]
    if info and info.def_content then
      -- Existing virtual text rendering logic
      render_footnote_vtext(bufnr, line_nr, id, info)
    end
  end
end
```

### embed.lua Special Handling

Embeds are the most complex module to integrate because they have their own extensive infrastructure:

- **Lazy rendering**: Visible lines rendered first via `render_in_range(descs, ctx, top, bot)`, then async background batches via `render_remaining_async()`
- **Table pool recycling**: `table_pool.new(config.pools.embed_descriptor, reset_fn)` → `_desc_pool:acquire()` / `release_batch()` for descriptor objects (pool size: `config.pools.embed_descriptor = 50`)
- **Request coalescer**: `request_coalescer` module deduplicates concurrent `render_embeds()` calls via key `"render_embeds:" .. bufnr`; non-forced calls skip when already pending, forced calls cancel and restart
- **embed_sync**: Live sync subscription for cross-file edit propagation with dependency tracking (`_embed_deps`), `mark_dep_index_dirty()` for lazy inverted index rebuild, `on_index_update()` subscriber uses inverted deps (`_dep_to_bufs`) for O(changed_paths) affected buffer lookup; debounce `config.embed.sync.debounce_ms = 300` (cross-file) / `config.embed.sync.self_debounce_ms = 500` (same-file); lazy subscription via `resource_cleanup.subscription_handle()` with weak state anchor
- **Image placements**: Snacks.image.placement API with immediate + deferred failure detection
- **Generation tracking**: Staleness checks via buffer-local generation counters in `embed_state._embed_descriptors[bufnr].generation`

The pipeline handles token-parsing and change-tracking; embed rendering remains as a separate consumer that receives parsed embed tokens:

```lua
pipeline.register_consumer({
  name = "embeds",
  token_types = { "embed" },
  ns = vim.api.nvim_create_namespace("VaultEmbed"),
  render = function(line_nr, resolved_tokens)
    -- For embeds, Layer 3 produces "embed descriptors" not final extmarks.
    -- The embed module's async renderer picks these up.
    -- Return empty specs here; embed.lua reads from semantic cache directly.
    return {}
  end,
})

-- embed.lua reads from pipeline cache instead of scanning:
-- Currently uses embed_state.iterate_embeds(lines, callback) which calls
-- find_embed_spans(line) per line (returns flat array {s1,e1,s2,e2,...}),
-- then extract_embed_inner(line, s, e).
-- Callback receives: (i, inner, s, e) where i=line number.
-- Pipeline replaces this with pre-tokenized embed positions.
function M.render_embeds(bufnr, opts)
  -- Replace build_descriptors() which uses state.iterate_embeds() with pipeline iteration
  local embed_tokens = line_parse.iter_tokens(bufnr, "embed")
  local descs = {}
  for line_nr, token in embed_tokens do
    descs[#descs + 1] = _desc_pool:acquire()  -- table_pool.new(config.pools.embed_descriptor, reset_fn)
    local desc = descs[#descs]
    desc.lnum = line_nr + 1  -- 1-indexed for embed module
    desc.col_s = token.start_col
    desc.col_e = token.end_col
    desc.inner = token.captures[1]
    desc.is_image = is_image_embed(desc.inner)
    desc.rendered = false
    desc.lines_used = 0
  end
  -- warm_embed_cache(descs, bufpath, arena_scope) pre-reads cross-file targets
  -- Existing lazy render logic: render_in_range(descs, ctx, top, bot) → render_remaining_async
  -- Request coalescer deduplicates via key "render_embeds:" .. bufnr
end
```

### task_hierarchy.lua Integration

`task_hierarchy.lua` is unique among the modules: it does NOT scan the buffer directly. Instead, it reads task data from `vault_index entry.tasks` (parsed by `vault_index_parser.lua` using pattern `^%s*[-*] %[(.)%] `). Its rendering produces virtual text (`[done/total pct%]`) on parent task lines.

Integration with the pipeline is limited to Layer 1 providing task token positions, which `task_hierarchy.lua` could use to validate that its index-derived line numbers are still accurate:

```lua
-- task_hierarchy uses vault_index as primary data source, not buffer scanning.
-- Reads from idx.files[rel_path].tasks (sorted by line number from index).
-- Uses filter_utils.is_cache_gen_valid() for generation-based staleness detection.
-- Renders via nvim_buf_set_extmark(bufnr, ns, line-1, 0, {virt_text=...}).
-- Highlight groups: "VaultHierarchyComplete" (100%) / "VaultHierarchyProgress" (partial).
-- Pipeline integration is optional: task tokens from Layer 1 can serve as a
-- cross-check against index data, but task_hierarchy.lua's 500ms debounce
-- (config.hierarchy.debounce_ms) and generation-based caching already provide
-- good performance.
```

### linkdiag.lua Integration

`linkdiag.lua` produces `vim.diagnostic` entries (not extmarks), so it doesn't participate in the render diff layer. However, it benefits from Layer 1+2:
- **Layer 1**: Wikilink tokens replace its `line:gmatch("()%[%[(.-)%]%]()")` full-buffer scan
- **Layer 2**: Resolution results replace its own vault_index lookups and heading validation
- **Diagnostic generation**: Consumes resolved tokens and emits diagnostic entries for `status == "broken"`

```lua
-- linkdiag.lua reads from pipeline instead of scanning:
-- Currently scans via line:gmatch("()%[%[(.-)%]%]()") with embed skip,
-- then uses link_utils.parse_target() + resolve_link() + get_headings().
-- Maintains per-validate heading_cache (filepath → slug_set) to avoid redundant lookups.
function M.validate(bufnr)
  local diagnostics = {}
  for line_nr, token in line_parse.iter_tokens(bufnr, "wikilink") do
    local resolved = semantic.get_resolved(bufnr, line_nr)
    for _, rt in ipairs(resolved) do
      if rt.token.type == "wikilink" and rt.status == "broken" then
        diagnostics[#diagnostics + 1] = {
          lnum = line_nr,
          col = rt.token.start_col,
          end_col = rt.token.end_col,
          severity = vim.diagnostic.severity.ERROR,  -- or WARN for broken headings
          message = string.format("Note not found: %s", rt.metadata.link_text),
          source = "vault-linkdiag",
          _type = "broken_note",     -- or "broken_heading" or "dead_url"
          _target = rt.metadata.link_text,
          _heading = rt.metadata.heading,    -- for heading validation
          _filepath = rt.target,             -- for heading lookup
        }
      end
    end
  end
  vim.diagnostic.set(ns, bufnr, diagnostics)
end
```

### Viewport Restriction

The pipeline naturally supports viewport-restricted processing. The coordinator already provides viewport-only updates (200ms debounce) vs full updates (30ms debounce). Combined with `link_scan.get_visible_range(bufnr, margin)`:

```lua
-- Only parse/resolve visible lines + margin
local start_line, end_line = link_scan.get_visible_range(bufnr, 5) -- 5-line margin
local relevant_dirty = {}
for _, ln in ipairs(dirty_lines) do
  if ln >= start_line and ln <= end_line then
    relevant_dirty[#relevant_dirty + 1] = ln
  end
end
```

### Navigation Preservation

The coordinator's factory functions (`make_jump()`, `make_scan_nav()`, `cached_positions()`) provide token-type navigation (e.g., `]t`/`[t` for tags, `]h`/`[h` for highlights). These currently rely on per-module scanning during `make_coordinated_update()` to populate `nav_cache`.

With the pipeline, navigation caches can be populated from `line_parse.iter_tokens()` instead:

```lua
-- Before: tag_highlights.scan_tags() populates nav_cache during coordinated_update
-- After: read positions from pipeline cache
local function tag_positions_from_pipeline(bufnr)
  local positions = {}
  for line_nr, token in line_parse.iter_tokens(bufnr, "tag") do
    positions[#positions + 1] = { row = line_nr + 1, col = token.start_col + 1 } -- 1-indexed
  end
  return positions
end
```

---

## Configuration

```lua
-- config.lua additions (alongside existing config sections)
M.pipeline = {
  enable = true,                     -- Master toggle for layered pipeline
  line_cache_max = 10000,            -- Max cached lines per buffer before eviction
  resolution_debounce_ms = 50,       -- Debounce Layer 2 resolution after parse
  full_reparse_threshold = 100,      -- If >100 dirty lines, do full reparse instead
}

-- Existing config values (NOTE: per-module debounce_ms values are currently UNUSED —
-- the coordinator overrides with its own adaptive 30ms full / 200ms viewport debounce.
-- These values exist in config.lua but are not consumed by the coordinator's schedule()):
-- M.wikilink_highlights.debounce_ms = 150  (unused — coordinator overrides)
-- M.tag_highlights.debounce_ms = 200       (unused — coordinator overrides)
-- M.highlight_marks.debounce_ms = 200      (unused — coordinator overrides)
-- M.footnotes.debounce_ms = 200            (unused — coordinator overrides)
-- M.footnotes.render = false               (footnotes off by default)
-- M.footnotes.auto_render = false          (conditional coordinator registration: only if render AND auto_render)
-- M.footnotes.render_delay_ms = 200        (BufReadPost auto-render delay)
-- M.hierarchy.debounce_ms = 500            (task_hierarchy uses its own debounce via event_dispatch)
-- M.embed.render_delay_ms = 150            (embed uses its own debounce, independent of coordinator)
-- M.embed.lazy_scroll_debounce_ms = 80     (embed scroll handler, independent of coordinator)
-- M.embed.sync.debounce_ms = 300           (embed_sync cross-file re-render debounce)
-- M.embed.sync.self_debounce_ms = 500      (embed_sync same-file re-render debounce)
-- M.autolink.debounce_ms = 300             (autolink, independent of coordinator)
-- M.inline_fields.debounce_ms = 200        (unused — coordinator overrides)
```

---

## Implementation Notes

### Line Number Stability on Multi-Line Edits

When lines are inserted or deleted, all line numbers after the edit point shift. The `on_bytes` callback reports `old_end_row` vs `new_end_row`; when these differ, Layer 0 signals a full reparse because the line-keyed caches (Layer 1, Layer 2) have stale keys.

An optimization for a later iteration: instead of full reparse, shift cached entries by the delta. For an insertion of N lines at row R, entries at row >= R get their keys incremented by N. This preserves the cache for the (typically large) unaffected portion of the buffer.

### Pattern Consolidation

The `TOKEN_PATTERNS` table in Layer 1 becomes the single source of truth for all vault-relevant patterns. Current pattern locations that would be consolidated:

| Current Location | Pattern | Consolidated Into |
|-----------------|---------|-------------------|
| `wikilink_highlights.lua` iterative `find("%[%[")` + `find("]]")` + `sub()` | Iterative find/sub scanning | `TOKEN_PATTERNS` wikilink entry |
| `tag_highlights.lua` `#[a-zA-Z][a-zA-Z0-9_/-]*` + `valid_tag_start()` + `is_hex_color()` | Pattern + multi-step validation | `TOKEN_PATTERNS` tag entry with `validate` flag |
| `highlights.lua` `HIGHLIGHT_PATTERN = "==[^=]+=="` (`string.find` in loop) | Local constant | `TOKEN_PATTERNS` highlight entry |
| `footnotes.lua` `"%[%^([%w_-]+)%]"` | Local pattern | `TOKEN_PATTERNS` footnote entry |
| `embed_state.lua` `M.EMBED_PAT = "!%[%[.-%]%]"` | Exported constant | `TOKEN_PATTERNS` embed entry |
| `vault_index_parser.lua` `"^%s*[-*] %[(.)%] "` | Parser pattern | `TOKEN_PATTERNS` task entry |

**Important**: Most modules use Lua pattern matching, but `wikilink_highlights.lua` uses iterative `find/sub` scanning (not a single pattern or gmatch). The consolidated tokenizer must produce equivalent results to all current approaches, particularly for edge cases like nested brackets, escaped characters, embed-vs-wikilink disambiguation (embeds are skipped by checking for preceding `!`), and the fact that `wikilink_highlights.lua` does NOT apply code exclusion (all wikilinks are highlighted regardless of code context). Additionally, `footnotes.lua` does NOT apply code exclusion despite being in the coordinator (`_code_excl` is accepted but unused).

### Backward Compatibility

During migration, the pipeline coexists with direct-scanning modules via `config.pipeline.enable`. The coordinator checks this flag and falls back to legacy per-updater dispatch. This allows incremental migration: migrate one module at a time, verify correctness, then proceed to the next.

Factory functions (`make_toggle`, `make_jump`, `make_coordinated_update`, `make_scan_nav`) continue to work unchanged — they just receive tokens from the pipeline cache instead of direct buffer scanning.

### Memory Considerations

Layer 1 stores tokenized data per line. For a 1000-line buffer with an average of 2 tokens per line, this is approximately 2000 small tables. At ~200 bytes per table (Lua overhead), this is ~400 KB — modest compared to the repeated string allocations from 5 regex passes.

The `line_cache_max` config bounds this for extremely large buffers. When exceeded, lines outside the visible range are evicted first (LRU by access).

The existing `render_arena` allocator can be used for Layer 3's temporary spec tables, matching the current pattern where `begin_scope()` / `end_scope()` wraps the coordinator's `run_all()`.

### Interaction with vault_index Generation

Layer 2 tracks the `vault_index._generation` number (incremented on every mutation via `_notify_update(context?)`). When the index rebuilds (new files added, links changed), Layer 2 detects the generation mismatch and re-resolves all tokens without re-parsing. This is the correct behavior: a new file being created can turn "broken" links into "valid" ones across all open buffers.

The vault index provides a subscriber system (`index:subscribe(fn)` → unsubscribe function) that the pipeline can use directly instead of the `User VaultCacheInvalidate` autocmd. Subscribers receive `(generation, context)` where context includes `{ changed_paths?, deleted_paths? }`. This is already used by `embed_sync.on_index_update()` (via `resource_cleanup.subscription_handle()` for weak subscription management) and could be adopted by the pipeline for Layer 2 cache invalidation.

The vault index also provides `snapshot()` and `snapshot_files()` for read-consistent access to index data. Layer 2 resolution should use `index:resolve_name(name)` which checks `_name_index` (by basename) then `_alias_index` (by alias). Vault index entries use lazy derived fields via `__index` metameta: `abs_path`, `basename`, `basename_lower`, `folder`, `tag_set`, `heading_slugs`, `block_id_set`.

### Interaction with Existing Caching

Several existing caches interact with the pipeline:

| Cache | Location | Purpose | Pipeline Interaction |
|-------|----------|---------|---------------------|
| Code exclusion | `link_scan._code_exclusion_cache` | Treesitter-based code region detection | Shared — pipeline passes `code_excl` to Layer 1 |
| Frontmatter range | `link_scan._frontmatter_cache` | YAML frontmatter line range | Shared — pipeline skips frontmatter lines |
| Footnote map | `footnotes._fn_cache` | Changedtick-validated full parse | Separate — footnotes still needs definition parsing |
| Nav positions | Per-module `_nav_cache` | Changedtick-validated position arrays | Replaced — pipeline provides `iter_tokens()` |
| Embed descriptors | `embed_state._embed_descriptors[bufnr]` = `{generation, list, async_timer}` | Generation-tracked descriptor lists; also `_embed_deps`, `_sync_timers`, `_scroll_timers`, `_image_retry_fired`, `image_placements` per buffer | Replaced — pipeline provides embed tokens; state dicts remain for async render lifecycle |
| Task tree | `task_hierarchy._vtext_cache`, `_fold_state`, `_tree_cache` | Generation-cached tree roots (via `filter_utils.is_cache_gen_valid()`), LRU fold state, tree view cache (via `task_utils.gen_cache()`) | Separate — reads from vault_index, not buffer |

### Handling Modules with Complex Rendering

Three modules have rendering too complex for simple extmark spec generation:

1. **footnotes.lua**: Virtual text lines with borders, continuation line parsing, orphan detection. Consumer returns empty specs; module handles its own extmark lifecycle using pipeline tokens for reference positions.

2. **embed.lua**: Async content loading, lazy visible-first rendering, image placements, live sync, table pool recycling, request coalescing. Consumer returns empty specs; module reads embed tokens from pipeline cache to build descriptors instead of scanning buffer.

3. **task_hierarchy.lua**: Tree building from vault_index data, LRU fold state, dedicated float view. Operates independently from the pipeline since it doesn't scan the buffer directly.

---

## Validation

1. **Correctness**: For each migrated module, verify that extmark output is identical to the pre-pipeline version on a representative set of vault files
2. **Performance**: Measure `nvim_buf_get_lines` call count before/after with `:VaultPipelineDebug`
3. **Incremental accuracy**: Edit a single line and verify only that line is re-parsed (add counters to `tokenize_line`)
4. **Multi-line edit handling**: Insert/delete lines and verify the full-reparse fallback produces correct results
5. **Index generation change**: Modify vault index and verify all open buffers re-resolve without re-parsing
6. **Memory**: Measure Lua memory (`collectgarbage("count")`) with pipeline vs without on a 2000-line buffer
7. **Navigation preservation**: Verify `]t`/`[t`, `]h`/`[h`, `]w`/`[w` navigation works correctly with pipeline-sourced positions
8. **Pattern equivalence**: For each token type, compare pipeline tokenizer output against original module's pattern matching on a corpus of vault files (especially edge cases: nested brackets, embeds inside wikilinks, tags in code blocks, hex color false positives)
9. **Arena integration**: Verify `render_arena.begin_scope()` / `end_scope()` lifecycle is preserved
10. **Fallback mode**: Verify `config.pipeline.enable = false` correctly falls back to legacy per-updater dispatch

---

## Expected Impact

### Buffer Read Reduction

| Scenario | Before | After | Reduction |
|----------|--------|-------|-----------|
| Single-char edit (typing) | 5 `nvim_buf_get_lines` calls (4 coordinator visible-range + 1 embed full) | 1 call for 1 line | ~96% |
| Multi-line paste (10 lines) | 5 range/full scans | 1 call for 10 lines | ~93% |
| BufEnter (initial render) | 5-6 full-buffer scans | 1 full-buffer scan | ~83% |
| Vault index rebuild | 1-2 full-buffer rescans (linkdiag + embed re-validate) | 0 buffer reads (re-resolve cached tokens) | 100% |

### Regex Pass Reduction

Single parse pass produces all token types. Five independent pattern scans per visible-range update collapse to one. Tag validation (hex color check, predecessor validation) is folded into the tokenizer.

### Extmark Churn Reduction

Current modules clear and re-set all extmarks in their namespace on every update via `highlight_coordinator.clear_extmarks()`. The render diff layer only sets/deletes extmarks that actually changed. For a single-character edit on a line with one wikilink, this means 4 extmark updates (the wikilink's brackets + content) instead of clearing and re-setting all extmarks in the visible range.

### Latency (Single-Line Edit, 500-Line Buffer)

| Phase | Before | After |
|-------|--------|-------|
| Buffer read | 5 × ~0.1ms = 0.5ms | 1 × 0.01ms = 0.01ms |
| Pattern matching | 5 × ~0.5ms = 2.5ms | 1 × 0.05ms = 0.05ms (single line) |
| Resolution | 1 × 0.2ms (linkdiag full scan) | 1 × 0.02ms (single line) |
| Extmark apply | 4 × clear+set ~0.3ms = 1.2ms | 1 × diff ~0.05ms |
| **Total** | **~4.4ms** | **~0.13ms** |
