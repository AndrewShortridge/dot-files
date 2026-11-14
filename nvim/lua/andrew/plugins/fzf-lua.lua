-- =============================================================================
-- Fuzzy Finder Configuration (fzf-lua)
-- =============================================================================
-- Configures fzf-lua for fuzzy finding files, grep results, buffers, and more.
-- Uses fzf as the underlying fuzzy matching engine.

return {
  -- Plugin: fzf-lua - A modern replacement for Telescope
  -- Repository: https://github.com/ibhagwan/fzf-lua
  "ibhagwan/fzf-lua",

  -- Plugin dependencies
  dependencies = {
    "nvim-tree/nvim-web-devicons",  -- File type icons in results
    "nvim-lua/plenary.nvim",         -- Utility functions
    "folke/todo-comments.nvim",      -- TODO comment integration
  },

  -- Load plugin when FzfLua command or keys are used
  cmd = "FzfLua",

  -- =============================================================================
  -- Keybindings
  -- =============================================================================
  -- All fzf-lua commands are prefixed with <leader>f

  keys = {
    -- File operations
    --
    -- <leader>ff is NOT declared here any more: it moved to core/keymaps.lua,
    -- beside <leader><space>, and both go through andrew.utils.file_picker,
    -- which chooses between this plugin's `files()` and the snacks picker. A
    -- lazy.nvim key on this spec would load fzf-lua on every first press, even
    -- when the snacks picker is the one opening. The `files = { ... }` setup
    -- below is unchanged and drives the fzf backend.
    {
      "<leader>fr",
      function()
        require("fzf-lua").oldfiles()
      end,
      desc = "Fuzzy find recently opened files",
    },

    -- Vault file search (frecency-sorted)
    {
      "<leader>vff",
      function()
        require("andrew.vault.frecency").files()
      end,
      desc = "Vault: find files (frecency)",
    },

    -- Search operations
    {
      "<leader>fs",
      function()
        require("fzf-lua").live_grep(require("andrew.utils.obsidian").picker_opts())
      end,
      desc = "Live grep: find string in current directory",
    },
    {
      "<leader>fc",
      function()
        require("fzf-lua").grep_cword(require("andrew.utils.obsidian").picker_opts())
      end,
      desc = "Grep current word: find string under cursor",
    },

    -- Command pickers (mirrors LazyVim's <leader>sc / <leader>sC)
    {
      "<leader>sc",
      function()
        require("fzf-lua").command_history()
      end,
      desc = "Command history: re-run a previously typed : command",
    },
    {
      "<leader>sC",
      function()
        require("fzf-lua").commands()
      end,
      desc = "Commands: fuzzy find any Ex command and run it",
    },

    -- Help and keymaps
    {
      "<leader>fk",
      function()
        require("fzf-lua").keymaps()
      end,
      desc = "Fuzzy find keybindings",
    },
    {
      "<leader>fh",
      function()
        require("fzf-lua").help_tags()
      end,
      desc = "Search Neovim :help tags",
    },

    -- Advanced search: grep through Neovim documentation
    {
      "<leader>fH",
      function()
        local fzf = require("fzf-lua")
        local doc_paths = vim.api.nvim_get_runtime_file("doc", true)

        fzf.live_grep(require("andrew.utils.fzf_look").titled("Help Grep", {
          search_paths = doc_paths,
          rg_glob = "--glob='*.txt'",
        }))
      end,
      desc = "Grep Neovim :help documentation",
    },

    -- TODO comments search
    { "<leader>ft", "<cmd>TodoFzfLua<cr>", desc = "Find TODO/FIXME comments" },

    -- =============================================================================
    -- LazyVim Search Group (<leader>s)
    -- =============================================================================
    -- Ported from LazyVim's fzf-lua extra (lazyvim/plugins/extras/editor/fzf.lua).
    -- Keys, modes and descriptions are kept exactly as LazyVim defines them.
    --
    -- The "(Root Dir)" variants anchor the grep to the detected project root
    -- (LSP workspace -> nearest .git/lua ancestor -> cwd) the same way <leader>/
    -- does; the "(cwd)" variants are LazyVim's `root = false` and simply let
    -- fzf-lua default to the working directory. Both run through
    -- obsidian.with_picker_opts so the vault's search exclusions still apply --
    -- LazyVim's own LazyVim.pick() has no such concept, and skipping it here
    -- would make these the only greps that dump .obsidian/Templates into results.

    -- Word under cursor, project-root scoped
    {
      "<leader>sw",
      function()
        require("fzf-lua").grep_cword(require("andrew.utils.obsidian").with_picker_opts({
          cwd = require("andrew.utils.root").get(),
        }))
      end,
      desc = "Word (Root Dir)",
    },

    -- Word under cursor, cwd scoped
    {
      "<leader>sW",
      function()
        require("fzf-lua").grep_cword(require("andrew.utils.obsidian").picker_opts())
      end,
      desc = "Word (cwd)",
    },

    -- Visual selection, project-root scoped
    {
      "<leader>sw",
      function()
        require("fzf-lua").grep_visual(require("andrew.utils.obsidian").with_picker_opts({
          cwd = require("andrew.utils.root").get(),
        }))
      end,
      mode = "x",
      desc = "Selection (Root Dir)",
    },

    -- Visual selection, cwd scoped
    {
      "<leader>sW",
      function()
        require("fzf-lua").grep_visual(require("andrew.utils.obsidian").picker_opts())
      end,
      mode = "x",
      desc = "Selection (cwd)",
    },

    -- Search history: re-run a previously typed / search
    { "<leader>s/", "<cmd>FzfLua search_history<cr>", desc = "Search History" },

    -- Diagnostics. Note the pairing is LazyVim's: lowercase is workspace-wide,
    -- uppercase is the current buffer -- the inverse of the sw/sW scoping above.
    -- These overlap in purpose with the Trouble views on <leader>xw / <leader>xd,
    -- which is also true in LazyVim; they are a fuzzy picker rather than a list.
    { "<leader>sd", "<cmd>FzfLua diagnostics_workspace<cr>", desc = "Diagnostics" },
    { "<leader>sD", "<cmd>FzfLua diagnostics_document<cr>", desc = "Buffer Diagnostics" },
  },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    -- Import modules
    -- `fd` ships as `fdfind` on Debian/Ubuntu (the name clashes with fdclone
    -- there) and as `fd` everywhere else -- including the conda-forge build
    -- inside the Apptainer image. Hardcoding either name makes the file picker
    -- silently return NOTHING on the other platform, with no error: fzf-lua
    -- just runs a command that does not exist. Resolve it instead; nil falls
    -- back to fzf-lua's own detection (rg --files, then find).
    -- Mirrors andrew.vault.engine.fd_bin(), kept local to avoid pulling the
    -- vault engine into the picker's load path.
    local fd_bin = vim.fn.executable("fd") == 1 and "fd"
      or vim.fn.executable("fdfind") == 1 and "fdfind"
      or nil

    local fzf_config = require("fzf-lua.config")
    local trouble_open = require("trouble.sources.fzf").actions.open
    local fzf = require("fzf-lua")
    local actions = require("fzf-lua.actions")

    -- =============================================================================
    -- Trouble Integration
    -- =============================================================================
    -- Press Ctrl-t inside fzf-lua to open results in Trouble.
    -- `.actions` is a TABLE of actions ({ open = ... }); only `.open` is the
    -- callable action, so the whole table must not be assigned here (it used to
    -- be, which is why the integration never worked).
    --
    -- This is trouble.nvim's documented hook, kept for pickers that fall back to
    -- fzf-lua's own defaults -- but it is NOT sufficient on its own here: a
    -- user-supplied `actions.files` in setup() REPLACES defaults.actions.files
    -- wholesale during normalize_opts, so the same binding is repeated in the
    -- setup block below.
    fzf_config.defaults.actions.files["ctrl-t"] = trouble_open

    -- =============================================================================
    -- Setup fzf-lua
    -- =============================================================================
    -- Two layers. The table written out below is this config's own fzf-lua
    -- configuration: what to list, how to grep, which keys do what. Over it
    -- goes the LOOK shared by every picker (andrew.utils.fzf_look: the snacks
    -- picker's layout, the `telescope` profile's colours and preview paging),
    -- deep-merged with "force" so that where both set a key the look wins.
    -- The one value that changes is `winopts.height`; the rest of the look
    -- either repeats what is written here or adds keys that are not.
    fzf.setup(vim.tbl_deep_extend("force", {
      -- =============================================================================
      -- Git Hunks: row parser
      -- =============================================================================
      -- fzf-lua's own parser raises on a hunk header without a line count
      -- (`@@ -1 +1,2 @@`), which empties the whole `git_hunks` picker
      -- (<leader>gd) as soon as one short file is among the changes. See
      -- andrew/utils/fzf_git_hunks.lua. `multiprocess = false` because the
      -- replacement lives in this config, which fzf-lua's headless helper
      -- process does not load.
      git = {
        hunks = {
          fn_transform = [[return require("andrew.utils.fzf_git_hunks").to_entry]],
          multiprocess = false,
        },
      },

      -- =============================================================================
      -- File Finder Configuration
      -- =============================================================================
      files = {
        -- Use fd for finding files (binary name resolved above)
        -- --type f: search files only (not directories)
        -- --hidden: include hidden files
        -- --exclude .git: ignore .git directory
        -- --exclude .obsidian: ignore Obsidian's own config folder. Unconditional
        --   because that directory exists nowhere but inside an Obsidian vault, so
        --   the flag is a no-op in every other project. Without it --hidden pulls
        --   ~100 JSON/CSS/JS files into the picker whenever you are in the vault.
        --   The templates folder cannot be excluded here -- "Templates" is an
        --   ordinary directory name -- so it is handled per-call by
        --   andrew.utils.obsidian, which only fires inside a vault.
        cmd = fd_bin and (fd_bin .. " --type f --hidden --exclude .git --exclude .obsidian") or nil,
      },

      -- =============================================================================
      -- Grep Configuration
      -- =============================================================================
      grep = {
        -- Ripgrep options for consistent output.
        --
        -- --hidden plus the two globs give grep the same file set as the file
        -- finder above (`fd --hidden --exclude .git --exclude .obsidian`), so a
        -- dotfile that can be opened by name can also be searched. The globs
        -- matter only because of --hidden: without them rg would walk .git/
        -- (objects, packed refs) and Obsidian's config folder. .gitignore is
        -- still respected.
        --
        -- The flag is spelled out here rather than set as `grep.hidden = true`
        -- on purpose. That option applies to EVERY grep, including the vault
        -- pickers that pass their own rg_opts (vault/engine.lua rg_base_opts),
        -- which would start returning notes from `.trash/`. Kept in rg_opts,
        -- it reaches only the callers that use these defaults -- and the one
        -- vault grep that does, vault/search.lua's M.search(), opts back out
        -- with `hidden = false`.
        rg_opts = table.concat({
          "--color=never",      -- No ANSI colors in output
          "--no-heading",       -- Don't group by file
          "--with-filename",    -- Show filename in results
          "--line-number",      -- Show line numbers
          "--column",           -- Show column numbers
          "--smart-case",       -- Case-insensitive unless uppercase in query
          "--hidden",           -- Search dotfiles and dot-directories
          '--glob "!.git"',     -- ...but never the git directory
          '--glob "!.obsidian"', -- ...nor Obsidian's config folder
          "-e",                 -- Next arg is the pattern (prevents -pattern misparse)
        }, " "),
      },

      -- =============================================================================
      -- Window Options
      -- =============================================================================
      winopts = {
        -- Window dimensions (fraction of editor)
        height = 0.85,  -- 85% of editor height; the look lowers this to 80%
        width = 0.80,   -- 80% of editor width

        -- Preview window configuration
        preview = {
          layout = "flex",  -- Auto-adjust preview size
        },
      },

      -- =============================================================================
      -- Keybindings Inside fzf Window
      -- =============================================================================
      -- The look adds <C-d> / <C-u> (page the preview) to both tables.
      keymap = {
        builtin = {
          ["<C-n>"] = "down",
          ["<C-p>"] = "up",
          ["<C-j>"] = "preview-down",
          ["<C-k>"] = "preview-up",
        },
        fzf = {
          ["ctrl-n"] = "down",
          ["ctrl-p"] = "up",
          ["ctrl-j"] = "preview-down",
          ["ctrl-k"] = "preview-up",
          ["ctrl-q"] = "select-all+accept",
        },
      },

      -- =============================================================================
      -- Default Actions
      -- =============================================================================
      actions = {
        -- Actions for file pickers
        files = {
          ["default"] = actions.file_edit,   -- Open in current window
          ["ctrl-s"] = actions.file_split,   -- Open in horizontal split
          ["ctrl-v"] = actions.file_vsplit,  -- Open in vertical split
          ["ctrl-t"] = trouble_open,         -- Send results to Trouble
          ["ctrl-q"] = actions.file_sel_to_qf,  -- Send to quickfix list
        },

        -- Actions for buffer pickers
        buffers = {
          ["default"] = actions.buf_edit,    -- Switch to buffer
          ["ctrl-s"] = actions.buf_split,    -- Split and show buffer
          ["ctrl-v"] = actions.buf_vsplit,   -- Vsplit and show buffer
          ["ctrl-t"] = actions.buf_tabedit,  -- Show buffer in new tab
        },
      },
    }, require("andrew.utils.fzf_look").setup_opts()))
  end,
}
