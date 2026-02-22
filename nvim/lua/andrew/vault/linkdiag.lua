local engine = require("andrew.vault.engine")

local M = {}
M.enabled = true
M.ns = vim.api.nvim_create_namespace("vault_linkdiag")
M._cache = { names = {}, paths = {}, timestamp = 0, ttl = 10 }
-- Heading cache: filepath -> { mtime = number, slugs = {slug=true}, headings = {"raw heading", ...} }
M._heading_cache = {}

-- ---------------------------------------------------------------------------
-- Heading slug conversion (matches wikilinks.lua logic)
-- ---------------------------------------------------------------------------

--- Convert a heading text to its Obsidian-style slug.
---@param text string raw heading text (without the leading # characters)
---@return string slug
local function heading_to_slug(text)
  return text:lower()
    :gsub("[^%w%s%-]", "")
    :gsub("%s", "-")
    :gsub("^%-+", "")
    :gsub("%-+$", "")
end

-- ---------------------------------------------------------------------------
-- Note name / path cache
-- ---------------------------------------------------------------------------

--- Build (or return cached) set of lowercase basenames and path map for all vault .md files.
--- Returns names (set), paths (basename->filepath map).
function M.build_cache()
  local now = os.time()
  if now - M._cache.timestamp < M._cache.ttl then
    return M._cache.names, M._cache.paths
  end
  local names = {}
  local paths = {}
  for _, f in ipairs(vim.fn.globpath(engine.vault_path, "**/*.md", false, true)) do
    local key = vim.fn.fnamemodify(f, ":t:r"):lower()
    names[key] = true
    -- Store first match (sufficient for heading validation)
    if not paths[key] then
      paths[key] = f
    end
  end
  M._cache.names = names
  M._cache.paths = paths
  M._cache.timestamp = now
  return names, paths
end

--- Return the list of all cached lowercase basenames (for fuzzy matching).
---@return string[]
function M.get_all_names()
  local names = M.build_cache()
  local list = {}
  for name in pairs(names) do
    list[#list + 1] = name
  end
  return list
end

-- ---------------------------------------------------------------------------
-- Heading extraction (cached by file mtime)
-- ---------------------------------------------------------------------------

--- Extract headings from a file, returning both a slug set and ordered raw heading list.
--- Results are cached by filepath and mtime for performance.
---@param filepath string absolute path to a markdown file
---@return table<string, boolean> slug_set, string[] raw_headings
function M.get_headings(filepath)
  local stat = vim.uv.fs_stat(filepath)
  if not stat then return {}, {} end

  local cached = M._heading_cache[filepath]
  if cached and cached.mtime == stat.mtime.sec then
    return cached.slugs, cached.headings
  end

  local slugs = {}
  local headings = {}
  local f = io.open(filepath, "r")
  if not f then return {}, {} end

  for line in f:lines() do
    local heading_text = line:match("^#+%s+(.*)")
    if heading_text then
      -- Trim trailing whitespace
      heading_text = heading_text:gsub("%s+$", "")
      headings[#headings + 1] = heading_text
      slugs[heading_to_slug(heading_text)] = true
    end
  end
  f:close()

  M._heading_cache[filepath] = {
    mtime = stat.mtime.sec,
    slugs = slugs,
    headings = headings,
  }
  return slugs, headings
end

-- ---------------------------------------------------------------------------
-- Simple fuzzy/edit-distance matching
-- ---------------------------------------------------------------------------

--- Compute Levenshtein edit distance between two strings.
---@param a string
---@param b string
---@return number
local function edit_distance(a, b)
  local la, lb = #a, #b
  if la == 0 then return lb end
  if lb == 0 then return la end

  -- Use single-row optimization
  local prev = {}
  for j = 0, lb do prev[j] = j end

  for i = 1, la do
    local curr = { [0] = i }
    for j = 1, lb do
      local cost = a:sub(i, i) == b:sub(j, j) and 0 or 1
      curr[j] = math.min(
        prev[j] + 1,        -- deletion
        curr[j - 1] + 1,    -- insertion
        prev[j - 1] + cost  -- substitution
      )
    end
    prev = curr
  end
  return prev[lb]
end

--- Find the top N closest matches for `query` from a list of candidates.
---@param query string the broken name (lowercased)
---@param candidates string[] list of valid names
---@param n number max results
---@return {name: string, dist: number}[]
local function find_closest(query, candidates, n)
  n = n or 5
  local scored = {}
  for _, cand in ipairs(candidates) do
    local dist = edit_distance(query, cand)
    -- Only include if reasonably close (within 60% of query length or 5 chars)
    local threshold = math.max(math.floor(#query * 0.6), 5)
    if dist <= threshold then
      scored[#scored + 1] = { name = cand, dist = dist }
    end
  end
  table.sort(scored, function(x, y) return x.dist < y.dist end)
  local result = {}
  for i = 1, math.min(n, #scored) do
    result[i] = scored[i]
  end
  return result
end

--- Find the top N closest heading matches from a target file's headings.
---@param anchor_slug string the broken heading slug
---@param filepath string path to the target note
---@param n number max results
---@return {heading: string, slug: string, dist: number}[]
function M.find_closest_headings(anchor_slug, filepath, n)
  n = n or 5
  local _, raw_headings = M.get_headings(filepath)
  local scored = {}
  for _, h in ipairs(raw_headings) do
    local slug = heading_to_slug(h)
    local dist = edit_distance(anchor_slug, slug)
    local threshold = math.max(math.floor(#anchor_slug * 0.6), 5)
    if dist <= threshold then
      scored[#scored + 1] = { heading = h, slug = slug, dist = dist }
    end
  end
  table.sort(scored, function(x, y) return x.dist < y.dist end)
  local result = {}
  for i = 1, math.min(n, #scored) do
    result[i] = scored[i]
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Link parsing helpers
-- ---------------------------------------------------------------------------

--- Parse the inner content of a wikilink into target, heading, and raw inner text.
---@param inner string content between [[ and ]]
---@return string target note name (trimmed)
---@return string|nil heading anchor (raw, not slugified)
---@return string full_inner the full inner text (for replacement)
local function parse_wikilink(inner)
  -- Normalise \| escape used inside markdown tables
  inner = inner:gsub("\\|", "|")
  -- Strip display alias: [[target|alias]] -> target portion
  local target_part = inner:match("^([^|]+)") or inner
  -- Split into note name and heading anchor
  local name, heading = target_part:match("^([^#^]+)#([^#^|]+)")
  if not name then
    name = vim.trim((target_part:match("^([^#^|]+)") or target_part))
    heading = nil
  else
    name = vim.trim(name)
    heading = vim.trim(heading)
  end
  return name, heading, inner
end

-- ---------------------------------------------------------------------------
-- Core validation
-- ---------------------------------------------------------------------------

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
  local self_name = vim.fn.fnamemodify(fname, ":t:r"):lower()
  local names, paths = M.build_cache()
  local diags = {}

  for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local pos = 1
    while true do
      local open = line:find("%[%[", pos, false)
      if not open then break end
      local is_embed = open > 1 and line:sub(open - 1, open - 1) == "!"
      local close = line:find("]]", open + 2, true)
      if not close then break end
      pos = close + 2
      if is_embed then goto continue end

      local inner = line:sub(open + 2, close - 1)
      local target, heading = parse_wikilink(inner)
      if target == "" or target:match("^https?://") then goto continue end

      local target_lower = target:lower()
      local target_exists = target_lower == self_name or names[target_lower]

      if not target_exists then
        -- Broken note link -> ERROR
        diags[#diags + 1] = {
          lnum = i - 1,
          col = open - 1,
          end_col = close + 1,
          severity = vim.diagnostic.severity.ERROR,
          message = "Broken link: [[" .. target .. "]] (note not found)",
          source = "vault-linkdiag",
          _type = "broken_note",
          _target = target,
        }
      elseif heading then
        -- Note exists but has a heading anchor -- validate it
        local filepath
        if target_lower == self_name then
          filepath = fname
        else
          filepath = paths[target_lower]
        end
        if filepath then
          local slug_set = M.get_headings(filepath)
          local anchor_slug = heading_to_slug(heading)
          if not slug_set[anchor_slug] then
            diags[#diags + 1] = {
              lnum = i - 1,
              col = open - 1,
              end_col = close + 1,
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
      ::continue::
    end
  end
  vim.diagnostic.set(M.ns, bufnr, diags)
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
      local _, paths_map = M.build_cache()
      local display = m.name
      if paths_map[m.name] then
        display = vim.fn.fnamemodify(paths_map[m.name], ":t:r")
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
    local anchor_slug = heading_to_slug(diag._heading)
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

--- Apply a code action: replace the broken link text in the buffer.
---@param action table an action from actions_for_diag
local function apply_action(action)
  local diag = action._diag
  local bufnr = action._bufnr
  local line = vim.api.nvim_buf_get_lines(bufnr, diag.lnum, diag.lnum + 1, false)[1]
  if not line then return end

  -- Extract the full wikilink span
  local link_text = line:sub(diag.col + 1, diag.end_col)
  local new_link

  if action._replacement_target then
    -- Replace the note name, preserving any existing heading/alias
    local inner = link_text:match("^%[%[(.-)%]%]$")
    if not inner then return end
    inner = inner:gsub("\\|", "|")
    -- Rebuild: replace the note name portion, keep heading/alias if present
    local rest = inner:match("^[^|#^]+(.*)")
    if rest then
      new_link = "[[" .. action._replacement_target .. rest .. "]]"
    else
      new_link = "[[" .. action._replacement_target .. "]]"
    end
  elseif action._replacement_heading then
    -- Replace just the heading anchor
    local inner = link_text:match("^%[%[(.-)%]%]$")
    if not inner then return end
    inner = inner:gsub("\\|", "|")
    -- Find the #heading portion and replace it
    local before_hash = inner:match("^([^#]+)")
    local after_heading = inner:match("#[^|^]+(.*)$") or ""
    new_link = "[[" .. before_hash .. "#" .. action._replacement_heading .. after_heading .. "]]"
  end

  if new_link then
    local new_line = line:sub(1, diag.col) .. new_link .. line:sub(diag.end_col + 1)
    vim.api.nvim_buf_set_lines(bufnr, diag.lnum, diag.lnum + 1, false, { new_line })
    -- Re-validate after fix
    vim.schedule(function() M.validate(bufnr) end)
  end
end

--- Show code actions for the broken link under the cursor via vim.ui.select.
function M.code_action()
  local bufnr = vim.api.nvim_get_current_buf()
  local diags = get_our_diags_at_cursor(bufnr)
  if #diags == 0 then
    vim.notify("Vault: no broken link under cursor", vim.log.levels.INFO)
    return
  end

  local all_actions = {}
  for _, d in ipairs(diags) do
    vim.list_extend(all_actions, actions_for_diag(d, bufnr))
  end

  if #all_actions == 0 then
    vim.notify("Vault: no fix suggestions available", vim.log.levels.INFO)
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
-- :VaultFixLinks -- fzf-lua picker for all broken links in buffer
-- ---------------------------------------------------------------------------

--- Collect all broken link diagnostics in the current buffer with suggested fixes.
--- Opens an fzf-lua picker.
function M.fix_links_picker()
  local bufnr = vim.api.nvim_get_current_buf()
  -- Force a fresh validation
  M.validate(bufnr)

  local diags = vim.diagnostic.get(bufnr, { namespace = M.ns })
  if #diags == 0 then
    vim.notify("Vault: no broken links in buffer", vim.log.levels.INFO)
    return
  end

  -- Build entries: "line:col  message  -> suggestion1, suggestion2, ..."
  local entries = {}
  -- Map from entry string -> list of actions
  local entry_actions = {}

  for _, d in ipairs(diags) do
    local acts = actions_for_diag(d, bufnr)
    local suggestions = {}
    for _, a in ipairs(acts) do
      suggestions[#suggestions + 1] = a.title
    end
    local sug_str = #suggestions > 0
      and " -> " .. table.concat(suggestions, " | ")
      or " (no suggestions)"
    local entry = string.format("%d:%d  %s%s", d.lnum + 1, d.col + 1, d.message, sug_str)
    entries[#entries + 1] = entry
    entry_actions[entry] = { diag = d, actions = acts }
  end

  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    -- Fallback: just list in quickfix
    vim.notify("Vault: fzf-lua not available, listing broken links:", vim.log.levels.WARN)
    for _, e in ipairs(entries) do
      vim.notify("  " .. e, vim.log.levels.WARN)
    end
    return
  end

  fzf.fzf_exec(entries, {
    prompt = "Fix broken links> ",
    actions = {
      ["default"] = function(selected)
        if not selected or not selected[1] then return end
        local sel = selected[1]
        local info = entry_actions[sel]
        if not info then return end

        if #info.actions == 0 then
          -- No suggestions; jump to the diagnostic location
          vim.api.nvim_win_set_cursor(0, { info.diag.lnum + 1, info.diag.col })
          return
        end

        -- Show sub-picker with fix options
        vim.schedule(function()
          vim.ui.select(info.actions, {
            prompt = "Choose fix",
            format_item = function(item) return item.title end,
          }, function(choice)
            if choice then apply_action(choice) end
          end)
        end)
      end,
      ["ctrl-j"] = function(selected)
        -- Jump to the broken link location
        if not selected or not selected[1] then return end
        local lnum = tonumber(selected[1]:match("^(%d+):"))
        if lnum then
          vim.api.nvim_win_set_cursor(0, { lnum, 0 })
        end
      end,
    },
  })
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
  vim.notify("Vault: link diagnostics " .. (M.enabled and "ON" or "OFF"), vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  vim.api.nvim_create_user_command("VaultLinkDiag", function() M.validate() end,
    { desc = "Run link diagnostics on current buffer" })
  vim.api.nvim_create_user_command("VaultLinkDiagToggle", function() M.toggle() end,
    { desc = "Toggle auto link diagnostics" })
  vim.api.nvim_create_user_command("VaultFixLinks", function() M.fix_links_picker() end,
    { desc = "Show broken links with fix suggestions (fzf-lua)" })

  local group = vim.api.nvim_create_augroup("VaultLinkDiag", { clear = true })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group, pattern = "*.md",
    callback = function(ev)
      M._cache.timestamp = 0
      -- Invalidate heading cache for the saved file so re-validation picks up changes
      local saved_path = vim.api.nvim_buf_get_name(ev.buf)
      if saved_path and M._heading_cache[saved_path] then
        M._heading_cache[saved_path] = nil
      end
      if M.enabled then M.validate(ev.buf) end
    end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = group, pattern = "*.md",
    callback = function() M._cache.timestamp = 0 end,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev)
      local name = vim.api.nvim_buf_get_name(ev.buf)
      if not name:find(engine.vault_path, 1, true) then
        vim.diagnostic.set(M.ns, ev.buf, {})
      end
    end,
  })

  vim.api.nvim_create_autocmd("FileType", {
    group = group, pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "<leader>vcd", function() M.toggle() end,
        { buffer = ev.buf, desc = "Check: diagnostics toggle", silent = true })
      vim.keymap.set("n", "<leader>vcf", function() M.code_action() end,
        { buffer = ev.buf, desc = "Check: fix broken link under cursor", silent = true })
      vim.keymap.set("n", "<leader>vcF", function() M.fix_links_picker() end,
        { buffer = ev.buf, desc = "Check: fix all broken links (picker)", silent = true })
    end,
  })
end

return M
