local config = require("andrew.vault.config")
local hl_coord = require("andrew.vault.highlight_coordinator")

local M = {}

M.enabled = config.tag_highlights.enabled
M.ns = vim.api.nvim_create_namespace("vault_tag_hl")

local _nav_cache = {}

-- ---------------------------------------------------------------------------
-- Tag pattern (matches tags.lua ripgrep pattern)
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Highlight groups
-- ---------------------------------------------------------------------------

--- Category prefix -> highlight group mapping.
--- Order matters: first match wins (most specific prefix first).
local default_categories = {
  { prefix = "project/", highlight = "VaultTagProject" },
  { prefix = "status/", highlight = "VaultTagStatus" },
  { prefix = "type/", highlight = "VaultTagType" },
  { prefix = "person/", highlight = "VaultTagPerson" },
}

--- Find the category that matches a tag based on its prefix.
---@param tag string the tag text (without #)
---@return table|nil category the matching category ({ prefix, highlight }) or nil
function M.find_tag_category(tag)
  local categories = config.tag_highlights.categories or default_categories
  local lower = tag:lower()
  for _, cat in ipairs(categories) do
    if lower:sub(1, #cat.prefix) == cat.prefix then
      return cat
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Toggle
-- ---------------------------------------------------------------------------

M.toggle = hl_coord.make_toggle(M, "tag highlights")

-- ---------------------------------------------------------------------------
-- Tag navigation (via factory)
-- ---------------------------------------------------------------------------

--- Pipeline-aware tag scanner for navigation. Reads from the pipeline parse
--- cache when warm; returns nothing if cache is not available (no legacy
--- fallback).
local function scan_tags_pipeline_aware(_lines, _start_line, _code_excl, _fm_start, _fm_end, callback)
  local parse_cache = require("andrew.vault.line_parse_cache")
  local bufnr = vim.api.nvim_get_current_buf()
  local iter = parse_cache.pipeline_token_iter(bufnr, "tag")
  if not iter then return end
  for line_nr, token in iter do
    -- token.start_col is 0-indexed; callback expects 1-indexed hash_pos
    callback(line_nr, token.start_col + 1, token.captures[1])
  end
end

local jump_tag = hl_coord.make_scan_nav(_nav_cache, scan_tags_pipeline_aware, function(row, hash_pos, _tag)
  return row + 1, hash_pos
end)

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  local palette = require("andrew.vault.command_palette")
  local group = vim.api.nvim_create_augroup("VaultTagHL", { clear = true })

  hl_coord.setup_buf_cleanup(group, M.ns, { _nav_cache })

  -- Commands
  vim.api.nvim_create_user_command("VaultTagHLToggle", function()
    M.toggle()
  end, { desc = "Toggle inline tag highlighting" })

  hl_coord.make_refresh_command("VaultTagHLRefresh", "Refresh tag highlights in current buffer")

  -- FileType autocmd removed: now dispatched via event_dispatch.lua

  -- Palette registrations
  palette.register_command("VaultTagHLToggle", "Toggle inline tag highlighting", "Debug", function()
    M.toggle()
  end, "<leader>vgt")
  palette.register_command("VaultTagHLRefresh", "Refresh tag highlights in current buffer", "Debug", function()
    vim.cmd("VaultTagHLRefresh")
  end)
  palette.register_keymap("]t", "Next inline tag", "Debug", function()
    jump_tag(1)
  end, true)
  palette.register_keymap("[t", "Previous inline tag", "Debug", function()
    jump_tag(-1)
  end, true)

end

--- Called by event_dispatch.lua on FileType markdown.
--- @param ev table autocmd event args
function M.on_ft_markdown(ev)
  vim.keymap.set("n", "<leader>vgt", function()
    M.toggle()
  end, {
    buffer = ev.buf,
    desc = "Tags: highlights toggle",
    silent = true,
  })
  hl_coord.register_nav_keymaps(ev, jump_tag, "]t", "[t", "Next inline tag", "Previous inline tag")
end

return M
