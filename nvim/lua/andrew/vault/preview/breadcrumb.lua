local config = require("andrew.vault.config")
local engine = require("andrew.vault.engine")
local link_utils = require("andrew.vault.link_utils")
local display_width = require("andrew.vault.text_utils").display_width

--- Breadcrumb formatting for preview float titles.
local M = {}

local DEFAULT_SEPARATOR = " \u{203A} "

--- Split an absolute file path into vault-relative breadcrumb segments.
--- Prepends "Vault" as the root segment.
---@param path string|nil
---@param parent_buf number|nil
---@return string[]
function M.vault_relative_segments(path, parent_buf)
  local abs_path = path
  if not abs_path and parent_buf then
    abs_path = vim.api.nvim_buf_get_name(parent_buf)
  end
  if not abs_path or abs_path == "" then
    return { "Vault" }
  end

  local parts = engine.vault_path_segments(abs_path)
  if not parts then
    -- Not a vault path; show basename only
    return { link_utils.get_tail(abs_path) }
  end

  local segments = { "Vault" }
  for _, seg in ipairs(parts) do
    segments[#segments + 1] = seg
  end
  return segments
end

--- Format a PreviewTarget into float title chunks.
---@param target PreviewTarget
---@param history_pos string  History position string from history.position()
---@return table[]
function M.format(target, history_pos)
  local style = config.preview.breadcrumb_style or "full"

  if style == "none" then
    local title = target.name
    if target.heading then
      title = (target.name ~= "" and target.name or "") .. "#" .. target.heading
    elseif target.block_id then
      title = (target.name ~= "" and target.name or "") .. "^" .. target.block_id
    end
    if history_pos ~= "" then
      title = title .. " " .. history_pos
    end
    return { { " " .. title .. " ", "Function" } }
  end

  local sep = config.preview.breadcrumb_separator or DEFAULT_SEPARATOR
  local sep_hl = "VaultPreviewBreadcrumbSep"
  local path_hl = "VaultPreviewBreadcrumbPath"
  local note_hl = "VaultPreviewBreadcrumbNote"
  local frag_hl = "VaultPreviewBreadcrumbFragment"

  local chunks = {}
  chunks[#chunks + 1] = { " ", sep_hl }

  if style == "short" then
    local note_name = target.name
    if note_name == "" then
      note_name = link_utils.get_basename(
        vim.api.nvim_buf_get_name(target.source_buf or 0)
      )
    end
    chunks[#chunks + 1] = { note_name, note_hl }
  else
    -- Full breadcrumb: Vault > Dir > Note.md
    local segments = M.vault_relative_segments(target.path, target.source_buf)

    for i, seg in ipairs(segments) do
      if i == #segments then
        local display = link_utils.rel_to_stem(seg)
        chunks[#chunks + 1] = { display, note_hl }
      else
        chunks[#chunks + 1] = { seg, path_hl }
      end
      if i < #segments then
        chunks[#chunks + 1] = { sep, sep_hl }
      end
    end
  end

  -- Append heading or block fragment
  if target.heading then
    chunks[#chunks + 1] = { " #" .. target.heading, frag_hl }
  elseif target.block_id then
    chunks[#chunks + 1] = { " ^" .. target.block_id, frag_hl }
  end

  -- Append history position
  if history_pos ~= "" then
    chunks[#chunks + 1] = { " " .. history_pos, sep_hl }
  end

  chunks[#chunks + 1] = { " ", sep_hl }

  return chunks
end

--- Truncate breadcrumb chunks from the left to fit within max_width.
---@param chunks table[]
---@param max_width number
---@return table[]
function M.truncate(chunks, max_width)
  local total_w = 0
  for _, chunk in ipairs(chunks) do
    total_w = total_w + display_width(chunk[1])
  end

  if total_w <= max_width then
    return chunks
  end

  local sep = config.preview.breadcrumb_separator or DEFAULT_SEPARATOR
  local sep_hl = "VaultPreviewBreadcrumbSep"
  local path_hl = "VaultPreviewBreadcrumbPath"
  local ellipsis_w = display_width("\u{2026}" .. sep)

  local first_path_idx = nil
  local last_path_idx = nil
  for i, chunk in ipairs(chunks) do
    if chunk[2] == path_hl then
      if not first_path_idx then first_path_idx = i end
      last_path_idx = i
    end
  end

  if not first_path_idx then
    return chunks
  end

  local result = {}
  local removed_any = false
  local skip_until = 0

  for i, chunk in ipairs(chunks) do
    if i <= skip_until then
      -- skip
    elseif i >= first_path_idx and i <= last_path_idx
           and chunk[2] == path_hl and total_w > max_width then
      local removed_w = display_width(chunk[1])
      total_w = total_w - removed_w

      if chunks[i + 1] and chunks[i + 1][2] == sep_hl
         and chunks[i + 1][1] == sep then
        total_w = total_w - display_width(sep)
        skip_until = i + 1
      end

      if not removed_any then
        result[#result + 1] = { "\u{2026}" .. sep, sep_hl }
        total_w = total_w + ellipsis_w
        removed_any = true
      end
    else
      result[#result + 1] = chunk
    end
  end

  return result
end

return M
