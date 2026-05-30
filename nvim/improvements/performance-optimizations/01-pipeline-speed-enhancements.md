# 01. Transform Pipeline Speed Enhancements

**Priority:** MEDIUM
**Phase:** 3 (Architecture) — post Document 27 implementation
**Dependencies:** Document 27 (Layered Transform Pipeline) — **fully implemented and active**
**Complements:** Document 28 (Pattern Compilation Cache), Document 35 (Invalidation Region Tracking), Document 42 (Content-Hash Change Detection), Document 38 (Syntactic Content Chunking)

---

## Current State (as of 2026-03-23, verified current)

Document 27's layered transform pipeline is **fully implemented and production-active** (always-on, no toggle — `config.pipeline.enable` was removed). The four-layer architecture is operational:

- **Layer 0** (`line_tracker.lua`): `on_bytes`-based dirty line tracking via `nvim_buf_attach`
- **Layer 1** (`line_parse_cache.lua`): Single-pass tokenizer producing 9 token types
- **Layer 2** (`semantic_resolution.lua`): Vault-index-backed resolution (valid/broken/external status)
- **Layer 3** (`render_diff.lua`): Key-based extmark diffing (set/del only changed extmarks)

Supporting infrastructure is also deployed:
- `transform_pipeline.lua`: Orchestrator with consumer registration
- `pipeline_consumers.lua`: 4 built-in consumers (wikilinks priority 30, tags 40, inline_fields 45, highlights 50)
- `render_arena.lua`: Scope-based table pooling (200 initial, 2000 max)
- `event_coalescer.lua`: Adaptive BufEnter coalescing (configurable base delay, 200ms rapid-switch threshold)
- `highlight_coordinator.lua`: Always-pipeline dispatch (legacy per-updater mode removed), 30ms full / 200ms incremental debounce
- `viewport.lua`: Viewport range tracking with `newly_visible()` and `render_strategy()`

---

## Problem

Despite the pipeline being operational, three additional speed gains remain unimplemented:

1. **Layer 1's tokenizer uses iterative `string.find` loops** — scanning 9 token types sequentially with per-type `while true` loops, a `consumed[]` overlap-checking table, and a final `table.sort()`. This is the hot path (called per line per edit).

2. **"Dirty" lines may have unchanged content** — `on_bytes` fires for any byte change, but undo, whitespace-only edits outside tokens, or overwriting with identical text produce identical tokens. The current `update()` always re-tokenizes every dirty line without comparing content. Document 42 addresses this at the file level, Document 38 at the chunk level, but neither operates at line granularity within Layer 1.

3. **Layer 3 calls `nvim_buf_set_extmark` per extmark** — `render_diff.apply_diff()` minimizes *which* extmarks are updated, but each surviving update is still a separate `pcall`-wrapped Lua→C API call. Document 64 (pcall batching) reduces pcall wrapping overhead but doesn't batch the API calls themselves.

### Current Hot Path Profile (Single-Line Edit)

```
line_parse_cache.tokenize_line():
  1. Embeds:        while line:find("!%[%[", pos, false)     ← scan for ![[...]]
  2. Wikilinks:     while line:find("%[%[", pos, false)      ← scan for [[...]], skip !-prefixed
  3. Footnotes:     while line:find("%[%^([%w_-]+)%]", pos)  ← scan for [^id]
  4. Highlights:    while line:find("==[^=]+==", pos)        ← scan for ==text==
  5. Tags:          while line:find("#", pos, true)           ← hash search + regex extract
  6. Tasks:         line:match("^%s*[-*] %[([ xX/-])%]")     ← single check at SOL (captures checkbox state)
  7. Headings:      line:match("^(#+)%s")                    ← single check at SOL
  8. Inline Fields: inline_fields.parse_line(line_text)      ← delegated to inline_fields module
  9. Block IDs:     line:match("%^(blk%-[%w]+)%s*$")         ← single check at EOL (allows trailing whitespace)
  overlap check via consumed[] per match                     ← O(n_consumed) per match
  table.sort(tokens, by start_col)                           ← sort after all 9 passes

render_diff.apply_diff():
  for each removed old_spec:
    pcall(nvim_buf_del_extmark, bufnr, ns, id)           ← individual pcall + C call
  for each new/changed spec:
    pcall(nvim_buf_set_extmark, bufnr, ns, line, col, opts)  ← individual pcall + C call
```

### Current Cache Structure (No Content Dedup)

```lua
-- line_parse_cache.lua (actual, lines 17-18):
---@type table<number, { tick: number, lines: table<number, LineToken[]> }>
local _cache = {}
-- No `texts` field — every dirty line is always re-tokenized
```

### Current LineToken Type (line_parse_cache.lua:9-15)

```lua
---@class LineToken
---@field type string "wikilink"|"tag"|"task"|"embed"|"footnote"|"heading"|"block_id"|"highlight"|"inline_field"
---@field start_col number 0-indexed byte offset
---@field end_col number 0-indexed byte offset (exclusive)
---@field text string raw matched text
---@field subtype? string e.g. "embed_image", "footnote_def"
---@field captures? table type-specific parsed fields
```

---

## Solution

### Enhancement 1: LPEG Single-Pass Tokenizer

Replace the 9 sequential `string.find` loops in `line_parse_cache.tokenize_line()` with an LPEG grammar. LPEG compiles to a bytecode VM in LuaJIT, handles priority/longest-match natively, and eliminates:
- The 9 sequential `while true` / `string.find` scanning passes (including delegated inline_fields.parse_line())
- The `consumed[]` overlap-checking table and `overlaps_consumed()` function
- The final `table.sort` (LPEG matches in document order by construction)

```lua
-- line_parse_cache.lua — LPEG tokenizer replacement

local lpeg = require("lpeg")
local P, R, S, C, Cp, Ct, Cg, Cc, V = lpeg.P, lpeg.R, lpeg.S, lpeg.C, lpeg.Cp, lpeg.Ct, lpeg.Cg, lpeg.Cc, lpeg.V

--- Build a capture that produces a LineToken table.
---@param type_name string token type
---@param pattern userdata LPEG pattern with one capture for inner text
---@return userdata LPEG pattern producing {type, start_col, end_col, text, captures}
local function token_capture(type_name, pattern)
  return Ct(
    Cp() *               -- start position (1-indexed)
    C(pattern) *          -- full matched text
    Cp() *               -- end position (exclusive, 1-indexed)
    Cc(type_name)         -- token type constant
  )
end

-- Individual token patterns (order = priority: first match at a position wins)
local embed    = P"![[" * (1 - P"]]")^1 * P"]]"
local wikilink = P"[[" * (1 - P"]]")^1 * P"]]"
local footnote = P"[^" * (R"az" + R"AZ" + R"09" + S"_-")^1 * P"]"
local highlight_mark = P"==" * (1 - P"==")^1 * P"=="

-- Tag: # followed by letter, then alphanum/_/- ; requires whitespace/punct/SOL before #
-- Validated post-match for hex colors and predecessor character
local tag_body = (R"az" + R"AZ") * (R"az" + R"AZ" + R"09" + S"_/-")^0
local tag      = P"#" * tag_body

-- Inline fields: [key:: value] or (key:: value)
local inline_field_bracket = P"[" * (R"az" + R"AZ" + R"09" + S"_-")^1 * P"::" * (1 - P"]")^1 * P"]"
local inline_field_paren   = P"(" * (R"az" + R"AZ" + R"09" + S"_-")^1 * P"::" * (1 - P")")^1 * P")"

-- Structural tokens (line-start only)
local heading  = P"#"^1 * P" "
local task     = S" \t"^0 * S"-*" * P" [" * S"xX /-" * P"] "
local block_id = P"^" * P"blk-" * (R"az" + R"AZ" + R"09")^1 * S" \t"^0 * -1  -- at EOL (trailing whitespace ok)

-- Combined scanner: try each token pattern, fall through on single char
local token = token_capture("embed", embed)
            + token_capture("wikilink", wikilink)
            + token_capture("footnote", footnote)
            + token_capture("highlight", highlight_mark)
            + token_capture("tag", tag)
            + token_capture("inline_field", inline_field_bracket)
            + token_capture("inline_field", inline_field_paren)
            + token_capture("heading", heading)
            + token_capture("task", task)
            + token_capture("block_id", block_id)

local scanner = Ct((token + P(1))^0)

--- Tokenize a line using LPEG grammar.
--- Produces tokens in document order (no sort needed).
--- Post-filters: tag validation (hex color, predecessor char), code exclusion.
---@param line_text string
---@param line_nr number 0-indexed
---@param code_excl fun(row: number, col: number): boolean
---@return LineToken[]
function M.tokenize_line(line_text, line_nr, code_excl)
  local raw = scanner:match(line_text)
  if not raw then return {} end

  local tokens = {}
  local is_heading_line = line_text:match("^#+ ") ~= nil

  for _, t in ipairs(raw) do
    local start_pos, text, end_pos, ttype = t[1], t[2], t[3], t[4]
    local col0 = start_pos - 1  -- 0-indexed
    local col1 = end_pos - 1    -- 0-indexed exclusive

    -- Per-type filtering
    if ttype == "tag" then
      if is_heading_line then goto continue end
      if not valid_tag_start(line_text, start_pos) then goto continue end
      local tag_name = text:sub(2) -- strip #
      if is_hex_color(tag_name) then goto continue end
    end

    -- Code exclusion (skip for wikilinks, embeds, footnotes — mirrors current behavior)
    local skip_code_excl = (ttype == "embed" or ttype == "wikilink" or ttype == "footnote")
    if not skip_code_excl and code_excl(line_nr, col0) then
      goto continue
    end

    tokens[#tokens + 1] = {
      type = ttype,
      start_col = col0,
      end_col = col1,
      text = text,
      captures = extract_captures(ttype, text),
    }

    ::continue::
  end

  return tokens
end
```

**Why LPEG over Lua patterns:**

| Aspect | Current `string.find` loops | LPEG grammar |
|--------|----------------------|--------------|
| Passes over input | 9 (one per token type, incl. delegated inline_fields) | 1 |
| Overlap detection | Manual `consumed[]` check via `overlaps_consumed()` | Implicit (ordered alternatives) |
| Output ordering | Requires `table.sort` | In-order by construction |
| Match priority | Scan order (embed before wikilink, etc.) | Grammar alternatives (explicit) |
| LuaJIT optimization | JIT-compiled per call | Compiled once, bytecode VM |
| Backtracking | Per-type restarts from `pos` | PEG: no backtracking past committed match |

**Expected speedup:** 2-5x for Layer 1 tokenization on typical lines with 2-4 tokens.

**LPEG availability:** Bundled with LuaJIT (which Neovim uses). `require("lpeg")` works out of the box — no external dependency.

### Enhancement 2: Line-Level Content-Hash Dedup

Extend the cache structure in `line_parse_cache.lua` to store raw line text alongside cached tokens. When a line is marked dirty by `on_bytes`, compare the new line text against the stored text before re-tokenizing. This catches:
- Undo operations (content reverts to cached state)
- Whitespace-only changes outside token boundaries
- Overwriting with identical text (paste-over-same)
- Reformatting that doesn't affect token content

**Current cache structure** (`line_parse_cache.lua:17-18`):
```lua
---@type table<number, { tick: number, lines: table<number, LineToken[]> }>
local _cache = {}
```

**Proposed change** — add `texts` field:
```lua
---@type table<number, { tick: number, lines: table<number, LineToken[]>, texts: table<number, string> }>
local _cache = {}
```

**Current `update()` function** (`line_parse_cache.lua:337-368`) always re-tokenizes:
```lua
function M.update(bufnr, line_nrs, code_excl)
  -- Line 338-342: Initialize buffer cache if missing with { tick = 0, lines = {} }
  -- Line 343: Update changedtick via nvim_buf_get_changedtick(bufnr)
  if not line_nrs then
    -- Line 345-351: Full parse mode — fetch all lines, clear cache, tokenize all
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    buf_cache.lines = {}
    for i, text in ipairs(lines) do
      buf_cache.lines[i - 1] = M.tokenize_line(text, i - 1, code_excl)  -- always re-tokenizes
    end
  else
    -- Line 352-362: Incremental mode — re-parse only dirty lines, delete cache for removed lines
    for _, ln in ipairs(line_nrs) do
      local text = vim.api.nvim_buf_get_lines(bufnr, ln, ln + 1, false)[1]
      if text then
        buf_cache.lines[ln] = M.tokenize_line(text, ln, code_excl)  -- always re-tokenizes
      else
        buf_cache.lines[ln] = nil  -- line was deleted
      end
    end
  end
  -- Line 365-367: Evict overflow via evict_if_needed() if cache exceeds config.pipeline.line_cache_max
end
```

**Proposed replacement** — skip tokenization when text unchanged:
```lua
function M.update(bufnr, line_nrs, code_excl)
  local buf_cache = _cache[bufnr]
  if not buf_cache then
    buf_cache = { tick = 0, lines = {}, texts = {} }
    _cache[bufnr] = buf_cache
  end
  buf_cache.tick = vim.api.nvim_buf_get_changedtick(bufnr)

  local reparse_count = 0

  if not line_nrs then
    -- Full parse
    local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local new_lines = {}
    local new_texts = {}
    for i, text in ipairs(all_lines) do
      local ln = i - 1
      if buf_cache.texts[ln] == text then
        -- Content unchanged: reuse cached tokens
        new_lines[ln] = buf_cache.lines[ln]
      else
        new_lines[ln] = M.tokenize_line(text, ln, code_excl)
        reparse_count = reparse_count + 1
      end
      new_texts[ln] = text
    end
    buf_cache.lines = new_lines
    buf_cache.texts = new_texts
  else
    -- Incremental: only re-parse dirty lines with changed content
    for _, ln in ipairs(line_nrs) do
      local text = vim.api.nvim_buf_get_lines(bufnr, ln, ln + 1, false)[1]
      if text then
        if buf_cache.texts[ln] == text then
          -- Content unchanged: skip tokenization entirely
          goto continue
        end
        buf_cache.lines[ln] = M.tokenize_line(text, ln, code_excl)
        buf_cache.texts[ln] = text
        reparse_count = reparse_count + 1
      else
        buf_cache.lines[ln] = nil
        buf_cache.texts[ln] = nil
      end
      ::continue::
    end
  end

  return reparse_count
end
```

**Why store raw text instead of a hash:**
- Lua string interning means `==` on equal strings is a pointer comparison (O(1)) — faster than computing SHA-256
- Memory overhead is negligible: the strings already exist in Neovim's buffer; Lua interns duplicates
- No hash collision risk

**Interaction with Document 42 (file-level hash) and Document 38 (chunk-level hash):**
- Doc 42 avoids re-reading files from disk when file content hasn't changed
- Doc 38 avoids re-parsing file chunks when chunk content hasn't changed
- This enhancement avoids re-tokenizing *individual lines* when line content hasn't changed
- All three operate at different granularities and are complementary (file → chunk → line)

**Expected impact:** Skips ~30-50% of "dirty" line tokenizations during typical editing (undo cycles, reformatting, code completion accept-then-undo).

### Enhancement 3: Batched Extmark API via `nvim_call_atomic`

The current `render_diff.apply_diff()` (`render_diff.lua:57-94`) minimizes *which* extmarks need updating but wraps each operation in its own `pcall` and crosses the Lua→C boundary individually:

```lua
-- Current render_diff.lua:
-- Line 74: Delete old extmarks
pcall(vim.api.nvim_buf_del_extmark, bufnr, old_spec.ns, old_spec._id)    -- per-extmark pcall + C call (error silently swallowed)
-- Line 86: Set new/updated extmarks
local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, spec.ns, spec.line, spec.col, spec.opts)  -- per-extmark pcall + C call
if ok then spec._id = id end  -- Line 87: store returned extmark ID
```

**Note:** On pcall failure for `nvim_buf_set_extmark`, `spec._id` remains unset, which silently breaks ID tracking on subsequent diffs. The module also exports `M.invalidate(bufnr)` (lines 98-100) which clears `_prev_specs[bufnr] = nil`. Total file: 103 lines.

**Proposed replacement** — batch all operations via `nvim_call_atomic`:
```lua
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

  -- Build atomic call batch
  local calls = {}

  -- Remove old extmarks on changed lines that are no longer present
  for key, old_spec in pairs(prev) do
    if changed_lines[old_spec.line] then
      if not new_by_key[key] then
        calls[#calls + 1] = { "nvim_buf_del_extmark", { bufnr, old_spec.ns, old_spec._id } }
      end
    else
      next_prev[key] = old_spec
    end
  end

  -- Set new/updated extmarks on changed lines
  local set_indices = {} -- track which calls are set_extmark for ID extraction
  for key, spec in pairs(new_by_key) do
    local old = prev[key]
    if not old or not opts_equal(old.opts, spec.opts) then
      calls[#calls + 1] = { "nvim_buf_set_extmark", { bufnr, spec.ns, spec.line, spec.col, spec.opts } }
      set_indices[#calls] = { key = key, spec = spec }
    else
      spec._id = old._id
    end
  end

  -- Execute all operations in one Lua→C boundary crossing
  if #calls > 0 then
    local results, err = vim.api.nvim_call_atomic(calls)
    if not err and results then
      -- Extract extmark IDs from set_extmark results
      for idx, info in pairs(set_indices) do
        local result = results[idx]
        if result then
          info.spec._id = result
        end
      end
    end
  end

  _prev_specs[bufnr] = next_prev
end
```

**When this matters:**
- A wikilink produces 3-4 extmarks (open bracket, close bracket, target, optional heading/alias)
- A line with 3 wikilinks and 2 tags = 3×4 + 2×2 = 16 extmarks
- Editing that line: up to 32 API calls (16 delete + 16 set) → 1 `nvim_call_atomic` call

**Interaction with Document 64 (pcall batching):**
- Doc 64 reduces pcall wrapping overhead by using a single pcall around an entire render loop
- This enhancement reduces Lua→C API call overhead by batching the actual API operations
- Complementary: use a single pcall around the `nvim_call_atomic` call

**Expected speedup:** 1.5-2x for Layer 3 render application, more significant on lines dense with tokens.

---

## Integration with Active Pipeline

These three enhancements slot into the **already-operational** pipeline architecture:

```
                    TextChanged / TextChangedI
                          │
                    event_dispatch.lua
                          │
              highlight_coordinator.schedule(bufnr, opts)
                          │ debounce: 30ms (full) / 200ms (viewport)
                          ▼
              highlight_coordinator.run_all(bufnr, opts)
                          │ arena scope: render_arena.begin_scope()
                          │ code_excl: link_scan.build_code_exclusion(bufnr)
                          ▼
              transform_pipeline.run(bufnr, code_excl, opts)
                          │
              ┌───────────────────────┐
              │  Layer 0: Buffer      │  on_bytes change tracking
              │  line_tracker.lua     │  consume() → dirty_lines or nil (full)
              └───────────┬───────────┘
                          │ dirty_lines = {42} or nil
                          ▼
              ┌───────────────────────┐
              │  Layer 1: Line Parse  │  ← Enhancement 1: LPEG tokenizer
              │  line_parse_cache.lua │  ← Enhancement 2: content dedup
              │                       │     (skip if texts[ln] == text)
              │  Current: 9 sequential│
              │  string.find loops +  │
              │  consumed[] + sort    │
              └───────────┬───────────┘
                          │ tokens cached in _cache[bufnr].lines[ln]
                          ▼
              ┌───────────────────────┐
              │  Layer 2: Semantic    │  vault_index resolution
              │  semantic_resolution  │  generation-based invalidation
              │  .lua                │
              └───────────┬───────────┘
                          │ resolved tokens with status/target/metadata
                          ▼
              ┌───────────────────────┐
              │  Consumers            │  pipeline_consumers.lua
              │  wikilinks (pri 30)   │  → ExtmarkSpec[] per line
              │  tags (pri 40)       │
              │  inline_fields (45)  │
              │  highlights (pri 50) │
              └───────────┬───────────┘
                          │ all specs aggregated
                          ▼
              ┌───────────────────────┐
              │  Layer 3: Render      │  ← Enhancement 3: nvim_call_atomic
              │  render_diff.lua     │     batch all set/del operations
              │                       │
              │  Current: per-extmark │
              │  pcall() + C call    │
              └───────────────────────┘
```

---

## Configuration

```lua
-- config.lua (actual M.pipeline, lines 888-891):
M.pipeline = {
  -- Pipeline is always active (enable toggle removed)
  line_cache_max = 10000,            -- Max cached lines per buffer before eviction
  full_reparse_threshold = 100,      -- If >N dirty lines, do full reparse instead
}

-- Related viewport config (lines 896-900):
M.viewport = {
  padding_lines = 50,
  cleanup_threshold = 3.0,
  full_buffer_threshold = 200,       -- Files ≤200 lines get full=true on BufEnter
}

-- New (proposed additions to M.pipeline):
M.pipeline = {
  -- ... existing fields (line_cache_max, full_reparse_threshold) ...
  use_lpeg = true,                   -- Use LPEG tokenizer (false = fallback to string.find loop)
  content_dedup = true,              -- Skip re-tokenizing lines with unchanged text
  batch_extmarks = true,             -- Use nvim_call_atomic for extmark operations
}
```

---

## Implementation Notes

### LPEG Pattern Equivalence

The LPEG grammar must produce identical results to the current `tokenize_line()` implementation in `line_parse_cache.lua` (lines 65-284) for all edge cases:

| Edge Case | Current Behavior (line_parse_cache.lua) | LPEG Must Match |
|-----------|-----------------|-----------------|
| `![[note]]` | Matched as "embed" in pass 1 (line 69-91), consumed range prevents wikilink match in pass 2 | `embed` alternative before `wikilink` in grammar |
| `[[note]]` without preceding `!` | Matched as "wikilink" in pass 2 (line 93-122), embed skip via `line:sub(open - 1, open - 1) == "!"` | `wikilink` alternative matches only when `embed` fails |
| `[[note]] [[other]]` | Two separate wikilink tokens via `pos = close + 2` advancement | LPEG alternatives restart after each match |
| `#fff` (hex color) | Rejected by `is_hex_color()` post-filter (line 35-39) | Post-filter preserved (cannot express in PEG cleanly) |
| `#tag` at line start | Accepted: `valid_tag_start()` returns true for `pos <= 1` (line 25-29) | `valid_tag_start()` post-filter preserved |
| `## Heading` line | Tags skipped on heading lines (implicit via heading match consuming `#` chars) | `is_heading_line` pre-check preserved |
| Wikilinks in code blocks | NOT excluded (wikilinks/embeds skip code_excl in current tokenizer) | `skip_code_excl` per-type flag preserved |
| Footnotes in code blocks | NOT excluded (footnotes skip code_excl in current tokenizer) | `skip_code_excl` per-type flag preserved |
| `[^id]` inside `[[note]]` | Wikilink consumes range first (pass 2), footnote pass 3 sees overlap via `consumed[]` | LPEG ordered choice: wikilink before footnote |
| `==text==` in code blocks | Excluded via `code_excl` in pass 4 (lines 150-168) | `code_excl` applied for highlight type |
| Inline fields in code blocks | Excluded via `code_excl` in pass 8 (lines 241-264) | `code_excl` applied for inline_field type |
| `[key:: value]` inline field | Delegated to `inline_fields.parse_line()` in pass 8 (lines 241-264); code_excl applied | LPEG inline_field patterns for bracket/paren forms |
| `^blk-abc123  ` (trailing ws) | Accepted: pattern `%^(blk%-[%w]+)%s*$` allows trailing whitespace (pass 9, lines 266-279) | LPEG: `S" \t"^0 * -1` after block ID body |

### Content Dedup Memory Overhead

Storing raw line text alongside tokens approximately doubles per-line memory:
- Before: ~200 bytes/line (token tables only)
- After: ~200 + avg_line_length bytes/line (~260 bytes for 60-char avg lines)

For a 1000-line buffer: ~260 KB vs ~200 KB — a 30% increase that pays for itself by avoiding redundant tokenization. Lua string interning means duplicate lines share storage.

### nvim_call_atomic Return Value Handling

`nvim_call_atomic` returns `{results, error}`:
- `results` is an array of return values, one per call
- `nvim_buf_set_extmark` returns the extmark ID (needed for `_id` tracking in render diff)
- `nvim_buf_del_extmark` returns boolean (can be ignored)
- On partial failure, `error` contains the index and error message; preceding calls succeeded

The implementation must extract extmark IDs from the results array to maintain the `_prev_specs` identity tracking that `render_diff.lua` relies on.

---

## Validation

1. **LPEG equivalence**: Run both tokenizers on a corpus of vault files, diff outputs per-line. Zero differences required before switching default.
2. **Content dedup correctness**: Verify that `reparse_count` from `update()` is always <= total dirty lines. Add `:VaultPipelineDebug` counter showing skipped-vs-reparsed ratio.
3. **Atomic batching**: Verify extmark IDs are correctly extracted from `nvim_call_atomic` results. Test with mixed set/del batches.
4. **LPEG availability**: Guard `require("lpeg")` with pcall; fall back to `string.find` loop if unavailable (defensive, but LuaJIT always has it).
5. **Regression**: All existing highlight/tag/embed/footnote visual tests must pass unchanged.

---

## Expected Impact

### Combined Latency (Single-Line Edit, 500-Line Buffer)

| Phase | Current Baseline | With Enhancements | Improvement |
|-------|----------------|-------------------|-------------|
| Layer 1: tokenize_line | 0.05ms (1 line, 9 string.find passes) | 0.01-0.02ms (LPEG single pass) | 2-5x |
| Layer 1: content check | — | 0.001ms (string ==) | skips 30-50% of lines |
| Layer 2: resolution | 0.02ms | 0.02ms (unchanged) | — |
| Layer 3: apply extmarks | 0.05ms (individual pcall + C calls) | 0.025-0.03ms (atomic batch) | 1.5-2x |
| **Total** | **~0.13ms** | **~0.06-0.08ms** | **~1.6-2x** |

### Throughput (Full Buffer Reparse, 2000 Lines)

| Phase | Current Baseline | With Enhancements | Improvement |
|-------|----------------|-------------------|-------------|
| Layer 1: all lines | 2000 × 0.05ms = 100ms | 2000 × 0.015ms = 30ms (LPEG) | ~3x |
| Layer 1: with dedup (undo scenario) | 100ms | 30ms × 0.5 = 15ms (50% skip) | ~6.5x |
| Layer 3: all extmarks | ~5ms | ~2.5ms (atomic) | ~2x |

---

## Codebase-Specific Implementation Details

The following details are derived from the actual vault codebase at `lua/andrew/vault/` and verified against the current source (2026-03-23).

### Current Tokenizer Implementation (line_parse_cache.lua:65-284)

The actual `tokenize_line()` function performs **9 sequential scan passes** over the input line:

```lua
function M.tokenize_line(line_text, line_nr, code_excl)
  local tokens = {}
  local consumed = {}  -- sorted list of {start, end} pairs (0-indexed)

  -- Pass 1: Embeds ![[...]]  (lines 69-91)
  --   line_text:find("!%[%[", pos, false) → line_text:find("]]", s+3, true)
  --   overlaps_consumed() check, add to consumed[]

  -- Pass 2: Wikilinks [[...]]  (lines 93-122)
  --   line_text:find("%[%[", pos, false), skip if preceded by "!"
  --   overlaps_consumed() check, add to consumed[]

  -- Pass 3: Footnotes [^id]  (lines 124-148)
  --   line_text:find("%[%^([%w_-]+)%]", pos)
  --   Detects definitions (s==1 and next char is ":"), sets subtype="footnote_def"

  -- Pass 4: Highlights ==text==  (lines 150-168)
  --   line_text:find("==[^=]+==", pos)
  --   code_excl() applied

  -- Pass 5: Tags #tag  (lines 170-212)
  --   line_text:find("#", pos, true) + line_text:match("^([a-zA-Z][a-zA-Z0-9_/-]*)", hash+1)
  --   valid_tag_start(), is_hex_color(), code_excl() applied
  --   Skipped on heading lines

  -- Pass 6: Tasks  (lines 214-227)
  --   line_text:match("^%s*[-*] %[([ xX/-])%]")  — single SOL check, captures checkbox state

  -- Pass 7: Headings  (lines 229-239)
  --   line_text:match("^(#+)%s")  — single SOL check

  -- Pass 8: Inline Fields  (lines 241-264)
  --   Delegated to inline_fields.parse_line(line_text) (inline_fields.lua:235-245)
  --   Supports 4 patterns: bracket [key:: val], paren (key:: val), standalone list, standalone bare
  --   code_excl() applied, overlaps_consumed() check
  --   Captures field object with key, value, delimiter style

  -- Pass 9: Block IDs  (lines 266-279)
  --   line_text:match("%^(blk%-[%w]+)%s*$")  — single EOL check (allows trailing whitespace)

  table.sort(tokens, function(a, b) return a.start_col < b.start_col end)
  return tokens
end
```

**Helper functions:**
- `M.valid_tag_start(line, pos)` (lines 25-29): Public, checks `#` preceded by whitespace/punct/SOL
- `M.is_hex_color(tag)` (lines 35-39): Public, validates CSS hex color (3/6/8 hex digits)
- `overlaps_consumed(col0, col1, consumed)` (lines 50-57): Local, binary range overlap check
- `evict_if_needed(buf_cache, bufnr, max_lines)` (lines 301-330): Local, LRU eviction based on viewport proximity

### Current Render Diff Implementation (render_diff.lua:57-94)

The actual `apply_diff()` uses individual pcall-wrapped API calls:

```lua
function M.apply_diff(bufnr, new_specs, changed_lines)
  -- prev = _prev_specs[bufnr] or {}
  -- Build new_by_key index mapping spec keys to new specs
  --
  -- Deletion loop (lines 70-80): iterate previous specs on changed lines,
  --   delete those no longer in new_specs
  pcall(vim.api.nvim_buf_del_extmark, bufnr, old_spec.ns, old_spec._id)  -- error silently swallowed
  --
  -- Addition/update loop (lines 83-91): for each new spec, check opts_equal()
  --   against old spec; if different or new, call set_extmark
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, spec.ns, spec.line, spec.col, spec.opts)
  if ok then spec._id = id end  -- reuse old _id if opts unchanged
  --
  -- Update _prev_specs[bufnr] with next_prev
end
```

**spec_key format** (lines 23-31): `"%d:%d:%d:%s:%s"` → `"ns:line:col:type_tag:end_col_or_dash"` where type_tag is `hl_group` value, `"vt"` (virt_text), `"vl"` (virt_lines), or `"other"`, and end_col uses `"-"` when absent. Note: `end_row` is NOT included in the key — potential collision if two specs differ only in `end_row`.

**opts_equal** (lines 37-51): fast path checks `hl_group`, `end_col`, `end_row`, `priority`; deep compare for `virt_text`/`virt_lines`. Does NOT compare `conceal`, `hl_mode`, `sign_text`, or other fields.

**_prev_specs** (line 18): `table<number, table<string, ExtmarkSpec>>` — outer key is bufnr, inner key is spec_key string.

### Pipeline Consumer Architecture (Actual)

Four consumers registered in `pipeline_consumers.lua`:

| Consumer | Token Types | Namespace | Priority | Extmarks/Match |
|----------|-------------|-----------|----------|----------------|
| wikilinks | `{"wikilink"}` | `vault_wikilink_hl` | 30 | 3-5 (brackets×2 + target + optional heading + optional alias) |
| tags | `{"tag"}` | `vault_tag_hl` | 40 | 2 (hash + text) |
| inline_fields | `{"inline_field"}` | `vault_inline_field_hl` | 45 | 4-5 (bracket + key + sep + value + bracket) |
| highlights | `{"highlight"}` | `vault_highlight_hl` | 50 | 3 (open delim + content + close delim) |

**Covered updaters** (handled by pipeline, 4 total): `wikilink_highlights`, `tag_highlights`, `inline_fields`, `highlights`

**Not yet pipeline consumers** (still use legacy coordinated updater path):
- `footnotes.lua` — uses `virt_lines` (not character-level extmarks), has pipeline-aware token iteration path (`lines 440-463`) but actual rendering still via coordinated updater (priority 70)
- `autolink.lua` — special rendering requirements (name-based substring matching for coverage check)

### Legacy Highlight Module Patterns (for LPEG Equivalence Testing)

The four pipeline-covered modules now have **no-op stubs** for their rendering functions (`process_lines` / `coordinated_update`). Their scanning patterns are no longer used for rendering but are preserved for reference and LPEG equivalence testing. Some modules retain pipeline-aware scanner functions used for navigation/diagnostics:

| Module | Rendering Status | Pipeline-Aware Scanner | Patterns (Reference) | Code Excl | Priority |
|--------|-----------------|----------------------|---------------------|-----------|----------|
| `wikilink_highlights.lua` | **No-op stub** (pipeline handles) | None | `line:find("%[%[", pos, false)` → `line:find("]]", open+2, true)`, embed skip via `!` prefix | **NO** | 200 |
| `tag_highlights.lua` | **No-op stub** (pipeline handles) | `scan_tags_pipeline_aware()` uses `iter_tokens(bufnr, "tag")` | `line:find("#", pos, true)` → `line:match("^([a-zA-Z][a-zA-Z0-9_/-]*)", hash+1)`, `valid_tag_start()`, `is_hex_color()` | YES | 190 |
| `highlights.lua` | **No-op stub** (pipeline handles) | `scan_highlights_pipeline_aware()` uses `iter_tokens(bufnr, "highlight")` | `line:find("==[^=]+==", pos)` | YES | 195 |
| `footnotes.lua` | **Hybrid** — legacy rendering + pipeline token iteration | `iter_tokens(bufnr, "footnote")` with subtype filter | Refs: `"%[%^([%w_-]+)%]"`, Defs: `"^%[%^([%w_-]+)%]:%s?(.*)"`, Continuation: `"^%s%s%s%s(.*)"` / `"^\t(.*)"` | **NO** | N/A (virt_lines) |
| `inline_fields.lua` | **No-op stub** (pipeline handles) | `parse_line()` exported for reuse | Bracket: `%[([%w_%-]+)::%s*(.-)%]()`, Paren: `%(([%w_%-]+)::%s*(.-)%)()`, Standalone list: `^(%s*[-*]%s+)([%w_%-]+)::%s*(.*)`, Standalone bare: `^([%w_%-]+)::%s*(.*)` | YES | 185 |

### Extmark Count Analysis (Verified from Source)

| Module | Extmarks per Match | Highlight Groups | Namespace |
|--------|-------------------|-----------------|-----------|
| `wikilink_highlights` | 3-6 (brackets×2 + target + optional heading + optional alias; legacy module may produce more than pipeline consumer) | `VaultWikiLinkBracket`, `VaultWikiLinkValid`, `VaultWikiLinkBroken`, `VaultWikiLinkSelf`, `VaultWikiLinkHeading`, `VaultWikiLinkHeadingBroken`, `VaultWikiLinkAlias` | `vault_wikilink_hl` |
| `tag_highlights` | 2 (hash + text) | `VaultTagHash`, `VaultTag`, `VaultTagProject`, `VaultTagStatus`, `VaultTagType`, `VaultTagPerson` | `vault_tag_hl` |
| `highlights` | 3 (open delim + content + close delim) | `VaultHighlightDelim`, `VaultHighlight` | `vault_highlight_hl` |
| `inline_fields` | 4-5 (bracket/paren fields: open + key + sep + value + close = 5; standalone fields: key + sep + value = 3-4) | `VaultFieldBracket`, `VaultFieldKey`, `VaultFieldSep`, `VaultFieldValue`, `VaultFieldValueBool`, `VaultFieldValueDate`, `VaultFieldValueNumber`, `VaultFieldValueLink` | `vault_inline_field_hl` |
| `footnotes` | N/A (uses `virt_lines`) | `VaultFootnoteBorder`, `VaultFootnoteContent`, `VaultFootnoteOrphan`, `VaultFootnoteRef` | `VaultFootnote` |

**Realistic per-line extmark estimate:** A typical vault line with 2 wikilinks and 1 tag produces: `(2 × 3-5) + (1 × 2) = 8-12` extmark API calls. With the current render diff, a single-line edit produces ~4-12 individual pcall-wrapped API calls → 1 `nvim_call_atomic` call with Enhancement 3.

### Always-Pipeline Dispatch (highlight_coordinator.lua:287-315)

The coordinator always uses the pipeline (legacy dual-mode dispatch removed). `run_all()` at lines 287-315:

```lua
function M.run_all(bufnr, opts)
  local arena_scope = render_arena.begin_scope()  -- line 287-289
  opts.arena = arena_scope
  local ok, err = pcall(function()
    local code_excl = link_scan.build_code_exclusion(bufnr)
    local pipeline = require("andrew.vault.transform_pipeline")
    pipeline.attach(bufnr)                         -- idempotent (line 295)
    pipeline.run(bufnr, code_excl, opts)           -- line 297
    -- Dispatch uncovered updaters (footnotes pri 70, autolink, etc.)
    for _, updater in ipairs(_updaters) do          -- lines 300-307
      if updater.enabled() and not pipeline.is_updater_covered(updater.name) then
        pcall(updater.fn, bufnr, code_excl, opts)
      end
    end
  end)
  render_arena.end_scope(arena_scope)              -- line 310-314
  opts.arena = nil
end
```

Scheduling (`schedule()` at lines 273-281) uses two debounce tiers:
- `full = true` (toggle, refresh, BufEnter): **30ms** debounce
- `full = false` (normal edits, scroll): **200ms** debounce

WinScrolled autocmd registered directly in highlight_coordinator.lua (line 336), calling `schedule(bufnr, { full = false })`.

### on_bytes Change Tracking (line_tracker.lua:15-42, consume at 48-62)

```lua
-- Data structure (lines 10-11):
---@type table<number, { tick: number, dirty: table<number, true>, full: boolean }>
local _buffers = {}

-- attach() (lines 15-42): idempotent, initializes with { tick = 0, dirty = {}, full = true }
-- on_bytes callback (lines 20-36):
-- Parameters: _, buf, tick, start_row, _, _, old_end_row, _, _, new_end_row, _, _
-- Decision logic:
--   Line 24: Update state.tick
--   Lines 26-29: old_end_row ~= new_end_row → state.full = true   (line count changed)
--   Lines 31-34: old_end_row == new_end_row → mark dirty rows:
--     for row = start_row, start_row + math.max(old_end_row, new_end_row)
-- consume() (lines 48-62):
--   Returns nil if not attached or state.full = true (signals full reparse to Layer 1)
--   Returns sorted dirty line numbers otherwise, clears dirty set
```

**Content dedup interaction:** When `consume()` returns `nil` (full reparse), `line_parse_cache.update(bufnr, nil, code_excl)` re-scans all lines. Enhancement 2 provides its biggest benefit here — comparing `texts[ln] == text` skips tokenization for the ~99% of lines not affected by the edit.

### Event Dispatch Integration (event_dispatch.lua)

| Event | Routing | Debounce |
|-------|---------|----------|
| `TextChanged` | `highlight_coordinator.schedule(bufnr, { full = false })`, `embed.on_text_changed()`, `task_hierarchy._schedule_render()` | 200ms (coordinator) |
| `TextChangedI` | `highlight_coordinator.schedule(bufnr, { full = false })`, `task_hierarchy._schedule_render()` | 200ms (coordinator) |
| `InsertLeave` | `embed.on_text_changed()` | 150ms (`config.embed.render_delay_ms`) |
| `BufEnter` | Coalesced via `event_coalescer` → `breadcrumbs.on_buf_enter()`, `embed.on_buf_enter()`, `frecency.on_buf_enter()`, `task_notify.on_buf_enter()`, `sidebar.on_buf_enter()` (if loaded, lazy); non-vault: `linkdiag.on_buf_enter_non_vault()`, `breadcrumbs.on_buf_enter_non_vault()` | 30ms (full) + adaptive coalescer (16ms base, 200ms rapid) |
| `WinScrolled` | `highlight_coordinator.schedule(bufnr, { full = false })` (line 336); `embed` scroll handler (line 835) | 200ms (coordinator); 80ms (`config.embed.lazy_scroll_debounce_ms`) |
| `BufWritePost` | `highlight_coordinator.on_buf_write(ctx)`, `breadcrumbs.on_buf_write(ctx)`, `autofile.on_buf_write(ctx)` — coordinator decides full vs viewport based on `line_count <= config.viewport.full_buffer_threshold` | N/A (immediate) |
| `VimLeavePre` | Consolidated teardown: `engine`, `highlight_coordinator`, `task_hierarchy`, `autosave`, `embed`, `connections`, `callout_folds`, coalescer close | N/A |

Enhancement 2 (content dedup) is most impactful on `BufEnter` full renders where the buffer is re-scanned but hasn't changed since the last render.

### Arena Allocator Compatibility (render_arena.lua)

The `render_arena.lua` module provides pooled table allocation:
- `begin_scope()` (lines 119-130) → scope_id; `end_scope(scope_id)` (lines 197-232) clears and returns tables to pool
- `alloc_table(scope_id)` (lines 136-165) draws from stack-based pool (200 initial, 2000 max)
- `alloc_array(scope_id, capacity)` (lines 172-192) uses LuaJIT `table.new(capacity, 0)` for pre-sized arrays (bypasses pool)
- `with_scope(fn)` (lines 238-246): RAII helper with pcall protection
- Debug mode (lines 57-98): metatable proxy intercepts `__index`/`__newindex`/`__pairs`/`__ipairs`/`__len` to detect use-after-free
- Stats (lines 32-40): `total_scopes`, `active_scopes`, `peak_scope_size`, `pool_hits`, `pool_misses`, `tables_cleared`, `overflow_discards`
- Module init (line 301): `M.warm(initial_pool_size)` pre-allocates 200 tables at load

**LPEG token tables and the arena:**
- LPEG `Ct()` creates tables internally (not arena-managed)
- Tokens must outlive the render scope (they're cached in `_cache`), so arena allocation is only useful for the intermediate `raw` table from `scanner:match()` which is discarded after filtering
- Recommendation: use arena for ephemeral `raw` captures only; final `tokens` arrays are GC-managed

### LPEG Availability Verification

LPEG is **not currently used anywhere** in the vault codebase. All pattern matching uses Lua `string.find`/`match`/`gmatch` or `vim.treesitter` queries.

---

## Zed Reference Architecture (Cross-Reference)

The Zed editor (`~/Software/zed-main`) solves analogous rendering pipeline problems in Rust. Key patterns relevant to these enhancements:

### Layered Transform Pipeline (display_map.rs)

Zed uses a **6-layer composable display pipeline**, each wrapping the previous snapshot:

1. **InlayMap** — inlay hints/annotations (analogous to our embed overlay)
2. **FoldMap** — code folding via Transform entries
3. **TabMap** — hard tab visualization
4. **WrapMap** — soft-wrap line breaking
5. **BlockMap** — custom blocks (diagnostics, headers)
6. **DisplayMap** — background highlights

**Key difference from vault pipeline:** Zed layers transform *coordinates and text*, not just decorations. Each layer has a `sync()` method consuming edits from the previous layer, producing transformed edits for the next. Our pipeline layers process *tokens* through parse→resolve→render, not coordinate transforms.

### Incremental Parsing Strategy (syntax_map.rs)

Zed's tree-sitter integration uses a two-phase incremental strategy:

1. **Interpolation phase** (`syntax_map.rs:286-402`): `tree.edit()` applies `InputEdit` directly to existing tree-sitter trees without reparsing — adjusts byte offsets for subsequent edits
2. **Reparse phase** (`syntax_map.rs:404-455`): Selective reparsing via `text.edits_since::<usize>(&self.parsed_version)` to identify affected byte ranges; also supports `reparse_with_ranges()` (`line 457+`) for line-range-based reparsing; `SyntaxSnapshot` (`lines 29-36`) tracks `parsed_version`, `interpolated_version` as separate `clock::Global` vector clocks, plus `language_registry_version: usize` and `update_count: usize`

**Relevance to Enhancement 2:** This is analogous to our content-dedup approach — both avoid redundant work by detecting unchanged regions. Zed uses version vectors (`clock::Global`) for O(1) change detection instead of string comparison. Our `texts[ln] == text` approach is simpler and equally effective for line-level dedup thanks to Lua string interning.

### Batched Rendering (scene.rs, custom_highlights.rs)

Zed batches rendering through:

1. **Highlight endpoint merging**: `CustomHighlightsChunks` (`custom_highlights.rs:14-23`) converts highlight ranges into sorted `HighlightEndpoint` events (`lines 25-31`: offset, is_start, tag, style), processed in a single pass via `BTreeMap<HighlightKey, HighlightStyle>` state machine (`active_highlights` field) — inserts on `is_start=true`, removes on `is_start=false`, merges all active highlights per chunk
2. **Scene-level primitive batching**: `Scene::batches()` (`gpui/src/scene.rs:152-176`) returns `BatchIterator` (`lines 248-270`) with 7 peekable iterators (shadows, quads, paths, underlines, monochrome_sprites, polychrome_sprites, surfaces) plus start position trackers, consolidated via Iterator impl (`lines 272-431`)
3. **InlaySplice batching** (`inlay_hint_cache.rs:87-90`): `to_remove: Vec<InlayId>` + `to_insert: Vec<Inlay>` applied atomically; accompanied by `ExcerptHintsUpdate` (`lines 92-98`) for per-excerpt cache updates

**Relevance to Enhancement 3:** Zed's InlaySplice pattern is structurally similar to our proposed `nvim_call_atomic` batching — collecting all add/remove operations and applying them in one boundary crossing. The endpoint-merging pattern could inspire future optimizations where overlapping extmarks from different consumers are merged before API dispatch.

### Resource Pooling (syntax_map.rs)

Zed pools `QueryCursor` via `QueryCursorHandle` (`syntax_map.rs:224`) backed by a static `QUERY_CURSORS: Mutex<Vec<QueryCursor>>` pool (`language.rs:94`). `new()` pops from pool and resets match limit to 64 (`lines 1880-1883`); `Drop` resets byte/point ranges and pushes back (`lines 1901-1908`). Analogous to our `render_arena.lua` table pooling. Both avoid allocation pressure in hot paths.

### Version-Based Cache Invalidation

Zed tracks changes via `clock::Global` (`SmallVec<[u32; 8]>` `values` + `local_branch_value: u32`, `clock/src/clock.rs:29-34`) with `changed_since()` (`lines 124-132`) for O(1) staleness detection — compares element-wise and checks length, returning true if any value or branch value is greater. Our vault index uses `_generation` counters for the same purpose in `semantic_resolution.lua`. Both avoid content hashing at the cache-invalidation layer.

### Key Takeaway

Zed validates the architectural decisions in our pipeline:
- **Layered processing** (their 6-layer display map ↔ our 4-layer transform pipeline)
- **Incremental change tracking** (their `tree.edit()` + `ChangeRegionSet` ↔ our `on_bytes` + `line_tracker`)
- **Batched rendering** (their `InlaySplice` ↔ our proposed `nvim_call_atomic`)
- **Resource pooling** (their `QueryCursor` pool ↔ our `render_arena`)
- **Content-aware dedup** (their version vectors ↔ our proposed `texts[ln] == text`)

The main architectural gap: Zed's chunk-based streaming iterator yields text+metadata lazily, while our pipeline materializes full token arrays per line. This is inherent to the Neovim extmark API (declarative) vs Zed's GPUI (immediate-mode rendering, with `Scene` batching 7 primitive types via `BatchIterator` in `scene.rs:152-176`).

The implementation must guard with:

```lua
local has_lpeg, lpeg = pcall(require, "lpeg")
if not has_lpeg then
  -- Fall back to string.find loop (current tokenize_line implementation)
  M.tokenize_line = tokenize_line_legacy
  return
end
```

### Config Section (Current Pipeline Config)

```lua
-- config.lua (actual, lines 856-860):
M.arena = {
  initial_pool_size = 200,      -- Tables pre-allocated at module load
  max_pool_size = 2000,         -- Upper bound on pooled tables (excess GC'd)
  debug_validation = false,     -- Enable use-after-free proxy detection
}

-- config.lua (actual, lines 872-877):
M.events = {
  buf_enter_coalesce_ms = 16,       -- BufEnter coalescing window (~1 frame)
  rapid_switch_threshold_ms = 50,   -- Detect :bufdo-style rapid switching
  rapid_switch_delay_ms = 200,      -- Extended delay during rapid switching
  max_batch_size = 32,              -- Force flush at this many pending events
}

-- config.lua (actual, lines 880-883):
M.coalescer = {
  max_waiters = 50,                 -- Maximum callbacks per in-flight operation
  timeout_ms = 30000,               -- Auto-cancel operations that take too long
}

-- config.lua (actual, lines 888-891):
M.pipeline = {
  -- Pipeline is always active (enable toggle removed; legacy per-updater dispatch deleted)
  line_cache_max = 10000,            -- Max cached lines per buffer before eviction
  full_reparse_threshold = 100,      -- If >N dirty lines, do full reparse instead
}

-- config.lua (actual, lines 896-900):
M.viewport = {
  padding_lines = 50,               -- Extra lines rendered beyond visible viewport edges
  cleanup_threshold = 3.0,          -- Multiplier: GC placements beyond this × viewport_height from edge
  full_buffer_threshold = 200,      -- Files with fewer lines skip viewport restriction (BufEnter uses full=true)
}
```

### Pipeline Orchestrator Details (transform_pipeline.lua:55-141)

The `run()` function orchestrates all four layers:
- **Layer 0** (line 62): `line_tracker.consume(bufnr)` → dirty_lines or nil (full); override if `opts.full` (lines 66-68)
- **Full reparse threshold** (lines 71-76): If `#dirty_lines > config.pipeline.full_reparse_threshold`, sets `dirty_lines = nil` for full reparse
- **Layer 1** (line 79): `line_parse.update(bufnr, dirty_lines, code_excl)` → token cache
- **Layer 2** (lines 82-89): `semantic.resolve(bufnr, dirty_lines, ...)` → resolved tokens; checks vault_index `_generation` for staleness, forces full resolve if index changed
- **Layer 3** (lines 92-133): Builds `line_set` table for diff (lines 92-99); iterates consumers, filters resolved tokens by type via `type_set` lookup (lines 104-107), calls `consumer.render(ln, relevant_tokens)` → ExtmarkSpec[], then `render.apply_diff(bufnr, all_specs, line_set)` (line 133)
- **Debug logging** (lines 135-141): Logs pipeline run stats (bufnr, dirty count, spec count, consumer count)

Consumer registration uses sorted-by-priority insertion (`register_consumer()` at lines 33-36). Consumers are lazy-loaded from `pipeline_consumers.lua` via `ensure_consumers()` (lines 39-48).

Additional public API:
- `M.attach(bufnr)` (lines 151-162): Tracks attachment, calls `line_tracker.attach()`, clears legacy extmarks from consumer namespaces
- `M.detach(bufnr)` (lines 166-172): Full invalidation cascade (line_tracker, line_parse, semantic, render)
- `M.is_updater_covered(updater_name)` (lines 192-195): Checks `_covered_updaters` table (wikilink_highlights, tag_highlights, highlights, inline_fields)
- `M.get_parse_cache()` / `M.get_semantic()` (lines 200-208): Accessors for Layer 1/2 modules

### Linkdiag Pipeline Integration (Already Active)

`linkdiag.lua` has a pipeline-aware code path (`validate_from_pipeline()` at lines 191-372) that uses `parse_cache.iter_tokens(bufnr, "wikilink")` (line 206) and `semantic.get_resolved(bufnr, line_nr)` (lines 214-225, matching by type + start_col + end_col) when the pipeline cache is warm. Entry point at `M.validate(bufnr)` (line 377) attempts pipeline path (lines 385-393) via `pcall(require, "andrew.vault.transform_pipeline")`, with automatic fallback to legacy full-buffer scanning if pipeline unavailable or cache cold. Uses per-validation heading cache (`cached_get_headings()` / `M.get_headings()`, lines 199-204) to avoid redundant vault_index lookups. Code exclusion is NOT used in the pipeline path (pre-resolved by semantic layer). Enhancement 1 (LPEG tokenizer) would benefit linkdiag directly by producing tokens faster.

### Full Extmark Call Volume (Realistic Estimate)

For a 100-line vault buffer with typical content density:
- ~15 wikilinks × 4 extmarks = 60
- ~10 tags × 2 extmarks = 20
- ~5 highlights × 3 extmarks = 15
- ~8 inline fields × 4 extmarks = 32
- **Total: ~127 extmark API calls per full render**

With the current render diff, a single-line edit reduces this to ~4-10 calls (only the changed line's tokens). Enhancement 3 batches even these remaining calls into a single `nvim_call_atomic`.

For `BufEnter` full renders (all 127 extmarks), the batching provides the most significant absolute improvement: 127 API crossings → 1.

---

## Zed Architecture Comparison

The Zed editor's rendering pipeline (investigated at `~/Software/zed-main/`) provides architectural context for these enhancements. All file paths and structures verified against current Zed source (2026-03-23).

### Relevant Zed Patterns

| Zed Pattern | Zed Implementation | Vault Equivalent | Status |
|-------------|-------------------|-----------------|--------|
| **Layered display pipeline** | `InlayMap → FoldMap → TabMap → WrapMap → BlockMap` — each layer receives typed edits from previous, transforms coordinates via `SumTree<Transform>` | `line_tracker → line_parse_cache → semantic_resolution → render_diff` | **Implemented** |
| **Edit subscription batching** | `Subscription(Arc<Mutex<Patch<usize>>>)` (`text/src/subscription.rs:11`); `consume()` returns `Patch<usize>` via `mem::take` (`lines 30-32`); `Topic.publish()` (`lines 20-22`) composes edits via internal `publish()` function using `patch.compose()` (`lines 35-48`) | `line_tracker.consume(bufnr)` returns dirty lines or full-reparse signal | **Implemented** |
| **Incremental tree-sitter reparse** | Two-phase: `interpolate()` (`syntax_map.rs:286-402`) applies `tree.edit()` in foreground; `reparse()` (`syntax_map.rs:404-455`) selectively reparses affected ranges; 1ms sync timeout (`buffer.rs:1513, default at 945`) with async fallback (`buffer.rs:1519-1543`) | Layer 1 re-tokenizes only dirty lines; no tree-sitter involvement in tokenization | **Partially analogous** |
| **Content-based change detection** | `clock::Global` vector clocks (`SmallVec<[u32; 8]>` + `local_branch_value`, `clock.rs:29-34`); `changed_since()` (`lines 124-132`) for O(1) staleness checks; `edits_since()` via `BufferSnapshot` with fragment filtering | Enhancement 2's `texts[ln] == text` comparison | **Not yet implemented** |
| **Early-exit optimizations** | Empty edit checks at multiple layers: `did_edit()` (`buffer.rs:2389-2402`) exits if `edits_since().next().is_none()`; `interpolate()` (`syntax_map.rs:292-293`) exits on empty edits; injection scan skipped if `changed_ranges.is_empty()` | Enhancement 2 skips unchanged lines; render_diff skips identical specs | **Partially implemented** |
| **Delta rendering** | Each display layer propagates typed edits (`InlayEdit`, `FoldEdit`, `TabEdit`, `WrapEdit`); WrapMap uses `Patch<u32>` for incremental tracking with background wrapping task | `render_diff.apply_diff()` — key-based spec diffing | **Implemented** |
| **Batch operations** | `InlaySplice { to_remove: Vec<InlayId>, to_insert: Vec<Inlay> }` single atomic call to inlay map (`crates/editor/src/inlay_hint_cache.rs:87-90`) | Enhancement 3's `nvim_call_atomic` batching | **Not yet implemented** |
| **Decoration caching** | `InlayHintCache` (`inlay_hint_cache.rs:34-46`) with per-excerpt `CachedExcerptHints` (`lines 54-61`) containing `buffer_version: Global` for vector-clock-based staleness detection; `TasksForRanges` (`lines 48-52`, impl at `lines 118-166`) reuses overlapping LSP query tasks | `_prev_specs[bufnr]` in render_diff.lua | **Implemented** |
| **Priority/layering** | `BlockPlacement` ordering: `Above(0) → Replace(1) → Near(2) → Below(3)` (`block_map.rs:84, sort_order at 131`); `CustomBlock.priority: usize` field (`line 189`); blocks sorted by anchor position → range → placement type | Consumer priority (wikilinks 30, tags 40, inline_fields 45, highlights 50) + extmark priority (200/195/190/185) | **Implemented** |
| **Invalidation strategy** | `InvalidationStrategy` enum (`inlay_hint_cache.rs:63-80`): `RefreshRequested` (full LSP hint refresh), `BufferEdited` (fast invalidation/re-query with debounce), `None` (append-only) — with configurable debounce via `invalidate_debounce` / `append_debounce` fields (`inlay_hint_cache.rs:34-46`) | Enhancement 2's content comparison prevents unnecessary tokenization | **Not yet implemented** |

### Key Architectural Insight from Zed

Zed's **two-tier parse scheduling** (1ms synchronous attempt → async background task) is notable (`buffer.rs:1482-1545`). Phase 1: `syntax_map.interpolate(&text)` runs in foreground, applying `tree.edit()` to adjust offsets without reparsing. Phase 2: `syntax_snapshot.reparse()` spawns as background task, with `block_with_timeout(self.sync_parse_timeout, parse_task)` (default 1ms, `buffer.rs:945`, field at line 111, setter at lines 1455-1456). On timeout, the parse is deferred to `cx.spawn()` with automatic re-parse detection if `version.changed_since(&parsed_version)`. The vault pipeline currently runs synchronously within the debounce callback. For very large buffers where LPEG tokenization + semantic resolution might exceed a frame budget, a similar pattern could be applied:

```lua
-- Future consideration (not part of this document):
-- If pipeline.run() exceeds config.pipeline.sync_timeout_ms,
-- defer remaining lines to vim.schedule() callback
```

This is not proposed as part of this document but is noted as a natural extension informed by Zed's approach.

### Zed's Display Layer Architecture (Verified)

Each display layer follows the same pattern:
- **Mutable map** (`InlayMap` at `inlay_map.rs:22`, `FoldMap` at `fold_map.rs:321` (`pub(crate)`), `TabMap` at `tab_map.rs:15` (newtype wrapper), `WrapMap` at `wrap_map.rs:21-29`) — owns state, accepts mutations
- **Immutable snapshot** (`InlaySnapshot` at `inlay_map.rs:28`, `FoldSnapshot` at `fold_map.rs:622`, `TabSnapshot` at `tab_map.rs:158`, `WrapSnapshot` at `wrap_map.rs:32`) — captures state at a point in time
- **Transform tree** (`SumTree<Transform>`) — efficiently tracks coordinate mappings between layers; transforms carry dual `TransformSummary` (input + output `TextSummary`)

The `DisplayMap.snapshot()` method (`display_map.rs:167`) chains through all layers:
```
buffer_snapshot → buffer_subscription.consume().into_inner() → InlayMap.sync() → FoldMap.read() → TabMap.sync() → WrapMap.update(|map| map.sync()) → BlockMap.read()
```

Each layer consumes edits from the previous and produces typed edits for the next:
- `Vec<text::Edit<usize>>` → `(InlaySnapshot, Vec<InlayEdit>)` → `(FoldSnapshot, Vec<FoldEdit>)` → `(TabSnapshot, Vec<TabEdit>)` → `(WrapSnapshot, Patch<u32>)` → `BlockSnapshot`

The resulting `DisplaySnapshot` (`display_map.rs:764-778`) composes all layer snapshots plus highlights, crease state, fold placeholders, and diagnostic severity. Coordinate transformation follows the chain: `DisplayPoint → BlockPoint → WrapPoint → TabPoint → FoldPoint → InlayPoint → MultiBufferPoint`.

The `DisplayMap` struct (`display_map.rs:98`) holds all mutable map layers (`InlayMap`, `FoldMap`, `TabMap`, `WrapMap` entity, `BlockMap`), text/inlay highlights, crease map, fold placeholder, clip settings, masked state, and `diagnostics_max_severity: DiagnosticSeverity`.

Notable: WrapMap uses background tasks for expensive soft-wrapping calculations, storing interpolated edits (`pending_edits: VecDeque<(TabSnapshot, Vec<TabEdit>)>`, `wrap_map.rs:23`) until full computation completes. The WrapMap struct also tracks `interpolated_edits: Patch<u32>` and `edits_since_sync: Patch<u32>` for incremental state management. This lazy evaluation pattern is similar to the vault's debounced rendering approach.

### Zed's Immutable Snapshot Pattern

Zed uses `DisplaySnapshot` (`display_map.rs:764`) — an immutable capture of all display layers at a moment in time, containing all layer snapshots (`InlaySnapshot`, `TabSnapshot`, `WrapSnapshot`, `BlockSnapshot`, `FoldSnapshot`, `CreaseSnapshot`), text/inlay highlights, fold placeholder, clip/mask settings, and `diagnostics_max_severity`. All read operations use snapshots while mutations accumulate in subscriptions (`Subscription(Arc<Mutex<Patch<usize>>>)`, `subscription.rs:11`, consumed atomically via `mem::take` at `lines 30-32`). The vault's equivalent is the `_prev_specs[bufnr]` state in render_diff.lua, which serves a similar purpose but is mutable. The current approach is appropriate for Neovim's single-threaded Lua execution model.
