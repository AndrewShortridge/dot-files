--- Vault-wide link repair: batch broken link fixing with auto-fix support.
---
--- Extends linkdiag.lua's per-cursor code actions with:
--- - Buffer-wide batch repair (:VaultLinkRepair)
--- - Vault-wide batch repair (:VaultLinkRepairAll)
--- - Auto-fix by confidence threshold
--- - Moved-file detection

local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local file_cache = require("andrew.vault.file_cache")
local link_utils = require("andrew.vault.link_utils")
local linkdiag = require("andrew.vault.linkdiag")
local notify = require("andrew.vault.notify")
local pat = require("andrew.vault.patterns")
local vault_index = require("andrew.vault.vault_index")

local M = {}

-- ---------------------------------------------------------------------------
-- Moved-file detection
-- ---------------------------------------------------------------------------

--- Check if a broken link target exists elsewhere in the vault under a different path.
--- Returns matching entries where the basename matches but the full path differs.
---@param broken_name string the broken link target (e.g., "OldProject")
---@param index table VaultIndex instance
---@return { rel_path: string, basename: string, dist: number }[]
local function check_moved_file(broken_name, index)
  local lower = broken_name:lower()
  local basename_lower = link_utils.get_basename(lower)
  local candidates = {}

  for rel_path, entry in pairs(index:snapshot_files()) do
    if entry.basename_lower == basename_lower then
      candidates[#candidates + 1] = {
        rel_path = rel_path,
        basename = entry.basename,
        basename_lower = entry.basename_lower,
        dist = 0,
        moved = true,
      }
    end
  end

  return candidates
end

-- ---------------------------------------------------------------------------
-- Auto-fix logic
-- ---------------------------------------------------------------------------

--- Determine if a repair candidate is high-confidence enough for auto-fix.
---@param candidates { name: string, dist: number }[]
---@param threshold number max edit distance for auto-fix (default 1)
---@return string|nil best_match the auto-fixable candidate, or nil
local function auto_fix_candidate(candidates, threshold)
  threshold = threshold or 1
  if #candidates == 0 then return nil end
  if #candidates == 1 and candidates[1].dist <= threshold then
    return candidates[1].name
  end
  -- Multiple candidates: only auto-fix if top candidate is strictly better
  if candidates[1].dist <= threshold
    and #candidates >= 2
    and candidates[2].dist > candidates[1].dist + 1 then
    return candidates[1].name
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Candidate collection
-- ---------------------------------------------------------------------------

--- Merge edit-distance candidates with moved-file candidates, deduplicating.
---@param name_candidates { name: string, dist: number }[]
---@param moved_candidates { rel_path: string, basename: string, dist: number, moved: boolean }[]
---@return { name: string, dist: number, moved: boolean }[]
local function merge_candidates(name_candidates, moved_candidates)
  local seen = {}
  local merged = {}

  for _, c in ipairs(name_candidates) do
    -- name_candidates come from find_closest() over get_all_names(),
    -- which returns pre-lowered names from the vault index name cache.
    local key = c.name
    if not seen[key] then
      seen[key] = true
      merged[#merged + 1] = { name = c.name, dist = c.dist, moved = false }
    end
  end

  for _, c in ipairs(moved_candidates) do
    -- check_moved_file() always sets basename_lower from the index entry
    local key = c.basename_lower or c.basename:lower()
    if not seen[key] then
      seen[key] = true
      merged[#merged + 1] = { name = c.basename, dist = c.dist, moved = true }
    end
  end

  table.sort(merged, function(a, b) return a.dist < b.dist end)
  return merged
end

--- Apply a single repair to a buffer line.
--- Delegates to linkdiag.apply_fix() for the actual replacement.
---@param bufnr number
---@param repair table repair entry with diag, candidates, auto_fix, type
---@return boolean success
local function apply_repair(bufnr, repair)
  if not repair.auto_fix then return false end
  return linkdiag.apply_fix(bufnr, repair.diag, repair.type, repair.auto_fix)
end

--- Compute repair candidates for a single broken link.
--- Shared by both buffer and vault repair paths.
---@param target string broken link target name
---@param link_type string "broken_note" or "broken_heading"
---@param heading string|nil heading text (for broken_heading)
---@param filepath string|nil absolute path to target file (for broken_heading)
---@param ctx table { all_names, idx, cfg }
---@return table repair_info { candidates, auto_fix, type }
local function compute_repair_candidates(target, link_type, heading, filepath, ctx)
  local max_candidates = ctx.cfg.max_candidates or 5
  local threshold = ctx.cfg.auto_fix_threshold or 1

  if link_type == "broken_note" then
    local name_candidates = linkdiag.find_closest(target:lower(), ctx.all_names, max_candidates)
    local moved_candidates = (ctx.cfg.detect_moved ~= false) and ctx.idx
      and check_moved_file(target, ctx.idx) or {}
    local merged = merge_candidates(name_candidates, moved_candidates)

    -- Resolve display names from paths
    if ctx.idx then
      local paths_map = ctx.idx:get_name_cache().paths or {}
      for _, c in ipairs(merged) do
        local name_lower = c.name:lower()
        if paths_map[name_lower] then
          c.name = link_utils.get_basename(paths_map[name_lower])
        end
      end
    end

    local auto = auto_fix_candidate(merged, threshold)
    return { candidates = merged, auto_fix = auto, type = "note" }
  else
    local heading_candidates = linkdiag.find_closest_headings(
      link_utils.heading_to_slug(heading), filepath, max_candidates
    )
    local for_auto = {}
    for _, h in ipairs(heading_candidates) do
      for_auto[#for_auto + 1] = { name = h.heading, dist = h.dist }
    end
    local auto = auto_fix_candidate(for_auto, threshold)
    return { candidates = heading_candidates, auto_fix = auto, type = "heading" }
  end
end

-- ---------------------------------------------------------------------------
-- Buffer repair
-- ---------------------------------------------------------------------------

--- Collect repair candidates for all broken links in a buffer.
---@param bufnr number
---@return table[] repairs list of repair entries
local function collect_buffer_repairs(bufnr)

  local idx = vault_index.current()
  local all_names = linkdiag.get_all_names()
  local cfg = config.link_repair or {}
  local ctx = { all_names = all_names, idx = idx, cfg = cfg }

  local diags = vim.diagnostic.get(bufnr, { namespace = linkdiag.ns })
  local repairs = {}

  for _, d in ipairs(diags) do
    if d._type == "broken_note" then
      local info = compute_repair_candidates(d._target, "broken_note", nil, nil, ctx)
      info.diag = d
      repairs[#repairs + 1] = info
    elseif d._type == "broken_heading" then
      local info = compute_repair_candidates(d._target, "broken_heading", d._heading, d._filepath, ctx)
      info.diag = d
      repairs[#repairs + 1] = info
    end
  end

  return repairs
end

--- Show the repair picker for a buffer.
---@param bufnr number
---@param repairs table[]
local function show_repair_picker(bufnr, repairs)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    notify.warn("fzf-lua required for link repair picker")
    return
  end

  local entries = {}
  local entry_map = {}

  for _, r in ipairs(repairs) do
    local d = r.diag
    local suggestions = {}
    if r.type == "note" then
      for _, c in ipairs(r.candidates) do
        local label = c.name .. " (dist=" .. c.dist .. ")"
        if c.moved then label = label .. " [moved]" end
        suggestions[#suggestions + 1] = label
      end
    elseif r.type == "heading" then
      for _, c in ipairs(r.candidates) do
        suggestions[#suggestions + 1] = "#" .. c.heading .. " (dist=" .. c.dist .. ")"
      end
    end

    local auto_tag = r.auto_fix and " [auto-fixable]" or ""
    local sug_str = #suggestions > 0
      and " -> " .. table.concat(suggestions, " | ")
      or " (no suggestions)"
    local entry = string.format("L%d:%d  %s%s%s",
      d.lnum + 1, d.col + 1, d.message, auto_tag, sug_str)
    entries[#entries + 1] = entry
    entry_map[entry] = r
  end

  fzf.fzf_exec(entries, {
    prompt = "Link repair (" .. #repairs .. " broken)> ",
    actions = {
      ["default"] = function(selected)
        if not selected or not selected[1] then return end
        local r = entry_map[selected[1]]
        if not r then return end

        if r.type == "note" and #r.candidates > 0 then
          vim.schedule(function()
            local items = {}
            for _, c in ipairs(r.candidates) do
              items[#items + 1] = {
                title = "[[" .. c.name .. "]]" .. (c.moved and " [moved]" or ""),
                _replacement = c.name,
              }
            end
            vim.ui.select(items, {
              prompt = "Choose fix for " .. r.diag.message,
              format_item = function(item) return item.title end,
            }, function(choice)
              if choice then
                r.auto_fix = choice._replacement
                apply_repair(bufnr, r)
                vim.schedule(function() linkdiag.validate(bufnr) end)
              end
            end)
          end)
        elseif r.type == "heading" and #r.candidates > 0 then
          vim.schedule(function()
            local items = {}
            for _, c in ipairs(r.candidates) do
              items[#items + 1] = {
                title = "#" .. c.heading .. " (dist=" .. c.dist .. ")",
                _replacement = c.heading,
              }
            end
            vim.ui.select(items, {
              prompt = "Choose heading fix",
              format_item = function(item) return item.title end,
            }, function(choice)
              if choice then
                r.auto_fix = choice._replacement
                apply_repair(bufnr, r)
                vim.schedule(function() linkdiag.validate(bufnr) end)
              end
            end)
          end)
        else
          -- No suggestions: jump to location
          vim.api.nvim_win_set_cursor(0, { r.diag.lnum + 1, r.diag.col })
        end
      end,
      ["ctrl-a"] = function()
        -- Apply all auto-fixable repairs
        local sorted = {}
        for _, r in ipairs(repairs) do
          if r.auto_fix then
            sorted[#sorted + 1] = r
          end
        end
        table.sort(sorted, function(a, b) return a.diag.lnum > b.diag.lnum end)
        local fixed = 0
        for _, r in ipairs(sorted) do
          if apply_repair(bufnr, r) then
            fixed = fixed + 1
          end
        end
        notify.links_auto_fixed(fixed)
        vim.schedule(function() linkdiag.validate(bufnr) end)
      end,
      ["ctrl-j"] = function(selected)
        if not selected or not selected[1] then return end
        local lnum = tonumber(selected[1]:match("^L(%d+):"))
        if lnum then
          vim.api.nvim_win_set_cursor(0, { lnum, 0 })
        end
      end,
    },
  })
end

--- Repair broken links in the current buffer.
---@param opts? { auto_fix_all?: boolean }
function M.repair_buffer(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  linkdiag.validate(bufnr)

  local diags = vim.diagnostic.get(bufnr, { namespace = linkdiag.ns })
  -- Filter to only link diagnostics (not URL diagnostics)
  local link_diags = {}
  for _, d in ipairs(diags) do
    if d._type == "broken_note" or d._type == "broken_heading" then
      link_diags[#link_diags + 1] = d
    end
  end

  if #link_diags == 0 then
    notify.info("no broken links in buffer")
    return
  end

  local repairs = collect_buffer_repairs(bufnr)

  if opts.auto_fix_all then
    table.sort(repairs, function(a, b) return a.diag.lnum > b.diag.lnum end)
    local fixed = 0
    for _, r in ipairs(repairs) do
      if r.auto_fix then
        if apply_repair(bufnr, r) then
          fixed = fixed + 1
        end
      end
    end
    notify.links_auto_fixed(fixed)
    linkdiag.validate(bufnr)
    return
  end

  show_repair_picker(bufnr, repairs)
end

-- ---------------------------------------------------------------------------
-- Vault-wide repair
-- ---------------------------------------------------------------------------

--- Scan the vault for broken wikilinks and collect structured repair data.
--- Uses linkcheck.scan_broken_links() for the shared scanning logic, then
--- layers on repair-specific candidate computation (edit-distance, moved-file, auto-fix).
---@param on_results fun(vault_repairs: table[])
local function scan_vault_broken_links(on_results)

  local linkcheck = require("andrew.vault.linkcheck")
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    notify.index_not_ready()
    return
  end

  linkcheck.scan_broken_links(function(broken_links, _total)
    local all_names = linkdiag.get_all_names()
    local cfg = config.link_repair or {}
    local ctx = { all_names = all_names, idx = idx, cfg = cfg }

    local vault_repairs = {}

    for _, b in ipairs(broken_links) do
      if b.type == "broken_note" then
        local info = compute_repair_candidates(b.target, "broken_note", nil, nil, ctx)
        info.file = b.file
        info.lnum = b.lnum
        info.col = 1
        info.message = "Broken link: [[" .. b.target .. "]]"
        info.target = b.target
        vault_repairs[#vault_repairs + 1] = info
      elseif b.type == "broken_heading" then
        local info = compute_repair_candidates(b.target, "broken_heading", b.heading, b.filepath, ctx)
        info.file = b.file
        info.lnum = b.lnum
        info.col = 1
        info.message = "Broken heading: [[" .. b.target .. "#" .. b.heading .. "]]"
        info.target = b.target
        info.heading = b.heading
        info.filepath = b.filepath
        vault_repairs[#vault_repairs + 1] = info
      end
      -- broken_block entries are skipped (link_repair doesn't handle block repairs)
    end

    on_results(vault_repairs)
  end)
end

--- Repair broken links across the entire vault.
---@param opts? { auto_fix_all?: boolean }
function M.repair_vault(opts)
  opts = opts or {}

  notify.info("scanning vault for broken links...")

  scan_vault_broken_links(function(vault_repairs)
    if #vault_repairs == 0 then
      notify.info("no broken links found in vault")
      return
    end

    if opts.auto_fix_all then
      -- Group by file, sort within each file by line descending
      local by_file = {}
      local auto_count = 0
      for _, vr in ipairs(vault_repairs) do
        if vr.auto_fix then
          if not by_file[vr.file] then by_file[vr.file] = {} end
          by_file[vr.file][#by_file[vr.file] + 1] = vr
          auto_count = auto_count + 1
        end
      end

      if auto_count == 0 then
        notify.info("no auto-fixable links found")
        return
      end

      -- Confirmation prompt: vault-wide file writes are not undoable
      local file_count = vim.tbl_count(by_file)
      local msg = string.format(
        "Auto-fix %d broken link(s) across %d file(s)? (not undoable)",
        auto_count, file_count
      )
      vim.ui.select({ "Yes", "No" }, { prompt = msg }, function(choice)
        if choice ~= "Yes" then
          notify.info("link repair cancelled")
          return
        end

      local fixed = 0
      for file, file_repairs in pairs(by_file) do
        table.sort(file_repairs, function(a, b) return a.lnum > b.lnum end)
        local lines = file_cache.read(file)
        if lines and #lines > 0 then
          for _, vr in ipairs(file_repairs) do
            local line = lines[vr.lnum]
            if line then
              local target_lower = vr.target:lower()
              local found_inner, found_open, found_close
              pat.scan_wikilinks(line, function(inner, start_col, end_col)
                local parsed = link_utils.parse_target(inner)
                local parsed_name_lower = parsed.name:lower()
                if parsed_name_lower == target_lower
                  or (parsed_name_lower:match("[^/]+$") or "") == target_lower then
                  found_inner = inner
                  found_open = start_col
                  found_close = end_col
                  return true -- stop scanning
                end
              end)
              if found_open then
                local full_link = "[[" .. found_inner .. "]]"
                local new_link
                if vr.type == "note" then
                  new_link = link_utils.replace_link_note(full_link, vr.auto_fix)
                elseif vr.type == "heading" then
                  new_link = link_utils.replace_link_heading(full_link, vr.auto_fix)
                end
                if new_link then
                  lines[vr.lnum] = line:sub(1, found_open - 1) .. new_link .. line:sub(found_close + 1)
                  fixed = fixed + 1
                end
              end
            end
          end
          engine.write_file(file, table.concat(lines, "\n") .. "\n")
        end
      end

      notify.links_auto_fixed(fixed, " across vault")
      -- Reload open buffers that were modified
      for file in pairs(by_file) do
        local bufnr = vim.fn.bufnr(file)
        if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
          vim.api.nvim_buf_call(bufnr, function()
            vim.cmd("edit!")
          end)
        end
      end
      end) -- vim.ui.select callback
      return
    end

    -- Interactive: show fzf picker
    local ok, fzf = pcall(require, "fzf-lua")
    if not ok then
      notify.warn("fzf-lua required for vault-wide link repair")
      return
    end

    local entries = {}
    local entry_map = {}
    for _, vr in ipairs(vault_repairs) do
      local rel = engine.vault_relative(vr.file) or vr.file
      local suggestions = {}
      if vr.type == "note" then
        for _, c in ipairs(vr.candidates) do
          suggestions[#suggestions + 1] = c.name .. "(d=" .. c.dist .. ")"
        end
      elseif vr.type == "heading" then
        for _, c in ipairs(vr.candidates) do
          suggestions[#suggestions + 1] = "#" .. c.heading .. "(d=" .. c.dist .. ")"
        end
      end
      local auto_tag = vr.auto_fix and " *" or ""
      local sug_str = #suggestions > 0 and " -> " .. suggestions[1] or ""
      local entry = string.format("%s:%d %s%s%s", rel, vr.lnum, vr.message, auto_tag, sug_str)
      entries[#entries + 1] = entry
      entry_map[entry] = vr
    end

    local auto_count = 0
    for _, vr in ipairs(vault_repairs) do
      if vr.auto_fix then auto_count = auto_count + 1 end
    end

    fzf.fzf_exec(entries, {
      prompt = string.format("Vault repair (%d broken, %d auto-fixable)> ",
        #vault_repairs, auto_count),
      previewer = "builtin",
      cwd = engine.vault_path,
      actions = {
        ["default"] = function(selected)
          if not selected or not selected[1] then return end
          local vr = entry_map[selected[1]]
          if vr then
            vim.cmd("edit " .. vim.fn.fnameescape(vr.file))
            vim.api.nvim_win_set_cursor(0, { vr.lnum, (vr.col or 1) - 1 })
            vim.cmd("normal! zz")
          end
        end,
        ["ctrl-a"] = function()
          M.repair_vault({ auto_fix_all = true })
        end,
        ["ctrl-j"] = function(selected)
          if not selected or not selected[1] then return end
          local vr = entry_map[selected[1]]
          if vr then
            vim.cmd("edit " .. vim.fn.fnameescape(vr.file))
            vim.api.nvim_win_set_cursor(0, { vr.lnum, (vr.col or 1) - 1 })
          end
        end,
      },
    })
  end)
end

-- ---------------------------------------------------------------------------
return M
