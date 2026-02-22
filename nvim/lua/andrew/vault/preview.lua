local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local link_utils = require("andrew.vault.link_utils")

local M = {}

-- Pre-compute terminal keycodes for scrolling
local ctrl_e = vim.api.nvim_replace_termcodes("<C-e>", true, false, true)
local ctrl_y = vim.api.nvim_replace_termcodes("<C-y>", true, false, true)

-- Active preview state
local state = {
  win = nil,
  buf = nil,
  parent_buf = nil,
  augroup = nil,
}

--- Close the active preview and clean up keymaps/autocmds.
local function close_preview()
  -- Remove parent buffer scroll keymaps
  if state.parent_buf and vim.api.nvim_buf_is_valid(state.parent_buf) then
    for _, key in ipairs({ "<C-j>", "<C-k>" }) do
      pcall(vim.keymap.del, "n", key, { buffer = state.parent_buf })
    end
  end
  -- Clear autocmds
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
  state.win = nil
  state.buf = nil
  state.parent_buf = nil
end

--- Check if a preview is currently active.
local function is_active()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

--- Scroll the preview window by delta lines.
---@param delta number positive = down, negative = up
local function scroll_preview(delta)
  if not is_active() then
    return
  end
  local count = math.abs(delta)
  local key = delta > 0 and ctrl_e or ctrl_y
  vim.fn.win_execute(state.win, "normal! " .. count .. key)
end

--- Parse the wikilink under the cursor into its components.
---@return {name: string, heading: string|nil, block_id: string|nil, alias: string|nil}|nil, string|nil
local function get_wikilink_details_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1

  local start = 1
  while true do
    local open_start, open_end = line:find("%[%[", start)
    if not open_start then
      return nil, nil
    end
    local close_start, close_end = line:find("%]%]", open_end + 1)
    if not close_start then
      return nil, nil
    end
    if col >= open_start and col <= close_end then
      local inner = line:sub(open_end + 1, close_start - 1)
      return link_utils.parse_target(inner), inner
    end
    start = close_end + 1
  end
end

--- Resolve a link name to an absolute file path, or nil if not found.
---@param name string
---@return string|nil
local function resolve_link(name)
  -- Try direct path first
  local direct = engine.vault_path .. "/" .. name .. ".md"
  if vim.fn.filereadable(direct) == 1 then
    return direct
  end

  -- Fall back to recursive search
  local results = vim.fs.find(name .. ".md", {
    path = engine.vault_path,
    type = "file",
    limit = 1,
  })
  return results[1]
end

--- Convert heading text to a slug for comparison (Obsidian-style).
---@param text string
---@return string
local function heading_slug(text)
  return text:lower()
    :gsub("[^%w%s%-]", "")
    :gsub("%s+", "-")
    :gsub("%-+", "-")
    :gsub("^%-+", "")
    :gsub("%-+$", "")
end

--- Extract section lines under a heading from a list of lines.
--- Captures from the heading through the next heading of same or higher level.
---@param lines string[]
---@param heading string heading text to match
---@return string[]
local function extract_heading_section(lines, heading)
  local target_slug = heading_slug(heading)
  local result = {}
  local capturing = false
  local target_level = nil

  for _, line in ipairs(lines) do
    if capturing then
      local level_str = line:match("^(#+)%s+")
      if level_str and #level_str <= target_level then
        break
      end
      result[#result + 1] = line
    else
      local level_str, text = line:match("^(#+)%s+(.*)")
      if text then
        local slug = heading_slug(text)
        if slug == target_slug then
          target_level = #level_str
          capturing = true
          result[#result + 1] = line
        end
      end
    end
  end

  return result
end

--- Extract the paragraph containing a block reference from a list of lines.
---@param lines string[]
---@param block_id string
---@return string[]
local function extract_block_content(lines, block_id)
  local escaped = vim.pesc(block_id)
  local paragraphs = {}
  local current = {}

  for _, line in ipairs(lines) do
    if line:match("^%s*$") then
      if #current > 0 then
        paragraphs[#paragraphs + 1] = current
        current = {}
      end
    else
      current[#current + 1] = line
    end
  end
  if #current > 0 then
    paragraphs[#paragraphs + 1] = current
  end

  for _, para in ipairs(paragraphs) do
    for _, line in ipairs(para) do
      if line:match("%^" .. escaped .. "%s*$") then
        local result = {}
        for _, l in ipairs(para) do
          result[#result + 1] = l:gsub("%s*%^" .. escaped .. "%s*$", "")
        end
        return result
      end
    end
  end

  return {}
end

--- Read all lines from a file path.
---@param path string
---@return string[]|nil
local function read_file_lines(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local lines = {}
  for l in f:lines() do
    lines[#lines + 1] = l
  end
  f:close()
  return lines
end

--- Show a floating preview of the note linked under the cursor.
--- Supports same-file heading/block references: [[#Heading]], [[^block-id]]
--- Press K again or move the cursor to close. C-j/C-k scroll the preview.
function M.preview()
  -- Toggle off if already showing
  if is_active() then
    close_preview()
    return
  end

  local details, raw_inner = get_wikilink_details_under_cursor()
  if not details then
    vim.notify("No wikilink under cursor", vim.log.levels.INFO)
    return
  end

  local all_lines
  local title

  if details.name == "" then
    -- Same-file reference: [[#heading]] or [[^block-id]]
    local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    if details.heading then
      all_lines = extract_heading_section(buf_lines, details.heading)
      title = "#" .. details.heading
      if #all_lines == 0 then
        all_lines = { "[Heading not found: #" .. details.heading .. "]" }
      end
    elseif details.block_id then
      all_lines = extract_block_content(buf_lines, details.block_id)
      title = "^" .. details.block_id
      if #all_lines == 0 then
        all_lines = { "[Block not found: ^" .. details.block_id .. "]" }
      end
    else
      vim.notify("No wikilink under cursor", vim.log.levels.INFO)
      return
    end
  else
    -- Cross-file reference
    title = details.name
    local path = resolve_link(details.name)
    if path then
      local file_lines = read_file_lines(path)
      if file_lines then
        if details.heading then
          all_lines = extract_heading_section(file_lines, details.heading)
          title = details.name .. "#" .. details.heading
          if #all_lines == 0 then
            all_lines = { "[Heading not found: #" .. details.heading .. "]" }
          end
        elseif details.block_id then
          all_lines = extract_block_content(file_lines, details.block_id)
          title = details.name .. "^" .. details.block_id
          if #all_lines == 0 then
            all_lines = { "[Block not found: ^" .. details.block_id .. "]" }
          end
        else
          all_lines = file_lines
        end
      else
        all_lines = { "[Could not read file]" }
      end
    else
      all_lines = { "[Note does not exist yet]" }
    end
  end

  -- Compute float dimensions
  local max_width = config.preview.max_width
  local max_height = config.preview.max_lines
  local width = 0
  for _, l in ipairs(all_lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(math.max(width, 20), max_width)
  local height = math.min(#all_lines, max_height)

  -- Create buffer with content (enables scrolling)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
  vim.bo[buf].bufhidden = "wipe"

  -- Open floating window near cursor (not focused — stays in parent)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = { { " " .. title .. " ", "Function" } },
    title_pos = "center",
  })

  -- Window options: enable render-markdown rendering and readable wrapping
  vim.wo[win].conceallevel = 2
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].foldenable = false

  -- Set filetype AFTER window exists so render-markdown can find the buffer
  -- in a valid window context during its FileType autocmd handler
  vim.bo[buf].filetype = "markdown"

  -- Explicitly start treesitter for the scratch buffer
  pcall(vim.treesitter.start, buf, "markdown")

  -- Manually trigger render-markdown since the float is not focused and
  -- normal render events (BufWinEnter, CursorMoved, etc.) won't fire
  pcall(function()
    require("render-markdown").render({ buf = buf, win = win })
  end)

  -- Lock buffer after all rendering setup is complete
  vim.bo[buf].modifiable = false

  -- Store state
  state.win = win
  state.buf = buf
  state.parent_buf = vim.api.nvim_get_current_buf()

  -- Scroll keymaps on the PARENT buffer (C-j/C-k don't move cursor, so
  -- CursorMoved won't fire and the preview stays open while scrolling)
  local scroll_amount = 3
  vim.keymap.set("n", "<C-j>", function()
    scroll_preview(scroll_amount)
  end, { buffer = state.parent_buf, nowait = true, silent = true, desc = "Scroll preview down" })
  vim.keymap.set("n", "<C-k>", function()
    scroll_preview(-scroll_amount)
  end, { buffer = state.parent_buf, nowait = true, silent = true, desc = "Scroll preview up" })

  -- Auto-close on cursor move or leaving the buffer
  state.augroup = vim.api.nvim_create_augroup("VaultPreviewClose", { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = state.augroup,
    buffer = state.parent_buf,
    once = true,
    callback = close_preview,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = state.augroup,
    buffer = state.parent_buf,
    once = true,
    callback = close_preview,
  })
end

--- Open the linked note under the cursor in an editable floating window.
function M.edit_link()
  local details = get_wikilink_details_under_cursor()
  if not details or details.name == "" then
    vim.notify("No cross-file wikilink under cursor", vim.log.levels.INFO)
    return
  end

  local link = details.name
  local path = resolve_link(link)
  if not path then
    vim.notify("Note not found: " .. link, vim.log.levels.WARN)
    return
  end

  -- Compute float dimensions: 80% width, 60% height, centered
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines
  local width = math.floor(editor_width * 0.8)
  local height = math.floor(editor_height * 0.6)
  local row = math.floor((editor_height - height) / 2)
  local col = math.floor((editor_width - width) / 2)

  -- Open (or reuse) the buffer for the file
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)

  -- Open focused floating window
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    border = "rounded",
    title = { { " " .. link .. " ", "Function" } },
    title_pos = "center",
  })

  -- Buffer options
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")

  -- Window options
  vim.wo[win].conceallevel = 2
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].foldenable = false
  vim.wo[win].winhighlight = "Normal:Normal,FloatBorder:FloatBorder"

  -- Helper to save and close the float
  local function save_and_close()
    if vim.api.nvim_buf_get_option(buf, "modified") then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent write")
      end)
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, false)
    end
  end

  -- Keymaps inside the float
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q", save_and_close, vim.tbl_extend("force", opts, { desc = "Save and close float" }))
  vim.keymap.set("n", "<Esc><Esc>", save_and_close, vim.tbl_extend("force", opts, { desc = "Save and close float" }))
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
  end, vim.tbl_extend("force", opts, { desc = "Save float buffer" }))

  -- Auto-save on WinClosed
  local augroup = vim.api.nvim_create_augroup("VaultEditFloat_" .. win, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = tostring(win),
    once = true,
    callback = function()
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_option(buf, "modified") then
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("silent write")
        end)
      end
      pcall(vim.api.nvim_del_augroup_by_id, augroup)
    end,
  })
end

function M.setup()
  vim.api.nvim_create_user_command("VaultPreview", function()
    M.preview()
  end, { desc = "Vault: preview wikilink under cursor" })

  local group = vim.api.nvim_create_augroup("VaultPreview", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "K", function()
        M.preview()
      end, { buffer = ev.buf, desc = "Vault: preview link", silent = true })
      vim.keymap.set("n", "<leader>vE", function()
        M.edit_link()
      end, { buffer = ev.buf, desc = "Vault: edit link in float", silent = true })
    end,
  })
end

return M
