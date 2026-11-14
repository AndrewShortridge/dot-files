local base = require("andrew.vault.completion_base")
local engine = require("andrew.vault.engine")
local file_cache = require("andrew.vault.file_cache")
local config = require("andrew.vault.config")
local fm_parser = require("andrew.vault.frontmatter_parser")
local link_utils = require("andrew.vault.link_utils")
local block_patterns = require("andrew.vault.block_patterns")
local string_intern = require("andrew.vault.string_intern")
local pat = require("andrew.vault.patterns")
local char_bag = require("andrew.vault.char_bag")

local function build_context_lines(lines, target_line, context_width)
  context_width = context_width or 2
  local doc = {}
  local start = math.max(1, target_line - context_width)
  local stop = math.min(#lines, target_line + context_width)
  for j = start, stop do
    local prefix = j == target_line and ">>> " or "    "
    doc[#doc + 1] = prefix .. "L" .. j .. ": " .. lines[j]
  end
  return table.concat(doc, "\n")
end

--- Build a single block completion item.
--- @param b table  Block entry with id, text, line fields
--- @param opts table  { label_prefix: string|nil, insert_suffix: string|nil, documentation: table|nil, data: table|nil }
--- @return table
local function make_block_item(b, opts)
  local item = base.make_item(
    (opts.label_prefix or "") .. b.id,
    b.id .. (opts.insert_suffix or ""),
    b.id .. " " .. (b.text or ""),
    base.KIND.Reference,
    {
      description = base.truncate_text(b.text or ""),
      documentation = opts.documentation,
      data = vim.tbl_extend("force", { completion_kind = "block" }, opts.data or {}),
    }
  )
  -- Tag the source label at build time (block lists are small, built per '^'
  -- trigger) so blink does not need a per-keystroke transform_items scan.
  item.source_name = "Block"
  return item
end

--- Build a single heading completion item.
--- @param h table  Heading entry with text, level, line fields
--- @param order number  Sort order
--- @param opts table|nil  { documentation: table|nil, data: table|nil }
--- @return table
local function make_heading_item(h, order, opts)
  opts = opts or {}
  local item = base.make_item(
    h.text,
    h.text .. "]]",
    h.text,
    base.KIND.Reference,
    {
      sortText = base.order_sort_text(order),
      description = string.rep("#", h.level) .. " L" .. h.line,
      documentation = opts.documentation,
      data = vim.tbl_extend("force", { completion_kind = "heading" }, opts.data or {}),
    }
  )
  -- Tag the source label at build time (heading lists are small, built per '#'
  -- trigger) so blink does not need a per-keystroke transform_items scan.
  item.source_name = "Heading"
  return item
end

-- Per-buffer cache of the expensive same-file extraction (buffer read + parse),
-- keyed on (bufnr, changedtick). The cache also memoizes the BUILT item arrays:
-- the item list is identical across keystrokes of an unchanged buffer (blink
-- re-filters via its own fuzzy matcher), and the items are immutable post-build,
-- so the per-keystroke loop (make_block_item + build_context_lines + tbl_extend)
-- is skipped entirely on a (bufnr, tick) hit.
--
-- Block items are keyed by a variant string derived from item_opts because the
-- two callers ('^id' standalone vs '[[^' same-file) produce different items
-- (label_prefix vs insert_suffix). `items` is a small map: variant -> item[].
local _block_cache = { bufnr = -1, tick = -1, buf_lines = nil, blocks = nil, items = nil }
local _heading_cache = { bufnr = -1, tick = -1, headings = nil, items = nil }

-- Memoizes the "]]"-stripped variant of an item array. When autopairs has
-- already inserted the closing "]]" after the cursor, the trailing "]]" must be
-- dropped from each item's insertText to avoid producing "]]]]". The naive
-- approach clones every "]]"-suffixed item on EVERY keystroke. Instead, key the
-- stripped clone-array on the SOURCE array's table identity (the note-name /
-- heading / block arrays are stable across keystrokes of an unchanged buffer/
-- index — the same invariant the array caches above rely on), so the clone is
-- built ONCE per array and reused. Weak keys+values let stale stripped arrays be
-- GC'd when the source array is replaced (e.g. after a rebuild). If the source
-- arrays ever stop being stable across keystrokes this degrades to per-keystroke
-- cloning (still correct, only slower) — there is no correctness coupling.
local _stripped_cache = setmetatable({}, { __mode = "kv" })

--- Return an array equal to `items` but with the trailing "]]" removed from
--- every item.insertText that has it. Clones the affected items (never mutates
--- the shared, cached item tables) and memoizes the result per source-array
--- identity so the clone loop runs once per distinct array, not per keystroke.
--- @param items table[]
--- @return table[]
local function stripped_close_bracket(items)
  local cached = _stripped_cache[items]
  if cached then return cached end
  local out = {}
  for i = 1, #items do
    local item = items[i]
    if item.insertText and item.insertText:sub(-2) == "]]" then
      local clone = {}
      for k, v in pairs(item) do clone[k] = v end
      clone.insertText = item.insertText:sub(1, -3)
      out[i] = clone
    else
      out[i] = item
    end
  end
  _stripped_cache[items] = out
  return out
end

--- Build block completion items from the current buffer's lines.
--- @param item_opts table  Options passed through to make_block_item (label_prefix, insert_suffix, etc.)
--- @return table[]
local function build_buffer_block_items(item_opts)
  local bufnr = vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  -- Variant key: only label_prefix / insert_suffix distinguish the two callers.
  -- "\0" is a delimiter byte (cannot appear in either option), not a tunable.
  local variant = (item_opts.label_prefix or "") .. "\0" .. (item_opts.insert_suffix or "")
  local buf_lines, blocks
  if _block_cache.bufnr == bufnr and _block_cache.tick == tick then
    -- Built-array cache hit: return the memoized items for this variant.
    local cached = _block_cache.items and _block_cache.items[variant]
    if cached then return cached end
    buf_lines = _block_cache.buf_lines
    blocks = _block_cache.blocks
  else
    buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    blocks = block_patterns.extract_from_lines(buf_lines)
    _block_cache.bufnr, _block_cache.tick = bufnr, tick
    _block_cache.buf_lines, _block_cache.blocks = buf_lines, blocks
    _block_cache.items = {} -- reset memoized item arrays for the new content
  end
  local block_items = {}
  for _, b in ipairs(blocks) do
    block_items[#block_items + 1] = make_block_item(b, vim.tbl_extend("force", {
      documentation = { kind = "plaintext", value = build_context_lines(buf_lines, b.line) },
    }, item_opts))
  end
  _block_cache.items = _block_cache.items or {}
  _block_cache.items[variant] = block_items
  return block_items
end

--- Build a content preview from lines starting after a heading.
--- Collects up to 8 non-empty lines until the next heading at or above the
--- given level.  When `heading_level` is nil, any heading terminates the preview.
---@param lines string[]
---@param heading_line number  1-indexed line of the heading
---@param heading_level number|nil  Level of the heading (e.g. 2 for ##)
---@return string
local function build_heading_preview(lines, heading_line, heading_level)
  local preview = {}
  for j = heading_line + 1, math.min(heading_line + 20, #lines) do
    local level_str = lines[j]:match(pat.HEADING)
    if level_str then
      if not heading_level or #level_str <= heading_level then break end
    end
    if lines[j] ~= "" then
      preview[#preview + 1] = lines[j]
      if #preview >= 8 then break end
    end
  end
  return table.concat(preview, "\n")
end

--- Extract headings for a file, preferring vault index data when available.
--- Falls back to manual line-by-line parsing when the index is not ready or
--- does not contain the file.
---@param lines string[]  Buffer lines (used for preview generation and fallback)
---@param buf_path string|nil  Absolute path of the buffer (for index lookup)
---@return table[]
local function get_headings(lines, buf_path)
  -- Try vault index first
  if buf_path and buf_path ~= "" then
    local idx = base.get_ready_index()
    if idx then
      local _, index_headings = idx:get_headings(buf_path)
      if index_headings and #index_headings > 0 then
        local headings = {}
        for order, h in ipairs(index_headings) do
          headings[#headings + 1] = {
            text = h.text,
            text_lower = h.text_lower,
            level = h.level,
            line = h.line,
            order = order,
            preview = build_heading_preview(lines, h.line),
          }
        end
        return headings
      end
    end
  end

  -- Fallback: manual extraction from lines
  local headings = {}
  local order = 0
  local fm = fm_parser.parse_lines(lines, #lines)
  local start_from = fm and (fm.end_line + 1) or 1

  for i = start_from, #lines do
    -- NB: uses .+ (not pat.HEADING's .*) to skip headings with empty text
    local level, text = lines[i]:match("^(#+)%s+(.+)")
    if text then
      order = order + 1
      headings[#headings + 1] = {
        text = text,
        text_lower = text:lower(),
        level = #level,
        line = i,
        order = order,
        preview = build_heading_preview(lines, i),
      }
    end
  end

  return headings
end

-- Bounded string pool for description deduplication.
-- Identical description strings (same type/tags/path combo) share one Lua string.
local _desc_pool = string_intern.new(500)

local function intern_desc(desc)
  if config.completion and config.completion.intern_descriptions == false then
    return desc
  end
  return string_intern.intern(_desc_pool, desc)
end

--- Reset the description pool on cache invalidation to free stale strings.
local function reset_desc_pool()
  string_intern.clear(_desc_pool)
  string_intern.reset_stats(_desc_pool)
end

local function build_description(fm, rel)
  if not fm then return rel end
  local parts = {}
  if fm.type then parts[#parts + 1] = fm.type end
  if fm.tags then
    local tags = type(fm.tags) == "table" and table.concat(fm.tags, ", ") or tostring(fm.tags)
    if tags ~= "" then parts[#parts + 1] = tags end
  end
  if #parts > 0 then
    return table.concat(parts, " | ") .. " — " .. rel
  end
  return rel
end

--- Build a wikilink note completion item (primary or alias).
--- @param label string  Display label
--- @param basename string  Note basename (used in insertText)
--- @param filter string  Filter text for fuzzy matching
--- @param desc string  Description string (already interned)
--- @param mtime number  Modification time (stored in data; sortText derived in update_cache)
--- @param rel string  Relative path
--- @return table
local function make_note_item(label, basename, filter, desc, mtime, rel)
  return base.make_item(
    label,
    basename .. "]]",
    filter,
    base.KIND.File,
    {
      description = desc,
      data = { rel_path = rel, mtime = mtime },
    }
  )
end

--- Build all completion items for a single file (primary + aliases).
--- Used by completion_base's per-file invalidation to rebuild items
--- without a full async rebuild.
---@param rel_path string
---@param entry VaultIndexEntry
---@param idx table VaultIndex instance
---@return table[] items
local function build_items_for_file(rel_path, entry, idx)
  local items = {}
  local rel = entry.rel_path or rel_path
  local name = link_utils.rel_to_stem(rel)
  local basename = entry.basename
  local mtime = entry.mtime or 0
  local fm = entry.frontmatter
  local desc = intern_desc(build_description(fm, rel))

  -- Only attach per-item char bags when the candidate list can reach the
  -- prefilter threshold; below it the sweep never fires and the bags are dead
  -- weight (build time + memory). Candidate count ~= file_count for wikilinks.
  local pf = config.prefilter
  local use_char_bag = pf.enabled and pf.completion_char_bag
    and idx:file_count() >= (pf.min_candidates_for_charbag or 500)
  local cb = use_char_bag and char_bag or nil

  -- Alias items
  local aliases = entry.aliases
  if aliases then
    local alias_list = type(aliases) == "table" and aliases or { aliases }
    for _, alias in ipairs(alias_list) do
      alias = vim.trim(tostring(alias))
      if alias ~= "" and alias ~= basename then
        local alias_filter = alias .. " " .. name
        local alias_item = make_note_item(
          alias, basename, alias_filter,
          intern_desc("(alias) " .. desc), mtime, rel
        )
        if cb then
          alias_item._char_bag = cb.from_string(alias_filter)
        end
        items[#items + 1] = alias_item
      end
    end
  end

  -- Primary item
  local item = make_note_item(basename, basename, name, desc, mtime, rel)
  if cb then
    item._char_bag = cb.from_string(name)
  end
  items[#items + 1] = item

  return items
end

-- CharBag pre-filter with its own superset-narrowing cache (see
-- base.new_charbag_filter for the narrowing rationale).
local charbag_filter = base.new_charbag_filter()

local source = base.create_source({
  name = "wikilinks",

  --- Build all completion items for a single file (for per-file invalidation).
  ---@param rel_path string
  ---@param entry VaultIndexEntry
  ---@param idx table
  ---@return table[] items
  build_single = build_items_for_file,

  --- Iterator-based builder for coroutine chunking.
  --- Returns a stateful iterator that yields one completion item per call.
  --- Returns nil when the vault index is not ready.
  ---@param vault_path string
  ---@return (fun(): table|nil)|nil
  build_iter = function(vault_path)
    local idx = base.get_ready_index()
    if not idx then return nil end

    -- Reset the description pool on each rebuild to free stale strings
    reset_desc_pool()

    -- Pre-resolve CharBag config once per build (avoid per-item table lookups).
    -- Gate on file_count: below the prefilter threshold the sweep never fires,
    -- so per-item bags are dead weight (build time + memory).
    local pf = config.prefilter
    local use_char_bag = pf.enabled and pf.completion_char_bag
      and idx:file_count() >= (pf.min_candidates_for_charbag or 500)
    local cb = use_char_bag and char_bag or nil

    -- Snapshot the index for consistent reads during coroutine iteration.
    -- Both keys and entries come from the same snapshot, so no entry can
    -- disappear between key collection and entry access.
    local snap_files = idx:snapshot_files()
    local keys = {}
    for rel_path in pairs(snap_files) do
      keys[#keys + 1] = rel_path
    end

    local key_idx = 0
    local alias_queue = {} -- pending alias items for the current entry
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
      local entry = snap_files[rel_path]
      if not entry then return nil end -- defensive: should not happen with snapshot

      local rel = entry.rel_path
      local name = link_utils.rel_to_stem(rel)
      local basename = entry.basename
      local mtime = entry.mtime or 0
      local fm = entry.frontmatter
      local desc = intern_desc(build_description(fm, rel))
      -- Queue alias items for this entry
      alias_queue = {}
      alias_qi = 0
      local aliases = entry.aliases
      if aliases then
        local alias_list = type(aliases) == "table" and aliases or { aliases }
        for _, alias in ipairs(alias_list) do
          alias = vim.trim(tostring(alias))
          if alias ~= "" and alias ~= basename then
            local alias_filter = alias .. " " .. name
            local alias_item = make_note_item(
              alias, basename, alias_filter,
              intern_desc("(alias) " .. desc), mtime, rel
            )
            if cb then
              alias_item._char_bag = cb.from_string(alias_filter)
            end
            alias_queue[#alias_queue + 1] = alias_item
          end
        end
      end

      -- Return the primary item for this entry
      local item = make_note_item(basename, basename, name, desc, mtime, rel)
      if cb then
        item._char_bag = cb.from_string(name)
      end
      return item
    end
  end,

  get_completions = function(self, ctx, items, callback)
    local before = ctx.line:sub(1, ctx.cursor[2])

    -- Standalone block ID reference: ^partial (not inside [[ ]])
    -- Triggers when typing ^id anywhere that isn't already a wikilink
    -- Gate: presence of "[[" (the optional "!" only precedes it, so a plain-byte
    -- "[[" scan is exactly equivalent to "!?%[%[" here and ~4000x cheaper per keystroke).
    if not before:find("[[", 1, true) then
      if before:match("%^[%w%-]*$") then
        local buf_path = vim.api.nvim_buf_get_name(0)
        if buf_path ~= "" then
          callback(base.response(build_buffer_block_items({ label_prefix = "^" })))
          return
        end
      end
      callback(base.empty_response)
      return
    end

    -- If closing ]] already exists after cursor (e.g. from autopairs),
    -- strip ]] from insertText to avoid doubled brackets
    -- `after:find("]]", 1, true) == 1` is exactly `after:match("^%]%]")` (both
    -- test that `after` starts with "]]") but skips the pattern engine.
    local after = ctx.line:sub(ctx.cursor[2] + 1)
    if after:find("]]", 1, true) == 1 then
      local orig_callback = callback
      callback = function(result)
        if result and result.items and #result.items > 0 then
          result = base.response(stripped_close_bracket(result.items))
        end
        orig_callback(result)
      end
    end

    -- Capture the wikilink tail once (the gate above already confirmed "!?%[%["
    -- is present, so this match succeeds). The block/heading triggers below
    -- dispatch on this single capture via cheap byte scans instead of re-matching
    -- the full line prefix with anchored, backtracking patterns each keystroke.
    -- NB: completion-specific trigger pattern (no pat equivalent)
    local tail = before:match("!?%[%[(.-)$") or ""
    -- Position of the last "]" in tail: the old `%^[^%]]*$` / `#[^%]]*$` patterns
    -- required the caret/hash to be followed by no "]" to EOL, i.e. to lie AFTER
    -- the last "]" in tail. Scan for it once and reuse for both triggers.
    local last_rb = 0
    local p = tail:find("]", 1, true)
    while p do
      last_rb = p
      p = tail:find("]", p + 1, true)
    end

    -- Block completion: [[Note Name^partial, [[^partial (same file), or ![[...^partial
    -- Find the first literal "^" strictly after the last "]" (plain=true: "^" is a byte).
    local caret = tail:find("^", last_rb + 1, true)
    if caret then
      local block_note_name = tail:sub(1, caret - 1)
      if block_note_name == "" then
        -- Same-file block reference: [[^ — read live buffer for unsaved changes
        callback(base.response(build_buffer_block_items({ insert_suffix = "]]" })))
      else
        -- Cross-file block reference: [[Note^ — use vault index
        local base_name = block_note_name:match("^([^#]+)") or block_note_name
        base_name = vim.trim(base_name)
        local _, entry = link_utils.resolve_note_via_index(base_name)
        if entry and entry.block_ids and #entry.block_ids > 0 then
          local block_items = {}
          for _, b in ipairs(entry.block_ids) do
            block_items[#block_items + 1] = make_block_item(b, {
              insert_suffix = "]]",
              documentation = (b.text and b.text ~= "") and {
                kind = "plaintext",
                value = "Line " .. b.line .. ": " .. b.text,
              } or nil,
              data = { rel_path = entry.rel_path, block_line = b.line },
            })
          end
          callback(base.response(block_items))
        else
          callback(base.empty_response)
        end
      end
      return
    end

    -- Heading completion: [[Note Name#partial, [[#partial (same file), or ![[...#partial
    -- Find the first literal "#" strictly after the last "]" (same invariant as block).
    local hash = tail:find("#", last_rb + 1, true)
    if hash then
      local note_name = tail:sub(1, hash - 1)
      if note_name == "" then
        -- Same-file heading reference: [[# — prefer index, fall back to buffer
        -- lines. Cache the extracted heading list on (bufnr, changedtick) so it
        -- is not rebuilt on every re-trigger of an unchanged buffer.
        local bufnr = vim.api.nvim_get_current_buf()
        local tick = vim.api.nvim_buf_get_changedtick(bufnr)
        local headings
        if _heading_cache.bufnr == bufnr and _heading_cache.tick == tick then
          -- Built-array cache hit: the heading item list is identical across
          -- keystrokes of an unchanged buffer, so skip the per-keystroke rebuild.
          if _heading_cache.items then
            callback(base.response(_heading_cache.items))
            return
          end
          headings = _heading_cache.headings
        else
          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          local buf_path = vim.api.nvim_buf_get_name(bufnr)
          headings = get_headings(lines, buf_path)
          _heading_cache.bufnr, _heading_cache.tick = bufnr, tick
          _heading_cache.headings = headings
          _heading_cache.items = nil -- invalidate memoized items for new content
        end
        local heading_items = {}
        for _, h in ipairs(headings) do
          heading_items[#heading_items + 1] = make_heading_item(h, h.order, {
            documentation = h.preview ~= "" and {
              kind = "markdown",
              value = string.rep("#", h.level) .. " " .. h.text .. "\n\n" .. h.preview,
            } or nil,
          })
        end
        _heading_cache.items = heading_items
        callback(base.response(heading_items))
      else
        -- Cross-file heading reference: [[Note# — use vault index
        local _, entry = link_utils.resolve_note_via_index(note_name)
        if entry and entry.headings and #entry.headings > 0 then
          local heading_items = {}
          for order, h in ipairs(entry.headings) do
            -- No inline preview; loaded lazily via resolve_item
            heading_items[#heading_items + 1] = make_heading_item(h, order, {
              data = { rel_path = entry.rel_path, heading_line = h.line, heading_level = h.level },
            })
          end
          callback(base.response(heading_items))
        else
          callback(base.empty_response)
        end
      end
      return
    end

    -- Normal note name completion: apply CharBag pre-filter before returning.
    -- Skip the sweep for small lists: blink re-filters via its fuzzy matcher
    -- (both incomplete flags are false), so narrowing here only pays off once
    -- the candidate list is large.
    local prefilter = config.prefilter
    if prefilter.enabled and prefilter.completion_char_bag
      and #items >= (prefilter.min_candidates_for_charbag or 500) then
      local query = tail -- captured once above; equals before:match("!?%[%[(.-)$")
      if #query >= (prefilter.min_query_length or 2) then
        local query_bag = char_bag.from_string(query)
        callback(base.response(charbag_filter(items, query_bag)))
        return
      end
    end
    callback(base.response(items))
  end,

  resolve_item = function(self, item, callback)
    -- Block context preview: lazy-load surrounding lines from disk
    if item.data and item.data.completion_kind == "block" and item.data.rel_path then
      local path = base.resolve_abs_path(item.data.rel_path)
      local block_line = item.data.block_line
      if not block_line then
        callback(item)
        return
      end

      local context_radius = 3
      local all_lines = file_cache.read(path)
      if not all_lines or #all_lines == 0 then
        callback(item)
        return
      end

      local preview = build_context_lines(all_lines, block_line, context_radius)
      if preview ~= "" then
        item.documentation = {
          kind = "plaintext",
          value = preview,
        }
      end

      callback(item)
      return
    end

    -- Heading preview: lazy-load content under the heading from disk
    if item.data and item.data.completion_kind == "heading" and item.data.rel_path then
      local path = base.resolve_abs_path(item.data.rel_path)
      local heading_line = item.data.heading_line
      local heading_level = item.data.heading_level

      local all_lines = file_cache.read(path)
      if not all_lines or #all_lines == 0 then
        callback(item)
        return
      end

      local heading_text = all_lines[heading_line] or ""
      local preview = build_heading_preview(all_lines, heading_line, heading_level)

      if preview ~= "" then
        item.documentation = {
          kind = "markdown",
          value = heading_text .. "\n\n" .. preview,
        }
      else
        item.documentation = {
          kind = "markdown",
          value = heading_text,
        }
      end

      callback(item)
      return
    end

    -- Note-level resolve: show frontmatter + body preview
    -- Derive abs_path from rel_path (abs_path not stored in items to save memory)
    if not (item.data and item.data.rel_path) then
      callback(item)
      return
    end

    local path = base.resolve_abs_path(item.data.rel_path)
    local all_file_lines = file_cache.read(path)
    if not all_file_lines or #all_file_lines == 0 then
      callback(item)
      return
    end

    -- Use first 60 lines for preview (file_cache caches the full read)
    local raw_lines = all_file_lines
    if #raw_lines > 60 then
      raw_lines = {}
      for i = 1, 60 do raw_lines[i] = all_file_lines[i] end
    end

    -- Separate frontmatter from body
    local fm_result = fm_parser.parse_lines(raw_lines, 60)
    local fm_lines = {}
    local body_lines = {}
    if fm_result then
      for i = 2, fm_result.end_line - 1 do
        fm_lines[#fm_lines + 1] = raw_lines[i]
      end
      for i = fm_result.end_line + 1, #raw_lines do
        body_lines[#body_lines + 1] = raw_lines[i]
      end
    else
      for _, line in ipairs(raw_lines) do
        body_lines[#body_lines + 1] = line
      end
    end

    -- Build preview
    local out = {}

    -- Header: note name and path
    out[#out + 1] = "### " .. item.label
    out[#out + 1] = "`" .. item.data.rel_path .. "`"
    out[#out + 1] = ""

    -- Frontmatter as a yaml code block
    if #fm_lines > 0 then
      out[#out + 1] = "```yaml"
      for _, l in ipairs(fm_lines) do
        out[#out + 1] = l
      end
      out[#out + 1] = "```"
      out[#out + 1] = ""
    end

    -- Separator
    out[#out + 1] = "---"
    out[#out + 1] = ""

    -- Body content
    for _, l in ipairs(body_lines) do
      out[#out + 1] = l
    end

    item.documentation = {
      kind = "markdown",
      value = table.concat(out, "\n"),
    }

    callback(item)
  end,
})

function source:get_trigger_characters()
  return { "[", "#", "^" }
end

--- Expose description pool statistics for debug output.
--- @return { unique: number, total: number }
function source.desc_pool_stats()
  local s = string_intern.stats(_desc_pool)
  return { unique = s.size, total = s.hits + s.misses }
end

return source
