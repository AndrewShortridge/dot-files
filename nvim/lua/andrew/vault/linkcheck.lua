local engine = require("andrew.vault.engine")
local link_utils = require("andrew.vault.link_utils")
local vault_index = require("andrew.vault.vault_index")
local block_patterns = require("andrew.vault.block_patterns")
local file_cache = require("andrew.vault.file_cache")
local notify = require("andrew.vault.notify")
local log = require("andrew.vault.vault_log").scope("linkcheck")
local semaphore = require("andrew.vault.process_semaphore")
local pat = require("andrew.vault.patterns")

local M = {}

--- fzf action: jump to the line number parsed from the selected item.
--- Expects entries formatted as "123: ..." where the leading number is the line.
---@param selected string[]
local function fzf_jump_to_line(selected)
  if selected[1] then
    local lnum = tonumber(selected[1]:match("^(%d+):"))
    if lnum then
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    end
  end
end

--- Classify a URL validation result and return a label if it is dead/error.
---@param r {entry: {url: string}, result: {status: number, error: string|nil}}
---@return string|nil label  non-nil when the URL is dead or errored
local function dead_url_label(r)
  local url_validate = require("andrew.vault.url_validate")
  local class = url_validate.classify_status(r.result.status)
  if class == "dead" or class == "error" then
    return r.result.error or ("HTTP " .. r.result.status)
  end
  return nil
end

--- Return the absolute path for a note name (lowercased).
---@param name_lower string
---@return string|nil
local function get_note_path(name_lower)
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then return nil end
  local paths = idx:resolve_name(name_lower)
  if paths and #paths > 0 then return paths[1] end
  -- Also try basename in case name_lower includes a path prefix
  local basename = link_utils.get_tail(name_lower)
  if basename ~= name_lower then
    paths = idx:resolve_name(basename)
    if paths and #paths > 0 then return paths[1] end
  end
  return nil
end

--- Extract wikilink targets from a single line (excluding embeds).
--- Returns full structured info: name, heading (if any), block_id (if any), and raw display.
---@param line string
---@return {name: string, heading: string|nil, block_id: string|nil, display: string}[]
local function extract_links(line)
  local links = {}
  for _, link in ipairs(link_utils.extract_line_links(line)) do
    -- Skip embeds — linkcheck only validates regular wikilinks
    if link.embed then goto continue end

    -- Build display string for diagnostics
    local display = link.name
    if link.heading then display = display .. "#" .. link.heading end
    if link.block_id then display = display .. "^" .. link.block_id end

    -- Include self-referencing links (name == "") if they have a heading or block_id
    if link.name ~= "" or link.heading or link.block_id then
      links[#links + 1] = {
        name = link.name,
        heading = link.heading,
        block_id = link.block_id,
        display = display,
      }
    end

    ::continue::
  end
  return links
end

--- Scan buffer lines for block IDs, returning a set.
---@param lines string[]
---@return table<string, boolean>
local function scan_buffer_block_ids(lines)
  return block_patterns.id_set_from_lines(lines)
end

--- Resolve heading slugs for a filepath, using cache.
--- For self_path when idx is unavailable, pass buffer_lines to extract from live buffer.
---@param filepath string
---@param heading_cache table<string, table<string, boolean>>
---@param idx VaultIndex|nil
---@param use_idx boolean
---@param buffer_lines string[]|nil live buffer lines (only used when filepath == self_path and no idx)
---@return table<string, boolean> slug_set
local function resolve_headings(filepath, heading_cache, idx, use_idx, buffer_lines)
  if not heading_cache[filepath] then
    if use_idx then
      heading_cache[filepath] = idx:get_headings(filepath)
    elseif buffer_lines then
      heading_cache[filepath] = link_utils.extract_headings(buffer_lines)
    else
      heading_cache[filepath] = link_utils.extract_headings(filepath)
    end
  end
  return heading_cache[filepath]
end

--- Resolve block IDs for a filepath, using cache.
---@param filepath string
---@param block_id_cache table<string, table<string, boolean>>
---@param idx VaultIndex|nil
---@param use_idx boolean
---@param self_path string|nil current buffer path
---@param self_block_ids table<string, boolean>|nil pre-scanned block IDs for self_path
---@return table<string, boolean> block_id_set
local function resolve_block_ids(filepath, block_id_cache, idx, use_idx, self_path, self_block_ids)
  if not block_id_cache[filepath] then
    if self_path and filepath == self_path then
      block_id_cache[filepath] = self_block_ids or {}
    elseif use_idx then
      block_id_cache[filepath] = idx:get_block_ids(filepath)
    else
      -- Fallback: read file and scan for block IDs
      local lines = file_cache.read(filepath)
      if lines then
        local content = table.concat(lines, "\n")
        block_id_cache[filepath] = block_patterns.id_set_from_content(content)
      else
        log.debug("failed to open file for block ID scan: %s", filepath)
        block_id_cache[filepath] = {}
      end
    end
  end
  return block_id_cache[filepath]
end

--- Check whether a wikilink target resolves to a file in the vault (case-insensitive).
---@param name string the link target (without .md extension)
---@return boolean
local function link_exists(name)
  return get_note_path(name:lower()) ~= nil
end

--- Scan the current buffer for broken wikilinks (including heading anchors and block refs).
--- Shows results in fzf-lua or notifies if all links are healthy.
function M.check_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local broken = {}
  local total = 0
  local block_ref_count = 0
  local self_path = vim.api.nvim_buf_get_name(buf)

  -- Cache heading lookups per file to avoid re-reading
  local heading_cache = {}
  -- Cache block ID lookups per file
  local block_id_cache = {}
  local idx = vault_index.current()
  local use_idx = idx and idx:is_ready()

  -- Pre-scan current buffer for same-file block ID validation
  local self_block_ids = scan_buffer_block_ids(lines)

  for i, line in ipairs(lines) do
    local links = extract_links(line)
    total = total + #links
    for _, link in ipairs(links) do
      if link.block_id then
        block_ref_count = block_ref_count + 1
      end

      -- Self-referencing link (name == "")
      if link.name == "" then
        if link.heading then
          local slug_set = resolve_headings(self_path, heading_cache, idx, use_idx, lines)
          local anchor_slug = link_utils.heading_to_slug(link.heading)
          if not slug_set[anchor_slug] then
            broken[#broken + 1] = { lnum = i, display = link.display, kind = "heading" }
            goto next_link
          end
        end
        if link.block_id then
          if not self_block_ids[link.block_id] then
            broken[#broken + 1] = { lnum = i, display = link.display, kind = "block" }
          end
        end
        goto next_link
      end

      -- Cross-file link: check note existence first
      if not link_exists(link.name) then
        broken[#broken + 1] = { lnum = i, display = link.display, kind = "note" }
        goto next_link
      end

      -- Note exists; resolve filepath for heading/block validation
      local name_lower = link.name:lower()
      local filepath = get_note_path(name_lower)
      local self_name = link_utils.get_basename(self_path):lower()
      if name_lower == self_name then
        filepath = self_path
      end

      if filepath then
        if link.heading then
          local slug_set = resolve_headings(filepath, heading_cache, idx, use_idx, nil)
          local anchor_slug = link_utils.heading_to_slug(link.heading)
          if not slug_set[anchor_slug] then
            broken[#broken + 1] = { lnum = i, display = link.display, kind = "heading" }
            goto next_link
          end
        end

        if link.block_id then
          local bid_set = resolve_block_ids(filepath, block_id_cache, idx, use_idx, self_path, self_block_ids)
          if not bid_set[link.block_id] then
            broken[#broken + 1] = { lnum = i, display = link.display, kind = "block" }
          end
        end
      end

      ::next_link::
    end
  end

  if #broken == 0 then
    local msg = "all " .. total .. " links OK"
    if block_ref_count > 0 then
      msg = msg .. " (" .. block_ref_count .. " block ref" .. (block_ref_count ~= 1 and "s" or "") .. ")"
    end
    notify.info(msg)
    return
  end

  local entries = {}
  for _, b in ipairs(broken) do
    local kind_label
    if b.kind == "heading" then
      kind_label = " (broken heading)"
    elseif b.kind == "block" then
      kind_label = " (broken block)"
    else
      kind_label = " (broken note)"
    end
    entries[#entries + 1] = string.format("%d: [[%s]]%s", b.lnum, b.display, kind_label)
  end

  require("fzf-lua").fzf_exec(entries, {
    prompt = "Broken links> ",
    actions = {
      ["default"] = fzf_jump_to_line,
    },
  })
end

--- Scan all markdown files in the vault for broken wikilinks.
--- Runs ripgrep async and calls `callback` with an array of structured entries.
--- Each entry: { file: string, lnum: number, target: string, heading: string|nil,
---   block_id: string|nil, filepath: string|nil, type: "broken_note"|"broken_heading"|"broken_block" }
---@param callback fun(broken_links: table[], total: number)
function M.scan_broken_links(callback)
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    notify.index_not_ready_rebuild()
    return
  end

  semaphore.acquire(semaphore.rg_semaphore(), function(release)
    vim.system({
      "rg",
      "--no-heading",
      "--line-number",
      "--only-matching",
      "--glob", "*.md",
      "\\[\\[[^\\]]+\\]\\]",
      engine.vault_path,
    }, { text = true }, function(result)
      release()
      vim.schedule(function()
        if result.code ~= 0 and result.code ~= 1 then
          notify.error("rg failed: " .. (result.stderr or ""))
          return
        end

        local output = result.stdout or ""
        if output == "" then
          callback({}, 0)
          return
        end

        -- Cache resolved names and heading/block lookups to avoid redundant work
        local resolved = {}
        local heading_file_cache = {} -- filepath -> slug_set
        local block_id_file_cache = {} -- filepath -> block_id_set
        local broken = {}
        local total = 0

        for line in output:gmatch(pat.LINE_NONEMPTY) do
          -- rg output: /path/to/file.md:42:[[Link Target]]
          local file, lnum_str, match = line:match("^(.+):(%d+):%[%[(.+)%]%]$")
          if not file or not lnum_str or not match then goto next_match end

          -- Skip embed links (![[...]])
          local prefix_check = line:match(":(%!?)%[%[")
          if prefix_check == "!" then goto next_match end

          local parsed = link_utils.parse_target(match)
          local name = parsed.name
          local heading = parsed.heading
          local block_id = parsed.block_id

          -- Skip self-referencing links in vault-wide scan
          if name == "" then goto next_match end

          total = total + 1
          local lnum = tonumber(lnum_str)

          -- Check note existence
          if resolved[name] == nil then
            resolved[name] = link_exists(name)
          end

          if not resolved[name] then
            broken[#broken + 1] = {
              file = file,
              lnum = lnum,
              target = name,
              heading = heading,
              block_id = block_id,
              filepath = nil,
              type = "broken_note",
            }
          else
            -- Note exists; resolve filepath for heading/block validation
            local name_lower = name:lower()
            local filepath = get_note_path(name_lower)
            local self_name = link_utils.get_basename(file):lower()
            if name_lower == self_name then
              filepath = file
            end

            if filepath then
              local heading_broken = false
              if heading then
                local slug_set = resolve_headings(filepath, heading_file_cache, idx, true, nil)
                local anchor_slug = link_utils.heading_to_slug(heading)
                if not slug_set[anchor_slug] then
                  heading_broken = true
                  broken[#broken + 1] = {
                    file = file,
                    lnum = lnum,
                    target = name,
                    heading = heading,
                    block_id = block_id,
                    filepath = filepath,
                    type = "broken_heading",
                  }
                end
              end

              if block_id and not heading_broken then
                local bid_set = resolve_block_ids(filepath, block_id_file_cache, idx, true, nil, nil)
                if not bid_set[block_id] then
                  broken[#broken + 1] = {
                    file = file,
                    lnum = lnum,
                    target = name,
                    heading = heading,
                    block_id = block_id,
                    filepath = filepath,
                    type = "broken_block",
                  }
                end
              end
            end
          end

          ::next_match::
        end

        callback(broken, total)
      end)
    end)
  end)
end

--- Scan all markdown files in the vault for broken wikilinks (including heading anchors).
--- Uses ripgrep to find all wikilink patterns, then validates each target.
--- Shows results in fzf-lua in grep-like format (file:line:link).
function M.check_vault()
  notify.info("scanning for broken links...")

  M.scan_broken_links(function(broken_links, total)
    if #broken_links == 0 then
      notify.info("all " .. total .. " links OK across vault")
      return
    end

    -- Format structured entries into display strings for fzf
    local entries = {}
    for _, b in ipairs(broken_links) do
      local rel = b.file:sub(#engine.vault_path + 2)
      local display = b.target
      if b.heading then display = display .. "#" .. b.heading end
      if b.block_id then display = display .. "^" .. b.block_id end

      local kind_label
      if b.type == "broken_heading" then
        kind_label = "broken heading"
      elseif b.type == "broken_block" then
        kind_label = "broken block"
      else
        kind_label = "broken note"
      end
      entries[#entries + 1] = string.format("%s:%d: [[%s]] (%s)", rel, b.lnum, display, kind_label)
    end

    notify.info("found " .. #broken_links .. " broken link(s) out of " .. total)

    require("fzf-lua").fzf_exec(entries, engine.vault_fzf_opts("Broken vault links", {
      previewer = "builtin",
      actions = engine.vault_fzf_actions(),
    }))
  end)
end

--- Find orphan notes (notes with zero inbound links from other notes).
--- Uses the vault index _inlinks map to detect notes that are never linked to.
function M.check_orphans()
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    notify.index_not_ready_rebuild()
    return
  end

  local orphans = {}
  local snap = idx:snapshot()
  for rel_path, _ in pairs(snap.files) do
    local inlinks = snap._inlinks[rel_path]
    if not inlinks or #inlinks == 0 then
      orphans[#orphans + 1] = rel_path
    end
  end

  table.sort(orphans)

  if #orphans == 0 then
    notify.info("no orphan notes found")
    return
  end

  notify.info("found " .. #orphans .. " orphan note(s)")

  require("fzf-lua").fzf_exec(orphans, engine.vault_fzf_opts("Orphan notes", {
    previewer = "builtin",
    actions = engine.vault_fzf_actions(),
  }))
end

--- Scan the current buffer for dead external URLs.
function M.check_urls_buffer()
  local url_validate = require("andrew.vault.url_validate")
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local url_entries = url_validate.extract_urls(lines)

  if #url_entries == 0 then
    notify.info("no external URLs found in buffer")
    return
  end

  notify.info("checking " .. #url_entries .. " URL(s)...")

  local dead = {}
  url_validate.validate_batch(url_entries,
    nil,
    function(results)
      for _, r in ipairs(results) do
        local label = dead_url_label(r)
        if label then
          dead[#dead + 1] = string.format(
            "%d: %s [%s]", r.entry.lnum, r.entry.url, label
          )
        end
      end

      if #dead == 0 then
        notify.info("all " .. #url_entries .. " URLs OK")
        return
      end

      notify.info(#dead .. " dead URL(s) found")

      require("fzf-lua").fzf_exec(dead, {
        prompt = "Dead URLs> ",
        actions = {
          ["default"] = fzf_jump_to_line,
        },
      })
    end
  )
end

--- Scan entire vault for dead external URLs.
function M.check_urls_vault()
  local url_validate = require("andrew.vault.url_validate")
  notify.info("scanning vault for external URLs...")

  semaphore.acquire(semaphore.rg_semaphore(), function(release)
    vim.system({
      "rg",
      "--no-heading",
      "--line-number",
      "--only-matching",
      "--glob", "*.md",
      "https?://[\\w\\-\\.\\~\\:\\/\\?#\\[\\]@!\\$&'\\(\\)\\*\\+,;=%]+",
      engine.vault_path,
    }, { text = true }, function(result)
      release()
      vim.schedule(function()
        if result.code ~= 0 and result.code ~= 1 then
          notify.error("rg failed")
          return
        end

        local unique_urls = {}
        local url_locations = {}

        for line in (result.stdout or ""):gmatch(pat.LINE_NONEMPTY) do
          local file, lnum, url = line:match("^(.+):(%d+):(.+)$")
          if url then
            if not url_locations[url] then
              url_locations[url] = {}
              unique_urls[#unique_urls + 1] = {
                url = url, lnum = 0, col = 0, end_col = 0,
              }
            end
            url_locations[url][#url_locations[url] + 1] = {
              file = file, lnum = tonumber(lnum),
            }
          end
        end

        notify.info("checking " .. #unique_urls .. " unique URL(s)...")

        url_validate.validate_batch(unique_urls, nil, function(results)
          local dead = {}
          for _, r in ipairs(results) do
            local label = dead_url_label(r)
            if label then
              for _, loc in ipairs(url_locations[r.entry.url] or {}) do
                local rel = loc.file:sub(#engine.vault_path + 2)
                dead[#dead + 1] = string.format(
                  "%s:%d: %s [%s]", rel, loc.lnum, r.entry.url, label
                )
              end
            end
          end

          if #dead == 0 then
            notify.info("all URLs OK across vault")
            return
          end

          notify.info(#dead .. " dead URL reference(s) found")

          require("fzf-lua").fzf_exec(dead, engine.vault_fzf_opts("Dead URLs", {
            previewer = "builtin",
            actions = engine.vault_fzf_actions(),
          }))
        end)
      end)
    end)
  end)
end

return M
