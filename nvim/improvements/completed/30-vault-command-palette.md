# Vault Command Palette

**Priority:** Medium
**Scope:** New module + integration with init.lua
**Effort:** ~200 lines of new code, minor edits to init.lua and which-key.lua

## Summary

Add a unified command palette (`<leader>v?`) that lists every vault command and
keymap in a single fzf-lua picker, searchable by name, description, and
category. This gives instant discoverability for the 100+ vault commands that
are currently scattered across 30+ modules, only findable via `:Vault<Tab>`
completion or memorised keymaps.

## Current State

### The problem

The vault plugin registers:

- **~100 user commands** (`VaultSearch`, `VaultBacklinks`, `VaultTasks`, ...)
  across 30+ module files via `vim.api.nvim_create_user_command()`.
- **~80 keymaps** (`<leader>vfs`, `<leader>vxo`, `<leader>vG`, ...) via
  `vim.keymap.set()`, split between global keymaps and buffer-local keymaps
  (registered inside `FileType markdown` autocmds).
- **16 which-key groups** (`<leader>va`, `<leader>vb`, ..., `<leader>vx`)
  registered in `lua/andrew/plugins/which-key.lua`.

Discovery mechanisms today:

| Method | Limitation |
|---|---|
| `:Vault<Tab>` | Only commands, no descriptions visible, no fuzzy search |
| `<leader>v` + wait | which-key popup shows groups, but not leaf descriptions until you drill down |
| `<leader>fk` (fzf-lua keymaps) | Shows ALL keymaps globally, vault keymaps buried in noise |
| Reading source code | Not realistic during editing |

There is no single place to see "what can the vault do?" with fuzzy search over
descriptions.

### Module registration patterns

Each vault module follows one of two patterns:

**Pattern A -- global keymaps + commands (in `M.setup()`):**

```lua
-- tasks.lua
function M.setup()
  vim.api.nvim_create_user_command("VaultTasks", function()
    M.tasks()
  end, { desc = "Show open tasks across vault" })

  vim.keymap.set("n", "<leader>vxo", function()
    M.tasks()
  end, { desc = "Tasks: open", silent = true })
end
```

**Pattern B -- buffer-local keymaps (inside FileType autocmd):**

```lua
-- backlinks.lua
function M.setup()
  vim.api.nvim_create_user_command("VaultBacklinks", function()
    M.backlinks()
  end, { desc = "Show notes linking to current note" })

  local group = vim.api.nvim_create_augroup("VaultBacklinks", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "<leader>vfb", function()
        M.backlinks()
      end, { buffer = ev.buf, desc = "Find: backlinks", silent = true })
    end,
  })
end
```

Both patterns store the description string in the `desc` option, but there is
no programmatic way to collect them all without introspecting Neovim's internal
keymap/command tables.

## Implementation

### Architecture

```
command_palette.lua
  |
  +-- M._registry = {}          -- static registry populated at load time
  +-- M.register(entry)         -- add a single entry
  +-- M.register_command(...)   -- helper for user commands
  +-- M.register_keymap(...)    -- helper for keymaps
  +-- M.open()                  -- fzf-lua picker
  +-- M.setup()                 -- bind <leader>v?, register self
```

The registry is a flat table of entry records. Each module calls
`register_command` / `register_keymap` right after its `nvim_create_user_command`
or `vim.keymap.set` call. This is explicit and grep-able -- no magic
introspection of Neovim internals.

### New file: `lua/andrew/vault/command_palette.lua`

```lua
local M = {}

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
  Export    = "[Export]    ",
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
---@return string[] lines
---@return VaultPaletteEntry[] entries (same index as lines)
local function build_entries()
  -- Sort by category order, then alphabetically within category
  local cat_rank = {}
  for i, cat in ipairs(M._category_order) do
    cat_rank[cat] = i
  end

  local sorted = {}
  for _, entry in ipairs(M._registry) do
    sorted[#sorted + 1] = entry
  end
  table.sort(sorted, function(a, b)
    local ra = cat_rank[a.category] or 999
    local rb = cat_rank[b.category] or 999
    if ra ~= rb then return ra < rb end
    return a.desc < b.desc
  end)

  local lines = {}
  local entries = {}
  for _, entry in ipairs(sorted) do
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
    vim.notify("Vault: no commands registered in palette", vim.log.levels.WARN)
    return
  end

  fzf.fzf_exec(lines, {
    prompt = "Vault Command> ",
    winopts = {
      height = 0.6,
      width = 0.7,
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
```

### Integration: how modules register their entries

Each module adds `register_command` / `register_keymap` calls alongside its
existing `nvim_create_user_command` and `vim.keymap.set` calls. The palette
module is required lazily to avoid load-order issues.

**Example -- search.lua (before):**

```lua
function M.setup()
  vim.api.nvim_create_user_command("VaultSearch", function()
    M.search()
  end, { desc = "Live grep across the vault" })

  vim.keymap.set("n", "<leader>vfs", function()
    M.search()
  end, { desc = "Find: search vault", silent = true })
end
```

**Example -- search.lua (after):**

```lua
function M.setup()
  local palette = require("andrew.vault.command_palette")

  vim.api.nvim_create_user_command("VaultSearch", function()
    M.search()
  end, { desc = "Live grep across the vault" })

  vim.keymap.set("n", "<leader>vfs", function()
    M.search()
  end, { desc = "Find: search vault", silent = true })

  palette.register_command("VaultSearch", "Live grep across the vault",
    "Search", M.search, "<leader>vfs")

  -- For commands with no keymap:
  palette.register_command("VaultSearchFiltered", "Search by directory scope",
    "Search", M.search_filtered, "<leader>vfD")

  -- For keymaps without a matching command (rare):
  -- palette.register_keymap("<leader>vfH", "Search history", "Search",
  --   function() require("andrew.vault.search_history").pick() end)
end
```

**Example -- tasks.lua (after):**

```lua
function M.setup()
  local palette = require("andrew.vault.command_palette")

  vim.api.nvim_create_user_command("VaultTasks", function()
    M.tasks()
  end, { desc = "Show open tasks across vault" })

  vim.keymap.set("n", "<leader>vxo", function()
    M.tasks()
  end, { desc = "Tasks: open", silent = true })

  palette.register_command("VaultTasks", "Show open tasks across vault",
    "Tasks", M.tasks, "<leader>vxo")

  palette.register_command("VaultTasksAll", "Show all tasks (any state)",
    "Tasks", M.tasks_all, "<leader>vxa")
end
```

### Category assignments

Full mapping of all existing commands/keymaps to categories:

| Category | Commands | Keymaps |
|---|---|---|
| **Search** | VaultSearch, VaultSearchNotes, VaultSearchFiltered, VaultSearchType, VaultSearchAdvanced, VaultSearchAdvancedLive, VaultSearchHelp, VaultSearchSave, VaultSearchList, VaultSearchDelete, VaultSearchHistory, VaultSearchHistoryClear | `<leader>vfs`, `<leader>vfn`, `<leader>vfD`, `<leader>vfy`, `<leader>vfA`, `<leader>vfH`, `<leader>vfS` |
| **Navigate** | VaultDailyPrev, VaultDailyNext, VaultDailyToday, VaultDailyList, VaultWeeklyList, VaultWeeklyPrev, VaultWeeklyNext, VaultReviewList, VaultCalendar, VaultFiles, VaultRecent | `<leader>vfd`, `<leader>vfw`, `<leader>vfW`, `<leader>v[`, `<leader>v]`, `<leader>v{`, `<leader>v}`, `<leader>vC`, `<leader>vff`, `<leader>vfr` |
| **Edit** | VaultExtract, VaultRename, VaultRenamePreview, VaultCapture, VaultCaptureInbox, VaultInsertFragment, VaultPasteImage, VaultQuickTask | `<leader>ver`, `<leader>veR`, `<leader>vep`, `<leader>vI`, `<leader>vp`, `<leader>vxq` |
| **Tasks** | VaultTasks, VaultTasksAll, VaultTasksByState, VaultOverdue, VaultOverdueSnooze, VaultKanban, VaultTaskTree, VaultTimeline, VaultCarryForward | `<leader>vxo`, `<leader>vxa`, `<leader>vxs`, `<leader>vxd`, `<leader>vxk`, `<leader>vxh`, `<leader>vxt`, `<leader>vdc` |
| **Graph** | VaultGraph, VaultRelated, VaultConnectionsRefresh, VaultConnectionDebug | `<leader>vG`, `<leader>vr` |
| **Tags** | VaultTags, VaultTagTree, VaultTagAdd, VaultTagRemove, VaultTagRename | `<leader>vft`, `<leader>vfT`, `<leader>vga`, `<leader>vgr`, `<leader>vet` |
| **Links** | VaultBacklinks, VaultForwardlinks, VaultLinkCheck, VaultLinkCheckAll, VaultOrphans, VaultURLCheck, VaultURLCheckAll, VaultLinkDiag, VaultLinkDiagToggle, VaultFixLinks, VaultLinkRepair, VaultLinkRepairAll, VaultUnlinked, VaultUnlinkedAll, VaultAutoLink, VaultAutoLinkAll, VaultAutoLinkToggle, VaultAutoLinkRefresh, VaultAutoLinkAccept, VaultAutoLinkAcceptLine, VaultAutoLinkDebug | `<leader>vfb`, `<leader>vfl`, `<leader>vfh`, `<leader>vcb`, `<leader>vca`, `<leader>vco`, `<leader>vcu`, `<leader>vcU`, `<leader>vcd`, `<leader>vcf`, `<leader>vcF`, `<leader>vcr`, `<leader>vcR`, `<leader>vfu`, `<leader>vfU`, `<leader>vaB`, `<leader>vaV`, `<leader>va`, `<leader>vA`, `<leader>vgA` |
| **Templates** | VaultNew, VaultDaily, VaultTemplateReload, VaultTemplateEdit, VaultTemplateList | `<leader>vtn`, `<leader>vtd`, `<leader>vtw`, `<leader>vts`, `<leader>vta`, `<leader>vtk`, `<leader>vtm`, `<leader>vtf`, `<leader>vtl`, `<leader>vtp`, `<leader>vtj`, `<leader>vtc`, `<leader>vtM`, `<leader>vtQ`, `<leader>vtY` |
| **Embed** | VaultEmbedRender, VaultEmbedClear, VaultEmbedToggle, VaultEmbedDebug, VaultEmbedSync, VaultFootnoteRender, VaultFootnoteClear, VaultFootnoteToggle, VaultFootnoteOrphans | (no dedicated keymaps) |
| **Export** | VaultExport | `<leader>vep` |
| **Sidebar** | VaultSidebar, VaultSidebarBacklinks, VaultSidebarTags, VaultSidebarMeta | `<leader>vS`, `<leader>vSb`, `<leader>vSt`, `<leader>vSm` |
| **Meta** | VaultMetaEdit, VaultMetaCycle, VaultMetaToggle, VaultFrontmatterEdit, VaultAutoFile, VaultAutoFileMove, VaultAutoSave, VaultSwitch, VaultProjects, VaultStickyProject, VaultStickyClear, VaultPin, VaultUnpin, VaultPins, VaultBlockId, VaultBlockIdLink | `<leader>vms`, `<leader>vmp`, `<leader>vmm`, `<leader>vmt`, `<leader>vmf`, `<leader>vM`, `<leader>vmv`, `<leader>vW`, `<leader>vV`, `<leader>vfp`, `<leader>vP`, `<leader>vbp`, `<leader>vbf`, `<leader>vki`, `<leader>vkl` |
| **Index** | VaultIndexRebuild, VaultIndexStatus, VaultIndexCollisions, VaultCacheInvalidate, VaultCacheStatus, VaultWatcherStatus | (no dedicated keymaps) |
| **Debug** | VaultEmbedDebug, VaultConnectionDebug, VaultAutoLinkDebug, VaultFoldDebug, VaultURLCacheStats, VaultHighlightToggle, VaultHighlightRefresh, VaultWikilinkHLToggle, VaultWikilinkHLRefresh, VaultFieldHLToggle, VaultFieldHLRefresh, VaultFieldList, VaultTagHLToggle, VaultTagHLRefresh, VaultFoldClear, VaultStats | `<leader>vch`, `<leader>vgt`, `<leader>vfF`, `<leader>vD` |

### Alternative: introspect Neovim directly (considered, rejected)

An alternative approach would be to skip the registry entirely and introspect
`vim.api.nvim_get_commands({})` + `vim.api.nvim_get_keymap("n")` at picker
open time, filtering for `Vault` prefix and `<leader>v` prefix respectively.

**Pros:** Zero changes to existing modules, always in sync.

**Cons:**
- No category metadata (would have to infer from command/keymap prefix).
- No way to associate a command with its keymap (they are registered
  independently).
- Buffer-local keymaps (registered in FileType autocmds) only appear when a
  markdown buffer is active.
- `nvim_get_commands` returns command names but the `action` field is the
  Lua function reference, which is not easily callable from the picker (it
  is callable, but the API is awkward).
- Description text comes from the `desc` field, which is inconsistently
  formatted across modules.

**Hybrid approach (recommended for v1):** Start with the introspection approach
for immediate value, then layer on the explicit registry for category metadata
and better descriptions. The introspection can serve as a fallback for any
commands that haven't been registered yet.

### Hybrid v1 implementation

```lua
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
  local cmds = vim.api.nvim_get_commands({})
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

  -- Collect unregistered <leader>v keymaps (normal mode)
  for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
    local lhs = map.lhs or ""
    if lhs:match("^<leader>v") and not registered_keymaps[lhs] then
      extra[#extra + 1] = {
        name = map.desc or lhs,
        desc = map.desc or lhs,
        category = M._infer_category(lhs),
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

  -- Also check buffer-local keymaps for current buffer
  if vim.bo.filetype == "markdown" then
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
      local lhs = map.lhs or ""
      if lhs:match("^<leader>v") and not registered_keymaps[lhs] then
        extra[#extra + 1] = {
          name = map.desc or lhs,
          desc = map.desc or lhs,
          category = M._infer_category(lhs),
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

--- Infer a category from a command or keymap name.
---@param name string
---@return string
function M._infer_category(name)
  -- Command-based inference
  if name:match("Search") or name:match("Query") then return "Search" end
  if name:match("Task") or name:match("Kanban") or name:match("Timeline")
    or name:match("Overdue") then return "Tasks" end
  if name:match("Daily") or name:match("Weekly") or name:match("Calendar")
    or name:match("Recent") or name:match("Navigate")
    or name:match("Review") then return "Navigate" end
  if name:match("Graph") or name:match("Connection") or name:match("Related") then return "Graph" end
  if name:match("Tag") then return "Tags" end
  if name:match("Link") or name:match("Backlink") or name:match("Forward")
    or name:match("Orphan") or name:match("URL") or name:match("Unlinked")
    or name:match("AutoLink") then return "Links" end
  if name:match("Template") or name:match("New") then return "Templates" end
  if name:match("Embed") or name:match("Footnote") then return "Embed" end
  if name:match("Export") then return "Export" end
  if name:match("Sidebar") then return "Sidebar" end
  if name:match("Index") or name:match("Cache") or name:match("Watcher") then return "Index" end
  if name:match("Debug") or name:match("Toggle") or name:match("Refresh")
    or name:match("Stats") then return "Debug" end

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

  return "Meta"
end
```

Then `build_entries()` merges the explicit registry with the introspected
fallback, deduplicating by command name and keymap:

```lua
local function build_entries()
  -- Merge explicit registry + introspected extras
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
```

### Integration with init.lua

Add two lines to `lua/andrew/vault/init.lua`:

```lua
-- Load command palette (must be after all other modules so introspection sees
-- their keymaps/commands)
require("andrew.vault.command_palette").setup()
```

This goes at the very end of init.lua, just before the `return M` statement,
after all other modules have been loaded and registered their commands/keymaps.

### Integration with which-key.lua

Add one entry to the which-key group registrations:

```lua
{ "<leader>v?", group = "Palette" },
```

This is not strictly necessary (which-key auto-discovers mapped keys), but it
makes the `?` key visible in the which-key popup when `<leader>v` is pressed.

### Keymap

| Keymap | Command | Description |
|---|---|---|
| `<leader>v?` | `:VaultPalette` | Open vault command palette |

### fzf-lua picker details

- **Prompt:** `Vault Command> `
- **Preview:** hidden (commands have no file to preview)
- **Window:** 60% height, 70% width, centered slightly above middle
- **Header:** `Vault Command Palette  |  <CR> to execute`
- **Search scope:** fzf searches the full formatted line, which includes
  category tag, description, keymap, and command name -- so the user can type
  any of those to filter
- **Action on `<CR>`:** `vim.schedule()` the entry's `action` function after
  fzf closes, so modals/pickers launched by the action don't conflict with
  fzf's window

### Display format

Each line in the picker looks like:

```
[Search]    Live grep across the vault  <leader>vfs  :VaultSearch
[Search]    Advanced search (live mode)  <leader>vfA  :VaultSearchAdvancedLive
[Tasks]     Show open tasks across vault  <leader>vxo  :VaultTasks
[Navigate]  Open today's daily log  <leader>vtd  :VaultDaily
[Links]     Show notes linking to current note  <leader>vfb  :VaultBacklinks
[Meta]      Switch active vault  <leader>vV  :VaultSwitch
[Index]     Rebuild vault index from scratch  :VaultIndexRebuild
```

The category tag is fixed-width (padded to 11 chars) so the descriptions
align vertically. fzf fuzzy-matches across the entire line, so typing
"backlink" or "vfb" or "Links" all find the backlinks entry.

## Rollout plan

### Phase 1: Hybrid introspection (immediate value, minimal changes)

1. Create `command_palette.lua` with `_collect_from_nvim()` introspection and
   `_infer_category()` heuristic.
2. Add `require("andrew.vault.command_palette").setup()` to init.lua.
3. Add which-key group entry.
4. Result: fully functional palette with auto-discovered commands/keymaps,
   reasonable category inference, zero changes to existing modules.

### Phase 2: Explicit registration (incremental, optional)

Gradually add `palette.register_command()` calls to individual modules for
better descriptions and exact category assignment. Each module can be updated
independently. The introspection fallback ensures nothing is ever missing.

## Test plan

- [ ] Open a vault markdown file, press `<leader>v?` -- palette opens with
  all vault commands visible
- [ ] Type `search` -- only search-related entries remain
- [ ] Type `<leader>vf` -- entries with that keymap prefix appear
- [ ] Press `<CR>` on `VaultSearch` -- fzf closes, live grep opens
- [ ] Press `<CR>` on `VaultGraph` -- fzf closes, graph view opens
- [ ] Press `<CR>` on `VaultTasks` -- fzf closes, task picker opens
- [ ] Open a non-markdown file, press `<leader>v?` -- palette still works,
  buffer-local keymaps (backlinks, outline, etc.) may not appear (expected)
- [ ] Run `:VaultPalette` -- same result as `<leader>v?`
- [ ] Verify no duplicate entries (command registered both as command and keymap)
- [ ] Verify category grouping: entries within same category appear together
- [ ] Verify `<Esc>` in picker cancels without executing anything
- [ ] Open palette, select a template entry (e.g. "Template: daily log") --
  template runs correctly after palette closes

## Files modified

| File | Change |
|---|---|
| `lua/andrew/vault/command_palette.lua` | **New file** -- registry, introspection, fzf picker, setup |
| `lua/andrew/vault/init.lua` | Add `require("andrew.vault.command_palette").setup()` before `return M` |
| `lua/andrew/plugins/which-key.lua` | Add `{ "<leader>v?", group = "Palette" }` to group registrations |

Phase 2 (optional, incremental):

| File | Change |
|---|---|
| `lua/andrew/vault/search.lua` | Add `palette.register_command()` calls in `M.setup()` |
| `lua/andrew/vault/tasks.lua` | Add `palette.register_command()` calls in `M.setup()` |
| `lua/andrew/vault/backlinks.lua` | Add `palette.register_command()` calls in `M.setup()` |
| `lua/andrew/vault/navigate.lua` | Add `palette.register_command()` calls in `M.setup()` |
| `lua/andrew/vault/graph.lua` | Add `palette.register_command()` calls in `M.setup()` |
| `lua/andrew/vault/tags.lua` | Add `palette.register_command()` calls in `M.setup()` |
| `lua/andrew/vault/embed.lua` | Add `palette.register_command()` calls in `M.setup()` |
| ... (all other vault modules) | Same pattern |
