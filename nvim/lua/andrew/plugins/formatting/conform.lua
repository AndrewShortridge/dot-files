-- =============================================================================
-- Code Formatter Configuration (conform.nvim)
-- =============================================================================
-- Configures conform.nvim for automatic and manual code formatting.
-- Formatters are applied on save for supported file types.

return {
  -- Plugin: conform.nvim - Flexible formatter plugin for Neovim
  -- Repository: https://github.com/stevearc/conform.nvim
  "stevearc/conform.nvim",

  -- Load just before the first save so the format autocmd is registered
  -- without paying the startup cost (matches the BufWritePre the config wires up)
  event = { "BufWritePre" },

  -- Expose ConformInfo command for debugging
  cmd = { "ConformInfo" },

  -- =============================================================================
  -- Manual formatting keys (LazyVim <leader>cf / <leader>cF)
  -- =============================================================================
  -- There was no format keymap at all before this -- vim.lsp.buf.format is never
  -- called anywhere in the config and conform only ran on write, so a buffer
  -- could not be formatted on demand or formatted at all once <leader>uf turned
  -- format-on-save off.
  --
  -- <leader>cf deliberately does NOT consult the autoformat gate: it is the
  -- "force" path, matching LazyVim.format({ force = true }).
  keys = {
    {
      "<leader>cf",
      function()
        require("conform").format({ async = false, lsp_fallback = true, timeout_ms = 3000 })
      end,
      mode = { "n", "x" },
      desc = "Format",
    },
    {
      "<leader>cF",
      function()
        -- Formats fenced code blocks inside markdown/docs using each block's
        -- own language formatter.
        require("conform").format({ formatters = { "injected" }, timeout_ms = 3000 })
      end,
      mode = { "n", "x" },
      desc = "Format Injected Langs",
    },
  },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    -- Load conform module
    local conform = require("conform")

    -- Prefer the conda-env copy of a formatter, fall back to a bare name that
    -- conform resolves on PATH.
    --
    -- The absolute $CONDA_PREFIX path is right on the workstation, where these
    -- come from the active env. It is WRONG anywhere CONDA_PREFIX is unset --
    -- notably the Apptainer image, where `expand()` yields "/bin/fprettify" and
    -- conform then fails silently, so Fortran files just never got formatted.
    local function conda_bin(name)
      local prefix = vim.env.CONDA_PREFIX
      if prefix and prefix ~= "" then
        local path = prefix .. "/bin/" .. name
        if vim.fn.executable(path) == 1 then
          return path
        end
      end
      return name
    end

    local conda_prettier = conda_bin("prettier")
    local conda_fprettify = conda_bin("fprettify")

    -- Configure conform with formatters and options
    conform.setup({
      -- =============================================================================
      -- Auto-format on Save
      -- =============================================================================
      -- Gated on the autoformat toggle (<leader>uf global / <leader>uF buffer).
      -- Returning nil skips formatting for this write; returning the opts table
      -- is what the old static table did unconditionally.
      format_on_save = function(bufnr)
        if not require("andrew.utils.autoformat").enabled(bufnr) then
          return
        end
        return {
          -- Timeout for formatting (1 second)
          timeout_ms = 1000,

          -- Fallback to LSP formatting if no formatter available
          lsp_fallback = true,
        }
      end,

      -- =============================================================================
      -- Formatter Definitions
      -- =============================================================================
      -- Each formatter specifies the command and arguments for formatting

      formatters = {
        -- stylua: Lua formatter (from conda)
        stylua = {
          command = "stylua",
          args = {
            "--search-parent-directories",  -- Look for stylua.toml config
            "--stdin-filepath",             -- Read file path from stdin
            "$FILENAME",                    -- Pass filename as argument
            "-",                             -- Read from stdin
          },
          stdin = true,  -- Accept input via stdin
        },

        -- ruff format: Python formatter (from conda)
        ruff_format = {
          command = "ruff",
          args = {
            "format",              -- Run formatter
            "--stdin-filename", "$FILENAME",
            "-",                   -- Read from stdin
          },
          stdin = true,
        },

        -- prettier: JavaScript/TypeScript/JSON/YAML/etc formatter
        prettier = {
          command = conda_prettier,
          args = { "--stdin-filepath", "$FILENAME" },
          stdin = true,
        },

        -- fprettify: Fortran formatter (from conda)
        fprettify = {
          command = conda_fprettify,
          args = { "--indent=2", "--whitespace=2", "-" },
          stdin = true,
        },

        -- Used by <leader>cF. ignore_errors keeps one unformattable fenced
        -- block from aborting the whole document (LazyVim sets the same).
        injected = { options = { ignore_errors = true } },
      },

      -- =============================================================================
      -- Formatter Mapping by File Type
      -- =============================================================================
      -- Maps file types to their appropriate formatters

      formatters_by_ft = {
        -- Lua files use stylua
        lua = { "stylua" },

        -- Note: Rust formatting is handled by rustaceanvim/rust-analyzer

        -- Python files use ruff format
        python = { "ruff_format" },

        -- JavaScript/TypeScript files use prettier
        javascript = { "prettier" },
        javascriptreact = { "prettier" },
        typescript = { "prettier" },
        typescriptreact = { "prettier" },

        -- Vue, CSS, HTML use prettier
        vue = { "prettier" },
        css = { "prettier" },
        scss = { "prettier" },
        html = { "prettier" },

        -- Configuration files use prettier
        json = { "prettier" },
        yaml = { "prettier" },
        markdown = { "prettier" },

        -- Fortran files use fprettify
        fortran = { "fprettify" },
      },
    })

    -- =============================================================================
    -- Format on Save
    -- =============================================================================
    -- Handled entirely by conform's own BufWritePre autocmd, installed from the
    -- `format_on_save` option above with pattern "*".
    --
    -- There used to be a SECOND BufWritePre autocmd here (augroup ConformFormat)
    -- with a hand-maintained pattern list. It was pure cost: the list was a
    -- strict subset of conform's "*" so it added no coverage (it even missed
    -- *.vue, which formatters_by_ft handles), and because conform registers its
    -- autocmd first and runs synchronously, conform's pass was always the one
    -- that reached disk. The second pass spawned another formatter process whose
    -- output landed in the buffer AFTER the write -- invisible while formatters
    -- are idempotent, and a buffer left dirty with content differing from disk
    -- when they are not. Removed; every filetype it listed is still formatted.
  end,
}
