local engine = require("andrew.vault.engine")
local fm_parser = require("andrew.vault.frontmatter_parser")
local link_utils = require("andrew.vault.link_utils")
local pat = require("andrew.vault.patterns")

local M = {}

---@param raw string e.g. `"[[Projects/Foo/Dashboard|Foo]]"` or `"Projects/Foo|Foo"`
---@return string display name
local function wikilink_name(raw)
  if raw == nil then return "" end
  raw = tostring(raw)
  -- Handle raw wikilink with brackets
  if raw:find(pat.HAS_WIKILINK) then return link_utils.wikilink_display_name(raw) end
  -- Handle parsed wikilink without brackets: "target|alias" or "target"
  local pipe_pos = raw:find("|")
  if pipe_pos then return vim.trim(raw:sub(pipe_pos + 1)) end
  -- Bare name: extract last path component
  local basename = link_utils.get_tail(raw)
  return vim.trim(basename or raw:gsub('["%[%]]', ""))
end

---@param bufnr number
---@return string[]|nil segments
local function build_segments(bufnr)
  local bufpath = vim.api.nvim_buf_get_name(bufnr)
  if bufpath == "" then return nil end

  local parts = engine.vault_path_segments(bufpath)
  if not parts or #parts == 0 then return nil end

  local note_name = link_utils.rel_to_stem(parts[#parts])

  -- Frontmatter parent-project override
  local pp = fm_parser.buf_field(bufnr, "parent-project")
  if pp then
    return { "Vault", wikilink_name(pp), note_name }
  end

  -- Default: vault root + note name only
  return { "Vault", note_name }
end

-- Lookup table for click targets (indexed by minwid)
M._click_targets = {}

function _G._vault_breadcrumb_click(minwid)
  local target = M._click_targets[minwid]
  if not target then return end
  local dash = target .. "/Dashboard.md"
  if vim.fn.filereadable(dash) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(dash))
  else
    local ok, fzf = pcall(require, "fzf-lua")
    if ok then fzf.files({ cwd = target }) end
  end
end

---@param segments string[]
---@return string winbar
local function format_winbar(segments)
  local sep = "%#VaultBreadcrumbSep# › "

  M._click_targets = {}
  local out = {}
  for i, s in ipairs(segments) do
    if i == #segments then
      out[#out + 1] = "%#VaultBreadcrumbCurrent#" .. s
    else
      -- Store absolute dir path in lookup table, use minwid to reference it
      local dir_parts = {}
      for j = 2, i do dir_parts[#dir_parts + 1] = segments[j] end
      local dir_path = engine.vault_path
      if #dir_parts > 0 then dir_path = dir_path .. "/" .. table.concat(dir_parts, "/") end
      M._click_targets[i] = dir_path
      out[#out + 1] = "%#VaultBreadcrumbItem#%" .. i .. "@v:lua._vault_breadcrumb_click@" .. s .. "%X"
    end
    if i < #segments then out[#out + 1] = sep end
  end
  return table.concat(out)
end

---@param bufnr number
---@return string|nil
function M.compute_breadcrumb(bufnr)
  local segments = build_segments(bufnr)
  if not segments then return nil end
  return format_winbar(segments)
end

--- True if `win` can carry a winbar without stealing its last text row.
--- Floats and one-row windows cannot: setting 'winbar' on them emits
--- "E36: Not enough room" (echoed via emsg, so it never raises).
---@param win number
---@return boolean
local function can_show_winbar(win)
  if not vim.api.nvim_win_is_valid(win) then return false end
  if vim.api.nvim_win_get_config(win).relative ~= "" then return false end
  return vim.api.nvim_win_get_height(win) > 1
end

--- Apply a winbar to every window displaying `bufnr`.
--- Targets those windows explicitly rather than using `vim.wo` (the *current*
--- window). BufEnter is coalesced (config.events.buf_enter_coalesce_ms), so by the
--- time this runs the current window can be an unrelated 1-row vim.ui.input
--- float while `bufnr` is still the markdown buffer.
---@param bufnr number
---@param trail string
local function apply_winbar(bufnr, trail)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if can_show_winbar(win) then
      pcall(vim.api.nvim_set_option_value, "winbar", trail, { win = win })
    end
  end
end

---@param args table autocmd callback args
function M.update(args)
  local bufnr = args.buf
  if vim.bo[bufnr].buftype ~= "" then return end
  local trail = M.compute_breadcrumb(bufnr)
  apply_winbar(bufnr, trail or "")
end

M.can_show_winbar = can_show_winbar

function M.setup()
  vim.api.nvim_set_hl(0, "VaultBreadcrumbItem", { link = "Directory" })
  vim.api.nvim_set_hl(0, "VaultBreadcrumbCurrent", { bold = true, link = "Title" })
  vim.api.nvim_set_hl(0, "VaultBreadcrumbSep", { link = "NonText" })
  -- BufEnter/BufWritePost autocmds dispatched via event_dispatch.lua
end

--- Called by event_dispatch.lua on BufWritePost for vault markdown buffers.
--- @param ctx { bufnr: number, file: string }
function M.on_buf_write(ctx)
  M.update({ buf = ctx.bufnr })
end

--- Called by event_dispatch.lua on BufEnter for vault markdown buffers.
--- @param ctx { bufnr: number, file: string, is_vault_md: boolean }
function M.on_buf_enter(ctx)
  M.update({ buf = ctx.bufnr })
end

--- Called by event_dispatch.lua on BufEnter for non-vault buffers.
--- @param ctx { bufnr: number, file: string, is_vault_md: boolean }
function M.on_buf_enter_non_vault(ctx)
  if vim.bo[ctx.bufnr].buftype ~= "" then return end
  apply_winbar(ctx.bufnr, "")
end

return M
