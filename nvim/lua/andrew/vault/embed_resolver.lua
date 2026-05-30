--- Content resolution for the embed system.
--- Pure resolution logic: recursive embed resolution with cycle detection,
--- depth limits, and line budget system.
local wikilinks = require("andrew.vault.wikilinks")
local config = require("andrew.vault.config")
local link_utils = require("andrew.vault.link_utils")
local state = require("andrew.vault.embed_state")
local images = require("andrew.vault.embed_images")

local M = {}

--- Resolve an embed link name to an absolute file path.
---@param name string note name (without .md)
---@param bufpath string buffer file path for same-file resolution
---@return string|nil
function M.resolve_embed(name, bufpath)
  if name == "" then
    return bufpath
  end
  return wikilinks.resolve_link(name)
end

--- Get the content lines for an embed.
---@param details {name: string, heading: string|nil, block_id: string|nil}
---@param source string|string[] resolved file path or buffer lines array
---@param line_budget number|nil max lines to return (nil = use config defaults)
---@return string[]
---@return boolean truncated
local function get_embed_content(details, source, line_budget)
  local max_lines
  if not details.heading and not details.block_id then
    max_lines = config.embed.max_lines
    if line_budget and line_budget < max_lines then
      max_lines = line_budget
    end
  elseif line_budget then
    max_lines = line_budget
  end

  return link_utils.resolve_content(details, source, { max_lines = max_lines })
end

--- Build the cycle path string for display.
---@param visited_list string[] ordered list of visited file paths
---@param cycle_target string the path that closes the cycle
---@return string
local function format_cycle_path(visited_list, cycle_target)
  local names = {}
  for _, p in ipairs(visited_list) do
    names[#names + 1] = link_utils.get_basename(p)
  end
  names[#names + 1] = link_utils.get_basename(cycle_target)
  return table.concat(names, " \u{2192} ")
end

--- Recursively resolve embed content, handling nested ![[...]] patterns.
---@param details {name: string, heading: string|nil, block_id: string|nil}
---@param source string|string[] resolved file path or buffer lines array
---@param depth number current nesting depth (0 = first level)
---@param visited_set table<string, boolean> set of absolute paths in current chain
---@param visited_list string[] ordered list of absolute paths for cycle display
---@param budget number|nil remaining line budget (nil = unlimited)
---@param bufpath string buffer file path
---@return string[] resolved_lines
---@return number lines_consumed
function M.resolve_embed_lines(details, source, depth, visited_set, visited_list, budget, bufpath)
  local max_depth = config.embed.max_depth

  if depth > max_depth then
    return { "\u{22ef} (max embed depth reached)" }, 1
  end

  if budget and budget <= 0 then
    return { "\u{22ef} (total line limit reached)" }, 1
  end

  local target_path
  if type(source) == "table" then
    target_path = bufpath
  else
    target_path = source
  end

  if target_path and visited_set[target_path] then
    return { "\u{21bb} cycle: " .. format_cycle_path(visited_list, target_path) }, 1
  end

  local content, content_truncated = get_embed_content(details, source, budget)
  if #content == 0 then
    return content, 0
  end

  if depth == max_depth then
    local used = #content
    if content_truncated then
      content[#content + 1] = "\u{22ef} (truncated)"
      used = used + 1
    end
    return content, used
  end

  local pushed = false
  if target_path then
    visited_set[target_path] = true
    visited_list[#visited_list + 1] = target_path
    pushed = true
  end

  local resolved = {}
  local remaining = budget

  local function append(line)
    resolved[#resolved + 1] = line
    if remaining then remaining = remaining - 1 end
  end

  for _, cline in ipairs(content) do
    if remaining and remaining <= 0 then
      resolved[#resolved + 1] = "\u{22ef} (total line limit reached)"
      break
    end

    local spans = state.find_embed_spans(cline)

    if not spans then
      append(cline)
    else
      local purely_embeds = state.is_purely_embeds(cline, spans)

      if not purely_embeds then
        append(cline)
      else
        for k = 1, #spans, 2 do
          if remaining and remaining <= 0 then
            resolved[#resolved + 1] = "\u{22ef} (total line limit reached)"
            break
          end
          local s, e = spans[k], spans[k + 1]
          local inner_text = state.extract_embed_inner(cline, s, e)

          if images.is_image_embed(inner_text) then
            append(cline:sub(s, e))
          else
            local inner_details = link_utils.parse_target(inner_text)
            local inner_path = M.resolve_embed(inner_details.name, bufpath)

            if inner_path then
              local inner_lines, inner_used = M.resolve_embed_lines(
                inner_details, inner_path,
                depth + 1, visited_set, visited_list,
                remaining, bufpath
              )
              for _, il in ipairs(inner_lines) do
                resolved[#resolved + 1] = il
              end
              if remaining then remaining = remaining - inner_used end
            else
              append("[Could not resolve: " .. inner_details.name .. "]")
            end
          end
        end
      end
    end
  end

  if pushed then
    visited_set[target_path] = nil
    visited_list[#visited_list] = nil
  end

  if content_truncated and (not remaining or remaining > 0) then
    resolved[#resolved + 1] = "\u{22ef} (truncated)"
  end

  local total_used = budget and (budget - (remaining or 0)) or #resolved
  return resolved, total_used
end

return M
