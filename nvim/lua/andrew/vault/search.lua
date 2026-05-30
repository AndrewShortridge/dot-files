local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local _track
local _execute_advanced_query
local _search_advanced
local _search_advanced_live
local _search_in_files
local _search_help
local _complete_advanced
local function track(...)
  if not _track then _track = require("andrew.vault.search.track").track end
  return _track(...)
end

local M = {}

function M.search()
  track("", "all", "grep")
  require("fzf-lua").live_grep(engine.vault_fzf_opts("Vault search"))
end

function M.search_notes()
  track("", "all", "grep")
  require("fzf-lua").live_grep(engine.vault_fzf_opts("Vault notes", {
    rg_opts = engine.rg_base_opts(),
  }))
end

function M.search_filtered()
  local scopes = config.scopes

  local labels = {}
  for _, scope in ipairs(scopes) do
    table.insert(labels, scope.label)
  end

  vim.ui.select(labels, { prompt = "Search scope:" }, function(choice)
    if not choice then
      return
    end

    local selected
    for _, scope in ipairs(scopes) do
      if scope.label == choice then
        selected = scope
        break
      end
    end

    if not selected then
      return
    end

    track("", selected.key, "grep")

    require("fzf-lua").live_grep(engine.vault_fzf_opts("Vault [" .. selected.label .. "]", {
      rg_opts = engine.rg_base_opts(selected.glob),
    }))
  end)
end

function M.search_by_type()
  local types = config.note_types

  vim.ui.select(types, { prompt = "Note type:" }, function(choice)
    if not choice then
      return
    end

    track(choice, "all", "type")

    require("fzf-lua").grep(engine.vault_fzf_opts("Vault type [" .. choice .. "]", {
      search = "^type:\\s+" .. choice,
      no_esc = true,
      rg_opts = engine.rg_base_opts(),
    }))
  end)
end

-- Re-exports from sub-modules (lazy-loaded, cached on first call)
function M.execute_advanced_query(...)
  if not _execute_advanced_query then _execute_advanced_query = require("andrew.vault.search.advanced").execute_advanced_query end
  return _execute_advanced_query(...)
end
function M.search_advanced(...)
  if not _search_advanced then _search_advanced = require("andrew.vault.search.prompt").search_advanced end
  return _search_advanced(...)
end
function M.search_advanced_live(...)
  if not _search_advanced_live then _search_advanced_live = require("andrew.vault.search.live").search_advanced_live end
  return _search_advanced_live(...)
end
function M.search_in_files(...)
  if not _search_in_files then _search_in_files = require("andrew.vault.search.live").search_in_files end
  return _search_in_files(...)
end
function M.search_help(...)
  if not _search_help then _search_help = require("andrew.vault.search.help").search_help end
  return _search_help(...)
end
function M._complete_advanced(...)
  if not _complete_advanced then _complete_advanced = require("andrew.vault.search.completion")._complete_advanced end
  return _complete_advanced(...)
end

function M.setup()
  local palette = require("andrew.vault.command_palette")

  vim.api.nvim_create_user_command("VaultSearch", function()
    M.search_advanced_live()
  end, { desc = "Live grep across the vault" })

  vim.api.nvim_create_user_command("VaultSearchNotes", function()
    M.search_notes()
  end, { desc = "Live grep across vault markdown notes" })

  -- Find group: <leader>vf
  vim.keymap.set("n", "<leader>vfs", function()
    M.search_advanced_live()
  end, { desc = "Find: search vault", silent = true })

  vim.keymap.set("n", "<leader>vfn", function()
    M.search_notes()
  end, { desc = "Find: search notes", silent = true })

  vim.api.nvim_create_user_command("VaultSearchFiltered", function()
    M.search_filtered()
  end, { desc = "Live grep across vault scoped by folder" })

  vim.api.nvim_create_user_command("VaultSearchType", function()
    M.search_by_type()
  end, { desc = "Search vault notes by frontmatter type" })

  vim.keymap.set("n", "<leader>vfD", function()
    M.search_filtered()
  end, { desc = "Find: search filtered (scope by directory)", silent = true })

  vim.keymap.set("n", "<leader>vfy", function()
    M.search_by_type()
  end, { desc = "Find: search by type", silent = true })

  -- Advanced search commands
  vim.api.nvim_create_user_command("VaultSearchAdvanced", function()
    M.search_advanced()
  end, { desc = "Advanced vault search (prompt mode)" })

  vim.api.nvim_create_user_command("VaultSearchAdvancedLive", function()
    M.search_advanced_live()
  end, { desc = "Advanced vault search (live mode)" })

  vim.api.nvim_create_user_command("VaultSearchHelp", function()
    M.search_help()
  end, { desc = "Show advanced search syntax help" })

  vim.keymap.set("n", "<leader>vfA", function()
    M.search_advanced_live()
  end, { desc = "Find: advanced search (live)", silent = true })

  -- Search history
  vim.keymap.set("n", "<leader>vfH", function()
    require("andrew.vault.search_history").pick()
  end, { desc = "Find: search history", silent = true })

  local sched = require("andrew.vault.work_scheduler")
  sched.schedule(sched.DEFERRED, function()
    require("andrew.vault.search_history").setup()
  end, { domain = "search", label = "history-setup" })

  -- Palette registrations
  palette.register_command("VaultSearch", "Live grep across the vault", "Search", M.search_advanced_live, "<leader>vfs")
  palette.register_command("VaultSearchNotes", "Live grep across vault markdown notes", "Search", M.search_notes, "<leader>vfn")
  palette.register_command("VaultSearchFiltered", "Live grep across vault scoped by folder", "Search", M.search_filtered, "<leader>vfD")
  palette.register_command("VaultSearchType", "Search vault notes by frontmatter type", "Search", M.search_by_type, "<leader>vfy")
  palette.register_command("VaultSearchAdvanced", "Advanced vault search (prompt mode)", "Search", M.search_advanced)
  palette.register_command("VaultSearchAdvancedLive", "Advanced vault search (live mode)", "Search", M.search_advanced_live, "<leader>vfA")
  palette.register_command("VaultSearchHelp", "Show advanced search syntax help", "Search", M.search_help)
end

return M
