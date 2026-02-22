local engine = require("andrew.vault.engine")

local M = {}

-- Case-insensitive note name cache (lowered basename -> true)
local _name_cache = nil
-- Note path cache (lowered basename -> absolute filepath)
local _path_cache = nil
local _cache_vault = nil

--- Build or return a cache of all note basenames (lowercased, without .md).
---@return table<string, boolean>
local function get_name_cache()
  local vault_path = engine.vault_path
  if _name_cache and _cache_vault == vault_path then
    return _name_cache
  end

  _name_cache = {}
  _path_cache = {}
  _cache_vault = vault_path

  local fd_bin = vim.fn.executable("fd") == 1 and "fd"
    or vim.fn.executable("fdfind") == 1 and "fdfind"
    or nil
  local cmd
  if fd_bin then
    cmd = { fd_bin, "--type", "f", "--extension", "md", "--base-directory", vault_path }
  else
    cmd = { "find", vault_path, "-type", "f", "-name", "*.md" }
  end

  local result = vim.system(cmd, { text = true }):wait()
  if result.code == 0 and result.stdout then
    local use_fd = fd_bin ~= nil
    for line in result.stdout:gmatch("[^\n]+") do
      local basename = vim.fn.fnamemodify(line, ":t:r"):lower()
      _name_cache[basename] = true
      if not _path_cache[basename] then
        -- For fd output, prepend vault_path; for find, it's already absolute
        _path_cache[basename] = use_fd and (vault_path .. "/" .. line) or line
      end
    end
  end

  return _name_cache
end

--- Return the absolute path for a note name (lowercased).
---@param name_lower string
---@return string|nil
local function get_note_path(name_lower)
  get_name_cache()
  return _path_cache and _path_cache[name_lower] or nil
end

--- Convert a heading text to its Obsidian-style slug (matches wikilinks.lua logic).
---@param text string raw heading text
---@return string
local function heading_to_slug(text)
  return text:lower()
    :gsub("[^%w%s%-]", "")
    :gsub("%s", "-")
    :gsub("^%-+", "")
    :gsub("%-+$", "")
end

--- Read headings from a file and return slug set + raw heading list.
---@param filepath string
---@return table<string, boolean> slug_set
---@return string[] raw_headings
local function extract_headings(filepath)
  local slugs = {}
  local headings = {}
  local f = io.open(filepath, "r")
  if not f then return slugs, headings end
  for line in f:lines() do
    local heading_text = line:match("^#+%s+(.*)")
    if heading_text then
      heading_text = heading_text:gsub("%s+$", "")
      headings[#headings + 1] = heading_text
      slugs[heading_to_slug(heading_text)] = true
    end
  end
  f:close()
  return slugs, headings
end

--- Extract wikilink targets from a single line.
--- Returns full structured info: name, heading (if any), and raw display.
---@param line string
---@return {name: string, heading: string|nil, display: string}[]
local function extract_links(line)
  local links = {}
  for inner in line:gmatch("%[%[([^%]]+)%]%]") do
    -- Normalise \| escape used inside markdown tables
    inner = inner:gsub("\\|", "|")
    -- Strip pipe alias: [[Name|Display]] -> target portion
    local target_part = inner:match("^([^|]+)") or inner
    -- Split into note name and optional heading anchor
    local name, heading = target_part:match("^([^#^]+)#([^#^|]+)")
    if not name then
      name = vim.trim((target_part:match("^([^#^|]+)") or target_part))
      heading = nil
    else
      name = vim.trim(name)
      heading = vim.trim(heading)
    end
    if name ~= "" then
      local display = heading and (name .. "#" .. heading) or name
      links[#links + 1] = { name = name, heading = heading, display = display }
    end
  end
  return links
end

--- Check whether a wikilink target resolves to a file in the vault (case-insensitive).
---@param name string the link target (without .md extension)
---@return boolean
local function link_exists(name)
  local cache = get_name_cache()
  return cache[name:lower()] == true
end

--- Scan the current buffer for broken wikilinks (including heading anchors).
--- Shows results in fzf-lua or notifies if all links are healthy.
function M.check_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local broken = {}
  local total = 0
  local self_path = vim.api.nvim_buf_get_name(buf)

  -- Cache heading lookups per file to avoid re-reading
  local heading_cache = {}

  for i, line in ipairs(lines) do
    local links = extract_links(line)
    total = total + #links
    for _, link in ipairs(links) do
      if not link_exists(link.name) then
        broken[#broken + 1] = { lnum = i, display = link.display, kind = "note" }
      elseif link.heading then
        -- Note exists, validate the heading anchor
        local name_lower = link.name:lower()
        local filepath = get_note_path(name_lower)
        -- If linking to self, use the current buffer's file
        local self_name = vim.fn.fnamemodify(self_path, ":t:r"):lower()
        if name_lower == self_name then
          filepath = self_path
        end
        if filepath then
          if not heading_cache[filepath] then
            heading_cache[filepath] = extract_headings(filepath)
          end
          local slug_set = heading_cache[filepath]
          local anchor_slug = heading_to_slug(link.heading)
          if not slug_set[anchor_slug] then
            broken[#broken + 1] = { lnum = i, display = link.display, kind = "heading" }
          end
        end
      end
    end
  end

  if #broken == 0 then
    vim.notify("Vault: all " .. total .. " links OK", vim.log.levels.INFO)
    return
  end

  local entries = {}
  for _, b in ipairs(broken) do
    local kind_label = b.kind == "heading" and " (broken heading)" or " (broken note)"
    entries[#entries + 1] = string.format("%d: [[%s]]%s", b.lnum, b.display, kind_label)
  end

  local fzf = require("fzf-lua")
  fzf.fzf_exec(entries, {
    prompt = "Broken links> ",
    actions = {
      ["default"] = function(selected)
        if selected[1] then
          local lnum = tonumber(selected[1]:match("^(%d+):"))
          if lnum then
            vim.api.nvim_win_set_cursor(0, { lnum, 0 })
          end
        end
      end,
    },
  })
end

--- Scan all markdown files in the vault for broken wikilinks (including heading anchors).
--- Uses ripgrep to find all wikilink patterns, then validates each target.
--- Shows results in fzf-lua in grep-like format (file:line:link).
function M.check_vault()
  vim.notify("Vault: scanning for broken links...", vim.log.levels.INFO)

  local result = vim.system({
    "rg",
    "--no-heading",
    "--line-number",
    "--only-matching",
    "--glob", "*.md",
    "\\[\\[[^\\]]+\\]\\]",
    engine.vault_path,
  }, { text = true }):wait()

  if result.code ~= 0 and result.code ~= 1 then
    vim.notify("Vault: rg failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
    return
  end

  local output = result.stdout or ""
  if output == "" then
    vim.notify("Vault: no wikilinks found in vault", vim.log.levels.INFO)
    return
  end

  -- Cache resolved names and heading lookups to avoid redundant work
  local resolved = {}
  local heading_file_cache = {} -- filepath -> slug_set
  local broken = {}
  local total = 0

  for line in output:gmatch("[^\n]+") do
    -- rg output: /path/to/file.md:42:[[Link Target]]
    local file, lnum, match = line:match("^(.+):(%d+):%[%[(.+)%]%]$")
    if file and lnum and match then
      -- Normalise \| escape used inside markdown tables
      match = match:gsub("\\|", "|")
      local target_part = match:match("^([^|]+)") or match
      local name, heading = target_part:match("^([^#^]+)#([^#^|]+)")
      if not name then
        name = vim.trim((target_part:match("^([^#^|]+)") or target_part))
        heading = nil
      else
        name = vim.trim(name)
        heading = vim.trim(heading)
      end

      if name ~= "" then
        total = total + 1

        -- Check note existence
        if resolved[name] == nil then
          resolved[name] = link_exists(name)
        end

        if not resolved[name] then
          local rel = file:sub(#engine.vault_path + 2)
          local display = heading and (name .. "#" .. heading) or name
          broken[#broken + 1] = string.format("%s:%s: [[%s]] (broken note)", rel, lnum, display)
        elseif heading then
          -- Note exists, check heading anchor
          local name_lower = name:lower()
          local filepath = get_note_path(name_lower)
          -- If linking to self, use the source file
          local self_name = vim.fn.fnamemodify(file, ":t:r"):lower()
          if name_lower == self_name then
            filepath = file
          end
          if filepath then
            if not heading_file_cache[filepath] then
              heading_file_cache[filepath] = extract_headings(filepath)
            end
            local slug_set = heading_file_cache[filepath]
            local anchor_slug = heading_to_slug(heading)
            if not slug_set[anchor_slug] then
              local rel = file:sub(#engine.vault_path + 2)
              broken[#broken + 1] = string.format(
                "%s:%s: [[%s#%s]] (broken heading)", rel, lnum, name, heading
              )
            end
          end
        end
      end
    end
  end

  if #broken == 0 then
    vim.notify("Vault: all " .. total .. " links OK across vault", vim.log.levels.INFO)
    return
  end

  vim.notify(
    "Vault: found " .. #broken .. " broken link(s) out of " .. total,
    vim.log.levels.WARN
  )

  local fzf = require("fzf-lua")
  fzf.fzf_exec(broken, {
    prompt = "Broken vault links> ",
    cwd = engine.vault_path,
    file_icons = true,
    git_icons = false,
    previewer = "builtin",
    actions = {
      ["default"] = fzf.actions.file_edit,
      ["ctrl-s"] = fzf.actions.file_split,
      ["ctrl-v"] = fzf.actions.file_vsplit,
    },
  })
end

--- Find orphan notes (notes with zero inbound links from other notes).
--- Uses ripgrep to scan all wikilinks in the vault, then compares against
--- the full list of notes to find those that are never linked to.
function M.check_orphans()
  vim.notify("Vault: scanning for orphan notes...", vim.log.levels.INFO)

  -- Step 1: Get all markdown files in vault
  local fd_bin = vim.fn.executable("fd") == 1 and "fd"
    or vim.fn.executable("fdfind") == 1 and "fdfind"
    or nil
  local all_cmd
  if fd_bin then
    all_cmd = { fd_bin, "--type", "f", "--extension", "md", "--base-directory", engine.vault_path }
  else
    all_cmd = { "find", engine.vault_path, "-type", "f", "-name", "*.md" }
  end

  local all_result = vim.system(all_cmd, { text = true }):wait()
  if all_result.code ~= 0 then
    vim.notify("Vault: failed to list files", vim.log.levels.ERROR)
    return
  end

  local all_notes = {}
  local use_fd = fd_bin ~= nil
  for line in (all_result.stdout or ""):gmatch("[^\n]+") do
    local rel = use_fd and line or line:sub(#engine.vault_path + 2)
    local basename = vim.fn.fnamemodify(rel, ":t:r"):lower()
    all_notes[basename] = rel
  end

  -- Step 2: Get all wikilink targets across the vault
  local rg_result = vim.system({
    "rg",
    "--no-heading",
    "--no-line-number",
    "--only-matching",
    "--no-filename",
    "--glob", "*.md",
    "\\[\\[[^\\]]+\\]\\]",
    engine.vault_path,
  }, { text = true }):wait()

  local linked = {}
  if rg_result.code == 0 and rg_result.stdout then
    for match in rg_result.stdout:gmatch("%[%[([^%]]+)%]%]") do
      -- Normalise \| escape used inside markdown tables
      local target = match:gsub("\\|", "|"):match("^([^|#]+)") or match
      target = vim.trim(target):lower()
      if target ~= "" then
        linked[target] = true
      end
    end
  end

  -- Step 3: Find notes that are never linked to
  local orphans = {}
  for basename, rel in pairs(all_notes) do
    if not linked[basename] then
      orphans[#orphans + 1] = rel
    end
  end

  table.sort(orphans)

  if #orphans == 0 then
    vim.notify("Vault: no orphan notes found", vim.log.levels.INFO)
    return
  end

  vim.notify(
    "Vault: found " .. #orphans .. " orphan note(s)",
    vim.log.levels.WARN
  )

  local fzf = require("fzf-lua")
  fzf.fzf_exec(orphans, {
    prompt = "Orphan notes> ",
    cwd = engine.vault_path,
    file_icons = true,
    git_icons = false,
    previewer = "builtin",
    actions = {
      ["default"] = fzf.actions.file_edit,
      ["ctrl-s"] = fzf.actions.file_split,
      ["ctrl-v"] = fzf.actions.file_vsplit,
    },
  })
end

function M.setup()
  vim.api.nvim_create_user_command("VaultLinkCheck", function()
    M.check_buffer()
  end, { desc = "Check current buffer for broken wikilinks" })

  vim.api.nvim_create_user_command("VaultLinkCheckAll", function()
    M.check_vault()
  end, { desc = "Check entire vault for broken wikilinks" })

  vim.api.nvim_create_user_command("VaultOrphans", function()
    M.check_orphans()
  end, { desc = "Find orphan notes with no inbound links" })

  local group = vim.api.nvim_create_augroup("VaultLinkCheck", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      -- Check group: <leader>vc
      vim.keymap.set("n", "<leader>vcb", function()
        M.check_buffer()
      end, { buffer = ev.buf, desc = "Check: links (buffer)", silent = true })

      vim.keymap.set("n", "<leader>vca", function()
        M.check_vault()
      end, { buffer = ev.buf, desc = "Check: links (vault)", silent = true })

      vim.keymap.set("n", "<leader>vco", function()
        M.check_orphans()
      end, { buffer = ev.buf, desc = "Check: orphans", silent = true })
    end,
  })

  -- Invalidate name cache when files are created/deleted
  vim.api.nvim_create_autocmd({ "BufWritePost", "BufDelete" }, {
    group = group,
    pattern = "*.md",
    callback = function()
      _name_cache = nil
      _path_cache = nil
    end,
  })
end

return M
