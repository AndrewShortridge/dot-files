--- Shared scanning primitives for link detection and text matching.
---
--- Provides common utilities used by autolink.lua (inline suggestions),
--- unlinked.lua (batch auto-linking), and potentially other modules.
--- Centralizes code that was previously duplicated across modules.

local render_arena = require("andrew.vault.render_arena")
local pat = require("andrew.vault.patterns")
local config = require("andrew.vault.config")

local M = {}

-- Generation-keyed cache of the (first_word_index, single_set) name partition.
-- The partition only changes when the vault index instance/generation changes
-- (which also invalidates idx:get_name_cache) or when the autolink params
-- (min_name_length / exclude_names) change. Rebuilt lazily on a key miss in
-- scan_buffer_names. The VaultIndex INSTANCE is part of the key: a vault switch
-- creates a fresh instance starting at generation 0, so a bare numeric gen would
-- collide across vaults and serve the previous vault's names.
-- NOTE: the cached tables MUST be plain {} (not render_arena allocations), since
-- they outlive the per-call arena scope.
local _name_partition_cache = nil -- { idx, gen, min, excl, single_set, first_word_index }

-- Shared, never-mutated empty ranges table. overlaps_range only ipairs-reads
-- its ranges arg (see M.overlaps_range), so a single frozen-by-convention {}
-- can be reused for every link-free line instead of allocating a fresh one.
local EMPTY_RANGES = {}

-- Delegate frontmatter range detection to frontmatter_parser's cached parse,
-- converting from 1-indexed to 0-indexed. Eliminates redundant boundary scan.

--- Count whitespace-delimited words in a string.
---@param s string
---@return number
function M.word_count(s)
  local n = 0
  for _ in s:gmatch("%S+") do n = n + 1 end
  return n
end

-- ---------------------------------------------------------------------------
-- Code exclusion (treesitter-based)
-- ---------------------------------------------------------------------------

-- Parse the (static) exclusion queries once at load instead of per call.
-- pcall-guarded so a missing parser/grammar degrades exactly like before:
-- a nil query simply skips that range source.
local function parse_q(lang, str)
  local ok, q = pcall(vim.treesitter.query.parse, lang, str)
  return ok and q or nil
end

local _q_fenced = parse_q("markdown", "(fenced_code_block) @code")
local _q_indented = parse_q("markdown", "(indented_code_block) @code")
local _q_code_span = parse_q("markdown_inline", "(code_span) @code")

-- ---------------------------------------------------------------------------
-- Incremental code-exclusion cache
--
-- The exclusion closure is consumed as a WHOLE-buffer query (scan_buffer_names,
-- inline_fields, highlight_coordinator all query arbitrary rows), so its range
-- set must stay complete across edits. A plain changedtick memo recomputed the
-- entire buffer on every keystroke — three iter_captures(0,-1) sweeps. Instead
-- we keep a per-buffer cache of the full range set and, when only a few lines
-- are dirty, rescan ONLY the dirty span (expanded to enclosing code blocks),
-- retaining out-of-range ranges verbatim. A private on_bytes attach supplies
-- the dirty span + net line delta, with a full-rebuild kill-switch mirroring
-- line_tracker's bounded_dirty fallback.
-- ---------------------------------------------------------------------------

---@class CodeExclEntry
---@field tick number changedtick of the last computed range set
---@field block_ranges number[][] markdown-tree ranges (fenced + indented code blocks)
---@field span_ranges number[][] markdown_inline-tree ranges (code_span)
---@field closure fun(row: number, col: number): boolean

---@type table<number, CodeExclEntry>
local _cache = {}

--- Per-buffer dirty accumulator fed by our private on_bytes attach.
--- `full` forces a whole-buffer rescan (cold attach or unsafe line math).
---@type table<number, { dmin: number, dmax: number, delta: number, full: boolean }>
local _dirty = {}

--- Reset a buffer's dirty accumulator to "clean" (nothing pending).
--- `edit_row` is the minimum on_bytes `start_row` (the PRE-EDIT row at which the
--- first change began); rows strictly below it are unaffected by line-count
--- deltas, so it — NOT the post-edit `dmin - delta` — is the correct boundary
--- for shifting cached ranges into post-edit coordinates.
--- `edit_pre_end` is the maximum PRE-EDIT row (exclusive) touched by an edit:
--- pre-edit rows [edit_row, edit_pre_end) were replaced/deleted, so any cached
--- range whose body lay in that band no longer exists and must be re-captured
--- rather than naively shifted.
local function dirty_clean(bufnr)
  _dirty[bufnr] = {
    dmin = math.huge, dmax = -1, delta = 0, full = false,
    edit_row = math.huge, edit_pre_end = -1,
  }
end

--- Attach a lightweight on_bytes tracker to feed the incremental rescan.
--- Independent of line_tracker (which is destructively consumed by the
--- transform pipeline). Detaches itself when the cache entry is gone.
local function ensure_attach(bufnr)
  if _dirty[bufnr] then return end
  dirty_clean(bufnr)
  -- A fresh attach has no prior range set -> first build is whole-buffer.
  _dirty[bufnr].full = true

  vim.api.nvim_buf_attach(bufnr, false, {
    on_bytes = function(_, buf, _tick, start_row, _, _, old_end_row, _, _, new_end_row, _, _)
      local d = _dirty[buf]
      if not d then return true end -- cache cleared -> detach

      -- Pre-edit start row of the change: everything strictly below it keeps its
      -- pre-edit row number. Track the minimum across accumulated edits, plus the
      -- maximum pre-edit end row (exclusive) so the replaced/deleted band is
      -- known. `old_end_row` is the end offset relative to start_row in PRE-EDIT
      -- coordinates; subsequent renumbering keeps these in pre-edit terms because
      -- we only ever widen with raw on_bytes rows.
      if start_row >= 0 then
        if start_row < d.edit_row then d.edit_row = start_row end
        local pre_end = start_row + old_end_row + 1
        if pre_end > d.edit_pre_end then d.edit_pre_end = pre_end end
      end

      if old_end_row ~= new_end_row then
        local bounded = config.pipeline.bounded_dirty
        if bounded == nil then bounded = true end
        if not bounded or start_row < 0 then
          d.full = true
          return
        end
        d.delta = d.delta + (new_end_row - old_end_row)
        -- Renumber the pending span into post-edit coordinates (rows at/after
        -- start_row shift by the delta), mirroring line_tracker's accumulator.
        if d.dmax >= start_row then
          d.dmax = d.dmax + (new_end_row - old_end_row)
        end
        if d.dmin >= start_row then
          d.dmin = d.dmin + (new_end_row - old_end_row)
        end
        local lo = start_row
        local hi = start_row + new_end_row
        if lo < d.dmin then d.dmin = lo end
        if hi > d.dmax then d.dmax = hi end
      else
        local lo = start_row
        local hi = start_row + math.max(old_end_row, new_end_row)
        if lo < d.dmin then d.dmin = lo end
        if hi > d.dmax then d.dmax = hi end
      end
    end,

    on_reload = function(_, buf)
      -- A buffer reload (`:e!`, external-change reload) advances changedtick but
      -- fires NO on_bytes, so the dirty accumulator stays empty while the cached
      -- range set is now stale against entirely new content. Force a whole-buffer
      -- rescan; otherwise the incremental path runs with an empty (math.huge)
      -- dirty span and feeds inf into nvim_buf_get_lines.
      local d = _dirty[buf]
      if d then d.full = true end
    end,

    on_detach = function(_, buf)
      _dirty[buf] = nil
    end,
  })
end

--- Capture markdown-tree code-BLOCK ranges (fenced + indented) overlapping the
--- row range [lo, hi]. Treesitter's iter_captures yields any node overlapping the
--- range, so a fence straddling the edit is still captured in full. `lo`/`hi` of
--- (0, -1) scans the whole buffer. Returns a flat list of {sr, sc, er, ec}.
local function capture_block_ranges(bufnr, lo, hi)
  local out = {}
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "markdown")
  if ok and parser then
    local tree = parser:parse()[1]
    if tree then
      local root = tree:root()
      -- A 5th tuple element tags the block KIND ("f" fenced / "i" indented). The
      -- incremental path needs it to reason about fenced-delimiter re-pairing vs
      -- indented gate-line dependencies without re-reading (possibly already
      -- edited) buffer content. build_lookup / the closure only read [1..4], so
      -- the tag is inert everywhere else.
      if _q_fenced then
        for _, node in _q_fenced:iter_captures(root, bufnr, lo, hi) do
          local sr, sc, er, ec = node:range()
          -- r[6] = the opener's fence character ("`" or "~"). A `~~~` opener can
          -- only be closed by `~~~`, never ```` ``` ````, so a delimiter changing
          -- character (count unchanged) still re-pairs everything below it.
          local opener_line = vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, false)[1] or ""
          local fc = opener_line:match("[`~]")
          out[#out + 1] = { sr, sc, er, ec, "f", fc }
        end
      end
      if _q_indented then
        for _, node in _q_indented:iter_captures(root, bufnr, lo, hi) do
          local sr, sc, er, ec = node:range()
          out[#out + 1] = { sr, sc, er, ec, "i" }
        end
      end
    end
  end
  return out
end

--- Fallback: harvest code_span ranges from a SEPARATE top-level markdown_inline
--- parser. Produces spurious fence-interior spans (the whole buffer is treated as
--- inline), but is the only path that works headless (and whenever the markdown
--- injection machinery is unavailable). Kept verbatim from the pre-injection
--- implementation so behavior degrades exactly as before.
local function capture_span_ranges_fallback(bufnr, lo, hi)
  local out = {}
  local iok, iparser = pcall(vim.treesitter.get_parser, bufnr, "markdown_inline")
  if iok and iparser then
    local itrees = iparser:parse()
    for _, itree in ipairs(itrees) do
      local iroot = itree:root()
      if _q_code_span then
        for _, node in _q_code_span:iter_captures(iroot, bufnr, lo, hi) do
          local sr, sc, er, ec = node:range()
          out[#out + 1] = { sr, sc, er, ec }
        end
      end
    end
  end
  return out
end

--- Capture markdown_inline-tree code_SPAN ranges overlapping the row range
--- [lo, hi]. Preferred path: harvest from the markdown parser's INJECTED
--- markdown_inline trees, which the markdown grammar injects only into prose
--- (inline) / table cells — NEVER into fenced/indented code blocks. This makes
--- the result MORE correct than a separate whole-buffer inline parser (no
--- spurious fence-interior spans) and avoids maintaining a second whole-buffer
--- parser whose injections nvim reparses wholesale on every edit.
---
--- CAVEAT: injected trees only cover ranges the markdown parser has already
--- parsed, so we parse the scan range first. Driving the markdown injections
--- runs the `set-lang-from-info-string!` directive, which is registered by
--- nvim-treesitter (NOT core); under `-u NONE` (or before that directive is
--- registered) a fence carrying a language info-string makes parse() THROW. We
--- pcall-guard the whole parse+harvest and, on error OR when no markdown_inline
--- injection trees exist, fall back to the separate-parser path above. This
--- preserves headless testability and degrades exactly as before.
local function capture_span_ranges(bufnr, lo, hi)
  if not _q_code_span then return {} end

  local mok, mparser = pcall(vim.treesitter.get_parser, bufnr, "markdown")
  if mok and mparser then
    local out = {}
    local saw_inline = false
    local ok = pcall(function()
      -- Ensure the scan range is parsed so its injected inline trees exist.
      -- (true = whole-buffer when lo/hi span everything.)
      if lo == 0 and hi == -1 then
        mparser:parse(true)
      else
        mparser:parse({ lo, hi })
      end
      mparser:for_each_tree(function(tstree, ltree)
        if ltree:lang() == "markdown_inline" then
          saw_inline = true
          for _, node in _q_code_span:iter_captures(tstree:root(), bufnr, lo, hi) do
            local sr, sc, er, ec = node:range()
            out[#out + 1] = { sr, sc, er, ec }
          end
        end
      end)
    end)
    if ok and saw_inline then return out end
  end

  -- Injection harvest unavailable (headless, no directive handler, or no inline
  -- trees yet) -> separate-parser fallback.
  return capture_span_ranges_fallback(bufnr, lo, hi)
end

--- Whole-buffer capture of both block and span ranges, returned separately.
--- The merged list + lookup are derived in store_entry, so we do not build them
--- here.
local function capture_all(bufnr)
  return capture_block_ranges(bufnr, 0, -1), capture_span_ranges(bufnr, 0, -1)
end

--- True if any line in the (post-edit) row range [lo, hi] contains a backtick.
--- A code_span node can only exist where a backtick byte is present, so when the
--- rescan span has no backtick, no code_span can START or END within it.
local function has_backtick_in_span(bufnr, lo, hi)
  if hi < lo then return false end
  local lines = vim.api.nvim_buf_get_lines(bufnr, lo, hi + 1, false)
  for _, line in ipairs(lines) do
    if line:find("`", 1, true) then return true end
  end
  return false
end

--- True if any line in the (post-edit) row range [lo, hi] is a code-fence
--- delimiter (``` or ~~~, optionally indented). A fenced_code_block range can
--- only be ADDED, REMOVED, or have its boundaries move if a fence delimiter line
--- was edited. Indented code blocks are detected by leading whitespace, so a
--- prose line that gained/lost a 4-space indent could also start/end one — we
--- treat any line whose indentation is ambiguous (>= 4 leading spaces / a tab) as
--- a potential block boundary too, keeping the precheck sound.
local function span_may_change_blocks(bufnr, lo, hi)
  if hi < lo then return false end
  local lines = vim.api.nvim_buf_get_lines(bufnr, lo, hi + 1, false)
  for _, line in ipairs(lines) do
    if pat.is_code_fence(line) then return true end
    -- Indented code block boundary: a line with >= 4 leading spaces (or a leading
    -- tab) can begin/extend/end an indented_code_block. Conservatively force a
    -- block rescan whenever the edited line carries such indentation.
    if line:match("^\t") or line:match("^    ") then return true end
  end
  return false
end

--- True if a buffer line carries indented-code indentation (>=4 leading spaces
--- or a leading tab) — the prerequisite for an indented_code_block body line.
local function is_indented_line(line)
  return line:match("^\t") ~= nil or line:match("^    ") ~= nil
end

--- True if the ±1-row neighbourhood [dmin-1, dmax+1] of an edit could begin a
--- NEW indented code block. An indented code block cannot interrupt a paragraph
--- (CommonMark): it starts only where the preceding line is blank (or at the
--- document/container start). So a paragraph line turning blank, or a line
--- gaining indentation just below a blank line, can create a block whose body
--- lies OUTSIDE the dirty span. We require BOTH an indented line AND a blank line
--- in the neighbourhood; a pure prose edit with neither returns false, so the
--- per-keystroke block-rescan skip is preserved for ordinary prose.
local function has_indented_create(bufnr, dmin, dmax)
  local lo = dmin - 1
  if lo < 0 then lo = 0 end
  local lines = vim.api.nvim_buf_get_lines(bufnr, lo, dmax + 2, false)
  local saw_indented, saw_blank = false, false
  for _, line in ipairs(lines) do
    if is_indented_line(line) then
      saw_indented = true
    elseif line == "" or line:match("^%s*$") then
      saw_blank = true
    end
    if saw_indented and saw_blank then return true end
  end
  return false
end

--- Rebuild row_set + boundary_rows from a range list (data shapes identical to
--- the original implementation, so the closure body is unchanged).
local function build_lookup(ranges)
  local row_set = {}
  local boundary_rows = {}
  for _, r in ipairs(ranges) do
    local sr, er = r[1], r[3]
    for row = sr + 1, er - 1 do
      row_set[row] = true
    end
    if not boundary_rows[sr] then boundary_rows[sr] = {} end
    boundary_rows[sr][#boundary_rows[sr] + 1] = r
    if er ~= sr then
      if not boundary_rows[er] then boundary_rows[er] = {} end
      boundary_rows[er][#boundary_rows[er] + 1] = r
    end
  end
  return row_set, boundary_rows
end

--- Construct the (row,col)->boolean closure over a row_set/boundary_rows pair.
local function make_closure(row_set, boundary_rows)
  return function(row, col)
    if row_set[row] then return true end
    local boundaries = boundary_rows[row]
    if not boundaries then return false end
    for _, r in ipairs(boundaries) do
      local sr, sc, er, ec = r[1], r[2], r[3], r[4]
      if row == sr and row == er and col >= sc and col < ec then return true end
      if row == sr and row ~= er and col >= sc then return true end
      if row == er and row ~= sr and col < ec then return true end
    end
    return false
  end
end

--- Store a freshly computed range set as the buffer's cache entry. Block and
--- span ranges are kept separately (so the incremental path can rescan each
--- independently); the merged list + lookup are derived from their union so the
--- closure output is byte-identical to the pre-split implementation.
local function store_entry(bufnr, tick, block_ranges, span_ranges)
  local ranges = {}
  for _, r in ipairs(block_ranges) do ranges[#ranges + 1] = r end
  for _, r in ipairs(span_ranges) do ranges[#ranges + 1] = r end
  local row_set, boundary_rows = build_lookup(ranges)
  local entry = {
    tick = tick,
    block_ranges = block_ranges,
    span_ranges = span_ranges,
    closure = make_closure(row_set, boundary_rows),
  }
  _cache[bufnr] = entry
  return entry
end

--- Build (or incrementally refresh) the code-exclusion closure for a buffer.
--- The returned closure answers correctly for EVERY row in the buffer.
---@param bufnr number
---@return fun(row: number, col: number): boolean
function M.build_code_exclusion(bufnr)
  ensure_attach(bufnr)

  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local entry = _cache[bufnr]
  local d = _dirty[bufnr]

  -- Tick unchanged AND nothing pending -> reuse cached closure (memo hit).
  if entry and entry.tick == tick and d and d.dmax < d.dmin and not d.full then
    return entry.closure
  end

  -- Cold cache, unsafe edit, or a changedtick advance with no tracked dirty span
  -- (d.dmax < d.dmin) -> full whole-buffer scan (no precheck). The empty-span case
  -- means the buffer changed via a path that fired no on_bytes (e.g. a reload), so
  -- the cached ranges are stale yet we have no incremental span to rescan; running
  -- the incremental path would feed math.huge into nvim_buf_get_lines.
  if not entry or d.full or d.dmax < d.dmin then
    local block, span = capture_all(bufnr)
    dirty_clean(bufnr)
    return store_entry(bufnr, tick, block, span).closure
  end

  -- Incremental: rescan only the dirty span, expanded to enclosing code blocks.
  local delta = d.delta
  local dmin, dmax = d.dmin, d.dmax
  -- Pre-edit row where the change began. Everything strictly below it kept its
  -- pre-edit row number; everything at/after it moved by `delta`. This is the
  -- on_bytes-tracked start_row — NOT `dmin - delta`, which is correct for a pure
  -- in-place same-line edit but over-counts for line INSERTS (post-edit dmin ==
  -- pre-edit start_row, so dmin - delta lands `delta` rows too high and wrongly
  -- shifts a cached range that sat just ABOVE the insertion point).
  local edit_row = d.edit_row
  if edit_row == math.huge then edit_row = dmin - delta end
  dirty_clean(bufnr)

  -- Shift a cached range list into post-edit coordinates (rows at/after the
  -- first edit move by the net delta). Returns the shifted list, or nil if any
  -- shift is unsafe (signalling a full rebuild). `shift_from` is the pre-edit
  -- row where the edit began; any range ending at/below it was unaffected.
  -- A range moves iff its LAST CONTENT ROW is at/after the edit point. Block
  -- ranges (kind tag in r[5]) use an EXCLUSIVE end row, so their last content row
  -- is er-1; code_span ranges (no tag) use an INCLUSIVE end row (er). Comparing
  -- the wrong one shifts a block whose exclusive end equals shift_from even
  -- though its body sits entirely ABOVE the edit (e.g. deleting the blank line
  -- directly below a two-line fence would wrongly drag the fence down a row).
  local shift_from = edit_row
  -- Pre-edit rows [edit_row, edit_pre_end) were replaced or deleted. A cached
  -- range lying ENTIRELY inside that band no longer exists; shifting it by delta
  -- would drag it onto an unrelated surviving row (e.g. a code_span on a deleted
  -- line slides up onto the line that took its place). Such ranges are dropped
  -- here; the post-edit edited rows [dmin, dmax] are re-captured below, so any
  -- real span/block there is re-detected. We only drop ranges fully within the
  -- band (start at/after edit_row): a range straddling the band keeps its
  -- shifted position so its surviving portion is not lost.
  local edit_pre_end = d.edit_pre_end
  local unsafe = false
  local function shift_list(list)
    local out = {}
    for _, r in ipairs(list) do
      local sr, sc, er, ec = r[1], r[2], r[3], r[4]
      local last_row = r[5] and (er - 1) or er
      if edit_pre_end > shift_from
        and sr >= shift_from and last_row < edit_pre_end then
        -- Entirely within the replaced/deleted band -> drop (re-captured later).
      else
        if delta ~= 0 and last_row >= shift_from then
          sr, er = sr + delta, er + delta
          if sr < 0 or er < 0 then
            unsafe = true
            return out
          end
        end
        out[#out + 1] = { sr, sc, er, ec, r[5], r[6] }
      end
    end
    return out
  end

  local shifted_block = shift_list(entry.block_ranges)
  local shifted_span = unsafe and {} or shift_list(entry.span_ranges)
  if unsafe then
    -- Unsafe shift -> full rebuild.
    local block, span = capture_all(bufnr)
    return store_entry(bufnr, tick, block, span).closure
  end

  -- Expand the rescan span to fully cover any (shifted) cached BLOCK range that
  -- overlaps the dirty rows, so a fence enclosing the edit is rescanned whole.
  -- (Span ranges are single-line and never enclose the edit, so they do not
  -- drive expansion — but they DO drive the inline-rescan decision below.)
  local lo, hi = dmin, dmax
  local edit_in_block = false
  -- INDENTED-block gate dependency: a CommonMark indented code block cannot
  -- interrupt a paragraph, so the block's existence hinges on the BLANKNESS of
  -- the line immediately above it (its "gate line"). That gate line sits one row
  -- OUTSIDE the dirty span, so an edit that toggles its blankness (or that lands
  -- directly on an indented block's boundary row) can create/destroy the
  -- adjacent block without the dirty span touching it. We must therefore (a) test
  -- the edit's ±1-row neighbourhood for indentation/blank-toggle, and (b) when an
  -- indented block sits adjacent to (within ±1 row of) the dirty span, expand
  -- [lo,hi] to fully cover it so its now-stale shifted range is re-captured (and
  -- dropped) rather than retained verbatim. Fenced ``` blocks are exempt: their
  -- existence depends only on their own delimiter lines, which fall inside
  -- [dmin,dmax] when edited (and edit_in_block already covers edits inside them).
  for _, r in ipairs(shifted_block) do
    if r[1] <= hi and r[3] >= lo then
      edit_in_block = true
      if r[1] < lo then lo = r[1] end
      if r[3] > hi then hi = r[3] end
    end
  end

  -- INDENTED-block gate handling. The two ways an edit can change an indented
  -- block whose body lies OUTSIDE the dirty span:
  --
  --   DESTROY / SHRINK — a cached indented block sits adjacent (within ±1 row)
  --     to the dirty span and its CommonMark "gate line" (the blank line that let
  --     it start, just above its first row) was edited to non-blank. The block's
  --     body is unchanged so its shifted cached range survives the shift verbatim
  --     and the dirty span never touches it. We detect this purely from the cache
  --     (no post-edit blank survives to detect): a cached block adjacent to the
  --     edit whose FIRST row is indented (i.e. an indented_code_block, NOT a
  --     fenced ``` block).
  --   CREATE — a paragraph line turned blank, or a line gained indentation just
  --     below a blank line, starting a new block (has_indented_create over the
  --     ±1 neighbourhood). There is no cached block to expand from, so we extend
  --     the region across the contiguous indented/blank run instead.
  --
  -- Either case requires (i) forcing scan_block so the region is actually
  -- re-parsed, and (ii) widening [lo,hi] to fully cover the affected block body
  -- so its stale shifted range is dropped (DESTROY) or its new body captured
  -- whole (CREATE) — iter_captures' span must cover the node. Fenced blocks are
  -- intentionally NOT pulled in here: their existence depends only on their own
  -- delimiter lines (which fall inside [dmin,dmax] when edited, already handled
  -- by edit_in_block / span_may_change_blocks), so an edit merely ADJACENT to a
  -- large fence never widens the region — preserving the per-keystroke skip.
  local gate_change = false
  for _, r in ipairs(shifted_block) do
    if r[5] == "i" and r[1] <= dmax + 1 and r[3] >= dmin - 1 then
      gate_change = true
      if r[1] < lo then lo = r[1] end
      if r[3] > hi then hi = r[3] end
    end
  end
  if has_indented_create(bufnr, dmin, dmax) then
    gate_change = true
  end

  if gate_change then
    local last = vim.api.nvim_buf_line_count(bufnr) - 1
    -- Extend the region outward across the contiguous indented/blank run that
    -- forms (or formed) the candidate block body, so iter_captures' span covers
    -- it fully and no stale fragment is left to merge back in.
    local up = lo - 1
    while up >= 0 do
      local l = vim.api.nvim_buf_get_lines(bufnr, up, up + 1, false)[1] or ""
      if is_indented_line(l) or l == "" or l:match("^%s*$") then
        lo = up
        up = up - 1
      else
        break
      end
    end
    local down = hi + 1
    while down <= last do
      local l = vim.api.nvim_buf_get_lines(bufnr, down, down + 1, false)[1] or ""
      if is_indented_line(l) or l == "" or l:match("^%s*$") then
        hi = down
        down = down + 1
      else
        break
      end
    end
    if lo < 0 then lo = 0 end
  end

  -- Decide whether the markdown_inline (code_span) tree must be reparsed.
  -- A code_span can only be ADDED where a backtick now exists ON THE EDITED
  -- ROWS, and can only be REMOVED where a previously-cached span sat on the
  -- (post-shift) edited rows. Either condition forces an inline rescan; when
  -- neither holds the cached span set provably cannot have changed and we skip
  -- the (expensive) inline reparse + code_span sweep entirely.
  --
  -- CRITICAL: this decision uses the ORIGINAL dirty rows [dmin, dmax] — the
  -- on_bytes-tracked edit span — NEVER the fence-expanded [lo, hi]. Editing a
  -- line deep inside a large fenced block expands [lo, hi] to enclose the whole
  -- fence; prechecking that span would see the fence's delimiter backticks (the
  -- ``` lines) and wrongly trigger a full inline reparse, even though the fence
  -- INTERIOR holds no real code_span and the edited interior line gained none. A
  -- code_span on a fence's own delimiter line can only change if that delimiter
  -- line was itself edited, in which case it is already within [dmin, dmax].
  local precheck = config.pipeline.code_excl_backtick_precheck
  if precheck == nil then precheck = true end
  local scan_inline
  -- Inline rescan range. Defaults to the ORIGINAL dirty rows (a code_span can
  -- only change on an edited row); a fence delimiter add/remove later widens it
  -- to the exposed region (see the fence-repair block below).
  local span_lo, span_hi = dmin, dmax
  if not precheck then
    scan_inline = true
  else
    scan_inline = has_backtick_in_span(bufnr, dmin, dmax)
    if not scan_inline then
      for _, r in ipairs(shifted_span) do
        if r[1] <= dmax and r[3] >= dmin then
          scan_inline = true
          break
        end
      end
    end
  end

  -- Decide whether the markdown code-BLOCK tree must be reparsed. A fenced /
  -- indented code_block range can only be ADDED, REMOVED, or resized if either
  --   (a) the edit fell INSIDE an existing cached block (edit_in_block — the
  --       expansion above already widened [lo,hi] to enclose that block), or
  --   (b) an EDITED line [dmin,dmax] is a fence delimiter / indented-code
  --       boundary (span_may_change_blocks).
  -- When neither holds, the (shifted) cached block set provably still describes
  -- every code block, so we keep it verbatim and SKIP the markdown parser:parse()
  -- — which, because nvim reparses the buffer's injected markdown_inline trees
  -- whenever the markdown parser parses, costs O(file) (~20ms on a 123KB note)
  -- regardless of dirty-line count. This is the dominant per-keystroke cost on
  -- large notes; the precheck below is what makes incremental cheaper than full.
  --
  -- CRITICAL: like the inline precheck, the fence test uses the ORIGINAL dirty
  -- rows [dmin,dmax] — NEVER the fence-expanded [lo,hi]. An edit deep inside a
  -- fenced block expands [lo,hi] to enclose the fence's delimiter lines; testing
  -- that span would always see the ``` delimiters and defeat the skip even though
  -- edit_in_block already forces a rescan in exactly that case.
  local block_precheck = config.pipeline.code_excl_fence_precheck
  if block_precheck == nil then block_precheck = true end
  local scan_block
  if not block_precheck then
    scan_block = true
  else
    scan_block = edit_in_block or gate_change
      or span_may_change_blocks(bufnr, dmin, dmax)
  end

  -- FENCE RE-PAIRING: ADDING or REMOVING a fenced-block delimiter re-pairs EVERY
  -- ``` / ~~~ below it (an opener consumes the next delimiter as its closer), so
  -- blocks far below the edit can appear, vanish, or shift even though their own
  -- rows were untouched. The kept-verbatim shifted cache below would retain those
  -- now-wrongly-paired ranges. Re-pairing happens ONLY when the COUNT of fence
  -- delimiters changes — merely editing a delimiter's info-string (```lua ->
  -- ```python) keeps it a delimiter and re-pairs nothing. We therefore compare,
  -- over the ±1 neighbourhood of the dirty rows, the number of fence-delimiter
  -- lines NOW present against the number of cached fenced-block delimiter rows
  -- (opener r[1] / closer r[3]-1) that fell there pre-shift. A mismatch means a
  -- delimiter was added or removed, so structure from here to EOF can differ and
  -- we widen the rescan (block + inline) down to the last line. Equal counts ⇒
  -- no re-pairing ⇒ the normal bounded rescan stands, preserving the per-edit
  -- skip even when a delimiter line's content was edited in place.
  if scan_block then
    local nlo = dmin - 1
    if nlo < 0 then nlo = 0 end
    local nhi = dmax + 1
    local now_fences = 0
    for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, nlo, nhi + 1, false)) do
      if pat.is_code_fence(line) then now_fences = now_fences + 1 end
    end
    local cached_delims = 0
    local char_changed = false
    for _, r in ipairs(shifted_block) do
      if r[5] == "f" then
        local opener, closer = r[1], r[3] - 1
        if opener >= nlo and opener <= nhi then cached_delims = cached_delims + 1 end
        if closer ~= opener and closer >= nlo and closer <= nhi then
          cached_delims = cached_delims + 1
        end
        -- A fence delimiter's CHARACTER changing (count unchanged) still re-pairs:
        -- a `~~~` opener can only be closed by `~~~`, never ```` ``` ````. If an
        -- edited row is this block's opener or closer, compare its current fence
        -- char with the block's cached char (r[6]); a mismatch (or no fence) means
        -- the pairing from here down can differ.
        if r[6] then
          for _, drow in ipairs({ opener, closer }) do
            if drow >= dmin and drow <= dmax then
              local cur = (vim.api.nvim_buf_get_lines(bufnr, drow, drow + 1, false)[1] or ""):match("[`~]")
              if cur ~= r[6] then char_changed = true end
            end
          end
        end
      end
    end
    local fence_repair = now_fences ~= cached_delims or char_changed
    if fence_repair then
      local last = vim.api.nvim_buf_line_count(bufnr) - 1
      if last > hi then hi = last end
      -- Removing/adding a fence delimiter re-pairs every delimiter below it,
      -- exposing or hiding prose throughout — and, crucially, on the headless
      -- separate-parser fallback the spurious fence-interior spans shift with the
      -- re-pairing. A range-scoped recapture of the fallback produces different
      -- spurious spans than a whole-buffer parse, desyncing the incremental
      -- closure from a fresh build. So when a fence is re-paired we recapture the
      -- code_span set over the WHOLE buffer, matching exactly what a cold rebuild
      -- would compute. (This is the only branch that does so; ordinary edits keep
      -- the tight [dmin,dmax] inline rescan, preserving the per-keystroke skip.)
      scan_inline = true
      span_lo = 0
      span_hi = last
    end
  end

  local kept_block
  if not scan_block then
    -- Block set provably unchanged: retain the shifted cache verbatim.
    kept_block = shifted_block
  else
    -- Block ranges: rescan the (fence-expanded) span. Keep cached block ranges
    -- entirely outside it; re-capture those intersecting it.
    --
    -- The prune predicate is the EXACT complement of iter_captures' overlap test
    -- so the union is duplicate-free AND complete. iter_captures(lo, hi+1) yields
    -- a node iff `er > lo and sr <= hi` (treesitter ranges use an EXCLUSIVE end
    -- row er). A node is therefore re-captured iff it overlaps; we must KEEP iff
    -- it does NOT: `er <= lo or sr > hi`. Using `er < lo` (an off-by-one) would
    -- DROP a block whose exclusive end row equals `lo` — neither kept here nor
    -- re-yielded by iter_captures — silently losing it.
    kept_block = {}
    for _, r in ipairs(shifted_block) do
      if r[3] <= lo or r[1] > hi then
        kept_block[#kept_block + 1] = r
      end
    end
    -- iter_captures uses an exclusive upper bound; +1 so a range ending exactly
    -- on `hi` is still yielded.
    for _, r in ipairs(capture_block_ranges(bufnr, lo, hi + 1)) do
      kept_block[#kept_block + 1] = r
    end
  end

  -- Span ranges: rescan only when scan_inline; otherwise retain the shifted
  -- cache verbatim (no backtick in span + no cached span on dirty rows means
  -- the code_span set is unchanged).
  --
  -- The re-capture (and its matching prune) is scoped to the ORIGINAL dirty rows
  -- [dmin, dmax] — NOT the fence-expanded [lo, hi]. Code_spans never live in a
  -- fence INTERIOR (that is the BLOCK path's job), so re-capturing the interior
  -- would (on the separate-parser fallback) re-introduce the very spurious
  -- interior spans we avoid AND would do the expensive interior sweep we just
  -- decided to skip. A code_span can only change on a row that was edited; rows
  -- outside [dmin, dmax] (including fence boundary lines we did not touch) keep
  -- their shifted cached spans verbatim. Prune-range == re-capture-range keeps
  -- the union complete.
  local span_ranges
  if scan_inline then
    span_ranges = {}
    -- Retain cached spans that do NOT overlap the rescan rows [span_lo, span_hi]
    -- (normally the edited rows; widened to the exposed region on a fence
    -- add/remove). Prune-range == re-capture-range keeps the union complete.
    for _, r in ipairs(shifted_span) do
      if r[3] < span_lo or r[1] > span_hi then
        span_ranges[#span_ranges + 1] = r
      end
    end
    -- iter_captures uses an exclusive upper bound; +1 so a span ending exactly
    -- on `span_hi` is still yielded. (On a fence re-pair span_lo/span_hi cover the
    -- whole buffer, so this matches a cold capture_span_ranges(0,-1) exactly.)
    for _, r in ipairs(capture_span_ranges(bufnr, span_lo, span_hi + 1)) do
      span_ranges[#span_ranges + 1] = r
    end
  else
    span_ranges = shifted_span
  end

  return store_entry(bufnr, tick, kept_block, span_ranges).closure
end

-- ---------------------------------------------------------------------------
-- Frontmatter detection
-- ---------------------------------------------------------------------------

--- Find frontmatter range (0-indexed line numbers).
--- Delegates to frontmatter_parser's cached parse to avoid redundant scanning.
---@param bufnr number
---@return number|nil start_line, number|nil end_line
function M.get_frontmatter_range(bufnr)
  local fm = require("andrew.vault.frontmatter_parser").parse_buffer_cached(bufnr)
  if not fm then return nil, nil end
  return fm.start_line - 1, fm.end_line - 1
end

--- Clear the code-exclusion cache for a buffer. The private on_bytes attach
--- detaches itself on the next callback once `_dirty` is gone; clearing both
--- here forces the next build to do a fresh whole-buffer scan.
---@param bufnr number
function M.clear_cache(bufnr)
  _cache[bufnr] = nil
  _dirty[bufnr] = nil
end

local cleanup = require("andrew.vault.resource_cleanup")
local _augroup = vim.api.nvim_create_augroup("VaultLinkScan", { clear = true })
cleanup.on_buf_delete(_augroup, function(bufnr) M.clear_cache(bufnr) end, { pattern = "*.md" })

-- ---------------------------------------------------------------------------
-- Link range detection
-- ---------------------------------------------------------------------------

--- Build a list of byte ranges on a line that are inside wikilinks, embeds,
--- markdown links, or URLs. Matches overlapping these ranges are skipped.
---@param line string
---@return {start_col: number, end_col: number}[]  0-indexed byte ranges
function M.get_link_ranges(line)
  local ranges = {}

  -- Wikilinks: [[...]] and ![[...]]
  pat.scan_all_links(line, function(_inner, start_col, end_col, _is_embed)
    ranges[#ranges + 1] = { start_col = start_col - 1, end_col = end_col }
  end)

  -- Markdown links: [text](url)
  local pos = 1
  while true do
    local s, e = line:find(pat.MARKDOWN_LINK, pos)
    if not s then break end
    if s > 1 and line:sub(s - 1, s - 1) == "[" then
      pos = s + 1
    else
      ranges[#ranges + 1] = { start_col = s - 1, end_col = e }
      pos = e + 1
    end
  end

  -- Bare URLs: https://... (URL_PAT == pat.URL; hoisted out of the per-line loop)
  pos = 1
  local url_pat = pat.URL
  while true do
    local s, e = line:find(url_pat, pos)
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
function M.overlaps_range(start_col, end_col, ranges)
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
  if start_pos > 1 then
    local prev = line:sub(start_pos - 1, start_pos - 1)
    if prev:match("[%w_]") then
      return false
    end
  end
  if end_pos < #line then
    local next_char = line:sub(end_pos + 1, end_pos + 1)
    if next_char:match("[%w_]") then
      return false
    end
  end
  return true
end

-- Per-line column bitset helpers, hoisted out of scan_buffer_names' loop so they
-- are not reallocated as closures on every scanned line. occupied_cols is passed
-- explicitly (it is the only per-line state these touch).
local function mark_position(occupied_cols, s, e)
  for col = s, e - 1 do
    occupied_cols[col] = true
  end
end

local function is_position_taken(occupied_cols, s, e)
  for col = s, e - 1 do
    if occupied_cols[col] then return true end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Buffer-level name scanning
-- ---------------------------------------------------------------------------

--- Scan a buffer for mentions of vault note names.
--- Implements the shared scanning algorithm used by both autolink.lua
--- (inline suggestions) and unlinked.lua (batch auto-linking).
---
--- The algorithm:
--- 1. Gets vault index name cache
--- 2. Splits names into multi-word (sorted longest first) and single-word sets
--- 3. Iterates buffer lines in the specified range
--- 4. Skips frontmatter, heading lines, empty lines
--- 5. For each line: gets link ranges, builds position tracking, scans
---    multi-word names (longest first, greedy), then single-word names
--- 6. Applies code exclusion, link overlap, word boundary, position overlap,
---    and self-mention checks
---
---@param bufnr number
---@param opts? { start_line?: number, end_line?: number, min_name_length?: number, exclude_names?: string[] }
---@return { row: number, start_col: number, end_col: number, text: string, note_name: string }[]
function M.scan_buffer_names(bufnr, opts)
  opts = opts or {}
  local min_name_length = opts.min_name_length or 3

  local arena_scope = render_arena.begin_scope()

  -- Build exclude set from opts (arena: per-call intermediate)
  local exclude_set = render_arena.alloc_table(arena_scope)
  if opts.exclude_names then
    for _, name in ipairs(opts.exclude_names) do
      exclude_set[name:lower()] = true
    end
  end

  -- Lazy-require to avoid circular dependencies
  local vault_index = require("andrew.vault.vault_index")
  local link_utils = require("andrew.vault.link_utils")

  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    render_arena.end_scope(arena_scope)
    return {}
  end

  local fname = vim.api.nvim_buf_get_name(bufnr)

  local name_cache = idx:get_name_cache()
  local names_map = name_cache.names

  -- Build name lists: multi-word names bucketed by first word (each bucket sorted
  -- longest first), single-word names as a hash set.
  -- Memoized on (index instance, generation, min_name_length, exclude_names
  -- identity): the partition only changes when one of these changes, so we skip
  -- the full-vault iteration + sort on every keystroke. The instance key guards
  -- against a vault switch (fresh VaultIndex at gen 0) colliding with the prior
  -- vault's cached partition. Keyed on opts.exclude_names by table identity
  -- (callers pass a stable config reference); nil is a valid stable key.
  -- Cached tables are plain {} so they survive past the arena scope below.
  local gen = idx._generation
  local excl = opts.exclude_names
  local cache = _name_partition_cache
  local single_set, first_word_index
  if cache and cache.idx == idx and cache.gen == gen and cache.min == min_name_length and cache.excl == excl then
    single_set = cache.single_set
    first_word_index = cache.first_word_index
  else
    single_set = {}
    -- First-word inverted index: bucket each multi-word name under its first
    -- [%w_]+ run (SAME tokenization as the Phase-2 word-walk below), so Phase 1
    -- only tests names whose first word actually occurs on the line. Keyed on
    -- [%w_]+ (NOT the whitespace-delimited first word) so a name whose first
    -- %S token carries punctuation (e.g. "c++ guide" -> "c") cannot bucket
    -- under a key the word-walk never produces. Each bucket is sorted
    -- longest-first to preserve the existing greedy match order; Phase 1
    -- re-sorts its per-line candidate set, so no global ordering of names is
    -- needed here.
    first_word_index = {}
    for lower_name in pairs(names_map) do
      if #lower_name >= min_name_length and not exclude_set[lower_name] then
        if M.word_count(lower_name) == 1 then
          single_set[lower_name] = true
        else
          local fw = lower_name:match("[%w_]+")
          if fw then
            local bucket = first_word_index[fw]
            if not bucket then
              bucket = {}
              first_word_index[fw] = bucket
            end
            bucket[#bucket + 1] = lower_name
          end
        end
      end
    end
    for _, bucket in pairs(first_word_index) do
      table.sort(bucket, function(a, b) return #a > #b end)
    end
    _name_partition_cache = {
      idx = idx,
      gen = gen,
      min = min_name_length,
      excl = excl,
      single_set = single_set,
      first_word_index = first_word_index,
    }
  end

  -- Determine line range
  local start_line = opts.start_line or 0
  local end_line = opts.end_line or vim.api.nvim_buf_line_count(bufnr)

  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)
  local is_in_code = M.build_code_exclusion(bufnr)
  local fm_start, fm_end = M.get_frontmatter_range(bufnr)

  -- Current buffer's own note name — exclude self-mentions
  local self_name = link_utils.get_basename(fname):lower()

  local matches = {} -- NOTE: escapes scope, NOT from arena

  -- Built once per scan_buffer_names call (not per line): captures only the
  -- loop-invariants is_in_code/self_name/matches; per-line state (line,
  -- link_ranges, occupied_cols, row) is passed explicitly.
  --- Try to record a match at [s, e] (1-indexed inclusive) for note_name.
  --- Returns true if the match was accepted (passes all exclusion checks).
  local function try_add_match(line, link_ranges, occupied_cols, row, s, e, note_name)
    if not has_word_boundaries(line, s, e) then return false end
    local start_col = s - 1 -- 0-indexed
    local end_col = e       -- 0-indexed exclusive
    if
      M.overlaps_range(start_col, end_col, link_ranges)
      or is_in_code(row, start_col)
      or is_position_taken(occupied_cols, start_col, end_col)
      or note_name == self_name
    then
      return false
    end
    matches[#matches + 1] = {
      row = row,
      start_col = start_col,
      end_col = end_col,
      text = line:sub(s, e),
      note_name = note_name,
    }
    mark_position(occupied_cols, start_col, end_col)
    return true
  end

  for i, line in ipairs(lines) do
    local row = start_line + i - 1 -- 0-indexed absolute row

    -- Skip frontmatter
    if fm_start and fm_end and row >= fm_start and row <= fm_end then
      goto next_line
    end

    -- Skip heading lines (uses M.is_heading_line pattern inline for hot-loop perf)
    if line:match("^#+ ") then goto next_line end

    -- Skip empty lines
    if #line == 0 then goto next_line end

    local lower_line = line:lower()

    -- Links/URLs require a literal '[' (WIKILINK_OPEN "[[", MARKDOWN_LINK "%[")
    -- or the substring "http" (URL "https?://"); a line with neither byte cannot
    -- produce any range, so get_link_ranges would return {} anyway. Skip the
    -- whole multi-pass scan + table alloc on link-free prose lines.
    local link_ranges
    if line:find("[", 1, true) or line:find("http", 1, true) then
      link_ranges = M.get_link_ranges(line)
    else
      link_ranges = EMPTY_RANGES
    end

    -- Column bitset: per-line ephemeral (arena)
    local occupied_cols = render_arena.alloc_table(arena_scope)

    -- Phase 1: Multi-word names (longest first, greedy). Use first_word_index to
    -- collect only candidates whose first [%w_]+ run actually occurs on the line
    -- (the perf win: a name can only match if its first word is present), then
    -- apply them in GLOBAL longest-first order — identical to the old all-names
    -- loop's greedy resolution via occupied_cols. NOTE: ordering must be global,
    -- not per-line-word, or cross-bucket overlaps resolve leftmost-wins instead
    -- of longest-wins (a real regression on the vault).
    local candidates = render_arena.alloc_table(arena_scope)
    local cand_seen = render_arena.alloc_table(arena_scope)
    local fw_seen = render_arena.alloc_table(arena_scope)
    local p1_start = 1
    while p1_start <= #line do
      local ws = line:find("[%w_]", p1_start)
      if not ws then break end
      local we = line:find("[^%w_]", ws)
      if not we then we = #line + 1 end
      local lw = line:sub(ws, we - 1):lower()
      if not fw_seen[lw] then
        fw_seen[lw] = true
        local bucket = first_word_index[lw]
        if bucket then
          for _, mw_name in ipairs(bucket) do
            if not cand_seen[mw_name] then
              cand_seen[mw_name] = true
              candidates[#candidates + 1] = mw_name
            end
          end
        end
      end
      p1_start = we
    end
    table.sort(candidates, function(a, b) return #a > #b end)
    for _, mw_name in ipairs(candidates) do
      local search_start = 1
      while true do
        local s, e = lower_line:find(mw_name, search_start, true)
        if not s then break end
        try_add_match(line, link_ranges, occupied_cols, row, s, e, mw_name)
        search_start = e + 1
      end
    end

    -- Phase 2: Single-word names (hash set lookup per word)
    local word_start = 1
    while word_start <= #line do
      local ws = line:find("[%w_]", word_start)
      if not ws then break end
      local we = line:find("[^%w_]", ws)
      if not we then we = #line + 1 end

      local lower_word = line:sub(ws, we - 1):lower()
      if single_set[lower_word] and #lower_word >= min_name_length then
        try_add_match(line, link_ranges, occupied_cols, row, ws, we - 1, lower_word)
      end

      word_start = we
    end

    ::next_line::
  end

  render_arena.end_scope(arena_scope)
  return matches
end

-- =============================================================================
-- Line-array based context exclusion (for disk-file scanning, e.g., ripgrep results)
-- =============================================================================

--- Check if a line is inside a fenced code block (line-array based).
---@param lines string[]
---@param target_line number 1-indexed line number
---@return boolean
function M.is_in_fenced_code_lines(lines, target_line)
  local in_fence = false
  for i = 1, target_line do
    local line = lines[i]
    if pat.is_code_fence(line) then
      in_fence = not in_fence
    end
  end
  return in_fence
end

--- Check if a line is inside YAML frontmatter (line-array based).
---@param lines string[]
---@param target_line number 1-indexed line number
---@return boolean
function M.is_in_frontmatter_lines(lines, target_line)
  if #lines == 0 or lines[1] ~= "---" then return false end
  if target_line <= 1 then return true end
  for i = 2, #lines do
    if lines[i] == "---" or lines[i] == "..." then
      return target_line <= i
    end
  end
  -- Unclosed frontmatter — treat everything as inside
  return true
end

--- Check if a byte position is inside an inline code span (backtick-delimited).
--- Uses regex matching for disk-file context (no treesitter available).
---@param line string
---@param pos number 1-indexed byte position
---@return boolean
function M.is_inside_code_span(line, pos)
  local search_start = 1
  while search_start <= #line do
    local tick_start, tick_end = line:find("`+", search_start)
    if not tick_start then break end
    local ticks = line:sub(tick_start, tick_end)
    local close_start, close_end = line:find(ticks, tick_end + 1, true)
    if not close_start then break end
    if pos > tick_end and pos <= close_start then
      return true
    end
    search_start = close_end + 1
  end
  return false
end

--- Check if a line is a markdown heading.
--- NOTE: This pattern is intentionally duplicated in line_parse_cache.lua
--- (which avoids requires for hot-path performance). Keep in sync.
---@param line string
---@return boolean
function M.is_heading_line(line)
  return line:match("^#+ ") ~= nil
end

return M
