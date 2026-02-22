local engine = require("andrew.vault.engine")
local wikilinks = require("andrew.vault.wikilinks")

local M = {}

--- Characters used for random block ID generation (alphanumeric, Obsidian-safe).
local charset = "abcdefghijklmnopqrstuvwxyz0123456789"

--- Generate a random alphanumeric string of the given length.
---@param len number
---@return string
local function random_id(len)
  math.randomseed(os.time() + vim.uv.hrtime())
  local chars = {}
  for _ = 1, len do
    local idx = math.random(1, #charset)
    chars[#chars + 1] = charset:sub(idx, idx)
  end
  return table.concat(chars)
end

--- Check whether a line already has a block ID (^identifier at end of line).
--- Returns the existing block ID (without the ^) or nil.
---@param line string
---@return string|nil
local function existing_block_id(line)
  return line:match("%^([%w%-]+)%s*$")
end

--- Get the note name (basename without .md) for the current buffer.
---@return string
local function current_note_name()
  return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t:r")
end

--- Collect all block IDs already present in the current buffer to avoid collisions.
---@return table<string, boolean>
local function collect_existing_ids()
  local ids = {}
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for _, line in ipairs(lines) do
    local id = existing_block_id(line)
    if id then
      ids[id] = true
    end
  end
  return ids
end

--- Generate a unique block ID that doesn't collide with existing ones in the buffer.
---@return string the block ID without the ^ prefix
local function unique_block_id()
  local existing = collect_existing_ids()
  for _ = 1, 100 do
    local id = "blk-" .. random_id(6)
    if not existing[id] then
      return id
    end
  end
  -- Extremely unlikely fallback: use timestamp-based ID
  return "blk-" .. tostring(os.time()):sub(-6)
end

--- Generate a block ID for the current line.
--- Appends `^blk-XXXXXX` to the end of the current line and copies
--- the full block reference `[[NoteName^blk-XXXXXX]]` to the system clipboard.
---@return string|nil block_id the generated or existing block ID, nil if line is empty
function M.generate()
  local line = vim.api.nvim_get_current_line()
  local row = vim.api.nvim_win_get_cursor(0)[1]

  -- Don't add block IDs to empty lines
  if vim.trim(line) == "" then
    vim.notify("Vault: cannot add block ID to an empty line", vim.log.levels.WARN)
    return nil
  end

  -- Check if the line already has a block ID
  local bid = existing_block_id(line)
  if bid then
    -- Still copy the reference to clipboard for convenience
    local note = current_note_name()
    local ref = "[[" .. note .. "^" .. bid .. "]]"
    vim.fn.setreg("+", ref)
    vim.notify("Vault: block ID already exists: ^" .. bid .. "  (reference copied)", vim.log.levels.INFO)
    return bid
  end

  -- Generate new block ID
  bid = unique_block_id()

  -- Append block ID to end of line, separated by a space
  -- Trim any trailing whitespace first, then append
  local trimmed = line:gsub("%s+$", "")
  local new_line = trimmed .. " ^" .. bid
  vim.api.nvim_buf_set_lines(0, row - 1, row, false, { new_line })

  -- Build the full block reference and copy to clipboard
  local note = current_note_name()
  local ref = "[[" .. note .. "^" .. bid .. "]]"
  vim.fn.setreg("+", ref)
  vim.notify("Vault: ^" .. bid .. "  — reference copied: " .. ref, vim.log.levels.INFO)

  return bid
end

--- Generate a block ID for the current line and insert a reference in a target note.
--- Prompts the user to pick a target note from the vault, then appends the block
--- reference at the end of that note.
function M.generate_and_link()
  -- First generate the block ID on the current line
  local bid = M.generate()
  if not bid then
    return
  end

  local source_note = current_note_name()
  local ref = "[[" .. source_note .. "^" .. bid .. "]]"

  engine.run(function()
    -- Collect note names for the picker
    local vault_path = engine.vault_path
    local files = vim.fs.find(function(name)
      return name:match("%.md$")
    end, { path = vault_path, type = "file", limit = math.huge })

    local names = {}
    local name_to_path = {}
    for _, path in ipairs(files) do
      local rel = path:sub(#vault_path + 2):gsub("%.md$", "")
      names[#names + 1] = rel
      name_to_path[rel] = path
    end
    table.sort(names)

    local choice = engine.select(names, {
      prompt = "Insert block reference in",
      format_item = function(item)
        return item
      end,
    })
    if not choice then
      return
    end

    local target_path = name_to_path[choice]
    if not target_path then
      vim.notify("Vault: could not resolve target note", vim.log.levels.ERROR)
      return
    end

    -- Read target file, append the block reference on a new line at the end
    local content = engine.read_file(target_path)
    if not content then
      vim.notify("Vault: could not read " .. target_path, vim.log.levels.ERROR)
      return
    end

    -- Ensure the file ends with a newline before appending
    if content:sub(-1) ~= "\n" then
      content = content .. "\n"
    end
    content = content .. ref .. "\n"

    if not engine.write_file(target_path, content) then
      return
    end

    vim.notify("Vault: inserted " .. ref .. " in " .. choice, vim.log.levels.INFO)

    -- If the target note is open in a buffer, reload it
    local target_buf = vim.fn.bufnr(target_path)
    if target_buf ~= -1 and vim.api.nvim_buf_is_loaded(target_buf) then
      vim.api.nvim_buf_call(target_buf, function()
        vim.cmd("edit!")
      end)
    end
  end)
end

function M.setup()
  -- Commands
  vim.api.nvim_create_user_command("VaultBlockId", function()
    M.generate()
  end, { desc = "Vault: generate block ID for current line" })

  vim.api.nvim_create_user_command("VaultBlockIdLink", function()
    M.generate_and_link()
  end, { desc = "Vault: generate block ID and insert reference in another note" })

  -- Keymaps (buffer-local for markdown files)
  local group = vim.api.nvim_create_augroup("VaultBlockId", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "<leader>vki", function()
        M.generate()
      end, {
        buffer = ev.buf,
        desc = "Block: generate ID",
        silent = true,
      })
      vim.keymap.set("n", "<leader>vkl", function()
        M.generate_and_link()
      end, {
        buffer = ev.buf,
        desc = "Block: generate ID + link in target",
        silent = true,
      })
    end,
  })
end

return M
