local engine = require("andrew.vault.engine")

local M = {}

local store = engine.json_store(".vault-pins.json")

--- Return the current buffer's path relative to vault_path, or nil if outside the vault.
---@return string|nil
local function buf_rel_path()
  local abs = vim.api.nvim_buf_get_name(0)
  if abs == "" then
    return nil
  end
  abs = vim.fn.resolve(abs)
  local vault = vim.fn.resolve(engine.vault_path)
  if not vim.startswith(abs, vault) then
    return nil
  end
  -- Strip vault prefix and leading slash
  return abs:sub(#vault + 2)
end


--- Pin the current buffer's note.
function M.pin()
  local rel = buf_rel_path()
  if not rel then
    vim.notify("Vault: buffer is not inside the vault", vim.log.levels.WARN)
    return
  end
  local pins = store.load()
  for _, p in ipairs(pins) do
    if p == rel then
      vim.notify("Vault: already pinned " .. rel, vim.log.levels.INFO)
      return
    end
  end
  pins[#pins + 1] = rel
  store.save(pins)
  vim.notify("Vault: pinned " .. rel, vim.log.levels.INFO)
end

--- Unpin the current buffer's note.
function M.unpin()
  local rel = buf_rel_path()
  if not rel then
    vim.notify("Vault: buffer is not inside the vault", vim.log.levels.WARN)
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
    vim.notify("Vault: not pinned " .. rel, vim.log.levels.INFO)
    return
  end
  store.save(new)
  vim.notify("Vault: unpinned " .. rel, vim.log.levels.INFO)
end

--- Toggle pin state for the current buffer's note.
function M.toggle_pin()
  local rel = buf_rel_path()
  if not rel then
    vim.notify("Vault: buffer is not inside the vault", vim.log.levels.WARN)
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
    vim.notify("Vault: no pinned notes", vim.log.levels.INFO)
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

function M.setup()
  vim.api.nvim_create_user_command("VaultPin", function()
    M.pin()
  end, { desc = "Pin current vault note" })

  vim.api.nvim_create_user_command("VaultUnpin", function()
    M.unpin()
  end, { desc = "Unpin current vault note" })

  vim.api.nvim_create_user_command("VaultPins", function()
    M.list()
  end, { desc = "List pinned vault notes" })

  vim.keymap.set("n", "<leader>vbp", function()
    M.toggle_pin()
  end, { desc = "Vault: toggle pin", silent = true })

  vim.keymap.set("n", "<leader>vbf", function()
    M.list()
  end, { desc = "Vault: find pinned notes", silent = true })
end

return M
