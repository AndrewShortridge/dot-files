local M = {}
local notify = require("andrew.vault.notify")
local pat = require("andrew.vault.patterns")

function M.outline()
  local buf = vim.api.nvim_get_current_buf()
  local bufname = vim.api.nvim_buf_get_name(buf)
  if bufname == "" then
    notify.no_filename()
    return
  end

  local parser = vim.treesitter.get_parser(buf, "markdown")
  if not parser then
    notify.warn("treesitter markdown parser not available")
    return
  end

  local tree = parser:parse()[1]
  if not tree then return end

  local query = vim.treesitter.query.parse("markdown", "(atx_heading) @heading")
  local entries = {}

  -- Single-pass: bulk fetch all lines, collect headings and compute widths together
  local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local raw = {}
  local max_left_len = 0
  local max_lnum = 0

  for _, node in query:iter_captures(tree:root(), buf) do
    local start_row = node:range()
    local row = start_row + 1
    local line = all_lines[row] or ""
    local hashes, text = line:match(pat.HEADING)
    local level = hashes and #hashes or 1
    text = text or line
    local indent = string.rep("  ", level - 1)
    local left = indent .. text .. " "
    local left_len = #left
    raw[#raw + 1] = { row = row, left = left, left_len = left_len }
    if left_len > max_left_len then max_left_len = left_len end
    if row > max_lnum then max_lnum = row end
  end

  -- Build display strings (requires max_left_len and max_lnum from above)
  local lnum_fmt = "%" .. #tostring(max_lnum) .. "d"
  local total_width = max_left_len + 4 + #tostring(max_lnum)

  for _, h in ipairs(raw) do
    local right = " " .. string.format(lnum_fmt, h.row)
    local dots_needed = total_width - h.left_len - #right
    if dots_needed < 2 then dots_needed = 2 end
    local display = h.left .. string.rep("·", dots_needed) .. right
    entries[#entries + 1] = string.format("%s:%d:1:%s", bufname, h.row, display)
  end

  if #entries == 0 then
    notify.info("no headings found")
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

--- Called by event_dispatch.lua on FileType markdown.
--- @param ev table autocmd event args
function M.on_ft_markdown(ev)
  vim.keymap.set("n", "<leader>vfo", function()
    M.outline()
  end, { buffer = ev.buf, desc = "Find: outline", silent = true })
end

function M.setup()
  vim.api.nvim_create_user_command("VaultOutline", function()
    M.outline()
  end, { desc = "Show heading outline for current markdown buffer" })

  -- FileType autocmd removed: now dispatched via event_dispatch.lua

  -- Palette registrations
  local palette = require("andrew.vault.command_palette")

  palette.register_command("VaultOutline", "Show heading outline for current markdown buffer", "Navigate", M.outline, "<leader>vfo")
end

return M
