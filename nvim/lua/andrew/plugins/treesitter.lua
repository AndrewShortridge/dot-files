-- =============================================================================
-- Syntax Highlighting and Parsing (nvim-treesitter)
-- =============================================================================
-- Configures tree-sitter for syntax highlighting, text objects, and indentation.
-- Tree-sitter provides more accurate syntax highlighting than built-in methods.

return {
  -- Plugin: nvim-treesitter - Tree-sitter integration for Neovim
  -- Repository: https://github.com/nvim-treesitter/nvim-treesitter
  "nvim-treesitter/nvim-treesitter",

  -- Pin to the classic `master` branch. nvim-treesitter changed its default
  -- branch to `main` (a full API rewrite that removes `nvim-treesitter.configs`,
  -- `ensure_installed`, `highlight`, `indent`, `incremental_selection`). This
  -- config uses the classic API, so we must stay on `master`.
  branch = "master",

  -- Events: Load when opening files for syntax highlighting
  event = { "BufReadPre", "BufNewFile" },

  -- Build command: Run after installation to parse and generate syntax files
  build = ":TSUpdate",

  -- Dependencies
  dependencies = {
    -- Auto-close HTML/XML tags
    "windwp/nvim-ts-autotag",
  },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    -- nvim 0.12 compat: fix nvim-treesitter (archived master) directive/predicate
    -- handlers that crash on 0.12's node-list match API. See the module for details.
    require("andrew.utils.ts_directive_compat").apply()

    -- Safely require treesitter module (handles install order)
    local status_ok, treesitter = pcall(require, "nvim-treesitter.configs")
    if not status_ok then
      return
    end

    -- Under a read-only image (container/nvim.def exports NVIM_CONTAINER=1) the
    -- plugin's own parser/ directory cannot be written. nvim-treesitter asserts
    -- that directory is read/write during setup and throws on every BufReadPre
    -- otherwise --
    --   Parser dir '<...>/nvim-treesitter/parser' should be read/write
    -- which makes the editor unusable for opening files. Point the INSTALL dir
    -- at writable state instead. The parsers baked into the image still load:
    -- nvim finds them via `parser/*.so` on the runtimepath, and lazy.nvim has
    -- the plugin directory on the runtimepath regardless of this setting.
    local parser_install_dir = nil
    if vim.env.NVIM_CONTAINER == "1" then
      parser_install_dir = vim.fn.stdpath("state") .. "/treesitter"
      vim.fn.mkdir(parser_install_dir, "p")
      vim.opt.runtimepath:append(parser_install_dir)
    end

    -- Configure treesitter
    treesitter.setup({
      -- nil on a normal workstation run, so upstream's default is used
      parser_install_dir = parser_install_dir,

      -- =============================================================================
      -- Syntax Highlighting
      -- =============================================================================
      highlight = {
        enable = true,  -- Enable syntax highlighting
        -- Bail on very large buffers: TS highlight parsing on huge files is a
        -- perf cliff with no escape hatch. Master API: disable(lang, bufnr)
        -- where a truthy return disables the module for that buffer.
        disable = function(_, bufnr)
          local ok, line_count = pcall(vim.api.nvim_buf_line_count, bufnr)
          if not ok then
            return false
          end
          if line_count > 20000 then
            return true
          end
          -- End offset of one-past-last line ≈ total byte size of the buffer.
          local ok2, bytes = pcall(vim.api.nvim_buf_get_offset, bufnr, line_count)
          if ok2 and bytes and bytes > 1.5 * 1024 * 1024 then
            return true
          end
          return false
        end,
      },

      -- =============================================================================
      -- Indentation
      -- =============================================================================
      -- Enable tree-sitter based indentation
      -- Disable for markdown: list indentation is handled by
      -- lua/andrew/utils/list-continuation.lua, and TS indent is a
      -- per-keystroke perf offender.
      indent = { enable = true, disable = { "markdown", "markdown_inline" } },

      -- =============================================================================
      -- Languages to Parse
      -- =============================================================================
      -- These languages will have syntax parsers installed and maintained.
      --
      -- Emptied under a read-only image: the parsers are already compiled into
      -- it at build time and load from the plugin directory via the
      -- runtimepath. Left as-is, nvim-treesitter sees the (deliberately
      -- relocated, empty) install dir and recompiles all 23 on first launch --
      -- which needs network and a C compiler, neither of which an air-gapped
      -- compute node has.
      ensure_installed = vim.env.NVIM_CONTAINER == "1" and {} or {
        -- Data formats
        "json",
        "yaml",
        "markdown",
        "markdown_inline",

        -- Web development
        "javascript",
        "typescript",
        "tsx",
        "html",
        "css",
        "vue",

        -- Shell and configuration
        "bash",
        "dockerfile",
        "gitignore",

        -- Programming languages
        "lua",
        "vim",
        "rust",
        "c",
        "fortran",
        "python",
        "latex",

        -- Neovim-specific
        "query",      -- Tree-sitter query language
        "vimdoc",     -- Vim help file syntax
        "regex",      -- Search-prompt highlighting in the noice cmdline
      },

      -- =============================================================================
      -- Incremental Selection
      -- =============================================================================
      -- Enable selection of syntax nodes with keybindings
      incremental_selection = {
        enable = true,

        -- Keybindings for selection navigation
        keymaps = {
          init_selection = "<C-space>",    -- Start selection
          node_incremental = "<C-space>",  -- Select next node
          scope_incremental = false,       -- Disable scope selection
          node_decremental = "<bs>",       -- Select previous node (backspace)
        },
      },
    })
  end,
}
