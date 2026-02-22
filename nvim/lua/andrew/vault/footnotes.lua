local M = {}

--- Find the footnote identifier under or near the cursor.
---@return string|nil footnote id (without [^ and ])
local function get_footnote_at_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1

  -- Search for [^...] patterns on the current line
  local start = 1
  while true do
    local s, e, id = line:find("%[%^([%w_-]+)%]", start)
    if not s then return nil end
    if col >= s and col <= e then
      return id
    end
    start = e + 1
  end
end

--- Jump between footnote reference and definition.
--- If on a definition `[^id]:`, jump to first reference `[^id]`.
--- If on a reference `[^id]`, jump to the definition `[^id]:`.
function M.jump()
  local id = get_footnote_at_cursor()
  if not id then
    vim.notify("No footnote under cursor", vim.log.levels.INFO)
    return
  end

  local line = vim.api.nvim_get_current_line()
  local is_definition = line:match("^%[%^" .. vim.pesc(id) .. "%]:")

  local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

  if is_definition then
    -- Jump to first reference (not a definition)
    local pattern = "%[%^" .. vim.pesc(id) .. "%]"
    for i, l in ipairs(buf_lines) do
      if not l:match("^%[%^" .. vim.pesc(id) .. "%]:") then
        local s = l:find(pattern)
        if s then
          vim.api.nvim_win_set_cursor(0, { i, s - 1 })
          return
        end
      end
    end
    vim.notify("No reference found for [^" .. id .. "]", vim.log.levels.INFO)
  else
    -- Jump to definition
    local pattern = "^%[%^" .. vim.pesc(id) .. "%]:"
    for i, l in ipairs(buf_lines) do
      if l:match(pattern) then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
    vim.notify("No definition found for [^" .. id .. "]", vim.log.levels.INFO)
  end
end

--- List all footnotes in current buffer via fzf-lua.
function M.list()
  local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local footnotes = {}
  local seen = {}

  for i, line in ipairs(buf_lines) do
    for id in line:gmatch("%[%^([%w_-]+)%]") do
      if not seen[id] then
        seen[id] = true
        -- Check if definition exists
        local has_def = false
        for _, l in ipairs(buf_lines) do
          if l:match("^%[%^" .. vim.pesc(id) .. "%]:") then
            has_def = true
            break
          end
        end
        footnotes[#footnotes + 1] = string.format(
          "%d: [^%s] %s",
          i,
          id,
          has_def and "" or "(no definition)"
        )
      end
    end
  end

  if #footnotes == 0 then
    vim.notify("No footnotes in buffer", vim.log.levels.INFO)
    return
  end

  local fzf = require("fzf-lua")
  fzf.fzf_exec(footnotes, {
    prompt = "Footnotes> ",
    actions = {
      ["default"] = function(selected)
        if selected[1] then
          local lnum = tonumber(selected[1]:match("^(%d+):"))
          if lnum then
            vim.api.nvim_win_set_cursor(0, { lnum, 0 })
          end
        end
      end,
    },
  })
end

function M.setup()
  local group = vim.api.nvim_create_augroup("VaultFootnotes", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "<leader>mj", function()
        M.jump()
      end, { buffer = ev.buf, desc = "Footnote: jump ref/def", silent = true })

      vim.keymap.set("n", "<leader>mn", function()
        M.list()
      end, { buffer = ev.buf, desc = "Footnote: list all", silent = true })
    end,
  })
end

return M
