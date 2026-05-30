local engine = require("andrew.vault.engine")
local vault_index = require("andrew.vault.vault_index")
local link_utils = require("andrew.vault.link_utils")
local link_scan = require("andrew.vault.link_scan")
local config = require("andrew.vault.config")
local notify = require("andrew.vault.notify")

local rg_pipeline = require("andrew.vault.unlinked.rg_pipeline")
local names = require("andrew.vault.unlinked.names")
local ui = require("andrew.vault.unlinked.ui")
local utils = require("andrew.vault.unlinked.utils")

local M = {}

-- ---------------------------------------------------------------------------
-- Shared vault-wide scan helper
-- ---------------------------------------------------------------------------

--- Scan the entire vault for unlinked mentions using batched ripgrep.
---@param on_results fun(results: table[])
local function scan_vault_mentions(on_results)
  local all_names = names.all_note_names()
  if #all_names == 0 then
    notify.warn("no notes found in vault")
    return
  end

  local batches = utils.batch_list(all_names, config.autolink.batch.max_pattern_names)

  local all_results = {}
  local pending = #batches

  for _, batch in ipairs(batches) do
    local batch_names = {}
    for _, entry in ipairs(batch) do
      batch_names[#batch_names + 1] = entry.name
    end

    rg_pipeline.rg_search(batch_names, nil, function(raw_results)
      local non_self = rg_pipeline.filter_self_mentions(raw_results, batch)
      local filtered = rg_pipeline.filter_results(non_self, batch_names)
      for _, r in ipairs(filtered) do
        all_results[#all_results + 1] = r
      end

      pending = pending - 1
      if pending == 0 then
        on_results(all_results)
      end
    end)
  end
end

--- Scan vault and open a picker with results.
---@param empty_msg string message when no results found
---@param build_opts fun(results: table[]): table builds picker_opts from results
local function scan_and_pick(empty_msg, build_opts)
  scan_vault_mentions(function(all_results)
    if #all_results == 0 then
      notify.info(empty_msg)
      return
    end
    local entries, entry_map = ui.build_vault_entries(all_results)
    ui.open_vault_picker(entries, entry_map, build_opts(all_results))
  end)
end

-- ---------------------------------------------------------------------------
-- Buffer-level batch auto-link scanning
-- ---------------------------------------------------------------------------

--- Scan the current buffer in-memory for unlinked mentions of vault note names.
---@param bufnr number
---@return table[]
local function scan_buffer_mentions(bufnr)
  if not engine.is_vault_buf(bufnr) then return {} end

  local raw_matches = link_scan.scan_buffer_names(bufnr, {
    min_name_length = config.autolink.min_name_length,
  })
  if #raw_matches == 0 then return {} end

  local idx = vault_index.current()
  local paths_map = idx and idx:is_ready() and idx:get_name_cache().paths or {}

  local matches = {}
  for _, m in ipairs(raw_matches) do
    local display = m.note_name
    if paths_map[m.note_name] then
      display = link_utils.get_basename(paths_map[m.note_name])
    end
    matches[#matches + 1] = {
      row = m.row,
      start_col = m.start_col,
      end_col = m.end_col,
      text = m.text,
      note_name = m.note_name,
      canonical = display,
    }
  end

  return matches
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Auto-link unlinked mentions in the current buffer via fzf-lua picker.
function M.autolink_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  if not engine.is_vault_buf(bufnr) then
    notify.not_vault_file()
    return
  end

  local buffer_matches = scan_buffer_mentions(bufnr)
  if #buffer_matches == 0 then
    notify.info("no unlinked mentions found in buffer")
    return
  end

  ui.open_buffer_picker(bufnr, buffer_matches)
end

--- Auto-link unlinked mentions across the entire vault via fzf-lua picker.
function M.autolink_vault()
  notify.info("scanning vault for auto-linkable mentions...")

  scan_and_pick("no auto-linkable mentions found", function(results)
    return {
      prompt = "Auto-link vault (" .. #results .. " mentions)> ",
      multi = true,
      all_results = results,
    }
  end)
end

--- Show unlinked mentions for the current note via fzf-lua.
function M.unlinked_mentions()
  local info = names.current_note_names()
  if not info then
    notify.not_vault_file()
    return
  end

  local search_names = utils.filter_by_min_length(info.names)

  if #search_names == 0 then
    notify.warn("note name too short for unlinked mention search")
    return
  end

  notify.info("scanning for unlinked mentions...")

  rg_pipeline.rg_search(search_names, info.path, function(raw_results)
    local results = rg_pipeline.filter_results(raw_results, search_names)

    if #results == 0 then
      notify.info("no unlinked mentions found for " .. search_names[1])
      return
    end

    local entries, entry_map = ui.build_vault_entries(results, { include_match = false, sort = false })

    ui.open_vault_picker(entries, entry_map, {
      prompt = "Unlinked mentions (" .. search_names[1] .. ")> ",
      all_results = results,
      with_wikilinks = true,
    })
  end)
end

--- Show all unlinked mentions across the entire vault.
function M.vault_unlinked_mentions()
  notify.info("building unlinked mentions index (this may take a moment)...")

  scan_and_pick("no unlinked mentions found", function(results)
    return {
      prompt = "Vault unlinked mentions (" .. #results .. ")> ",
    }
  end)
end

-- ---------------------------------------------------------------------------
return M
