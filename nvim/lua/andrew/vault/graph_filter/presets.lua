--- Graph filter preset persistence.
--- Manages saving, loading, listing, and deleting filter presets.

local M = {}

local notify = require("andrew.vault.notify")

local _store = nil

--- Get the JSON store for filter presets (lazy-initialized).
---@return table store with .load() and .save() methods
function M.preset_store()
  if not _store then
    local engine = require("andrew.vault.engine")
    _store = engine.json_store(".vault-graph-presets.json", { presets = {} })
  end
  return _store
end

--- Save the current filter state as a named preset.
---@param name string
---@param state GraphFilterState
function M.save_preset(name, state)
  local store = M.preset_store()
  local data = store.load()
  data.presets = data.presets or {}
  data.presets[name] = vim.deepcopy(state)
  store.save(data)
end

--- Load a named preset, filling missing fields from defaults.
---@param name string
---@param defaults GraphFilterState default state to merge with
---@return GraphFilterState|nil
function M.load_preset(name, defaults)
  local store = M.preset_store()
  local data = store.load()
  local preset = data.presets and data.presets[name]
  if not preset then return nil end
  return vim.tbl_deep_extend("keep", preset, defaults)
end

--- List all saved preset names.
---@return string[]
function M.list_presets()
  local store = M.preset_store()
  local data = store.load()
  local names = {}
  for name in pairs(data.presets or {}) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

--- Delete a named preset.
---@param name string
function M.delete_preset(name)
  local store = M.preset_store()
  local data = store.load()
  if data.presets then
    data.presets[name] = nil
  end
  store.save(data)
end

--- Open the preset picker (load/delete).
---@param state_ref table reference with .state field to mutate
---@param default_state fun(): GraphFilterState
---@param on_apply fun() callback after loading a preset
function M.open_preset_picker(state_ref, default_state, on_apply)
  local names = M.list_presets()
  if #names == 0 then
    notify.info("no saved presets")
    return
  end

  local fzf = require("fzf-lua")
  fzf.fzf_exec(names, {
    prompt = "Load preset> ",
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          local loaded = M.load_preset(selected[1], default_state())
          if loaded then
            state_ref.state = loaded
            on_apply()
          end
        end
      end,
      ["ctrl-x"] = function(selected)
        if selected and selected[1] then
          M.delete_preset(selected[1])
          notify.info("deleted preset '" .. selected[1] .. "'")
        end
      end,
    },
  })
end

--- Save a preset with user-provided name.
---@param state GraphFilterState
---@param on_done fun()|nil
function M.save_preset_prompt(state, on_done)
  vim.ui.input({ prompt = "Preset name: " }, function(name)
    if not name or vim.trim(name) == "" then
      if on_done then on_done() end
      return
    end
    M.save_preset(vim.trim(name), state)
    notify.info("saved preset '" .. vim.trim(name) .. "'")
    if on_done then on_done() end
  end)
end

return M
