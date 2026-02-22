local engine = require("andrew.vault.engine")
local wikilinks = require("andrew.vault.wikilinks")
local config = require("andrew.vault.config")

local M = {}

local formats = { "pdf", "docx", "html" }

-- Image file extensions recognized by Obsidian
local image_exts = {
  png = true, jpg = true, jpeg = true, gif = true,
  svg = true, webp = true, bmp = true, tiff = true,
}

--- Check whether a filename looks like an image based on its extension.
---@param name string
---@return boolean
local function is_image(name)
  local ext = name:match("%.(%w+)$")
  return ext and image_exts[ext:lower()] or false
end

--- Slugify a heading for use as a markdown anchor.
--- Matches the algorithm used in wikilinks.lua for consistency.
---@param heading string
---@return string
local function heading_to_anchor(heading)
  return heading:lower()
    :gsub("[^%w%s%-]", "")
    :gsub("%s", "-")
    :gsub("^%-+", "")
    :gsub("%-+$", "")
end

--- Resolve the filesystem path for an attachment/image embed.
--- Looks in the vault-level `attachments/` directory first, then falls back
--- to searching relative to the source buffer directory.
---@param name string filename (e.g. "image.png")
---@param buf_dir string directory of the buffer being exported
---@return string relative_path  path suitable for a markdown image link
local function resolve_attachment(name, buf_dir)
  -- 1) vault-level attachments folder
  local vault_attach = engine.vault_path .. "/attachments/" .. name
  if vim.fn.filereadable(vault_attach) == 1 then
    -- Return path relative to the buffer directory
    local rel = vim.fn.fnamemodify(vault_attach, ":.")
    -- If the buffer is inside the vault, compute relative from buf_dir
    local ok, result = pcall(function()
      return vim.fn.resolve(vault_attach)
    end)
    if ok then
      return result
    end
    return rel
  end

  -- 2) same directory as the buffer
  local local_path = buf_dir .. "/" .. name
  if vim.fn.filereadable(local_path) == 1 then
    return vim.fn.resolve(local_path)
  end

  -- 3) search the vault
  local found = vim.fs.find(name, {
    path = engine.vault_path,
    type = "file",
    limit = 1,
  })
  if found[1] then
    return vim.fn.resolve(found[1])
  end

  -- Fallback: use the attachments convention even if file is missing
  return engine.vault_path .. "/attachments/" .. name
end

--- Read all lines from a file path.
---@param path string
---@return string[]|nil
local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local lines = {}
  for line in f:lines() do
    lines[#lines + 1] = line
  end
  f:close()
  return lines
end

--- Extract content under a heading until the next heading of same or higher level.
---@param path string
---@param heading string
---@return string[]
local function read_heading_section(path, heading)
  local f = io.open(path, "r")
  if not f then
    return { "*[Could not read: " .. path .. "]*" }
  end

  local lines = {}
  local capturing = false
  local target_level = nil

  for line in f:lines() do
    if capturing then
      local level_str = line:match("^(#+)%s+")
      if level_str and #level_str <= target_level then
        break
      end
      lines[#lines + 1] = line
    else
      local level_str, text = line:match("^(#+)%s+(.*)")
      if text then
        if vim.trim(text) == heading then
          target_level = #level_str
          capturing = true
          lines[#lines + 1] = line
        end
      end
    end
  end

  f:close()
  if #lines == 0 then
    return { "*[Heading not found: #" .. heading .. "]*" }
  end
  return lines
end

--- Extract the paragraph containing a block reference.
---@param path string
---@param block_id string
---@return string[]
local function read_block_content(path, block_id)
  local f = io.open(path, "r")
  if not f then
    return { "*[Could not read: " .. path .. "]*" }
  end

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

  local escaped = vim.pesc(block_id)
  for _, para in ipairs(paragraphs) do
    for _, line in ipairs(para) do
      if line:match("%^" .. escaped .. "%s*$") then
        local result = {}
        for _, l in ipairs(para) do
          result[#result + 1] = l:gsub("%s*%^" .. escaped .. "%s*$", "")
        end
        return result
      end
    end
  end

  return { "*[Block not found: ^" .. block_id .. "]*" }
end

--- Parse an embed/wikilink target string into components.
---@param target string
---@return {name: string, heading: string|nil, block_id: string|nil}
local function parse_target(target)
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

--- Convert a single wikilink match to a standard markdown link.
--- Handles: [[Name]], [[Name|Alias]], [[Name#Heading]], [[Name#Heading|Alias]],
---          [[Name^block]], [[Name#Heading^block|Alias]]
---@param inner string the content between [[ and ]]
---@return string markdown link
local function convert_wikilink(inner)
  -- Normalise \| escape used inside markdown tables
  inner = inner:gsub("\\|", "|")

  -- Separate alias from target: [[target|alias]]
  local target, alias = inner:match("^([^|]+)|(.+)$")
  if not target then
    target = inner
    alias = nil
  end

  local details = parse_target(target)

  -- Build display text
  local display
  if alias then
    display = alias
  elseif details.heading and details.name ~= "" then
    display = details.name .. " > " .. details.heading
  elseif details.heading then
    display = details.heading
  else
    display = details.name
  end

  -- Build destination URL
  local dest
  if details.name ~= "" then
    dest = details.name .. ".md"
  else
    -- Self-referencing heading link: [[#Heading]]
    dest = ""
  end

  if details.heading then
    dest = dest .. "#" .. heading_to_anchor(details.heading)
  end

  if details.block_id then
    -- Pandoc does not have block-id anchors; append as fragment anyway
    if not details.heading then
      dest = dest .. "#" .. details.block_id
    end
  end

  return "[" .. display .. "](" .. dest .. ")"
end

--- Convert a note embed (![[Note]]) into blockquoted inline content.
---@param inner string content between ![[  and  ]]
---@param buf_dir string directory of the source buffer
---@return string replacement text (may be multi-line)
local function convert_embed(inner, buf_dir)
  -- Normalise \| escape
  inner = inner:gsub("\\|", "|")

  -- Separate alias
  local target = inner:match("^([^|]+)") or inner

  -- Image embed: ![[image.png]] or ![[path/image.png]]
  if is_image(target) then
    local alt = inner:match("|(.+)$") or target:match("([^/]+)$"):gsub("%.%w+$", "")
    local resolved = resolve_attachment(target, buf_dir)
    return "![" .. alt .. "](" .. resolved .. ")"
  end

  -- Note embed: resolve and inline content
  local details = parse_target(target)
  local path = wikilinks.resolve_link(details.name)

  if not path then
    return "> *[Embed not found: " .. inner .. "]*"
  end

  local content_lines
  if details.block_id then
    content_lines = read_block_content(path, details.block_id)
  elseif details.heading then
    content_lines = read_heading_section(path, details.heading)
  else
    content_lines = read_file(path)
    if not content_lines then
      return "> *[Could not read: " .. details.name .. "]*"
    end
    -- Strip frontmatter from embedded notes
    if content_lines[1] and content_lines[1]:match("^%-%-%-") then
      local fm_end = nil
      for i = 2, #content_lines do
        if content_lines[i]:match("^%-%-%-") then
          fm_end = i
          break
        end
      end
      if fm_end then
        local stripped = {}
        for i = fm_end + 1, #content_lines do
          stripped[#stripped + 1] = content_lines[i]
        end
        content_lines = stripped
        -- Remove leading blank lines after frontmatter
        while #content_lines > 0 and content_lines[1]:match("^%s*$") do
          table.remove(content_lines, 1)
        end
      end
    end
  end

  -- Format as blockquote with source attribution
  local result = {}
  result[#result + 1] = "> **" .. details.name .. "**"
  result[#result + 1] = ">"
  for _, line in ipairs(content_lines) do
    if line:match("^%s*$") then
      result[#result + 1] = ">"
    else
      result[#result + 1] = "> " .. line
    end
  end

  return table.concat(result, "\n")
end

--- Map Obsidian callout types to a style description for Pandoc.
--- Returns the callout kind lowercased and a suitable label/icon.
---@param ctype string e.g. "NOTE", "WARNING", "TIP"
---@return string kind, string label
local function callout_label(ctype)
  local upper = ctype:upper()
  local map = {
    NOTE      = "Note",
    TIP       = "Tip",
    IMPORTANT = "Important",
    WARNING   = "Warning",
    CAUTION   = "Caution",
    ABSTRACT  = "Abstract",
    SUMMARY   = "Summary",
    TLDR      = "TL;DR",
    INFO      = "Info",
    TODO      = "Todo",
    SUCCESS   = "Success",
    CHECK     = "Check",
    DONE      = "Done",
    QUESTION  = "Question",
    HELP      = "Help",
    FAQ       = "FAQ",
    FAILURE   = "Failure",
    FAIL      = "Fail",
    MISSING   = "Missing",
    DANGER    = "Danger",
    ERROR     = "Error",
    BUG       = "Bug",
    EXAMPLE   = "Example",
    QUOTE     = "Quote",
    CITE      = "Cite",
  }
  return upper:lower(), map[upper] or ctype
end

--- Convert Obsidian callout blocks to Pandoc fenced div syntax.
--- A callout starts with `> [!TYPE] Optional title` and continues with
--- subsequent `> ` prefixed lines.
---@param lines string[] all lines of the document
---@return string[] converted lines
local function convert_callouts(lines)
  local result = {}
  local i = 1
  while i <= #lines do
    local ctype, title = lines[i]:match("^>%s*%[!(%w+)%]%s*(.*)")
    if ctype then
      local kind, label = callout_label(ctype)
      local heading = title and title ~= "" and title or label

      -- Pandoc fenced div: ::: {.callout-<kind>}
      result[#result + 1] = "::: {.callout-" .. kind .. "}"
      result[#result + 1] = "**" .. heading .. "**"
      result[#result + 1] = ""

      -- Collect subsequent blockquote lines
      i = i + 1
      while i <= #lines do
        local content = lines[i]:match("^>%s?(.*)")
        if content then
          result[#result + 1] = content
          i = i + 1
        else
          break
        end
      end

      result[#result + 1] = ":::"
      result[#result + 1] = ""
    else
      result[#result + 1] = lines[i]
      i = i + 1
    end
  end
  return result
end

--- Preprocess buffer content: convert Obsidian-specific syntax to standard
--- markdown that Pandoc can process.
---
--- Handles:
---   - Wikilinks: [[Note]], [[Note|Alias]], [[Note#H]], [[Note#H|A]]
---   - Note embeds: ![[Note]], ![[Note#Heading]], ![[Note^block]]
---   - Image embeds: ![[image.png]], ![[image.png|alt text]]
---   - Callouts: > [!TYPE] Title
---
---@param content string raw markdown content
---@param buf_dir string directory of the source file
---@return string preprocessed content
function M.preprocess(content, buf_dir)
  local lines = {}
  for line in (content .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end

  -- Pass 1: Convert embeds (![[...]]) before wikilinks so the ! prefix is consumed first
  local pass1 = {}
  for _, line in ipairs(lines) do
    local converted = line:gsub("!%[%[(.-)%]%]", function(inner)
      return convert_embed(inner, buf_dir)
    end)
    -- An embed conversion may produce multiple lines; split them
    for sub in (converted .. "\n"):gmatch("(.-)\n") do
      pass1[#pass1 + 1] = sub
    end
  end

  -- Pass 2: Convert remaining wikilinks ([[...]])
  local pass2 = {}
  for _, line in ipairs(pass1) do
    local converted = line:gsub("%[%[(.-)%]%]", function(inner)
      return convert_wikilink(inner)
    end)
    pass2[#pass2 + 1] = converted
  end

  -- Pass 3: Convert Obsidian callouts to Pandoc fenced divs
  local pass3 = convert_callouts(pass2)

  return table.concat(pass3, "\n")
end

--- Export current markdown buffer via pandoc.
---@param fmt string|nil output format (pdf, docx, html). Prompts if nil.
function M.export(fmt)
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" or not bufname:match("%.md$") then
    vim.notify("Vault: current buffer is not a markdown file", vim.log.levels.WARN)
    return
  end

  local function run_export(format)
    local stem = vim.fn.fnamemodify(bufname, ":t:r")
    local dir = vim.fn.fnamemodify(bufname, ":h")
    local outfile = dir .. "/" .. stem .. "." .. format

    -- Save before exporting
    if vim.bo.modified then
      vim.cmd("write")
    end

    -- Read buffer content and preprocess Obsidian syntax
    local content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    local preprocessed = M.preprocess(content, dir)

    -- Write preprocessed content to a temp file
    local tmpfile = vim.fn.tempname() .. ".md"
    local f = io.open(tmpfile, "w")
    if not f then
      vim.notify("Vault: failed to create temp file for preprocessing", vim.log.levels.ERROR)
      return
    end
    f:write(preprocessed)
    f:close()

    local cmd = {
      "pandoc",
      tmpfile,
      "-o",
      outfile,
      "--standalone",
      "--resource-path=" .. dir .. ":" .. engine.vault_path,
    }

    if format == "pdf" then
      table.insert(cmd, "--pdf-engine=tectonic")
      -- US Letter with 1-inch margins, 12pt Times New Roman (matches Word default)
      table.insert(cmd, "-V")
      table.insert(cmd, "geometry:letterpaper,margin=1in")
      table.insert(cmd, "-V")
      table.insert(cmd, "fontsize=12pt")
      table.insert(cmd, "-V")
      table.insert(cmd, 'mainfont=Times New Roman')
    end

    vim.fn.jobstart(cmd, {
      on_exit = function(_, code)
        -- Clean up temp file regardless of success/failure
        os.remove(tmpfile)
        vim.schedule(function()
          if code == 0 then
            vim.notify("Exported: " .. stem .. "." .. format, vim.log.levels.INFO)
          else
            vim.notify("Vault: pandoc export failed (exit " .. code .. ")", vim.log.levels.ERROR)
          end
        end)
      end,
    })
  end

  if fmt and vim.tbl_contains(formats, fmt) then
    run_export(fmt)
    return
  end

  engine.run(function()
    local choice = engine.select(formats, { prompt = "Export format" })
    if choice then
      run_export(choice)
    end
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("VaultExport", function(args)
    local fmt = args.args ~= "" and args.args or nil
    M.export(fmt)
  end, {
    nargs = "?",
    complete = function()
      return formats
    end,
    desc = "Export current note via pandoc",
  })

  local group = vim.api.nvim_create_augroup("VaultExport", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "<leader>vep", function()
        M.export()
      end, { buffer = ev.buf, desc = "Edit: export (pandoc)", silent = true })
    end,
  })
end

return M
