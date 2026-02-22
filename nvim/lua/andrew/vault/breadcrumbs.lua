local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")

local M = {}

---@param bufnr number
---@param field string
---@return string|nil
local function buf_frontmatter(bufnr, field)
  local n = math.min(vim.api.nvim_buf_line_count(bufnr), config.frontmatter.max_scan_lines)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, n, false)
  if #lines == 0 or lines[1] ~= "---" then return nil end
  for i = 2, #lines do
    if lines[i] == "---" then return nil end
    local k, v = lines[i]:match("^(%S+):%s*(.+)$")
    if k == field then return v end
  end
end

---@param raw string e.g. `"[[Projects/Foo/Dashboard|Foo]]"`
---@return string display name
local function wikilink_name(raw)
  local alias = raw:match("|([^%]]+)%]%]")
  if alias then return vim.trim(alias) end
  local target = raw:match("%[%[([^|%]]+)%]%]")
  if target then return target:match("([^/]+)$") or target end
  return vim.trim(raw:gsub('["%[%]]', ""))
end

---@param bufnr number
---@return string[]|nil segments
local function build_segments(bufnr)
  local bufpath = vim.api.nvim_buf_get_name(bufnr)
  if bufpath == "" then return nil end
  local vp = engine.vault_path
  if bufpath:sub(1, #vp) ~= vp then return nil end

  local rel = bufpath:sub(#vp + 2):gsub("%.md$", "")
  local parts = {}
  for seg in rel:gmatch("[^/]+") do parts[#parts + 1] = seg end
  if #parts == 0 then return nil end

  local note_name = parts[#parts]

  -- Frontmatter parent-project override
  local pp = buf_frontmatter(bufnr, "parent-project")
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

---@param args table autocmd callback args
function M.update(args)
  local bufnr = args.buf
  if vim.bo[bufnr].buftype ~= "" then return end
  local trail = M.compute_breadcrumb(bufnr)
  vim.wo.winbar = trail or ""
end

function M.setup()
  vim.api.nvim_set_hl(0, "VaultBreadcrumbItem", { link = "Directory" })
  vim.api.nvim_set_hl(0, "VaultBreadcrumbCurrent", { bold = true, link = "Title" })
  vim.api.nvim_set_hl(0, "VaultBreadcrumbSep", { link = "NonText" })

  local group = vim.api.nvim_create_augroup("VaultBreadcrumbs", { clear = true })

  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
    group = group,
    pattern = "*.md",
    callback = M.update,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev)
      if vim.bo[ev.buf].buftype ~= "" then return end
      local name = vim.api.nvim_buf_get_name(ev.buf)
      if name == "" or not vim.endswith(name, ".md")
        or name:sub(1, #engine.vault_path) ~= engine.vault_path then
        vim.wo.winbar = ""
      end
    end,
  })
end

return M
