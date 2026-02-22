local engine = require("andrew.vault.engine")
local link_utils = require("andrew.vault.link_utils")

local M = {}

local cache = {}
local cache_valid = false
local cache_vault = nil

--- Read aliases from a markdown file's frontmatter.
--- Handles both inline (aliases: [a, b]) and list formats.
---@param path string
---@return string[]|nil
local function read_aliases(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local first = f:read("*l")
  if not first or first ~= "---" then
    f:close()
    return nil
  end
  local alias_list = nil
  local cur_key = nil
  while true do
    local line = f:read("*l")
    if not line or line == "---" then break end
    local list_item = line:match("^%s+-%s+(.+)$")
    if list_item and cur_key == "aliases" then
      if not alias_list then alias_list = {} end
      list_item = vim.trim(list_item):gsub("^['\"]", ""):gsub("['\"]$", "")
      if list_item ~= "" then
        alias_list[#alias_list + 1] = list_item
      end
    else
      local key, val = line:match("^(%w[%w_-]*):%s*(.*)$")
      if key then
        cur_key = key
        if key == "aliases" and val and val ~= "" then
          val = val:gsub("^%[", ""):gsub("%]$", "")
          alias_list = {}
          for alias in val:gmatch("[^,]+") do
            alias = vim.trim(alias):gsub("^['\"]", ""):gsub("['\"]$", "")
            if alias ~= "" then
              alias_list[#alias_list + 1] = alias
            end
          end
        end
      end
    end
  end
  f:close()
  return alias_list
end

local function build_cache()
  cache = {}
  local vault_path = engine.vault_path
  cache_vault = vault_path
  local files = vim.fs.find(function(name)
    return name:match("%.md$")
  end, { path = vault_path, type = "file", limit = math.huge })
  for _, path in ipairs(files) do
    local basename = vim.fn.fnamemodify(path, ":t:r"):lower()
    if not cache[basename] then
      cache[basename] = {}
    end
    table.insert(cache[basename], path)

    -- Index by frontmatter aliases
    local aliases = read_aliases(path)
    if aliases then
      for _, alias in ipairs(aliases) do
        local key = alias:lower()
        if key ~= basename then
          if not cache[key] then
            cache[key] = {}
          end
          table.insert(cache[key], path)
        end
      end
    end
  end
  cache_valid = true
end

function M.invalidate_cache()
  cache_valid = false
end

local function ensure_cache()
  if not cache_valid or cache_vault ~= engine.vault_path then
    build_cache()
  end
end

local function get_wikilink_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1

  local start = 1
  while true do
    local open_start, open_end = line:find("%[%[", start)
    if not open_start then
      return nil
    end
    local close_start, close_end = line:find("%]%]", open_end + 1)
    if not close_start then
      return nil
    end
    if col >= open_start and col <= close_end then
      local inner = line:sub(open_end + 1, close_start - 1)
      -- Normalise \| escape used inside markdown tables
      inner = inner:gsub("\\|", "|")
      -- Strip alias, heading anchor, and block reference:
      -- [[note#heading^block|alias]] -> note
      local link = inner:match("^([^|#%^]+)") or inner
      return vim.trim(link)
    end
    start = close_end + 1
  end
end

--- Parse the wikilink under the cursor into its components.
--- Returns a table with name, heading, and block_id fields, or nil.
---@return {name: string, heading: string|nil, block_id: string|nil}|nil
local function get_wikilink_details_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1

  local start = 1
  while true do
    local open_start, open_end = line:find("%[%[", start)
    if not open_start then
      return nil
    end
    local close_start, close_end = line:find("%]%]", open_end + 1)
    if not close_start then
      return nil
    end
    if col >= open_start and col <= close_end then
      local inner = line:sub(open_end + 1, close_start - 1)
      return link_utils.parse_target(inner)
    end
    start = close_end + 1
  end
end

--- Find a block reference (^block-id) in a file.
--- Returns the 1-indexed line number if found, nil otherwise.
---@param path string absolute file path
---@param block_id string the block identifier (without the ^ prefix)
---@return number|nil
local function find_block_in_file(path, block_id)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local line_num = 0
  for line in f:lines() do
    line_num = line_num + 1
    -- Block IDs appear as ^identifier at the end of a line
    if line:match("%^" .. vim.pesc(block_id) .. "%s*$") then
      f:close()
      return line_num
    end
  end
  f:close()
  return nil
end

local function resolve_link(link_name)
  ensure_cache()
  local key = link_name:lower()
  local paths = cache[key]
  if not paths or #paths == 0 then
    return nil
  end
  if #paths == 1 then
    return paths[1]
  end
  -- Multiple matches: pick the closest to the current buffer's directory
  local current_dir = vim.fn.expand("%:p:h")
  local best_path = paths[1]
  local best_score = math.huge
  for _, path in ipairs(paths) do
    local dir = vim.fn.fnamemodify(path, ":h")
    local common = 0
    for i = 1, math.min(#dir, #current_dir) do
      if dir:sub(i, i) == current_dir:sub(i, i) then
        common = common + 1
      else
        break
      end
    end
    local score = (#dir - common) + (#current_dir - common)
    if score < best_score then
      best_score = score
      best_path = path
    end
  end
  return best_path
end

--- Get markdown link [text](destination) under cursor.
--- Falls back to closest link on line when conceal shifts cursor positions.
---@return string|nil destination portion of the link
local function get_mdlink_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1

  local closest_dest = nil
  local closest_dist = math.huge
  local start = 1
  while true do
    local s, e, dest = line:find("%[.-%]%((.-)%)", start)
    if not s then
      break
    end
    -- Exact match: cursor inside the link span
    if col >= s and col <= e then
      return dest
    end
    -- Track closest link as fallback (handles concealed offsets)
    local dist = math.min(math.abs(col - s), math.abs(col - e))
    if dist < closest_dist then
      closest_dist = dist
      closest_dest = dest
    end
    start = e + 1
  end

  -- If no exact match but a link exists nearby on this line, use it
  if closest_dest and closest_dist <= 5 then
    return closest_dest
  end
  return nil
end

--- Get bare URL under cursor.
---@return string|nil
local function get_url_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local pattern = "https?://[%w%-%.%_%~%:%/%?#%[%]@!%$&'%(%)%*%+,;=%%]+"
  local start = 1
  while true do
    local s, e = line:find(pattern, start)
    if not s then
      return nil
    end
    if col >= s and col <= e then
      return line:sub(s, e)
    end
    start = e + 1
  end
end

local function follow_link()
  -- 1) Wikilink: [[target]] or [[target|alias]] or [[target#heading]] or [[target^block-id]]
  local details = get_wikilink_details_under_cursor()
  if details then
    -- Same-file reference: [[#heading]] or [[^block-id]]
    if details.name == "" and (details.heading or details.block_id) then
      if details.heading then
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local heading_slug = details.heading:lower()
          :gsub("[^%w%s%-]", "")
          :gsub("%s", "-")
          :gsub("^%-+", "")
          :gsub("%-+$", "")
        for i, l in ipairs(lines) do
          local heading_text = l:match("^#+%s+(.*)")
          if heading_text then
            local slug = heading_text:lower()
              :gsub("[^%w%s%-]", "")
              :gsub("%s", "-")
              :gsub("^%-+", "")
              :gsub("%-+$", "")
            if slug == heading_slug then
              vim.api.nvim_win_set_cursor(0, { i, 0 })
              vim.cmd("normal! zz")
              return
            end
          end
        end
        vim.notify("Heading not found: #" .. details.heading, vim.log.levels.WARN)
      elseif details.block_id then
        local path = vim.api.nvim_buf_get_name(0)
        local block_line = find_block_in_file(path, details.block_id)
        if block_line then
          vim.api.nvim_win_set_cursor(0, { block_line, 0 })
          vim.cmd("normal! zz")
        else
          vim.notify("Block not found: ^" .. details.block_id, vim.log.levels.WARN)
        end
      end
      return
    end

    -- Normal cross-file wikilink
    if details.name ~= "" then
      local link = details.name
      local path = resolve_link(link)
      if path then
        vim.cmd("edit " .. vim.fn.fnameescape(path))

        -- Jump to heading if specified
        if details.heading then
          local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
          local heading_slug = details.heading:lower()
            :gsub("[^%w%s%-]", "")
            :gsub("%s", "-")
            :gsub("^%-+", "")
            :gsub("%-+$", "")
          for i, l in ipairs(lines) do
            local heading_text = l:match("^#+%s+(.*)")
            if heading_text then
              local slug = heading_text:lower()
                :gsub("[^%w%s%-]", "")
                :gsub("%s", "-")
                :gsub("^%-+", "")
                :gsub("%-+$", "")
              if slug == heading_slug then
                vim.api.nvim_win_set_cursor(0, { i, 0 })
                vim.cmd("normal! zz")
                break
              end
            end
          end
        end

        -- Jump to block reference if specified
        if details.block_id then
          local block_line = find_block_in_file(path, details.block_id)
          if block_line then
            vim.api.nvim_win_set_cursor(0, { block_line, 0 })
            vim.cmd("normal! zz")
          else
            vim.notify("Block not found: ^" .. details.block_id, vim.log.levels.WARN)
          end
        end
      else
        -- Create new notes in the same directory as the current buffer (Obsidian behavior)
        local buf_dir = vim.fn.expand("%:p:h")
        local new_path
        if engine.is_vault_path(buf_dir) then
          new_path = buf_dir .. "/" .. link .. ".md"
        else
          new_path = engine.vault_path .. "/" .. link .. ".md"
        end
        local dir = vim.fn.fnamemodify(new_path, ":h")
        vim.fn.mkdir(dir, "p")
        vim.cmd("edit " .. vim.fn.fnameescape(new_path))
        local key = link:lower()
        if not cache[key] then
          cache[key] = {}
        end
        table.insert(cache[key], new_path)
        vim.notify("Created: " .. link .. ".md", vim.log.levels.INFO)
      end
      return
    end
  end

  -- 2) Markdown link: [text](url-or-path) or [text](#anchor)
  local dest = get_mdlink_under_cursor()
  if dest then
    if dest:match("^https?://") then
      vim.ui.open(dest)
    else
      -- Split into file path and anchor: "file.md#anchor" or "#anchor"
      local file_part, anchor = dest:match("^(.-)#(.+)$")
      if not anchor then
        file_part = dest
      end

      -- Navigate to file if specified
      if file_part and file_part ~= "" then
        local buf_dir = vim.fn.expand("%:p:h")
        local target = buf_dir .. "/" .. file_part
        if vim.fn.filereadable(target) == 1 then
          vim.cmd("edit " .. vim.fn.fnameescape(target))
        else
          vim.notify("File not found: " .. file_part, vim.log.levels.WARN)
          return
        end
      end

      -- Jump to anchor heading if present
      if anchor then
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        for i, line in ipairs(lines) do
          local heading_text = line:match("^#+%s+(.*)")
          if heading_text then
            -- Convert heading to slug: lowercase, spaces/special chars to hyphens
            local slug = heading_text:lower()
              :gsub("[^%w%s%-]", "")
              :gsub("%s", "-")
              :gsub("^%-+", "")
              :gsub("%-+$", "")
            if slug == anchor then
              vim.api.nvim_win_set_cursor(0, { i, 0 })
              vim.cmd("normal! zz")
              return
            end
          end
        end
        vim.notify("Heading not found: #" .. anchor, vim.log.levels.WARN)
      end
    end
    return
  end

  -- 3) Bare URL under cursor
  local url = get_url_under_cursor()
  if url then
    vim.ui.open(url)
    return
  end

  -- 4) Fall back to normal gf
  local ok, _ = pcall(vim.cmd, "normal! gF")
  if not ok then
    pcall(vim.cmd, "normal! gf")
  end
end

--- Jump to the next or previous link in the buffer.
--- Finds both wikilinks ([[...]]) and markdown links ([text](url)).
---@param direction 1|-1  forward (1) or backward (-1)
local function jump_link(direction)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local cur_row, cur_col = unpack(vim.api.nvim_win_get_cursor(0))
  cur_col = cur_col + 1 -- 1-indexed

  -- Collect all link positions: { row (1-indexed), col (1-indexed) }
  local links = {}
  for i, line in ipairs(lines) do
    -- Find wikilinks: [[...]]
    local start = 1
    while true do
      local s = line:find("%[%[", start)
      if not s then break end
      table.insert(links, { row = i, col = s })
      start = s + 2
    end
    -- Find markdown links: [text](url) — but skip wikilinks (preceded by [)
    start = 1
    while true do
      local s = line:find("%[.-%]%(.-%)", start)
      if not s then break end
      -- Skip if this is part of a wikilink (preceded by another [)
      if s > 1 and line:sub(s - 1, s - 1) == "[" then
        start = s + 1
      else
        table.insert(links, { row = i, col = s })
        start = s + 1
      end
    end
  end

  if #links == 0 then
    return
  end

  -- Sort by position (row, then col) since we collected two types
  table.sort(links, function(a, b)
    if a.row ~= b.row then return a.row < b.row end
    return a.col < b.col
  end)

  if direction == 1 then
    for _, link in ipairs(links) do
      if link.row > cur_row or (link.row == cur_row and link.col > cur_col) then
        vim.api.nvim_win_set_cursor(0, { link.row, link.col - 1 })
        return
      end
    end
    -- Wrap to first link
    vim.api.nvim_win_set_cursor(0, { links[1].row, links[1].col - 1 })
  else
    for i = #links, 1, -1 do
      local link = links[i]
      if link.row < cur_row or (link.row == cur_row and link.col < cur_col) then
        vim.api.nvim_win_set_cursor(0, { link.row, link.col - 1 })
        return
      end
    end
    -- Wrap to last link
    local last = links[#links]
    vim.api.nvim_win_set_cursor(0, { last.row, last.col - 1 })
  end
end

function M.setup()
  build_cache()

  local group = vim.api.nvim_create_augroup("VaultWikilinks", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "gf", follow_link, {
        buffer = ev.buf,
        desc = "Vault: follow link (wiki/markdown/URL)",
        silent = true,
      })
      vim.keymap.set("n", "gx", follow_link, {
        buffer = ev.buf,
        desc = "Vault: open link in browser or follow",
        silent = true,
      })
      vim.keymap.set("n", "]o", function()
        jump_link(1)
      end, {
        buffer = ev.buf,
        desc = "Vault: next link",
        silent = true,
      })
      vim.keymap.set("n", "[o", function()
        jump_link(-1)
      end, {
        buffer = ev.buf,
        desc = "Vault: previous link",
        silent = true,
      })
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      local bufpath = vim.api.nvim_buf_get_name(ev.buf)
      if engine.is_vault_path(bufpath) then
        M.invalidate_cache()
      end
    end,
  })
end

-- Expose for use by other vault modules (embed, preview, etc.)
M.resolve_link = resolve_link
M.find_block_in_file = find_block_in_file

return M
