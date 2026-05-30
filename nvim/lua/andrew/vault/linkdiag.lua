local config = require("andrew.vault.config")
local engine = require("andrew.vault.engine")
local link_utils = require("andrew.vault.link_utils")
local notify = require("andrew.vault.notify")
local pat = require("andrew.vault.patterns")
local vault_index = require("andrew.vault.vault_index")

local M = {}
M.enabled = true
M.ns = vim.api.nvim_create_namespace("vault_linkdiag")

--- Return the list of all cached lowercase basenames (for fuzzy matching).
---@return string[]
function M.get_all_names()
  local idx = vault_index.current()
  if idx and idx:is_ready() then
    local name_cache = idx:get_name_cache()
    local list = {}
    for name in pairs(name_cache.names) do
      list[#list + 1] = name
    end
    return list
  end
  return {}
end

-- ---------------------------------------------------------------------------
-- Heading extraction
-- ---------------------------------------------------------------------------

--- Extract headings from a file, returning both a slug set and ordered raw heading list.
--- Uses vault index when ready; falls back to disk read for unindexed files.
---@param filepath string absolute path to a markdown file
---@return table<string, boolean> slug_set, string[] raw_headings
function M.get_headings(filepath)
  local idx = vault_index.current()
  if idx and idx:is_ready() then
    local slug_set, headings = idx:get_headings(filepath)
    if slug_set and next(slug_set) ~= nil then
      local raw_headings = {}
      for _, h in ipairs(headings) do
        raw_headings[#raw_headings + 1] = h.text
      end
      return slug_set, raw_headings
    end
  end
  -- File not in index (e.g. new unsaved file): read from disk
  local slugs, headings = link_utils.extract_headings(filepath)
  return slugs, headings
end

-- ---------------------------------------------------------------------------
-- Simple fuzzy/edit-distance matching
-- ---------------------------------------------------------------------------

--- Levenshtein edit distance — delegates to search_query.lua (shared impl).
local edit_distance = require("andrew.vault.search_query").edit_distance

--- Rank candidates by edit distance, returning the top N within threshold.
---@param query string the query string to match against
---@param candidates table[] list of { key = string, ... } tables
---@param key_fn fun(item: any): string extracts the comparison string from each candidate
---@param entry_fn fun(item: any, dist: number): table builds the result entry
---@param n number max results
---@return table[]
local function rank_by_distance(query, candidates, key_fn, entry_fn, n)
  n = n or 5
  local scored = {}
  local threshold = math.max(math.floor(#query * config.link_repair.fuzzy_threshold), config.link_repair.fuzzy_min_distance)
  for _, cand in ipairs(candidates) do
    local dist = edit_distance(query, key_fn(cand))
    if dist <= threshold then
      scored[#scored + 1] = entry_fn(cand, dist)
    end
  end
  table.sort(scored, function(x, y) return x.dist < y.dist end)
  local result = {}
  for i = 1, math.min(n, #scored) do
    result[i] = scored[i]
  end
  return result
end

--- Find the top N closest matches for `query` from a list of candidates.
---@param query string the broken name (lowercased)
---@param candidates string[] list of valid names
---@param n number max results
---@return {name: string, dist: number}[]
local function find_closest(query, candidates, n)
  return rank_by_distance(query, candidates,
    function(cand) return cand end,
    function(cand, dist) return { name = cand, dist = dist } end,
    n)
end

--- Find the top N closest heading matches from a target file's headings.
---@param anchor_slug string the broken heading slug
---@param filepath string path to the target note
---@param n number max results
---@return {heading: string, slug: string, dist: number}[]
function M.find_closest_headings(anchor_slug, filepath, n)
  -- Use vault index entries directly when available (they already have .slug)
  local heading_entries
  local idx = vault_index.current()
  if idx and idx:is_ready() then
    local _, headings = idx:get_headings(filepath)
    if headings and #headings > 0 then
      heading_entries = headings -- each entry has .text and .slug
    end
  end
  if not heading_entries then
    -- Fallback: read from disk and compute slugs
    local _, raw_headings = M.get_headings(filepath)
    heading_entries = {}
    for _, h in ipairs(raw_headings) do
      heading_entries[#heading_entries + 1] = { text = h, slug = link_utils.heading_to_slug(h) }
    end
  end
  return rank_by_distance(anchor_slug, heading_entries,
    function(e) return e.slug end,
    function(e, dist) return { heading = e.text, slug = e.slug, dist = dist } end,
    n)
end

-- ---------------------------------------------------------------------------
-- Core validation
-- ---------------------------------------------------------------------------

--- Run URL validation (async) and append diagnostics.
--- Called after pipeline validation to check external URLs.
---@param bufnr number buffer number
---@param diags table[] diagnostics list (mutated in place)
local function run_url_validation(bufnr, diags)
  if not (config.url_validation.enabled and config.url_validation.diagnostics) then
    return
  end
  local url_validate = require("andrew.vault.url_validate")
  local url_entries = url_validate.extract_urls(
    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  )

  -- Add cached results immediately (avoids flicker for known-dead links)
  for _, entry in ipairs(url_entries) do
    local cached = url_validate.get_cached(entry.url)
    if cached then
      local class = url_validate.classify_status(cached.status)
      local severity = url_validate.class_to_severity(class)
      if severity then
        diags[#diags + 1] = {
          lnum = entry.lnum - 1,
          col = entry.col,
          end_col = entry.end_col,
          severity = severity,
          message = string.format("Dead URL [%d]: %s", cached.status, entry.url),
          source = "vault-linkdiag",
          _type = "dead_url",
          _url = entry.url,
        }
      end
    end
  end

  -- Re-set diagnostics with cached URL results included
  vim.diagnostic.set(M.ns, bufnr, diags)

  -- Fire async validation for uncached URLs
  local uncached = {}
  for _, entry in ipairs(url_entries) do
    if not url_validate.get_cached(entry.url) then
      uncached[#uncached + 1] = entry
    end
  end

  if #uncached > 0 then
    url_validate.validate_batch(uncached, function(_entry, _result)
      if vim.api.nvim_buf_is_valid(bufnr) then
        M.validate(bufnr)
      end
    end, function(_all_results)
      if vim.api.nvim_buf_is_valid(bufnr) then
        M.validate(bufnr)
      end
    end)
  end
end

--- Pipeline-based validation: uses pre-tokenized and pre-resolved data.
---@param bufnr number buffer number
---@param fname string buffer file path
---@param parse_cache table line_parse_cache module
---@param semantic table semantic_resolution module
local function validate_from_pipeline(bufnr, fname, parse_cache, semantic)
  local diags = {}

  -- Per-validate heading cache: avoids redundant disk reads / index lookups
  local heading_cache = {} -- filepath -> slug_set

  ---@param filepath string
  ---@return table<string, boolean>
  local function cached_get_headings(filepath)
    if not heading_cache[filepath] then
      heading_cache[filepath] = M.get_headings(filepath)
    end
    return heading_cache[filepath]
  end

  for line_nr, token in parse_cache.iter_tokens(bufnr, "wikilink") do
    local inner = token.captures[1]
    if not inner then goto continue end

    -- Embed links (![[...]]) are already separated by the pipeline tokenizer
    -- as "embed" type tokens; iter_tokens("wikilink") never yields embeds.

    -- Get resolved tokens for this line and find the matching one
    local resolved_list = semantic.get_resolved(bufnr, line_nr)
    local rt = nil
    if resolved_list then
      for _, r in ipairs(resolved_list) do
        if r.token and r.token.type == "wikilink"
            and r.token.start_col == token.start_col
            and r.token.end_col == token.end_col then
          rt = r
          break
        end
      end
    end

    -- Diagnostic columns: already 0-indexed from pipeline tokens
    local col = token.start_col
    local end_col = token.end_col

    if rt then
      local meta = rt.metadata or {}
      local link_text = meta.link_text or inner
      local heading = meta.heading
      local target_name = meta.parsed_name or link_text

      if rt.status == "broken" then
        -- Broken note link -> ERROR
        diags[#diags + 1] = {
          lnum = line_nr,
          col = col,
          end_col = end_col,
          severity = vim.diagnostic.severity.ERROR,
          message = "Broken link: [[" .. target_name .. "]] (note not found)",
          source = "vault-linkdiag",
          _type = "broken_note",
          _target = target_name,
        }
      elseif rt.status == "valid" and meta.self_ref and heading then
        -- Self-referencing link with heading: [[#heading]] — check before cross-file
        local slug_set = cached_get_headings(fname)
        local anchor_slug = link_utils.heading_to_slug(heading)
        if not slug_set[anchor_slug] then
          diags[#diags + 1] = {
            lnum = line_nr,
            col = col,
            end_col = end_col,
            severity = vim.diagnostic.severity.WARN,
            message = "Broken heading: [[#" .. heading .. "]]",
            source = "vault-linkdiag",
            _type = "broken_heading",
            _target = link_utils.get_basename(fname),
            _heading = heading,
            _filepath = fname,
          }
        end
      elseif rt.status == "valid" and heading then
        -- Cross-file note with heading anchor — validate heading exists
        local filepath = rt.target
        if filepath then
          local slug_set = cached_get_headings(filepath)
          local anchor_slug = link_utils.heading_to_slug(heading)
          if not slug_set[anchor_slug] then
            diags[#diags + 1] = {
              lnum = line_nr,
              col = col,
              end_col = end_col,
              severity = vim.diagnostic.severity.WARN,
              message = "Broken heading: [[" .. target_name .. "#" .. heading .. "]] (heading not found)",
              source = "vault-linkdiag",
              _type = "broken_heading",
              _target = target_name,
              _heading = heading,
              _filepath = filepath,
            }
          end
        end
      end
    else
      -- No resolved token found — fall back to manual parsing for this token
      local parsed = link_utils.parse_target(inner)
      local target, heading = parsed.name, parsed.heading
      if not target:match("^https?://") then
        if target == "" then
          if heading then
            local slug_set = cached_get_headings(fname)
            local anchor_slug = link_utils.heading_to_slug(heading)
            if not slug_set[anchor_slug] then
              diags[#diags + 1] = {
                lnum = line_nr,
                col = col,
                end_col = end_col,
                severity = vim.diagnostic.severity.WARN,
                message = "Broken heading: [[#" .. heading .. "]]",
                source = "vault-linkdiag",
                _type = "broken_heading",
                _target = link_utils.get_basename(fname),
                _heading = heading,
                _filepath = fname,
              }
            end
          end
        else
          -- Check note existence via vault index / engine cache
          local idx = vault_index.current()
          local name_cache = idx and idx:is_ready() and idx:get_name_cache() or engine.get_name_cache()
          local names, paths = name_cache.names, name_cache.paths
          local self_name = link_utils.get_basename(fname):lower()
          local target_lower = target:lower()
          local target_basename = link_utils.get_basename(target_lower)
          local target_exists = target_lower == self_name or target_basename == self_name
            or names[target_lower] or names[target_basename]

          if not target_exists then
            diags[#diags + 1] = {
              lnum = line_nr,
              col = col,
              end_col = end_col,
              severity = vim.diagnostic.severity.ERROR,
              message = "Broken link: [[" .. target .. "]] (note not found)",
              source = "vault-linkdiag",
              _type = "broken_note",
              _target = target,
            }
          elseif heading then
            local filepath
            if target_lower == self_name or target_basename == self_name then
              filepath = fname
            else
              filepath = paths[target_lower] or paths[target_basename]
            end
            if filepath then
              local slug_set = cached_get_headings(filepath)
              local anchor_slug = link_utils.heading_to_slug(heading)
              if not slug_set[anchor_slug] then
                diags[#diags + 1] = {
                  lnum = line_nr,
                  col = col,
                  end_col = end_col,
                  severity = vim.diagnostic.severity.WARN,
                  message = "Broken heading: [[" .. target .. "#" .. heading .. "]] (heading not found)",
                  source = "vault-linkdiag",
                  _type = "broken_heading",
                  _target = target,
                  _heading = heading,
                  _filepath = filepath,
                }
              end
            end
          end
        end
      end
    end

    ::continue::
  end

  vim.diagnostic.set(M.ns, bufnr, diags)

  -- External URL validation (async) — reuse shared helper
  run_url_validation(bufnr, diags)
end

--- Validate wikilinks in the given buffer and set diagnostics.
--- Checks both note existence (ERROR) and heading anchor validity (WARN).
---@param bufnr number|nil buffer number, defaults to current
function M.validate(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local fname = vim.api.nvim_buf_get_name(bufnr)
  if not fname:find(engine.vault_path, 1, true) then
    vim.diagnostic.set(M.ns, bufnr, {})
    return
  end

  -- Pipeline path: use pre-tokenized, pre-resolved data
  local ok, pipeline = pcall(require, "andrew.vault.transform_pipeline")
  if ok then
    local parse_cache = pipeline.get_parse_cache()
    if parse_cache then
      validate_from_pipeline(bufnr, fname, parse_cache, pipeline.get_semantic())
      return
    end
  end

  -- Pipeline not available yet (cold cache) — set empty diagnostics until it warms up
  vim.diagnostic.set(M.ns, bufnr, {})
end

-- ---------------------------------------------------------------------------
-- Code actions (broken link quick-fix suggestions)
-- ---------------------------------------------------------------------------

--- Collect diagnostics from our namespace at the given cursor position.
---@param bufnr number
---@return table[] our diagnostics at cursor
local function get_our_diags_at_cursor(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]
  local all = vim.diagnostic.get(bufnr, { namespace = M.ns })
  local result = {}
  for _, d in ipairs(all) do
    if d.lnum == row and col >= d.col and col < d.end_col then
      result[#result + 1] = d
    end
  end
  return result
end

--- Build code-action entries for a single diagnostic.
---@param diag table a diagnostic entry from M.validate
---@param bufnr number
---@return table[] list of {title, action} tables
local function actions_for_diag(diag, bufnr)
  local actions = {}

  if diag._type == "broken_note" then
    -- Suggest closest note names
    local all_names = M.get_all_names()
    local matches = find_closest(diag._target:lower(), all_names, 5)
    for _, m in ipairs(matches) do
      -- Reconstruct the original display-cased name from cached paths
      local vi_idx = vault_index.current()
      local paths_map = (vi_idx and vi_idx:is_ready() and vi_idx:get_name_cache() or engine.get_name_cache()).paths
      local display = m.name
      if paths_map[m.name] then
        display = link_utils.get_basename(paths_map[m.name])
      end
      actions[#actions + 1] = {
        title = "Replace with [[" .. display .. "]]",
        _replacement_target = display,
        _diag = diag,
        _bufnr = bufnr,
      }
    end
  elseif diag._type == "broken_heading" then
    -- Suggest closest headings from the target note
    local anchor_slug = link_utils.heading_to_slug(diag._heading)
    local matches = M.find_closest_headings(anchor_slug, diag._filepath, 5)
    for _, m in ipairs(matches) do
      actions[#actions + 1] = {
        title = "Replace heading with #" .. m.heading,
        _replacement_heading = m.heading,
        _diag = diag,
        _bufnr = bufnr,
      }
    end
  end

  return actions
end

--- Apply a link fix: replace the broken link text in the buffer.
--- Public API for both linkdiag code actions and link_repair batch fixes.
---@param bufnr number buffer number
---@param diag table diagnostic entry (needs lnum, col, end_col)
---@param replacement_type "note"|"heading"
---@param replacement_value string the replacement string
---@return boolean success whether the replacement was applied
function M.apply_fix(bufnr, diag, replacement_type, replacement_value)
  local line = vim.api.nvim_buf_get_lines(bufnr, diag.lnum, diag.lnum + 1, false)[1]
  if not line then return false end

  local link_text = line:sub(diag.col + 1, diag.end_col)
  local new_link

  if replacement_type == "note" then
    new_link = link_utils.replace_link_note(link_text, replacement_value)
  elseif replacement_type == "heading" then
    new_link = link_utils.replace_link_heading(link_text, replacement_value)
  end

  if new_link then
    local new_line = line:sub(1, diag.col) .. new_link .. line:sub(diag.end_col + 1)
    vim.api.nvim_buf_set_lines(bufnr, diag.lnum, diag.lnum + 1, false, { new_line })
    return true
  end
  return false
end

--- Apply a code action: thin wrapper around M.apply_fix for internal use.
---@param action table an action from actions_for_diag
local function apply_action(action)
  local diag = action._diag
  local bufnr = action._bufnr
  local replacement_type = action._replacement_target and "note" or "heading"
  local replacement_value = action._replacement_target or action._replacement_heading
  if replacement_value and M.apply_fix(bufnr, diag, replacement_type, replacement_value) then
    vim.schedule(function() M.validate(bufnr) end)
  end
end

--- Show code actions for the broken link under the cursor via vim.ui.select.
function M.code_action()
  local bufnr = vim.api.nvim_get_current_buf()
  local diags = get_our_diags_at_cursor(bufnr)
  if #diags == 0 then
    notify.info("no broken link under cursor")
    return
  end

  local all_actions = {}
  for _, d in ipairs(diags) do
    vim.list_extend(all_actions, actions_for_diag(d, bufnr))
  end

  if #all_actions == 0 then
    notify.info("no fix suggestions available")
    return
  end

  vim.ui.select(all_actions, {
    prompt = "Fix broken link",
    format_item = function(item) return item.title end,
  }, function(choice)
    if choice then
      apply_action(choice)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Toggle
-- ---------------------------------------------------------------------------

--- Toggle auto-diagnostics on/off.
function M.toggle()
  M.enabled = not M.enabled
  if not M.enabled then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      vim.diagnostic.set(M.ns, buf, {})
    end
  else
    M.validate()
  end
  notify.toggle("link diagnostics", M.enabled)
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  local palette = require("andrew.vault.command_palette")

  vim.api.nvim_create_user_command("VaultLinkDiag", function() M.validate() end,
    { desc = "Run link diagnostics on current buffer" })
  vim.api.nvim_create_user_command("VaultLinkDiagToggle", function() M.toggle() end,
    { desc = "Toggle auto link diagnostics" })
  vim.api.nvim_create_user_command("VaultFixLinks", function()
    require("andrew.vault.link_repair").repair_buffer()
  end, { desc = "Repair broken links in buffer (delegates to link_repair)" })
  vim.api.nvim_create_user_command("VaultURLCacheStats", function()
    local url_validate = require("andrew.vault.url_validate")
    local stats = url_validate.cache_stats()
    notify.info(string.format(
      "URL cache: %d total (%d valid, %d expired)\n" ..
      "  OK: %d | Dead: %d | Error: %d | Redirect: %d\n" ..
      "  Queue: %d pending, %d active | %d submitted, %d completed, %d rejected (max %d)",
      stats.total, stats.valid, stats.expired,
      stats.by_class.ok, stats.by_class.dead,
      stats.by_class.error, stats.by_class.redirect,
      stats.queue_depth, stats.queue_active,
      stats.queue_submitted, stats.queue_completed, stats.queue_rejected,
      stats.max_queue_size
    ))
  end, { desc = "Show URL validation cache statistics" })

  local group = vim.api.nvim_create_augroup("VaultLinkDiag", { clear = true })

  vim.api.nvim_create_autocmd("User", {
    pattern = "VaultCacheInvalidate",
    callback = function(ev)
      if not M.enabled then return end
      local data = ev.data or {}
      local bufnr = vim.api.nvim_get_current_buf()
      local bufname = vim.api.nvim_buf_get_name(bufnr)
      if not (bufname:match(pat.MD_EXTENSION) and engine.is_vault_buf(bufnr)) then
        return
      end

      local filter_utils = require("andrew.vault.filter_utils")
      if not filter_utils.should_invalidate_buffer(data, bufname) then return end

      M.validate(bufnr)
    end,
  })

  -- BufEnter autocmd removed: now dispatched via event_dispatch.lua

  -- FileType autocmd removed: now dispatched via event_dispatch.lua

  -- Palette registrations
  palette.register_command("VaultLinkDiag", "Run link diagnostics on current buffer", "Links", function() M.validate() end)
  palette.register_command("VaultLinkDiagToggle", "Toggle auto link diagnostics", "Links", M.toggle, "<leader>vcd")
  palette.register_command("VaultFixLinks", "Repair broken links in buffer (delegates to link_repair)", "Links", function()
    require("andrew.vault.link_repair").repair_buffer()
  end, "<leader>vcF")
  palette.register_command("VaultURLCacheStats", "Show URL validation cache statistics", "Links", function()
    vim.cmd("VaultURLCacheStats")
  end)
  palette.register_keymap("<leader>vcf", "Check: fix broken link under cursor", "Links", M.code_action, true)
end

--- Called by event_dispatch.lua on BufEnter for non-vault buffers.
--- @param ctx { bufnr: number, file: string, is_vault_md: boolean }
function M.on_buf_enter_non_vault(ctx)
  vim.diagnostic.set(M.ns, ctx.bufnr, {})
end

--- Called by event_dispatch.lua on FileType markdown.
--- @param ev table autocmd event args
function M.on_ft_markdown(ev)
  vim.keymap.set("n", "<leader>vcd", function() M.toggle() end,
    { buffer = ev.buf, desc = "Check: diagnostics toggle", silent = true })
  vim.keymap.set("n", "<leader>vcf", function() M.code_action() end,
    { buffer = ev.buf, desc = "Check: fix broken link under cursor", silent = true })
  vim.keymap.set("n", "<leader>vcF", function()
    require("andrew.vault.link_repair").repair_buffer()
  end, { buffer = ev.buf, desc = "Check: repair broken links (buffer)", silent = true })
end

-- Public API: fuzzy name matching for broken link repair
M.find_closest = find_closest

return M
