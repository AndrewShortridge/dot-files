--- Pipeline consumer registrations for all highlight modules.
---
--- Registers render consumers that translate resolved tokens into extmark specs.
--- Loaded once during pipeline initialization. Each consumer mirrors the
--- extmark output of its corresponding highlight module.

local link_utils = require("andrew.vault.link_utils")
local log = require("andrew.vault.vault_log").scope("consumers")

local M = {}

--- Wikilink consumer: 4+ extmarks per link (brackets + target + heading/alias).
--- Mirrors wikilink_highlights.lua apply_range() logic.
---@param pipeline table transform_pipeline module
local function register_wikilink_consumer(pipeline)
  local ns = vim.api.nvim_create_namespace("vault_wikilink_hl")

  --- Check if a heading exists in a file via linkdiag.
  ---@param filepath string absolute path
  ---@param heading string
  ---@return boolean
  local function heading_exists(filepath, heading)
    local linkdiag = require("andrew.vault.linkdiag")
    local slug_set = linkdiag.get_headings(filepath)
    local target_slug = link_utils.heading_to_slug(heading)
    return slug_set[target_slug] == true
  end

  local wikilink_hl_mod = require("andrew.vault.wikilink_highlights")

  pipeline.register_consumer({
    name = "wikilinks",
    token_types = { "wikilink" },
    ns = ns,
    priority = 30,
    render = function(line_nr, resolved_tokens)
      if not wikilink_hl_mod.enabled then return {} end
      local specs = {}
      for _, rt in ipairs(resolved_tokens) do
        local tok = rt.token
        -- Token positions: start_col = 0-indexed start of [[, end_col = 0-indexed exclusive end of ]]
        local bracket_open_start = tok.start_col         -- start of first [
        local bracket_open_end = tok.start_col + 2       -- end of second [
        local text_start = tok.start_col + 2             -- start of inner text
        local text_end = tok.end_col - 2                 -- end of inner text (exclusive)
        local bracket_close_start = tok.end_col - 2      -- start of first ]
        local bracket_close_end = tok.end_col             -- end of second ]

        -- Open brackets [[
        specs[#specs + 1] = {
          line = line_nr, col = bracket_open_start,
          opts = { end_col = bracket_open_end, hl_group = "VaultWikiLinkBracket", hl_mode = "combine", priority = 200 },
        }
        -- Close brackets ]]
        specs[#specs + 1] = {
          line = line_nr, col = bracket_close_start,
          opts = { end_col = bracket_close_end, hl_group = "VaultWikiLinkBracket", hl_mode = "combine", priority = 200 },
        }

        local meta = rt.metadata or {}

        if meta.self_ref then
          -- Self-reference: [[#Heading]] or [[^blockid]]
          specs[#specs + 1] = {
            line = line_nr, col = text_start,
            opts = { end_col = text_end, hl_group = "VaultWikiLinkSelf", hl_mode = "combine", priority = 200 },
          }
        elseif rt.status == "broken" then
          -- Broken link
          specs[#specs + 1] = {
            line = line_nr, col = text_start,
            opts = { end_col = text_end, hl_group = "VaultWikiLinkBroken", hl_mode = "combine", priority = 200 },
          }
        elseif rt.status == "valid" or rt.status == "ambiguous" then
          -- Valid note — highlight name portion
          local parsed_name = meta.parsed_name or meta.link_text or ""
          local name_byte_end = text_start + #parsed_name
          specs[#specs + 1] = {
            line = line_nr, col = text_start,
            opts = {
              end_col = math.min(name_byte_end, text_end),
              hl_group = "VaultWikiLinkValid", hl_mode = "combine", priority = 200,
            },
          }

          -- Heading anchor if present
          if meta.heading and rt.target then
            -- Find # position in the inner text
            local inner = tok.captures and tok.captures[1] or ""
            local hash_idx = inner:find("#", 1, true)
            if hash_idx then
              local heading_start = text_start + hash_idx - 1
              local heading_end_pos = heading_start + 1 + #meta.heading
              local h_exists = heading_exists(rt.target, meta.heading)
              specs[#specs + 1] = {
                line = line_nr, col = heading_start,
                opts = {
                  end_col = math.min(heading_end_pos, text_end),
                  hl_group = h_exists and "VaultWikiLinkHeading" or "VaultWikiLinkHeadingBroken",
                  hl_mode = "combine", priority = 200,
                },
              }
            end
          end

          -- Alias if present
          if meta.alias then
            local inner = tok.captures and tok.captures[1] or ""
            local pipe_idx = inner:find("|", 1, true)
            if pipe_idx then
              local pipe_col = text_start + pipe_idx - 1
              specs[#specs + 1] = {
                line = line_nr, col = pipe_col,
                opts = { end_col = text_end, hl_group = "VaultWikiLinkAlias", hl_mode = "combine", priority = 200 },
              }
            end
          end
        end
      end
      return specs
    end,
  })
end

--- Tag consumer: 2 extmarks per tag (hash + text by category).
--- Mirrors tag_highlights.lua process_lines() logic.
---@param pipeline table
local function register_tag_consumer(pipeline)
  local ns = vim.api.nvim_create_namespace("vault_tag_hl")
  local tag_hl_mod = require("andrew.vault.tag_highlights")

  pipeline.register_consumer({
    name = "tags",
    token_types = { "tag" },
    ns = ns,
    priority = 40,
    render = function(line_nr, resolved_tokens)
      if not tag_hl_mod.enabled then return {} end
      local specs = {}
      for _, rt in ipairs(resolved_tokens) do
        local tok = rt.token
        local tag_name = tok.captures and tok.captures[1] or ""

        -- Hash char (#)
        specs[#specs + 1] = {
          line = line_nr, col = tok.start_col,
          opts = { end_col = tok.start_col + 1, hl_group = "VaultTagHash", hl_mode = "combine", priority = 190 },
        }

        -- Tag text with category-based highlight
        local cat = tag_hl_mod.find_tag_category(tag_name)
        local hl = cat and cat.highlight or "VaultTag"
        specs[#specs + 1] = {
          line = line_nr, col = tok.start_col + 1,
          opts = { end_col = tok.end_col, hl_group = hl, hl_mode = "combine", priority = 190 },
        }
      end
      return specs
    end,
  })
end

--- Highlight mark consumer: 3 extmarks per ==text== (open delim + content + close delim).
--- Mirrors highlights.lua process_lines() logic.
---@param pipeline table
local function register_highlight_consumer(pipeline)
  local ns = vim.api.nvim_create_namespace("vault_highlight_hl")
  local highlight_mod = require("andrew.vault.highlights")

  pipeline.register_consumer({
    name = "highlights",
    token_types = { "highlight" },
    ns = ns,
    priority = 50,
    render = function(line_nr, resolved_tokens)
      if not highlight_mod.enabled then return {} end
      local specs = {}
      for _, rt in ipairs(resolved_tokens) do
        local tok = rt.token
        -- tok.start_col = 0-indexed start of first =
        -- tok.end_col = 0-indexed exclusive end of last =

        -- Opening delimiter ==
        specs[#specs + 1] = {
          line = line_nr, col = tok.start_col,
          opts = { end_col = tok.start_col + 2, hl_group = "VaultHighlightDelim", hl_mode = "combine", priority = 195 },
        }

        -- Content between delimiters
        specs[#specs + 1] = {
          line = line_nr, col = tok.start_col + 2,
          opts = { end_col = tok.end_col - 2, hl_group = "VaultHighlight", hl_mode = "combine", priority = 195 },
        }

        -- Closing delimiter ==
        specs[#specs + 1] = {
          line = line_nr, col = tok.end_col - 2,
          opts = { end_col = tok.end_col, hl_group = "VaultHighlightDelim", hl_mode = "combine", priority = 195 },
        }
      end
      return specs
    end,
  })
end

--- Inline field consumer: up to 5 extmarks per field (bracket + key + sep + value + bracket).
--- Mirrors inline_fields.lua highlight_field() logic.
---@param pipeline table
local function register_inline_field_consumer(pipeline)
  local ns = vim.api.nvim_create_namespace("vault_inline_field_hl")
  local inline_fields_mod = require("andrew.vault.inline_fields")

  pipeline.register_consumer({
    name = "inline_fields",
    token_types = { "inline_field" },
    ns = ns,
    priority = 45,
    render = function(line_nr, resolved_tokens)
      if not inline_fields_mod.enabled then return {} end
      local specs = {}
      for _, rt in ipairs(resolved_tokens) do
        local field = rt.token.captures[1]
        if not field then goto next_field end
        local priority = 185
        local row = line_nr

        -- Opening delimiter (bracket or paren)
        if field.syntax == "bracket" or field.syntax == "paren" then
          specs[#specs + 1] = {
            line = row, col = field.col_start,
            opts = { end_col = field.col_start + 1, hl_group = "VaultFieldBracket", hl_mode = "combine", priority = priority },
          }
        end

        -- Key
        specs[#specs + 1] = {
          line = row, col = field.col_key_start,
          opts = { end_col = field.col_key_end, hl_group = "VaultFieldKey", hl_mode = "combine", priority = priority },
        }

        -- Separator ::
        specs[#specs + 1] = {
          line = row, col = field.col_sep_start,
          opts = { end_col = field.col_sep_end, hl_group = "VaultFieldSep", hl_mode = "combine", priority = priority },
        }

        -- Value (type-aware highlighting)
        if field.value ~= "" then
          specs[#specs + 1] = {
            line = row, col = field.col_val_start,
            opts = { end_col = field.col_val_end, hl_group = inline_fields_mod.value_highlight(inline_fields_mod.classify_value(field.value)), hl_mode = "combine", priority = priority },
          }
        end

        -- Closing delimiter
        if field.syntax == "bracket" or field.syntax == "paren" then
          specs[#specs + 1] = {
            line = row, col = field.col_end - 1,
            opts = { end_col = field.col_end, hl_group = "VaultFieldBracket", hl_mode = "combine", priority = priority },
          }
        end

        ::next_field::
      end
      return specs
    end,
  })
end

--- Register all pipeline consumers.
--- Called once during pipeline initialization.
--- NOTE: Footnotes and autolink are NOT registered as consumers.
--- Footnotes uses complex virt_lines rendering; autolink uses name-based matching
--- that doesn't fit the token-based model. They're dispatched via the
--- uncovered-updater fallback in highlight_coordinator.run_all().
---@param pipeline table transform_pipeline module
function M.register_all(pipeline)
  register_wikilink_consumer(pipeline)
  register_tag_consumer(pipeline)
  register_highlight_consumer(pipeline)
  register_inline_field_consumer(pipeline)
  log.info("registered %d pipeline consumers", 4)
end

return M
