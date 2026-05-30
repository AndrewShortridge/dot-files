local M = {}
local config = require("andrew.vault.config")
local notify = require("andrew.vault.notify")

---@class VaultPaletteEntry
---@field name string       Display name (command name or keymap description)
---@field desc string       One-line description
---@field category string   Category for grouping (Search, Tasks, Navigate, etc.)
---@field keymap string|nil Keymap if one exists (e.g. "<leader>vfs")
---@field command string|nil Vim command if one exists (e.g. "VaultSearch")
---@field action fun()      Function to execute
---@field buffer_local boolean Whether this is a buffer-local (markdown-only) binding

--- Static registry of all vault palette entries.
---@type VaultPaletteEntry[]
M._registry = {}

--- Category display order for consistent grouping.
M._category_order = {
  "Search",
  "Navigate",
  "Edit",
  "Tasks",
  "Graph",
  "Tags",
  "Links",
  "Templates",
  "Embed",
  "Export",
  "Sidebar",
  "Meta",
  "Index",
  "Debug",
}

--- Map category names to icon/prefix for display.
local category_icons = {
  Search    = "[Search]   ",
  Navigate  = "[Navigate] ",
  Edit      = "[Edit]     ",
  Tasks     = "[Tasks]    ",
  Graph     = "[Graph]    ",
  Tags      = "[Tags]     ",
  Links     = "[Links]    ",
  Templates = "[Template] ",
  Embed     = "[Embed]    ",
  Export    = "[Export]   ",
  Sidebar   = "[Sidebar]  ",
  Meta      = "[Meta]     ",
  Index     = "[Index]    ",
  Debug     = "[Debug]    ",
}

--- Register a single palette entry.
---@param entry VaultPaletteEntry
function M.register(entry)
  M._registry[#M._registry + 1] = entry
end

--- Convenience: register a user command with its palette metadata.
---@param command string       e.g. "VaultSearch"
---@param desc string          e.g. "Live grep across the vault"
---@param category string      e.g. "Search"
---@param action fun()         the function to execute
---@param keymap? string       e.g. "<leader>vfs"
function M.register_command(command, desc, category, action, keymap)
  M.register({
    name = command,
    desc = desc,
    category = category,
    command = command,
    keymap = keymap,
    action = action,
    buffer_local = false,
  })
end

--- Convenience: register a keymap-only entry (no user command).
---@param keymap string        e.g. "<leader>vfb"
---@param desc string          e.g. "Find: backlinks to current note"
---@param category string      e.g. "Links"
---@param action fun()
---@param buffer_local? boolean
function M.register_keymap(keymap, desc, category, action, buffer_local)
  M.register({
    name = desc,
    desc = desc,
    category = category,
    command = nil,
    keymap = keymap,
    action = action,
    buffer_local = buffer_local or false,
  })
end

--- Infer a category from a command or keymap name.
---@param name string
---@return string
function M._infer_category(name)
  -- Command-based inference
  if name:match("Search") or name:match("Query") then return "Search" end
  if name:match("Task") or name:match("Kanban") or name:match("Timeline")
    or name:match("Overdue") or name:match("CarryForward") then return "Tasks" end
  if name:match("Daily") or name:match("Weekly") or name:match("Calendar")
    or name:match("Recent") or name:match("Navigate")
    or name:match("Review") or name:match("Files") then return "Navigate" end
  if name:match("Graph") or name:match("Connection") or name:match("Related") then return "Graph" end
  if name:match("Tag") and not name:match("Sticky") then return "Tags" end
  if name:match("Link") or name:match("Backlink") or name:match("Forward")
    or name:match("Orphan") or name:match("URL") or name:match("Unlinked")
    or name:match("AutoLink") then return "Links" end
  if name:match("Template") or name:match("VaultNew") or name:match("VaultDaily") then return "Templates" end
  if name:match("Embed") or name:match("Footnote") or name:match("ImageRetry") then return "Embed" end
  if name:match("Export") then return "Export" end
  if name:match("Sidebar") then return "Sidebar" end
  if name:match("Extract") or name:match("Rename") or name:match("Capture")
    or name:match("Fragment") or name:match("PasteImage")
    or name:match("QuickTask") then return "Edit" end
  if name:match("Index") or name:match("Cache") or name:match("Watcher") then return "Index" end
  if name:match("Debug") or name:match("Toggle") or name:match("Refresh")
    or name:match("Stats") or name:match("Fold") or name:match("Highlight")
    or name:match("HL") then return "Debug" end
  if name:match("Meta") or name:match("Frontmatter") or name:match("AutoFile")
    or name:match("AutoSave") or name:match("Switch") or name:match("Project")
    or name:match("Sticky") or name:match("Pin") or name:match("Block")
    or name:match("Vault") then return "Meta" end

  -- Keymap-based inference
  if name:match("<leader>vf") then return "Search" end
  if name:match("<leader>vx") then return "Tasks" end
  if name:match("<leader>vt") then return "Templates" end
  if name:match("<leader>ve") then return "Edit" end
  if name:match("<leader>vc") then return "Links" end
  if name:match("<leader>vg") then return "Tags" end
  if name:match("<leader>vm") then return "Meta" end
  if name:match("<leader>vS") then return "Sidebar" end
  if name:match("<leader>va") then return "Links" end
  if name:match("<leader>vd") then return "Navigate" end
  if name:match("<leader>vb") then return "Meta" end
  if name:match("<leader>vk") then return "Meta" end

  return "Meta"
end

--- Collect entries from Neovim's command/keymap tables as a fallback.
--- Used for any Vault* commands or <leader>v keymaps not explicitly registered.
---@return VaultPaletteEntry[]
function M._collect_from_nvim()
  local extra = {}
  local registered_commands = {}
  local registered_keymaps = {}

  -- Build lookup sets from explicit registry
  for _, entry in ipairs(M._registry) do
    if entry.command then registered_commands[entry.command] = true end
    if entry.keymap then registered_keymaps[entry.keymap] = true end
  end

  -- Collect unregistered Vault* user commands
  local ok, cmds = pcall(vim.api.nvim_get_commands, {})
  if ok then
    for name, info in pairs(cmds) do
      if name:match("^Vault") and not registered_commands[name] then
        extra[#extra + 1] = {
          name = name,
          desc = info.definition or name,
          category = M._infer_category(name),
          command = name,
          keymap = nil,
          action = function() vim.cmd(name) end,
          buffer_local = false,
        }
      end
    end
  end

  -- Collect unregistered <leader>v keymaps (normal mode, global)
  for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
    local lhs = map.lhs or ""
    if lhs:match("^<leader>v") and not registered_keymaps[lhs] then
      extra[#extra + 1] = {
        name = map.desc or lhs,
        desc = map.desc or lhs,
        category = M._infer_category(map.desc or lhs),
        command = nil,
        keymap = lhs,
        action = function()
          vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes(lhs, true, false, true),
            "m", false
          )
        end,
        buffer_local = false,
      }
    end
  end

  -- Also check buffer-local keymaps for current buffer (markdown-only bindings)
  if vim.bo.filetype == "markdown" then
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
      local lhs = map.lhs or ""
      if lhs:match("^<leader>v") and not registered_keymaps[lhs] then
        extra[#extra + 1] = {
          name = map.desc or lhs,
          desc = map.desc or lhs,
          category = M._infer_category(map.desc or lhs),
          command = nil,
          keymap = lhs,
          action = function()
            vim.api.nvim_feedkeys(
              vim.api.nvim_replace_termcodes(lhs, true, false, true),
              "m", false
            )
          end,
          buffer_local = true,
        }
      end
    end
  end

  return extra
end

--- Format a single entry for fzf display.
---@param entry VaultPaletteEntry
---@return string
local function format_entry(entry)
  local icon = category_icons[entry.category] or ("[" .. entry.category .. "] ")
  local keys = ""
  if entry.keymap then
    keys = "  " .. entry.keymap
  end
  if entry.command then
    if keys ~= "" then
      keys = keys .. "  :" .. entry.command
    else
      keys = "  :" .. entry.command
    end
  end
  return icon .. entry.desc .. keys
end

--- Build sorted display lines and a parallel lookup table.
--- Merges explicit registry with introspected fallback, deduplicating.
---@return string[] lines
---@return VaultPaletteEntry[] entries (same index as lines)
local function build_entries()
  local all = {}
  local seen_cmd = {}
  local seen_key = {}

  -- Explicit entries take priority
  for _, entry in ipairs(M._registry) do
    all[#all + 1] = entry
    if entry.command then seen_cmd[entry.command] = true end
    if entry.keymap then seen_key[entry.keymap] = true end
  end

  -- Add introspected entries that were not explicitly registered
  for _, entry in ipairs(M._collect_from_nvim()) do
    local dominated = false
    if entry.command and seen_cmd[entry.command] then dominated = true end
    if entry.keymap and seen_key[entry.keymap] then dominated = true end
    if not dominated then
      all[#all + 1] = entry
      if entry.command then seen_cmd[entry.command] = true end
      if entry.keymap then seen_key[entry.keymap] = true end
    end
  end

  -- Sort by category order, then alphabetically within category
  local cat_rank = {}
  for i, cat in ipairs(M._category_order) do
    cat_rank[cat] = i
  end

  table.sort(all, function(a, b)
    local ra = cat_rank[a.category] or 999
    local rb = cat_rank[b.category] or 999
    if ra ~= rb then return ra < rb end
    return a.desc < b.desc
  end)

  local lines = {}
  local entries = {}
  for _, entry in ipairs(all) do
    lines[#lines + 1] = format_entry(entry)
    entries[#entries + 1] = entry
  end
  return lines, entries
end

--- Open the command palette fzf-lua picker.
function M.open()
  local fzf = require("fzf-lua")
  local lines, entries = build_entries()

  if #lines == 0 then
    notify.warn("no commands registered in palette")
    return
  end

  fzf.fzf_exec(lines, {
    prompt = "Vault Command> ",
    winopts = {
      height = config.command_palette.height,
      width = config.command_palette.width,
      row = 0.3,
      preview = { hidden = "hidden" },
    },
    fzf_opts = {
      ["--no-multi"] = "",
      ["--header"] = "Vault Command Palette  |  <CR> to execute",
    },
    actions = {
      ["default"] = function(selected)
        if not selected or #selected == 0 then return end
        -- Find matching entry by display line
        local line = selected[1]
        for i, l in ipairs(lines) do
          if l == line then
            -- Schedule to run after fzf window closes
            vim.schedule(function()
              entries[i].action()
            end)
            return
          end
        end
      end,
    },
  })
end

--- Register the palette's own keymap and command.
function M.setup()
  vim.api.nvim_create_user_command("VaultPalette", function()
    M.open()
  end, { desc = "Open vault command palette" })

  vim.keymap.set("n", "<leader>v?", function()
    M.open()
  end, { desc = "Vault: command palette", silent = true })
end

return M
