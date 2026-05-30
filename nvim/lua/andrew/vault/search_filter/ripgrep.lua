--- Ripgrep integration for search filter pipeline.

local M = {}

local config = require("andrew.vault.config")
local semaphore = require("andrew.vault.process_semaphore")
local pat = require("andrew.vault.patterns")

-- Module-level semaphore shared across all rg spawns (search, rename, linkcheck, etc.)
-- Uses the process_semaphore singleton so all vault modules share the same instance.

--- Build ripgrep command arguments for a single text/regex AST node.
---@param node table text or regex AST node
---@param vault_path string vault root directory
---@param files_from string|nil path to temp file with file list
---@return string[] command arguments for vim.system()
local function build_rg_args(node, vault_path, files_from)
  local args = {
    "rg",
    "--column",
    "--line-number",
    "--no-heading",
    "--color=never",
  }

  if node.type == "text" then
    if node.quoted then
      -- Exact fixed-string match
      args[#args + 1] = "--fixed-strings"
    else
      -- Smart case for unquoted text
      args[#args + 1] = "--smart-case"
    end
    args[#args + 1] = "--"
    args[#args + 1] = node.value
  elseif node.type == "regex" then
    -- Apply regex flags
    local flags = node.flags or ""
    if flags:find("i") then
      args[#args + 1] = "--case-insensitive"
    end
    if flags:find("s") then
      args[#args + 1] = "--multiline-dotall"
    elseif flags:find("m") then
      args[#args + 1] = "--multiline"
    end
    args[#args + 1] = "--"
    args[#args + 1] = node.pattern
  end

  local max_per_file = config.search.max_matches_per_file
  if max_per_file then
    args[#args + 1] = "--max-count"
    args[#args + 1] = tostring(max_per_file)
  end

  if files_from then
    args[#args + 1] = "--files-from=" .. files_from
  else
    args[#args + 1] = vault_path
  end

  return args
end

--- Write a list of file paths to a temporary file for rg --files-from.
---@param file_paths string[] absolute paths
---@return string|nil temp file path, or nil on error
local function write_paths_tmpfile(file_paths)
  local tmpfile = os.tmpname()
  local f = io.open(tmpfile, "w")
  if not f then return nil end
  for _, path in ipairs(file_paths) do
    f:write(path .. "\n")
  end
  f:close()
  return tmpfile
end

--- Extract the file path from a ripgrep output line or bare path.
--- Uses plain string.find() instead of regex for performance on large result sets.
---@param line string
---@return string
function M.extract_rg_file(line)
  local p1 = line:find(":", 1, true)
  if not p1 then return line end
  local p2 = line:find(":", p1 + 1, true)
  if not p2 then return line end
  local p3 = line:find(":", p2 + 1, true)
  if not p3 then return line end
  return line:sub(1, p1 - 1)
end

--- Collect the set of unique file paths from ripgrep results.
---@param lines string[]
---@return table<string, boolean>
function M.collect_file_set(lines)
  local files = {}
  for _, line in ipairs(lines) do
    files[M.extract_rg_file(line)] = true
  end
  return files
end

--- Check whether an AST node is a ripgrep leaf (text or regex).
---@param node table AST node
---@return boolean
local function is_leaf(node)
  local t = node.type
  return t == "text" or t == "regex"
end

--- Compute file restriction flag for a ripgrep call.
---@param tmpfile string|nil pre-created tmpfile path
---@param file_paths string[] absolute file paths
---@return boolean use_file_restriction
local function should_restrict_files(tmpfile, file_paths)
  return tmpfile ~= nil and #file_paths <= config.search.max_files_from
end

--- Post-process raw ripgrep stdout into lines, optionally filtering to allowed files.
---@param stdout string raw stdout from ripgrep
---@param use_file_restriction boolean whether --files-from was used
---@param file_paths string[] original file paths (for post-filtering)
---@param limit_state table shared { reached: boolean } for tracking truncation
---@return string[] ripgrep output lines
local function process_rg_output(stdout, use_file_restriction, file_paths, limit_state)
  local max_lines = config.search.max_result_lines
  local lines = {}
  local count = 0
  for line in (stdout or ""):gmatch(pat.LINE_NONEMPTY) do
    count = count + 1
    if max_lines and count > max_lines then
      limit_state.reached = true
      break
    end
    lines[#lines + 1] = line
  end

  -- When full-vault fallback was used, post-filter results to only include
  -- files from the original file_paths set (otherwise metadata filtering is bypassed)
  if not use_file_restriction and #file_paths > 0 then
    local allowed = {}
    for _, path in ipairs(file_paths) do
      allowed[path] = true
    end
    local filtered = {}
    for _, line in ipairs(lines) do
      if allowed[M.extract_rg_file(line)] then
        filtered[#filtered + 1] = line
      end
    end
    return filtered
  end

  return lines
end

--- Prepare ripgrep args and output processor for a leaf node.
---@param node table text or regex AST leaf node
---@param file_paths string[] absolute file paths to search within
---@param vault_path string vault root path
---@param tmpfile string|nil pre-created tmpfile path (reused across calls)
---@param limit_state table shared { reached: boolean } for tracking truncation
---@return string[] args, fun(result: table): string[] process
local function prepare_rg_call(node, file_paths, vault_path, tmpfile, limit_state)
  local use_file_restriction = should_restrict_files(tmpfile, file_paths)
  local args = build_rg_args(node, vault_path, use_file_restriction and tmpfile or nil)
  local function process(result)
    return process_rg_output(result.stdout, use_file_restriction, file_paths, limit_state)
  end
  return args, process
end

--- Get the shared rg semaphore (singleton in process_semaphore module).
---@return ProcessSemaphore
local function get_rg_sem()
  return semaphore.rg_semaphore()
end

--- Spawn a ripgrep process asynchronously, bounded by the process semaphore.
--- Uses streaming stdout to enforce max_result_lines early (kills process once cap is hit).
--- Returns a cancel function that kills the process (if running) or cancels the queued request.
---@param node table text or regex AST leaf node
---@param file_paths string[] absolute file paths to search within
---@param vault_path string vault root path
---@param tmpfile string|nil pre-created tmpfile path (reused across calls)
---@param limit_state table shared { reached: boolean } for tracking truncation
---@param on_done fun(lines: string[]) callback with processed output lines
---@return fun() cancel
local function spawn_rg_async(node, file_paths, vault_path, tmpfile, limit_state, on_done)
  local args, process = prepare_rg_call(node, file_paths, vault_path, tmpfile, limit_state)
  local process_obj = nil

  local cancel = semaphore.acquire(get_rg_sem(), function(release)
    -- Streaming state: buffer chunks, count newlines for early termination
    local chunks = {}
    local line_count = 0
    local max_lines = config.search.max_result_lines
    local capped = false

    process_obj = vim.system(args, {
      stdout = function(_, data)
        if not data or capped then return end
        -- Count newlines in this chunk for the line limit
        if max_lines then
          for _ in data:gmatch("\n") do
            line_count = line_count + 1
            if line_count >= max_lines then
              capped = true
              limit_state.reached = true
              -- Keep partial chunk up to this point, then kill
              chunks[#chunks + 1] = data
              if process_obj then
                process_obj:kill()
              end
              return
            end
          end
        end
        chunks[#chunks + 1] = data
      end,
    }, function(result)
      release()
      -- Assemble collected chunks as stdout, then process normally
      result.stdout = table.concat(chunks)
      on_done(process(result))
    end)
  end)

  return function()
    if process_obj then
      process_obj:kill()
    end
    cancel()
  end
end

--- Merge two line arrays, deduplicating by exact line content.
---@param left string[]
---@param right string[]
---@return string[]
local function merge_unique(left, right)
  local seen = {}
  local result = {}
  for _, line in ipairs(left) do
    if not seen[line] then
      seen[line] = true
      result[#result + 1] = line
    end
  end
  for _, line in ipairs(right) do
    if not seen[line] then
      seen[line] = true
      result[#result + 1] = line
    end
  end
  return result
end

--- Combine left and right results for an AND node: intersect file sets, keep matching lines.
---@param left string[]
---@param right string[]
---@return string[]
local function and_combine(left, right)
  local left_files = M.collect_file_set(left)
  local right_files = M.collect_file_set(right)
  local common = {}
  for f in pairs(left_files) do
    if right_files[f] then common[f] = true end
  end
  local result = {}
  for _, line in ipairs(left) do
    if common[M.extract_rg_file(line)] then
      result[#result + 1] = line
    end
  end
  for _, line in ipairs(right) do
    if common[M.extract_rg_file(line)] then
      result[#result + 1] = line
    end
  end
  return result
end

--- Run a single synchronous ripgrep call (blocking, used by sync fallback path).
--- Uses try_acquire for non-blocking semaphore check; falls back to unbounded
--- if the semaphore is full (sync callers cannot wait asynchronously).
---@param node table text or regex AST leaf node
---@param file_paths string[] absolute file paths to search within
---@param vault_path string vault root path
---@param tmpfile string|nil pre-created tmpfile path
---@param limit_state table shared { reached: boolean } for tracking truncation
---@return string[] ripgrep output lines
local function run_rg_sync(node, file_paths, vault_path, tmpfile, limit_state)
  local args, process = prepare_rg_call(node, file_paths, vault_path, tmpfile, limit_state)
  local release = semaphore.try_acquire(get_rg_sem())
  local result = process(vim.system(args, { text = true }):wait())
  if release then release() end
  return result
end

--- Restrict file_paths to only those present in a matched file set.
---@param file_paths string[] original file paths
---@param matched_files table<string, boolean> file set from collect_file_set()
---@return string[] restricted file paths
local function restrict_paths(file_paths, matched_files)
  local restricted = {}
  for _, fp in ipairs(file_paths) do
    if matched_files[fp] then
      restricted[#restricted + 1] = fp
    end
  end
  return restricted
end

--- Build the complement: file paths not present in inner ripgrep results.
---@param inner string[] ripgrep output lines from the inner NOT expression
---@param file_paths string[] all file paths to complement against
---@return string[] file paths not matching the inner expression
local function build_complement(inner, file_paths)
  local inner_files = M.collect_file_set(inner)
  local result = {}
  for _, path in ipairs(file_paths) do
    if not inner_files[path] then
      result[#result + 1] = path
    end
  end
  return result
end

-- Forward declarations for mutual recursion
local ripgrep_recursive_sync
local ripgrep_recursive_async

--- Spawn both children of a binary AND/OR node synchronously, combining results.
--- When both children are leaves, spawns two rg processes in parallel (overlapping I/O).
--- Otherwise falls back to sequential recursive evaluation.
---@param text_ast table AND or OR AST node
---@param file_paths string[] absolute file paths to search within
---@param vault_path string vault root path
---@param tmpfile string|nil pre-created tmpfile path
---@param combine_fn fun(left: string[], right: string[]): string[] and_combine or merge_unique
---@param limit_state table shared { reached: boolean } for tracking truncation
---@return string[]
local function sync_binary(text_ast, file_paths, vault_path, tmpfile, combine_fn, limit_state)
  local left, right

  if is_leaf(text_ast.left) and is_leaf(text_ast.right) then
    -- Parallel: spawn both with semaphore permits, then wait (overlapping I/O)
    local l_args, l_process = prepare_rg_call(text_ast.left, file_paths, vault_path, tmpfile, limit_state)
    local r_args, r_process = prepare_rg_call(text_ast.right, file_paths, vault_path, tmpfile, limit_state)
    local sem = get_rg_sem()
    local l_release = semaphore.try_acquire(sem)
    local lh = vim.system(l_args, { text = true })
    local r_release = semaphore.try_acquire(sem)
    local rh = vim.system(r_args, { text = true })
    left = l_process(lh:wait())
    if l_release then l_release() end
    right = r_process(rh:wait())
    if r_release then r_release() end
  else
    left = ripgrep_recursive_sync(text_ast.left, file_paths, vault_path, tmpfile, limit_state)
    -- For AND: restrict right side to files that matched left (reduces peak memory)
    if text_ast.type == "and" then
      right = ripgrep_recursive_sync(text_ast.right,
        restrict_paths(file_paths, M.collect_file_set(left)), vault_path, tmpfile, limit_state)
    else
      right = ripgrep_recursive_sync(text_ast.right, file_paths, vault_path, tmpfile, limit_state)
    end
  end

  return combine_fn(left, right)
end

--- Spawn both children of a binary AND/OR node asynchronously, combining via callback.
--- Both children are dispatched concurrently; combine_fn is called when both complete.
---@param text_ast table AND or OR AST node
---@param file_paths string[] absolute file paths to search within
---@param vault_path string vault root path
---@param tmpfile string|nil pre-created tmpfile path
---@param combine_fn fun(left: string[], right: string[]): string[] and_combine or merge_unique
---@param limit_state table shared { reached: boolean } for tracking truncation
---@param on_done fun(lines: string[]) callback with combined results
local function async_binary(text_ast, file_paths, vault_path, tmpfile, combine_fn, limit_state, on_done)
  if text_ast.type == "and" then
    -- Sequential: restrict right side to left's matched files (reduces peak memory)
    ripgrep_recursive_async(text_ast.left, file_paths, vault_path, tmpfile, limit_state, function(left)
      local restricted = restrict_paths(file_paths, M.collect_file_set(left))
      ripgrep_recursive_async(text_ast.right, restricted, vault_path, tmpfile, limit_state, function(right)
        on_done(combine_fn(left, right))
      end)
    end)
    return
  end

  -- OR / other: parallel dispatch
  local left_result, right_result
  local pending = 2

  local function check_done()
    pending = pending - 1
    if pending == 0 then
      on_done(combine_fn(left_result, right_result))
    end
  end

  ripgrep_recursive_async(text_ast.left, file_paths, vault_path, tmpfile, limit_state, function(lines)
    left_result = lines
    check_done()
  end)
  ripgrep_recursive_async(text_ast.right, file_paths, vault_path, tmpfile, limit_state, function(lines)
    right_result = lines
    check_done()
  end)
end

--- Internal synchronous recursive ripgrep dispatcher (blocking, reuses a single tmpfile).
--- Used as fallback by fzf_live which requires synchronous return values.
---@param text_ast table text AST node (preserving boolean structure)
---@param file_paths string[] array of absolute file paths to search within
---@param vault_path string vault root path
---@param tmpfile string|nil pre-created tmpfile path
---@param limit_state table shared { reached: boolean } for tracking truncation
---@return string[] ripgrep output lines or bare file paths
ripgrep_recursive_sync = function(text_ast, file_paths, vault_path, tmpfile, limit_state)
  local t = text_ast.type

  -- Leaf: run single ripgrep
  if t == "text" or t == "regex" then
    return run_rg_sync(text_ast, file_paths, vault_path, tmpfile, limit_state)
  end

  -- AND: intersect file sets, parallel spawn when both children are leaves
  if t == "and" then
    return sync_binary(text_ast, file_paths, vault_path, tmpfile, and_combine, limit_state)
  end

  -- OR: union results
  if t == "or" then
    return sync_binary(text_ast, file_paths, vault_path, tmpfile, merge_unique, limit_state)
  end

  -- NOT: complement
  if t == "not" then
    local inner = ripgrep_recursive_sync(text_ast.operand, file_paths, vault_path, tmpfile, limit_state)
    return build_complement(inner, file_paths)
  end

  return {}
end

--- Internal async recursive ripgrep dispatcher (reuses a single tmpfile).
--- All rg processes are spawned asynchronously; boolean nodes coordinate via callbacks.
---@param text_ast table text AST node (preserving boolean structure)
---@param file_paths string[] array of absolute file paths to search within
---@param vault_path string vault root path
---@param tmpfile string|nil pre-created tmpfile path
---@param limit_state table shared { reached: boolean } for tracking truncation
---@param on_done fun(lines: string[]) callback with final results
ripgrep_recursive_async = function(text_ast, file_paths, vault_path, tmpfile, limit_state, on_done)
  local t = text_ast.type

  -- Leaf: spawn single async ripgrep
  if t == "text" or t == "regex" then
    spawn_rg_async(text_ast, file_paths, vault_path, tmpfile, limit_state, on_done)
    return
  end

  -- AND: intersect file sets from both sides, keep lines from common files
  if t == "and" then
    async_binary(text_ast, file_paths, vault_path, tmpfile, and_combine, limit_state, on_done)
    return
  end

  -- OR: union results from both sides
  if t == "or" then
    async_binary(text_ast, file_paths, vault_path, tmpfile, merge_unique, limit_state, on_done)
    return
  end

  -- NOT: files NOT matching the inner expression (returned as bare paths)
  if t == "not" then
    ripgrep_recursive_async(text_ast.operand, file_paths, vault_path, tmpfile, limit_state, function(inner)
      on_done(build_complement(inner, file_paths))
    end)
    return
  end

  on_done({})
end

--- Run ripgrep for a text AST with boolean structure, restricted to specific files.
---
--- Handles AND (intersect file sets), OR (union), and NOT (complement).
--- Leaf text/regex nodes are dispatched to ripgrep. Boolean operators combine
--- file sets accordingly. Returns ripgrep output lines or bare file paths.
---
--- Creates a single tmpfile for --files-from and reuses it across all recursive
--- ripgrep calls, cleaning up on completion or error.
---
--- When on_done is provided, runs fully async (non-blocking). The callback
--- receives results via vim.schedule (safe for vim API calls).
--- When on_done is nil, falls back to synchronous vim.system():wait().
---
---@param text_ast table|nil text AST node (preserving boolean structure)
---@param file_paths string[] array of absolute file paths to search within
---@param vault_path string vault root path
---@param on_done? fun(lines: string[], limit_reached: boolean) optional callback for async mode
---@return string[]|nil lines (sync mode only; nil in async mode)
---@return boolean limit_reached true if max_result_lines cap was hit (sync mode only)
function M.ripgrep_in_files(text_ast, file_paths, vault_path, on_done)
  if not text_ast then
    if on_done then on_done({}, false) return nil end
    return {}, false
  end
  if not file_paths or #file_paths == 0 then
    if on_done then on_done({}, false) return nil end
    return {}, false
  end

  local limit_state = { reached = false }

  -- Create tmpfile once for all recursive calls
  local tmpfile = write_paths_tmpfile(file_paths)

  if on_done then
    -- Async path: non-blocking ripgrep with callback
    ripgrep_recursive_async(text_ast, file_paths, vault_path, tmpfile, limit_state, function(lines)
      if tmpfile then os.remove(tmpfile) end
      vim.schedule(function()
        on_done(lines, limit_state.reached)
      end)
    end)
    return nil
  end

  -- Sync fallback: blocking wait (used by fzf_live provider which must return synchronously)
  if not tmpfile then
    local lines = ripgrep_recursive_sync(text_ast, file_paths, vault_path, nil, limit_state)
    return lines, limit_state.reached
  end

  local ok, result = pcall(ripgrep_recursive_sync, text_ast, file_paths, vault_path, tmpfile, limit_state)
  os.remove(tmpfile)

  if not ok then
    error(result)
  end

  return result, limit_state.reached
end

--- Get current semaphore stats for debugging (e.g., :VaultCacheStats).
---@return table { active: number, max: number, queued: number }
function M.semaphore_stats()
  return semaphore.stats(get_rg_sem())
end

--- Reset the semaphore queue (cancel all queued rg requests).
--- Active permits are still held until their processes complete.
--- Used when a new search supersedes a previous one.
function M.semaphore_reset()
  semaphore.reset(get_rg_sem())
end

return M
