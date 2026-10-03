-- =============================================================================
-- LaTeX cache warming (latex_warm.lua)
-- =============================================================================
-- render-markdown.nvim's latex handler converts each $...$ / $$...$$ equation
-- via `vim.system({converter}, {stdin}):wait()` — a SYNCHRONOUS block of the
-- main thread (latex2text/pylatexenc is ~100-300ms cold). Results are cached
-- per equation text per session, so the first scroll into a math-heavy note
-- freezes the editor.
--
-- This module warms that cache OFF the main thread: on BufReadPost for vault
-- markdown buffers it enumerates the buffer's latex equations and pre-converts
-- the cache MISSES via async `vim.system` (no :wait()), writing successes into
-- the plugin's private `Handler.cache` so the plugin reuses them.
--
-- The plugin exposes no public conversion or cache-write API. The only safe
-- bridge is the single upvalue of `render-markdown.handler.latex`'s `parse`
-- closure, which is the live `Handler` table. We resolve it once (memoized),
-- guard its shape, and degrade silently to the plugin's synchronous path if the
-- structure ever changes (no regression — latex still works, just not warmed).

local log = require("andrew.vault.vault_log").scope("latex_warm")

local M = {}

-- Memoized handle to the plugin's private Handler table (with .cache / .input).
-- `false` = resolution attempted and failed (don't retry); nil = not yet tried.
local _handle = nil

--- Resolve the plugin's private Handler table via the `parse` closure upvalue.
--- Guards the upvalue name and shape; returns nil safely if unavailable.
--- Memoized — never re-walks upvalues after the first resolution.
---@return table|nil handler the live Handler with `.cache` and `.input`
function M._cache_handle()
  if _handle ~= nil then
    return _handle or nil
  end
  local ok, mod = pcall(require, "render-markdown.handler.latex")
  if not ok or type(mod) ~= "table" or type(mod.parse) ~= "function" then
    log.debug("latex handler unavailable; skipping warm")
    _handle = false
    return nil
  end
  local name, val = debug.getupvalue(mod.parse, 1)
  if name ~= "Handler" or type(val) ~= "table"
      or type(val.cache) ~= "table" or type(val.input) ~= "function" then
    log.debug("latex Handler upvalue shape changed; skipping warm")
    _handle = false
    return nil
  end
  _handle = val
  return val
end

--- Enumerate the distinct latex equation cache keys present in a buffer,
--- mirroring exactly how the plugin derives them: one root per injected
--- `latex`-language tree, keyed by the Handler's own `input()` function.
--- This guarantees parity with the keys the plugin will look up (and excludes
--- `$` inside code blocks, which are never math injections).
---@param buf integer
---@param handler table the resolved Handler (for its `input` key function)
---@return string[] keys distinct equation keys in buffer order
local function collect_keys(buf, handler)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  if not ok or not parser then
    return {}
  end
  pcall(parser.parse, parser, true)

  local keys = {} ---@type string[]
  local seen = {} ---@type table<string, boolean>
  parser:for_each_tree(function(tree, ltree)
    if ltree:lang() ~= "latex" then
      return
    end
    local root = tree:root()
    local text = vim.treesitter.get_node_text(root, buf)
    if not text then
      return
    end
    -- Mirror Handler.input(node): { text = node.text } -> trimmed, $-stripped.
    local key = handler.input({ text = text })
    if key ~= "" and not seen[key] then
      seen[key] = true
      keys[#keys + 1] = key
    end
  end)
  return keys
end

--- Convert one equation key asynchronously and store the result in the plugin
--- cache on success. Mirrors the plugin's command form and key:
---   vim.system({ converter }, { stdin = key, text = true })
---@param key string
---@param converter string
---@param handler table
---@param on_done fun() called (after scheduling) once the process settles
local function convert_async(key, converter, handler, on_done)
  vim.system({ converter }, { stdin = key, text = true }, function(result)
    vim.schedule(function()
      if result.code == 0 and result.stdout then
        -- Re-check: the plugin may have populated it synchronously meanwhile.
        if not handler.cache[key] then
          handler.cache[key] = result.stdout
        end
      else
        log.debug("latex2text failed for %q (code %s)", key, tostring(result.code))
      end
      on_done()
    end)
  end)
end

--- Warm the plugin cache for all cache-MISS equations in `buf`.
--- Caps total equations and bounds concurrency via a draining work pool so we
--- never spawn an unbounded number of latex2text processes.
---@param buf integer
---@param latex_opts { enabled: boolean, converter: string }
function M.warm(buf, latex_opts)
  if not (latex_opts and latex_opts.enabled) then
    return
  end
  local converter = latex_opts.converter
  if type(converter) ~= "string" or vim.fn.executable(converter) ~= 1 then
    return
  end
  local handler = M._cache_handle()
  if not handler then
    return
  end
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then
    return
  end

  local cfg = require("andrew.vault.config").latex_warm

  -- Cache-miss-only: skip keys already present (including 'error' sentinels).
  local cache = handler.cache
  local pending = {} ---@type string[]
  for _, key in ipairs(collect_keys(buf, handler)) do
    if cache[key] == nil then
      pending[#pending + 1] = key
      if #pending >= cfg.max_equations then
        break
      end
    end
  end
  if #pending == 0 then
    return
  end
  log.debug("warming %d latex equation(s) for buf %d", #pending, buf)

  -- Bounded-concurrency pool draining the work queue.
  local next_idx = 1
  local in_flight = 0
  local function pump()
    while in_flight < cfg.max_concurrent and next_idx <= #pending do
      local key = pending[next_idx]
      next_idx = next_idx + 1
      in_flight = in_flight + 1
      convert_async(key, converter, handler, function()
        in_flight = in_flight - 1
        pump()
      end)
    end
  end
  pump()
end

--- Register the BufReadPost warm autocmd. Cheap to call at plugin config time;
--- the handler require + upvalue resolution happen lazily on first markdown
--- BufReadPost (and are memoized), so there is no startup cost.
---@param latex_opts { enabled: boolean, converter: string }
function M.setup(latex_opts)
  local cfg = require("andrew.vault.config").latex_warm
  if not (cfg.enabled and latex_opts and latex_opts.enabled) then
    return
  end

  local sched = require("andrew.vault.work_scheduler")
  local group = vim.api.nvim_create_augroup("VaultLatexWarm", { clear = true })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      local engine = require("andrew.vault.engine")
      if not engine.is_vault_buf(ev.buf) then
        return
      end
      local domain = "latex-warm:" .. ev.buf
      -- Coalesce rapid re-triggers for the same buffer (natural debounce).
      sched.cancel_domain(domain)
      sched.schedule(sched.DEFERRED, function()
        M.warm(ev.buf, latex_opts)
      end, { domain = domain, label = "warm" })
    end,
  })
end

return M
