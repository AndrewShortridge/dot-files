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
    require("render-markdown").setup(opts)

    -- =========================================================================
    -- Callout collapsing support (Obsidian [!TYPE]- / [!TYPE]+ syntax)
    -- =========================================================================
    -- Uses Neovim folds to collapse/expand callout content. Callouts marked
    -- with `-` are folded on BufRead; those with `+` are left open but can be
    -- toggled. A buffer-local keymap (<leader>mz) toggles the fold under cursor.

    --- Find the callout block boundaries starting at `start_lnum` (1-indexed).
    --- Returns (header_lnum, block_end_lnum, suffix) where suffix is "-", "+", or nil.
    ---@param bufnr number
    ---@param start_lnum number 1-indexed line number of the callout header
    ---@return number, number, string|nil
    local function parse_callout_block(bufnr, start_lnum)
      local header = vim.api.nvim_buf_get_lines(bufnr, start_lnum - 1, start_lnum, false)[1]
      if not header then
        return start_lnum, start_lnum, nil
      end

      -- Match the suffix: > [!TYPE]- or > [!TYPE]+
      local suffix = header:match("^>%s*%[![%w_]+%]([%-+])")

      -- Walk forward to find the end of the blockquote (consecutive `> ` lines)
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      local block_end = start_lnum
      for lnum = start_lnum + 1, line_count do
        local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
        if not line or not line:match("^>") then
          break
        end
        block_end = lnum
      end

      return start_lnum, block_end, suffix
    end

    --- Scan the buffer for all collapsible callouts and apply folds.
    ---@param bufnr number
    local function apply_callout_folds(bufnr)
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      local lnum = 1
      while lnum <= line_count do
        local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
        if line and line:match("^>%s*%[![%w_]+%][%-+]") then
          local header_lnum, block_end, suffix = parse_callout_block(bufnr, lnum)
          -- Only create folds when there is content beyond the header line
          if block_end > header_lnum then
            -- Create the fold over the content lines (excluding the header)
            vim.api.nvim_buf_call(bufnr, function()
              -- Create fold spanning from header+1 to block_end
              pcall(vim.cmd, (header_lnum + 1) .. "," .. block_end .. "fold")
              -- Auto-close folds for collapsed (-) callouts
              if suffix == "-" then
                pcall(vim.cmd, header_lnum + 1 .. "foldclose")
              else
                -- Expanded (+) callouts: open the fold
                pcall(vim.cmd, header_lnum + 1 .. "foldopen")
              end
            end)
          end
          lnum = block_end + 1
        else
          lnum = lnum + 1
        end
      end
    end

    --- Toggle the callout fold under the cursor.
    ---@param bufnr number
    local function toggle_callout_fold(bufnr)
      local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]
      local line_count = vim.api.nvim_buf_line_count(bufnr)

      -- Walk backward to find the callout header if we're inside a callout block
      local header_lnum = nil
      for lnum = cursor_lnum, 1, -1 do
        local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
        if line and line:match("^>%s*%[![%w_]+%]") then
          header_lnum = lnum
          break
        end
        -- Stop searching if we leave the blockquote
        if not line or not line:match("^>") then
          break
        end
      end

      if not header_lnum then
        vim.notify("No callout under cursor", vim.log.levels.WARN)
        return
      end

      local _, block_end, _ = parse_callout_block(bufnr, header_lnum)
      if block_end <= header_lnum then
        vim.notify("Callout has no content to fold", vim.log.levels.WARN)
        return
      end

      -- Check if any content line is folded
      local content_start = header_lnum + 1
      local fold_closed = vim.fn.foldclosed(content_start)

      if fold_closed ~= -1 then
        -- Content is folded — open it
        pcall(vim.cmd, content_start .. "foldopen")
      else
        -- Content is visible — try closing existing fold or create a new one
        local fold_level = vim.fn.foldlevel(content_start)
        if fold_level > 0 then
          pcall(vim.cmd, content_start .. "foldclose")
        else
          -- No fold exists yet — create one and close it
          pcall(vim.cmd, content_start .. "," .. block_end .. "fold")
          pcall(vim.cmd, content_start .. "foldclose")
        end
      end
    end

    local callout_group = vim.api.nvim_create_augroup("VaultCalloutCollapse", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = callout_group,
      pattern = "markdown",
      callback = function(ev)
        local bufnr = ev.buf

        -- Use manual foldmethod so we can create folds programmatically
        vim.api.nvim_set_option_value("foldmethod", "manual", { win = 0 })
        -- Don't auto-close folds when moving cursor
        vim.api.nvim_set_option_value("foldlevel", 99, { win = 0 })

        -- Custom foldtext: show the callout header with a collapse indicator
        vim.api.nvim_set_option_value("foldtext", "v:lua.VaultCalloutFoldtext()", { win = 0 })

        -- Buffer-local keymap to toggle callout fold
        vim.keymap.set("n", "<leader>mz", function()
          toggle_callout_fold(bufnr)
        end, { buffer = bufnr, desc = "Toggle callout fold" })

        -- Apply folds after the buffer is fully loaded and on re-read
        vim.api.nvim_create_autocmd({ "BufWinEnter", "BufRead" }, {
          group = callout_group,
          buffer = bufnr,
          callback = function()
            -- Defer so render-markdown has time to process the buffer
            vim.defer_fn(function()
              if vim.api.nvim_buf_is_valid(bufnr) then
                apply_callout_folds(bufnr)
              end
            end, 50)
          end,
        })
      end,
    })

    -- Global foldtext function for callout folds
    function _G.VaultCalloutFoldtext()
      local foldstart = vim.v.foldstart
      local foldend = vim.v.foldend
      local header_lnum = foldstart - 1
      if header_lnum >= 1 then
        local header = vim.fn.getline(header_lnum)
        if header:match("^>%s*%[![%w_]+%]") then
          local fold_count = foldend - foldstart + 1
          return header .. "  (" .. fold_count .. " lines)"
        end
      end
      return vim.fn.getline(foldstart) .. " ... (" .. (foldend - foldstart + 1) .. " lines)"
    end
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
      custom = {
        in_progress = { raw = "[/]", rendered = "󰔟 ", highlight = "RenderMarkdownWarn" },
        cancelled = { raw = "[-]", rendered = "✘ ", highlight = "RenderMarkdownError" },
        deferred = { raw = "[>]", rendered = "󰒊 ", highlight = "RenderMarkdownInfo" },
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

    -- LaTeX equation rendering via latex2text (pip install pylatexenc)
    latex = {
      enabled = true,
      converter = "latex2text",
      highlight = "RenderMarkdownMath",
    },
  },
}
