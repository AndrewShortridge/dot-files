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

    -- render-markdown swallows a missing converter: handler/latex.lua logs
    -- ConverterNotFound at DEBUG level and renders nothing, so math silently
    -- stays raw `$...$` source. Say so once instead.
    if opts.latex and opts.latex.enabled then
      local conv = opts.latex.converter
      local list = type(conv) == "table" and conv or { conv or "latex2text" }
      local found = false
      for _, c in ipairs(list) do
        if vim.fn.executable(c) == 1 then
          found = true
          break
        end
      end
      if not found then
        vim.schedule(function()
          vim.notify_once(
            ("render-markdown: latex.enabled but none of %s is on PATH (pip install pylatexenc); math will not render")
              :format(vim.inspect(list)),
            vim.log.levels.WARN
          )
        end)
      end
    end

    -- Async pre-warm of the latex2text cache so the first scroll into a
    -- math-heavy note doesn't block the main thread on synchronous conversion.
    pcall(function()
      require("andrew.vault.latex_warm").setup(opts.latex)
    end)

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
    ---@param all_blocks table[]  pre-fetched (changedtick-memoized) callout block list
    local function apply_callout_folds(bufnr, all_blocks)
      -- Batch all range-fold Ex commands in a single buffer context (mirrors
      -- callout_folds.restore) instead of one vim.cmd round-trip per block.
      vim.api.nvim_buf_call(bufnr, function()
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
      end)
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

        -- FileType=markdown fires on every :edit / ft-reset for the same buffer;
        -- the keymap and inner {BufWinEnter,BufRead} autocmd below only need to be
        -- registered ONCE per buffer (the augroup is cleared at config() time, so
        -- without this guard they accumulate +2 autocmds per edit). The buffer-scoped
        -- inner autocmd persists across :edit and re-applies folds via the changedtick
        -- guard, so suppressing duplicate registration does not affect fold behavior.
        if vim.b[bufnr].vault_callout_autocmd_set then return end
        vim.b[bufnr].vault_callout_autocmd_set = true

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
              -- Re-entry guard: manual folds are WINDOW-local, so key the "already
              -- applied" marker on the window (vim.w) + buffer changedtick. Re-entering
              -- an unchanged buffer in the same window is then a no-op; a new split or an
              -- edit (new changedtick) still re-applies folds correctly.
              local tick = vim.api.nvim_buf_get_changedtick(bufnr)
              if vim.w.vault_callout_folds_tick == tick then return end
              -- Cheap short-circuit: most notes have ZERO callouts. Fetch the
              -- (changedtick-memoized) block list FIRST and bail before touching
              -- foldmethod or running zE when there's nothing to fold. We still
              -- mark this tick handled so the guard holds and we don't re-scan on
              -- every BufWinEnter/BufRead.
              local ok_cf, cf = pcall(require, "andrew.vault.callout_folds")
              if not ok_cf then return end
              local blocks = cf.get_all_blocks(bufnr)
              if #blocks == 0 then
                vim.w.vault_callout_folds_tick = tick
                return
              end
              -- Switch to manual foldmethod and clear all treesitter folds,
              -- then create clean callout folds without nested fold interference
              vim.wo.foldmethod = "manual"
              pcall(vim.cmd, "normal! zE")
              apply_callout_folds(bufnr, blocks)
              -- Restore user overrides from cache (callout_folds already loaded above)
              cf.restore(bufnr)
              vim.w.vault_callout_folds_tick = tick
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

      -- ── Collapsed / expanded variants ─────────────────────────────────────
      -- INERT as of render-markdown 8.13.1 (verified 2026-09, nvim 0.12.5):
      -- every entry below whose `raw` carries a `-`/`+` suffix is never matched.
      -- resolved.lua:47 looks the callout up by EXACT text of the
      -- `shortcut_link` treesitter node, which is only the bracketed part
      -- (`[!NOTE]`); Obsidian's fold suffix sits outside that node, in the
      -- surrounding inline text. So `> [!NOTE]-` matches the plain `note` entry
      -- above and quote.lua:70 then treats everything after `[!NOTE]` as the
      -- title, rendering `󰋽 -` (or `󰋽 - My title`) instead of `󰋽 Note ▸`.
      -- The FOLDING itself is unaffected -- it comes from callout_folds.lua /
      -- the <leader>mz keymap below, which parse the suffix themselves.
      -- Keep these here so they start working if upstream ever matches the
      -- suffix; do not expect ▸/▾ on screen until then.
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

    -- LaTeX equations are rendered by snacks.image (`image.math.enabled` in
    -- snacks.lua) as real typeset inline images. Enabling this block as well
    -- draws every equation twice: snacks conceals the source and overlays an
    -- image, while this adds latex2text unicode virt text on the same rows.
    -- Flip this to true (and snacks math off) for the text-only fallback;
    -- latex2text (pip install pylatexenc) is installed for that case.
    latex = {
      enabled = false,
      converter = "latex2text",
      highlight = "RenderMarkdownMath",
    },
  },
}
