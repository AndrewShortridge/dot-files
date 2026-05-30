local link_utils = require("andrew.vault.link_utils")
local wikilinks = require("andrew.vault.wikilinks")

--- Target resolution for preview navigation.
local M = {}

---@class PreviewTarget
---@field path string|nil      Absolute file path (nil for same-file references)
---@field name string          Display name from the wikilink
---@field heading string|nil   Heading fragment (without #)
---@field block_id string|nil  Block ID fragment (without ^)
---@field lines string[]       Resolved content lines to display
---@field source_buf number|nil  Buffer number for same-file references

--- Build a PreviewTarget from parsed wikilink details.
---@param details { name: string, heading: string|nil, block_id: string|nil }
---@param parent_buf number  Buffer from which the preview was triggered
---@return PreviewTarget|nil
function M.resolve(details, parent_buf)
  local target = {
    name = details.name,
    heading = details.heading,
    block_id = details.block_id,
    path = nil,
    lines = {},
    source_buf = nil,
  }

  if details.name == "" then
    -- Same-file reference: [[#heading]] or [[^block-id]]
    if not details.heading and not details.block_id then return nil end
    target.source_buf = parent_buf
    local buf_lines = vim.api.nvim_buf_get_lines(parent_buf, 0, -1, false)
    target.lines = link_utils.resolve_content(details, buf_lines)
  else
    -- Cross-file reference
    local path = wikilinks.resolve_link(details.name)
    if path then
      target.path = path
      target.lines = link_utils.resolve_content(details, path)
    else
      target.lines = { "[Note does not exist yet]" }
    end
  end

  return target
end

--- Resolve a target from within the preview context.
--- For same-file refs inside a preview, the "file" is the preview target's file.
---@param details { name: string, heading: string|nil, block_id: string|nil }
---@param current_entry PreviewTarget|nil  Current history entry
---@param parent_buf number  Parent buffer fallback
---@return PreviewTarget|nil
function M.resolve_in_preview(details, current_entry, parent_buf)
  if details.name == "" and current_entry and current_entry.path then
    -- Same-file heading/block ref within previewed note — resolve against
    -- the previewed file, not the parent buffer.
    if not details.heading and not details.block_id then return nil end
    return {
      name = "",
      heading = details.heading,
      block_id = details.block_id,
      path = current_entry.path,
      lines = link_utils.resolve_content(details, current_entry.path),
      source_buf = nil,
    }
  end

  -- Cross-file or same-file ref with parent buffer context
  return M.resolve(details, parent_buf)
end

return M
