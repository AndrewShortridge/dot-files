local engine = require("andrew.vault.engine")
local link_utils = require("andrew.vault.link_utils")
local cleanup = require("andrew.vault.resource_cleanup")
-- Lazy-load command_palette: register_* calls just append to tables, so we
-- queue them until the module is actually required (Tier 2 FileType autocmd).
-- The proxy returns stub functions for register_command/register_keymap that
-- queue calls; any other key access triggers the real require + replay.
local _palette_mod
local _palette_queue = {}
local palette = setmetatable({}, {
  __index = function(_, key)
    if not _palette_mod and (key == "register_command" or key == "register_keymap") then
      return function(...)
        _palette_queue[#_palette_queue + 1] = { fn = key, args = { ... } }
      end
    end
    if not _palette_mod then
      _palette_mod = require("andrew.vault.command_palette")
      for _, call in ipairs(_palette_queue) do
        _palette_mod[call.fn](unpack(call.args))
      end
      _palette_queue = nil
    end
    return _palette_mod[key]
  end,
})
local config = require("andrew.vault.config")
local notify = require("andrew.vault.notify")

local M = {}

--- Open the template picker and run the selected template
function M.new_note()
  local templates = require("andrew.vault.templates")
  local pickers = require("andrew.vault.pickers")
  engine.run(function()
    local all = templates.all()
    local names = {}
    local desc_map = {}
    for _, t in ipairs(all) do
      names[#names + 1] = t.name
      if t.desc then
        desc_map[t.name] = t.desc
      end
    end

    local choice = engine.select(names, {
      prompt = "New vault note",
      format_item = function(item)
        if desc_map[item] then
          return item .. "  --  " .. desc_map[item]
        end
        return item
      end,
    })
    if not choice then
      return
    end

    for _, t in ipairs(all) do
      if t.name == choice and not t._separator then
        t.run(engine, pickers)
        return
      end
    end
  end)
end

--- Run a specific template by its name (for direct keybindings)
---@param name string template display name
function M.run_template(name)
  local templates = require("andrew.vault.templates")
  local pickers = require("andrew.vault.pickers")
  local all = templates.all()
  for _, t in ipairs(all) do
    if t.name == name and not t._separator then
      engine.run(function()
        t.run(engine, pickers)
      end)
      return
    end
  end
  notify.warn("unknown template '" .. name .. "'")
end

-- =============================================================================
-- Commands
-- =============================================================================

vim.api.nvim_create_user_command("VaultNew", function()
  M.new_note()
end, { desc = "Create a new vault note from template" })

vim.api.nvim_create_user_command("VaultDaily", function()
  M.run_template("Daily Log")
end, { desc = "Create today's daily log" })

-- =============================================================================
-- Keybindings
-- =============================================================================

local keymap = vim.keymap.set
local opts = function(desc)
  return { desc = desc, silent = true }
end

-- Template group: <leader>vt
keymap("n", "<leader>vtn", function()
  M.new_note()
end, opts("Template: picker"))
keymap("n", "<leader>vtd", function()
  M.run_template("Daily Log")
end, opts("Template: daily log"))
keymap("n", "<leader>vtw", function()
  M.run_template("Weekly Review")
end, opts("Template: weekly review"))
keymap("n", "<leader>vts", function()
  M.run_template("Simulation Note")
end, opts("Template: simulation"))
keymap("n", "<leader>vta", function()
  M.run_template("Analysis Note")
end, opts("Template: analysis"))
keymap("n", "<leader>vtk", function()
  M.run_template("Task Note")
end, opts("Template: task"))
keymap("n", "<leader>vtm", function()
  M.run_template("Meeting Note")
end, opts("Template: meeting"))
keymap("n", "<leader>vtf", function()
  M.run_template("Finding Note")
end, opts("Template: finding"))
keymap("n", "<leader>vtl", function()
  M.run_template("Literature Note")
end, opts("Template: literature"))
keymap("n", "<leader>vtp", function()
  M.run_template("Project Dashboard")
end, opts("Template: project"))
keymap("n", "<leader>vtj", function()
  M.run_template("Journal Entry")
end, opts("Template: journal"))
keymap("n", "<leader>vtc", function()
  M.run_template("Concept Note")
end, opts("Template: concept"))
keymap("n", "<leader>vtM", function()
  M.run_template("Monthly Review")
end, opts("Template: monthly review"))
keymap("n", "<leader>vtQ", function()
  M.run_template("Quarterly Review")
end, opts("Template: quarterly review"))
keymap("n", "<leader>vtY", function()
  M.run_template("Yearly Review")
end, opts("Template: yearly review"))

-- ---------------------------------------------------------------------------
-- Palette registrations: Templates
-- ---------------------------------------------------------------------------
palette.register_command("VaultNew", "Create a new vault note from template", "Templates", M.new_note, "<leader>vtn")
palette.register_command("VaultDaily", "Create today's daily log", "Templates", function() M.run_template("Daily Log") end, "<leader>vtd")
palette.register_keymap("<leader>vtw", "Template: weekly review", "Templates", function() M.run_template("Weekly Review") end)
palette.register_keymap("<leader>vts", "Template: simulation", "Templates", function() M.run_template("Simulation Note") end)
palette.register_keymap("<leader>vta", "Template: analysis", "Templates", function() M.run_template("Analysis Note") end)
palette.register_keymap("<leader>vtk", "Template: task", "Templates", function() M.run_template("Task Note") end)
palette.register_keymap("<leader>vtm", "Template: meeting", "Templates", function() M.run_template("Meeting Note") end)
palette.register_keymap("<leader>vtf", "Template: finding", "Templates", function() M.run_template("Finding Note") end)
palette.register_keymap("<leader>vtl", "Template: literature", "Templates", function() M.run_template("Literature Note") end)
palette.register_keymap("<leader>vtp", "Template: project", "Templates", function() M.run_template("Project Dashboard") end)
palette.register_keymap("<leader>vtj", "Template: journal", "Templates", function() M.run_template("Journal Entry") end)
palette.register_keymap("<leader>vtc", "Template: concept", "Templates", function() M.run_template("Concept Note") end)
palette.register_keymap("<leader>vtM", "Template: monthly review", "Templates", function() M.run_template("Monthly Review") end)
palette.register_keymap("<leader>vtQ", "Template: quarterly review", "Templates", function() M.run_template("Quarterly Review") end)
palette.register_keymap("<leader>vtY", "Template: yearly review", "Templates", function() M.run_template("Yearly Review") end)

-- ===========================================================================
-- Lazy query access (loaded on first use)
-- ===========================================================================
setmetatable(M, {
  __index = function(self, key)
    if key == "query" then
      self.query = require("andrew.vault.query")
      return self.query
    end
  end,
})

-- ===========================================================================
-- Deferred setup: all vault modules load on first markdown buffer
-- ===========================================================================
-- Reduces startup from ~40 synchronous require+setup calls to ~5 core
-- requires (engine, config, notify, cleanup, palette).  Modules load when
-- the first markdown FileType event fires, with autocmd re-triggers so
-- they catch the initial buffer.

vim.api.nvim_create_autocmd("FileType", {
  pattern = "markdown",
  once = true,
  callback = function(ev)
    -- Highlight infrastructure (must load before highlight modules)
    require("andrew.vault.colors").setup()
    require("andrew.vault.highlight_coordinator").setup()

    -- Core navigation & editing
    require("andrew.vault.wikilinks").setup()
    require("andrew.vault.backlinks").setup()
    require("andrew.vault.navigate").setup()
    require("andrew.vault.search").setup()
    require("andrew.vault.tags").setup()
    require("andrew.vault.frontmatter").setup()
    -- footnotes moved to Tier 3 (lazy commands)

    -- Highlight modules (depend on coordinator)
    require("andrew.vault.wikilink_highlights").setup()
    require("andrew.vault.tag_highlights").setup()
    require("andrew.vault.inline_fields").setup()
    require("andrew.vault.highlights").setup()

    -- Persistent autocmd features (BufReadPost, BufWritePre, BufEnter, etc.)
    require("andrew.vault.frecency").setup()
    require("andrew.vault.pickers").setup()
    require("andrew.vault.embed").setup()
    require("andrew.vault.autolink").setup()
    require("andrew.vault.blockid").setup()
    require("andrew.vault.callout_folds").setup()
    require("andrew.vault.autosave").setup()
    require("andrew.vault.linkdiag").setup()
    require("andrew.vault.breadcrumbs").setup()
    require("andrew.vault.autofile").setup()
    require("andrew.vault.task_hierarchy").setup()
    require("andrew.vault.task_notify").setup()
    -- calendar moved to Tier 3 (lazy commands, loaded via navigate.lua)

    -- Editing features
    require("andrew.vault.outline").setup()
    -- linkcheck, extract, rename moved to Tier 3 (lazy commands)
    require("andrew.vault.recent").setup()
    require("andrew.vault.preview").setup()
    require("andrew.vault.images").setup()
    -- pins moved to Tier 3 (lazy commands)
    require("andrew.vault.capture").setup()
    require("andrew.vault.quicktask").setup()
    -- export, graph, connections, frontmatter_editor, unlinked moved to Tier 3 (lazy commands)

    -- Consolidated event dispatcher (after all modules with BufEnter/TextChanged are loaded)
    require("andrew.vault.event_dispatch").setup()

    -- Prioritized work scheduler (after event_dispatch so IDLE autocmd fires after dispatches)
    require("andrew.vault.work_scheduler").setup()

    -- Request coalescer (deduplicates concurrent identical operations)
    require("andrew.vault.request_coalescer").configure(config.coalescer)

    -- Command palette (after all keymaps/commands are registered)
    -- Accessing palette.setup triggers the lazy proxy to require + replay queued registrations
    palette.setup()

    -- Re-trigger autocmds so modules catch the first markdown buffer
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(ev.buf) then
        vim.api.nvim_exec_autocmds("FileType", { buffer = ev.buf, modeline = false })
        vim.api.nvim_exec_autocmds("BufReadPost", { buffer = ev.buf, modeline = false })
      end
    end)
  end,
})

-- ===========================================================================
-- Tier 3: On-demand — lazy command/keymap stubs for infrequent features
-- ===========================================================================

local function lazy_mod(mod_path)
  local mod, loaded
  return function()
    if not loaded then
      loaded = true
      mod = require(mod_path)
      if mod.setup then mod.setup() end
    end
    return mod
  end
end

-- Stats
local _stats = lazy_mod("andrew.vault.stats")
vim.api.nvim_create_user_command("VaultStats", function()
  _stats().show()
end, { desc = "Show vault statistics dashboard" })
keymap("n", "<leader>vD", function() _stats().show() end, opts("Vault: statistics dashboard"))

-- Sidebar
local _sidebar = lazy_mod("andrew.vault.sidebar")
vim.api.nvim_create_user_command("VaultSidebar", function(a)
  local sb = _sidebar()
  if a.args == "" then sb.toggle() else sb.open(a.args) end
end, { nargs = "?", desc = "Toggle persistent sidebar" })
vim.api.nvim_create_user_command("VaultSidebarFocus", function()
  _sidebar().focus_toggle()
end, { desc = "Toggle sidebar focus" })
vim.api.nvim_create_user_command("VaultSidebarBacklinks", function()
  _sidebar().open("backlinks")
end, { desc = "Open sidebar backlinks panel" })
vim.api.nvim_create_user_command("VaultSidebarTags", function()
  _sidebar().open("tags")
end, { desc = "Open sidebar tags panel" })
vim.api.nvim_create_user_command("VaultSidebarMeta", function()
  _sidebar().open("meta")
end, { desc = "Open sidebar meta panel" })
keymap("n", "<leader>vS", function() _sidebar().toggle() end, opts("Vault: toggle sidebar"))
keymap("n", "<leader>vSf", function() _sidebar().focus_toggle() end, opts("Vault: sidebar focus"))
keymap("n", "<leader>vSb", function() _sidebar().open("backlinks") end, opts("Vault: sidebar backlinks"))
keymap("n", "<leader>vSt", function() _sidebar().open("tags") end, opts("Vault: sidebar tags"))
keymap("n", "<leader>vSm", function() _sidebar().open("meta") end, opts("Vault: sidebar meta"))

-- Saved searches
local _saved = lazy_mod("andrew.vault.saved_searches")
vim.api.nvim_create_user_command("VaultSearchSave", function(a)
  local sv = _saved()
  if a.args and a.args ~= "" then sv.save(a.args) else sv.save_last() end
end, { nargs = "?", desc = "Save last vault search" })
vim.api.nvim_create_user_command("VaultSearchList", function()
  _saved().list()
end, { desc = "Pick and execute a saved vault search" })
vim.api.nvim_create_user_command("VaultSearchDelete", function()
  _saved().pick_delete()
end, { desc = "Pick and delete a saved vault search" })
keymap("n", "<leader>vfS", function() _saved().list() end, opts("Find: saved searches"))

-- Tasks
local _tasks = lazy_mod("andrew.vault.tasks")
vim.api.nvim_create_user_command("VaultTasks", function()
  _tasks().tasks()
end, { desc = "List vault tasks" })
vim.api.nvim_create_user_command("VaultTasksAll", function()
  _tasks().tasks_all()
end, { desc = "List all vault tasks" })
vim.api.nvim_create_user_command("VaultTasksByState", function(a)
  local mark = a.args
  if mark == "" then mark = " " end
  _tasks().tasks_by_state(mark)
end, { nargs = "?", desc = "Show tasks with specific checkbox state" })
vim.api.nvim_create_user_command("VaultTaskToggle", function(a)
  _tasks().cycle_task(a.bang and "backward" or "forward")
end, { bang = true, desc = "Cycle task checkbox state (! = reverse)" })
keymap("n", "<leader>vxo", function() _tasks().tasks() end, opts("Tasks: open tasks"))
keymap("n", "<leader>vxa", function() _tasks().tasks_all() end, opts("Tasks: all tasks"))
keymap("n", "<leader>vxs", function() _tasks().tasks_by_state() end, opts("Tasks: by state"))
keymap("n", "<leader>vxt", function() _tasks().cycle_task("forward") end, opts("Tasks: toggle forward"))
keymap("n", "<leader>vxT", function() _tasks().cycle_task("backward") end, opts("Tasks: toggle backward"))

-- Task Kanban
local _kanban = lazy_mod("andrew.vault.task_kanban")
vim.api.nvim_create_user_command("VaultKanban", function()
  _kanban().kanban()
end, { desc = "Open vault task Kanban board" })
keymap("n", "<leader>vxk", function() _kanban().kanban() end, opts("Vault: Kanban board"))

-- Task Timeline
local _timeline = lazy_mod("andrew.vault.task_timeline")
vim.api.nvim_create_user_command("VaultTimeline", function()
  _timeline().timeline()
end, { desc = "Open task timeline view" })
keymap("n", "<leader>vxl", function() _timeline().timeline() end, opts("Vault: Task timeline"))

-- User templates
local _utpl = lazy_mod("andrew.vault.user_templates")
vim.api.nvim_create_user_command("VaultTemplateReload", function()
  _utpl().reload()
end, { desc = "Reload user templates" })
vim.api.nvim_create_user_command("VaultTemplateEdit", function(a)
  _utpl() -- setup creates real command
  vim.cmd("VaultTemplateEdit " .. (a.args or ""))
end, { nargs = "?", desc = "Edit a user template" })
vim.api.nvim_create_user_command("VaultTemplateList", function()
  _utpl() -- setup creates real command
  vim.cmd("VaultTemplateList")
end, { desc = "List user templates" })

-- Linkcheck
local _linkcheck = lazy_mod("andrew.vault.linkcheck")
vim.api.nvim_create_user_command("VaultLinkCheck", function()
  _linkcheck().check_buffer()
end, { desc = "Check current buffer for broken wikilinks" })
vim.api.nvim_create_user_command("VaultLinkCheckAll", function()
  _linkcheck().check_vault()
end, { desc = "Check entire vault for broken wikilinks" })
vim.api.nvim_create_user_command("VaultOrphans", function()
  _linkcheck().check_orphans()
end, { desc = "Find orphan notes with no inbound links" })
vim.api.nvim_create_user_command("VaultURLCheck", function()
  _linkcheck().check_urls_buffer()
end, { desc = "Check external URLs in current buffer" })
vim.api.nvim_create_user_command("VaultURLCheckAll", function()
  _linkcheck().check_urls_vault()
end, { desc = "Check external URLs across entire vault" })
keymap("n", "<leader>vcb", function() _linkcheck().check_buffer() end, opts("Check: links (buffer)"))
keymap("n", "<leader>vca", function() _linkcheck().check_vault() end, opts("Check: links (vault)"))
keymap("n", "<leader>vco", function() _linkcheck().check_orphans() end, opts("Check: orphans"))
keymap("n", "<leader>vcu", function() _linkcheck().check_urls_buffer() end, opts("Check: URLs (buffer)"))
keymap("n", "<leader>vcU", function() _linkcheck().check_urls_vault() end, opts("Check: URLs (vault)"))
palette.register_command("VaultLinkCheck", "Check current buffer for broken wikilinks", "Links", function() _linkcheck().check_buffer() end, "<leader>vcb")
palette.register_command("VaultLinkCheckAll", "Check entire vault for broken wikilinks", "Links", function() _linkcheck().check_vault() end, "<leader>vca")
palette.register_command("VaultOrphans", "Find orphan notes with no inbound links", "Links", function() _linkcheck().check_orphans() end, "<leader>vco")
palette.register_command("VaultURLCheck", "Check external URLs in current buffer", "Links", function() _linkcheck().check_urls_buffer() end, "<leader>vcu")
palette.register_command("VaultURLCheckAll", "Check external URLs across entire vault", "Links", function() _linkcheck().check_urls_vault() end, "<leader>vcU")

-- Extract
local _extract = lazy_mod("andrew.vault.extract")
vim.api.nvim_create_user_command("VaultExtract", function()
  _extract().extract()
end, { desc = "Extract selection to new vault note", range = true })
keymap("v", "<leader>vex", function()
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.api.nvim_feedkeys(esc, "nx", false)
  vim.schedule(function() _extract().extract() end)
end, opts("Edit: extract to note"))
palette.register_command("VaultExtract", "Extract selection to new vault note", "Edit", function() _extract().extract() end)
palette.register_keymap("<leader>vex", "Edit: extract to note", "Edit", function() _extract().extract() end, true)

-- Rename
local _rename = lazy_mod("andrew.vault.rename")
vim.api.nvim_create_user_command("VaultRename", function(a)
  local arg = a.args and a.args ~= "" and a.args or nil
  _rename().rename(arg)
end, { nargs = "?", desc = "Rename current note and update all wikilinks (with confirmation)" })
vim.api.nvim_create_user_command("VaultRenamePreview", function(a)
  local arg = a.args and a.args ~= "" and a.args or nil
  _rename().rename_preview(arg)
end, { nargs = "?", desc = "Preview rename: show all wikilink changes in the quickfix list" })
vim.api.nvim_create_user_command("VaultTagRename", function(a)
  local args = vim.split(a.args or "", "%s+", { trimempty = true })
  _rename().tag_rename(args[1], args[2])
end, { nargs = "*", desc = "Rename a tag across the vault" })
keymap("n", "<leader>ver", function() _rename().rename() end, opts("Edit: rename note"))
keymap("n", "<leader>veR", function() _rename().rename_preview() end, opts("Edit: preview rename (dry-run)"))
keymap("n", "<leader>vet", function() _rename().tag_rename() end, opts("Edit: rename tag"))
palette.register_command("VaultRename", "Rename current note and update all wikilinks (with confirmation)", "Edit", function() _rename().rename() end, "<leader>ver")
palette.register_command("VaultRenamePreview", "Preview rename: show all wikilink changes in the quickfix list", "Edit", function() _rename().rename_preview() end, "<leader>veR")
palette.register_command("VaultTagRename", "Rename a tag across the vault", "Tags", function() _rename().tag_rename() end, "<leader>vet")

-- Pins
local _pins = lazy_mod("andrew.vault.pins")
vim.api.nvim_create_user_command("VaultPin", function()
  _pins().pin()
end, { desc = "Pin current vault note" })
vim.api.nvim_create_user_command("VaultUnpin", function()
  _pins().unpin()
end, { desc = "Unpin current vault note" })
vim.api.nvim_create_user_command("VaultPins", function()
  _pins().list()
end, { desc = "List pinned vault notes" })
keymap("n", "<leader>vbp", function() _pins().toggle_pin() end, opts("Vault: toggle pin"))
keymap("n", "<leader>vbf", function() _pins().list() end, opts("Vault: find pinned notes"))
palette.register_command("VaultPin", "Pin current vault note", "Meta", function() _pins().pin() end)
palette.register_command("VaultUnpin", "Unpin current vault note", "Meta", function() _pins().unpin() end)
palette.register_command("VaultPins", "List pinned vault notes", "Meta", function() _pins().list() end, "<leader>vbf")
palette.register_keymap("<leader>vbp", "Vault: toggle pin", "Meta", function() _pins().toggle_pin() end)

-- Fragments
local _fragments = lazy_mod("andrew.vault.fragments")
vim.api.nvim_create_user_command("VaultInsertFragment", function()
  _fragments().insert_fragment()
end, { desc = "Insert a template fragment at cursor" })
keymap("n", "<leader>vI", function() _fragments().insert_fragment() end, opts("Vault: insert fragment"))
palette.register_command("VaultInsertFragment", "Insert a template fragment at cursor", "Edit", function() _fragments().insert_fragment() end, "<leader>vI")

-- Metaedit
local _metaedit = lazy_mod("andrew.vault.metaedit")
vim.api.nvim_create_user_command("VaultMetaEdit", function(a)
  local args = vim.split(vim.trim(a.args), "%s+", { trimempty = true })
  if #args < 2 then
    notify.info("usage: VaultMetaEdit [field] [value]")
    return
  end
  _metaedit() -- ensure loaded
  vim.cmd("VaultMetaEdit " .. a.args)
end, { nargs = "+", desc = "Set a frontmatter field to a value" })
vim.api.nvim_create_user_command("VaultMetaCycle", function(a)
  _metaedit() -- ensure loaded
  vim.cmd("VaultMetaCycle " .. a.args)
end, { nargs = 1, desc = "Cycle a frontmatter field through its known values" })
vim.api.nvim_create_user_command("VaultMetaToggle", function(a)
  _metaedit() -- ensure loaded
  vim.cmd("VaultMetaToggle " .. a.args)
end, { nargs = 1, desc = "Toggle a boolean frontmatter field" })
keymap("n", "<leader>vms", function() _metaedit().cycle_field("status", config.status_values) end, opts("Meta: cycle status"))
keymap("n", "<leader>vmp", function() _metaedit().cycle_field("priority", config.priority_values) end, opts("Meta: cycle priority"))
keymap("n", "<leader>vmm", function() _metaedit().cycle_field("maturity", config.maturity_values) end, opts("Meta: cycle maturity"))
keymap("n", "<leader>vmt", function() _metaedit().toggle_field("draft") end, opts("Meta: toggle draft"))
keymap("n", "<leader>vmf", function()
  _metaedit() -- ensure loaded
  engine.run(function()
    local field = engine.input({ prompt = "Field name: " })
    if not field or field == "" then return end
    local value = engine.input({ prompt = field .. " = " })
    if not value then return end
    _metaedit().set_field(field, require("andrew.vault.frontmatter_parser").parse_value(value))
  end)
end, opts("Meta: set any field"))
palette.register_command("VaultMetaEdit", "Set a frontmatter field to a value", "Meta", function()
  vim.ui.input({ prompt = "VaultMetaEdit [field] [value]: " }, function(input)
    if not input or input == "" then return end
    _metaedit() -- ensure loaded
    vim.cmd("VaultMetaEdit " .. input)
  end)
end)
palette.register_command("VaultMetaCycle", "Cycle a frontmatter field through its known values", "Meta", function()
  vim.ui.input({ prompt = "VaultMetaCycle [field]: " }, function(input)
    if not input or input == "" then return end
    _metaedit() -- ensure loaded
    vim.cmd("VaultMetaCycle " .. input)
  end)
end)
palette.register_command("VaultMetaToggle", "Toggle a boolean frontmatter field", "Meta", function()
  vim.ui.input({ prompt = "VaultMetaToggle [field]: " }, function(input)
    if not input or input == "" then return end
    _metaedit() -- ensure loaded
    vim.cmd("VaultMetaToggle " .. input)
  end)
end)
palette.register_keymap("<leader>vms", "Meta: cycle status", "Meta", function() _metaedit().cycle_field("status", config.status_values) end, true)
palette.register_keymap("<leader>vmp", "Meta: cycle priority", "Meta", function() _metaedit().cycle_field("priority", config.priority_values) end, true)
palette.register_keymap("<leader>vmm", "Meta: cycle maturity", "Meta", function() _metaedit().cycle_field("maturity", config.maturity_values) end, true)
palette.register_keymap("<leader>vmt", "Meta: toggle draft", "Meta", function() _metaedit().toggle_field("draft") end, true)
palette.register_keymap("<leader>vmf", "Meta: set any field", "Meta", function()
  _metaedit() -- ensure loaded
  engine.run(function()
    local field = engine.input({ prompt = "Field name: " })
    if not field or field == "" then return end
    local value = engine.input({ prompt = field .. " = " })
    if not value then return end
    _metaedit().set_field(field, require("andrew.vault.frontmatter_parser").parse_value(value))
  end)
end, true)

-- Link Repair
local _link_repair = lazy_mod("andrew.vault.link_repair")
vim.api.nvim_create_user_command("VaultLinkRepair", function(a)
  _link_repair().repair_buffer({ auto_fix_all = a.bang })
end, { bang = true, desc = "Repair broken links in current buffer" })
vim.api.nvim_create_user_command("VaultLinkRepairAll", function(a)
  _link_repair().repair_vault({ auto_fix_all = a.bang })
end, { bang = true, desc = "Repair broken links across vault" })
keymap("n", "<leader>vcr", function() _link_repair().repair_buffer() end, opts("Check: repair broken links (buffer)"))
keymap("n", "<leader>vcR", function() _link_repair().repair_vault() end, opts("Check: repair broken links (vault)"))
palette.register_command("VaultLinkRepair", "Repair broken links in current buffer", "Links", function() _link_repair().repair_buffer() end, "<leader>vcr")
palette.register_command("VaultLinkRepairAll", "Repair broken links across vault", "Links", function() _link_repair().repair_vault() end, "<leader>vcR")

-- Export
local _export = lazy_mod("andrew.vault.export")
vim.api.nvim_create_user_command("VaultExport", function(a)
  _export().export(a.args ~= "" and a.args or nil)
end, { nargs = "?", desc = "Export current note via pandoc" })
keymap("n", "<leader>vep", function() _export().export() end, opts("Edit: export (pandoc)"))
palette.register_command("VaultExport", "Export current note via pandoc", "Export", function() _export().export() end, "<leader>vep")

-- Graph
local _graph = lazy_mod("andrew.vault.graph")
vim.api.nvim_create_user_command("VaultGraph", function()
  _graph().local_graph()
end, { desc = "Vault: local graph view" })
keymap("n", "<leader>vG", function() _graph().local_graph() end, opts("Vault: local graph"))
palette.register_command("VaultGraph", "Vault: local graph view", "Graph", function() _graph().local_graph() end, "<leader>vG")

-- Connections
local _connections = lazy_mod("andrew.vault.connections")
vim.api.nvim_create_user_command("VaultRelated", function()
  _connections().related_notes()
end, { desc = "Show related notes for current note" })
vim.api.nvim_create_user_command("VaultConnectionsRefresh", function()
  _connections().invalidate_cache()
  notify.info("connections cache cleared")
end, { desc = "Clear connection score cache" })
vim.api.nvim_create_user_command("VaultConnectionDebug", function(a)
  _connections().debug_pair(a.args)
end, { nargs = "?", desc = "Debug connection score between current note and target" })
keymap("n", "<leader>vr", function() _connections().related_notes() end, opts("Vault: related notes"))
palette.register_command("VaultRelated", "Show related notes for current note", "Graph", function() _connections().related_notes() end, "<leader>vr")
palette.register_command("VaultConnectionsRefresh", "Clear connection score cache", "Graph", function() _connections().invalidate_cache() end)
palette.register_command("VaultConnectionDebug", "Debug connection score", "Graph", function() vim.cmd("VaultConnectionDebug") end)

-- Frontmatter Editor
local _fmeditor = lazy_mod("andrew.vault.frontmatter_editor")
vim.api.nvim_create_user_command("VaultFrontmatterEdit", function()
  _fmeditor().open()
end, { desc = "Open frontmatter editor for current note" })
keymap("n", "<leader>vM", function() _fmeditor().open() end, opts("Vault: frontmatter editor"))
palette.register_command("VaultFrontmatterEdit", "Open frontmatter editor", "Meta", function() _fmeditor().open() end, "<leader>vM")

-- Unlinked
local _unlinked = lazy_mod("andrew.vault.unlinked")
vim.api.nvim_create_user_command("VaultUnlinked", function()
  _unlinked().unlinked_mentions()
end, { desc = "Show unlinked mentions for current note" })
vim.api.nvim_create_user_command("VaultUnlinkedAll", function()
  _unlinked().vault_unlinked_mentions()
end, { desc = "Show all unlinked mentions across vault" })
vim.api.nvim_create_user_command("VaultAutoLink", function()
  _unlinked().autolink_buffer()
end, { desc = "Auto-link unlinked mentions in current buffer" })
vim.api.nvim_create_user_command("VaultAutoLinkAll", function()
  _unlinked().autolink_vault()
end, { desc = "Auto-link unlinked mentions across vault" })
keymap("n", "<leader>vfu", function() _unlinked().unlinked_mentions() end, opts("Find: unlinked mentions"))
keymap("n", "<leader>vfU", function() _unlinked().vault_unlinked_mentions() end, opts("Find: unlinked mentions (vault)"))
keymap("n", "<leader>vaB", function() _unlinked().autolink_buffer() end, opts("Auto-link: buffer"))
keymap("n", "<leader>vaV", function() _unlinked().autolink_vault() end, opts("Auto-link: vault"))
palette.register_command("VaultUnlinked", "Show unlinked mentions for current note", "Links", function() _unlinked().unlinked_mentions() end, "<leader>vfu")
palette.register_command("VaultUnlinkedAll", "Show all unlinked mentions across vault", "Links", function() _unlinked().vault_unlinked_mentions() end, "<leader>vfU")
palette.register_command("VaultAutoLink", "Auto-link unlinked mentions in buffer", "Links", function() _unlinked().autolink_buffer() end, "<leader>vaB")
palette.register_command("VaultAutoLinkAll", "Auto-link unlinked mentions across vault", "Links", function() _unlinked().autolink_vault() end, "<leader>vaV")

-- Calendar: removed from Tier 2.  Command, keymap, and palette registration
-- live in navigate.lua (uses inline require).  calendar.setup() is self-
-- initializing on first M.calendar() call.

-- Footnotes
local _footnotes = lazy_mod("andrew.vault.footnotes")
vim.api.nvim_create_user_command("VaultFootnoteRender", function()
  _footnotes().render_footnotes()
end, { desc = "Vault: render footnote content inline" })
vim.api.nvim_create_user_command("VaultFootnoteClear", function()
  _footnotes().clear_footnotes()
end, { desc = "Vault: clear footnote virtual text" })
vim.api.nvim_create_user_command("VaultFootnoteToggle", function()
  _footnotes().toggle_footnotes()
end, { desc = "Vault: toggle footnote virtual text" })
vim.api.nvim_create_user_command("VaultFootnoteOrphans", function()
  _footnotes().orphans()
end, { desc = "Vault: find orphaned footnote refs/defs" })
keymap("n", "<leader>mj", function() _footnotes().jump() end, opts("Footnote: jump ref/def"))
keymap("n", "<leader>mn", function() _footnotes().list() end, opts("Footnote: list all"))
palette.register_command("VaultFootnoteRender", "Vault: render footnote content inline", "Embed", function() _footnotes().render_footnotes() end)
palette.register_command("VaultFootnoteClear", "Vault: clear footnote virtual text", "Embed", function() _footnotes().clear_footnotes() end)
palette.register_command("VaultFootnoteToggle", "Vault: toggle footnote virtual text", "Embed", function() _footnotes().toggle_footnotes() end)
palette.register_command("VaultFootnoteOrphans", "Vault: find orphaned footnote refs/defs", "Embed", function() _footnotes().orphans() end)
palette.register_keymap("<leader>mj", "Footnote: jump ref/def", "Embed", function() _footnotes().jump() end, true)
palette.register_keymap("<leader>mn", "Footnote: list all", "Embed", function() _footnotes().list() end, true)

-- Vault switcher
vim.api.nvim_create_user_command("VaultSwitch", function()
  engine.pick_vault()
end, { desc = "Switch active vault" })

keymap("n", "<leader>vV", function()
  engine.pick_vault()
end, opts("Vault: switch vault"))

-- ---------------------------------------------------------------------------
-- Palette registrations: Meta / Index (late-defined commands)
-- ---------------------------------------------------------------------------
palette.register_command("VaultSwitch", "Switch active vault", "Meta", function() engine.pick_vault() end, "<leader>vV")
palette.register_command("VaultCacheInvalidate", "Invalidate vault caches", "Index", function() vim.cmd("VaultCacheInvalidate") end)
palette.register_command("VaultCacheStatus", "Show vault cache health status", "Index", function() vim.cmd("VaultCacheStatus") end)
palette.register_command("VaultIndexRebuild", "Rebuild vault index from scratch", "Index", function() vim.cmd("VaultIndexRebuild") end)
palette.register_command("VaultIndexStatus", "Show vault index status", "Index", function() vim.cmd("VaultIndexStatus") end)
palette.register_command("VaultWatcherStatus", "Show filesystem watcher status", "Index", function() vim.cmd("VaultWatcherStatus") end)
palette.register_command("VaultIndexCollisions", "Show alias/name collisions in vault index", "Index", function() vim.cmd("VaultIndexCollisions") end)
palette.register_command("VaultIndexWaiters", "Show pending scan completion waiters", "Debug", function() vim.cmd("VaultIndexWaiters") end)
palette.register_command("VaultCompletionDebug", "Show completion source cache/build debug info", "Debug", function() vim.cmd("VaultCompletionDebug") end)
palette.register_command("VaultPipelineDebug", "Show pipeline tokenizer/render debug info", "Debug", function() vim.cmd("VaultPipelineDebug") end)
palette.register_command("VaultOpsDebug", "Show operation tracker stats", "Debug", function() vim.cmd("VaultOpsDebug") end)

-- ---------------------------------------------------------------------------
-- Unified Cache Invalidation
-- ---------------------------------------------------------------------------

-- Single consolidated augroup replaces per-module BufWritePost/BufDelete autocmds
local inv_group = vim.api.nvim_create_augroup("VaultCacheInvalidation", { clear = true })

-- File-scoped invalidation on vault markdown saves, external edits, and buffer deletes
vim.api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost", "BufDelete", "BufWipeout" }, {
  group = inv_group,
  pattern = "*.md",
  callback = function(ev)
    local bufpath = vim.api.nvim_buf_get_name(ev.buf)
    if engine.is_vault_buf(ev.buf) then
      engine.invalidate_caches({ scope = "files", paths = { bufpath } })
    end
  end,
})

-- FocusGained: pick up external changes (git pull, Obsidian sync)
local focus_debounce_timer = nil
vim.api.nvim_create_autocmd("FocusGained", {
  group = inv_group,
  callback = function()
    focus_debounce_timer = cleanup.debounce(focus_debounce_timer, 200, function()
      focus_debounce_timer = nil
      -- When the fs watcher is active, it already tracks external changes.
      -- Only invalidate downstream caches (skip the O(N) index rebuild).
      local ws = engine.watcher_status()
      if ws.active then
        engine.invalidate_caches({ scope = "all", skip_index = true })
      else
        engine.invalidate_caches({ scope = "all" })
      end
    end)
  end,
})

-- File content cache registration (done here to avoid circular deps:
-- engine → link_utils → file_cache, so file_cache cannot require engine)
local file_cache = require("andrew.vault.file_cache")
engine.register_cache({
  name = "file_content",
  module = "andrew.vault.file_cache",
  invalidate = function() file_cache.clear() end,
  invalidate_file = function(path) file_cache.invalidate(path) end,
  stats = function()
    local s = file_cache.stats()
    return {
      entries = s.file_size,
      max = s.file_max,
      hits = s.hits,
      misses = s.misses,
      section_entries = s.section_size,
      section_max = s.section_max,
      hit_rate = s.hit_rate,
      total_bytes = s.total_bytes,
      max_bytes = s.max_bytes,
    }
  end,
})

-- Section outlinks cache registration (done here for same reason as file_cache:
-- match_field requires vault_index, so engine cannot require it directly)
local match_field = require("andrew.vault.search_filter.match_field")
engine.register_cache({
  name = "section_outlinks",
  module = "andrew.vault.search_filter.match_field",
  invalidate = function() match_field.clear_section_cache() end,
  stats = function()
    return match_field.section_cache_stats()
  end,
})

-- ---------------------------------------------------------------------------
-- Cache Management Commands
-- ---------------------------------------------------------------------------

vim.api.nvim_create_user_command("VaultCacheInvalidate", function(cmd_opts)
  local module_name = nil
  if cmd_opts.args and cmd_opts.args ~= "" then
    module_name = cmd_opts.args
  end
  engine.invalidate_caches({ scope = "all", module = module_name })
  if module_name then
    notify.info("invalidated cache '" .. module_name .. "'")
  else
    notify.info("invalidated all caches")
  end
end, {
  nargs = "?",
  desc = "Invalidate vault caches (optionally specify a module name)",
  complete = function()
    local names = {}
    for name in pairs(engine._cache_registry) do
      names[#names + 1] = name
    end
    table.sort(names)
    return names
  end,
})

vim.api.nvim_create_user_command("VaultCacheStatus", function()
  local stats = engine.cache_stats()
  local lines = { "Cache Status", string.rep("=", config.ui.status_separator_width) }

  local names = {}
  for name in pairs(stats) do names[#names + 1] = name end
  table.sort(names)

  for _, name in ipairs(names) do
    local s = stats[name]
    local parts = { "  " .. name .. ":" }
    if s.entries then
      parts[#parts + 1] = s.entries .. " entries"
    end
    if s.age_seconds then
      parts[#parts + 1] = string.format("%.1fs old", s.age_seconds)
    end
    if s.ttl then
      parts[#parts + 1] = "TTL=" .. s.ttl .. "s"
    end
    if s.vault then
      parts[#parts + 1] = "vault=" .. link_utils.get_tail(s.vault)
    end
    lines[#lines + 1] = table.concat(parts, "  ")
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Registered caches: " .. vim.tbl_count(engine._cache_registry)

  notify.info_lines(lines)
end, { desc = "Show vault cache health status" })

-- ---------------------------------------------------------------------------
-- Filesystem Watcher
-- ---------------------------------------------------------------------------

-- Real-time detection of external changes while Neovim is in the foreground
-- (covers tmux splits, background sync daemons, etc.)
vim.defer_fn(function()
  engine.start_fs_watcher()
end, 200) -- Start 200ms after init, unblocking startup

-- ---------------------------------------------------------------------------
-- Vault Index Lifecycle
-- ---------------------------------------------------------------------------

local vi = require("andrew.vault.vault_index")

-- Initialize vault index for the current vault
if engine.vault_path and engine.vault_path ~= "" then
  local idx = vi.get(engine.vault_path)
  vim.defer_fn(function()
    idx:load() -- Load persisted index
    idx:build_async() -- Start incremental build
  end, 50) -- Load after initial render
end

-- Persist vault index and clean up init-level resources before exit
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = inv_group,
  callback = function()
    cleanup.close_timer(focus_debounce_timer)
    focus_debounce_timer = nil
    -- Cancel all scheduled work before shutdown (drain IDLE items would be wasteful)
    require("andrew.vault.work_scheduler").teardown()
    engine.stop_fs_watcher()
    local idx = vi.current()
    if idx then
      idx:persist_now()
    end
    -- url_validate.persist_now() handled by engine.teardown() via event_dispatch
    require("andrew.vault.table_pool").clear_all()
  end,
})

vim.api.nvim_create_user_command("VaultIndexRebuild", function()
  local idx = vi.current()
  if idx then
    idx:build_sync()
    notify.info("index rebuilt: " .. idx:file_count() .. " files")
  else
    notify.index_not_ready()
  end
end, { desc = "Rebuild vault index from scratch" })

vim.api.nvim_create_user_command("VaultIndexStatus", function()
  local idx = vi.current()
  if not idx then
    notify.index_not_ready()
    return
  end
  local ws = engine.watcher_status()
  local lines = {
    "Index Status",
    string.rep("=", config.ui.status_separator_width),
    "  Vault: " .. idx.vault_path,
    "  Files: " .. idx:file_count(),
    "  Ready: " .. tostring(idx:is_ready()),
    "  Generation: " .. idx._generation,
    "  Subscribers: " .. idx:subscriber_count(),
    "  Waiters: " .. #idx._waiters,
    "  Watcher: " .. (ws.active and ("active, " .. ws.dirs_watched .. " dirs")
                        or "inactive"),
  }
  -- Tiered invalidation stats
  local inv = idx._inv_stats
  if inv and inv.total > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Invalidation Stats"
    lines[#lines + 1] = string.rep("-", config.ui.status_separator_width)
    lines[#lines + 1] = string.format("  Total notifications: %d", inv.total)
    lines[#lines + 1] = string.format("  FULL:     %d (%.1f%%)", inv.full, inv.full / inv.total * 100)
    lines[#lines + 1] = string.format("  PARTIAL:  %d (%.1f%%)", inv.partial, inv.partial / inv.total * 100)
    lines[#lines + 1] = string.format("  ADDITIVE: %d (%.1f%%)", inv.additive, inv.additive / inv.total * 100)
    lines[#lines + 1] = string.format("  Subscriber skips: %d", inv.subscriber_skips)
    local saved = (inv.partial_cache_hits or 0)
    lines[#lines + 1] = string.format("  Cache rebuilds saved: %d", saved)
  end
  notify.info_lines(lines)
end, { desc = "Show vault index status" })

vim.api.nvim_create_user_command("VaultIndexWaiters", function()
  local idx = vi.current()
  if not idx then
    notify.warn("No active vault index")
    return
  end
  local lines = {
    "Index Waiters",
    string.rep("=", config.ui.status_separator_width),
    string.format("  Generation: %d | Ready: %s", idx._generation, tostring(idx._ready)),
    string.format("  Waiters: %d / %d", #idx._waiters, config.index.max_waiters),
  }
  for i, w in ipairs(idx._waiters) do
    lines[#lines + 1] = string.format(
      "  [%d] id=%d gen=%d %s%s",
      i, w.id, w.generation,
      w.ready_waiter and "(ready) " or "",
      w.description or ""
    )
  end
  if #idx._waiters == 0 then
    lines[#lines + 1] = "  (none)"
  end
  notify.info_lines(lines)
end, { desc = "Show pending scan completion waiters" })

vim.api.nvim_create_user_command("VaultWatcherStatus", function()
  local status = engine.watcher_status()
  local lines = {
    "Filesystem Watcher",
    string.rep("=", config.ui.status_separator_width),
    "  Active: " .. tostring(status.active),
    "  Vault: " .. (status.vault_path or "none"),
    "  Mode: " .. (status.recursive and "recursive (single watch)"
                     or "per-directory (inotify)"),
    "  Directories watched: " .. status.dirs_watched,
    "  Events received: " .. status.events_received,
  }

  if status.started_at then
    local uptime = os.time() - status.started_at
    local h = math.floor(uptime / 3600)
    local m = math.floor((uptime % 3600) / 60)
    lines[#lines + 1] = string.format("  Uptime: %dh %dm", h, m)
  end

  if status.last_event_at then
    local ago = os.time() - status.last_event_at
    lines[#lines + 1] = string.format("  Last event: %ds ago", ago)
    if status.last_event_file then
      local rel = status.last_event_file
      if status.vault_path then
        rel = status.last_event_file:sub(#status.vault_path + 2)
      end
      lines[#lines + 1] = "  Last file: " .. rel
    end
  end

  if status.pending_files > 0 then
    lines[#lines + 1] = "  Pending (in debounce): " .. status.pending_files
  end

  notify.info_lines(lines)
end, { desc = "Show filesystem watcher status" })

vim.api.nvim_create_user_command("VaultIndexCollisions", function()
  local idx = vi.current()
  if not idx then
    notify.index_not_ready()
    return
  end
  idx:show_collisions()
end, { desc = "Show alias/name collisions in vault index" })

vim.api.nvim_create_user_command("VaultIndexChunkDebug", function(a)
  local idx = vi.current()
  if not idx then
    notify.index_not_ready()
    return
  end
  local chunker_mod = require("andrew.vault.vault_index_chunker")
  -- If an argument is provided, show chunk info for that file
  local rel_path = a.args ~= "" and a.args or nil
  if not rel_path then
    -- Use current buffer's file
    local buf_path = vim.api.nvim_buf_get_name(0)
    if buf_path ~= "" and idx.vault_path then
      local prefix = idx.vault_path .. "/"
      if buf_path:sub(1, #prefix) == prefix then
        rel_path = buf_path:sub(#prefix + 1)
      end
    end
  end
  if not rel_path then
    notify.warn("No file specified. Use :VaultIndexChunkDebug <rel_path> or open a vault file")
    return
  end
  local entry = idx.files[rel_path]
  if not entry then
    notify.warn("File not in index: " .. rel_path)
    return
  end
  local lines = {
    "Chunk Debug: " .. rel_path,
    string.rep("=", config.ui.status_separator_width),
    "  Chunking enabled: " .. tostring(config.index.chunking_enabled),
    "  Min chunk lines: " .. config.index.min_chunk_lines,
    "  Fallback threshold: " .. config.index.fallback_threshold,
    "",
  }
  vim.list_extend(lines, chunker_mod.debug_info(entry._chunks))
  notify.info_lines(lines)
end, { nargs = "?", desc = "Show chunk state for a vault file" })

vim.api.nvim_create_user_command("VaultCompletionDebug", function()
  local completion_base = require("andrew.vault.completion_base")
  notify.info_lines(completion_base.debug_info())
end, { desc = "Show completion source cache/build debug info" })

vim.api.nvim_create_user_command("VaultOpsDebug", function()
  local lines = { "Operation Tracker Stats", string.rep("=", config.ui.status_separator_width), "" }
  local trackers = {
    { name = "search", tracker = (function()
      local ok, adv = pcall(require, "andrew.vault.search.advanced")
      return ok and adv._ops or nil
    end)() },
  }
  -- Add per-source completion trackers
  do
    local ok, cb = pcall(require, "andrew.vault.completion_base")
    if ok then
      for name, tracker in pairs(cb.ops_trackers()) do
        trackers[#trackers + 1] = { name = "completion:" .. name, tracker = tracker }
      end
    end
  end
  for _, t in ipairs(trackers) do
    if t.tracker then
      local s = t.tracker:stats()
      lines[#lines + 1] = string.format(
        "  %s: counter=%d  started=%d  completed=%d  discarded=%d",
        t.name, t.tracker:current(), s.started, s.completed, s.discarded
      )
    else
      lines[#lines + 1] = string.format("  %s: not loaded", t.name)
    end
  end
  notify.info_lines(lines)
end, { desc = "Show operation tracker stats" })

vim.api.nvim_create_user_command("VaultPipelineDebug", function()
  local parse_cache = require("andrew.vault.line_parse_cache")
  local render = require("andrew.vault.render_diff")
  local cfg = require("andrew.vault.config")

  local ps = parse_cache._stats
  local rs = render._stats
  local total = ps.total_dirty
  local skip_pct = total > 0 and math.floor(ps.skipped / total * 100) or 0

  local lines = {
    "--- Pipeline Debug ---",
    string.format("Tokenizer mode: %s", parse_cache.tokenizer_mode()),
    string.format("LPEG available: %s", tostring(pcall(require, "lpeg"))),
    string.format("Content dedup: %s", tostring(cfg.pipeline.content_dedup ~= false)),
    string.format("Batch extmarks: %s", tostring(cfg.pipeline.batch_extmarks ~= false)),
    "",
    "--- Content Dedup Stats ---",
    string.format("Total dirty lines: %d", ps.total_dirty),
    string.format("Reparsed: %d", ps.reparsed),
    string.format("Skipped (unchanged): %d (%d%%)", ps.skipped, skip_pct),
    "",
    "--- Render Diff Stats ---",
    string.format("Batched API calls: %d", rs.batched_calls),
    string.format("Individual API calls: %d", rs.individual_calls),
    string.format("Atomic failures (fallback): %d", rs.atomic_failures),
  }

  -- Per-buffer cache info
  local cache_data = parse_cache._get_cache()
  local buf_count = 0
  local total_cached_lines = 0
  for bufnr, buf_cache in pairs(cache_data) do
    buf_count = buf_count + 1
    local line_count = 0
    for _ in pairs(buf_cache.lines) do line_count = line_count + 1 end
    total_cached_lines = total_cached_lines + line_count
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "--- Cache ---"
  lines[#lines + 1] = string.format("Cached buffers: %d", buf_count)
  lines[#lines + 1] = string.format("Total cached lines: %d", total_cached_lines)
  lines[#lines + 1] = string.format("Max lines/buffer: %d", cfg.pipeline.line_cache_max or 10000)

  notify.info_lines(lines)
end, { desc = "Show pipeline tokenizer/render debug info" })

vim.api.nvim_create_user_command("VaultCoalescerStats", function()
  local rc = require("andrew.vault.request_coalescer")
  local all_pools = rc.pools()
  local lines = {
    "Coalescer Stats",
    string.rep("=", config.ui.status_separator_width),
  }
  for name, pool in pairs(all_pools) do
    local s = pool:stats()
    local total_requests = s.total_operations + s.total_coalesced
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("  Pool: %s", name)
    lines[#lines + 1] = string.rep("-", config.ui.status_separator_width)
    lines[#lines + 1] = "    Total operations:  " .. s.total_operations
    lines[#lines + 1] = "    Total coalesced:   " .. s.total_coalesced
    lines[#lines + 1] = "    Total cancelled:   " .. s.total_cancelled
    lines[#lines + 1] = "    Currently in-flight: " .. s.in_flight
    lines[#lines + 1] = string.format("    Coalesce rate:     %.1f%%", s.coalesce_rate)
    lines[#lines + 1] = string.format("    (%d duplicate requests avoided out of %d total requests)",
      s.total_coalesced, total_requests)
  end
  notify.info_lines(lines)
end, { desc = "Show request coalescer statistics (per-pool)" })
palette.register_command("VaultCoalescerStats", "Show request coalescer statistics (per-pool)", "Debug", function() vim.cmd("VaultCoalescerStats") end)

vim.api.nvim_create_user_command("VaultCoalescerDebug", function()
  local rc = require("andrew.vault.request_coalescer")
  local all_pools = rc.pools()
  local lines = { "In-Flight Operations", string.rep("=", config.ui.status_separator_width) }
  local any = false
  for name, pool in pairs(all_pools) do
    local keys = pool:pending_keys()
    if #keys > 0 then
      any = true
      lines[#lines + 1] = ""
      lines[#lines + 1] = string.format("  Pool: %s", name)
      for _, k in ipairs(keys) do
        lines[#lines + 1] = "    " .. k
      end
    end
  end
  if not any then
    lines[#lines + 1] = "  (none)"
  end
  notify.info_lines(lines)
end, { desc = "Show in-flight coalesced operations (per-pool)" })
palette.register_command("VaultCoalescerDebug", "Show in-flight coalesced operations (per-pool)", "Debug", function() vim.cmd("VaultCoalescerDebug") end)

vim.api.nvim_create_user_command("VaultCacheDebug", function()
  local lines = engine.cache_debug()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
end, { desc = "Show detailed LRU cache stats across all vault modules" })
palette.register_command("VaultCacheDebug", "Show detailed LRU cache debug info", "Debug", function() vim.cmd("VaultCacheDebug") end)

require("andrew.vault.memoize").setup_commands()
palette.register_command("VaultMemoDebug", "Show memoized state check statistics", "Debug", function() vim.cmd("VaultMemoDebug") end)

vim.api.nvim_create_user_command("VaultSlotMapDebug", function()
  local sep = string.rep("─", config.ui.status_separator_width)
  local lines_out = { "SlotMap Status", sep }
  local maps = {
    { name = "embed_buf", map = require("andrew.vault.embed_state")._get_slot_map() },
    { name = "img_placement", map = require("andrew.vault.embed_images")._get_slot_map() },
    { name = "highlight", map = require("andrew.vault.highlight_coordinator")._get_slot_map() },
  }
  for _, m in ipairs(maps) do
    local s = m.map:get_stats()
    lines_out[#lines_out + 1] = string.format(
      "%s: live=%d, slots_allocated=%d, free_list=%d",
      m.name, s.entries, s.max, s.free
    )
  end
  for _, m in ipairs(maps) do
    if m.map._leak_detect then
      local leaks = m.map:detect_leaks()
      if #leaks > 0 then
        lines_out[#lines_out + 1] = ""
        lines_out[#lines_out + 1] = string.format("LEAKS in %s: %d entities", m.name, #leaks)
        for _, leak in ipairs(leaks) do
          lines_out[#lines_out + 1] = string.format(
            "  slot=%d gen=%d age=%.1fs",
            leak.slot, leak.generation, leak.age_ms / 1000
          )
        end
      end
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines_out)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
end, { desc = "Show generational slot map status and leak report" })
palette.register_command("VaultSlotMapDebug", "Show slot map entity status and leaks", "Debug", function() vim.cmd("VaultSlotMapDebug") end)

vim.api.nvim_create_user_command("VaultRenderCacheDebug", function()
  local bufnr = vim.api.nvim_get_current_buf()
  local sep = string.rep("─", config.ui.status_separator_width)
  local lines = { "Render Cache Debug (buf " .. bufnr .. ")", sep }

  local function append_stats(name, cache)
    if not cache then
      lines[#lines + 1] = string.format("  %-20s (no cache)", name)
      return
    end
    local s = cache:get_stats()
    local total_lookups = s.hits + s.misses + s.promotions
    local hit_pct = total_lookups > 0
      and ((s.hits + s.promotions) / total_lookups * 100) or 0
    lines[#lines + 1] = string.format("  %s:", name)
    lines[#lines + 1] = string.format("    current=%d  previous=%d  total=%d",
      s.current_entries, s.previous_entries, s.total_entries)
    lines[#lines + 1] = string.format(
      "    hits=%d  promotions=%d  misses=%d  evictions=%d  hit_rate=%.1f%%",
      s.hits, s.promotions, s.misses, s.evictions, hit_pct)
  end

  -- Coordinator cache
  local ok_c, hl_coord = pcall(require, "andrew.vault.highlight_coordinator")
  if ok_c and hl_coord.get_frame_cache then
    append_stats("coordinator", hl_coord.get_frame_cache(bufnr))
  end

  -- Embed cache
  local ok_e, embed = pcall(require, "andrew.vault.embed")
  if ok_e and embed.get_frame_cache then
    append_stats("embed", embed.get_frame_cache(bufnr))
  end

  -- Task hierarchy cache
  local ok_t, tasks = pcall(require, "andrew.vault.task_hierarchy")
  if ok_t and tasks.get_frame_cache then
    append_stats("task_hierarchy", tasks.get_frame_cache(bufnr))
  end

  lines[#lines + 1] = sep
  lines[#lines + 1] = "enabled=" .. tostring(config.render_cache.enabled)
    .. "  max_entries=" .. tostring(config.render_cache.max_entries_per_frame or "unlimited")
  notify.info_lines(lines)
end, { desc = "Show dual-frame render cache statistics for current buffer" })
palette.register_command("VaultRenderCacheDebug", "Show render cache stats", "Debug", function() vim.cmd("VaultRenderCacheDebug") end)

vim.api.nvim_create_user_command("VaultSchedulerDebug", function()
  local scheduler = require("andrew.vault.work_scheduler")
  local s = scheduler.stats()
  local lines = {
    "Work Scheduler Stats",
    string.rep("=", config.ui.status_separator_width),
    string.format("  Enqueued:  %d", s.enqueued),
    string.format("  Executed:  %d", s.executed),
    string.format("  Cancelled: %d", s.cancelled),
    string.format("  Pending:   %d (normal=%d, deferred=%d, idle=%d)",
      s.pending, s.pending_normal, s.pending_deferred, s.pending_idle),
    "",
    "  By priority:",
    string.format("    CRITICAL: %d", s.by_priority[1]),
    string.format("    NORMAL:   %d", s.by_priority[2]),
    string.format("    DEFERRED: %d", s.by_priority[3]),
    string.format("    IDLE:     %d", s.by_priority[4]),
  }
  notify.info_lines(lines)
end, { desc = "Show work scheduler statistics" })
palette.register_command("VaultSchedulerDebug", "Show work scheduler statistics", "Debug", function() vim.cmd("VaultSchedulerDebug") end)

vim.api.nvim_create_user_command("VaultPoolStats", function()
  local table_pool = require("andrew.vault.table_pool")
  local all = table_pool.all_stats()
  local lines = { "Pool Stats", string.rep("=", config.ui.status_separator_width) }
  local names = {}
  for name in pairs(all) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local s = all[name]
    lines[#lines + 1] = string.format(
      "  %-20s %d max, %d pooled, hit_rate=%.1f%%, %d overflows",
      name .. ":", s.max_size, s.size, s.hit_rate, s.overflows
    )
  end
  notify.info_lines(lines)
end, { desc = "Show table object pool statistics" })
palette.register_command("VaultPoolStats", "Show table object pool statistics", "Debug", function() vim.cmd("VaultPoolStats") end)

vim.api.nvim_create_user_command("VaultArenaStats", function()
  local render_arena = require("andrew.vault.render_arena")
  local s = render_arena.stats()
  local total_allocs = s.pool_hits + s.pool_misses
  local hit_pct = total_allocs > 0 and (s.pool_hits / total_allocs * 100) or 0
  local lines = { "Arena Pool Stats", string.rep("=", config.ui.status_separator_width) }
  lines[#lines + 1] = string.format("  Pool size:          %d / %d max", s.pool_size, s.max_pool_size)
  lines[#lines + 1] = string.format("  Total scopes:       %d", s.total_scopes)
  lines[#lines + 1] = string.format("  Active scopes:      %d", s.active_scopes)
  lines[#lines + 1] = string.format("  Peak scope size:    %d tables", s.peak_scope_size)
  lines[#lines + 1] = string.format("  Pool hits:          %d (%.1f%%)", s.pool_hits, hit_pct)
  lines[#lines + 1] = string.format("  Pool misses:        %d (%.1f%%)", s.pool_misses, 100 - hit_pct)
  lines[#lines + 1] = string.format("  Tables cleared:     %d", s.tables_cleared)
  lines[#lines + 1] = string.format("  Overflow discards:  %d", s.overflow_discards)
  notify.info_lines(lines)
end, { desc = "Show render arena allocation statistics" })
palette.register_command("VaultArenaStats", "Show render arena allocation statistics", "Debug", function() vim.cmd("VaultArenaStats") end)

vim.api.nvim_create_user_command("VaultSharingStats", function()
  local ss = require("andrew.vault.structural_sharing")
  local vi = require("andrew.vault.vault_index")
  local idx = vi.current()
  local lines = { "Structural Sharing Stats", string.rep("=", config.ui.status_separator_width) }
  lines[#lines + 1] = string.format("  Enabled:            %s", config.sharing.enable and "yes" or "no")
  lines[#lines + 1] = string.format("  Debug immutability: %s", config.sharing.debug_immutability and "yes" or "no")

  -- Phase 1: Sub-table reuse stats
  local stats = ss.share_stats()
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  Sub-Table Sharing (Phase 1):"
  lines[#lines + 1] = string.format("    share_unchanged() calls: %d", stats.calls)
  if stats.calls > 0 then
    local fields = { "tags", "aliases", "frontmatter", "inline_fields",
                     "headings", "block_ids", "outlinks", "tasks" }
    for _, f in ipairs(fields) do
      local reused = stats.reused[f] or 0
      local changed = stats.changed[f] or 0
      local total = reused + changed
      local pct = total > 0 and (reused / total * 100) or 0
      lines[#lines + 1] = string.format("    %-16s %4d reused / %4d total (%.0f%%)", f .. ":", reused, total, pct)
    end
  end

  -- Phase 2: Tag interning stats
  if idx and idx._tag_intern then
    local ts = ss.intern_store_stats(idx._tag_intern)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Tag Intern Store (Phase 2):"
    lines[#lines + 1] = string.format("    Unique arrays:    %d", ts.size)
    lines[#lines + 1] = string.format("    Hits:             %d", ts.hits)
    lines[#lines + 1] = string.format("    Misses:           %d", ts.misses)
    lines[#lines + 1] = string.format("    Hit rate:         %.1f%%", ts.hit_rate * 100)
  else
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Tag intern store: not initialized"
  end
  notify.info_lines(lines)
end, { desc = "Show structural sharing statistics" })
palette.register_command("VaultSharingStats", "Show structural sharing statistics", "Debug", function() vim.cmd("VaultSharingStats") end)

-- Memory profiler commands
vim.api.nvim_create_user_command("VaultMemoryProfile", function()
  local profiler = require("andrew.vault.memory_profiler")
  profiler.open_dashboard()
end, { desc = "Open memory profiler dashboard (R to refresh, q to close)" })
palette.register_command("VaultMemoryProfile", "Open memory profiler dashboard", "Debug", function() vim.cmd("VaultMemoryProfile") end)

vim.api.nvim_create_user_command("VaultMemorySnapshot", function()
  local profiler = require("andrew.vault.memory_profiler")
  profiler.snapshot()
  notify.info("Memory snapshot saved")
end, { desc = "Save current profiler state to snapshot stack" })
palette.register_command("VaultMemorySnapshot", "Save memory profiler snapshot", "Debug", function() vim.cmd("VaultMemorySnapshot") end)

vim.api.nvim_create_user_command("VaultMemoryDiff", function()
  local profiler = require("andrew.vault.memory_profiler")
  profiler.open_diff()
end, { desc = "Compare current state vs last memory snapshot" })
palette.register_command("VaultMemoryDiff", "Show memory profiler diff vs last snapshot", "Debug", function() vim.cmd("VaultMemoryDiff") end)

vim.api.nvim_create_user_command("VaultMemoryReset", function()
  local profiler = require("andrew.vault.memory_profiler")
  profiler.reset_timings()
  notify.info("Profiler timing windows reset")
end, { desc = "Reset profiler timing windows and GC samples" })
palette.register_command("VaultMemoryReset", "Reset memory profiler timing windows", "Debug", function() vim.cmd("VaultMemoryReset") end)

return M
