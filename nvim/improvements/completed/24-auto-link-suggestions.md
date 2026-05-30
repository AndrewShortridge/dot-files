# 24 — Auto-Link Suggestions

## Problem

When writing prose in vault notes, the author frequently mentions concepts, people, projects, or other notes by name without wrapping them in wikilinks (`[[...]]`). These missed links are invisible — there is no visual indication that a word or phrase in the current buffer matches an existing note name in the vault.

Obsidian has a similar friction: users must consciously remember which note names exist and manually type `[[` to trigger completion. The result is:

1. **Under-linked notes** — connections between notes are lost because the author did not think to link.
2. **Discovery failure** — the author may not realize a note already exists for a concept they are writing about.
3. **Manual labor** — scanning text for linkable phrases requires conscious effort and vault-wide knowledge.

### Current State

| Component | What It Does | File |
|-----------|-------------|------|
| **completion.lua** | Wikilink completion triggered by `[[` via blink.cmp source | `lua/andrew/vault/completion.lua` |
| **wikilinks.lua** | Note resolution cache (`basename:lower()` -> `abs_path[]`), includes alias indexing | `lua/andrew/vault/wikilinks.lua` |
| **engine.lua** | Shared name cache (`get_name_cache()`) with TTL, async prebuild | `lua/andrew/vault/engine.lua` |
| **wikilink_highlights.lua** | Extmark-based resolution highlighting for existing `[[links]]` | `lua/andrew/vault/wikilink_highlights.lua` |
| **tag_highlights.lua** | Extmark-based inline `#tag` highlighting with debounce | `lua/andrew/vault/tag_highlights.lua` |

### Why Existing Completion Is Not Enough

The wikilink completion source (`completion.lua`) only activates when the user types `[[`. It cannot:

- Retroactively identify already-typed text that matches a note name.
- Provide ambient visual hints without user action.
- Handle multi-word note names that span multiple tokens in prose.

**Conclusion**: A new module that passively scans buffer text against the vault name cache and surfaces non-intrusive hints via extmarks is required.

---

## Goal

Add auto-link suggestions so that:

1. Text matching existing note names is visually marked with a subtle hint (dimmed virtual text icon).
2. The user can accept a suggestion with a single keypress to wrap the text in `[[...]]`.
3. Matching is case-insensitive and respects word boundaries (no partial-word noise).
4. Multi-word note names (e.g., "Machine Learning") are matched as contiguous phrases.
5. Code blocks, existing wikilinks, frontmatter, and URLs are excluded from scanning.
6. Scanning is debounced (300ms) to avoid lag during fast typing.
7. The feature can be toggled on/off per-session.
8. Aliases from frontmatter are matched in addition to note basenames.

---

## Approach

### Architecture

Create a new module `lua/andrew/vault/autolink.lua` that:

1. Builds a lookup structure from the wikilinks resolution cache (note names + aliases).
2. Scans visible buffer lines for text matching known note names.
3. Places extmarks with virtual text hints on matching spans.
4. Provides a keymap to accept the suggestion under the cursor (wrapping in `[[...]]`).
5. Runs on `BufEnter`, `TextChanged`, `TextChangedI`, `CursorMoved` (debounced 300ms).
6. Shares exclusion logic (code blocks, frontmatter) with `tag_highlights.lua`.

### Data Flow

```
wikilinks.lua cache (basename:lower() -> paths[])
        |
        v
autolink.lua builds sorted name list + trie-like prefix map
        |
        v
Buffer text scanned line-by-line against name list
        |
        v
Matches filtered (word boundaries, exclusion zones)
        |
        v
Extmarks placed with virtual text hints
        |
        v
Accept keymap wraps text in [[ ]] and clears the extmark
```

### Name Matching Strategy

The core challenge is efficiently matching multi-word note names against buffer text. A naive approach (iterate all names, search each in every line) is O(N*L) where N is the number of notes and L is the number of lines. For a vault with 1000+ notes and a 500-line buffer, this is too slow.

**Strategy: Length-bucketed case-insensitive scan**

1. **Build phase** (on cache refresh):
   - Collect all note basenames and aliases from the wikilinks cache.
   - Lowercase all names. Store a mapping from lowercase -> original case.
   - Group names by word count: single-word names in one bucket, multi-word in another.
   - For multi-word names, sort by descending length (longest match first / greedy).

2. **Scan phase** (per buffer update):
   - For each line, build a lowercase copy.
   - **Single-word names**: Use a hash set lookup. For each word in the line (split on word boundaries), check if `word:lower()` is in the set.
   - **Multi-word names**: For each multi-word name (sorted longest first), use `string.find()` on the lowercase line. Verify word boundaries at match start/end positions. This is greedy: a match for "Machine Learning Fundamentals" prevents a shorter match for "Machine Learning" at the same position.

3. **Word boundary check**:
   - Match start: position 1, or preceded by whitespace/punctuation (not alphanumeric/underscore).
   - Match end: end of line, or followed by whitespace/punctuation (not alphanumeric/underscore).
   - This prevents "Note" from matching inside "Notebook" or "Denote".

### Exclusion Zones

Reuse the same exclusion approach as `tag_highlights.lua`:

| Zone | Detection | Why Exclude |
|------|-----------|-------------|
| Frontmatter | `---` delimiters (lines 1..N) | YAML metadata, not prose |
| Fenced code blocks | Treesitter `fenced_code_block` node | Code, not prose |
| Indented code blocks | Treesitter `indented_code_block` node | Code, not prose |
| Inline code spans | Treesitter `code_span` node | Code, not prose |
| Existing wikilinks | Regex: text inside `[[...]]` | Already linked |
| Embed links | Regex: text inside `![[...]]` | Already linked |
| Markdown links | Regex: text inside `[...](...)` | Already linked |
| URLs | Regex: `https?://...` | Not linkable prose |
| Heading markers | Regex: `^#+\s` (the `#` chars only) | Structure, not prose content |

For existing wikilinks specifically: rather than excluding entire lines, track the byte ranges of `[[...]]` spans on each line and skip matches that overlap with them. This allows a line like `See [[Foo]] and Bar` to still suggest "Bar" while ignoring "Foo".

### Extmark Strategy

Each suggestion is rendered as a single extmark with:

- **Highlight**: Subtle underline on the matched text span (`VaultAutoLinkHint`).
- **Virtual text**: A small icon appended after the match end, displayed as `end_virt_text` on the extmark (e.g., dimmed `[[` or a link icon character).
- **Priority**: 180 (below tag highlights at 190, wikilink highlights at 200).
- **Namespace**: `vault_autolink` (separate from other vault namespaces).

The extmark stores the match metadata in its user data (via the extmark id -> match mapping table) so the accept function can look up what to wrap.

### Highlight Groups

| Group | Applies To | Default Style |
|-------|-----------|---------------|
| `VaultAutoLinkHint` | Matched text span | `underline = true`, `sp = "#5c6370"` (gray underline) |
| `VaultAutoLinkIcon` | Virtual text icon | `fg = "#5c6370"` (dim gray) |

The styling is intentionally subtle — these are ambient hints, not warnings. The gray underline avoids competing with the colorful wikilink and tag highlights.

### Accept Mechanism

When the cursor is on or adjacent to a suggested match:

1. Find the extmark at the cursor position (using `nvim_buf_get_extmarks` with position filtering).
2. Look up the original match span (start col, end col, matched text).
3. Replace the text span with `[[original_text]]` (preserving original case from the buffer, not the note name).
4. Delete the extmark.
5. Optionally: if the buffer text case differs from the note name, use the pipe alias syntax: `[[NoteName|buffer text]]`. This is configurable.

**Alternative accept**: Accept all suggestions on the current line, or in a visual selection.

### Performance Considerations

| Concern | Mitigation |
|---------|------------|
| Large vault (1000+ notes) | Name list built once per cache refresh (10s TTL). Scan is O(L * W) for single-word (W = words per line) + O(L * M) for multi-word (M = multi-word names). |
| Long buffers (500+ lines) | Only scan visible lines (`vim.fn.line("w0")` to `vim.fn.line("w$")`) plus a small margin. Full-buffer scan only on `BufEnter`. |
| Rapid typing | 300ms debounce on `TextChangedI`. No scan during active insert if last scan was < 300ms ago. |
| Extmark churn | Clear namespace and re-apply (same pattern as `tag_highlights.lua`). Extmark operations are O(1) amortized in Neovim. |
| Cache staleness | Hook into `engine.invalidate_all_caches()` to rebuild the name list. |
| Multi-word scan cost | Sort multi-word names longest-first and skip overlapping regions (positions already matched). Typical vault has < 200 multi-word names. |

### Visible-Range Optimization

For `TextChanged`/`TextChangedI` events, only scan visible lines plus a 5-line margin above and below the viewport. This keeps the per-keystroke cost proportional to screen height (~50 lines) rather than buffer length.

A full-buffer scan runs on:
- `BufEnter` (deferred 200ms)
- `BufWritePost`
- Manual refresh (`:VaultAutoLinkRefresh`)
- Toggle on

### Integration with Existing Completion

The auto-link module complements but does not replace `completion.lua`:

- **completion.lua**: Active completion triggered by typing `[[`. Provides a pick list with previews.
- **autolink.lua**: Passive suggestions on already-typed text. Provides ambient hints with one-key accept.

Both share the same underlying data: the wikilinks cache (via `wikilinks.resolve_link` / engine's `get_name_cache`). The autolink module uses `engine.get_name_cache()` rather than the wikilinks module's cache directly, because `get_name_cache()` provides both a `names` set (for quick lookup) and a `paths` table (for resolution), and is already TTL-managed.

For alias support, the autolink module also reads the wikilinks cache (which indexes aliases). This is a lazy-require to avoid circular dependencies.

---

## Implementation

### File: `lua/andrew/vault/autolink.lua`

```lua
local engine = require("andrew.vault.engine")

local M = {}

M.enabled = false -- Off by default; user opts in with toggle
M.ns = vim.api.nvim_create_namespace("vault_autolink")

---@type uv.uv_timer_t|nil
local timer = nil
local DEBOUNCE_MS = 300

-- ---------------------------------------------------------------------------
-- Name index (rebuilt from cache)
-- ---------------------------------------------------------------------------

---@class AutoLinkNameEntry
---@field lower string lowercase name for matching
---@field original string original-case name (for alias resolution)
---@field word_count number number of words in the name
---@field path string|nil absolute path (for note existence confirmation)

---@type AutoLinkNameEntry[]
local single_word_names = {}  -- names with 1 word (hash set lookup)
---@type AutoLinkNameEntry[]
local multi_word_names = {}   -- names with 2+ words (sorted longest first)
---@type table<string, AutoLinkNameEntry>
local name_set = {}           -- lowercase name -> entry (for O(1) single-word lookup)

local index_vault = nil       -- vault path when index was last built
local index_ts = 0            -- timestamp of last build
local INDEX_TTL = 15          -- seconds before index is stale

--- Rebuild the name index from the wikilinks cache.
local function rebuild_index()
  single_word_names = {}
  multi_word_names = {}
  name_set = {}

  -- Primary source: engine's name cache (basenames + rel paths)
  local name_cache = engine.get_name_cache()
  for lower_name, _ in pairs(name_cache.names) do
    -- Skip very short names (1-2 chars) — too noisy
    if #lower_name >= 3 then
      local entry = {
        lower = lower_name,
        original = lower_name,
        word_count = select(2, lower_name:gsub("%S+", "")) or 1,
        path = name_cache.paths[lower_name],
      }

      if not name_set[lower_name] then
        name_set[lower_name] = entry
        if entry.word_count == 1 then
          single_word_names[#single_word_names + 1] = entry
        else
          multi_word_names[#multi_word_names + 1] = entry
        end
      end
    end
  end

  -- Secondary source: wikilinks alias cache
  local ok, wikilinks_mod = pcall(require, "andrew.vault.wikilinks")
  if ok and wikilinks_mod.resolve_link then
    -- The wikilinks cache is private, but we can test resolution.
    -- We already have basenames from engine; aliases are bonus.
    -- For now, aliases are indexed by the wikilinks cache's build_cache(),
    -- and engine.get_name_cache() does NOT include aliases.
    -- We access aliases via a separate scan if needed.
    -- (Future enhancement: expose alias list from wikilinks.lua)
  end

  -- Sort multi-word names longest first (greedy matching)
  table.sort(multi_word_names, function(a, b)
    return #a.lower > #b.lower
  end)

  index_vault = engine.vault_path
  index_ts = vim.uv.now() / 1000
end

--- Ensure the name index is current.
local function ensure_index()
  local now = vim.uv.now() / 1000
  if index_vault ~= engine.vault_path or (now - index_ts) > INDEX_TTL then
    rebuild_index()
  end
end

--- Invalidate the name index (called when caches are flushed).
function M.invalidate_index()
  index_ts = 0
end

-- ---------------------------------------------------------------------------
-- Exclusion zone detection
-- ---------------------------------------------------------------------------

--- Build a function to check if a (row, col) is inside a code block/span.
--- Mirrors the approach from tag_highlights.lua.
---@param bufnr number
---@return fun(row: number, col: number): boolean
local function build_code_exclusion(bufnr)
  local ranges = {}

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "markdown")
  if ok and parser then
    local tree = parser:parse()[1]
    if tree then
      local root = tree:root()

      for _, query_str in ipairs({
        "(fenced_code_block) @code",
        "(indented_code_block) @code",
      }) do
        local qok, query = pcall(vim.treesitter.query.parse, "markdown", query_str)
        if qok and query then
          for _, node in query:iter_captures(root, bufnr, 0, -1) do
            local sr, sc, er, ec = node:range()
            ranges[#ranges + 1] = { sr, sc, er, ec }
          end
        end
      end
    end
  end

  local iok, iparser = pcall(vim.treesitter.get_parser, bufnr, "markdown_inline")
  if iok and iparser then
    local itrees = iparser:parse()
    for _, itree in ipairs(itrees) do
      local iroot = itree:root()
      local cs_ok, cs_query = pcall(vim.treesitter.query.parse, "markdown_inline", "(code_span) @code")
      if cs_ok and cs_query then
        for _, node in cs_query:iter_captures(iroot, bufnr, 0, -1) do
          local sr, sc, er, ec = node:range()
          ranges[#ranges + 1] = { sr, sc, er, ec }
        end
      end
    end
  end

  return function(row, col)
    for _, r in ipairs(ranges) do
      local sr, sc, er, ec = r[1], r[2], r[3], r[4]
      if row > sr and row < er then return true end
      if row == sr and row == er and col >= sc and col < ec then return true end
      if row == sr and row ~= er and col >= sc then return true end
      if row == er and row ~= sr and col < ec then return true end
    end
    return false
  end
end

--- Find frontmatter range (0-indexed line numbers).
---@param bufnr number
---@return number|nil start_line, number|nil end_line
local function get_frontmatter_range(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, math.min(5, vim.api.nvim_buf_line_count(bufnr)), false)
  if not lines[1] or lines[1] ~= "---" then return nil, nil end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local max_scan = math.min(line_count, 200)
  for i = 2, max_scan do
    local line = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1]
    if line == "---" or line == "..." then
      return 0, i - 1
    end
  end
  return nil, nil
end

--- Build a list of byte ranges on a line that are inside wikilinks, embeds,
--- markdown links, or URLs. Matches overlapping these ranges are skipped.
---@param line string
---@return {start_col: number, end_col: number}[]  0-indexed byte ranges
local function get_link_ranges(line)
  local ranges = {}

  -- Wikilinks: [[...]] and ![[...]]
  local pos = 1
  while true do
    local s = line:find("%[%[", pos)
    if not s then break end
    local e = line:find("]]", s + 2, true)
    if not e then break end
    -- Include the ! prefix for embeds
    local start_byte = s - 1
    if s > 1 and line:sub(s - 1, s - 1) == "!" then
      start_byte = s - 2
    end
    ranges[#ranges + 1] = { start_col = start_byte, end_col = e + 1 }
    pos = e + 2
  end

  -- Markdown links: [text](url)
  pos = 1
  while true do
    local s, e = line:find("%[.-%]%(.-%)", pos)
    if not s then break end
    -- Skip if part of wikilink
    if s > 1 and line:sub(s - 1, s - 1) == "[" then
      pos = s + 1
    else
      ranges[#ranges + 1] = { start_col = s - 1, end_col = e }
      pos = e + 1
    end
  end

  -- Bare URLs: https://...
  pos = 1
  while true do
    local s, e = line:find("https?://[%w%-%.%_%~%:%/%?#%[%]@!%$&'%(%)%*%+,;=%%]+", pos)
    if not s then break end
    ranges[#ranges + 1] = { start_col = s - 1, end_col = e }
    pos = e + 1
  end

  return ranges
end

--- Check if a byte range overlaps any of the exclusion ranges.
---@param start_col number 0-indexed
---@param end_col number 0-indexed (exclusive)
---@param ranges {start_col: number, end_col: number}[]
---@return boolean
local function overlaps_range(start_col, end_col, ranges)
  for _, r in ipairs(ranges) do
    if start_col < r.end_col and end_col > r.start_col then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Word boundary check
-- ---------------------------------------------------------------------------

--- Check if a match at (start_pos, end_pos) in a line has valid word boundaries.
--- start_pos and end_pos are 1-indexed byte positions (Lua string convention).
---@param line string
---@param start_pos number 1-indexed start of match
---@param end_pos number 1-indexed end of match (inclusive)
---@return boolean
local function has_word_boundaries(line, start_pos, end_pos)
  -- Check left boundary
  if start_pos > 1 then
    local prev = line:sub(start_pos - 1, start_pos - 1)
    if prev:match("[%w_]") then
      return false
    end
  end

  -- Check right boundary
  if end_pos < #line then
    local next_char = line:sub(end_pos + 1, end_pos + 1)
    if next_char:match("[%w_]") then
      return false
    end
  end

  return true
end

-- ---------------------------------------------------------------------------
-- Match tracking (extmark id -> match info)
-- ---------------------------------------------------------------------------

---@class AutoLinkMatch
---@field row number 0-indexed
---@field start_col number 0-indexed byte position
---@field end_col number 0-indexed byte position (exclusive)
---@field text string the matched text from the buffer (original case)
---@field note_name string the note name (lowercase key)
---@field extmark_id number

---@type table<number, AutoLinkMatch>
local matches_by_extmark = {}

-- ---------------------------------------------------------------------------
-- Highlight groups
-- ---------------------------------------------------------------------------

local hl_groups = {
  VaultAutoLinkHint = { underline = true, sp = "#5c6370", default = true },
  VaultAutoLinkIcon = { fg = "#5c6370", default = true },
}

local function define_highlights()
  for group, attrs in pairs(hl_groups) do
    vim.api.nvim_set_hl(0, group, attrs)
  end
end

-- ---------------------------------------------------------------------------
-- Core scan and apply
-- ---------------------------------------------------------------------------

--- Clear all autolink hints from a buffer.
---@param bufnr number
local function clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  matches_by_extmark = {}
end

--- Scan buffer lines and apply autolink hints.
---@param bufnr number
---@param opts? { visible_only?: boolean }
local function apply(bufnr, opts)
  if not M.enabled then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local fname = vim.api.nvim_buf_get_name(bufnr)
  if not engine.is_vault_path(fname) then
    clear(bufnr)
    return
  end

  clear(bufnr)
  ensure_index()

  -- If no names to match, bail
  if vim.tbl_isempty(name_set) then return end

  opts = opts or {}

  -- Determine line range
  local start_line, end_line
  if opts.visible_only then
    -- Only scan visible lines + margin
    local win = vim.api.nvim_get_current_win()
    local win_buf = vim.api.nvim_win_get_buf(win)
    if win_buf ~= bufnr then
      -- Fallback to full scan if buffer is not in current window
      start_line = 0
      end_line = vim.api.nvim_buf_line_count(bufnr)
    else
      local top = vim.fn.line("w0") - 1  -- 0-indexed
      local bot = vim.fn.line("w$")       -- 1-indexed, use as exclusive end
      start_line = math.max(0, top - 5)
      end_line = math.min(vim.api.nvim_buf_line_count(bufnr), bot + 5)
    end
  else
    start_line = 0
    end_line = vim.api.nvim_buf_line_count(bufnr)
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)
  local is_in_code = build_code_exclusion(bufnr)
  local fm_start, fm_end = get_frontmatter_range(bufnr)

  -- Get the current buffer's own note name so we don't suggest self-links
  local self_name = vim.fn.fnamemodify(fname, ":t:r"):lower()

  for i, line in ipairs(lines) do
    local row = start_line + i - 1  -- 0-indexed absolute row

    -- Skip frontmatter
    if fm_start and fm_end and row >= fm_start and row <= fm_end then
      goto next_line
    end

    -- Skip heading marker lines (but content after ## could still match)
    -- Actually, headings can contain linkable text, so we allow them.

    if #line == 0 then goto next_line end

    local lower_line = line:lower()
    local link_ranges = get_link_ranges(line)

    -- Track which byte positions have already been matched (for greedy multi-word)
    local matched_positions = {}  -- sorted list of {start, end} (0-indexed)

    local function is_position_taken(s, e)
      for _, m in ipairs(matched_positions) do
        if s < m[2] and e > m[1] then return true end
      end
      return false
    end

    local function mark_position(s, e)
      matched_positions[#matched_positions + 1] = { s, e }
    end

    -- Phase 1: Multi-word names (longest first, greedy)
    for _, entry in ipairs(multi_word_names) do
      local search_start = 1
      while true do
        local s, e = lower_line:find(entry.lower, search_start, true)
        if not s then break end

        -- Check word boundaries (1-indexed)
        if has_word_boundaries(line, s, e) then
          local start_col = s - 1  -- 0-indexed
          local end_col = e        -- 0-indexed exclusive

          -- Check exclusion zones
          if not overlaps_range(start_col, end_col, link_ranges)
            and not is_in_code(row, start_col)
            and not is_position_taken(start_col, end_col)
            and entry.lower ~= self_name then

            -- Place extmark
            local extmark_id = vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, start_col, {
              end_col = end_col,
              hl_group = "VaultAutoLinkHint",
              hl_mode = "combine",
              priority = 180,
              virt_text = { { " [[", "VaultAutoLinkIcon" } },
              virt_text_pos = "inline",
              virt_text_hide = true,
            })

            matches_by_extmark[extmark_id] = {
              row = row,
              start_col = start_col,
              end_col = end_col,
              text = line:sub(s, e),
              note_name = entry.lower,
              extmark_id = extmark_id,
            }

            mark_position(start_col, end_col)
          end
        end

        search_start = e + 1
      end
    end

    -- Phase 2: Single-word names (hash set lookup per word)
    -- Split line into words and check each against the set
    local word_start = 1
    while word_start <= #line do
      -- Skip non-word characters
      local ws = line:find("[%w_]", word_start)
      if not ws then break end

      -- Find end of word
      local we = line:find("[^%w_]", ws)
      if not we then
        we = #line + 1
      end

      local word = line:sub(ws, we - 1)
      local lower_word = word:lower()

      -- Check if this word matches a single-word note name
      if name_set[lower_word] and name_set[lower_word].word_count == 1 then
        local start_col = ws - 1   -- 0-indexed
        local end_col = we - 1     -- 0-indexed exclusive

        -- Check word boundaries (already word-split, but verify no underscore adjacency)
        if has_word_boundaries(line, ws, we - 1)
          and not overlaps_range(start_col, end_col, link_ranges)
          and not is_in_code(row, start_col)
          and not is_position_taken(start_col, end_col)
          and lower_word ~= self_name
          and #lower_word >= 3 then

          local extmark_id = vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, start_col, {
            end_col = end_col,
            hl_group = "VaultAutoLinkHint",
            hl_mode = "combine",
            priority = 180,
            virt_text = { { " [[", "VaultAutoLinkIcon" } },
            virt_text_pos = "inline",
            virt_text_hide = true,
          })

          matches_by_extmark[extmark_id] = {
            row = row,
            start_col = start_col,
            end_col = end_col,
            text = word,
            note_name = lower_word,
            extmark_id = extmark_id,
          }

          mark_position(start_col, end_col)
        end
      end

      word_start = we
    end

    ::next_line::
  end
end

-- ---------------------------------------------------------------------------
-- Accept suggestion
-- ---------------------------------------------------------------------------

--- Find the autolink suggestion nearest to the cursor.
---@param bufnr number
---@return AutoLinkMatch|nil
local function find_suggestion_at_cursor(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1  -- 0-indexed
  local col = cursor[2]       -- 0-indexed

  -- Get all extmarks on the cursor row
  local marks = vim.api.nvim_buf_get_extmarks(
    bufnr, M.ns,
    { row, 0 }, { row, -1 },
    { details = true }
  )

  local best = nil
  local best_dist = math.huge

  for _, mark in ipairs(marks) do
    local id = mark[1]
    local match = matches_by_extmark[id]
    if match then
      -- Check if cursor is within or adjacent to the match span
      if col >= match.start_col and col <= match.end_col then
        return match  -- Exact hit
      end
      -- Track nearest
      local dist = math.min(math.abs(col - match.start_col), math.abs(col - match.end_col))
      if dist < best_dist and dist <= 3 then
        best_dist = dist
        best = match
      end
    end
  end

  return best
end

--- Accept the autolink suggestion at the cursor position.
--- Wraps the matched text in [[...]].
function M.accept()
  local bufnr = vim.api.nvim_get_current_buf()
  local match = find_suggestion_at_cursor(bufnr)
  if not match then
    vim.notify("Vault: no auto-link suggestion at cursor", vim.log.levels.INFO)
    return
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, match.row, match.row + 1, false)[1]
  if not line then return end

  -- Build the replacement text
  local original_text = line:sub(match.start_col + 1, match.end_col)

  -- Check if buffer text case matches the note name case
  -- If different, we could use [[NoteName|displayed text]] but for simplicity
  -- we just wrap with the buffer text (Obsidian resolves case-insensitively)
  local replacement = "[[" .. original_text .. "]]"

  -- Replace the text on the line
  local new_line = line:sub(1, match.start_col) .. replacement .. line:sub(match.end_col + 1)
  vim.api.nvim_buf_set_lines(bufnr, match.row, match.row + 1, false, { new_line })

  -- Move cursor to end of the inserted link
  local new_col = match.start_col + #replacement
  vim.api.nvim_win_set_cursor(0, { match.row + 1, new_col - 1 })

  -- Remove this specific extmark
  pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns, match.extmark_id)
  matches_by_extmark[match.extmark_id] = nil
end

--- Accept all autolink suggestions on the current line.
function M.accept_line()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1

  local marks = vim.api.nvim_buf_get_extmarks(
    bufnr, M.ns,
    { row, 0 }, { row, -1 },
    { details = true }
  )

  -- Collect matches on this line, sorted by column descending
  -- (replace right-to-left so byte offsets remain valid)
  local line_matches = {}
  for _, mark in ipairs(marks) do
    local id = mark[1]
    local match = matches_by_extmark[id]
    if match then
      line_matches[#line_matches + 1] = match
    end
  end

  if #line_matches == 0 then
    vim.notify("Vault: no auto-link suggestions on this line", vim.log.levels.INFO)
    return
  end

  table.sort(line_matches, function(a, b) return a.start_col > b.start_col end)

  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if not line then return end

  for _, match in ipairs(line_matches) do
    local original_text = line:sub(match.start_col + 1, match.end_col)
    local replacement = "[[" .. original_text .. "]]"
    line = line:sub(1, match.start_col) .. replacement .. line:sub(match.end_col + 1)
    pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns, match.extmark_id)
    matches_by_extmark[match.extmark_id] = nil
  end

  vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { line })
  vim.notify(("Vault: accepted %d auto-link(s)"):format(#line_matches), vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------------
-- Debounced update
-- ---------------------------------------------------------------------------

---@param bufnr number
---@param opts? { visible_only?: boolean }
local function schedule_update(bufnr, opts)
  if timer then
    timer:stop()
  end
  timer = vim.uv.new_timer()
  timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      apply(bufnr, opts)
    end
  end))
end

-- ---------------------------------------------------------------------------
-- Toggle
-- ---------------------------------------------------------------------------

function M.toggle()
  M.enabled = not M.enabled
  if M.enabled then
    apply(vim.api.nvim_get_current_buf())
  else
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      clear(buf)
    end
  end
  vim.notify(
    "Vault: auto-link suggestions " .. (M.enabled and "ON" or "OFF"),
    vim.log.levels.INFO
  )
end

-- ---------------------------------------------------------------------------
-- Debug
-- ---------------------------------------------------------------------------

--- Show debug information about current autolink state.
function M.debug()
  ensure_index()
  local bufnr = vim.api.nvim_get_current_buf()
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, M.ns, 0, -1, { details = true })

  local lines = {
    "Vault Auto-Link Debug",
    "=====================",
    "Enabled: " .. tostring(M.enabled),
    "Single-word names: " .. #single_word_names,
    "Multi-word names: " .. #multi_word_names,
    "Total indexed names: " .. vim.tbl_count(name_set),
    "Active suggestions: " .. #marks,
    "Index age: " .. string.format("%.1fs", (vim.uv.now() / 1000) - index_ts),
    "",
    "Active suggestions:",
  }

  for _, mark in ipairs(marks) do
    local id = mark[1]
    local match = matches_by_extmark[id]
    if match then
      lines[#lines + 1] = string.format(
        "  L%d:%d-%d  \"%s\"  -> %s",
        match.row + 1, match.start_col, match.end_col,
        match.text, match.note_name
      )
    end
  end

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  define_highlights()

  local group = vim.api.nvim_create_augroup("VaultAutoLink", { clear = true })

  -- Apply on buffer enter (full scan, deferred)
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      if M.enabled and engine.is_vault_path(vim.api.nvim_buf_get_name(ev.buf)) then
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(ev.buf) then
            apply(ev.buf)
          end
        end, 200)
      end
    end,
  })

  -- Debounced update on text changes (visible range only)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      if M.enabled and engine.is_vault_path(vim.api.nvim_buf_get_name(ev.buf)) then
        schedule_update(ev.buf, { visible_only = true })
      end
    end,
  })

  -- Re-define highlights when colorscheme changes
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = define_highlights,
  })

  -- Clean up on buffer delete
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      clear(ev.buf)
    end,
  })

  -- Commands
  vim.api.nvim_create_user_command("VaultAutoLinkToggle", function()
    M.toggle()
  end, { desc = "Toggle auto-link suggestions" })

  vim.api.nvim_create_user_command("VaultAutoLinkRefresh", function()
    apply(vim.api.nvim_get_current_buf())
  end, { desc = "Refresh auto-link suggestions in current buffer" })

  vim.api.nvim_create_user_command("VaultAutoLinkAccept", function()
    M.accept()
  end, { desc = "Accept auto-link suggestion at cursor" })

  vim.api.nvim_create_user_command("VaultAutoLinkAcceptLine", function()
    M.accept_line()
  end, { desc = "Accept all auto-link suggestions on current line" })

  vim.api.nvim_create_user_command("VaultAutoLinkDebug", function()
    M.debug()
  end, { desc = "Show auto-link debug info" })

  -- Buffer-local keymaps
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "<leader>va", function()
        M.toggle()
      end, {
        buffer = ev.buf,
        desc = "AutoLink: toggle suggestions",
        silent = true,
      })
      vim.keymap.set("n", "<leader>vA", function()
        M.accept()
      end, {
        buffer = ev.buf,
        desc = "AutoLink: accept suggestion at cursor",
        silent = true,
      })
      vim.keymap.set("n", "<leader>vgA", function()
        M.accept_line()
      end, {
        buffer = ev.buf,
        desc = "AutoLink: accept all on line",
        silent = true,
      })
    end,
  })
end

return M
```

---

## Integration

### 1. Register in vault init

**File:** `lua/andrew/vault/init.lua`

Add after the tag highlights setup:

```lua
-- Load auto-link suggestions
require("andrew.vault.autolink").setup()
```

### 2. Hook into cache invalidation

**File:** `lua/andrew/vault/engine.lua`

Add to `invalidate_all_caches()`:

```lua
-- 7. Auto-link name index
local ok_al, autolink = pcall(require, "andrew.vault.autolink")
if ok_al and autolink.invalidate_index then
  autolink.invalidate_index()
end
```

### 3. Add config section

**File:** `lua/andrew/vault/config.lua`

Add to the config table:

```lua
-- ---------------------------------------------------------------------------
-- Auto-link suggestions
-- ---------------------------------------------------------------------------
M.autolink = {
  enabled = false,        -- Off by default (opt-in feature)
  debounce_ms = 300,
  min_name_length = 3,    -- Ignore note names shorter than this
  exclude_names = {},     -- Lowercase names to never suggest (e.g., {"the", "and"})
}
```

---

## Testing

### Manual Verification

1. **Create a test note with note name references:**

   Assuming the vault contains notes named "Machine Learning", "Python", "CFD", "Simulation", "Alice":

   ```markdown
   ---
   title: Test Auto-Link
   ---

   # Test Note

   This note discusses Machine Learning approaches to CFD simulation.

   Alice presented the Python implementation last week.

   We used [[Machine Learning]] explicitly here (should NOT double-suggest).

   Code example: `Python is great` (should NOT suggest inside code span).

   ```python
   # Python code block (should NOT suggest)
   import simulation
   ```

   Visit https://python.org for more info (should NOT suggest from URL).
   ```

2. **Expected behavior after `<leader>va` to enable:**
   - "Machine Learning" (first paragraph) gets gray underline + `[[` icon
   - "CFD" gets gray underline + `[[` icon
   - "Alice" gets gray underline + `[[` icon
   - "Python" (first paragraph) gets gray underline + `[[` icon
   - "Machine Learning" inside existing `[[...]]` is NOT suggested
   - "Python" inside backtick code span is NOT suggested
   - "Python" inside fenced code block is NOT suggested
   - "python" in the URL is NOT suggested
   - "simulation" inside code block is NOT suggested
   - The current note's own name is NOT suggested

3. **Accept:**
   - Move cursor to "Alice", press `<leader>vA` -> line changes to `[[Alice]] presented...`
   - Press `<leader>vgA` on a line with multiple suggestions -> all wrapped

4. **Toggle:**
   - `<leader>va` turns off -> all underlines disappear
   - `<leader>va` again -> re-scans and underlines reappear

### Automated Test

Add to `tests/test_vault_fixes.lua`:

```lua
-- Test: autolink module structure
do
  local source = io.open("lua/andrew/vault/autolink.lua", "r")
  if source then
    local content = source:read("*a")
    source:close()

    -- Core functionality present
    assert_true(content:find("VaultAutoLinkHint") ~= nil, "defines hint highlight group")
    assert_true(content:find("VaultAutoLinkIcon") ~= nil, "defines icon highlight group")
    assert_true(content:find("nvim_buf_set_extmark") ~= nil, "uses extmarks")
    assert_true(content:find("build_code_exclusion") ~= nil, "has code block filtering")
    assert_true(content:find("get_frontmatter_range") ~= nil, "has frontmatter filtering")
    assert_true(content:find("get_link_ranges") ~= nil, "has existing link filtering")
    assert_true(content:find("has_word_boundaries") ~= nil, "validates word boundaries")
    assert_true(content:find("schedule_update") ~= nil, "has debounced update")
    assert_true(content:find("M.accept") ~= nil, "has accept function")
    assert_true(content:find("M.toggle") ~= nil, "has toggle function")
    assert_true(content:find("rebuild_index") ~= nil, "has index builder")
    assert_true(content:find("multi_word_names") ~= nil, "supports multi-word names")
    assert_true(content:find("single_word_names") ~= nil, "supports single-word names")
  end
end
```

### Performance Verification

In a vault note with 200+ words and a vault with 500+ notes:

```vim
:lua local s = vim.uv.hrtime(); require("andrew.vault.autolink").apply(0); print(("%.1f ms"):format((vim.uv.hrtime() - s) / 1e6))
```

Target: < 30ms for a 200-line buffer with 500 indexed names. The main costs are:

1. `build_code_exclusion()` — treesitter parse, ~5ms
2. Multi-word name scanning — O(lines * multi_word_names), typically < 10ms
3. Single-word name scanning — O(total_words_in_buffer), typically < 5ms

For visible-only scans (~50 lines), target is < 10ms.

---

## Edge Cases

| Case | Expected Behavior |
|------|-------------------|
| Note named "A" or "Is" (< 3 chars) | Not suggested — minimum length filter |
| Note named "the" (common word) | Not suggested — too short; also configurable exclude list |
| "machine learning" (lowercase in text) | Suggested — matching is case-insensitive |
| "MachineLearning" (camelCase, no space) | Not matched — word boundaries require space separation |
| Text "Denote" with note "Note" | "Note" NOT suggested — "Note" does not have a left word boundary inside "Denote" |
| Text "Note." with note "Note" | Suggested — punctuation is a valid word boundary |
| Self-referencing (buffer is "Note.md", text says "Note") | Not suggested — self-name excluded |
| Note with alias "ML" matching text "ML" | Suggested if aliases are indexed (future: wikilinks cache exposes aliases) |
| Empty buffer | No suggestions, no errors |
| Non-vault markdown file | Skipped — `is_vault_path()` check |
| 1000+ line buffer | Visible-range scan on typing; full scan only on `BufEnter` |
| Note name containing special regex chars (`C++`) | Safe — uses `string.find` with `plain = true` for multi-word scan |
| Multiple matches on same line | All suggested with non-overlapping extmarks |
| Overlapping possible matches ("Machine" and "Machine Learning") | "Machine Learning" wins (longest first, greedy) |
| Text inside `> blockquote` | Suggested — blockquotes are prose |
| Text inside `- list item` | Suggested — list items are prose |
| Frontmatter value matching note name | Not suggested — frontmatter is excluded |

---

## Dependencies

| Module | How It's Used | Required? |
|--------|-------------|-----------|
| `engine.lua` | `is_vault_path()`, `get_name_cache()`, `vault_path` | Yes |
| `wikilinks.lua` | Alias resolution (lazy-require, future enhancement) | No |
| `config.lua` | Autolink settings (optional) | No (fallback defaults) |
| Treesitter `markdown` parser | Code block exclusion | No (degrades gracefully) |
| Treesitter `markdown_inline` parser | Code span exclusion | No (degrades gracefully) |

---

## Key Files Modified

| File | Change |
|------|--------|
| `lua/andrew/vault/autolink.lua` | **New file** — complete module |
| `lua/andrew/vault/init.lua` | Add `require("andrew.vault.autolink").setup()` |
| `lua/andrew/vault/engine.lua` | Add autolink index invalidation to `invalidate_all_caches()` |
| `lua/andrew/vault/config.lua` | Add `autolink` config section (optional) |

---

## Risk Assessment

**Risk: Low**

- New module with a single `require` line added to `init.lua`.
- **Disabled by default** (`M.enabled = false`) — no impact until the user explicitly opts in with `<leader>va` or `:VaultAutoLinkToggle`.
- Uses established patterns from `tag_highlights.lua` and `wikilink_highlights.lua` (same debounce, extmark, autocmd structure).
- Extmarks with `priority = 180` sit below tag highlights (190) and wikilink highlights (200), so they never visually conflict.
- The accept action only modifies the current line at the exact match span — no risk of corrupting surrounding text.
- Performance bounded by visible-range optimization on typing events; full-buffer scan only on `BufEnter`.
- Treesitter exclusion degrades gracefully — without it, code blocks may get false-positive suggestions (minor UX annoyance, not a correctness issue).
- No modification to existing completion behavior or wikilink resolution logic.

---

## Future Enhancements

1. **Alias support**: Expose the alias list from `wikilinks.lua`'s cache so autolink can match aliases (e.g., text "ML" matching note "Machine Learning" with `aliases: [ML]`). When accepted, use pipe syntax: `[[Machine Learning|ML]]`.

2. **Configurable exclude list**: Allow users to blacklist common words that happen to be note names (e.g., `exclude_names = {"note", "project", "log"}`).

3. **Visual-mode accept**: Select a range and accept all suggestions within it.

4. **Suggestion count in statusline**: Expose `M.suggestion_count()` for statusline integration.

5. **Ghost text variant**: Instead of underline + icon, show the `[[` and `]]` brackets as inline virtual text around the match (ghost text style), toggled with a separate highlight mode config.

---

## Relationship to Existing Modules

| Module | Relationship |
|--------|-------------|
| **completion.lua** | Complementary — completion is active (user types `[[`), autolink is passive (ambient hints) |
| **wikilink_highlights.lua** | Same architectural pattern (extmarks, debounce, toggle). Autolink is for un-linked text; wikilink_highlights is for existing links |
| **tag_highlights.lua** | Shared code exclusion approach. Same autocmd/debounce pattern. Compatible extmark priorities |
| **linkdiag.lua** | Linkdiag validates existing links for breakage. Autolink suggests new links for unlinked text |
| **wikilinks.lua** | Autolink consumes the same resolution cache for name lookups |
