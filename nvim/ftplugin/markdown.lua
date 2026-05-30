local opt_local = vim.opt_local

opt_local.spell = true
opt_local.spelllang = "en_us"
opt_local.conceallevel = 2

-- Custom spellfile for vault-specific terms.
-- The first entry is the default (where zg adds words).
local spell_dir = vim.fn.stdpath("config") .. "/spell"
vim.fn.mkdir(spell_dir, "p")
opt_local.spellfile = spell_dir .. "/en.utf-8.add"

opt_local.foldmethod = "expr"
opt_local.foldexpr = "v:lua.vim.treesitter.foldexpr()"
opt_local.foldlevel = 99
opt_local.foldcolumn = "1"
opt_local.foldenable = true

opt_local.foldtext = "v:lua.MarkdownFoldText()"

function MarkdownFoldText()
  local first = vim.fn.getline(vim.v.foldstart)
  local count = vim.v.foldend - vim.v.foldstart
  return first .. " (" .. count .. " lines)"
end

local map = function(lhs, rhs, desc)
  vim.keymap.set("n", lhs, rhs, { buffer = true, desc = desc })
end

-- Smart fold toggle: if cursor is on a callout header line, use callout-aware
-- toggle (same as <leader>mz); otherwise fall back to standard za.
local callout_utils = require("andrew.vault.callout_utils")

local function smart_fold_toggle()
  local line = vim.api.nvim_get_current_line()
  -- Check if current line is a callout header using canonical parser
  if callout_utils.parse_header(line) then
    local ok, callout_folds = pcall(require, "andrew.vault.callout_folds")
    if ok then
      local bufnr = vim.api.nvim_get_current_buf()
      local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]
      local blocks = callout_folds.get_all_blocks(bufnr)
      for _, block in ipairs(blocks) do
        if cursor_lnum == block.start_line and block.end_line > block.start_line then
          -- Ensure foldmethod is manual for fold manipulation
          if vim.wo.foldmethod ~= "manual" then
            vim.wo.foldmethod = "manual"
          end
          local cs = block.start_line + 1
          local ce = block.end_line
          if vim.fn.foldclosed(cs) ~= -1 then
            vim.cmd("silent! " .. cs .. "," .. ce .. "foldopen")
          else
            vim.cmd("silent! " .. cs .. "," .. ce .. "foldclose")
            if vim.fn.foldclosed(cs) == -1 then
              vim.cmd(cs .. "," .. ce .. "fold")
            end
          end
          return
        end
      end
    end
  end
  -- Not on a callout header — use standard fold toggle
  vim.cmd("silent! normal! za")
end

map("<Tab>", smart_fold_toggle, "Toggle fold")
map("za", smart_fold_toggle, "Toggle fold")
map("<leader>mf", "zM", "Fold all")
map("<leader>mu", "zR", "Unfold all")
map("zd", "<Nop>", "Fold delete disabled (expr foldmethod)")
map("zD", "<Nop>", "Fold delete disabled (expr foldmethod)")
map("zE", "<Nop>", "Fold eliminate disabled (expr foldmethod)")
map("zf", "<Nop>", "Fold create disabled (expr foldmethod)")
map("zF", "<Nop>", "Fold create disabled (expr foldmethod)")
map("<leader>ml", function()
  local level = vim.fn.input("Fold level: ")
  level = tonumber(level)
  if level then
    vim.opt_local.foldenable = true
    vim.opt_local.foldlevel = level
    vim.cmd("normal! zx")
  end
end, "Set fold level")

-- =============================================================================
-- Heading Navigation: ]h / [h (any heading), ]1-]6 / [1-[6 (specific level)
-- =============================================================================
local heading_query = vim.treesitter.query.parse("markdown", "((atx_heading) @heading)")

local function get_headings()
  local parser = vim.treesitter.get_parser(0, "markdown")
  if not parser then
    return {}
  end
  local tree = parser:parse()[1]
  if not tree then
    return {}
  end
  local headings = {}
  for _, node in heading_query:iter_captures(tree:root(), 0) do
    local row = node:range()
    local line = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1] or ""
    local hashes = line:match("^(#+)")
    local level = hashes and #hashes or 0
    table.insert(headings, { row = row + 1, level = level }) -- 1-indexed
  end
  return headings
end

map("]h", function()
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  for _, h in ipairs(get_headings()) do
    if h.row > cur then
      vim.api.nvim_win_set_cursor(0, { h.row, 0 })
      vim.cmd("normal! zz")
      return
    end
  end
end, "Next heading")

map("[h", function()
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local headings = get_headings()
  for i = #headings, 1, -1 do
    if headings[i].row < cur then
      vim.api.nvim_win_set_cursor(0, { headings[i].row, 0 })
      vim.cmd("normal! zz")
      return
    end
  end
end, "Previous heading")

for level = 1, 6 do
  map("]" .. level, function()
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    for _, h in ipairs(get_headings()) do
      if h.row > cur and h.level == level then
        vim.api.nvim_win_set_cursor(0, { h.row, 0 })
        vim.cmd("normal! zz")
        return
      end
    end
  end, "Next h" .. level .. " heading")

  map("[" .. level, function()
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    local headings = get_headings()
    for i = #headings, 1, -1 do
      if headings[i].row < cur and headings[i].level == level then
        vim.api.nvim_win_set_cursor(0, { headings[i].row, 0 })
        vim.cmd("normal! zz")
        return
      end
    end
  end, "Previous h" .. level .. " heading")
end

-- Math text objects (am|im) and motions (]m|[m) for inline $...$ and display $$...$$
require("andrew.utils.tex-motions").setup_markdown()

-- Markdown text objects (ac|ic, al|il, aq|iq) and motions (]b|[b, ]l|[l, ]q|[q)
require("andrew.utils.md-textobjects").setup()

-- =============================================================================
-- Smart List Continuation on Enter
-- =============================================================================

local list_cont = require("andrew.utils.list-continuation")

-- Defer CR setup to InsertEnter so autopairs' <CR> mapping is captured correctly
vim.api.nvim_create_autocmd("InsertEnter", {
  buffer = 0,
  once = true,
  callback = function()
    list_cont.setup_buffer()
  end,
  desc = "Setup smart list continuation",
})

-- Normal mode o/O can be set up immediately (no autopairs dependency)
list_cont.setup_buffer_normal()

vim.api.nvim_buf_create_user_command(0, "VaultListContinue", function()
  list_cont.toggle()
end, { desc = "Toggle smart list continuation" })

map("<leader>mx", function()
  require("andrew.vault.tasks").cycle_task("forward")
end, "Cycle checkbox")

-- =============================================================================
-- Markdown Inline Formatting Keybindings
-- =============================================================================

-- Helper: map a visual-mode keybinding that exits visual mode first
local function vmap(lhs, rhs, desc)
  vim.keymap.set("v", lhs, function()
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "x", false)
    vim.schedule(rhs)
  end, { buffer = true, desc = desc })
end

--- Toggle a markdown inline delimiter around text.
--- @param delim string  The delimiter (e.g., "**", "*", "~~", "`")
--- @param mode string   "n" for normal (word under cursor), "v" for visual selection
local function toggle_markup(delim, mode)
  local len = #delim

  if mode == "n" then
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2] -- 0-indexed

    -- Find the word region around the cursor (including adjacent delimiters)
    local word_start = col
    while word_start > 0 and not line:sub(word_start, word_start):match("%s") do
      word_start = word_start - 1
    end
    word_start = word_start + 1 -- 1-indexed

    local word_end = col + 2 -- 1-indexed, start past cursor char
    while word_end <= #line and not line:sub(word_end, word_end):match("%s") do
      word_end = word_end + 1
    end
    word_end = word_end - 1 -- 1-indexed

    local region = line:sub(word_start, word_end)

    -- Determine if region is already delimited.
    -- Guard against partial matches (e.g., * vs **):
    -- After stripping the delimiter, the next char must NOT be the same.
    local is_wrapped = false
    if #region > 2 * len and region:sub(1, len) == delim and region:sub(-len) == delim then
      is_wrapped = true
      -- Check for false positive: * matching the first * of **
      if delim == "*" then
        if region:sub(len + 1, len + 1) == "*" or region:sub(#region - len, #region - len) == "*" then
          is_wrapped = false
        end
      end
    end

    if is_wrapped then
      local unwrapped = region:sub(len + 1, #region - len)
      local new_line = line:sub(1, word_start - 1) .. unwrapped .. line:sub(word_end + 1)
      vim.api.nvim_set_current_line(new_line)
      local new_col = math.max(0, math.min(col - len, word_start - 1 + #unwrapped - 1))
      vim.api.nvim_win_set_cursor(0, { vim.api.nvim_win_get_cursor(0)[1], new_col })
    else
      local wrapped = delim .. region .. delim
      local new_line = line:sub(1, word_start - 1) .. wrapped .. line:sub(word_end + 1)
      vim.api.nvim_set_current_line(new_line)
      vim.api.nvim_win_set_cursor(0, { vim.api.nvim_win_get_cursor(0)[1], col + len })
    end

  elseif mode == "v" then
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    local start_row, start_col = start_pos[2], start_pos[3]
    local end_row, end_col = end_pos[2], end_pos[3]

    if start_row ~= end_row then
      vim.notify("Markdown format: only single-line selections supported", vim.log.levels.WARN)
      return
    end

    local line = vim.api.nvim_buf_get_lines(0, start_row - 1, start_row, false)[1]
    local selected = line:sub(start_col, end_col)

    -- Check if the selected text itself is wrapped
    local sel_wrapped = false
    if #selected > 2 * len and selected:sub(1, len) == delim and selected:sub(-len) == delim then
      sel_wrapped = true
      if delim == "*" then
        if selected:sub(len + 1, len + 1) == "*" or selected:sub(#selected - len, #selected - len) == "*" then
          sel_wrapped = false
        end
      end
    end

    if sel_wrapped then
      -- Remove delimiters from inside the selection
      local unwrapped = selected:sub(len + 1, #selected - len)
      local new_line = line:sub(1, start_col - 1) .. unwrapped .. line:sub(end_col + 1)
      vim.api.nvim_buf_set_lines(0, start_row - 1, start_row, false, { new_line })
      return
    end

    -- Check if delimiters exist just outside the selection
    local pre = line:sub(math.max(1, start_col - len), start_col - 1)
    local post = line:sub(end_col + 1, math.min(#line, end_col + len))
    if pre == delim and post == delim then
      local new_line = line:sub(1, start_col - len - 1) .. selected .. line:sub(end_col + len + 1)
      vim.api.nvim_buf_set_lines(0, start_row - 1, start_row, false, { new_line })
    else
      -- Wrap selection
      local wrapped = delim .. selected .. delim
      local new_line = line:sub(1, start_col - 1) .. wrapped .. line:sub(end_col + 1)
      vim.api.nvim_buf_set_lines(0, start_row - 1, start_row, false, { new_line })
    end
  end
end

-- Toggle bold: **text**
map("<leader>mb", function() toggle_markup("**", "n") end, "Toggle bold")
vmap("<leader>mb", function() toggle_markup("**", "v") end, "Toggle bold")

-- Toggle italic: *text*
map("<leader>mi", function() toggle_markup("*", "n") end, "Toggle italic")
vmap("<leader>mi", function() toggle_markup("*", "v") end, "Toggle italic")

-- Toggle strikethrough: ~~text~~
map("<leader>ms", function() toggle_markup("~~", "n") end, "Toggle strikethrough")
vmap("<leader>ms", function() toggle_markup("~~", "v") end, "Toggle strikethrough")

-- Toggle inline code: `text`
map("<leader>mc", function() toggle_markup("`", "n") end, "Toggle inline code")
vmap("<leader>mc", function() toggle_markup("`", "v") end, "Toggle inline code")

-- =============================================================================
-- Quick Link Creation
-- =============================================================================

--- Create a markdown link [text](url) from visual selection, prompting for URL.
local function create_md_link()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_row, start_col = start_pos[2], start_pos[3]
  local end_row, end_col = end_pos[2], end_pos[3]

  if start_row ~= end_row then
    vim.notify("Link creation: only single-line selections supported", vim.log.levels.WARN)
    return
  end

  local line = vim.api.nvim_buf_get_lines(0, start_row - 1, start_row, false)[1]
  local selected = line:sub(start_col, end_col)

  vim.ui.input({ prompt = "URL: " }, function(url)
    if not url or url == "" then
      return
    end
    local link = "[" .. selected .. "](" .. url .. ")"
    local new_line = line:sub(1, start_col - 1) .. link .. line:sub(end_col + 1)
    vim.api.nvim_buf_set_lines(0, start_row - 1, start_row, false, { new_line })
  end)
end

--- Create a wikilink [[text]] from visual selection (toggle on/off).
local function create_wikilink()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_row, start_col = start_pos[2], start_pos[3]
  local end_row, end_col = end_pos[2], end_pos[3]

  if start_row ~= end_row then
    vim.notify("Link creation: only single-line selections supported", vim.log.levels.WARN)
    return
  end

  local line = vim.api.nvim_buf_get_lines(0, start_row - 1, start_row, false)[1]
  local selected = line:sub(start_col, end_col)

  -- Toggle: if already wrapped in [[...]], unwrap
  local pre2 = line:sub(math.max(1, start_col - 2), start_col - 1)
  local post2 = line:sub(end_col + 1, math.min(#line, end_col + 2))
  if pre2 == "[[" and post2 == "]]" then
    local new_line = line:sub(1, start_col - 3) .. selected .. line:sub(end_col + 3)
    vim.api.nvim_buf_set_lines(0, start_row - 1, start_row, false, { new_line })
  else
    local link = "[[" .. selected .. "]]"
    local new_line = line:sub(1, start_col - 1) .. link .. line:sub(end_col + 1)
    vim.api.nvim_buf_set_lines(0, start_row - 1, start_row, false, { new_line })
  end
end

vmap("<leader>mk", create_md_link, "Create [text](url) link")
vmap("<leader>mK", create_wikilink, "Create [[wikilink]]")

-- =============================================================================
-- Paste Clipboard Image
-- =============================================================================

map("<leader>mp", function()
  require("andrew.vault.images").paste_image()
end, "Paste clipboard image")

-- =============================================================================
-- Toggle Heading Level
-- =============================================================================

--- Set current line to heading level N, or remove heading if already at that level.
--- @param level number  Heading level (1-6)
local function toggle_heading(level)
  local line = vim.api.nvim_get_current_line()
  local prefix = string.rep("#", level) .. " "

  local existing_hashes, rest = line:match("^(#+)%s+(.*)")
  if existing_hashes then
    if #existing_hashes == level then
      -- Same level: remove heading
      vim.api.nvim_set_current_line(rest)
    else
      -- Different level: change to requested level
      vim.api.nvim_set_current_line(prefix .. rest)
    end
  else
    -- No heading: add heading prefix (strip leading whitespace)
    local trimmed = line:match("^%s*(.*)$")
    vim.api.nvim_set_current_line(prefix .. trimmed)
  end
end

for level = 1, 6 do
  map("<leader>m" .. level, function()
    toggle_heading(level)
  end, "Heading " .. level)
end

-- =============================================================================
-- Blockquote / Callout Creation
-- =============================================================================

--- Add one level of blockquote prefix (`> `) to the given lines.
--- Blank lines receive a bare `>` to maintain blockquote continuity.
--- @param start_row number  1-indexed start line
--- @param end_row number    1-indexed end line (inclusive)
local function add_blockquote(start_row, end_row)
  local lines = vim.api.nvim_buf_get_lines(0, start_row - 1, end_row, false)
  for i, line in ipairs(lines) do
    if line:match("^%s*$") then
      lines[i] = ">"
    else
      lines[i] = "> " .. line
    end
  end
  vim.api.nvim_buf_set_lines(0, start_row - 1, end_row, false, lines)
end

--- Remove one level of blockquote prefix from the given lines.
--- Handles `> ` (with space), `>` (bare, on blank lines), and nested `> > `.
--- Lines without a `>` prefix are left unchanged.
--- @param start_row number  1-indexed start line
--- @param end_row number    1-indexed end line (inclusive)
local function remove_blockquote(start_row, end_row)
  local lines = vim.api.nvim_buf_get_lines(0, start_row - 1, end_row, false)
  for i, line in ipairs(lines) do
    local rest = line:match("^> (.*)")
    if rest then
      lines[i] = rest
    else
      rest = line:match("^>(.*)")
      if rest then
        lines[i] = rest == "" and "" or rest
      end
    end
  end
  vim.api.nvim_buf_set_lines(0, start_row - 1, end_row, false, lines)
end

-- Add blockquote level: <leader>mq
map("<leader>mq", function()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  add_blockquote(row, row)
end, "Add blockquote level")

vmap("<leader>mq", function()
  local start_row = vim.fn.getpos("'<")[2]
  local end_row = vim.fn.getpos("'>")[2]
  add_blockquote(start_row, end_row)
end, "Add blockquote level")

-- Remove blockquote level: <leader>mQ
map("<leader>mQ", function()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  remove_blockquote(row, row)
end, "Remove blockquote level")

vmap("<leader>mQ", function()
  local start_row = vim.fn.getpos("'<")[2]
  local end_row = vim.fn.getpos("'>")[2]
  remove_blockquote(start_row, end_row)
end, "Remove blockquote level")

-- Callout creation: <leader>mC
local callout_types = {
  "NOTE",
  "TIP",
  "WARNING",
  "IMPORTANT",
  "CAUTION",
  "ABSTRACT",
  "INFO",
  "TODO",
  "SUCCESS",
  "QUESTION",
  "FAILURE",
  "DANGER",
  "BUG",
  "EXAMPLE",
  "QUOTE",
  "custom...",
}

--- Create a callout block from lines.
--- @param start_row number  1-indexed start line
--- @param end_row number    1-indexed end line (inclusive)
--- @param callout_type string  e.g., "NOTE", "WARNING"
local function create_callout(start_row, end_row, callout_type)
  local lines = vim.api.nvim_buf_get_lines(0, start_row - 1, end_row, false)
  local result = {}
  local first = lines[1] or ""
  if first:match("^%s*$") then
    result[1] = "> [!" .. callout_type .. "]"
  else
    result[1] = "> [!" .. callout_type .. "] " .. first
  end
  for i = 2, #lines do
    local line = lines[i]
    if line:match("^%s*$") then
      result[i] = ">"
    else
      result[i] = "> " .. line
    end
  end
  vim.api.nvim_buf_set_lines(0, start_row - 1, end_row, false, result)
end

--- Prompt for callout type, then wrap lines.
--- @param start_row number  1-indexed start line
--- @param end_row number    1-indexed end line (inclusive)
local function prompt_callout(start_row, end_row)
  vim.ui.select(callout_types, { prompt = "Callout type:" }, function(choice)
    if not choice then
      return
    end
    if choice == "custom..." then
      vim.ui.input({ prompt = "Custom callout type: " }, function(custom)
        if not custom or custom == "" then
          return
        end
        create_callout(start_row, end_row, custom:upper())
      end)
    else
      create_callout(start_row, end_row, choice)
    end
  end)
end

map("<leader>mC", function()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  prompt_callout(row, row)
end, "Create callout")

vmap("<leader>mC", function()
  local start_row = vim.fn.getpos("'<")[2]
  local end_row = vim.fn.getpos("'>")[2]
  prompt_callout(start_row, end_row)
end, "Create callout")

-- =============================================================================
-- Spell Checking Toggle
-- =============================================================================

map("<leader>mS", function()
  vim.opt_local.spell = not vim.opt_local.spell:get()
  vim.notify(
    "Spell checking " .. (vim.opt_local.spell:get() and "ON" or "OFF"),
    vim.log.levels.INFO
  )
end, "Toggle spell check")

-- =============================================================================
-- Table Creation Helper
-- =============================================================================

local table_gen = require("andrew.utils.table-gen")

--- Insert a generated table at the cursor position and enable table mode.
--- @param cols number
--- @param rows number
--- @param headers? string[]
--- @param alignments? string
local function insert_table(cols, rows, headers, alignments)
  local lines = table_gen.generate(cols, rows, headers, alignments)

  -- Insert at current cursor line
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] -- 1-indexed
  vim.api.nvim_buf_set_lines(0, row - 1, row - 1, false, lines)

  -- Move cursor to the first header cell (row 1, after "| ")
  vim.api.nvim_win_set_cursor(0, { row, 2 })

  -- Auto-enable vim-table-mode for immediate cell navigation
  if vim.fn.exists(":TableModeEnable") == 2 then
    vim.cmd("TableModeEnable")
  end

  vim.notify(
    string.format("Created %dx%d table", cols, rows),
    vim.log.levels.INFO
  )
end

--- :TableCreate command handler.
--- Usage:
---   :TableCreate 3x4
---   :TableCreate 3x4 Name|Age|City
---   :TableCreate 3x4 Name|Age|City l|c|r
vim.api.nvim_buf_create_user_command(0, "TableCreate", function(opts)
  local args = opts.fargs
  if #args < 1 then
    vim.notify("Usage: :TableCreate CxR [headers] [alignments]", vim.log.levels.ERROR)
    return
  end

  local cols, rows = table_gen.parse_dimensions(args[1])
  if not cols then
    vim.notify("Invalid dimensions: " .. args[1] .. " (expected CxR, e.g., 3x4)", vim.log.levels.ERROR)
    return
  end

  local headers = nil
  if args[2] then
    headers = table_gen.parse_headers(args[2])
  end

  local alignments = args[3] or nil

  insert_table(cols, rows, headers, alignments)
end, {
  nargs = "+",
  desc = "Create a markdown table with CxR dimensions",
})

--- <leader>mT: Interactive table creation prompt.
map("<leader>Tc", function()
  vim.ui.input({ prompt = "Table dimensions (CxR): " }, function(dim)
    if not dim or dim == "" then
      return
    end

    local cols, rows = table_gen.parse_dimensions(dim)
    if not cols then
      vim.notify("Invalid dimensions: " .. dim .. " (expected CxR, e.g., 3x4)", vim.log.levels.ERROR)
      return
    end

    vim.ui.input({ prompt = "Headers (pipe-separated, or empty for defaults): " }, function(header_str)
      local headers = nil
      if header_str and header_str ~= "" then
        headers = table_gen.parse_headers(header_str)
      end

      vim.ui.input({ prompt = "Alignment (l|c|r per column, or empty for default): " }, function(align_str)
        local alignments = nil
        if align_str and align_str ~= "" then
          alignments = align_str
        end

        insert_table(cols, rows, headers, alignments)
      end)
    end)
  end)
end, "Create table (interactive)")


-- =============================================================================
-- Table Row / Delete Operations
-- =============================================================================

--- Find the bounds of the table surrounding the given line.
--- @param line_nr number 1-indexed line number
--- @return number? start_row, number? end_row 1-indexed bounds, or nil if not in a table
local function find_table_bounds(line_nr)
  local total = vim.api.nvim_buf_line_count(0)
  local line = vim.api.nvim_buf_get_lines(0, line_nr - 1, line_nr, false)[1]
  if not line or not line:match("^%s*|") then
    return nil, nil
  end
  local start_row = line_nr
  while start_row > 1 do
    local prev = vim.api.nvim_buf_get_lines(0, start_row - 2, start_row - 1, false)[1]
    if not prev or not prev:match("^%s*|") then break end
    start_row = start_row - 1
  end
  local end_row = line_nr
  while end_row < total do
    local next_line = vim.api.nvim_buf_get_lines(0, end_row, end_row + 1, false)[1]
    if not next_line or not next_line:match("^%s*|") then break end
    end_row = end_row + 1
  end
  return start_row, end_row
end

--- Parse cell widths from a table row (content between pipes, including padding).
--- @param line string e.g. "| Name | Age |"
--- @return number[]
local function parse_cell_widths(line)
  local widths = {}
  for cell in line:gmatch("|([^|]+)") do
    widths[#widths + 1] = #cell
  end
  return widths
end

map("<leader>Tir", function()
  local line_nr = vim.api.nvim_win_get_cursor(0)[1]
  local start_row, _ = find_table_bounds(line_nr)
  if not start_row then
    vim.notify("Not inside a table", vim.log.levels.WARN)
    return
  end
  -- Use header row for consistent cell widths
  local ref = vim.api.nvim_buf_get_lines(0, start_row - 1, start_row, false)[1]
  local widths = parse_cell_widths(ref)
  local cells = {}
  for _, w in ipairs(widths) do
    cells[#cells + 1] = string.rep(" ", w)
  end
  local new_row = "|" .. table.concat(cells, "|") .. "|"
  vim.api.nvim_buf_set_lines(0, line_nr, line_nr, false, { new_row })
  vim.api.nvim_win_set_cursor(0, { line_nr + 1, 2 })
end, "Insert table row below")

map("<leader>Tdt", function()
  local line_nr = vim.api.nvim_win_get_cursor(0)[1]
  local start_row, end_row = find_table_bounds(line_nr)
  if not start_row then
    vim.notify("Not inside a table", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_buf_set_lines(0, start_row - 1, end_row, false, {})
  vim.api.nvim_win_set_cursor(0, { math.min(start_row, vim.api.nvim_buf_line_count(0)), 0 })
  vim.notify("Deleted table (" .. (end_row - start_row + 1) .. " lines)", vim.log.levels.INFO)
end, "Delete entire table")

-- =============================================================================
-- Smart Paste: URL/note detection on visual paste
-- =============================================================================

local smart_paste = require("andrew.utils.smart-paste")

-- Override visual mode p/P to detect URLs and vault notes in clipboard
for _, key in ipairs({ "p", "P" }) do
  vim.keymap.set("x", key, function()
    -- Exit visual mode to set '< '> marks
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "x", false)
    vim.schedule(function()
      local did_smart = smart_paste.smart_paste()
      if not did_smart then
        -- Fall through to default paste behavior.
        -- Re-select the same range and paste normally.
        vim.cmd("normal! gv" .. key)
      end
    end)
  end, { buffer = true, desc = "Smart paste (auto-link)" })
end

-- Explicit "paste as link" — always attempts smart behavior, warns on failure
-- Uses "x" mode and captures selection bounds BEFORE exiting visual mode,
-- so that which-key or other interceptors can't invalidate the marks.
vim.keymap.set("x", "<leader>mP", function()
  -- Capture selection bounds while still in visual mode
  local s = vim.fn.getpos("v")
  local e = vim.fn.getpos(".")
  -- Normalize: ensure start <= end
  if s[2] > e[2] or (s[2] == e[2] and s[3] > e[3]) then
    s, e = e, s
  end
  -- Exit visual mode to set marks
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.api.nvim_feedkeys(esc, "x", false)
  vim.schedule(function()
    local ok, err = pcall(smart_paste.smart_paste, {
      force = true,
      range = { s[2], s[3], e[2], e[3] },
    })
    if not ok then
      vim.notify("Smart paste error: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end, { buffer = true, desc = "Paste clipboard as link" })

-- Normal mode: paste clipboard URL/note as link around word under cursor
vim.keymap.set("n", "<leader>mP", function()
  -- Select inner word and exit visual mode to set '< '> marks
  local keys = vim.api.nvim_replace_termcodes("viw<Esc>", true, false, true)
  vim.api.nvim_feedkeys(keys, "nx", false)
  vim.schedule(function()
    local ok, err = pcall(smart_paste.smart_paste, { force = true })
    if not ok then
      vim.notify("Smart paste error: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end, { buffer = true, desc = "Paste clipboard as link (word under cursor)" })

-- Buffer-local command to toggle auto smart paste
vim.api.nvim_buf_create_user_command(0, "SmartPasteToggle", function()
  local current = vim.b.smart_paste_auto
  if current == nil then current = true end
  vim.b.smart_paste_auto = not current
  vim.notify(
    "Smart paste auto: " .. (vim.b.smart_paste_auto and "ON" or "OFF"),
    vim.log.levels.INFO
  )
end, { desc = "Toggle automatic smart paste for this buffer" })

-- =============================================================================
-- Which-Key: Register <leader>m subgroups for markdown buffers
-- =============================================================================

local ok, wk = pcall(require, "which-key")
if ok then
  wk.add({
    -- Override global "Make/Build" label in markdown buffers
    { "<leader>m", group = "Markdown", icon = { icon = "", color = "blue" }, buffer = 0 },

    -- ── Formatting ──────────────────────────────────────────────────────
    { "<leader>mb", icon = { icon = "󰉿", color = "yellow" }, buffer = 0 },
    { "<leader>mi", icon = { icon = "󰉿", color = "yellow" }, buffer = 0 },
    { "<leader>ms", icon = { icon = "󰉿", color = "yellow" }, buffer = 0 },
    { "<leader>mc", icon = { icon = "", color = "yellow" }, buffer = 0 },

    -- ── Headings ────────────────────────────────────────────────────────
    { "<leader>m1", icon = { icon = "󰉫", color = "purple" }, buffer = 0 },
    { "<leader>m2", icon = { icon = "󰉬", color = "purple" }, buffer = 0 },
    { "<leader>m3", icon = { icon = "󰉭", color = "purple" }, buffer = 0 },
    { "<leader>m4", icon = { icon = "󰉮", color = "purple" }, buffer = 0 },
    { "<leader>m5", icon = { icon = "󰉯", color = "purple" }, buffer = 0 },
    { "<leader>m6", icon = { icon = "󰉰", color = "purple" }, buffer = 0 },

    -- ── Folding ─────────────────────────────────────────────────────────
    { "<leader>mf", icon = { icon = "", color = "cyan" }, buffer = 0 },
    { "<leader>mu", icon = { icon = "", color = "cyan" }, buffer = 0 },
    { "<leader>ml", icon = { icon = "", color = "cyan" }, buffer = 0 },

    -- ── Blocks (blockquote / callout) ───────────────────────────────────
    { "<leader>mq", icon = { icon = "", color = "green" }, buffer = 0 },
    { "<leader>mQ", icon = { icon = "", color = "green" }, buffer = 0 },
    { "<leader>mC", icon = { icon = "", color = "green" }, buffer = 0 },
    { "<leader>mz", icon = { icon = "", color = "green" }, buffer = 0 },
    { "<leader>mZ", icon = { icon = "", color = "green" }, buffer = 0 },

    -- ── Links ───────────────────────────────────────────────────────────
    { "<leader>mP", icon = { icon = "", color = "orange" }, buffer = 0 },

    -- ── Tasks ───────────────────────────────────────────────────────────
    { "<leader>mx", icon = { icon = "", color = "red" }, buffer = 0 },

    -- ── Media ───────────────────────────────────────────────────────────
    { "<leader>mp", icon = { icon = "", color = "azure" }, buffer = 0 },

    -- ── Footnotes ───────────────────────────────────────────────────────
    { "<leader>mj", icon = { icon = "", color = "orange" }, buffer = 0 },
    { "<leader>mn", icon = { icon = "", color = "orange" }, buffer = 0 },

    -- ── Spell ───────────────────────────────────────────────────────────
    { "<leader>mS", icon = { icon = "󰓆", color = "grey" }, buffer = 0 },

    -- ── Visual mode: same prefix ────────────────────────────────────────
    { mode = "v", "<leader>m", group = "Markdown", icon = { icon = "", color = "blue" }, buffer = 0 },

    { mode = "v", "<leader>mb", icon = { icon = "󰉿", color = "yellow" }, buffer = 0 },
    { mode = "v", "<leader>mi", icon = { icon = "󰉿", color = "yellow" }, buffer = 0 },
    { mode = "v", "<leader>ms", icon = { icon = "󰉿", color = "yellow" }, buffer = 0 },
    { mode = "v", "<leader>mc", icon = { icon = "", color = "yellow" }, buffer = 0 },
    { mode = "v", "<leader>mq", icon = { icon = "", color = "green" }, buffer = 0 },
    { mode = "v", "<leader>mQ", icon = { icon = "", color = "green" }, buffer = 0 },
    { mode = "v", "<leader>mC", icon = { icon = "", color = "green" }, buffer = 0 },
    { mode = "v", "<leader>mk", icon = { icon = "", color = "orange" }, buffer = 0 },
    { mode = "v", "<leader>mK", icon = { icon = "", color = "orange" }, buffer = 0 },

    -- Visual "x" mode for smart paste
    { mode = "x", "<leader>mP", icon = { icon = "", color = "orange" }, buffer = 0 },

    -- ── Table operations ────────────────────────────────────────────────
    { "<leader>T",   group = "Table", buffer = 0 },
    { "<leader>Tc",  desc = "Create table (interactive)", buffer = 0 },
    { "<leader>Ti",  group = "Insert", buffer = 0 },
    { "<leader>Td",  group = "Delete", buffer = 0 },
    { "<leader>Tir", desc = "Insert row below",   buffer = 0 },
    { "<leader>Tdt", desc = "Delete entire table", buffer = 0 },

    -- ── List continuation ───────────────────────────────────────────────
    { "<CR>", desc = "Smart list continue", buffer = 0, mode = "i" },

    -- ── Spell motions (built-in, listed for discoverability) ────────────
    { "]s",  desc = "Next misspelling",     buffer = 0 },
    { "[s",  desc = "Prev misspelling",     buffer = 0 },
    { "z=",  desc = "Spell suggestions",    buffer = 0 },
    { "zg",  desc = "Add word to spellfile", buffer = 0 },
    { "zw",  desc = "Mark word as bad",     buffer = 0 },
    { "zug", desc = "Undo add to spellfile", buffer = 0 },

    -- ── Heading navigation (bracket motions) ────────────────────────────
    { "]h", desc = "Next heading",     buffer = 0 },
    { "[h", desc = "Previous heading", buffer = 0 },
  })
end
