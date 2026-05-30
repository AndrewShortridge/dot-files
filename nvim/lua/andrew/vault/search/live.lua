local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local notify = require("andrew.vault.notify")
local filter_utils = require("andrew.vault.filter_utils")
local search_filter = require("andrew.vault.search_filter")
local vault_index -- lazy loaded
local function get_vault_index()
  if not vault_index then vault_index = require("andrew.vault.vault_index") end
  return vault_index
end
local track = require("andrew.vault.search.track").track

local M = {}

--- Advanced search: live mode.
--- Uses fzf_live with a provider function that re-evaluates the query on each keystroke.
function M.search_advanced_live()
  local search_query = require("andrew.vault.search_query")
  local advanced = require("andrew.vault.search.advanced")
  local stats = require("andrew.vault.search.stats")
  local fzf = require("fzf-lua")

  local idx = get_vault_index().current()
  if not idx or not idx:is_ready() then
    notify.info("Index building, search will start when ready...")
    if idx then
      idx:wait_for_ready(function()
        vim.schedule(function()
          M.search_advanced_live()
        end)
      end, "search.live.deferred")
    end
    return
  end

  local debounce = config.search.live_debounce_ms
  local last_live_query = ""
  -- Capture the source buffer path before fzf opens (for graph: center resolution)
  local source_path = vim.api.nvim_buf_get_name(0)

  local search_group = require("andrew.vault.search_group")
  local warned_queries = {}

  -- Incremental filtering cache: reuse previous result set when query is more restrictive
  local _prev_cache = { query = nil, ast = nil, file_set = nil, gen = nil }

  fzf.fzf_live(function(args)
    local query_string = type(args) == "table" and args[1] or args
    if type(query_string) ~= "string" or query_string == "" then return {} end
    last_live_query = query_string

    local t_start = vim.uv.hrtime()

    local ast, _, group_mode = search_query.parse_query(query_string)
    if not ast then return {} end

    -- Field name warnings (once per unique query in live mode)
    if not warned_queries[query_string] then
      warned_queries[query_string] = true
      vim.schedule(function()
        stats.warn_unknown_fields(ast, idx)
      end)
    end

    -- Incremental filtering: reuse previous result set when the new query
    -- is strictly more restrictive than the previous one.
    -- Two checks: (1) string prefix heuristic, (2) AST superset analysis.
    local restrict_to = nil
    local cur_gen = idx._generation
    if _prev_cache.file_set and _prev_cache.query
      and filter_utils.is_cache_gen_valid(_prev_cache, cur_gen) then
      local is_prefix = #query_string > #_prev_cache.query
        and query_string:sub(1, #_prev_cache.query) == _prev_cache.query
      if is_prefix then
        -- String prefix is a necessary but not sufficient condition.
        -- Also verify via AST superset check for safety.
        if search_filter.is_ast_superset(_prev_cache.ast, ast) then
          restrict_to = _prev_cache.file_set
        end
      end
    end

    local result, effective_group_mode, metadata_matches
    result, effective_group_mode, metadata_matches = advanced.evaluate_advanced_ast(
      ast, group_mode, idx, source_path, restrict_to)

    -- Update incremental cache
    _prev_cache.query = query_string
    _prev_cache.ast = ast
    _prev_cache.file_set = metadata_matches
    _prev_cache.gen = cur_gen

    -- Prepend stats line if configured
    if config.search.show_stats ~= false and #result.entries > 0 then
      local elapsed_ms = math.floor((vim.uv.hrtime() - t_start) / 1e6)
      local ansi = require("andrew.vault.ansi")
      local limit_indicator = ""
      if result.limit_reached then
        limit_indicator = " [results truncated]"
      end
      local stats_str = string.format(
        "%s%s%s%s%s",
        search_group.HEADER_PREFIX,
        ansi.dim,
        stats.format_stats(result.entries, effective_group_mode, elapsed_ms),
        limit_indicator,
        ansi.reset
      )
      table.insert(result.entries, 1, stats_str)
    end

    return result.entries
  end, vim.tbl_extend("force",
    engine.vault_fzf_opts("Advanced live search"),
    {
      actions = {
        ["default"] = function(selected, fzf_opts)
          if last_live_query ~= "" then
            track(last_live_query, "all", "advanced", true)
          end
          local filtered = search_group.filter_selected(selected)
          if #filtered > 0 then
            require("fzf-lua").actions.file_edit(filtered, fzf_opts)
          end
        end,
        ["ctrl-/"] = { fn = function() require("andrew.vault.search.help").search_help() end, reload = false },
        ["ctrl-s"] = require("fzf-lua").actions.file_split,
        ["ctrl-v"] = require("fzf-lua").actions.file_vsplit,
        ["ctrl-t"] = require("fzf-lua").actions.file_tabedit,
      },
      fzf_opts = {
        ["--header"] = advanced.SEARCH_HEADER,
        ["--ansi"] = "",
        ["--no-sort"] = "",
      },
      previewer = "builtin",
      exec_empty_query = false,
      query_delay = debounce,
    }
  ))
end

--- Build a restrict_to table (rel_path -> entry) from absolute file paths.
--- This lets evaluate_advanced_ast constrain queries to a specific file subset.
---@param file_paths string[] absolute file paths
---@param idx table VaultIndex instance
---@return table<string, table> restrict_to map
local function build_restrict_to(file_paths, idx)
  local abs_set = {}
  for _, p in ipairs(file_paths) do abs_set[p] = true end
  -- Use a snapshot for consistent reads (matches search_filter pattern).
  local files = idx:snapshot_files()
  local restrict_to = {}
  for rel_path, entry in pairs(files) do
    if abs_set[entry.abs_path] then
      restrict_to[rel_path] = entry
    end
  end
  return restrict_to
end

--- Run advanced live search restricted to a specific set of files.
--- Reuses evaluate_advanced_ast with a restrict_to constraint built from file_paths.
---@param file_paths string[] absolute file paths to search within
function M.search_in_files(file_paths)
  if #file_paths == 0 then
    notify.info("no files to search")
    return
  end

  local fzf = require("fzf-lua")
  local search_query = require("andrew.vault.search_query")
  local advanced = require("andrew.vault.search.advanced")

  local idx = get_vault_index().current()
  if not idx or not idx:is_ready() then
    notify.info("Index building, search will start when ready...")
    if idx then
      idx:wait_for_ready(function()
        vim.schedule(function()
          M.search_in_files(file_paths)
        end)
      end, "search.files.deferred")
    end
    return
  end

  local restrict_to = build_restrict_to(file_paths, idx)
  local source_path = vim.api.nvim_buf_get_name(0)

  fzf.fzf_live(function(args)
    local query_string = type(args) == "table" and args[1] or args
    if type(query_string) ~= "string" or query_string == "" then return {} end

    local ast, _, group_mode = search_query.parse_query(query_string)
    if not ast then return {} end

    local result = advanced.evaluate_advanced_ast(
      ast, group_mode, idx, source_path, restrict_to)

    return result and result.entries or {}
  end, vim.tbl_extend("force",
    engine.vault_fzf_opts("Search in graph nodes"),
    {
      previewer = "builtin",
      exec_empty_query = false,
      query_delay = config.search.live_debounce_ms,
    }
  ))
end

return M
