--- Consolidated autocmd dispatcher for vault events.
---
--- BufEnter: coalesces via event_coalescer (adaptive delay for :bufdo).
---   Vault markdown: dispatches to embed, breadcrumbs, frecency, task_notify, sidebar.
---   Non-vault: dispatches to linkdiag (clear diagnostics), breadcrumbs (clear winbar).
---   Leaves alone: highlight_coordinator (own BufEnter pipeline), search/prompt, pickers.
---
--- TextChanged/TextChangedI/InsertLeave: single autocmd, shared vault check.
---   Dispatches to: highlight_coordinator, embed, task_hierarchy.
---
--- FileType markdown: single autocmd, dispatches buffer-local keymaps to 14 modules.
---
--- BufWritePost: single autocmd, shared vault check.
---   Dispatches to: highlight_coordinator, breadcrumbs, autofile.
---
--- VimLeavePre: single autocmd, dispatches teardown to all modules with cleanup.

local M = {}

local event_coalescer = require("andrew.vault.event_coalescer")
local config = require("andrew.vault.config")

local _buf_enter_coalescer
local _group

function M.setup()
  local engine = require("andrew.vault.engine")
  local embed = require("andrew.vault.embed")
  local breadcrumbs = require("andrew.vault.breadcrumbs")
  local frecency = require("andrew.vault.frecency")
  local task_notify = require("andrew.vault.task_notify")
  local linkdiag = require("andrew.vault.linkdiag")
  -- sidebar is Tier 3 (lazy-loaded); only dispatch if already loaded
  local highlight_coordinator = require("andrew.vault.highlight_coordinator")
  local task_hierarchy = require("andrew.vault.task_hierarchy")

  -- FileType keymap modules (all already loaded by Tier 2 init)
  local wikilinks = require("andrew.vault.wikilinks")
  local backlinks = require("andrew.vault.backlinks")
  local navigate = require("andrew.vault.navigate")
  local blockid = require("andrew.vault.blockid")
  local preview = require("andrew.vault.preview")
  local outline = require("andrew.vault.outline")
  local images = require("andrew.vault.images")
  local callout_folds = require("andrew.vault.callout_folds")
  local autolink = require("andrew.vault.autolink")
  local inline_fields = require("andrew.vault.inline_fields")
  local tag_highlights = require("andrew.vault.tag_highlights")
  local wikilink_highlights = require("andrew.vault.wikilink_highlights")
  local highlights = require("andrew.vault.highlights")

  -- BufWritePost modules
  local autofile = require("andrew.vault.autofile")

  -- VimLeavePre modules
  local autosave = require("andrew.vault.autosave")
  local connections = require("andrew.vault.connections")

  _group = vim.api.nvim_create_augroup("VaultEventDispatch", { clear = true })

  -- -----------------------------------------------------------------------
  -- BufEnter coalescer
  -- -----------------------------------------------------------------------

  _buf_enter_coalescer = event_coalescer.new({
    delay_ms = config.events.buf_enter_coalesce_ms,
    max_batch = config.events.max_batch_size,
    adaptive = true,
    rapid_threshold_ms = config.events.rapid_switch_threshold_ms,
    rapid_delay_ms = config.events.rapid_switch_delay_ms,
    handler = function(batch)
      for bufnr, _ in pairs(batch) do
        if not vim.api.nvim_buf_is_valid(bufnr) then goto continue end

        local ft = vim.bo[bufnr].filetype
        local file = vim.api.nvim_buf_get_name(bufnr)
        local is_vault_md = ft == "markdown" and engine.is_vault_buf(bufnr)

        local ctx = { bufnr = bufnr, file = file, is_vault_md = is_vault_md }

        -- Non-vault: clear diagnostics and winbar
        if not is_vault_md then
          linkdiag.on_buf_enter_non_vault(ctx)
          breadcrumbs.on_buf_enter_non_vault(ctx)
          goto continue
        end

        -- Vault markdown handlers (shared context, no redundant checks)
        breadcrumbs.on_buf_enter(ctx)
        embed.on_buf_enter(ctx)
        frecency.on_buf_enter(ctx)
        task_notify.on_buf_enter(ctx)

        -- sidebar is lazy: only dispatch if already loaded
        local sb = package.loaded["andrew.vault.sidebar"]
        if sb and sb.on_buf_enter then
          sb.on_buf_enter(ctx)
        end

        ::continue::
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = _group,
    callback = function(ev)
      -- Skip special buffers (terminals, help, etc.)
      if vim.bo[ev.buf].buftype ~= "" then return end
      event_coalescer.queue(_buf_enter_coalescer, ev.buf, { event = "BufEnter" })
    end,
  })

  -- -----------------------------------------------------------------------
  -- TextChanged / TextChangedI / InsertLeave — shared condition check
  -- -----------------------------------------------------------------------
  -- Event routing:
  --   highlight_coordinator: TextChanged + TextChangedI (NOT InsertLeave)
  --   embed:                 TextChanged + InsertLeave  (NOT TextChangedI)
  --   task_hierarchy:        TextChanged + TextChangedI (NOT InsertLeave)

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group = _group,
    pattern = "*.md",
    callback = function(ev)
      local bufnr = ev.buf
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      if vim.bo[bufnr].filetype ~= "markdown" then return end

      local file = vim.api.nvim_buf_get_name(bufnr)
      if not engine.is_vault_buf(bufnr) then return end

      local event = ev.event

      -- highlight_coordinator: TextChanged + TextChangedI
      if event ~= "InsertLeave" then
        highlight_coordinator.schedule(bufnr, { full = false })
      end

      -- embed: TextChanged + InsertLeave (self-referential rerender)
      if event ~= "TextChangedI" then
        embed.on_text_changed(bufnr, file)
      end

      -- task_hierarchy: TextChanged + TextChangedI
      if event ~= "InsertLeave" then
        task_hierarchy._schedule_render(bufnr)
      end
    end,
  })

  -- -----------------------------------------------------------------------
  -- FileType markdown — consolidated buffer-local keymap setup
  -- -----------------------------------------------------------------------
  -- Replaces 14 independent FileType autocmds with a single dispatcher.
  -- Each module's on_ft_markdown(ev) sets buffer-local keymaps.

  vim.api.nvim_create_autocmd("FileType", {
    group = _group,
    pattern = "markdown",
    callback = function(ev)
      -- Core navigation & editing
      wikilinks.on_ft_markdown(ev)
      backlinks.on_ft_markdown(ev)
      navigate.on_ft_markdown(ev)
      preview.on_ft_markdown(ev)
      outline.on_ft_markdown(ev)

      -- Block & structure
      blockid.on_ft_markdown(ev)
      callout_folds.on_ft_markdown(ev)
      images.on_ft_markdown(ev)

      -- Link & field features
      autolink.on_ft_markdown(ev)
      linkdiag.on_ft_markdown(ev)

      -- Highlight modules
      inline_fields.on_ft_markdown(ev)
      tag_highlights.on_ft_markdown(ev)
      wikilink_highlights.on_ft_markdown(ev)
      highlights.on_ft_markdown(ev)
    end,
  })

  -- -----------------------------------------------------------------------
  -- BufWritePost — shared vault check, dispatches to 3 handlers
  -- -----------------------------------------------------------------------
  -- init.lua cache invalidation stays separate (different event set + scope).

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = _group,
    pattern = "*.md",
    callback = function(ev)
      local bufnr = ev.buf
      local file = vim.api.nvim_buf_get_name(bufnr)
      if not engine.is_vault_buf(bufnr) then return end

      local ctx = { bufnr = bufnr, file = file }
      highlight_coordinator.on_buf_write(ctx)
      breadcrumbs.on_buf_write(ctx)
      autofile.on_buf_write(ctx)
    end,
  })

  -- -----------------------------------------------------------------------
  -- VimLeavePre — consolidated module teardown
  -- -----------------------------------------------------------------------
  -- init.lua keeps its own VimLeavePre for init-level cleanup (focus timer,
  -- fs watcher, vault index persist).

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = _group,
    callback = function()
      -- Engine: URL validation persist + log close
      engine.teardown()

      -- Highlight & render timers
      highlight_coordinator.teardown()
      task_hierarchy.teardown()
      autosave.teardown()

      -- Embed state & sync cleanup
      embed.teardown()

      -- Subscriptions
      connections.teardown()

      -- Persistent state saves
      callout_folds.teardown()

      -- Event coalescer timer
      M.close()
    end,
  })
end

function M.close()
  if _buf_enter_coalescer then
    event_coalescer.close(_buf_enter_coalescer)
    _buf_enter_coalescer = nil
  end
end

return M
