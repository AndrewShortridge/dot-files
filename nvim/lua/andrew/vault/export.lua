local engine = require("andrew.vault.engine")
local wikilinks = require("andrew.vault.wikilinks")
local link_utils = require("andrew.vault.link_utils")
local notify = require("andrew.vault.notify")
local embed_images = require("andrew.vault.embed_images")
local callout_utils = require("andrew.vault.callout_utils")
local file_cache = require("andrew.vault.file_cache")
local pat = require("andrew.vault.patterns")

local M = {}

local formats = { "pdf", "docx", "html" }

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

--- Convert a single wikilink match to a standard markdown link.
--- Handles: [[Name]], [[Name|Alias]], [[Name#Heading]], [[Name#Heading|Alias]],
---          [[Name^block]], [[Name#Heading^block|Alias]]
---@param inner string the content between [[ and ]]
---@return string markdown link
local function convert_wikilink(inner)
  local details = link_utils.parse_target(inner)

  -- Build display text
  local display
  if details.alias then
    display = details.alias
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
    dest = dest .. "#" .. link_utils.heading_to_slug(details.heading)
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
  local details = link_utils.parse_target(inner)

  -- Image embed: ![[image.png]] or ![[path/image.png]]
  if embed_images.is_image_embed(inner) then
    local alt = details.alias or link_utils.get_basename(details.name)
    local resolved = resolve_attachment(details.name, buf_dir)
    return "![" .. alt .. "](" .. resolved .. ")"
  end

  -- Note embed: resolve and inline content
  local path = wikilinks.resolve_link(details.name)

  if not path then
    return "> *[Embed not found: " .. inner .. "]*"
  end

  local content_lines
  if details.block_id then
    content_lines = link_utils.read_block_content(path, details.block_id)
    if not content_lines or #content_lines == 0 then
      return "> *[Block not found: ^" .. details.block_id .. "]*"
    end
  elseif details.heading then
    content_lines = link_utils.read_heading_section(path, details.heading)
    if #content_lines == 0 then
      return "> *[Heading not found: #" .. details.heading .. "]*"
    end
  else
    content_lines = file_cache.read(path)
    if #content_lines == 0 then
      return "> *[Could not read: " .. details.name .. "]*"
    end
    -- Strip frontmatter from embedded notes
    if content_lines[1] and content_lines[1]:match(pat.FM_OPEN) then
      local fm_end = nil
      for i = 2, #content_lines do
        if content_lines[i]:match(pat.FM_OPEN) then
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
  local blocks = callout_utils.scan_blocks(lines)

  -- Build a set of line ranges owned by callout blocks
  local block_by_start = {}
  for _, b in ipairs(blocks) do
    block_by_start[b.start_line] = b
  end

  local result = {}
  local i = 1
  while i <= #lines do
    local b = block_by_start[i]
    if b then
      local kind, label = callout_label(b.ctype)
      local heading = b.title ~= "" and b.title or label

      result[#result + 1] = "::: {.callout-" .. kind .. "}"
      result[#result + 1] = "**" .. heading .. "**"
      result[#result + 1] = ""

      for _, cl in ipairs(b.content_lines) do
        result[#result + 1] = cl:gsub("^>%s?", "")
      end

      result[#result + 1] = ":::"
      result[#result + 1] = ""
      i = b.end_line + 1
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
  for line in (content .. "\n"):gmatch(pat.LINE_CAPTURE) do
    lines[#lines + 1] = line
  end

  -- Single pass: convert embeds, then wikilinks on each resulting line
  local converted_lines = {}
  for _, line in ipairs(lines) do
    -- Step 1: Convert embeds (![[...]]) — must happen before wikilinks
    local embed_converted = line:gsub(pat.EMBED, function(inner)
      return convert_embed(inner, buf_dir)
    end)
    -- An embed conversion may produce multiple lines; split and process each
    for sub in (embed_converted .. "\n"):gmatch(pat.LINE_CAPTURE) do
      -- Step 2: Convert remaining wikilinks ([[...]])
      local wikilink_converted = sub:gsub(pat.WIKILINK, function(inner)
        return convert_wikilink(inner)
      end)
      converted_lines[#converted_lines + 1] = wikilink_converted
    end
  end

  -- Convert Obsidian callouts to Pandoc fenced divs (requires full line context)
  local result = convert_callouts(converted_lines)

  return table.concat(result, "\n")
end

--- Export current markdown buffer via pandoc.
---@param fmt string|nil output format (pdf, docx, html). Prompts if nil.
function M.export(fmt)
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" or not bufname:match(pat.MD_EXTENSION) then
    notify.warn("current buffer is not a markdown file")
    return
  end

  local function run_export(format)
    local stem = link_utils.get_basename(bufname)
    local dir = link_utils.lua_dirname(bufname)
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
      notify.error("failed to create temp file for preprocessing")
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
            notify.info("exported " .. stem .. "." .. format)
          else
            notify.error("pandoc export failed (exit " .. code .. ")")
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

return M
