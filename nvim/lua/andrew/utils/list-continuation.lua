--- Smart list continuation for markdown buffers.
--- Automatically continues list markers, blockquotes, and task checkboxes
--- when pressing Enter in insert mode.
local M = {}

-- ---------------------------------------------------------------------------
-- Patterns
-- ---------------------------------------------------------------------------

-- Blockquote prefix: one or more `> ` layers (with optional trailing space).
local BLOCKQUOTE_PREFIX = "^(>[> ]*>?%s?)"

-- List bullet patterns (applied AFTER stripping blockquote prefix).
-- Order matters: task must be checked before unordered (superset).
local patterns = {
  -- Task list: `- [ ] `, `* [x] `, `+ [/] `, etc.
  {
    type = "task",
    pattern = "^(%s*)([%-%*%+])(%s%[.%]%s)",
    continue = function(indent, marker, _checkbox)
      return indent .. marker .. " [ ] "
    end,
    empty = function(indent, marker, checkbox)
      return indent .. marker .. checkbox
    end,
  },
  -- Unordered: `- `, `* `, `+ `
  {
    type = "unordered",
    pattern = "^(%s*)([%-%*%+])(%s)",
    continue = function(indent, marker, space)
      return indent .. marker .. space
    end,
    empty = function(indent, marker, space)
      return indent .. marker .. space
    end,
  },
  -- Ordered: `1. `, `2) `, `12. `, etc.
  {
    type = "ordered",
    pattern = "^(%s*)(%d+)([%.%)]%s)",
    continue = function(indent, num, sep)
      return indent .. tostring(tonumber(num) + 1) .. sep
    end,
    empty = function(indent, num, sep)
      return indent .. num .. sep
    end,
  },
}

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local function get_config()
  local ok, cfg = pcall(require, "andrew.vault.config")
  if ok and cfg.list_continuation then
    return cfg.list_continuation
  end
  return { enabled = true, continue_blockquotes = true, continue_on_o = true }
end

-- ---------------------------------------------------------------------------
-- Treesitter context guards
-- ---------------------------------------------------------------------------

local function in_code_block()
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = 0 })
  if not ok or not node then
    return false
  end
  while node do
    local ntype = node:type()
    if ntype == "fenced_code_block" or ntype == "code_fence_content" then
      return true
    end
    node = node:parent()
  end
  return false
end

local function in_frontmatter()
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = 0 })
  if not ok or not node then
    return false
  end
  while node do
    local ntype = node:type()
    if ntype == "minus_metadata" or ntype == "front_matter" then
      return true
    end
    node = node:parent()
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Line parser
-- ---------------------------------------------------------------------------

--- Parse a markdown line into its structural components.
---@param line string
---@return table|nil result with fields:
---   - blockquote: string  blockquote prefix (empty string if none)
---   - indent: string      whitespace before bullet
---   - bullet_full: string the full bullet prefix (e.g., "- [ ] ", "1. ")
---   - continuation: string what to put on the next line
---   - content: string     text after the bullet
---   - is_empty: boolean   true if content is empty/whitespace-only
---   - type: string        "task"|"unordered"|"ordered"|"blockquote"
function M.parse_line(line)
  -- Extract blockquote prefix
  local bq_prefix = ""
  local rest = line
  local bq_match = line:match(BLOCKQUOTE_PREFIX)
  if bq_match then
    bq_prefix = bq_match
    rest = line:sub(#bq_prefix + 1)
  end

  -- Try each list pattern against the remainder
  for _, pat in ipairs(patterns) do
    local c1, c2, c3 = rest:match(pat.pattern)
    if c1 then
      local bullet_full = c1 .. c2 .. c3
      local content = rest:sub(#bullet_full + 1)
      return {
        blockquote = bq_prefix,
        indent = c1,
        bullet_full = bullet_full,
        continuation = bq_prefix .. pat.continue(c1, c2, c3),
        content = content,
        is_empty = content:match("^%s*$") ~= nil,
        type = pat.type,
      }
    end
  end

  -- No list bullet found -- check for bare blockquote
  if bq_prefix ~= "" then
    local content = rest
    return {
      blockquote = bq_prefix,
      indent = "",
      bullet_full = "",
      continuation = bq_prefix,
      content = content,
      is_empty = content:match("^%s*$") ~= nil,
      type = "blockquote",
    }
  end

  return nil
end

-- ---------------------------------------------------------------------------
-- Empty bullet handler
-- ---------------------------------------------------------------------------

--- Handle the empty bullet case: remove bullet and optionally reduce indent.
---@param parsed table  the result from parse_line()
---@param line_nr number  1-indexed line number
---@return boolean handled  true if we handled it
function M.handle_empty_bullet(parsed, line_nr)
  if not parsed.is_empty then
    return false
  end

  local indent = parsed.indent
  local bq = parsed.blockquote

  if #indent > 0 then
    -- Reduce indent by one shiftwidth level (or 2 spaces as fallback)
    local sw = vim.bo.shiftwidth
    if sw == 0 then sw = vim.bo.tabstop end
    if sw == 0 then sw = 2 end
    local new_indent_len = math.max(0, #indent - sw)
    local new_indent = indent:sub(1, new_indent_len)
    -- Keep the same bullet type but at reduced indent, still empty
    local new_line = bq .. new_indent .. parsed.bullet_full:sub(#indent + 1)
    vim.api.nvim_set_current_line(new_line)
    vim.api.nvim_win_set_cursor(0, { line_nr, #new_line })
  else
    -- Top-level bullet: clear the line entirely, but keep the blockquote prefix
    -- when the empty thing is a BULLET INSIDE a quote (`> - ` -> `> `).
    -- For a bare blockquote line (`> `, parse type "blockquote") the prefix IS
    -- the item, so keeping it rewrote the line to itself and <CR> was a no-op:
    -- there was no way to leave a quote. Clear it to "" instead.
    if bq ~= "" and parsed.type ~= "blockquote" then
      vim.api.nvim_set_current_line(bq)
      vim.api.nvim_win_set_cursor(0, { line_nr, #bq })
    else
      vim.api.nvim_set_current_line("")
      vim.api.nvim_win_set_cursor(0, { line_nr, 0 })
    end
  end

  return true
end

-- ---------------------------------------------------------------------------
-- Enable/disable toggle
-- ---------------------------------------------------------------------------

function M.is_enabled()
  local buf_val = vim.b.list_continuation_enabled
  if buf_val ~= nil then return buf_val end
  return get_config().enabled
end

function M.toggle()
  local current = M.is_enabled()
  vim.b.list_continuation_enabled = not current
  vim.notify(
    "List continuation: " .. (vim.b.list_continuation_enabled and "ON" or "OFF"),
    vim.log.levels.INFO
  )
end

-- ---------------------------------------------------------------------------
-- nvim-autopairs bracket-pair expansion inside a list item
-- ---------------------------------------------------------------------------
-- On a prose line `foo(|)` + <CR> is autopairs' pair expansion: `foo(` / empty
-- line with the cursor on it / `)`. On a list line the mid-line split below used
-- to win instead and produced `- x (` / `- )`, i.e. a bogus second bullet. The
-- pair expansion is what the user wants in both places, so when the cursor sits
-- directly between an opener and its matching closer we hand <CR> to the
-- autopairs mapping captured by make_cr_fallback() and then re-indent the two
-- lines it produced.
--
-- Only `()`, `[]` and `{}` qualify, and only when nvim-autopairs really has that
-- rule live for this buffer. Quotes/backticks are deliberately excluded: `- "|"`
-- + <CR> reads as ordinary prose typing, and the ``` rules are `only_cr`
-- *endwise* rules that never match "cursor between opener and closer", so every
-- other line keeps byte-identical behaviour.
local BRACKET_PAIRS = { ["("] = ")", ["["] = "]", ["{"] = "}" }

-- Cache of the bracket subset of autopairs' per-buffer rule list. Keyed by the
-- rule table's identity (nvim-autopairs swaps the table in set_buf_rule(), e.g.
-- after add_rule/remove_rule), so a rule change invalidates it for free and the
-- per-keystroke cost is one table lookup.
local ap_cache_bufnr, ap_cache_rules, ap_cache_map

--- opener -> closer for the bracket rules nvim-autopairs currently has active in
--- the current buffer. nil when autopairs is not loaded, not attached here, or
--- has no plain bracket rule left.
local function active_bracket_pairs()
  -- Never `require` it: if autopairs is not loaded there is nothing to delegate
  -- to, and forcing the plugin to load from the <CR> hot path would be wrong.
  local ap = package.loaded["nvim-autopairs"]
  if not ap or type(ap.get_buf_rules) ~= "function" then
    return nil
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local rules = ap.get_buf_rules(bufnr)
  if bufnr == ap_cache_bufnr and rules == ap_cache_rules then
    return ap_cache_map
  end
  local map
  for _, rule in pairs(rules) do
    local closer = rule.start_pair and BRACKET_PAIRS[rule.start_pair]
    if closer and rule.end_pair == closer and not rule.is_regex then
      map = map or {}
      map[rule.start_pair] = closer
    end
  end
  ap_cache_bufnr, ap_cache_rules, ap_cache_map = bufnr, rules, map
  return map
end

--- The closing bracket the cursor is sitting in front of, when the cursor is
--- directly between an autopairs bracket pair AND autopairs would expand it.
---@param line string
---@param col number  0-indexed byte offset of the cursor
---@return string|nil closer
local function bracket_pair_at_cursor(line, col)
  -- Cheapest possible rejection first: this runs on every <CR> in a list item.
  if col == 0 or col >= #line then
    return nil
  end
  local closer = BRACKET_PAIRS[line:sub(col, col)]
  if not closer or line:sub(col + 1, col + #closer) ~= closer then
    return nil
  end
  local map = active_bracket_pairs()
  if not map or map[line:sub(col, col)] ~= closer then
    return nil
  end
  -- Final authority: ask autopairs itself. It returns a bare <CR> when it is
  -- disabled for this buffer or a `can_cr` condition vetoes the expansion, and
  -- in that case we must keep the normal list behaviour rather than delegate.
  local ap = package.loaded["nvim-autopairs"]
  if type(ap.autopairs_cr) ~= "function" then
    return nil
  end
  local ok, keys = pcall(ap.autopairs_cr)
  if not ok or keys == "\r" then
    return nil
  end
  return closer
end

--- Re-indent the three lines autopairs' pair expansion just produced so the
--- middle (cursor) line and the closer line sit at the list item's CONTENT
--- column instead of column 0.
---
--- Why indent at all: autopairs' own sequence is
--- `<c-g>u<CR><CMD>normal! ====<CR><up><end><CR>`, and `==` is a no-op in
--- markdown (tree-sitter indent is disabled for markdown in treesitter.lua and
--- there is no indent/markdown.vim), so raw delegation leaves both new lines at
--- column 0. A column-0 `)` terminates the list item, turning the item into a
--- paragraph; indenting to the content column keeps the whole thing one list
--- item, which is what `- x (`-then-<CR> is asking for.
---
--- Fed as a trailing <Cmd> key (not vim.schedule) so it is ordered *after*
--- autopairs' keys in the typeahead deterministically.
---@param prefix string  whitespace/blockquote prefix to put on both new lines
---@param closer string  the closing bracket we expect on the line below
function M._indent_pair_expansion(prefix, closer)
  if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  -- Bail out unless the buffer looks exactly like the expansion we asked for:
  -- blank cursor line, closer alone on the line below. A rule with a custom
  -- map_cr_func may produce something else entirely -- leave it be.
  if vim.api.nvim_get_current_line():match("^%s*$") == nil then
    return
  end
  local below = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1]
  if below == nil then
    return
  end
  -- Prefix match, not equality: the closer can carry text that was after the
  -- cursor (`- x (|) tail`), and a `[[|]]` wikilink leaves `]]` on that line
  -- while the matched rule was the single-char `[`/`]` one.
  below = vim.trim(below)
  if below:sub(1, #closer) ~= closer then
    return
  end
  vim.api.nvim_buf_set_lines(0, row - 1, row + 1, false, { prefix, prefix .. below })
  vim.api.nvim_win_set_cursor(0, { row, #prefix })
end

--- Column the list item's content starts at, expressed as a prefix string:
--- blockquote markers + the item's own indent + spaces for the bullet's width.
--- `- x ` -> "  ", `  - a ` -> "    ", `- [ ] z ` -> "      ", `> q ` -> "> ".
--- Tabs in the indent are preserved; only the marker itself becomes spaces.
local function content_indent(parsed)
  return parsed.blockquote
    .. parsed.indent
    .. string.rep(" ", #parsed.bullet_full - #parsed.indent)
end

-- ---------------------------------------------------------------------------
-- CR action (insert mode)
-- ---------------------------------------------------------------------------

--- The main CR handler for insert mode in markdown buffers.
---@param fallback_cr string|fun()  the original CR action (for non-list lines)
---@return string|fun() result  "" if handled, else the fallback to run
function M.cr_action(fallback_cr)
  if not M.is_enabled() then
    return fallback_cr
  end

  if in_code_block() or in_frontmatter() then
    return fallback_cr
  end

  local line = vim.api.nvim_get_current_line()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] -- 1-indexed
  local col = cursor[2] -- 0-indexed byte offset

  local parsed = M.parse_line(line)

  -- Not a list or blockquote line: fall through
  if not parsed then
    return fallback_cr
  end

  -- Cursor directly between a bracket pair (`- x (|)`): autopairs' pair
  -- expansion wins over list continuation / the mid-line split below, so no
  -- stray bullet is created. Delegate to the captured autopairs mapping and
  -- append a re-indent to the content column.
  local closer = bracket_pair_at_cursor(line, col)
  if closer then
    if type(fallback_cr) ~= "function" then
      return fallback_cr
    end
    local fixup = vim.api.nvim_replace_termcodes(
      ("<Cmd>lua require('andrew.utils.list-continuation')._indent_pair_expansion(%q, %q)<CR>")
        :format(content_indent(parsed), closer),
      true,
      false,
      true
    )
    return function()
      -- Queue the fixup at the FRONT of the typeahead first, then let
      -- make_cr_fallback's own front-insert put autopairs' keys ahead of it.
      -- Both land before anything the user typed after <CR>.
      vim.api.nvim_feedkeys(fixup, "ni", false)
      fallback_cr()
    end
  end

  -- Skip bare blockquote continuation if disabled
  if parsed.type == "blockquote" and not get_config().continue_blockquotes then
    return fallback_cr
  end

  -- Empty bullet: delete it instead of continuing
  if parsed.is_empty then
    M.handle_empty_bullet(parsed, row)
    return ""
  end

  local continuation = parsed.continuation

  -- Cursor is somewhere in the line (not at the end): split
  if col < #line then
    local before = line:sub(1, col)
    local after = line:sub(col + 1)
    vim.api.nvim_set_current_line(before)
    vim.api.nvim_buf_set_lines(0, row, row, false, { continuation .. after })
    vim.api.nvim_win_set_cursor(0, { row + 1, #continuation })
    return ""
  end

  -- Cursor at end of line: simple case
  vim.api.nvim_buf_set_lines(0, row, row, false, { continuation })
  vim.api.nvim_win_set_cursor(0, { row + 1, #continuation })
  return ""
end

-- ---------------------------------------------------------------------------
-- Buffer setup: insert-mode <CR>
-- ---------------------------------------------------------------------------

--- Set up the <CR> mapping for the current markdown buffer.
--- Should be called from ftplugin/markdown.lua (deferred to InsertEnter).
--- Build a function that replays the <CR> mapping captured by maparg().
---
--- The captured mapping can take three shapes, and each must be replayed
--- differently -- feeding the raw `rhs` string only works for the plain-keys
--- case:
---   * Lua callback (blink.cmp)      -> call it; if `expr`, feed its return value
---   * Vimscript `<expr>` (autopairs:
---     `v:lua.require'nvim-autopairs'.completion_confirm()`)
---                                   -> nvim_eval the rhs, feed the result
---   * plain key sequence            -> replace termcodes, feed
--- Feeding the autopairs expr source as literal keys is what typed a stray
--- Lua line into the buffer on every non-list <CR>.
---@param map table|nil  result of vim.fn.maparg("<CR>", "i", false, true)
---@return fun()
local function make_cr_fallback(map)
  local plain_cr = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
  -- The "i" flag inserts at the FRONT of the typeahead so the replayed keys
  -- run before anything the user has already typed after <CR>; appending
  -- ("n"/"m" alone) would reorder fast typing.
  local function feed_plain()
    vim.api.nvim_feedkeys(plain_cr, "ni", false)
  end

  if type(map) ~= "table" or vim.tbl_isempty(map) then
    return feed_plain
  end

  -- Respect the original mapping's remap flag when replaying its output.
  local feed_mode = (map.noremap == 1 and "n" or "m") .. "i"
  local is_expr = map.expr == 1

  local function feed(keys)
    if type(keys) == "string" and keys ~= "" then
      vim.api.nvim_feedkeys(keys, feed_mode, false)
    end
  end

  if type(map.callback) == "function" then
    return function()
      if is_expr then
        local keys = map.callback()
        if type(keys) == "string" and map.replace_keycodes == 1 then
          keys = vim.api.nvim_replace_termcodes(keys, true, true, true)
        end
        feed(keys)
      else
        map.callback()
      end
    end
  end

  if type(map.rhs) == "string" and map.rhs ~= "" then
    if is_expr then
      return function()
        -- An <expr> mapping's result is already raw key bytes.
        local ok, keys = pcall(vim.api.nvim_eval, map.rhs)
        if ok then
          feed(keys)
        else
          feed_plain()
        end
      end
    end
    local keys = vim.api.nvim_replace_termcodes(map.rhs, true, true, true)
    return function()
      feed(keys)
    end
  end

  return feed_plain
end

function M.setup_buffer()
  -- Capture the existing <CR> mapping so we can fall back to it
  -- (this preserves autopairs' CR behavior for bracket expansion)
  local existing_cr = vim.fn.maparg("<CR>", "i", false, true)
  local fallback_cr = make_cr_fallback(existing_cr)

  vim.keymap.set("i", "<CR>", function()
    local result = M.cr_action(fallback_cr)
    if result == "" then
      return
    end
    if type(result) == "function" then
      result()
    elseif type(result) == "string" then
      vim.api.nvim_feedkeys(result, "ni", false)
    end
  end, {
    buffer = true,
    desc = "Smart list continuation",
    silent = true,
  })
end

-- ---------------------------------------------------------------------------
-- Buffer setup: normal-mode o / O
-- ---------------------------------------------------------------------------

--- Set up `o` and `O` overrides for the current markdown buffer.
function M.setup_buffer_normal()
  if not get_config().continue_on_o then
    return
  end

  vim.keymap.set("n", "o", function()
    if not M.is_enabled() or in_code_block() or in_frontmatter() then
      local keys = vim.api.nvim_replace_termcodes("o", true, false, true)
      vim.api.nvim_feedkeys(keys, "n", false)
      return
    end

    local line = vim.api.nvim_get_current_line()
    local parsed = M.parse_line(line)
    if parsed and not parsed.is_empty then
      local row = vim.api.nvim_win_get_cursor(0)[1]
      vim.api.nvim_buf_set_lines(0, row, row, false, { parsed.continuation })
      vim.api.nvim_win_set_cursor(0, { row + 1, #parsed.continuation })
      vim.cmd("startinsert!")
    else
      local keys = vim.api.nvim_replace_termcodes("o", true, false, true)
      vim.api.nvim_feedkeys(keys, "n", false)
    end
  end, {
    buffer = true,
    desc = "Smart list continuation (o)",
    silent = true,
  })

  vim.keymap.set("n", "O", function()
    if not M.is_enabled() or in_code_block() or in_frontmatter() then
      local keys = vim.api.nvim_replace_termcodes("O", true, false, true)
      vim.api.nvim_feedkeys(keys, "n", false)
      return
    end

    local line = vim.api.nvim_get_current_line()
    local parsed = M.parse_line(line)
    if parsed and not parsed.is_empty then
      local row = vim.api.nvim_win_get_cursor(0)[1]
      -- For O, insert above. For ordered lists, use the current number.
      local continuation = parsed.continuation
      if parsed.type == "ordered" then
        continuation = parsed.blockquote .. parsed.bullet_full
      end
      vim.api.nvim_buf_set_lines(0, row - 1, row - 1, false, { continuation })
      vim.api.nvim_win_set_cursor(0, { row, #continuation })
      vim.cmd("startinsert!")
    else
      local keys = vim.api.nvim_replace_termcodes("O", true, false, true)
      vim.api.nvim_feedkeys(keys, "n", false)
    end
  end, {
    buffer = true,
    desc = "Smart list continuation (O)",
    silent = true,
  })
end

return M
