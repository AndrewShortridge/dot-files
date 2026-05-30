--- Live sync for the embed system.
--- Vault index subscription, debounced re-render scheduling, dependency tracking.
local config = require("andrew.vault.config")
local cleanup = require("andrew.vault.resource_cleanup")
local watch = require("andrew.vault.watch_channel")
local state = require("andrew.vault.embed_state")

local M = {}

-- Deferred subscription init: on_index_update is defined below, so we lazily
-- create the handle on first ensure_subscription() call.
local _subscription_initialized = false
-- State anchor for weak_callback defense-in-depth: if the module is unloaded
-- (package.loaded cleared), this becomes unreachable and the vault_index
-- subscriber callback silently becomes a no-op on next GC cycle.
local _state_anchor = {}

-- Inverted dependency index: dep_path -> { [bufnr] = true }
-- Marked dirty by mark_dep_index_dirty() (called from embed.lua on dep changes)
-- and by embed_state.notify_dep_index_dirty() (called during GC/buffer cleanup,
-- which uses package.loaded to avoid circular require).
local _dep_to_bufs = {}
local _dep_index_dirty = true

--- Rebuild the inverted dependency index from embed state deps.
--- Only rebuilds when marked dirty (lazy rebuild).
local function ensure_dep_index()
  if not _dep_index_dirty then return end
  _dep_to_bufs = {}
  for bufnr, st in state.iter_buffers() do
    for dep_path in pairs(st.deps or {}) do
      if not _dep_to_bufs[dep_path] then
        _dep_to_bufs[dep_path] = {}
      end
      _dep_to_bufs[dep_path][bufnr] = true
    end
  end
  _dep_index_dirty = false
end

--- Mark the inverted dependency index as dirty.
--- Call this whenever a buffer's embed deps (st.deps) change.
function M.mark_dep_index_dirty()
  _dep_index_dirty = true
end

--- Get or create a watch channel for embed sync on a buffer.
--- Channels are stored in the unified embed_state per-buffer record.
---@param bufnr number
---@return { send: fun(any), handle: WatchChannelHandle }
local function get_embed_channel(bufnr)
  local st = state.get_buf_state(bufnr)
  if not st.channel then
    local send, handle = watch.new(nil)
    handle.subscribe(function()
      if not state.is_embed_active(bufnr) then
        local st2 = state.try_get_buf_state(bufnr)
        if st2 and st2.channel then
          st2.channel.handle.close()
          st2.channel = nil
        end
        return
      end

      local embed = require("andrew.vault.embed")
      local fc = embed.get_frame_cache(bufnr)
      if fc then fc:clear() end
      embed.render_embeds_buf(bufnr, { silent = true })
    end)
    st.channel = { send = send, handle = handle }
  end
  return st.channel
end

--- Schedule a coalesced re-render for a specific buffer.
--- Uses watch-style coalescing: fires on next event loop tick.
---@param bufnr number
function M.schedule_rerender(bufnr)
  local ch = get_embed_channel(bufnr)
  ch.send(true)
end

--- Return count of active embed sync channels (for debug).
---@return number
function M.channel_count()
  local count = 0
  for _, st in state.iter_buffers() do
    if st.channel then count = count + 1 end
  end
  return count
end

--- Handle vault index update notification.
--- The generation parameter is part of the vault_index subscription callback
--- signature but is unused by this handler (context paths are sufficient).
---@param _generation number vault index generation (unused, required by callback signature)
---@param context? { changed_paths?: string[], deleted_paths?: string[] }
function M.on_index_update(_generation, context)
  if not config.embed.sync or not config.embed.sync.enabled then
    return
  end

  -- Full rebuild: rerender all active embed buffers
  if not context or context.tier == "full" then
    for bufnr, st in state.iter_buffers() do
      if not st.visible then goto continue end
      if state.is_embed_active(bufnr) then
        M.schedule_rerender(bufnr)
      end
      ::continue::
    end
    return
  end

  -- Additive: new files might resolve previously-unresolved embeds.
  -- Fall through to partial handling (added_paths checked below).
  -- This is cheap since additive events are infrequent.

  -- Partial/Additive: use inverted index for O(changed_paths) lookups.
  -- Convert relative paths to absolute since _dep_to_bufs keys are absolute.
  ensure_dep_index()

  local vault_path = nil
  local vi = package.loaded["andrew.vault.vault_index"]
  if vi then
    local idx = vi.current()
    if idx then vault_path = idx.vault_path end
  end

  local to_rerender = {}
  for _, list in ipairs({ context.changed_paths, context.deleted_paths, context.added_paths }) do
    for _, p in ipairs(list or {}) do
      -- Convert relative path to absolute for _dep_to_bufs lookup
      local abs_p = vault_path and (vault_path .. "/" .. p) or p
      local bufs = _dep_to_bufs[abs_p]
      if bufs then
        for bufnr in pairs(bufs) do
          to_rerender[bufnr] = true
        end
      end
    end
  end

  for bufnr in pairs(to_rerender) do
    if state.is_embed_active(bufnr) then
      M.schedule_rerender(bufnr)
    end
  end
end

--- Lazily initialize the subscription handle (deferred because on_index_update
--- must be defined before the handle can reference it).
local function init_subscription()
  if _subscription_initialized then return end
  _subscription_initialized = true
  -- weak_state: subscriber becomes no-op if module is unloaded (defense-in-depth).
  state._subscription = cleanup.subscription_handle(function()
    local vault_index_mod = package.loaded["andrew.vault.vault_index"]
    return vault_index_mod and vault_index_mod.current() or nil
  end, M.on_index_update, { weak_state = _state_anchor })
end

--- Ensure the vault index subscription is active.
---@return boolean
function M.ensure_subscription()
  init_subscription()
  return state._subscription.ensure()
end

--- Unsubscribe from vault index updates.
function M.unsubscribe()
  if state._subscription then
    state._subscription.unsubscribe()
  end
end

return M
