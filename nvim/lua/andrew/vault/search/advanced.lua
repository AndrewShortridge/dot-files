local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local notify = require("andrew.vault.notify")
local search_group = require("andrew.vault.search_group")
local search_filter = require("andrew.vault.search_filter")
local operation_tracker = require("andrew.vault.operation_tracker")
local stats -- lazy-loaded on first use

local M = {}

-- Track active async metadata evaluation for cancellation
local _active_eval_cancel = nil

-- Shared operation tracker for discarding stale async search results.
-- Replaces the ad-hoc _search_generation counter.
local search_ops = operation_tracker.new()

-- Expose for debug command (VaultOpsDebug)
M._ops = search_ops

--- Start an async metadata evaluation with cancellation tracking.
--- Consolidates the repeated cancel-previous / register-new / evaluate_async pattern.
---@param metadata_ast table parsed metadata AST
---@param idx table VaultIndex instance
---@param graph_sets table|nil pre-computed graph reachable sets
---@param restrict_to table|nil optional subset to filter
---@param callback fun(matches: table, limit_reached: boolean) called on completion (not called if cancelled)
local function eval_async_cancellable(metadata_ast, idx, graph_sets, restrict_to, callback)
  local cancelled = false
  if _active_eval_cancel then _active_eval_cancel() end
  local op_id = search_ops:start()
  _active_eval_cancel = function() cancelled = true end

  search_filter.evaluate_async(metadata_ast, idx, {
    graph_sets = graph_sets,
    restrict_to = restrict_to,
    cancelled = function() return cancelled end,
    callback = function(matches, limit_reached)
      _active_eval_cancel = nil
      -- Race guard: cancel could be called after the coroutine completes but
      -- before vim.schedule delivers this callback.
      if cancelled then return end
      if search_ops:is_stale(op_id) then return end
      callback(matches, limit_reached)
    end,
  })
  return op_id
end

--- Compact syntax hint shown in fzf header for both prompt and live modes.
M.SEARCH_HEADER = table.concat({
  "field:value  tag:x  task-due:<7d  has:tags  created:>7d  graph:depth=2  group:folder",
  "AND  OR  NOT  -excluded  (a OR b) AND c   |  Ctrl-/ full help  Ctrl-g graph",
}, "\n")

--- Apply grouping to a result if requested.
---@param result table { entries, needs_previewer, ... }
---@param group_mode string|nil
---@param idx table VaultIndex instance
---@return table result (mutated)
local function apply_grouping(result, group_mode, idx)
  if group_mode and group_mode ~= "none" and #result.entries > 0 then
    local grouping_cfg = config.search.grouping
    local spec = {
      reverse = grouping_cfg.date_newest_first ~= false, -- default true
      tag_level = grouping_cfg.tag_level or "prefix",
    }
    local grouped = search_group.group_entries(result.entries, group_mode, idx, spec)
    result.entries = grouped.entries
  end
  return result
end

--- Build a result table with grouping and limit_reached in one step.
---@param entries table list of result entries
---@param needs_previewer boolean whether results need fzf previewer
---@param limit_reached boolean|nil whether results were truncated
---@param group_mode string|nil grouping mode
---@param idx table VaultIndex instance
---@return table result
local function make_result(entries, needs_previewer, limit_reached, group_mode, idx)
  local result = apply_grouping({ entries = entries, needs_previewer = needs_previewer }, group_mode, idx)
  result.limit_reached = limit_reached
  return result
end

--- Collect absolute file paths from an index file table.
---@param files table<string, table> rel_path -> entry with abs_path field
---@return string[]
local function collect_abs_paths(files)
  local paths = {}
  for _, entry in pairs(files) do
    paths[#paths + 1] = entry.abs_path
  end
  return paths
end

--- Finish the metadata_then_text path: if ripgrep returned content matches use
--- those; otherwise fall back to plain metadata match paths.
---@param results string[] ripgrep result lines
---@param rg_limit boolean|nil whether ripgrep hit its limit
---@param matches table metadata matches (rel_path -> entry)
---@param limit_reached boolean|nil whether metadata evaluation hit its limit
---@param group_mode string|nil grouping mode
---@param idx table VaultIndex instance
---@return table result
---@return table matches
local function finish_metadata_then_text(results, rg_limit, matches, limit_reached, group_mode, idx)
  if #results > 0 then
    return make_result(results, true, limit_reached or rg_limit, group_mode, idx), matches
  end
  -- AND semantics: no text matches means no results
  local result = make_result({}, false, limit_reached or rg_limit, group_mode, idx)
  return result, matches
end

--- Finish the mixed_or path: union metadata-only matches with ripgrep content
--- matches, deduplicating files that appear in both sets.
---@param rg_results string[] ripgrep result lines
---@param rg_limit boolean|nil whether ripgrep hit its limit
---@param meta_matches table metadata matches (rel_path -> entry)
---@param limit_reached_meta boolean|nil whether metadata evaluation hit its limit
---@param group_mode string|nil grouping mode
---@param idx table VaultIndex instance
---@return table result
local function finish_mixed_or(rg_results, rg_limit, meta_matches, limit_reached_meta, group_mode, idx)
  local rg_files = search_filter.collect_file_set(rg_results)
  local result_entries = {}
  for rel_path, entry in pairs(meta_matches) do
    if not rg_files[entry.abs_path] and not rg_files[rel_path] then
      result_entries[#result_entries + 1] = rel_path
    end
  end
  for _, line in ipairs(rg_results) do
    result_entries[#result_entries + 1] = line
  end
  return make_result(result_entries, #rg_results > 0, limit_reached_meta or rg_limit, group_mode, idx)
end

--- Dispatch a ripgrep call synchronously or asynchronously.
--- @param text_ast table text AST for ripgrep
--- @param file_paths string[] absolute file paths to search
--- @param vault_path string vault root
--- @param on_done fun|nil async callback (nil = sync mode)
--- @param finish fun(results: string[], rg_limit: boolean|nil): any... callback that transforms ripgrep output into final return values
--- @param op_id number|nil operation ID to check before delivering async results
--- @return any ... finish(...) return values in sync mode; nil in async mode
local function dispatch_ripgrep(text_ast, file_paths, vault_path, on_done, finish, op_id)
  if on_done then
    search_filter.ripgrep_in_files(text_ast, file_paths, vault_path, function(results, rg_limit)
      -- Discard stale ripgrep results if a newer search has started
      if op_id and search_ops:is_stale(op_id) then return end
      on_done(finish(results, rg_limit))
    end)
    return nil
  end
  local results, rg_limit = search_filter.ripgrep_in_files(text_ast, file_paths, vault_path)
  return finish(results, rg_limit)
end

--- Evaluate a split AST against the vault index and ripgrep, returning display entries.
--- Shared by both prompt mode (execute_advanced_query) and live mode (search_advanced_live).
---
--- When on_done is provided, ripgrep calls run asynchronously (non-blocking).
--- When on_done is nil, runs synchronously (blocking, for fzf_live compatibility).
---
---@param split table from search_filter.split_ast()
---@param idx table VaultIndex instance
---@param vault_path string
---@param graph_sets table|nil pre-computed graph reachable sets
---@param group_mode? string optional grouping mode from group: directive
---@param restrict_to table|nil optional subset to filter (rel_path -> entry)
---@param on_done? fun(result: table, metadata_matches: table|nil) async callback
---@return table|nil { entries: string[], needs_previewer: boolean }
---@return table|nil metadata_matches for incremental caching
local function resolve_query(split, idx, vault_path, graph_sets, group_mode, restrict_to, on_done)
  -- When iterating the full index (no restrict_to), take a snapshot for
  -- consistent reads. This matches the pattern in search_filter.prepare_evaluate().
  local snap_files = restrict_to or idx:snapshot_files()

  if split.mode == "metadata_only" then
    if on_done then
      eval_async_cancellable(split.metadata_ast, idx, graph_sets, restrict_to,
        function(matches, limit_reached)
          local entries = {}
          for rel_path, _ in pairs(matches) do
            entries[#entries + 1] = rel_path
          end
          table.sort(entries)
          on_done(make_result(entries, false, limit_reached, group_mode, idx), matches)
        end)
      return nil
    end

    local matches, limit_reached = search_filter.evaluate(split.metadata_ast, idx, graph_sets, restrict_to)
    local entries = {}
    for rel_path, _ in pairs(matches) do
      entries[#entries + 1] = rel_path
    end
    table.sort(entries)
    return make_result(entries, false, limit_reached, group_mode, idx), matches
  end

  if split.mode == "text_only" then
    local file_paths = collect_abs_paths(snap_files)
    local op_id = nil
    if on_done then
      -- Start a new operation so a superseding search discards these results
      op_id = search_ops:start()
    end

    return dispatch_ripgrep(split.text_ast, file_paths, vault_path, on_done, function(results, rg_limit)
      return make_result(results, true, rg_limit, group_mode, idx), nil
    end, op_id)
  end

  if split.mode == "metadata_then_text" then
    if on_done then
      local op_id = eval_async_cancellable(split.metadata_ast, idx, graph_sets, restrict_to,
        function(matches, limit_reached)
          local file_paths_inner = collect_abs_paths(matches)
          if #file_paths_inner == 0 then
            on_done(make_result({}, false, limit_reached, group_mode, idx), matches)
            return
          end
          dispatch_ripgrep(split.text_ast, file_paths_inner, vault_path, on_done, function(results, rg_limit)
            return finish_metadata_then_text(results, rg_limit, matches, limit_reached, group_mode, idx)
          end, op_id)
        end)
      return nil
    end

    local matches, limit_reached = search_filter.evaluate(split.metadata_ast, idx, graph_sets, restrict_to)
    local file_paths = collect_abs_paths(matches)

    if #file_paths == 0 then
      return make_result({}, false, limit_reached, group_mode, idx), matches
    end

    return dispatch_ripgrep(split.text_ast, file_paths, vault_path, nil, function(results, rg_limit)
      return finish_metadata_then_text(results, rg_limit, matches, limit_reached, group_mode, idx)
    end)
  end

  -- mixed_or: evaluate both metadata and text, union results
  if on_done and split.metadata_ast then
    local op_id = eval_async_cancellable(split.metadata_ast, idx, graph_sets, restrict_to,
      function(meta_matches, limit_reached_meta)
        local file_paths_inner = collect_abs_paths(snap_files)
        dispatch_ripgrep(split.text_ast, file_paths_inner, vault_path, on_done, function(rg_results, rg_limit)
          return finish_mixed_or(rg_results, rg_limit, meta_matches, limit_reached_meta, group_mode, idx), nil
        end, op_id)
      end)
    return nil
  end

  local meta_matches = {}
  local limit_reached_meta = false
  if split.metadata_ast then
    meta_matches, limit_reached_meta = search_filter.evaluate(split.metadata_ast, idx, graph_sets, restrict_to)
  end
  local file_paths = collect_abs_paths(snap_files)
  local op_id = nil
  if on_done then
    op_id = search_ops:start()
  end

  return dispatch_ripgrep(split.text_ast, file_paths, vault_path, on_done, function(rg_results, rg_limit)
    return finish_mixed_or(rg_results, rg_limit, meta_matches, limit_reached_meta, group_mode, idx), nil
  end, op_id)
end

--- Parse, split, and evaluate an advanced query AST against the vault index.
--- Shared pipeline for prompt mode (execute_advanced_query) and live mode
--- (search_advanced_live), eliminating duplicated setup logic.
---
--- When on_done is provided, ripgrep runs asynchronously (non-blocking).
--- When on_done is nil, runs synchronously (blocking, for fzf_live compatibility).
---
---@param ast table parsed AST from search_query.parse_query()
---@param group_mode string|nil from parse_query group: directive
---@param idx table VaultIndex instance
---@param current_path string buffer path for graph: center resolution
---@param restrict_to table|nil optional subset to filter (rel_path -> entry)
---@param on_done? fun(result: table, group_mode: string|nil, metadata_matches: table|nil) async callback
---@return table|nil result from resolve_query (sync only)
---@return string|nil effective_group_mode (sync only)
---@return table|nil metadata_matches for incremental caching (sync only)
function M.evaluate_advanced_ast(ast, group_mode, idx, current_path, restrict_to, on_done)
  -- Apply default group mode from config if no explicit group: directive
  if not group_mode then
    local grouping_cfg = config.search.grouping
    if grouping_cfg.default_mode and grouping_cfg.default_mode ~= "none" then
      group_mode = grouping_cfg.default_mode
    end
  end

  local split = search_filter.split_ast(ast)

  -- Pre-compute graph traversal sets if the AST contains graph: nodes
  local needs_graph = split.metadata_ast and search_filter.ast_contains_graph(split.metadata_ast)

  if on_done then
    local function dispatch_with_graph_sets(graph_sets)
      resolve_query(split, idx, engine.vault_path, graph_sets, group_mode, restrict_to,
        function(result, metadata_matches)
          on_done(result, group_mode, metadata_matches)
        end)
    end

    if needs_graph then
      -- Async graph pre-computation to avoid blocking UI during BFS
      search_filter.precompute_graph_sets_async(
        split.metadata_ast, idx, current_path, dispatch_with_graph_sets)
    else
      dispatch_with_graph_sets(nil)
    end
    return nil
  end

  -- Sync path (fzf_live compatibility)
  local graph_sets = nil
  if needs_graph then
    graph_sets = search_filter.precompute_graph_sets(
      split.metadata_ast, idx, current_path)
  end

  local result, metadata_matches = resolve_query(
    split, idx, engine.vault_path, graph_sets, group_mode, restrict_to)
  return result, group_mode, metadata_matches
end

--- Execute an advanced search query and display results in fzf.
--- Used by both prompt mode and saved search dispatch.
---@param query_string string the raw advanced query
---@param opts? { silent?: boolean }
function M.execute_advanced_query(query_string, opts)
  opts = opts or {}
  local search_query = require("andrew.vault.search_query")
  local vault_index = require("andrew.vault.vault_index")
  local fzf = require("fzf-lua")

  local t_start = vim.uv.hrtime()

  local ast, err, group_mode = search_query.parse_query(query_string)
  if not ast then
    if not opts.silent then
      notify.warn("search parse error: " .. (err or "unknown"))
    end
    return
  end

  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    if idx then
      notify.info("Index building, advanced search will start when ready...")
      idx:wait_for_ready(function()
        vim.schedule(function()
          M.execute_advanced_query(query_string, opts)
        end)
      end, "search.advanced.deferred")
    else
      if not opts.silent then
        notify.index_not_ready("falling back to text search")
      end
      fzf.grep(engine.vault_fzf_opts("Vault advanced", {
        search = query_string,
        rg_opts = engine.rg_base_opts(),
      }))
    end
    return
  end

  -- Warn about probable field name typos
  if not opts.silent then
    if not stats then stats = require("andrew.vault.search.stats") end
    stats.warn_unknown_fields(ast, idx)
  end

  local current_path = vim.api.nvim_buf_get_name(0)

  -- Cancel previous async evaluation and drop stale queued rg requests
  if _active_eval_cancel then
    _active_eval_cancel()
    _active_eval_cancel = nil
  end
  search_filter.semaphore_reset()

  M.evaluate_advanced_ast(ast, group_mode, idx, current_path, nil,
    function(result, effective_group_mode, _metadata_matches)
      group_mode = effective_group_mode

      if result.limit_reached then
        notify.warn("Search results were truncated. Try narrowing your query.")
      end

      local elapsed_ms = math.floor((vim.uv.hrtime() - t_start) / 1e6)

      if #result.entries == 0 then
        if not opts.silent then
          notify.info(string.format("no matches (%dms)", elapsed_ms))
        end
        return
      end

      local actions = engine.vault_fzf_actions()
      actions["ctrl-/"] = { fn = function() require("andrew.vault.search.help").search_help() end, reload = false }
      if config.graph.search_to_graph then
        actions["ctrl-g"] = {
          fn = function(selected)
            -- Collect all result file paths and open as graph
            local file_set = {}
            for _, line in ipairs(result.entries) do
              if not search_group.is_header(line) then
                local file = search_filter.extract_rg_file(line)
                if not file:match("^/") then
                  file = engine.vault_path .. "/" .. file
                end
                file_set[file] = true
              end
            end
            require("andrew.vault.graph").search_result_graph(file_set, query_string)
          end,
          reload = false,
        }
      end

      -- Wrap default action to skip group headers
      if group_mode and group_mode ~= "none" then
        local orig_default = actions["default"]
        actions["default"] = function(selected, fzf_opts_inner)
          local filtered = search_group.filter_selected(selected)
          if #filtered > 0 then
            orig_default(filtered, fzf_opts_inner)
          end
        end
      end

      -- Build stats line for header
      local header = M.SEARCH_HEADER
      if config.search.show_stats ~= false then
        if not stats then stats = require("andrew.vault.search.stats") end
        local stats_line = stats.format_stats(result.entries, group_mode, elapsed_ms)
        header = stats_line .. "\n" .. M.SEARCH_HEADER
      end

      local fzf_inner_opts = {
        ["--header"] = header,
        ["--ansi"] = "",
      }
      -- When grouped, disable fzf sorting to preserve group order
      if group_mode and group_mode ~= "none" then
        fzf_inner_opts["--no-sort"] = ""
      end

      local fzf_opts = vim.tbl_extend("force",
        engine.vault_fzf_opts("Vault: advanced search"),
        {
          actions = actions,
          fzf_opts = fzf_inner_opts,
        }
      )
      if result.needs_previewer then
        fzf_opts.previewer = "builtin"
      end
      fzf.fzf_exec(result.entries, fzf_opts)
    end)
end

return M
