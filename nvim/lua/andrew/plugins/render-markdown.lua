-- =============================================================================
-- Markdown Rendering (render-markdown.nvim)
-- =============================================================================
-- Renders markdown in-buffer with styled headings, tables with box-drawing
-- characters, checkboxes, code blocks, and concealed wiki-link syntax.
-- Uses treesitter for parsing. Rendering disappears when cursor enters
-- the element so you can edit normally.

return {
  "MeanderingProgrammer/render-markdown.nvim",

  ft = { "markdown", "blink-cmp-documentation" },

  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "nvim-tree/nvim-web-devicons",
  },

  config = function(_, opts)
    -- Tell treesitter to use the markdown parser for blink.cmp doc buffers
    vim.treesitter.language.register("markdown", "blink-cmp-documentation")

    -- Fallback strikethrough highlights — re-applied after every colorscheme
    -- change because `hi clear` wipes them and themes like onedark don't define them.
    -- Uses `default = true` so theme-specific definitions (soft-paper) take precedence.
    local function apply_scope_fallbacks()
      for _, name in ipairs({ "RenderMarkdownCheckedScope", "RenderMarkdownCancelledScope" }) do
        vim.api.nvim_set_hl(0, name, { strikethrough = true, fg = "#888888", default = true })
      end
    end
    apply_scope_fallbacks()
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = vim.api.nvim_create_augroup("RenderMarkdownScopeFallback", { clear = true }),
      callback = apply_scope_fallbacks,
    })

    require("render-markdown").setup(opts)

    -- =========================================================================
    -- Callout collapsing support (Obsidian [!TYPE]- / [!TYPE]+ syntax)
    -- =========================================================================
    -- Uses Neovim folds to collapse/expand callout content. Callouts marked
    -- with `-` are folded on BufRead; those with `+` are left open but can be
    -- toggled. A buffer-local keymap (<leader>mz) toggles the fold under cursor.

    --- Scan the buffer for all callouts and ensure proper manual folds exist.
    --- Creates folds covering the full callout range (header+1 to end_line),
    --- then closes/opens suffixed callouts per their default state.
    --- Uses Ex commands with explicit line ranges (no cursor movement needed).
    ---@param bufnr number
    local function apply_callout_folds(bufnr)
      local ok_cf, callout_folds = pcall(require, "andrew.vault.callout_folds")
      if not ok_cf then return end

      local all_blocks = callout_folds.get_all_blocks(bufnr)
      for _, block in ipairs(all_blocks) do
        if block.end_line > block.start_line then
          local cs = block.start_line + 1
          local ce = block.end_line
          -- :N,Mfold creates a CLOSED manual fold covering the content range
          vim.cmd("silent! " .. cs .. "," .. ce .. "fold")
          -- Collapsed callouts (-) stay closed; others need to be opened
          if block.suffix ~= "-" then
            vim.cmd("silent! " .. cs .. "," .. ce .. "foldopen")
          end
        end
      end
    end

    --- Toggle the callout fold under the cursor.
    --- Uses Ex commands with explicit line ranges (no cursor movement needed).
    ---@param bufnr number
    local function toggle_callout_fold(bufnr)
      local ok_cf, callout_folds = pcall(require, "andrew.vault.callout_folds")
      if not ok_cf then
        vim.notify("Callout folds module not available", vim.log.levels.WARN)
        return
      end

      local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]

      -- Find the callout block containing the cursor (all callouts, not just suffixed)
      local blocks = callout_folds.get_all_blocks(bufnr)
      local target_block = nil
      for _, block in ipairs(blocks) do
        if cursor_lnum >= block.start_line and cursor_lnum <= block.end_line then
          target_block = block
          break
        end
      end

      if not target_block then
        vim.notify("No callout under cursor", vim.log.levels.WARN)
        return
      end

      if target_block.end_line <= target_block.start_line then
        vim.notify("Callout has no content to fold", vim.log.levels.WARN)
        return
      end

      -- Ensure foldmethod is manual (ftplugin sets expr; our setup switches to manual,
      -- but guard against race conditions or re-triggers)
      if vim.wo.foldmethod ~= "manual" then
        vim.wo.foldmethod = "manual"
      end

      local cs = target_block.start_line + 1
      local ce = target_block.end_line
      local is_folded = vim.fn.foldclosed(cs) ~= -1
      local is_now_open

      if is_folded then
        -- Content is folded — open it
        vim.cmd("silent! " .. cs .. "," .. ce .. "foldopen")
        is_now_open = true
      else
        -- Content is visible — try closing existing fold first
        vim.cmd("silent! " .. cs .. "," .. ce .. "foldclose")
        -- If no fold existed, foldclose was a no-op; create a new one (closed by default)
        if vim.fn.foldclosed(cs) == -1 then
          vim.cmd(cs .. "," .. ce .. "fold")
        end
        is_now_open = false
        -- Keep cursor on header line (content is now hidden)
        pcall(vim.api.nvim_win_set_cursor, 0, { target_block.start_line, 0 })
      end

      -- Persist the toggle (only for suffixed callouts that have a default state)
      if target_block.suffix then
        callout_folds.record_toggle(bufnr, target_block.header_lnum, is_now_open)
      end
    end

    local callout_group = vim.api.nvim_create_augroup("VaultCalloutCollapse", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = callout_group,
      pattern = "markdown",
      callback = function(ev)
        local bufnr = ev.buf

        -- Buffer-local keymap to toggle callout fold
        vim.keymap.set("n", "<leader>mz", function()
          toggle_callout_fold(bufnr)
        end, { buffer = bufnr, desc = "Toggle callout fold" })

        -- Apply folds after the buffer is fully loaded and on re-read
        vim.api.nvim_create_autocmd({ "BufWinEnter", "BufRead" }, {
          group = callout_group,
          buffer = bufnr,
          callback = function()
            -- Defer so treesitter folds are computed before we manipulate them
            vim.defer_fn(function()
              if not vim.api.nvim_buf_is_valid(bufnr) then return end
              if vim.api.nvim_get_current_buf() ~= bufnr then return end
              -- Switch to manual foldmethod and clear all treesitter folds,
              -- then create clean callout folds without nested fold interference
              vim.wo.foldmethod = "manual"
              pcall(vim.cmd, "normal! zE")
              apply_callout_folds(bufnr)
              -- Restore user overrides from cache (callout_folds already loaded by apply_callout_folds)
              local ok_cf, cf = pcall(require, "andrew.vault.callout_folds")
              if ok_cf then cf.restore(bufnr) end
            end, 50)
          end,
        })
      end,
    })

  end,

  ---@module 'render-markdown'
  ---@type render.md.UserConfig
  opts = {
    file_types = { "markdown", "blink-cmp-documentation" },

    -- Use the obsidian preset (renders in all modes)
    preset = "obsidian",

    -- Heading: keep markdown-style icons, disable sign column clutter
    heading = {
      sign = false,
    },

    -- Code blocks: no sign column, full-width background
    code = {
      sign = false,
    },

    -- Table rendering with round box-drawing characters
    pipe_table = {
      preset = "round",
    },

    -- Custom checkbox rendering for all vault task states
    checkbox = {
      -- Strikethrough completed task text
      checked = {
        scope_highlight = "RenderMarkdownCheckedScope",
      },
      custom = {
        -- Override render-markdown default 'todo' (also raw="[-]") to avoid
        -- non-deterministic conflict with our 'cancelled' entry in normalize()
        todo = { raw = "[~]", rendered = "󰥔 ", highlight = "RenderMarkdownTodo" },
        in_progress = { raw = "[/]", rendered = "󰔟 ", highlight = "RenderMarkdownWarn" },
        cancelled = {
          raw = "[-]",
          rendered = "✘ ",
          highlight = "RenderMarkdownError",
          scope_highlight = "RenderMarkdownCancelledScope",
        },
        deferred = { raw = "[>]", rendered = "󰒊 ", highlight = "RenderMarkdownInfo" },
      },
    },

    -- Keep scope highlight visible even on the cursor line
    anti_conceal = {
      ignore = {
        check_scope = true,
      },
    },

    -- Obsidian-style callout / admonition rendering
    -- The plugin ships with all standard callout types by default (note, tip,
    -- warning, caution, important, abstract, info, todo, success, question,
    -- failure, danger, bug, example, quote and their aliases). We override
    -- quote_icon per callout so each category gets a distinct quote-bar icon
    -- instead of sharing the generic "▋".
    callout = {
      -- stylua: ignore start

      -- Standard callouts (always expanded, no toggle)
      note      = { raw = "[!NOTE]",      rendered = "󰋽 Note",      highlight = "RenderMarkdownInfo",    quote_icon = "┃" },
      tip       = { raw = "[!TIP]",       rendered = "󰌶 Tip",       highlight = "RenderMarkdownSuccess", quote_icon = "┃" },
      important = { raw = "[!IMPORTANT]", rendered = "󰅾 Important", highlight = "RenderMarkdownHint",    quote_icon = "┃" },
      warning   = { raw = "[!WARNING]",   rendered = "󰀪 Warning",   highlight = "RenderMarkdownWarn",    quote_icon = "┃" },
      caution   = { raw = "[!CAUTION]",   rendered = "󰳦 Caution",   highlight = "RenderMarkdownError",   quote_icon = "┃" },
      abstract  = { raw = "[!ABSTRACT]",  rendered = "󰨸 Abstract",  highlight = "RenderMarkdownInfo",    quote_icon = "┃" },
      info      = { raw = "[!INFO]",      rendered = "󰋽 Info",       highlight = "RenderMarkdownInfo",    quote_icon = "┃" },
      todo      = { raw = "[!TODO]",      rendered = "󰗡 Todo",      highlight = "RenderMarkdownInfo",    quote_icon = "┃" },
      success   = { raw = "[!SUCCESS]",   rendered = "󰄬 Success",   highlight = "RenderMarkdownSuccess", quote_icon = "┃" },
      question  = { raw = "[!QUESTION]",  rendered = "󰘥 Question",  highlight = "RenderMarkdownWarn",    quote_icon = "┃" },
      failure   = { raw = "[!FAILURE]",   rendered = "󰅖 Failure",   highlight = "RenderMarkdownError",   quote_icon = "┃" },
      danger    = { raw = "[!DANGER]",    rendered = "󱐌 Danger",    highlight = "RenderMarkdownError",   quote_icon = "┃" },
      bug       = { raw = "[!BUG]",       rendered = "󰨰 Bug",       highlight = "RenderMarkdownError",   quote_icon = "┃" },
      example   = { raw = "[!EXAMPLE]",   rendered = "󰉹 Example",   highlight = "RenderMarkdownHint",    quote_icon = "┃" },
      quote     = { raw = "[!QUOTE]",     rendered = "󱆨 Quote",     highlight = "RenderMarkdownQuote",   quote_icon = "┃" },

      -- Vault-specific callout types (matching config.note_types)
      simulation = { raw = "[!SIMULATION]", rendered = "󰓹 Simulation", highlight = "RenderMarkdownHint",    quote_icon = "┃" },
      finding    = { raw = "[!FINDING]",    rendered = "󱩼 Finding",    highlight = "RenderMarkdownSuccess", quote_icon = "┃" },
      meeting    = { raw = "[!MEETING]",    rendered = "󰤙 Meeting",    highlight = "RenderMarkdownInfo",    quote_icon = "┃" },
      analysis   = { raw = "[!ANALYSIS]",   rendered = "󰇙 Analysis",   highlight = "RenderMarkdownWarn",    quote_icon = "┃" },
      literature = { raw = "[!LITERATURE]", rendered = "󰂺 Literature", highlight = "RenderMarkdownInfo",    quote_icon = "┃" },
      concept    = { raw = "[!CONCEPT]",    rendered = "󰛕 Concept",    highlight = "RenderMarkdownHint",    quote_icon = "┃" },

      -- Collapsed variants (> [!TYPE]- — folded by default)
      note_collapsed      = { raw = "[!NOTE]-",      rendered = "󰋽 Note ▸",      highlight = "RenderMarkdownInfo",    quote_icon = "┃" },
      tip_collapsed       = { raw = "[!TIP]-",       rendered = "󰌶 Tip ▸",       highlight = "RenderMarkdownSuccess", quote_icon = "┃" },
      important_collapsed = { raw = "[!IMPORTANT]-", rendered = "󰅾 Important ▸", highlight = "RenderMarkdownHint",    quote_icon = "┃" },
      warning_collapsed   = { raw = "[!WARNING]-",   rendered = "󰀪 Warning ▸",   highlight = "RenderMarkdownWarn",    quote_icon = "┃" },
      caution_collapsed   = { raw = "[!CAUTION]-",   rendered = "󰳦 Caution ▸",   highlight = "RenderMarkdownError",   quote_icon = "┃" },
      abstract_collapsed  = { raw = "[!ABSTRACT]-",  rendered = "󰨸 Abstract ▸",  highlight = "RenderMarkdownInfo",    quote_icon = "┃" },
      info_collapsed      = { raw = "[!INFO]-",      rendered = "󰋽 Info ▸",       highlight = "RenderMarkdownInfo",    quote_icon = "┃" },
      todo_collapsed      = { raw = "[!TODO]-",      rendered = "󰗡 Todo ▸",      highlight = "RenderMarkdownInfo",    quote_icon = "┃" },
      success_collapsed   = { raw = "[!SUCCESS]-",   rendered = "󰄬 Success ▸",   highlight = "RenderMarkdownSuccess", quote_icon = "┃" },
      question_collapsed  = { raw = "[!QUESTION]-",  rendered = "󰘥 Question ▸",  highlight = "RenderMarkdownWarn",    quote_icon = "┃" },
      failure_collapsed   = { raw = "[!FAILURE]-",   rendered = "󰅖 Failure ▸",   highlight = "RenderMarkdownError",   quote_icon = "┃" },
      danger_collapsed    = { raw = "[!DANGER]-",    rendered = "󱐌 Danger ▸",    highlight = "RenderMarkdownError",   quote_icon = "┃" },
      bug_collapsed       = { raw = "[!BUG]-",       rendered = "󰨰 Bug ▸",       highlight = "RenderMarkdownError",   quote_icon = "┃" },
      example_collapsed   = { raw = "[!EXAMPLE]-",   rendered = "󰉹 Example ▸",   highlight = "RenderMarkdownHint",    quote_icon = "┃" },
      quote_collapsed     = { raw = "[!QUOTE]-",     rendered = "󱆨 Quote ▸",     highlight = "RenderMarkdownQuote",   quote_icon = "┃" },

      simulation_collapsed = { raw = "[!SIMULATION]-", rendered = "󰓹 Simulation ▸", highlight = "RenderMarkdownHint",    quote_icon = "┃" },
      finding_collapsed    = { raw = "[!FINDING]-",    rendered = "󱩼 Finding ▸",    highlight = "RenderMarkdownSuccess", quote_icon = "┃" },
      meeting_collapsed    = { raw = "[!MEETING]-",    rendered = "󰤙 Meeting ▸",    highlight = "RenderMarkdownInfo",    quote_icon = "┃" },
      analysis_collapsed   = { raw = "[!ANALYSIS]-",   rendered = "󰇙 Analysis ▸",   highlight = "RenderMarkdownWarn",    quote_icon = "┃" },
      literature_collapsed = { raw = "[!LITERATURE]-", rendered = "󰂺 Literature ▸", highlight = "RenderMarkdownInfo",    quote_icon = "┃" },
      concept_collapsed    = { raw = "[!CONCEPT]-",    rendered = "󰛕 Concept ▸",    highlight = "RenderMarkdownHint",    quote_icon = "┃" },

      -- Expanded variants (> [!TYPE]+ — expanded by default, but togglable)
      note_expanded      = { raw = "[!NOTE]+",      rendered = "󰋽 Note ▾",      highlight = "RenderMarkdownInfo",    quote_icon = "┃" },
      tip_expanded       = { raw = "[!TIP]+",       rendered = "󰌶 Tip ▾",       highlight = "RenderMarkdownSuccess", quote_icon = "┃" },
      important_expanded = { raw = "[!IMPORTANT]+", rendered = "󰅾 Important ▾", highlight = "RenderMarkdownHint",    quote_icon = "┃" },
      warning_expanded   = { raw = "[!WARNING]+",   rendered = "󰀪 Warning ▾",   highlight = "RenderMarkdownWarn",    quote_icon = "┃" },
      caution_expanded   = { raw = "[!CAUTION]+",   rendered = "󰳦 Caution ▾",   highlight = "RenderMarkdownError",   quote_icon = "┃" },
      abstract_expanded  = { raw = "[!ABSTRACT]+",  rendered = "󰨸 Abstract ▾",  highlight = "RenderMarkdownInfo",    quote_icon = "┃" },
      info_expanded      = { raw = "[!INFO]+",      rendered = "󰋽 Info ▾",       highlight = "RenderMarkdownInfo",    quote_icon = "┃" },
      todo_expanded      = { raw = "[!TODO]+",      rendered = "󰗡 Todo ▾",      highlight = "RenderMarkdownInfo",    quote_icon = "┃" },
      success_expanded   = { raw = "[!SUCCESS]+",   rendered = "󰄬 Success ▾",   highlight = "RenderMarkdownSuccess", quote_icon = "┃" },
      question_expanded  = { raw = "[!QUESTION]+",  rendered = "󰘥 Question ▾",  highlight = "RenderMarkdownWarn",    quote_icon = "┃" },
      failure_expanded   = { raw = "[!FAILURE]+",   rendered = "󰅖 Failure ▾",   highlight = "RenderMarkdownError",   quote_icon = "┃" },
      danger_expanded    = { raw = "[!DANGER]+",    rendered = "󱐌 Danger ▾",    highlight = "RenderMarkdownError",   quote_icon = "┃" },
      bug_expanded       = { raw = "[!BUG]+",       rendered = "󰨰 Bug ▾",       highlight = "RenderMarkdownError",   quote_icon = "┃" },
      example_expanded   = { raw = "[!EXAMPLE]+",   rendered = "󰉹 Example ▾",   highlight = "RenderMarkdownHint",    quote_icon = "┃" },
      quote_expanded     = { raw = "[!QUOTE]+",     rendered = "󱆨 Quote ▾",     highlight = "RenderMarkdownQuote",   quote_icon = "┃" },

      simulation_expanded = { raw = "[!SIMULATION]+", rendered = "󰓹 Simulation ▾", highlight = "RenderMarkdownHint",    quote_icon = "┃" },
      finding_expanded    = { raw = "[!FINDING]+",    rendered = "󱩼 Finding ▾",    highlight = "RenderMarkdownSuccess", quote_icon = "┃" },
      meeting_expanded    = { raw = "[!MEETING]+",    rendered = "󰤙 Meeting ▾",    highlight = "RenderMarkdownInfo",    quote_icon = "┃" },
      analysis_expanded   = { raw = "[!ANALYSIS]+",   rendered = "󰇙 Analysis ▾",   highlight = "RenderMarkdownWarn",    quote_icon = "┃" },
      literature_expanded = { raw = "[!LITERATURE]+", rendered = "󰂺 Literature ▾", highlight = "RenderMarkdownInfo",    quote_icon = "┃" },
      concept_expanded    = { raw = "[!CONCEPT]+",    rendered = "󰛕 Concept ▾",    highlight = "RenderMarkdownHint",    quote_icon = "┃" },

      -- stylua: ignore end
    },

    -- Inline ==highlight== rendering (Obsidian-style)
    inline_highlight = {
      enabled = true,
      custom = {
        important = { prefix = "!", highlight = "RenderMarkdownError" },
        question  = { prefix = "?", highlight = "RenderMarkdownWarn" },
      },
    },

    -- LaTeX equation rendering via latex2text (pip install pylatexenc)
    latex = {
      enabled = true,
      converter = "latex2text",
      highlight = "RenderMarkdownMath",
    },
  },
}
