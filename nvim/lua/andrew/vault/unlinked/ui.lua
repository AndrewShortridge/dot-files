local engine = require("andrew.vault.engine")
local wrapper = require("andrew.vault.unlinked.wrapper")
local notify = require("andrew.vault.notify")
local fzf = require("fzf-lua")

local M = {}

local function notify_wrapped(count, with_wikilinks)
  if count == 0 then return end
  local msg = "wrapped " .. count .. " mention(s)"
  if with_wikilinks then
    msg = msg .. " in [[wikilinks]]"
  end
  notify.info(msg)
end

--- Build fzf entry strings and lookup map from vault scan results.
---@param results table[]
---@return string[] entries, table<string, table> entry_map
function M.build_vault_entries(results, opts)
  opts = opts or {}
  local entries = {}
  local entry_map = {}
  for _, r in ipairs(results) do
    local rel = engine.vault_relative(r.file) or r.file
    local entry
    if opts.include_match ~= false then
      entry = rel .. ":" .. r.line .. ":" .. r.col .. ":[" .. (r.match or "?") .. "] " .. r.text
    else
      entry = rel .. ":" .. r.line .. ":" .. r.col .. ": " .. r.text
    end
    entries[#entries + 1] = entry
    entry_map[entry] = r
  end
  if opts.sort ~= false then
    table.sort(entries)
  end
  return entries, entry_map
end

--- Collect selected items from entry_map, optionally filtering by a predicate.
---@param selected string[]
---@param entry_map table<string, table>
---@param filter_fn? fun(item: table): boolean
---@return table[]
local function collect_selected(selected, entry_map, filter_fn)
  if not selected or #selected == 0 then return {} end
  local items = {}
  for _, sel in ipairs(selected) do
    local item = entry_map[sel]
    if item and (not filter_fn or filter_fn(item)) then
      items[#items + 1] = item
    end
  end
  return items
end

--- Open a vault-wide fzf picker for unlinked mentions.
--- Deduplicates the common vault picker pattern shared by autolink_vault,
--- unlinked_mentions, and vault_unlinked_mentions.
---@param entries string[]
---@param entry_map table<string, table>
---@param opts { prompt: string, multi?: boolean, all_results?: table[], with_wikilinks?: boolean }
function M.open_vault_picker(entries, entry_map, opts)
  local fzf_opts = {
    ["--no-sort"] = "",
    ["--delimiter"] = ":",
    ["--nth"] = "4..",
  }
  if opts.multi then
    fzf_opts["--multi"] = ""
  end

  local actions = {
    ["default"] = function(selected)
      local items = collect_selected(selected, entry_map)
      if #items == 0 then return end
      vim.cmd("edit " .. vim.fn.fnameescape(items[1].file))
      vim.api.nvim_win_set_cursor(0, { items[1].line, items[1].col - 1 })
      vim.cmd("normal! zz")
    end,
    ["ctrl-w"] = function(selected)
      local to_wrap = collect_selected(selected, entry_map, function(r) return r.match end)
      if #to_wrap == 0 then return end
      local wrapped = wrapper.apply_file_wraps_bottom_up(to_wrap, wrapper.wrap_in_wikilink)
      notify_wrapped(wrapped, opts.with_wikilinks)
    end,
  }

  if opts.all_results then
    actions["ctrl-a"] = function()
      local wrapped = wrapper.apply_file_wraps_bottom_up(opts.all_results, wrapper.wrap_in_wikilink)
      notify_wrapped(wrapped, opts.with_wikilinks)
    end
  end

  fzf.fzf_exec(entries, {
    prompt = opts.prompt,
    previewer = "builtin",
    cwd = engine.vault_path,
    fzf_opts = fzf_opts,
    actions = actions,
  })
end

--- Open a buffer-level fzf picker for auto-linking.
---@param bufnr number
---@param buffer_matches table[]
function M.open_buffer_picker(bufnr, buffer_matches)
  local entries = {}
  local entry_map = {}

  for _, m in ipairs(buffer_matches) do
    local link_display = wrapper.build_wikilink_text(m.text)
    local entry = string.format("L%d:%d  '%s' -> %s",
      m.row + 1, m.start_col + 1, m.text, link_display)
    entries[#entries + 1] = entry
    entry_map[entry] = m
  end

  fzf.fzf_exec(entries, {
    prompt = "Auto-link buffer (" .. #buffer_matches .. " mentions)> ",
    fzf_opts = { ["--multi"] = "" },
    actions = {
      ["default"] = function(selected)
        local items = collect_selected(selected, entry_map)
        if #items == 0 then return end
        vim.api.nvim_win_set_cursor(0, { items[1].row + 1, items[1].start_col })
        vim.cmd("normal! zz")
      end,
      ["ctrl-w"] = function(selected)
        local to_wrap = collect_selected(selected, entry_map)
        if #to_wrap == 0 then return end
        local wrapped = wrapper.apply_buffer_wraps_bottom_up(bufnr, to_wrap, wrapper.build_wikilink_text)
        notify_wrapped(wrapped, true)
      end,
      ["ctrl-a"] = function()
        local wrapped = wrapper.apply_buffer_wraps_bottom_up(bufnr, buffer_matches, wrapper.build_wikilink_text)
        notify_wrapped(wrapped, true)
      end,
    },
  })
end

return M
