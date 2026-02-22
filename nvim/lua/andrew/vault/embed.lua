local engine = require("andrew.vault.engine")
local wikilinks = require("andrew.vault.wikilinks")
local config = require("andrew.vault.config")

local M = {}

local ns = vim.api.nvim_create_namespace("VaultEmbed")
local embeds_visible = {}

--- Resolve an embed link name to an absolute file path.
---@param name string note name (without .md)
---@return string|nil
local function resolve_embed(name)
  -- Try wikilinks resolver first (uses its cache)
  local path = wikilinks.resolve_link(name)
  if path then
    return path
  end
  -- Fallback: direct search
  local results = vim.fs.find(name .. ".md", {
    path = engine.vault_path,
    type = "file",
    limit = 1,
  })
  return results[1]
end

--- Read the full content of a file, returning lines and total count.
---@param path string
---@param max_lines number|nil cap on lines to return (nil = unlimited)
---@return string[]
local function read_file_lines(path, max_lines)
  local f = io.open(path, "r")
  if not f then
    return { "[Could not read file]" }
  end
  local lines = {}
  local count = 0
  for line in f:lines() do
    count = count + 1
    if max_lines and count > max_lines then
      lines[#lines + 1] = "..."
      break
    end
    lines[#lines + 1] = line
  end
  f:close()
  return lines
end

--- Extract content under a heading until the next heading of same or higher level.
---@param path string
---@param heading string heading text to match
---@return string[]
local function read_heading_section(path, heading)
  local f = io.open(path, "r")
  if not f then
    return { "[Could not read file]" }
  end

  local lines = {}
  local capturing = false
  local target_level = nil

  for line in f:lines() do
    if capturing then
      local level_str = line:match("^(#+)%s+")
      if level_str and #level_str <= target_level then
        -- Hit a heading of same or higher level; stop
        break
      end
      lines[#lines + 1] = line
    else
      local level_str, text = line:match("^(#+)%s+(.*)")
      if text then
        -- Normalize for comparison: trim whitespace
        local trimmed = vim.trim(text)
        if trimmed == heading then
          target_level = #level_str
          capturing = true
          lines[#lines + 1] = line -- include the heading itself
        end
      end
    end
  end

  f:close()
  if #lines == 0 then
    return { "[Heading not found: #" .. heading .. "]" }
  end
  return lines
end

--- Extract the block (paragraph/line) containing a block reference.
---@param path string
---@param block_id string
---@return string[]
local function read_block_content(path, block_id)
  local f = io.open(path, "r")
  if not f then
    return { "[Could not read file]" }
  end

  -- Collect paragraphs: groups of non-blank lines
  local paragraphs = {}
  local current = {}
  for line in f:lines() do
    if line:match("^%s*$") then
      if #current > 0 then
        paragraphs[#paragraphs + 1] = current
        current = {}
      end
    else
      current[#current + 1] = line
    end
  end
  if #current > 0 then
    paragraphs[#paragraphs + 1] = current
  end
  f:close()

  -- Find the paragraph containing the block id
  local escaped = vim.pesc(block_id)
  for _, para in ipairs(paragraphs) do
    for _, line in ipairs(para) do
      if line:match("%^" .. escaped .. "%s*$") then
        -- Return the whole paragraph, stripping the block id from the last matching line
        local result = {}
        for _, l in ipairs(para) do
          result[#result + 1] = l:gsub("%s*%^" .. escaped .. "%s*$", "")
        end
        return result
      end
    end
  end

  return { "[Block not found: ^" .. block_id .. "]" }
end

--- Parse an embed target string into components.
--- "note" -> {name="note"}
--- "note#heading" -> {name="note", heading="heading"}
--- "note^block-id" -> {name="note", block_id="block-id"}
--- "note#heading^block-id" -> {name="note", heading="heading", block_id="block-id"}
---@param target string
---@return {name: string, heading: string|nil, block_id: string|nil}
local function parse_embed_target(target)
  local name, heading, block_id

  local n, h, b = target:match("^([^#%^]+)#([^%^]+)%^(.+)$")
  if n then
    name, heading, block_id = n, h, b
  else
    n, b = target:match("^([^#%^]+)%^(.+)$")
    if n then
      name, block_id = n, b
    else
      n, h = target:match("^([^#%^]+)#(.+)$")
      if n then
        name, heading = n, h
      else
        name = target
      end
    end
  end

  return {
    name = vim.trim(name),
    heading = heading and vim.trim(heading) or nil,
    block_id = block_id and vim.trim(block_id) or nil,
  }
end

--- Get the content lines for an embed.
---@param details {name: string, heading: string|nil, block_id: string|nil}
---@param path string resolved file path
---@return string[]
local function get_embed_content(details, path)
  if details.block_id then
    return read_block_content(path, details.block_id)
  elseif details.heading then
    return read_heading_section(path, details.heading)
  else
    -- Full note embed: first 20 lines
    return read_file_lines(path, config.embed.max_lines)
  end
end

--- Render all ![[...]] embeds in the current buffer as virtual text.
function M.render_embeds()
  local bufnr = vim.api.nvim_get_current_buf()
  local bufpath = vim.api.nvim_buf_get_name(bufnr)

  -- Only operate on vault files
  if not vim.startswith(bufpath, engine.vault_path) then
    return
  end

  -- Clear existing embeds first
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local border_hl = "VaultEmbedBorder"
  local content_hl = "VaultEmbedContent"

  for i, line in ipairs(lines) do
    -- Find ![[...]] patterns on this line
    local start = 1
    while true do
      local s, e = line:find("!%[%[.-%]%]", start)
      if not s then
        break
      end

      local inner = line:sub(s + 3, e - 2)
      -- Strip display alias: ![[target|alias]] -> target
      local target = inner:match("^([^|]+)") or inner
      local details = parse_embed_target(target)

      local path = resolve_embed(details.name)
      local virt_lines = {}

      if path then
        local content = get_embed_content(details, path)
        local header_text = string.rep("\u{2500}", 2)
          .. " ![[" .. inner .. "]] "
          .. string.rep("\u{2500}", 40)

        -- Header border
        virt_lines[#virt_lines + 1] = { { header_text, border_hl } }

        -- Content lines
        for _, cl in ipairs(content) do
          virt_lines[#virt_lines + 1] = { { "  " .. cl, content_hl } }
        end

        -- Footer border
        local footer_text = string.rep("\u{2500}", 50)
        virt_lines[#virt_lines + 1] = { { footer_text, border_hl } }
      else
        virt_lines[#virt_lines + 1] = {
          { string.rep("\u{2500}", 2) .. " ![[" .. inner .. "]] (not found) " .. string.rep("\u{2500}", 20), border_hl },
        }
      end

      vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, 0, {
        virt_lines = virt_lines,
        virt_lines_above = false,
      })

      start = e + 1
    end
  end

  embeds_visible[bufnr] = true
end

--- Clear all embed virtual text from the current buffer.
function M.clear_embeds()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  embeds_visible[bufnr] = false
end

--- Toggle embed rendering on/off in the current buffer.
function M.toggle_embeds()
  local bufnr = vim.api.nvim_get_current_buf()
  if embeds_visible[bufnr] then
    M.clear_embeds()
  else
    M.render_embeds()
  end
end

function M.setup()
  -- Define highlight groups (dimmed/italic for content, dimmed for borders)
  vim.api.nvim_set_hl(0, "VaultEmbedContent", { italic = true, fg = "#8888aa", default = true })
  vim.api.nvim_set_hl(0, "VaultEmbedBorder", { fg = "#555577", default = true })

  -- Commands
  vim.api.nvim_create_user_command("VaultEmbedRender", function()
    M.render_embeds()
  end, { desc = "Vault: render embed transclusions" })

  vim.api.nvim_create_user_command("VaultEmbedClear", function()
    M.clear_embeds()
  end, { desc = "Vault: clear embed transclusions" })

  vim.api.nvim_create_user_command("VaultEmbedToggle", function()
    M.toggle_embeds()
  end, { desc = "Vault: toggle embed transclusions" })
end

return M
