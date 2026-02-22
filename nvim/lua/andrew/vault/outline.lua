local M = {}

function M.outline()
  local buf = vim.api.nvim_get_current_buf()
  local bufname = vim.api.nvim_buf_get_name(buf)
  if bufname == "" then
    vim.notify("Vault: buffer has no filename", vim.log.levels.WARN)
    return
  end

  local parser = vim.treesitter.get_parser(buf, "markdown")
  if not parser then
    vim.notify("Vault: treesitter markdown parser not available", vim.log.levels.WARN)
    return
  end

  local tree = parser:parse()[1]
  if not tree then return end

  local query = vim.treesitter.query.parse("markdown", "(atx_heading) @heading")
  local entries = {}

  local raw = {}
  local max_left = 0
  local max_lnum = 0

  for _, node in query:iter_captures(tree:root(), buf) do
    local start_row = node:range()
    local line = vim.api.nvim_buf_get_lines(buf, start_row, start_row + 1, false)[1] or ""
    local hashes, text = line:match("^(#+)%s+(.*)")
    local level = hashes and #hashes or 1
    text = text or line
    local indent = string.rep("  ", level - 1)
    local left = indent .. text .. " "
    raw[#raw + 1] = { row = start_row + 1, left = left }
    if #left > max_left then max_left = #left end
    if start_row + 1 > max_lnum then max_lnum = start_row + 1 end
  end

  local lnum_width = #tostring(max_lnum)
  local width = max_left + 4 + lnum_width

  for _, h in ipairs(raw) do
    local right = " " .. string.format("%" .. lnum_width .. "d", h.row)
    local dots_needed = width - #h.left - #right
    if dots_needed < 2 then dots_needed = 2 end
    local display = h.left .. string.rep("·", dots_needed) .. right
    entries[#entries + 1] = string.format("%s:%d:1:%s", bufname, h.row, display)
  end

  if #entries == 0 then
    vim.notify("Vault: no headings found", vim.log.levels.INFO)
    return
  end

  local fzf = require("fzf-lua")
  fzf.fzf_exec(entries, {
    prompt = "Outline> ",
    previewer = "builtin",
    fzf_opts = {
      ["--no-multi"] = "",
      ["--delimiter"] = ":",
      ["--with-nth"] = "4..",
    },
    actions = {
      ["default"] = function(selected)
        if selected[1] then
          local lnum = tonumber(selected[1]:match("^[^:]+:(%d+):"))
          if lnum then
            vim.api.nvim_win_set_cursor(0, { lnum, 0 })
            vim.cmd("normal! zz")
          end
        end
      end,
    },
  })
end

function M.setup()
  vim.api.nvim_create_user_command("VaultOutline", function()
    M.outline()
  end, { desc = "Show heading outline for current markdown buffer" })

  local group = vim.api.nvim_create_augroup("VaultOutline", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "<leader>vfo", function()
        M.outline()
      end, { buffer = ev.buf, desc = "Find: outline", silent = true })
    end,
  })
end

return M
