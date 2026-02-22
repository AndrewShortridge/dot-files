local engine = require("andrew.vault.engine")
local parser = require("andrew.vault.query.parser")
local index_mod = require("andrew.vault.query.index")
local executor = require("andrew.vault.query.executor")
local api = require("andrew.vault.query.api")
local render = require("andrew.vault.query.render")
local js2lua = require("andrew.vault.query.js2lua")

local M = {}

-- Cached index instance (rebuilt on demand)
local _index = nil
local _index_mtime = 0

--- Get or build the vault index. Rebuilds if vault was modified.
local function get_index()
  local vault_path = engine.vault_path
  -- Simple staleness check: rebuild if more than 30s old
  local now = os.time()
  if _index and (now - _index_mtime) < 30 then
    return _index
  end
  _index = index_mod.Index.new(vault_path)
  _index:build_sync()
  _index_mtime = now
  return _index
end

--- Force rebuild the index
function M.rebuild_index()
  _index = nil
  _index_mtime = 0
  get_index()
  vim.notify("Vault query: index rebuilt", vim.log.levels.INFO)
end

--- Find the code block boundaries around the cursor position.
--- Returns block_type, content, start_line, end_line (0-indexed) or nil.
local function find_code_block_at_cursor()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1 -- 0-indexed
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local total = #lines

  -- Walk backwards from cursor to find opening fence
  local open_line = nil
  local block_type = nil
  for i = row, 0, -1 do
    local line = lines[i + 1]
    local lang = line:match("^%s*```(%S+)")
    if lang then
      open_line = i
      block_type = lang:lower()
      break
    end
    -- Hit a closing fence before an opening one -> not inside a block
    if i < row and line:match("^%s*```%s*$") then
      return nil
    end
  end
  if not open_line then return nil end

  -- Walk forwards from opening fence to find closing fence
  local close_line = nil
  for i = open_line + 1, total - 1 do
    local line = lines[i + 1]
    if line:match("^%s*```%s*$") then
      close_line = i
      break
    end
  end
  if not close_line then return nil end

  -- Cursor must be between open and close
  if row < open_line or row > close_line then return nil end

  -- Extract content (lines between fences)
  local content_lines = {}
  for i = open_line + 2, close_line do -- +2 because buf_get_lines is 1-indexed
    table.insert(content_lines, lines[i])
  end
  local content = table.concat(content_lines, "\n")

  return block_type, content, open_line, close_line
end

--- Execute a dataview DQL query and return render results.
local function execute_dql(content, current_file)
  local idx = get_index()
  local ast, parse_err = parser.parse(content)
  if not ast then
    return { { type = "error", message = "Parse error: " .. (parse_err or "unknown") } }
  end
  local results, exec_err = executor.execute(ast, idx, current_file)
  if not results then
    return { { type = "error", message = "Execution error: " .. (exec_err or "unknown") } }
  end
  return results
end

--- Execute a Lua vault block and return render results.
local function execute_lua(content, current_file)
  local idx = get_index()
  local results, err = api.execute_block(content, idx, current_file)
  if not results then
    return { { type = "error", message = "Lua error: " .. (err or "unknown") } }
  end
  return results
end

--- Transpile JavaScript to Lua, then execute.
local function execute_js(content, current_file)
  local lua_code, transpile_err = js2lua.transpile(content)
  if not lua_code then
    return { { type = "error", message = "Transpile error: " .. (transpile_err or "unknown") } }
  end
  return execute_lua(lua_code, current_file)
end

--- Render the query block under the cursor, or inline expr on current line.
function M.render_block()
  local block_type, content, _, close_line = find_code_block_at_cursor()
  if not block_type then
    -- Check if current line has an inline `$=...` expression
    local buf = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = cursor[1] - 1
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    local found_inline = false
    local current_file = vim.api.nvim_buf_get_name(buf)
    local search_start = 1
    while true do
      local s, e, expr = line:find("`%$=(.-)%`", search_start)
      if not s then break end
      search_start = e + 1
      found_inline = true
      local ok, result = pcall(function()
        local lua_expr = js2lua.transpile(expr)
        if not lua_expr then lua_expr = expr end
        -- Wrap as return statement for inline expressions
        local code = "return " .. vim.trim(lua_expr)
        local idx = get_index()
        local results, err = api.execute_block(code, idx, current_file)
        if not results then return nil, err end
        if #results > 0 and results[1].text then
          return results[1].text
        elseif #results > 0 and results[1].items then
          return tostring(#results[1].items) .. " items"
        end
        return tostring(results[1] and results[1].text or "nil")
      end)
      if ok and result then
        render.render_inline(buf, row, e - 1, tostring(result), false)
      else
        render.render_inline(buf, row, e - 1, tostring(result or "error"), true)
      end
    end
    if not found_inline then
      vim.notify("Vault query: cursor not inside a code block or inline expression", vim.log.levels.WARN)
    end
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local current_file = vim.api.nvim_buf_get_name(buf)

  local ok, results = pcall(function()
    if block_type == "dataview" then
      return execute_dql(content, current_file)
    elseif block_type == "dataviewjs" then
      return execute_js(content, current_file)
    elseif block_type == "vault" then
      return execute_lua(content, current_file)
    else
      return { { type = "error", message = "unsupported block type '" .. block_type .. "'" } }
    end
  end)

  if ok then
    render.render(buf, close_line, results)
  else
    render.render(buf, close_line, {
      { type = "error", message = tostring(results) },
    })
  end
end

--- Clear rendered output under the cursor.
function M.clear_block()
  local block_type, _, _, close_line = find_code_block_at_cursor()
  if not block_type then
    vim.notify("Vault query: cursor not inside a code block", vim.log.levels.WARN)
    return
  end
  render.clear(vim.api.nvim_get_current_buf(), close_line)
end

--- Toggle rendered output under the cursor.
function M.toggle_block()
  local block_type, content, _, close_line = find_code_block_at_cursor()
  if not block_type then
    vim.notify("Vault query: cursor not inside a code block", vim.log.levels.WARN)
    return
  end

  local buf = vim.api.nvim_get_current_buf()

  if render.is_rendered(buf, close_line) then
    render.clear(buf, close_line)
  else
    local current_file = vim.api.nvim_buf_get_name(buf)
    local results
    if block_type == "dataview" then
      results = execute_dql(content, current_file)
    elseif block_type == "dataviewjs" then
      results = execute_js(content, current_file)
    elseif block_type == "vault" then
      results = execute_lua(content, current_file)
    else
      vim.notify("Vault query: unsupported block type '" .. block_type .. "'", vim.log.levels.WARN)
      return
    end
    render.render(buf, close_line, results)
  end
end

--- Render all query blocks in the current buffer.
function M.render_all()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local current_file = vim.api.nvim_buf_get_name(buf)
  local total = #lines
  local block_count = 0

  local i = 0
  while i < total do
    local line = lines[i + 1]
    local lang = line:match("^%s*```(%S+)")
    if lang then
      local block_type = lang:lower()
      if block_type == "dataview" or block_type == "dataviewjs" or block_type == "vault" then
        -- Find closing fence
        local close_line = nil
        local content_lines = {}
        for j = i + 1, total - 1 do
          if lines[j + 1]:match("^%s*```%s*$") then
            close_line = j
            break
          end
          table.insert(content_lines, lines[j + 1])
        end
        if close_line then
          local content = table.concat(content_lines, "\n")
          local ok, results = pcall(function()
            if block_type == "dataview" then
              return execute_dql(content, current_file)
            elseif block_type == "dataviewjs" then
              return execute_js(content, current_file)
            else
              return execute_lua(content, current_file)
            end
          end)
          if ok then
            local n = results and #results or 0
            if n == 0 then
              vim.notify("Vault query debug: block at line " .. i .. " (" .. block_type .. ") returned 0 results", vim.log.levels.WARN)
            end
            render.render(buf, close_line, results)
          else
            vim.notify("Vault query debug: block at line " .. i .. " error: " .. tostring(results), vim.log.levels.ERROR)
            render.render(buf, close_line, {
              { type = "error", message = tostring(results) },
            })
          end
          block_count = block_count + 1
          i = close_line + 1
        else
          i = i + 1
        end
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end

  -- Also render inline expressions
  local inline_count = M.render_inline_all()

  local parts = {}
  if block_count > 0 then
    parts[#parts + 1] = block_count .. " block(s)"
  end
  if inline_count > 0 then
    parts[#parts + 1] = inline_count .. " inline"
  end
  if #parts == 0 then
    vim.notify("Vault query: no dataview/vault queries found in buffer", vim.log.levels.WARN)
  else
    vim.notify("Vault query: rendered " .. table.concat(parts, ", "), vim.log.levels.INFO)
  end
end

--- Render all inline `$=expr` expressions in the current buffer.
function M.render_inline_all()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local current_file = vim.api.nvim_buf_get_name(buf)
  local count = 0
  local inside_code_block = false

  for i, line in ipairs(lines) do
    -- Track code block boundaries so we skip fenced blocks
    if line:match("^%s*```") then
      inside_code_block = not inside_code_block
    elseif not inside_code_block then
      -- Find all `$=...` patterns on this line
      local search_start = 1
      while true do
        local s, e, expr = line:find("`%$=(.-)%`", search_start)
        if not s then break end
        search_start = e + 1

        local row = i - 1 -- 0-indexed
        local ok, result = pcall(function()
          local lua_expr = js2lua.transpile(expr)
          if not lua_expr then lua_expr = expr end
          local code = "return " .. vim.trim(lua_expr)
          local idx = get_index()
          local results, err = api.execute_block(code, idx, current_file)
          if not results then return nil, err end
          if #results > 0 and results[1].text then
            return results[1].text
          elseif #results > 0 and results[1].items then
            return tostring(#results[1].items) .. " items"
          end
          return tostring(results[1] and results[1].text or "nil")
        end)
        if ok and result then
          render.render_inline(buf, row, e - 1, tostring(result), false)
        else
          render.render_inline(buf, row, e - 1, tostring(result or "error"), true)
        end
        count = count + 1
      end
    end
  end

  return count
end

--- Clear all rendered output in the current buffer.
function M.clear_all()
  local buf = vim.api.nvim_get_current_buf()
  render.clear_all(buf)
  render.clear_all_inline(buf)
end

-- =============================================================================
-- Commands
-- =============================================================================

vim.api.nvim_create_user_command("VaultQuery", function()
  M.render_block()
end, { desc = "Render vault query under cursor" })

vim.api.nvim_create_user_command("VaultQueryAll", function()
  M.render_all()
end, { desc = "Render all vault queries in buffer" })

vim.api.nvim_create_user_command("VaultQueryClear", function()
  M.clear_block()
end, { desc = "Clear rendered output under cursor" })

vim.api.nvim_create_user_command("VaultQueryClearAll", function()
  M.clear_all()
end, { desc = "Clear all rendered output in buffer" })

vim.api.nvim_create_user_command("VaultQueryToggle", function()
  M.toggle_block()
end, { desc = "Toggle vault query output under cursor" })

vim.api.nvim_create_user_command("VaultQueryRebuild", function()
  M.rebuild_index()
end, { desc = "Rebuild vault query index" })

-- =============================================================================
-- Keybindings
-- =============================================================================

local keymap = vim.keymap.set
local opts = function(desc)
  return { desc = desc, silent = true }
end

keymap("n", "<leader>vqr", function() M.render_block() end, opts("Vault: render query"))
keymap("n", "<leader>vqa", function() M.render_all() end, opts("Vault: render all queries"))
keymap("n", "<leader>vqc", function() M.clear_block() end, opts("Vault: clear query output"))
keymap("n", "<leader>vqx", function() M.clear_all() end, opts("Vault: clear all output"))
keymap("n", "<leader>vqq", function() M.toggle_block() end, opts("Vault: toggle query"))
keymap("n", "<leader>vqi", function() M.rebuild_index() end, opts("Vault: rebuild index"))

return M
