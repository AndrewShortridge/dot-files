local engine = require("andrew.vault.engine")

local source = {}

local cached_items = nil
local cached_vault = nil
local building = false
local build_generation = 0

local function parse_frontmatter(path)
  local f = io.open(path, "r")
  if not f then return nil end

  local first = f:read("*l")
  if not first or first ~= "---" then
    f:close()
    return nil
  end

  local fm = {}
  local cur_key = nil
  local cur_list = nil

  while true do
    local line = f:read("*l")
    if not line or line == "---" then break end

    local list_item = line:match("^%s+-%s+(.+)$")
    if list_item and cur_key then
      if not cur_list then cur_list = {} end
      cur_list[#cur_list + 1] = list_item
      fm[cur_key] = table.concat(cur_list, ", ")
    else
      local key, val = line:match("^(%w[%w_-]*):%s*(.*)$")
      if key then
        cur_key = key
        cur_list = nil
        if val and val ~= "" then
          val = val:gsub("^%[", ""):gsub("%]$", ""):gsub("^'", ""):gsub("'$", ""):gsub('^"', ""):gsub('"$', "")
          fm[key] = val
        end
      end
    end
  end

  f:close()
  return fm
end

local function read_lines(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local lines = {}
  for line in f:lines() do
    lines[#lines + 1] = line
  end
  f:close()
  return lines
end

local function get_blocks(lines)
  local blocks = {}
  for i, line in ipairs(lines) do
    local block_id = line:match("%^([%w%-]+)%s*$")
    if block_id then
      local text = line:gsub("%s*%^[%w%-]+%s*$", "")
      blocks[#blocks + 1] = { id = block_id, text = text, line = i }
    end
  end
  return blocks
end

local function get_headings(lines)
  local headings = {}
  local in_fm = false
  local order = 0

  for i, line in ipairs(lines) do
    if i == 1 and line == "---" then
      in_fm = true
    elseif in_fm and line == "---" then
      in_fm = false
    elseif not in_fm then
      local level, text = line:match("^(#+)%s+(.+)")
      if text then
        order = order + 1
        -- Capture content preview: up to 8 non-empty lines until next heading
        local preview = {}
        for j = i + 1, math.min(i + 20, #lines) do
          if lines[j]:match("^#+%s+") then break end
          if lines[j] ~= "" then
            preview[#preview + 1] = lines[j]
            if #preview >= 8 then break end
          end
        end
        headings[#headings + 1] = {
          text = text,
          level = #level,
          line = i,
          order = order,
          preview = table.concat(preview, "\n"),
        }
      end
    end
  end

  return headings
end

local function build_description(fm, rel)
  if not fm then return rel end
  local parts = {}
  if fm.type then parts[#parts + 1] = fm.type end
  if fm.tags and fm.tags ~= "" then parts[#parts + 1] = fm.tags end
  if #parts > 0 then
    return table.concat(parts, " | ") .. " — " .. rel
  end
  return rel
end

local function build_items_async(callback)
  if building then return end
  building = true

  local gen = build_generation
  local vault_path = engine.vault_path
  local fd_bin = vim.fn.executable("fd") == 1 and "fd"
    or vim.fn.executable("fdfind") == 1 and "fdfind"
    or nil
  local cmd
  if fd_bin then
    cmd = { fd_bin, "--type", "f", "--extension", "md", "--base-directory", vault_path }
  else
    cmd = { "find", vault_path, "-type", "f", "-name", "*.md" }
  end
  local use_fd = fd_bin ~= nil

  vim.system(cmd, { text = true }, function(out)
    vim.schedule(function()
      building = false
      if gen ~= build_generation then
        -- Cache was invalidated during build; discard stale results
        if callback then callback({}) end
        return
      end
      if out.code ~= 0 or not out.stdout then
        if callback then callback({}) end
        return
      end

      local items = {}
      for line in out.stdout:gmatch("[^\r\n]+") do
        local rel = line
        if not use_fd then
          rel = line:sub(#vault_path + 2)
        end

        local name = rel:gsub("%.md$", "")
        local basename = vim.fn.fnamemodify(name, ":t")
        local abs_path = use_fd and (vault_path .. "/" .. rel) or line

        local stat = vim.uv.fs_stat(abs_path)
        local mtime = stat and stat.mtime and stat.mtime.sec or 0

        local fm = parse_frontmatter(abs_path)

        items[#items + 1] = {
          label = basename,
          insertText = basename .. "]]",
          filterText = name,
          kind = 18,
          sortText = string.format("%010d", 9999999999 - mtime),
          labelDetails = {
            description = build_description(fm, rel),
          },
          data = {
            rel_path = rel,
            abs_path = abs_path,
          },
        }

        -- Add alias completion items
        if fm and fm.aliases and fm.aliases ~= "" then
          for alias in fm.aliases:gmatch("[^,]+") do
            alias = vim.trim(alias)
            if alias ~= "" and alias ~= basename then
              items[#items + 1] = {
                label = alias,
                insertText = basename .. "]]",
                filterText = alias .. " " .. name,
                kind = 18,
                sortText = string.format("%010d", 9999999999 - mtime),
                labelDetails = {
                  description = "(alias) " .. build_description(fm, rel),
                },
                data = {
                  rel_path = rel,
                  abs_path = abs_path,
                },
              }
            end
          end
        end
      end

      cached_items = items
      cached_vault = vault_path
      if callback then callback(items) end
    end)
  end)
end

local function invalidate()
  cached_items = nil
  build_generation = build_generation + 1
end

vim.api.nvim_create_autocmd("BufWritePost", {
  pattern = "*.md",
  group = vim.api.nvim_create_augroup("VaultCompletionCache", { clear = true }),
  callback = invalidate,
})

--- Find the best matching note path from cached items by name.
--- Uses proximity to the current buffer when multiple notes share the same basename.
local function resolve_note_path(name)
  if not cached_items then return nil end
  local lower = name:lower()
  local matches = {}
  for _, item in ipairs(cached_items) do
    if item.label:lower() == lower then
      matches[#matches + 1] = item.data.abs_path
    end
  end
  if #matches == 0 then return nil end
  if #matches == 1 then return matches[1] end
  -- Multiple matches: pick the closest to the current buffer's directory
  local current_dir = vim.fn.expand("%:p:h")
  local best, best_score = matches[1], math.huge
  for _, path in ipairs(matches) do
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
      best = path
    end
  end
  return best
end

local empty = { is_incomplete_forward = false, is_incomplete_backward = false, items = {} }

function source.new(opts)
  local self = setmetatable({}, { __index = source })
  self.opts = opts or {}
  build_items_async()
  return self
end

function source:enabled()
  return vim.bo.filetype == "markdown"
end

function source:get_trigger_characters()
  return { "[", "#", "^" }
end

function source:get_completions(ctx, callback)
  local before = ctx.line:sub(1, ctx.cursor[2])

  -- Standalone block ID reference: ^partial (not inside [[ ]])
  -- Triggers when typing ^id anywhere that isn't already a wikilink
  if not before:match("!?%[%[") then
    local block_prefix = before:match("%^([%w%-]*)$")
    if block_prefix then
      local buf_path = vim.api.nvim_buf_get_name(0)
      if buf_path ~= "" then
        local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local blocks = get_blocks(buf_lines)
        local items = {}
        for _, b in ipairs(blocks) do
          local preview = b.text
          if #preview > 60 then
            preview = preview:sub(1, 57) .. "..."
          end
          items[#items + 1] = {
            label = "^" .. b.id,
            insertText = b.id,
            kind = 22,
            labelDetails = { description = preview },
            documentation = {
              kind = "plaintext",
              value = "Line " .. b.line .. ": " .. b.text,
            },
          }
        end
        callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
        return
      end
    end
    callback(empty)
    return
  end

  -- If closing ]] already exists after cursor (e.g. from autopairs),
  -- strip ]] from insertText to avoid doubled brackets
  local after = ctx.line:sub(ctx.cursor[2] + 1)
  if after:match("^%]%]") then
    local orig_callback = callback
    callback = function(result)
      if result and result.items then
        local items = {}
        for _, item in ipairs(result.items) do
          if item.insertText and item.insertText:sub(-2) == "]]" then
            local new_item = vim.tbl_extend("force", {}, item)
            new_item.insertText = item.insertText:sub(1, -3)
            items[#items + 1] = new_item
          else
            items[#items + 1] = item
          end
        end
        result = { is_incomplete_forward = result.is_incomplete_forward, is_incomplete_backward = result.is_incomplete_backward, items = items }
      end
      orig_callback(result)
    end
  end

  -- Block completion: [[Note Name^partial, [[^partial (same file), or ![[...^partial
  local block_note_name = before:match("!?%[%[(.-)%^[^%]]*$")
  if block_note_name then
    local lines
    if block_note_name == "" then
      -- Same-file block reference: [[^
      lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    else
      -- Cross-file block reference: [[Note^
      local base_name = block_note_name:match("^([^#]+)") or block_note_name
      base_name = vim.trim(base_name)
      local target_path = resolve_note_path(base_name)
      if target_path then lines = read_lines(target_path) end
    end

    if lines then
      local blocks = get_blocks(lines)
      local items = {}
      for _, b in ipairs(blocks) do
        local preview = b.text
        if #preview > 60 then
          preview = preview:sub(1, 57) .. "..."
        end
        items[#items + 1] = {
          label = b.id,
          insertText = b.id .. "]]",
          kind = 22,
          labelDetails = { description = preview },
          documentation = {
            kind = "plaintext",
            value = "Line " .. b.line .. ": " .. b.text,
          },
        }
      end
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
    else
      callback(empty)
    end
    return
  end

  -- Heading completion: [[Note Name#partial, [[#partial (same file), or ![[...#partial
  local note_name = before:match("!?%[%[(.-)#[^%]]*$")
  if note_name then
    local lines
    if note_name == "" then
      -- Same-file heading reference: [[# — read from buffer for unsaved changes
      lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    else
      local target_path = resolve_note_path(note_name)
      if target_path then lines = read_lines(target_path) end
    end

    if lines then
      local headings = get_headings(lines)
      local items = {}
      for _, h in ipairs(headings) do
        items[#items + 1] = {
          label = h.text,
          insertText = h.text .. "]]",
          kind = 22,
          sortText = string.format("%04d", h.order),
          labelDetails = {
            description = string.rep("#", h.level) .. " L" .. h.line,
          },
          documentation = h.preview ~= "" and {
            kind = "markdown",
            value = string.rep("#", h.level) .. " " .. h.text .. "\n\n" .. h.preview,
          } or nil,
          data = { completion_kind = "heading" },
        }
      end
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
    else
      callback(empty)
    end
    return
  end

  -- Normal note name completion (invalidate if vault changed)
  if cached_items and cached_vault == engine.vault_path then
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = cached_items })
    return
  end

  build_items_async(function(items)
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items or {} })
  end)
end

function source:resolve(item, callback)
  if not item.data or not item.data.abs_path then
    callback(item)
    return
  end

  local path = item.data.abs_path
  local f = io.open(path, "r")
  if not f then
    callback(item)
    return
  end

  local raw_lines = {}
  for _ = 1, 60 do
    local line = f:read("*l")
    if not line then break end
    raw_lines[#raw_lines + 1] = line
  end
  f:close()

  -- Separate frontmatter from body
  local fm_lines = {}
  local body_lines = {}
  local in_fm = false
  local fm_done = false
  for i, line in ipairs(raw_lines) do
    if i == 1 and line == "---" then
      in_fm = true
    elseif in_fm and line == "---" then
      in_fm = false
      fm_done = true
    elseif in_fm then
      fm_lines[#fm_lines + 1] = line
    else
      if fm_done or i > 1 or line ~= "---" then
        body_lines[#body_lines + 1] = line
      end
    end
  end

  -- Build preview
  local out = {}

  -- Header: note name and path
  out[#out + 1] = "### " .. item.label
  out[#out + 1] = "`" .. item.data.rel_path .. "`"
  out[#out + 1] = ""

  -- Frontmatter as a yaml code block
  if #fm_lines > 0 then
    out[#out + 1] = "```yaml"
    for _, l in ipairs(fm_lines) do
      out[#out + 1] = l
    end
    out[#out + 1] = "```"
    out[#out + 1] = ""
  end

  -- Separator
  out[#out + 1] = "---"
  out[#out + 1] = ""

  -- Body content
  for _, l in ipairs(body_lines) do
    out[#out + 1] = l
  end

  item.documentation = {
    kind = "markdown",
    value = table.concat(out, "\n"),
  }

  callback(item)
end

return source
