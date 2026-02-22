local engine = require("andrew.vault.engine")

local M = {}

--- Return the absolute path to the pins JSON file.
---@return string
local function pins_path()
  return engine.vault_path .. "/.vault-pins.json"
end

--- Return the current buffer's path relative to vault_path, or nil if outside the vault.
---@return string|nil
local function buf_rel_path()
  local abs = vim.api.nvim_buf_get_name(0)
  if abs == "" then
    return nil
  end
  abs = vim.fn.resolve(abs)
  local vault = vim.fn.resolve(engine.vault_path)
  if abs:find(vault, 1, true) ~= 1 then
    return nil
  end
  -- Strip vault prefix and leading slash
  return abs:sub(#vault + 2)
end

--- Load pinned paths from the JSON file.
---@return string[]
local function load_pins()
  local file = io.open(pins_path(), "r")
  if not file then
    return {}
  end
  local raw = file:read("*a")
  file:close()
  if raw == "" then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return {}
  end
  return decoded
end

--- Write the pins list to the JSON file.
---@param pins string[]
local function save_pins(pins)
  local file = io.open(pins_path(), "w")
  if not file then
    vim.notify("Vault: failed to write pins file", vim.log.levels.ERROR)
    return
  end
  file:write(vim.json.encode(pins))
  file:close()
end

--- Pin the current buffer's note.
function M.pin()
  local rel = buf_rel_path()
  if not rel then
    vim.notify("Vault: buffer is not inside the vault", vim.log.levels.WARN)
    return
  end
  local pins = load_pins()
  for _, p in ipairs(pins) do
    if p == rel then
      vim.notify("Vault: already pinned " .. rel, vim.log.levels.INFO)
      return
    end
  end
  pins[#pins + 1] = rel
  save_pins(pins)
  vim.notify("Vault: pinned " .. rel, vim.log.levels.INFO)
end

--- Unpin the current buffer's note.
function M.unpin()
  local rel = buf_rel_path()
  if not rel then
    vim.notify("Vault: buffer is not inside the vault", vim.log.levels.WARN)
    return
  end
  local pins = load_pins()
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
  save_pins(new)
  vim.notify("Vault: unpinned " .. rel, vim.log.levels.INFO)
end

--- Toggle pin state for the current buffer's note.
function M.toggle_pin()
  local rel = buf_rel_path()
  if not rel then
    vim.notify("Vault: buffer is not inside the vault", vim.log.levels.WARN)
    return
  end
  local pins = load_pins()
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
  local pins = load_pins()
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
  fzf.fzf_exec(abs_paths, {
    prompt = "Pinned notes> ",
    file_icons = true,
    git_icons = false,
    previewer = "builtin",
    actions = {
      ["default"] = fzf.actions.file_edit,
      ["ctrl-s"] = fzf.actions.file_split,
      ["ctrl-v"] = fzf.actions.file_vsplit,
    },
  })
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
