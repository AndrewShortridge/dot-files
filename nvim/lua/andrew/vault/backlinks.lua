local engine = require("andrew.vault.engine")
local wikilinks = require("andrew.vault.wikilinks")
local link_utils = require("andrew.vault.link_utils")
local vault_index = require("andrew.vault.vault_index")
local filter_utils = require("andrew.vault.filter_utils")
local string_intern = require("andrew.vault.string_intern")
local file_cache = require("andrew.vault.file_cache")
local notify = require("andrew.vault.notify")
local pat = require("andrew.vault.patterns")

local _lowercase_pool = string_intern.new(5000)

local M = {}

--- Get the current file's rel_path in the vault index.
---@return string|nil rel_path
---@return VaultIndex|nil idx
local function current_file_index_info()
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" then return nil, nil end

  local idx = vault_index.current()
  if not idx or not idx:is_ready() then return nil, nil end

  local entry = idx:get_entry_by_abs(bufname)
  if not entry then return nil, nil end

  return entry.rel_path, idx
end

--- Find lines in pre-read file lines that contain a wikilink to the target name.
---@param lines string[] file lines (already read from disk or cache)
---@param target_name string The note name to search for (case-insensitive)
---@param heading_filter string|nil If set, only match links with this #heading
---@return { lnum: number, text: string }[]
local function find_link_lines_from_cache(lines, target_name, heading_filter)
  local results = {}
  local target_lower = string_intern.intern_lower(_lowercase_pool, target_name)
  local heading_slug = heading_filter and link_utils.heading_to_slug(heading_filter)
  local pattern = link_utils.WIKILINK_PAT

  for lnum, line in ipairs(lines) do
    for inner in line:gmatch(pattern) do
      -- Strip display alias
      local link_path = inner:match("^(.-)%|") or inner
      -- Separate heading/block fragment
      local name_part = string_intern.intern(_lowercase_pool, filter_utils.normalize_link_name(link_path))

      if name_part then
        -- Check if this link targets our note (by basename or full path)
        local name_basename = link_utils.get_tail(name_part)
        local matches = (name_part == target_lower) or (name_basename == target_lower)

        if matches then
          if heading_slug then
            local heading_frag = link_path:match("#(.+)$")
            if heading_frag and link_utils.heading_to_slug(heading_frag) == heading_slug then
              results[#results + 1] = { lnum = lnum, text = line }
            end
          else
            results[#results + 1] = { lnum = lnum, text = line }
          end
        end
      end
    end
  end

  return results
end

--- Find lines in a file that contain a wikilink to the target name.
---@param abs_path string
---@param target_name string The note name to search for (case-insensitive)
---@param heading_filter string|nil If set, only match links with this #heading
---@return { lnum: number, text: string }[]
function M.find_link_lines(abs_path, target_name, heading_filter)
  local lines = file_cache.read(abs_path)
  if not lines then return {} end
  return find_link_lines_from_cache(lines, target_name, heading_filter)
end

--- Batch-read unique source files for a set of inlinks, deduplicating by abs_path.
---@param inlinks table[] array of inlink entries from vault index
---@param idx VaultIndex
---@return table<string, string[]> file_lines_cache mapping abs_path -> lines
local function batch_read_inlink_sources(inlinks, idx)
  local file_lines_cache = {}
  for _, inlink in ipairs(inlinks) do
    local source_rel = inlink.path .. ".md"
    local source_entry = idx:get_entry(source_rel)
    if source_entry and not file_lines_cache[source_entry.abs_path] then
      local lines = file_cache.read(source_entry.abs_path)
      file_lines_cache[source_entry.abs_path] = lines or {}
    end
  end
  return file_lines_cache
end

--- Build grep-like results from cached file lines for a set of inlinks.
---@param inlinks table[] array of inlink entries from vault index
---@param idx VaultIndex
---@param file_lines_cache table<string, string[]>
---@param target_name string
---@param heading_filter string|nil
---@return string[] results in "rel_path:lnum:text" format
local function collect_backlink_results(inlinks, idx, file_lines_cache, target_name, heading_filter)
  local results = {}
  for _, inlink in ipairs(inlinks) do
    local source_rel = inlink.path .. ".md"
    local source_entry = idx:get_entry(source_rel)
    if source_entry and file_lines_cache[source_entry.abs_path] then
      local hits = find_link_lines_from_cache(file_lines_cache[source_entry.abs_path], target_name, heading_filter)
      for _, hit in ipairs(hits) do
        results[#results + 1] = source_rel .. ":" .. hit.lnum .. ":" .. hit.text
      end
    end
  end
  return results
end

local function nearest_heading_above_cursor()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(0, 0, row, false)
  for i = #lines, 1, -1 do
    local heading_text = lines[i]:match(pat.HEADING_TEXT)
    if heading_text then
      return heading_text
    end
  end
  return nil
end

function M.backlinks()
  local name = engine.current_note_name()
  if not name then
    notify.no_filename()
    return
  end

  -- Try vault index first
  local rel_path, idx = current_file_index_info()
  if rel_path and idx then
    local inlinks = idx:get_inlinks(rel_path)
    if #inlinks == 0 then
      notify.no_backlinks(name)
      return
    end

    local file_lines_cache = batch_read_inlink_sources(inlinks, idx)
    local results = collect_backlink_results(inlinks, idx, file_lines_cache, name, nil)

    if #results == 0 then
      -- Inlinks exist but couldn't find the actual lines (edge case)
      local file_list = {}
      for _, inlink in ipairs(inlinks) do
        file_list[#file_list + 1] = inlink.path .. ".md"
      end
      table.sort(file_list)
      require("fzf-lua").fzf_exec(file_list, engine.vault_fzf_opts(
        "Backlinks to " .. name, {
          previewer = "builtin",
          actions = engine.vault_fzf_actions(),
        }
      ))
      return
    end

    require("fzf-lua").fzf_exec(results, engine.vault_fzf_opts(
      "Backlinks to " .. name, {
        fzf_opts = { ["--delimiter"] = ":", ["--nth"] = "3.." },
        previewer = "builtin",
        actions = engine.vault_fzf_actions(),
      }
    ))
    return
  end

  -- Index not ready
  notify.index_not_ready()
end

function M.heading_backlinks()
  local name = engine.current_note_name()
  if not name then
    notify.no_filename()
    return
  end

  local heading = nearest_heading_above_cursor()
  if not heading then
    notify.info("no heading above cursor, falling back to regular backlinks")
    M.backlinks()
    return
  end

  -- Try vault index first
  local rel_path, idx = current_file_index_info()
  if rel_path and idx then
    local inlinks = idx:get_inlinks(rel_path)
    if #inlinks == 0 then
      notify.no_backlinks(name, heading)
      return
    end

    local file_lines_cache = batch_read_inlink_sources(inlinks, idx)
    local results = collect_backlink_results(inlinks, idx, file_lines_cache, name, heading)

    if #results == 0 then
      notify.info("no heading backlinks found for " .. name .. "#" .. heading)
      return
    end

    require("fzf-lua").fzf_exec(results, engine.vault_fzf_opts(
      "Heading backlinks to " .. name .. "#" .. heading, {
        fzf_opts = { ["--delimiter"] = ":", ["--nth"] = "3.." },
        previewer = "builtin",
        actions = engine.vault_fzf_actions(),
      }
    ))
    return
  end

  -- Index not ready
  notify.index_not_ready()
end

function M.forwardlinks()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local seen = {}
  local links = {}

  for _, line in ipairs(lines) do
    for link in line:gmatch(pat.LINK_TARGETS_SIMPLE) do
      -- Strip trailing backslash from \| escape used in markdown tables
      local trimmed = vim.trim(link:gsub("\\$", ""))
      if trimmed ~= "" and not seen[trimmed] then
        seen[trimmed] = true
        local path = wikilinks.resolve_link(trimmed)
        if path then
          local rel = path:sub(#engine.vault_path + 2)
          links[#links + 1] = rel
        else
          links[#links + 1] = trimmed .. ".md"
        end
      end
    end
  end

  if #links == 0 then
    notify.info("no wikilinks found in current buffer")
    return
  end

  table.sort(links)

  require("fzf-lua").fzf_exec(links, engine.vault_fzf_opts("Forward links", {
    previewer = "builtin",
    actions = engine.vault_fzf_actions(),
  }))
end

--- Called by event_dispatch.lua on FileType markdown.
--- @param ev table autocmd event args
function M.on_ft_markdown(ev)
  vim.keymap.set("n", "<leader>vfb", function()
    M.backlinks()
  end, { buffer = ev.buf, desc = "Find: backlinks", silent = true })

  vim.keymap.set("n", "<leader>vfl", function()
    M.forwardlinks()
  end, { buffer = ev.buf, desc = "Find: forward links", silent = true })

  vim.keymap.set("n", "<leader>vfh", function()
    M.heading_backlinks()
  end, { buffer = ev.buf, desc = "Find: heading backlinks", silent = true })
end

function M.setup()
  local palette = require("andrew.vault.command_palette")

  vim.api.nvim_create_user_command("VaultBacklinks", function()
    M.backlinks()
  end, { desc = "Show notes linking to current note" })

  vim.api.nvim_create_user_command("VaultForwardlinks", function()
    M.forwardlinks()
  end, { desc = "List wikilinks in current note" })

  -- FileType autocmd removed: now dispatched via event_dispatch.lua

  -- Palette registrations
  palette.register_command("VaultBacklinks", "Show notes linking to current note", "Links", M.backlinks, "<leader>vfb")
  palette.register_command("VaultForwardlinks", "List wikilinks in current note", "Links", M.forwardlinks, "<leader>vfl")
  palette.register_keymap("<leader>vfh", "Find: heading backlinks", "Links", M.heading_backlinks, true)
end

-- Expose cache-aware variant for sidebar_backlinks and other consumers
M.find_link_lines_from_cache = find_link_lines_from_cache
M.batch_read_inlink_sources = batch_read_inlink_sources

return M
