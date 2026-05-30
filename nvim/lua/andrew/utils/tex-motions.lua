-- =============================================================================
-- LaTeX motions and text objects via TreeSitter
-- =============================================================================
local M = {}

-- Node type sets
local section_types = {
  part = true,
  chapter = true,
  section = true,
  subsection = true,
  subsubsection = true,
  paragraph = true,
  subparagraph = true,
}

local env_types = {
  generic_environment = true,
  math_environment = true,
}

local math_types = {
  inline_formula = true,
  displayed_equation = true,
  math_environment = true,
}

-- =============================================================================
-- TreeSitter helpers
-- =============================================================================

local function get_root()
  local ok, parser = pcall(vim.treesitter.get_parser, 0, "latex")
  if not ok or not parser then
    return nil
  end
  local trees = parser:parse()
  return trees and trees[1] and trees[1]:root()
end

--- Collect all nodes matching `types` in document order.
local function collect_nodes(root, types)
  local result = {}
  local function walk(node)
    if types[node:type()] then
      result[#result + 1] = node
    end
    for child in node:iter_children() do
      walk(child)
    end
  end
  walk(root)
  return result
end

--- Find the innermost ancestor (or self) matching `types` from cursor.
local function enclosing_node(types)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = 0 })
  if not ok or not node then
    return nil
  end
  while node do
    if types[node:type()] then
      return node
    end
    node = node:parent()
  end
end

-- =============================================================================
-- Selection helper (works in visual and operator-pending modes)
-- All parameters are 0-indexed row/col, ec is inclusive.
-- =============================================================================

local function select_range(sr, sc, er, ec)
  if sr > er or (sr == er and sc > ec) then
    return
  end
  vim.api.nvim_win_set_cursor(0, { sr + 1, sc })
  vim.cmd("normal! v")
  vim.api.nvim_win_set_cursor(0, { er + 1, ec })
end

-- =============================================================================
-- Motions: jump to next/previous node of a given type
-- Supports v:count (e.g., 3]] jumps 3 sections forward)
-- =============================================================================

function M.next_node(types)
  local root = get_root()
  if not root then
    return
  end
  local nodes = collect_nodes(root, types)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1
  local count = vim.v.count1
  local found = 0
  for _, node in ipairs(nodes) do
    local sr, sc = node:range()
    if sr > row or (sr == row and sc > col) then
      found = found + 1
      if found == count then
        vim.api.nvim_win_set_cursor(0, { sr + 1, sc })
        return
      end
    end
  end
end

function M.prev_node(types)
  local root = get_root()
  if not root then
    return
  end
  local nodes = collect_nodes(root, types)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1
  local count = vim.v.count1
  local found = 0
  for i = #nodes, 1, -1 do
    local sr, sc = nodes[i]:range()
    if sr < row or (sr == row and sc < col) then
      found = found + 1
      if found == count then
        vim.api.nvim_win_set_cursor(0, { sr + 1, sc })
        return
      end
    end
  end
end

-- =============================================================================
-- Text objects
-- =============================================================================

--- "around environment": select full \begin{...}...\end{...} range.
function M.around_env()
  local node = enclosing_node(env_types)
  if not node then
    return
  end
  local sr, sc, er, ec = node:range()
  select_range(sr, sc, er, ec - 1)
end

--- "inside environment": content between \begin{...} and \end{...}.
--- Accepts optional node for reuse from inside_math.
function M.inside_env(target)
  local node = target or enclosing_node(env_types)
  if not node then
    return
  end

  local begin_node, end_node
  for child in node:iter_children() do
    local t = child:type()
    if t == "begin" then
      begin_node = child
    end
    if t == "end" then
      end_node = child
    end
  end
  if not begin_node or not end_node then
    return
  end

  -- Inner range: from end-of-begin to start-of-end
  local _, _, br, bc = begin_node:range() -- bc is exclusive end col of \begin{...}
  local er, ec = end_node:range() -- er,ec is start of \end{...}

  -- If \begin{...} ends at EOL, start inner range on next line
  local begin_line = vim.api.nvim_buf_get_lines(0, br, br + 1, false)[1] or ""
  if bc >= #begin_line then
    br, bc = br + 1, 0
  end

  -- If \end{...} starts at BOL, end inner range on previous line
  if ec == 0 and er > br then
    er = er - 1
    local prev = vim.api.nvim_buf_get_lines(0, er, er + 1, false)[1] or ""
    ec = math.max(0, #prev - 1)
  else
    ec = math.max(0, ec - 1)
  end

  select_range(br, bc, er, ec)
end

--- "around math": select full math zone including delimiters.
function M.around_math()
  local node = enclosing_node(math_types)
  if not node then
    return
  end
  local sr, sc, er, ec = node:range()
  select_range(sr, sc, er, ec - 1)
end

--- "inside math": content within math delimiters.
function M.inside_math()
  local node = enclosing_node(math_types)
  if not node then
    return
  end
  local t = node:type()

  -- math_environment has begin/end structure, delegate to inside_env
  if t == "math_environment" then
    M.inside_env(node)
    return
  end

  local sr, sc, er, ec = node:range() -- ec is exclusive

  if t == "inline_formula" then
    -- $content$ → skip leading $ and trailing $
    select_range(sr, sc + 1, er, ec - 2)
  elseif t == "displayed_equation" then
    -- \[content\] → skip \[ (2 chars) and \] (2 chars)
    local isr, isc = sr, sc + 2
    local begin_line = vim.api.nvim_buf_get_lines(0, sr, sr + 1, false)[1] or ""
    if isc >= #begin_line then
      isr, isc = sr + 1, 0
    end

    -- Content ends before \] which occupies ec-2..ec-1
    local ier, iec = er, ec - 3
    if iec < 0 and ier > isr then
      ier = er - 1
      local prev = vim.api.nvim_buf_get_lines(0, ier, ier + 1, false)[1] or ""
      iec = math.max(0, #prev - 1)
    else
      iec = math.max(0, iec)
    end

    select_range(isr, isc, ier, iec)
  end
end

--- "around command": select full \cmd{...} including command name and arguments.
function M.around_cmd()
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = 0 })
  if not ok or not node then
    return
  end
  while node do
    if node:type() == "generic_command" then
      local sr, sc, er, ec = node:range()
      select_range(sr, sc, er, ec - 1)
      return
    end
    node = node:parent()
  end
end

--- "inside command": select content within the nearest curly_group of a command.
--- For \frac{a}{b}, selects whichever argument the cursor is in.
function M.inside_cmd()
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = 0 })
  if not ok or not node then
    return
  end
  while node do
    if node:type() == "curly_group" then
      local parent = node:parent()
      -- Only match curly_group inside commands, not inside \begin{...}/\end{...}
      if parent and parent:type() == "generic_command" then
        local sr, sc, er, ec = node:range()
        select_range(sr, sc + 1, er, ec - 2) -- skip { and }
        return
      end
    end
    node = node:parent()
  end
end

-- =============================================================================
-- Markdown math helpers (regex-based, since treesitter doesn't wrap $...$)
-- =============================================================================

--- Find the inline math $...$ enclosing col on line.
--- Returns (open_col, close_col) as 0-indexed byte positions of the `$` chars,
--- or nil if cursor is not inside inline math.
local function find_inline_math(line, col)
  -- Collect positions of unescaped single $ (not $$)
  local dollars = {}
  local i = 1
  while i <= #line do
    if line:sub(i, i) == "$" then
      -- Skip escaped \$
      if i > 1 and line:sub(i - 1, i - 1) == "\\" then
        i = i + 1
      -- Check for $$ (display math delimiter) — skip the pair
      elseif line:sub(i, i + 1) == "$$" then
        i = i + 2
      else
        dollars[#dollars + 1] = i - 1 -- 0-indexed
        i = i + 1
      end
    else
      i = i + 1
    end
  end

  -- Pair them up and find which pair contains col
  for j = 1, #dollars - 1, 2 do
    local open, close = dollars[j], dollars[j + 1]
    if col > open and col < close then
      return open, close
    end
  end
  return nil
end

--- Find display math $$...$$ block enclosing the cursor row (0-indexed).
--- Returns (open_row, close_row) as 0-indexed line numbers of the $$ lines,
--- or nil if cursor is not inside display math.
local function find_display_math(row)
  local total = vim.api.nvim_buf_line_count(0)
  -- Search upward for opening $$
  local open_row
  for r = row, 0, -1 do
    local l = vim.api.nvim_buf_get_lines(0, r, r + 1, false)[1] or ""
    if l:match("^%s*%$%$$") then
      open_row = r
      break
    end
  end
  if not open_row then
    return nil
  end
  -- Search downward for closing $$
  local start = (open_row == row) and row + 1 or row
  for r = start, total - 1 do
    local l = vim.api.nvim_buf_get_lines(0, r, r + 1, false)[1] or ""
    if l:match("^%s*%$%$$") then
      return open_row, r
    end
  end
  return nil
end

--- Collect all math zone positions in the buffer for ]m/[m motions.
--- Returns list of {row, col} (0-indexed) sorted by position.
local function collect_math_positions_md()
  local total = vim.api.nvim_buf_line_count(0)
  local positions = {}
  for r = 0, total - 1 do
    local line = vim.api.nvim_buf_get_lines(0, r, r + 1, false)[1] or ""
    -- Display math $$
    if line:match("^%s*%$%$$") then
      positions[#positions + 1] = { r, 0 }
    else
      -- Inline math $...$
      local i = 1
      while i <= #line do
        if line:sub(i, i) == "$" then
          if i > 1 and line:sub(i - 1, i - 1) == "\\" then
            i = i + 1
          elseif line:sub(i, i + 1) == "$$" then
            i = i + 2
          else
            positions[#positions + 1] = { r, i - 1 }
            i = i + 1
          end
        else
          i = i + 1
        end
      end
    end
  end
  return positions
end

function M.around_math_md()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1
  local line = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1] or ""

  -- Try inline math first
  local open, close = find_inline_math(line, col)
  if open and close then
    select_range(row, open, row, close)
    return
  end

  -- Try display math
  local open_row, close_row = find_display_math(row)
  if open_row and close_row then
    local close_line = vim.api.nvim_buf_get_lines(0, close_row, close_row + 1, false)[1] or ""
    select_range(open_row, 0, close_row, #close_line - 1)
    return
  end
end

function M.inside_math_md()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1
  local line = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1] or ""

  -- Try inline math first
  local open, close = find_inline_math(line, col)
  if open and close then
    if open + 1 <= close - 1 then
      select_range(row, open + 1, row, close - 1)
    end
    return
  end

  -- Try display math
  local open_row, close_row = find_display_math(row)
  if open_row and close_row then
    local isr, isc = open_row + 1, 0
    local ier = close_row - 1
    if ier >= isr then
      local prev = vim.api.nvim_buf_get_lines(0, ier, ier + 1, false)[1] or ""
      select_range(isr, isc, ier, math.max(0, #prev - 1))
    end
    return
  end
end

function M.next_math_md()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1
  local positions = collect_math_positions_md()
  local count = vim.v.count1
  local found = 0
  for _, pos in ipairs(positions) do
    if pos[1] > row or (pos[1] == row and pos[2] > col) then
      found = found + 1
      if found == count then
        vim.api.nvim_win_set_cursor(0, { pos[1] + 1, pos[2] })
        return
      end
    end
  end
end

function M.prev_math_md()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1
  local positions = collect_math_positions_md()
  local count = vim.v.count1
  local found = 0
  for i = #positions, 1, -1 do
    local pos = positions[i]
    if pos[1] < row or (pos[1] == row and pos[2] < col) then
      found = found + 1
      if found == count then
        vim.api.nvim_win_set_cursor(0, { pos[1] + 1, pos[2] })
        return
      end
    end
  end
end

-- =============================================================================
-- Setup: register buffer-local keymaps
-- =============================================================================

function M.setup()
  local function map(modes, lhs, rhs, desc)
    vim.keymap.set(modes, lhs, rhs, { buffer = true, desc = desc })
  end

  -- Motions (normal, visual, operator-pending)
  map({ "n", "x", "o" }, "]]", function()
    M.next_node(section_types)
  end, "Next section")
  map({ "n", "x", "o" }, "[[", function()
    M.prev_node(section_types)
  end, "Previous section")
  map({ "n", "x", "o" }, "]e", function()
    M.next_node(env_types)
  end, "Next environment")
  map({ "n", "x", "o" }, "[e", function()
    M.prev_node(env_types)
  end, "Previous environment")
  map({ "n", "x", "o" }, "]m", function()
    M.next_node(math_types)
  end, "Next math zone")
  map({ "n", "x", "o" }, "[m", function()
    M.prev_node(math_types)
  end, "Previous math zone")

  -- Text objects (visual, operator-pending)
  map({ "x", "o" }, "ae", M.around_env, "Around environment")
  map({ "x", "o" }, "ie", M.inside_env, "Inside environment")
  map({ "x", "o" }, "am", M.around_math, "Around math zone")
  map({ "x", "o" }, "im", M.inside_math, "Inside math zone")
  map({ "x", "o" }, "ac", M.around_cmd, "Around command")
  map({ "x", "o" }, "ic", M.inside_cmd, "Inside command")
end

function M.setup_markdown()
  local function map(modes, lhs, rhs, desc)
    vim.keymap.set(modes, lhs, rhs, { buffer = true, desc = desc })
  end

  -- Math motions
  map({ "n", "x", "o" }, "]m", M.next_math_md, "Next math zone")
  map({ "n", "x", "o" }, "[m", M.prev_math_md, "Previous math zone")

  -- Math text objects
  map({ "x", "o" }, "am", M.around_math_md, "Around math zone")
  map({ "x", "o" }, "im", M.inside_math_md, "Inside math zone")
end

return M
