local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")

local M = {}

--- Record the last search in saved_searches for the quick-save feature.
---@param query string
---@param scope string
---@param search_type? string
local function track(query, scope, search_type)
  -- Lazy-require to avoid circular dependency at load time
  require("andrew.vault.saved_searches").set_last_search(query, scope, search_type)
end

function M.search()
  track("", "all", "grep")
  require("fzf-lua").live_grep({
    cwd = engine.vault_path,
    prompt = "Vault search> ",
    file_icons = true,
    git_icons = false,
  })
end

function M.search_notes()
  track("", "all", "grep")
  require("fzf-lua").live_grep({
    cwd = engine.vault_path,
    prompt = "Vault notes> ",
    file_icons = true,
    git_icons = false,
    rg_opts = '--column --line-number --no-heading --color=always --smart-case --glob "*.md"',
  })
end

function M.search_filtered()
  local scopes = {
    { label = "All notes", glob = "**/*.md", key = "all" },
    { label = "Projects", glob = config.dirs.projects .. "/**/*.md", key = "projects" },
    { label = "Areas", glob = config.dirs.areas .. "/**/*.md", key = "areas" },
    { label = "Log", glob = config.dirs.log .. "/**/*.md", key = "log" },
    { label = "Domains", glob = config.dirs.domains .. "/**/*.md", key = "domains" },
  }

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

    require("fzf-lua").live_grep({
      cwd = engine.vault_path,
      prompt = "Vault [" .. selected.label .. "]> ",
      file_icons = true,
      git_icons = false,
      rg_opts = '--column --line-number --no-heading --color=always --smart-case --glob "' .. selected.glob .. '"',
    })
  end)
end

function M.search_by_type()
  local types = config.note_types

  vim.ui.select(types, { prompt = "Note type:" }, function(choice)
    if not choice then
      return
    end

    track(choice, "all", "type")

    require("fzf-lua").grep({
      cwd = engine.vault_path,
      prompt = "Vault type [" .. choice .. "]> ",
      file_icons = true,
      git_icons = false,
      search = "^type:\\s+" .. choice,
      no_esc = true,
      rg_opts = '--column --line-number --no-heading --color=always --smart-case --glob "*.md"',
    })
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("VaultSearch", function()
    M.search()
  end, { desc = "Live grep across the vault" })

  vim.api.nvim_create_user_command("VaultSearchNotes", function()
    M.search_notes()
  end, { desc = "Live grep across vault markdown notes" })

  -- Find group: <leader>vf
  vim.keymap.set("n", "<leader>vfs", function()
    M.search()
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
end

return M
