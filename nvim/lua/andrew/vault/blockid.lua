local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local notify = require("andrew.vault.notify")
local link_utils = require("andrew.vault.link_utils")
local pat = require("andrew.vault.patterns")
local block_patterns = require("andrew.vault.block_patterns")

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
  return block_patterns.match_id(line)
end

--- Get the note name (basename without .md) for the current buffer.
---@return string
local function current_note_name()
  return link_utils.get_basename(vim.api.nvim_buf_get_name(0))
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
  for _ = 1, config.blockid.max_retries do
    local id = "blk-" .. random_id(config.blockid.suffix_length)
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
    notify.warn("cannot add block ID to an empty line")
    return nil
  end

  -- Check if the line already has a block ID
  local bid = existing_block_id(line)
  if bid then
    -- Still copy the reference to clipboard for convenience
    local note = current_note_name()
    local ref = "[[" .. note .. "^" .. bid .. "]]"
    vim.fn.setreg("+", ref)
    notify.info("block ID already exists: ^" .. bid .. "  (reference copied)")
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
  notify.info("^" .. bid .. "  — reference copied: " .. ref)

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
      return name:match(pat.MD_EXTENSION)
    end, { path = vault_path, type = "file", limit = math.huge })

    local names = {}
    local name_to_path = {}
    for _, path in ipairs(files) do
      local rel = link_utils.rel_to_stem(path:sub(#vault_path + 2))
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
      notify.warn("could not resolve target note")
      return
    end

    -- Read target file, append the block reference on a new line at the end
    local content = engine.read_file(target_path)
    if not content then
      notify.warn("could not read " .. target_path)
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

    notify.info("inserted " .. ref .. " in " .. choice)

    -- If the target note is open in a buffer, reload it
    local target_buf = vim.fn.bufnr(target_path)
    if target_buf ~= -1 and vim.api.nvim_buf_is_loaded(target_buf) then
      vim.api.nvim_buf_call(target_buf, function()
        vim.cmd("edit!")
      end)
    end
  end)
end

--- Called by event_dispatch.lua on FileType markdown.
--- @param ev table autocmd event args
function M.on_ft_markdown(ev)
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
end

function M.setup()
  local palette = require("andrew.vault.command_palette")

  -- Commands
  vim.api.nvim_create_user_command("VaultBlockId", function()
    M.generate()
  end, { desc = "Vault: generate block ID for current line" })

  vim.api.nvim_create_user_command("VaultBlockIdLink", function()
    M.generate_and_link()
  end, { desc = "Vault: generate block ID and insert reference in another note" })

  -- FileType autocmd removed: now dispatched via event_dispatch.lua

  -- Palette registrations
  palette.register_command("VaultBlockId", "Vault: generate block ID for current line", "Meta", function()
    M.generate()
  end, "<leader>vki")
  palette.register_command("VaultBlockIdLink", "Vault: generate block ID and insert reference in another note", "Meta", function()
    M.generate_and_link()
  end, "<leader>vkl")
end

return M
