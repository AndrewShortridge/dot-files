local cleanup = require("andrew.vault.resource_cleanup")
local notify = require("andrew.vault.notify")
local pat = require("andrew.vault.patterns")
local watch = require("andrew.vault.watch_channel")
local log = require("andrew.vault.vault_log").scope("watcher")

local W = {}
local _engine -- set by W.setup()

--- Whether the platform supports recursive fs_event watching.
--- macOS (kqueue/FSEvents) and Windows (ReadDirectoryChanges) support it.
--- Linux (inotify) does NOT — the recursive flag is silently ignored.
--- Computed once at module load (the OS never changes mid-session).
local _platform_recursive = (function()
  local sysname = vim.uv.os_uname().sysname
  return sysname == "Darwin" or sysname == "Windows_NT"
end)()

--- Directories to skip when setting up per-directory watches.
--- Reads from config.index.skip_dirs (shared with vault_index.lua).
--- Cached at module level to avoid re-requiring on every filesystem event.
local _skip_dirs = nil
local function watcher_skip_dirs()
  if not _skip_dirs then
    _skip_dirs = require("andrew.vault.config").index.skip_dirs
  end
  return _skip_dirs
end


--- Cached image extension set for O(1) lookup on each fs event.
--- The config value never changes after init.
local _image_exts = nil
local function get_image_exts()
  if not _image_exts then
    _image_exts = require("andrew.vault.config").embed.image_exts
  end
  return _image_exts
end

local _fs_watchers = {}            -- abs_dir -> uv_fs_event_t
local _fs_watcher_count = 0        -- count of entries in _fs_watchers
local _fs_watcher_vault = nil
local _pending_changed_files = {}  -- abs_path -> true
local _pending_count = 0           -- count of entries in _pending_changed_files
-- Hybrid coalescing: watch channel collapses within-tick fs events,
-- then a short debounce (100ms) handles cross-tick bursts (e.g. git checkout).
local _fs_send, _fs_handle = watch.new(nil)
local _fs_debounce_timer = nil

--- Flush pending changed files and update the vault index.
local function flush_pending_files()
  local paths = vim.tbl_keys(_pending_changed_files)
  _pending_changed_files = {}
  _pending_count = 0

  local vault = _fs_watcher_vault
  if not vault then return end

  local vault_index_mod = package.loaded["andrew.vault.vault_index"]
  if not vault_index_mod then return end
  local idx = vault_index_mod.current()
  if not idx or idx.vault_path ~= vault:gsub("/$", "") then return end

  if #paths > 0 then
    if idx._building then
      _engine.invalidate_caches({ scope = "all", skip_index = true })
    else
      idx:update_files_batch(paths)
      if #paths > 10 then
        _engine.invalidate_caches({ scope = "all", skip_index = true })
      else
        _engine.invalidate_caches({ scope = "files", paths = paths, skip_index = true })
      end
    end
  else
    idx:build_async()
    _engine.invalidate_caches({ scope = "all", skip_index = true })
  end
end

--- Subscribe the watch channel: coalesce within-tick, then debounce cross-tick.
local function setup_fs_watch_subscriber()
  _fs_handle.subscribe(function()
    _fs_debounce_timer = cleanup.debounce(_fs_debounce_timer, 100, flush_pending_files)
  end)
end

setup_fs_watch_subscriber()
local _inotify_limit_warned = false
local _watcher_stats = {
  started_at = nil,
  dirs_watched = 0,
  events_received = 0,
  last_event_at = nil,
  last_event_file = nil,
}

-- Forward declaration: assigned after on_fs_event (which references it)
local add_dir_watch

--- Shared callback for all fs_event watchers.
local function on_fs_event(vault, base_dir, err_msg, filename, _events)
  if err_msg then return end

  if filename then
    local abs_path = base_dir .. "/" .. filename

    -- Fast-path: files with extensions are almost certainly not directories,
    -- so skip the synchronous fs_stat() call for them (Linux only).
    local has_ext = filename:match("%.%w+$")

    -- Check if a new directory was created (Linux only — need to add a watch)
    if not _platform_recursive and not has_ext then
      local stat = vim.uv.fs_stat(abs_path)
      if stat and stat.type == "directory" and not watcher_skip_dirs()[filename] then
        add_dir_watch(vault, abs_path)
        -- Deferred scan for .md files created before watch was established
        local sched = require("andrew.vault.work_scheduler")
        sched.schedule(sched.DEFERRED, function()
          local dir_handle = vim.uv.fs_scandir(abs_path)
          if not dir_handle then return end
          local found_new = false
          while true do
            local name, ftype = vim.uv.fs_scandir_next(dir_handle)
            if not name then break end
            if ftype == "file" and name:match(pat.MD_EXTENSION) then
              local md_path = abs_path .. "/" .. name
              if not _pending_changed_files[md_path] then
                _pending_changed_files[md_path] = true
                _pending_count = _pending_count + 1
                found_new = true
              end
            end
          end
          if found_new then
            on_fs_event(vault, abs_path, nil, nil, nil)
          end
        end, { domain = "fs-watch", label = "scan-new-dir" })
        -- Fall through (deferred scan will trigger debounce if .md files found)
      end
    end

    -- Check if the event affects image files — invalidate image cache
    local ext = filename:match("%.(%w+)$")
    if ext then
      if get_image_exts()[ext:lower()] then
        local embed_images = package.loaded["andrew.vault.embed_images"]
        if embed_images then
          embed_images.invalidate_image_cache(abs_path)
        end
      end
    end

    -- Only track .md file changes for index updates
    if filename:match(pat.MD_EXTENSION) then
      if not _pending_changed_files[abs_path] then
        _pending_changed_files[abs_path] = true
        _pending_count = _pending_count + 1
      end
      _watcher_stats.events_received = _watcher_stats.events_received + 1
      _watcher_stats.last_event_at = os.time()
      _watcher_stats.last_event_file = abs_path
    elseif _pending_count == 0 then
      -- Non-.md file change and no .md changes pending — skip debounce
      return
    end
  end

  -- Coalesce: signal the watch channel (collapses within-tick events)
  _fs_send(true)
end

--- Install a fs_event watch on a single directory (no recursion).
local function add_dir_watch_single(abs_dir)
  if _fs_watchers[abs_dir] then return end

  local vault = _fs_watcher_vault
  local watcher = vim.uv.new_fs_event()
  if not watcher then return end

  local ok, _err = watcher:start(abs_dir, {}, function(err_msg, filename, events)
    on_fs_event(vault, abs_dir, err_msg, filename, events)
  end)

  if not ok then
    watcher:stop()
    watcher:close()
    if not _inotify_limit_warned then
      _inotify_limit_warned = true
      vim.schedule(function()
        notify.warn(
          "fs watcher could not watch " .. abs_dir
          .. " (inotify limit?). Some external changes may not be detected."
        )
      end)
    end
    return
  end

  _fs_watchers[abs_dir] = watcher
  _fs_watcher_count = _fs_watcher_count + 1
  _watcher_stats.dirs_watched = _watcher_stats.dirs_watched + 1
end

--- Incrementally install per-directory watches using coroutine batching.
--- Installs the top-level watch immediately, then scans subdirectories
--- in batches of 10, yielding between batches to avoid blocking the UI.
local function start_incremental_watches(vault)
  local skip = watcher_skip_dirs()

  -- Install top-level watch immediately
  add_dir_watch_single(vault)

  -- Scan subdirectories in batches via coroutine
  local dirs_to_scan = { vault }
  local co = coroutine.create(function()
    while #dirs_to_scan > 0 do
      local dir = table.remove(dirs_to_scan, 1)
      local handle = vim.uv.fs_scandir(dir)
      if handle then
        local batch = 0
        while true do
          local name, ftype = vim.uv.fs_scandir_next(handle)
          if not name then break end
          if ftype == "directory" and not skip[name] then
            local sub = dir .. "/" .. name
            add_dir_watch_single(sub)
            dirs_to_scan[#dirs_to_scan + 1] = sub
            batch = batch + 1
            if batch >= 10 then
              coroutine.yield()
              batch = 0
            end
          end
        end
      end
    end
  end)

  local function step()
    if coroutine.status(co) == "dead" then return end
    local ok, err = coroutine.resume(co)
    if not ok then
      log.error("watcher scan error: %s", tostring(err))
      return
    end
    if coroutine.status(co) ~= "dead" then
      vim.defer_fn(step, 1)
    end
  end

  step()
end

--- Add a fs_event watch on a single directory (runtime new-directory handler).
--- Does NOT recurse — subdirectories are picked up by their own creation events
--- flowing through on_fs_event, avoiding synchronous blocking on deep trees.
add_dir_watch = function(_vault, abs_dir)
  add_dir_watch_single(abs_dir)
end

--- Start watching the current vault root for filesystem changes.
function W.start_fs_watcher()
  W.stop_fs_watcher()

  local config_mod = require("andrew.vault.config")
  if not config_mod.index.watch then return end

  local vault = _engine.vault_path
  if not vault or vim.fn.isdirectory(vault) == 0 then return end

  _fs_watcher_vault = vault
  _inotify_limit_warned = false
  _watcher_stats = {
    started_at = os.time(),
    dirs_watched = 0,
    events_received = 0,
    last_event_at = nil,
    last_event_file = nil,
  }

  if _platform_recursive then
    -- macOS/Windows: single recursive watch
    local watcher = vim.uv.new_fs_event()
    if not watcher then return end

    local ok, _err = watcher:start(vault, { recursive = true },
      function(err_msg, filename, events)
        on_fs_event(vault, vault, err_msg, filename, events)
      end)

    if not ok then
      watcher:stop()
      watcher:close()
      return
    end

    _fs_watchers[vault] = watcher
    _fs_watcher_count = 1
    _watcher_stats.dirs_watched = 1
  else
    -- Linux: per-directory inotify watches (incremental to avoid blocking)
    start_incremental_watches(vault)
  end
end

--- Stop the current filesystem watcher.
function W.stop_fs_watcher()
  for _, watcher in pairs(_fs_watchers) do
    local ok, err = pcall(function()
      watcher:stop()
      watcher:close()
    end)
    if not ok then log.debug("fs watcher cleanup failed: %s", err) end
  end
  _fs_watchers = {}
  _fs_watcher_count = 0
  _fs_watcher_vault = nil

  cleanup.close_timer(_fs_debounce_timer)
  _fs_debounce_timer = nil
  _fs_handle.close()

  _pending_changed_files = {}
  _pending_count = 0

  -- Recreate watch channel for potential restart
  _fs_send, _fs_handle = watch.new(nil)
  setup_fs_watch_subscriber()
end

--- Get filesystem watcher status.
---@return table
function W.watcher_status()
  return {
    active = _fs_watcher_count > 0,
    vault_path = _fs_watcher_vault,
    recursive = _platform_recursive,
    dirs_watched = _watcher_stats.dirs_watched,
    events_received = _watcher_stats.events_received,
    started_at = _watcher_stats.started_at,
    last_event_at = _watcher_stats.last_event_at,
    last_event_file = _watcher_stats.last_event_file,
    pending_files = _pending_count,
  }
end

--- Initialize the watcher system with a reference to the engine module.
---@param engine table  The engine module table
function W.setup(engine)
  _engine = engine
end

return W
