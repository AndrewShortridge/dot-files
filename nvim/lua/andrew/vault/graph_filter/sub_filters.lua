--- Graph filter sub-filter UI components.
--- Handles the individual filter category pickers (tags, types, dates, etc.).

local M = {}

local notify = require("andrew.vault.notify")
local config = require("andrew.vault.config")
local date_utils = require("andrew.vault.date_utils")
local engine = require("andrew.vault.engine")
local fzf = require("fzf-lua")
local tags_mod = require("andrew.vault.tags")
local ui = require("andrew.vault.ui")
local search_query = require("andrew.vault.search_query")

--- Open an fzf multi-select picker and return selected items.
---@param items string[]
---@param prompt string
---@param on_select fun(selected: string[])
local function fzf_multi_select(items, prompt, on_select)
  fzf.fzf_exec(items, {
    prompt = prompt,
    fzf_opts = { ["--multi"] = "" },
    actions = {
      ["default"] = function(selected)
        on_select(selected or {})
      end,
    },
  })
end

-- ---------------------------------------------------------------------------
-- Date range parsing (used by category 4)
-- ---------------------------------------------------------------------------

--- Parse a date range input string into from/to date strings.
--- Supports shortcuts like "7d", "30d", "today", "this-week", "this-month",
--- and explicit "YYYY-MM-DD..YYYY-MM-DD" ranges.
---@param input string
---@return string|nil from_date, string|nil to_date
function M.parse_date_range(input)
  input = vim.trim(input)
  if input == "" then return nil, nil end

  local today = engine.today()

  -- Check shortcuts
  local shortcut = config.graph.date_shortcuts[input]
  if shortcut then
    if type(shortcut) == "table" and shortcut.offset_days then
      local from = engine.date_offset(shortcut.offset_days)
      return from, today
    elseif shortcut == "week" then
      return date_utils.resolve_date_string("this-week"), today
    elseif shortcut == "month" then
      return date_utils.resolve_date_string("this-month"), today
    end
  end

  -- Explicit range: "YYYY-MM-DD..YYYY-MM-DD"
  local from, to = input:match("^(%d%d%d%d%-%d%d%-%d%d)%.%.(%d%d%d%d%-%d%d%-%d%d)$")
  if from then return from, to end

  -- Single date = exact day
  if date_utils.is_iso_date(input) then
    return input, input
  end

  -- Keywords and relative dates (7d, 30d, yesterday, etc.) via shared resolver
  local resolved = date_utils.resolve_date_string(input)
  if resolved then
    return resolved, today
  end

  return nil, nil
end

-- ---------------------------------------------------------------------------
-- Display helpers
-- ---------------------------------------------------------------------------

--- Format the date filter portion for display.
---@param state GraphFilterState
---@return string
function M.format_date_filter(state)
  if not state.date_field then return "(none)" end
  local range = state.date_from or "*"
  range = range .. ".." .. (state.date_to or "*")
  return state.date_field .. " " .. range
end

--- Format toggles for display.
---@param state GraphFilterState
---@return string
function M.format_toggles(state)
  local parts = {}
  parts[#parts + 1] = "unresolved=" .. (state.show_unresolved and "on" or "off")
  parts[#parts + 1] = "existing-only=" .. (state.existing_only and "on" or "off")
  return table.concat(parts, " ")
end

-- ---------------------------------------------------------------------------
-- Category handlers (dispatch table)
-- ---------------------------------------------------------------------------

---@param field_name string state field to update
---@param prompt string fzf prompt
local function handle_tags(field_name, prompt)
  return function(state, on_done)
    tags_mod.collect_tags(function(tags)
      if #tags == 0 then
        notify.no_tags()
        on_done()
        return
      end
      fzf_multi_select(tags, prompt, function(selected)
        state[field_name] = selected
        on_done()
      end)
    end)
  end
end

local function handle_note_type(state, on_done)
  fzf_multi_select(config.note_types, "Note types> ", function(selected)
    state.note_types = selected
    on_done()
  end)
end

--- Open a float input and dispatch based on empty/non-empty input.
---@param title string
---@param on_empty fun() called when input is empty
---@param on_value fun(input: string) called when input is non-empty
---@param on_done fun() always called after processing
local function filter_text_input(title, on_empty, on_value, on_done)
  ui.create_float_input({
    title = title,
    width = config.graph.filter_input_width,
    on_submit = function(lines)
      local input = lines[1] or ""
      if input == "" then
        on_empty()
      else
        on_value(input)
      end
      on_done()
    end,
    submit_modes = { "n", "i" },
  })
end

local function handle_date_range(state, on_done)
  vim.ui.select({ "modified", "created" }, { prompt = "Date field:" }, function(field)
    if not field then
      on_done()
      return
    end
    filter_text_input(
      "Date range (7d, 30d, today, this-week, this-month, YYYY-MM-DD..YYYY-MM-DD)",
      function()
        state.date_field = nil
        state.date_from = nil
        state.date_to = nil
      end,
      function(input)
        local from, to = M.parse_date_range(input)
        if from or to then
          state.date_field = field
          state.date_from = from
          state.date_to = to
        else
          notify.warn("unrecognized date range: " .. input)
        end
      end,
      on_done
    )
  end)
end

local function handle_depth(state, on_done)
  local items = {}
  for i = 1, config.graph.max_depth do
    items[#items + 1] = tostring(i)
  end
  vim.ui.select(items, { prompt = "Link depth:" }, function(choice)
    if choice then
      state.depth = tonumber(choice) or 1
    end
    on_done()
  end)
end

local function handle_path_exclude(state, on_done)
  local items = {}
  for _, scope in ipairs(config.scopes) do
    if scope.key ~= "all" then
      items[#items + 1] = scope.label
    end
  end
  fzf_multi_select(items, "Exclude paths> ", function(selected)
    if #selected == 0 then
      on_done()
      return
    end
    local paths = {}
    for _, label in ipairs(selected) do
      for _, scope in ipairs(config.scopes) do
        if scope.label == label and scope.key ~= "all" then
          local dir = scope.glob:match("^([^*]+)") or ""
          dir = dir:gsub("/$", "") .. "/"
          paths[#paths + 1] = dir
          break
        end
      end
    end
    state.paths_exclude = paths
    on_done()
  end)
end

local function handle_toggles(state, on_done)
  local function render_toggle_lines()
    return {
      "  [1] Show unresolved:     " .. (state.show_unresolved and "ON" or "OFF"),
      "  [2] Existing files only: " .. (state.existing_only and "ON" or "OFF"),
      "",
      "  Press 1/2 to toggle, q to close",
    }
  end

  local float = ui.create_float_display({
    title = "Toggle Filters",
    lines = render_toggle_lines(),
    width = config.graph.filter_toggle_width,
    height = 4,
    cursor_line = true,
  })

  local function refresh()
    vim.bo[float.buf].modifiable = true
    vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, render_toggle_lines())
    vim.bo[float.buf].modifiable = false
  end

  vim.keymap.set("n", "1", function()
    state.show_unresolved = not state.show_unresolved
    refresh()
  end, { buffer = float.buf, nowait = true, silent = true })

  vim.keymap.set("n", "2", function()
    state.existing_only = not state.existing_only
    refresh()
  end, { buffer = float.buf, nowait = true, silent = true })

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      float.close()
      on_done()
    end, { buffer = float.buf, nowait = true, silent = true })
  end
end

local function handle_search_expr(state, on_done)
  filter_text_input(
    "Search expression (e.g., has:tasks AND tag:urgent)",
    function()
      state.search_expr = nil
    end,
    function(input)
      local ast, err = search_query.parse_query(input)
      if ast then
        state.search_expr = input
      else
        notify.warn("invalid search expression: " .. (err or "unknown"))
      end
    end,
    on_done
  )
end

---@type table<number, fun(state: GraphFilterState, on_done: fun())>
local category_handlers = {
  [1] = handle_tags("tags_include", "Include tags> "),
  [2] = handle_tags("tags_exclude", "Exclude tags> "),
  [3] = handle_note_type,
  [4] = handle_date_range,
  [5] = handle_depth,
  [6] = handle_path_exclude,
  [7] = handle_toggles,
  [8] = handle_search_expr,
}

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Open a sub-filter picker for the given filter category.
---@param category number 1-8
---@param state GraphFilterState
---@param on_done fun()
function M.open_sub_filter(category, state, on_done)
  local handler = category_handlers[category]
  if handler then
    handler(state, on_done)
  end
end

return M
