local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local fm_parser = require("andrew.vault.frontmatter_parser")
local cleanup = require("andrew.vault.resource_cleanup")
local notify = require("andrew.vault.notify")
local link_utils = require("andrew.vault.link_utils")

local M = {}
M.auto_file = false

local d = config.dirs

M.type_map = {
  ["log"] = d.log,                     ["journal"] = d.log .. "/journal",
  ["task"] = d.log .. "/tasks",        ["literature"] = d.library,
  ["methodology"] = d.methods,         ["person"] = d.people,
  ["meeting"] = d.log,                 ["simulation"] = d.log,
  ["analysis"] = d.log,                ["finding"] = d.log,
  ["concept"] = d.domains,             ["domain-moc"] = d.domains,
  ["project-dashboard"] = d.projects,  ["area-dashboard"] = d.areas,
}

local project_types = { task = true, meeting = true, simulation = true, analysis = true, finding = true, ["project-dashboard"] = true }

function M.get_expected_dir(note_type, fm)
  local base = M.type_map[note_type]
  if not base then return nil end

  local project = fm["parent-project"] and link_utils.wikilink_display_name(tostring(fm["parent-project"]))
  if project and project ~= "" and project_types[note_type] then
    if note_type == "task" then
      return config.dirs.projects .. "/" .. project .. "/tasks"
    end
    return config.dirs.projects .. "/" .. project
  end

  local domain = fm["domain"] and link_utils.wikilink_display_name(tostring(fm["domain"]))
  if domain and domain ~= "" and (note_type == "concept" or note_type == "domain-moc") then
    return config.dirs.domains .. "/" .. domain
  end

  local area = fm["area"] and link_utils.wikilink_display_name(tostring(fm["area"]))
  if area and area ~= "" and note_type == "area-dashboard" then
    return config.dirs.areas .. "/" .. area
  end

  return base
end

local function already_correct(filepath, expected_dir)
  local expected_abs = engine.vault_path .. "/" .. expected_dir
  return vim.startswith(link_utils.lua_dirname(filepath), expected_abs)
end

-- in_vault removed: use engine.is_vault_path() directly

function M.move(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if not engine.is_vault_buf(bufnr) then return end

  local result = fm_parser.parse_buffer_cached(bufnr)
  local fm = result and result.fields or {}
  local expected = fm["type"] and M.get_expected_dir(fm["type"], fm)
  if not expected then return end
  if already_correct(filepath, expected) then
    notify.info("already in correct directory")
    return
  end

  local dest_dir = engine.vault_path .. "/" .. expected
  local dest = dest_dir .. "/" .. link_utils.get_tail(filepath)

  if vim.fn.filereadable(dest) == 1 then
    notify.warn("destination already exists: " .. dest)
    return
  end

  engine.ensure_dir(dest_dir)
  if vim.fn.rename(filepath, dest) ~= 0 then
    notify.error("failed to move file")
    return
  end

  vim.cmd("edit " .. vim.fn.fnameescape(dest))
  local old_buf = vim.fn.bufnr(filepath)
  if old_buf ~= -1 and old_buf ~= vim.api.nvim_get_current_buf() then
    cleanup.delete_buf(old_buf)
  end
  notify.info("moved " .. filepath .. " -> " .. dest)
end

function M.suggest(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if not engine.is_vault_buf(bufnr) then return end

  local result = fm_parser.parse_buffer_cached(bufnr)
  local fm = result and result.fields or {}
  local expected = fm["type"] and M.get_expected_dir(fm["type"], fm)
  if not expected then return end
  if already_correct(filepath, expected) then return end

  local dest = expected .. "/" .. link_utils.get_tail(filepath)
  engine.run(function()
    local answer = engine.input({ prompt = "Move to " .. dest .. "? (y/n): " })
    if answer and answer:lower() == "y" then M.move(bufnr) end
  end)
end

function M.setup()
  local palette = require("andrew.vault.command_palette")

  -- BufWritePost dispatched via event_dispatch.lua

  vim.api.nvim_create_user_command("VaultAutoFile", function()
    M.suggest()
  end, { desc = "Suggest moving current note to its expected directory" })

  vim.api.nvim_create_user_command("VaultAutoFileMove", function()
    M.move()
  end, { desc = "Force-move current note to its expected directory" })

  vim.keymap.set("n", "<leader>vmv", function()
    M.suggest()
  end, { desc = "Vault: auto-file suggestion", silent = true })

  -- Palette registrations
  palette.register_command("VaultAutoFile", "Suggest moving current note to its expected directory", "Meta", function()
    M.suggest()
  end, "<leader>vmv")
  palette.register_command("VaultAutoFileMove", "Force-move current note to its expected directory", "Meta", function()
    M.move()
  end)
end

--- Called by event_dispatch.lua on BufWritePost for vault markdown buffers.
--- @param ctx { bufnr: number, file: string }
function M.on_buf_write(ctx)
  M.suggest(ctx.bufnr)
end

return M
