local engine = require("andrew.vault.engine")
local file_cache = require("andrew.vault.file_cache")
local link_scan = require("andrew.vault.link_scan")
local config = require("andrew.vault.config")
local notify = require("andrew.vault.notify")
local utils = require("andrew.vault.unlinked.utils")
local semaphore = require("andrew.vault.process_semaphore")
local pat = require("andrew.vault.patterns")

local M = {}


--- Build a PCRE2 alternation pattern for a list of names with word boundaries.
---@param names string[]
---@return string
local function build_rg_pattern(names)
  local escaped = {}
  for _, name in ipairs(names) do
    escaped[#escaped + 1] = engine.rg_escape(name)
  end
  if #escaped == 0 then return "" end
  table.sort(escaped, function(a, b) return #a > #b end)
  return "\\b(" .. table.concat(escaped, "|") .. ")\\b"
end

--- Parse a ripgrep output line in the format: file:line:col:text
---@param rg_line string
---@return { file: string, line: number, col: number, text: string }|nil
local function parse_rg_line(rg_line)
  local file, lnum, col, text = rg_line:match("^(.+):(%d+):(%d+):(.*)$")
  if file then
    return { file = file, line = tonumber(lnum), col = tonumber(col), text = text }
  end
  return nil
end

--- Run ripgrep to find unlinked mentions and return raw results.
---@param names string[] note names to search for
---@param exclude_path string|nil path to exclude (current note)
---@param callback fun(results: { file: string, line: number, col: number, text: string }[])
function M.rg_search(names, exclude_path, callback)
  local pattern = build_rg_pattern(names)
  if pattern == "" then
    vim.schedule(function() callback({}) end)
    return
  end

  local cmd = {
    "rg", "--column", "--line-number", "--no-heading", "--color=never",
    "-i", "--glob", "*.md", pattern, engine.vault_path,
  }

  semaphore.acquire(semaphore.rg_semaphore(), function(release)
    vim.system(cmd, { text = true }, function(result)
      release()
      local results = {}
      if result.code == 0 and result.stdout and result.stdout ~= "" then
        for line in result.stdout:gmatch(pat.LINE_NONEMPTY) do
          local parsed = parse_rg_line(line)
          if parsed then
            if not exclude_path or parsed.file ~= exclude_path then
              results[#results + 1] = parsed
            end
          end
        end
      elseif result.code ~= 0 and result.code ~= 1 and result.stderr and result.stderr ~= "" then
        vim.schedule(function()
          notify.error("rg error: " .. vim.trim(result.stderr))
        end)
      end
      vim.schedule(function() callback(results) end)
    end)
  end)
end

--- Filter out self-mentions (matches found in their own source file).
---@param results table[] ripgrep results with .file and .text
---@param entries { name: string, name_lower: string, path: string }[] name-to-path mappings
---@return table[]
function M.filter_self_mentions(results, entries)
  local filtered = {}
  for _, r in ipairs(results) do
    local dominated = false
    local line_lower = r.text:lower()
    for _, entry in ipairs(entries) do
      if r.file == entry.path and line_lower:find(entry.name_lower, 1, true) then
        dominated = true
        break
      end
    end
    if not dominated then
      filtered[#filtered + 1] = r
    end
  end
  return filtered
end

--- Apply Lua post-filters to ripgrep results.
---@param results { file: string, line: number, col: number, text: string }[]
---@param names string[] the names being searched (for match length calculation)
---@return { file: string, line: number, col: number, text: string, match: string }[]
function M.filter_results(results, names)
  if #results == 0 then return {} end

  local by_file = utils.group_by_file(results)

  local name_lower_set = {}
  for _, name in ipairs(names) do
    name_lower_set[name:lower()] = name
  end

  local batch = config.autolink.batch
  local case_sensitive = batch and batch.case_sensitive_single_word or false
  local filtered = {}

  for file, file_results in pairs(by_file) do
    local lines = file_cache.read(file)
    if lines and #lines > 0 then
      for _, r in ipairs(file_results) do
        local skip = false
        local line_text = lines[r.line] or r.text

        if link_scan.is_in_frontmatter_lines(lines, r.line) then skip = true end
        if not skip and link_scan.is_in_fenced_code_lines(lines, r.line) then skip = true end
        if not skip and link_scan.is_heading_line(line_text) then skip = true end

        if not skip then
          local line_lower = line_text:lower()
          local link_ranges = link_scan.get_link_ranges(line_text)
          for name_lower, original_name in pairs(name_lower_set) do
            local ms, me = utils.find_name_at_col(line_lower, name_lower, r.col)
            if ms then
              if link_scan.overlaps_range(ms - 1, me, link_ranges) then
                skip = true
                break
              end
              if link_scan.is_inside_code_span(line_text, ms) then
                skip = true
                break
              end
              if case_sensitive and link_scan.word_count(original_name) == 1 then
                if not line_text:find(original_name, 1, true) then
                  skip = true
                  break
                end
              end
              r.match = original_name
              break
            end
          end
        end

        if not skip and r.match then
          filtered[#filtered + 1] = r
        end
      end
    end
  end

  return filtered
end

return M
