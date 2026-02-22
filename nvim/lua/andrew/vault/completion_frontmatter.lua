local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")

local source = {}

local cached_property_names = nil
local cached_property_values = nil
local cached_vault = nil
local building = false
local build_generation = 0

-- Well-known properties with predefined value suggestions
local known_values = {
  type = config.note_types,
  status = { "Active", "Complete", "On Hold", "Archived", "Draft", "In Progress" },
  priority = { "High", "Medium", "Low", "Critical", "None" },
}

--- Check whether the cursor is inside the YAML frontmatter block.
--- Returns true if between the opening and closing --- delimiters.
---@param bufnr number
---@param cursor_row number 1-indexed row
---@return boolean
local function in_frontmatter(bufnr, cursor_row)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, math.min(cursor_row, vim.api.nvim_buf_line_count(bufnr)), false)
  if #lines == 0 or lines[1] ~= "---" then
    return false
  end

  -- Cursor must be after line 1 (the opening ---) and before the closing ---
  if cursor_row <= 1 then
    return false
  end

  for i = 2, #lines do
    if lines[i] == "---" then
      -- Found closing delimiter
      -- Cursor is inside if cursor_row is before this line
      return cursor_row < i + 1 -- i is 1-indexed from lines array, cursor_row is 1-indexed
    end
  end

  -- No closing delimiter found yet (user is still typing frontmatter)
  -- Treat everything after opening --- as inside frontmatter
  return true
end

--- Scan the vault for all frontmatter property names and their values.
---@param callback fun(prop_names: table[], prop_values: table)
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
        if callback then callback({}, {}) end
        return
      end
      if out.code ~= 0 or not out.stdout then
        if callback then callback({}, {}) end
        return
      end

      local prop_counts = {} -- property_name -> count of files using it
      local prop_values = {} -- property_name -> { value -> count }

      for line in out.stdout:gmatch("[^\r\n]+") do
        local rel = line
        if not use_fd then
          rel = line:sub(#vault_path + 2)
        end
        local abs_path = use_fd and (vault_path .. "/" .. rel) or line

        local f = io.open(abs_path, "r")
        if f then
          local first = f:read("*l")
          if first and first == "---" then
            local cur_key = nil
            while true do
              local fm_line = f:read("*l")
              if not fm_line or fm_line == "---" then break end

              -- YAML list item under a key
              local list_item = fm_line:match("^%s+-%s+(.+)$")
              if list_item and cur_key then
                list_item = list_item:gsub("^[\"'](.+)[\"']$", "%1")
                list_item = vim.trim(list_item)
                if list_item ~= "" then
                  if not prop_values[cur_key] then
                    prop_values[cur_key] = {}
                  end
                  prop_values[cur_key][list_item] = (prop_values[cur_key][list_item] or 0) + 1
                end
              else
                -- Top-level key: value
                local key, val = fm_line:match("^([%w_%-]+):%s*(.*)$")
                if key then
                  prop_counts[key] = (prop_counts[key] or 0) + 1
                  cur_key = key

                  if val and val ~= "" then
                    -- Strip inline array brackets and quotes
                    val = val:gsub("^%[", ""):gsub("%]$", "")
                    val = val:gsub("^[\"'](.+)[\"']$", "%1")
                    val = vim.trim(val)
                    if val ~= "" and not val:match("^%[%[") then
                      if not prop_values[key] then
                        prop_values[key] = {}
                      end
                      prop_values[key][val] = (prop_values[key][val] or 0) + 1
                    end
                  end
                else
                  cur_key = nil
                end
              end
            end
          end
          f:close()
        end
      end

      -- Build property name completion items
      local names = {}
      for name, _ in pairs(prop_counts) do
        names[#names + 1] = name
      end
      table.sort(names)

      local name_items = {}
      for _, name in ipairs(names) do
        local count = prop_counts[name]
        name_items[#name_items + 1] = {
          label = name,
          insertText = name .. ": ",
          filterText = name,
          kind = 10, -- Property
          sortText = string.format("%05d", 99999 - count) .. name,
          labelDetails = {
            description = count .. " note" .. (count == 1 and "" or "s"),
          },
        }
      end

      -- Merge known values with discovered values
      for key, presets in pairs(known_values) do
        if not prop_values[key] then
          prop_values[key] = {}
        end
        for _, v in ipairs(presets) do
          if not prop_values[key][v] then
            prop_values[key][v] = 0
          end
        end
      end

      -- Build value completion items per property
      local value_items = {} -- property_name -> items[]
      for key, vals in pairs(prop_values) do
        local val_list = {}
        for v, _ in pairs(vals) do
          val_list[#val_list + 1] = v
        end
        table.sort(val_list)

        local items = {}
        for _, v in ipairs(val_list) do
          local count = vals[v]
          local desc = count > 0 and (count .. " note" .. (count == 1 and "" or "s")) or "suggested"
          items[#items + 1] = {
            label = v,
            insertText = v,
            filterText = v,
            kind = 12, -- Value
            sortText = string.format("%05d", 99999 - count) .. v,
            labelDetails = {
              description = desc,
            },
          }
        end
        value_items[key] = items
      end

      cached_property_names = name_items
      cached_property_values = value_items
      cached_vault = vault_path
      if callback then callback(name_items, value_items) end
    end)
  end)
end

local function invalidate()
  cached_property_names = nil
  cached_property_values = nil
  build_generation = build_generation + 1
end

vim.api.nvim_create_autocmd("BufWritePost", {
  pattern = "*.md",
  group = vim.api.nvim_create_augroup("VaultFrontmatterCompletionCache", { clear = true }),
  callback = invalidate,
})

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

function source:get_completions(ctx, callback)
  local bufnr = ctx.bufnr or vim.api.nvim_get_current_buf()
  local cursor_row = ctx.cursor[1]

  -- Only complete inside frontmatter
  if not in_frontmatter(bufnr, cursor_row) then
    callback(empty)
    return
  end

  local line = ctx.line
  local col = ctx.cursor[2]
  local before = line:sub(1, col)

  -- Determine context: property name or property value?

  -- Value completion: line starts with "key: " and cursor is after the colon
  local prop_key = before:match("^([%w_%-]+):%s+")
  if prop_key then
    -- Completing a value for this property
    local provide_values = function(name_items, value_items)
      local items = value_items and value_items[prop_key] or {}
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
    end

    if cached_property_values and cached_vault == engine.vault_path then
      provide_values(cached_property_names, cached_property_values)
    else
      build_items_async(function(name_items, value_items)
        provide_values(name_items, value_items)
      end)
    end
    return
  end

  -- List item value completion: line starts with "  - " (under a YAML list key)
  -- Find the parent key by scanning upward
  local list_prefix = before:match("^%s+-%s+")
  if list_prefix then
    local parent_key = nil
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, cursor_row - 1, false)
    for i = #lines, 1, -1 do
      local key = lines[i]:match("^([%w_%-]+):")
      if key then
        parent_key = key
        break
      end
    end

    if parent_key then
      local provide_values = function(_, value_items)
        local items = value_items and value_items[parent_key] or {}
        callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
      end

      if cached_property_values and cached_vault == engine.vault_path then
        provide_values(cached_property_names, cached_property_values)
      else
        build_items_async(function(name_items, value_items)
          provide_values(name_items, value_items)
        end)
      end
      return
    end
  end

  -- Property name completion: at the beginning of a line or typing a key name
  if cached_property_names and cached_vault == engine.vault_path then
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = cached_property_names })
    return
  end

  build_items_async(function(name_items, _)
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = name_items or {} })
  end)
end

return source
