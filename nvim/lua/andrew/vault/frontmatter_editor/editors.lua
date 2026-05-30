local engine = require("andrew.vault.engine")
local fm_parser = require("andrew.vault.frontmatter_parser")
local notify = require("andrew.vault.notify")
local pat = require("andrew.vault.patterns")
local type_utils = require("andrew.vault.frontmatter_editor.type_utils")
local field_ops = require("andrew.vault.frontmatter_editor.field_ops")
local vault_queries = require("andrew.vault.frontmatter_editor.vault_queries")

local M = {}

--- Create a prefix-matching completion function from a list of candidates.
---@param candidates string[]
---@return function
local function make_prefix_completion(candidates)
  return function(_, line, _)
    local matches = {}
    local prefix = line:lower()
    for _, v in ipairs(candidates) do
      if v:lower():find(prefix, 1, true) == 1 then
        matches[#matches + 1] = v
      end
    end
    return matches
  end
end

--- Select a value from a cycle field's allowed values.
---@param values any[]
---@param prompt string
---@return any|nil chosen_value
local function select_from_cycle(values, prompt)
  local items = {}
  for _, v in ipairs(values) do
    items[#items + 1] = tostring(v)
  end
  local choice = engine.select(items, { prompt = prompt })
  if not choice then return nil end

  for _, v in ipairs(values) do
    if tostring(v) == choice then
      return v
    end
  end
  return nil
end

--- Edit a string/number/date field via vim.ui.input.
---@param field FmEditorField
---@param state FmEditorState
---@param render_fn function
local function edit_string_field(field, state, render_fn)
  engine.run(function()
    local existing = vault_queries.vault_field_values(field.key)
    local prompt = field.key
    if #existing > 0 then
      prompt = prompt .. " (tab for suggestions)"
    end
    local new_val = engine.input({
      prompt = prompt .. ": ",
      default = type_utils.format_display_value(field.value, field.field_type),
      completion = #existing > 0 and make_prefix_completion(existing) or nil,
    })
    if new_val == nil then return end

    local typed = fm_parser.parse_value(new_val)
    field.value = typed
    field.field_type = type_utils.detect_field_type(field.key, typed)
    field_ops.write_field_to_source(state.source_buf, field.key, typed)
    render_fn()
  end)
end

--- Edit a boolean field by toggling.
---@param field FmEditorField
---@param state FmEditorState
---@param render_fn function
local function edit_boolean_field(field, state, render_fn)
  local new_val = not field.value
  field.value = new_val
  field.field_type = "boolean"
  field_ops.write_field_to_source(state.source_buf, field.key, new_val)
  render_fn()
end

--- Edit a cycle field by selecting from allowed values.
---@param field FmEditorField
---@param state FmEditorState
---@param render_fn function
local function edit_cycle_field(field, state, render_fn)
  local values = type_utils.CYCLE_FIELDS[field.key]
  if not values then return end

  engine.run(function()
    local chosen = select_from_cycle(values, field.key)
    if not chosen then return end

    field.value = chosen
    field.field_type = type_utils.detect_field_type(field.key, chosen)
    field_ops.write_field_to_source(state.source_buf, field.key, chosen)
    render_fn()
  end)
end

--- Edit a list field via repeated input.
---@param field FmEditorField
---@param state FmEditorState
---@param render_fn function
---@param resize_fn function
local function edit_list_field(field, state, render_fn, resize_fn)
  engine.run(function()
    local items = {}
    if type(field.value) == "table" then
      for _, v in ipairs(field.value) do
        items[#items + 1] = tostring(v)
      end
    end

    local actions = { "Add item", "Remove item", "Replace all", "Clear", "Cancel" }
    local action = engine.select(actions, {
      prompt = field.key .. " [" .. #items .. " items]",
    })
    if not action or action == "Cancel" then return end

    if action == "Add item" then
      local existing = vault_queries.vault_field_values(field.key)
      local new_item = engine.input({
        prompt = "New " .. field.key .. " item: ",
        completion = #existing > 0 and make_prefix_completion(existing) or nil,
      })
      if not new_item or new_item == "" then return end
      items[#items + 1] = new_item
    elseif action == "Remove item" then
      if #items == 0 then
        notify.warn("list is empty")
        return
      end
      local to_remove = engine.select(items, { prompt = "Remove from " .. field.key })
      if not to_remove then return end
      local new_items = {}
      for _, item in ipairs(items) do
        if item ~= to_remove then
          new_items[#new_items + 1] = item
        end
      end
      items = new_items
    elseif action == "Replace all" then
      local raw = engine.input({
        prompt = field.key .. " (comma-separated): ",
        default = table.concat(items, ", "),
      })
      if not raw then return end
      items = {}
      for item in raw:gmatch(pat.CSV_ITEM) do
        local trimmed = vim.trim(item)
        if trimmed ~= "" then
          items[#items + 1] = trimmed
        end
      end
    elseif action == "Clear" then
      items = {}
    end

    local typed_items = {}
    for _, item in ipairs(items) do
      typed_items[#typed_items + 1] = fm_parser.parse_value(item)
    end

    field.value = typed_items
    field.field_type = "list"
    field_ops.set_list_field(state.source_buf, field.key, typed_items)
    render_fn()
    resize_fn()
  end)
end

--- Edit a date field via input with default = today.
---@param field FmEditorField
---@param state FmEditorState
---@param render_fn function
local function edit_date_field(field, state, render_fn)
  engine.run(function()
    local default = type_utils.format_display_value(field.value, field.field_type)
    if default == "" then
      default = os.date("%Y-%m-%d")
    end
    local new_val = engine.input({
      prompt = field.key .. " (YYYY-MM-DD): ",
      default = default,
    })
    if not new_val or new_val == "" then return end

    field.value = new_val
    field.field_type = type_utils.detect_field_type(field.key, new_val)
    field_ops.write_field_to_source(state.source_buf, field.key, new_val)
    render_fn()
  end)
end

--- Dispatch to the appropriate edit function based on field type.
---@param field FmEditorField
---@param state FmEditorState
---@param render_fn function
---@param resize_fn function
function M.edit_field(field, state, render_fn, resize_fn)
  local ft = field.field_type
  if ft == "boolean" then
    edit_boolean_field(field, state, render_fn)
  elseif ft == "cycle" then
    edit_cycle_field(field, state, render_fn)
  elseif ft == "list" then
    edit_list_field(field, state, render_fn, resize_fn)
  elseif ft == "date" then
    edit_date_field(field, state, render_fn)
  else
    edit_string_field(field, state, render_fn)
  end
end

--- Add a new field to the frontmatter.
---@param state FmEditorState
---@param render_fn function
---@param resize_fn function
function M.add_field(state, render_fn, resize_fn)
  engine.run(function()
    local known_names = vault_queries.vault_field_names()
    local new_key = engine.input({
      prompt = "New field name: ",
      completion = #known_names > 0 and make_prefix_completion(known_names) or nil,
    })
    if not new_key or new_key == "" then return end

    for _, f in ipairs(state.fields) do
      if f.key == new_key then
        notify.warn("field '" .. new_key .. "' already exists")
        return
      end
    end

    local default_value = ""
    if type_utils.CYCLE_FIELDS[new_key] then
      local chosen = select_from_cycle(type_utils.CYCLE_FIELDS[new_key], new_key)
      if not chosen then return end
      default_value = chosen
    else
      local raw = engine.input({ prompt = new_key .. ": " })
      if raw == nil then return end
      default_value = fm_parser.parse_value(raw)
    end

    local new_field = {
      key = new_key,
      value = default_value,
      field_type = type_utils.detect_field_type(new_key, default_value),
    }
    state.fields[#state.fields + 1] = new_field
    state.cursor_idx = #state.fields

    if type(default_value) == "table" then
      field_ops.set_list_field(state.source_buf, new_key, default_value)
    else
      field_ops.write_field_to_source(state.source_buf, new_key, default_value)
    end

    render_fn()
    resize_fn()
  end)
end

--- Delete the currently selected field.
---@param state FmEditorState
---@param render_fn function
---@param resize_fn function
function M.delete_current_field(state, render_fn, resize_fn)
  if #state.fields == 0 then return end

  local field = state.fields[state.cursor_idx]
  if not field then return end

  engine.run(function()
    local confirm = engine.select({ "Yes", "No" }, {
      prompt = "Delete '" .. field.key .. "'?",
    })
    if confirm ~= "Yes" then return end

    field_ops.delete_field(state.source_buf, field.key)

    table.remove(state.fields, state.cursor_idx)
    if state.cursor_idx > #state.fields then
      state.cursor_idx = math.max(1, #state.fields)
    end

    render_fn()
    resize_fn()
  end)
end

return M
