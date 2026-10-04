-- ksession buffer-restore loader. Installed to:
--   ~/.local/share/nvim/site/lua/ksession_restore.lua
-- by `make install`. Consumed at restore time by one line appended to the
-- mksession output:
--   lua require('ksession_restore').load(vim.fn.expand('<sfile>:p:h') .. '/win-XYZ.json')
--
-- The JSON manifest is written by `adapter::nvim` after each
-- `nvim_buf_get_lines` dump. Lua reads it back, walks the buffer list,
-- recreates each buffer's contents, and re-applies the `&modified` /
-- `&filetype` flags. Mirrors `s:KsessionRestoreBuffer` in the Bash port
-- (`ksession.sh:212-231`) but without the quoting-hell of inlining a vim
-- function into the saved session file.
--
-- Per Plan §5.3 the size cap (8 MiB / buffer) lives on the writer side;
-- this loader surfaces truncation via `vim.notify` at WARN level.

local M = {}

-- ---------------------------------------------------------------------------
-- Cross-process tracing (PRD-0 slice 10)
--
-- When KSESSION_TRACE_DIR is set, trace_span brackets fn() with
-- vim.uv.hrtime() monotonic nanosecond timestamps and appends one
-- chrome-trace X event per call to <trace_dir>/nvim-<pid>.jsonl.
-- When unset, trace_span is a zero-cost passthrough.
-- Errors during emit are silently logged to <trace_dir>/nvim-error.log;
-- never raised into the user's restore.
-- ---------------------------------------------------------------------------

local _trace_dir = os.getenv('KSESSION_TRACE_DIR')
local _trace_pid = nil -- lazily resolved on first emit

--- Emit one chrome-trace X event line to the trace JSONL file.
--- Errors are swallowed and redirected to a fallback error log.
local function _trace_emit(name, args_table, ts_ns, dur_ns)
  if not _trace_pid then
    _trace_pid = vim.fn.getpid()
  end
  -- Convert nanoseconds to microseconds for chrome-trace format.
  local ts_us = math.floor(ts_ns / 1000)
  local dur_us = math.floor(dur_ns / 1000)

  local event = {
    name = name,
    ph = 'X',
    ts = ts_us,
    dur = dur_us,
    pid = _trace_pid,
    tid = _trace_pid,
    args = args_table or {},
  }

  local ok_enc, line = pcall(vim.json.encode, event)
  if not ok_enc then
    -- Cannot encode — write to fallback log.
    pcall(function()
      local ef = io.open(_trace_dir .. '/nvim-error.log', 'a')
      if ef then
        ef:write('encode error: ' .. tostring(line) .. '\n')
        ef:close()
      end
    end)
    return
  end

  local ok_io, io_err = pcall(function()
    local fh = io.open(_trace_dir .. '/nvim-' .. _trace_pid .. '.jsonl', 'a')
    if fh then
      fh:write(line .. '\n')
      fh:close()
    end
  end)
  if not ok_io then
    pcall(function()
      local ef = io.open(_trace_dir .. '/nvim-error.log', 'a')
      if ef then
        ef:write('io error: ' .. tostring(io_err) .. '\n')
        ef:close()
      end
    end)
  end
end

--- Trace a named span around fn(). If KSESSION_TRACE_DIR is unset,
--- simply calls fn() and returns its results. If set, brackets fn()
--- with monotonic timing and emits a chrome-trace X event.
---
--- @param name string  Dotted span name (e.g. "nvim.restore.load_modified_buffers")
--- @param args table|nil  Key-value pairs to include in the trace event args
--- @param fn function  The function to execute inside the span
--- @return any  The return value of fn()
function M.trace_span(name, args, fn)
  if not _trace_dir then
    return fn()
  end

  -- vim.uv.hrtime() returns monotonic nanoseconds (no syscall on Linux).
  -- We use it for precise duration measurement. For the wall-clock `ts`
  -- field required by chrome-trace, we compute:
  --   ts = (wall-clock at span end) - duration
  -- This gives a reasonable approximation without forking or syscalls
  -- beyond os.time() (second-precision epoch).
  local t0 = vim.uv.hrtime()
  local results = { pcall(fn) }
  local t1 = vim.uv.hrtime()
  local dur_ns = t1 - t0

  -- Wall-clock timestamp: os.time() gives seconds since epoch.
  -- Compute ts_us = (end wall-clock in us) - dur_us. The ~1s granularity
  -- of os.time() is acceptable — perfetto aligns cross-process spans by
  -- relative offsets, not absolute timestamps.
  local dur_us = math.floor(dur_ns / 1000)
  local ts_us = os.time() * 1000000 - dur_us

  -- _trace_emit takes (name, args, ts_ns, dur_ns) but we already have
  -- microsecond values, so multiply back. This keeps _trace_emit's
  -- internal conversion (ns -> us) idempotent.
  pcall(_trace_emit, name, args, ts_us * 1000, dur_ns)

  -- Re-raise or return the inner function's results.
  local ok = table.remove(results, 1)
  if not ok then
    error(results[1])
  end
  return unpack(results)
end

function M.load(json_path)
  -- PRD-0003 phase coverage:
  --   nvim.restore.decode_manifest       — measured below
  --   nvim.restore.load_modified_buffers — measured below (PRD name: load_modified_buffers)
  --   nvim.restore.mark_loaded           — measured below
  --   nvim.restore.source_session_vim    — unmeasurable from lua; this is nvim's
  --     native :source of Session.vim, which happens before this module is called
  --   nvim.restore.restore_window_options — not applicable; the lua loader does
  --     not restore window options (mksession handles this)
  --   nvim.restore.fire_user_autocmds    — not applicable; user autocmds fire
  --     naturally via nvim's event loop after restore completes
  M.trace_span('nvim.restore.load', { json_path = json_path }, function()
    -- `vim.g.x[k] = v` does NOT persist — vim.g returns a snapshot copy.
    -- The guard must read the table, mutate locally, and write the whole
    -- table back via the setter for vim.g to see the change.
    local loaded = vim.g.ksession_loaded or {}
    if loaded[json_path] then return end

    -- Dump paths in the manifest are stored RELATIVE to the manifest's own
    -- directory so the state dir can be moved without breaking restore.
    -- Resolve once outside the loop; identical for every buffer.
    local json_dir = vim.fn.fnamemodify(json_path, ':h')

    -- Phase 1: read and decode the JSON manifest.
    local data = M.trace_span('nvim.restore.decode_manifest', { json_path = json_path }, function()
      local f = io.open(json_path, 'r')
      if not f then
        return nil
      end
      local raw = f:read('*a')
      f:close()
      if raw == nil or raw == '' then
        return nil
      end

      local ok, decoded = pcall(vim.json.decode, raw)
      if not ok or type(decoded) ~= 'table' or type(decoded.buffers) ~= 'table' then
        return nil
      end

      if (decoded.schema or 1) > 1 then
        vim.notify('ksession: manifest schema ' .. tostring(decoded.schema) .. ' newer than loader; skipping buffer restore', vim.log.levels.WARN)
        return nil
      end

      return decoded
    end)

    if not data then return end

    -- Phase 2: walk the buffer list and restore contents + flags.
    M.trace_span('nvim.restore.load_modified_buffers', { count = #data.buffers }, function()
      for _, b in ipairs(data.buffers) do
        local bnr
        if b.name and b.name ~= '' then
          bnr = vim.fn.bufnr(b.name)
          if bnr <= 0 then
            bnr = vim.fn.bufadd(b.name)
          end
          vim.fn.bufload(bnr)
        else
          bnr = vim.api.nvim_create_buf(true, false)
        end

        -- readfile splits on newlines; matches how the writer used
        -- nvim_buf_get_lines (line-oriented, no trailing NL).
        if type(b.dump_path) ~= 'string' or b.dump_path == '' then
          vim.notify('ksession: manifest entry missing dump_path; skipping', vim.log.levels.WARN)
          vim.api.nvim_buf_delete(bnr, { force = true })
          goto continue
        end
        local path = json_dir .. '/' .. b.dump_path
        if vim.fn.filereadable(path) ~= 1 then
          vim.notify('ksession: buffer dump missing: ' .. path, vim.log.levels.WARN)
          -- Don't leave the half-created buffer hanging in the buffer list.
          -- force=true for robustness — readfile/set_lines haven't run yet
          -- so it shouldn't be marked modified, but be defensive.
          vim.api.nvim_buf_delete(bnr, { force = true })
          goto continue
        end
        local lines = vim.fn.readfile(path)
        vim.api.nvim_buf_set_lines(bnr, 0, -1, false, lines)

        if b.modified then
          vim.bo[bnr].modified = true
        end
        if b.filetype and b.filetype ~= '' then
          vim.bo[bnr].filetype = b.filetype
        end
        if b.truncated then
          vim.notify(
            ('ksession: buffer %s was truncated at capture'):format(b.name or '<unnamed>'),
            vim.log.levels.WARN
          )
        end
        ::continue::
      end
    end)

    -- Phase 3: mark this manifest as loaded (idempotency guard).
    M.trace_span('nvim.restore.mark_loaded', { json_path = json_path }, function()
      loaded[json_path] = true
      vim.g.ksession_loaded = loaded
    end)

    -- Slice 11: ready marker. Touched after the last buffer is loaded
    -- so downstream tooling knows this nvim contributor is done.
    -- Gated on KSESSION_TRACE_DIR — without it there is no directory.
    local trace_dir = os.getenv("KSESSION_TRACE_DIR")
    if trace_dir then
      local ready_dir = trace_dir .. "/ready"
      os.execute("mkdir -p " .. ready_dir)
      local f = io.open(ready_dir .. "/nvim-" .. vim.fn.getpid(), "w")
      if f then f:close() end
    end
  end)
end

return M
