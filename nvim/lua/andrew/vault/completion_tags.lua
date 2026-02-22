local engine = require("andrew.vault.engine")

local source = {}

local cached_items = nil
local cached_vault = nil
local building = false
local build_generation = 0

--- Collect tags with frequency counts using ripgrep.
--- Counts both inline #tags and frontmatter tags.
---@param callback fun(items: table[])
local function build_items_async(callback)
  if building then return end
  building = true

  local gen = build_generation
  local vault_path = engine.vault_path

  -- Use ripgrep to find all inline #tags
  local inline_cmd = {
    "rg",
    "-o",
    "(?:^|\\s)#([a-zA-Z][a-zA-Z0-9_/-]+)",
    "--no-filename",
    "--no-line-number",
    "--replace", "$1",
    "--glob", "*.md",
    vault_path,
  }

  -- Use ripgrep to find frontmatter tags (YAML list items under tags:)
  local frontmatter_cmd = {
    "rg",
    "-U",
    "--no-filename",
    "--no-line-number",
    "-o",
    "^tags:\\n(\\s+- .+\\n?)+",
    "--glob", "*.md",
    vault_path,
  }

  local counts = {} -- tag_name -> count
  local pending = 2

  local function finish()
    pending = pending - 1
    if pending > 0 then return end

    vim.schedule(function()
      building = false
      if gen ~= build_generation then
        if callback then callback({}) end
        return
      end

      -- Build sorted tag list
      local tag_list = {}
      for tag, _ in pairs(counts) do
        tag_list[#tag_list + 1] = tag
      end
      table.sort(tag_list)

      -- Build completion items
      local items = {}
      for _, tag in ipairs(tag_list) do
        local count = counts[tag]
        items[#items + 1] = {
          label = "#" .. tag,
          insertText = tag,
          filterText = tag,
          kind = 14, -- Keyword
          sortText = string.format("%05d", 99999 - count) .. tag,
          labelDetails = {
            description = count .. " note" .. (count == 1 and "" or "s"),
          },
        }
      end

      cached_items = items
      cached_vault = vault_path
      if callback then callback(items) end
    end)
  end

  local function add_tag(name)
    local trimmed = vim.trim(name)
    if trimmed ~= "" then
      counts[trimmed] = (counts[trimmed] or 0) + 1
    end
  end

  -- Inline tags
  vim.system(inline_cmd, { text = true }, function(result)
    if result.code ~= 0 then
      vim.schedule(function()
        vim.notify("Vault tags: inline tag search failed (rg exit " .. (result.code or "?") .. ")", vim.log.levels.WARN)
      end)
    elseif result.stdout and result.stdout ~= "" then
      for line in result.stdout:gmatch("[^\n]+") do
        add_tag(line)
      end
    end
    finish()
  end)

  -- Frontmatter tags
  vim.system(frontmatter_cmd, { text = true }, function(result)
    if result.code ~= 0 then
      vim.schedule(function()
        vim.notify("Vault tags: frontmatter tag search failed (rg exit " .. (result.code or "?") .. ")", vim.log.levels.WARN)
      end)
    elseif result.stdout and result.stdout ~= "" then
      for line in result.stdout:gmatch("[^\n]+") do
        local tag = line:match("^%s+-%s+(.+)$")
        if tag then
          tag = tag:gsub("^[\"'](.+)[\"']$", "%1")
          add_tag(tag)
        end
      end
    end
    finish()
  end)
end

local function invalidate()
  cached_items = nil
  build_generation = build_generation + 1
end

vim.api.nvim_create_autocmd("BufWritePost", {
  pattern = "*.md",
  group = vim.api.nvim_create_augroup("VaultTagCompletionCache", { clear = true }),
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
  local before = ctx.line:sub(1, ctx.cursor[2])

  -- Only trigger after a # that looks like a tag start:
  -- must be at start of line or preceded by whitespace, and not be a heading
  -- Pattern: (beginning or whitespace) followed by # and optional tag chars
  if not before:match("[%s^]#[%w_/-]*$") and not before:match("^#[%w_/-]*$") then
    callback(empty)
    return
  end

  -- Exclude markdown headings: lines that start with one or more # followed by space
  local trimmed = vim.trim(before)
  if trimmed:match("^#+%s") or trimmed:match("^#+$") then
    callback(empty)
    return
  end

  if cached_items and cached_vault == engine.vault_path then
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = cached_items })
    return
  end

  build_items_async(function(items)
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items or {} })
  end)
end

return source
