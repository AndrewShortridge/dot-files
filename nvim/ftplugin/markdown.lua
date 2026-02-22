local opt_local = vim.opt_local

opt_local.spell = true
opt_local.spelllang = "en_us"
opt_local.conceallevel = 2

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

map("<Tab>", "za", "Toggle fold")
map("<leader>mf", "zM", "Fold all")
map("<leader>mu", "zR", "Unfold all")
map("<leader>ml", function()
  local level = vim.fn.input("Fold level: ")
  level = tonumber(level)
  if level then
    vim.opt_local.foldlevel = level
  end
end, "Set fold level")

-- Cycle checkbox states from vault config
local vault_config = require("andrew.vault.config")
local checkbox_cycle = {}
for _, state in ipairs(vault_config.task_states) do
  checkbox_cycle[#checkbox_cycle + 1] = state.mark
end
local checkbox_next = {}
for i, v in ipairs(checkbox_cycle) do
  checkbox_next[v] = checkbox_cycle[i % #checkbox_cycle + 1]
end

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

map("<leader>mx", function()
  local line = vim.api.nvim_get_current_line()
  local prefix, mark, rest = line:match("^(.*%- %[)(.)(%].*)$")
  if not prefix then
    return
  end
  local next_mark = checkbox_next[mark] or " "
  -- Add completion date when cycling to [x], remove when cycling away
  if next_mark == "x" then
    rest = rest:gsub("%s*%[completion::[^%]]*%]", "")
    rest = rest .. " [completion:: " .. os.date("%Y-%m-%d") .. "]"
  elseif mark == "x" then
    rest = rest:gsub("%s*%[completion::[^%]]*%]", "")
  end
  vim.api.nvim_set_current_line(prefix .. next_mark .. rest)
  if next_mark == "x" then
    local line_nr = vim.api.nvim_win_get_cursor(0)[1]
    require("andrew.vault.recurrence").handle_recurrence(line_nr)
  end
end, "Cycle checkbox")
