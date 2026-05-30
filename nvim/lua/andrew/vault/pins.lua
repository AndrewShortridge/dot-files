local engine = require("andrew.vault.engine")
local notify = require("andrew.vault.notify")

local M = {}

local store = engine.json_store(".vault-pins.json")

--- Return the current buffer's path relative to vault_path, or nil if outside the vault.
---@return string|nil
local function buf_rel_path()
  local abs = vim.api.nvim_buf_get_name(0)
  if abs == "" then
    return nil
  end
  return engine.vault_relative(vim.fn.resolve(abs))
end


--- Pin the current buffer's note.
function M.pin()
  local rel = buf_rel_path()
  if not rel then
    notify.not_vault_file()
    return
  end
  local pins = store.load()
  for _, p in ipairs(pins) do
    if p == rel then
      notify.info("already pinned " .. rel)
      return
    end
  end
  pins[#pins + 1] = rel
  store.save(pins)
  notify.info("pinned " .. rel)
end

--- Unpin the current buffer's note.
function M.unpin()
  local rel = buf_rel_path()
  if not rel then
    notify.not_vault_file()
    return
  end
  local pins = store.load()
  local new = {}
  local found = false
  for _, p in ipairs(pins) do
    if p == rel then
      found = true
    else
      new[#new + 1] = p
    end
  end
  if not found then
    notify.info("not pinned " .. rel)
    return
  end
  store.save(new)
  notify.info("unpinned " .. rel)
end

--- Toggle pin state for the current buffer's note.
function M.toggle_pin()
  local rel = buf_rel_path()
  if not rel then
    notify.not_vault_file()
    return
  end
  local pins = store.load()
  for _, p in ipairs(pins) do
    if p == rel then
      M.unpin()
      return
    end
  end
  M.pin()
end

--- List pinned notes in fzf-lua.
function M.list()
  local pins = store.load()
  if #pins == 0 then
    notify.info("no pinned notes")
    return
  end

  local vault = engine.vault_path
  local abs_paths = {}
  for _, rel in ipairs(pins) do
    abs_paths[#abs_paths + 1] = vault .. "/" .. rel
  end

  local fzf = require("fzf-lua")
  fzf.fzf_exec(abs_paths, engine.vault_fzf_opts("Pinned notes", {
    previewer = "builtin",
    actions = engine.vault_fzf_actions(),
  }))
end

return M
