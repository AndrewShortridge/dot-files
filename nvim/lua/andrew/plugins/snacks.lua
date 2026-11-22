-- =============================================================================
-- Snacks.nvim Configuration
-- =============================================================================
-- Utility collection by folke. Modules are opt-in.
-- Currently enabled: dashboard (the start screen of a bare `nvim`), input +
-- picker.ui_select (the vim.ui.input / vim.ui.select backends, replacing the
-- archived dressing.nvim), image (inline rendering).

-- Set SNACKS_KITTY before ANY Snacks code loads.
-- This must happen at parse time (not in init/config) because Snacks modules
-- may be accessed by other plugins during startup, triggering env() caching
-- before init() runs. The env var causes snacks terminal.env() to force-detect
-- Kitty regardless of DA3 async state.
if not os.getenv("SNACKS_KITTY") then
  if os.getenv("KITTY_WINDOW_ID") or os.getenv("KITTY_PID") then
    vim.env.SNACKS_KITTY = "1"
  end
end

return {
  "folke/snacks.nvim",
  priority = 1000,
  lazy = false,

  init = function()
    -- Safety net: if env() was somehow cached before the env var was set,
    -- invalidate the cache so the next access re-evaluates. This handles
    -- edge cases where another plugin's init() accessed Snacks.image before
    -- this spec was parsed.
    if vim.env.SNACKS_KITTY == "1" and Snacks and Snacks.image and Snacks.image.terminal then
      local term = Snacks.image.terminal
      if term._env and not term._env.placeholders then
        -- Cache was poisoned — clear it so next env() call picks up SNACKS_KITTY
        term._env = nil
      end
    end
  end,

  ---@type snacks.Config
  opts = {
    -- =======================================================================
    -- Start screen: what a bare `nvim` opens on
    -- =======================================================================
    -- The dashboard LazyVim ships (and Omarchy's Neovim, which is LazyVim):
    -- header, a column of single-key actions, the plugin load time. Snacks
    -- opens it on UIEnter and only when Neovim started with nothing to show --
    -- no file or directory argument, no piped stdin, an empty first buffer
    -- (snacks/dashboard.lua, M.setup). `nvim file`, `nvim .` and
    -- `git commit` never see it. `:lua Snacks.dashboard()` reopens it.
    --
    -- The header is snacks' own "NEOVIM"; LazyVim's spells "LAZYVIM", which
    -- this config is not.
    --
    -- Only `keys` is set: every action is the one this config already has on
    -- a <leader> key, so the two cannot drift. Snacks' stock actions would
    -- not be: `Snacks.dashboard.pick()` prefers the snacks picker whenever it
    -- is enabled, and it is (for vim.ui.select), while the pickers here are
    -- fzf-lua's. A string that does not start with `:` is fed as keys.
    --
    -- While it is up snacks sets 'showtabline' and 'laststatus' to 0 and puts
    -- them back when it closes. lualine loads later (VeryLazy) and would set
    -- 'laststatus' again, so the dashboard filetype is in its
    -- `disabled_filetypes` (plugins/lualine.lua).
    dashboard = {
      enabled = true,
      preset = {
        -- stylua: ignore
        keys = {
          { icon = " ", key = "f", desc = "Find File", action = "<leader>ff" },
          { icon = " ", key = "n", desc = "New File", action = ":ene | startinsert" },
          { icon = " ", key = "g", desc = "Find Text", action = "<leader>fs" },
          { icon = " ", key = "r", desc = "Recent Files", action = "<leader>fr" },
          {
            icon = " ",
            key = "c",
            desc = "Config",
            action = function()
              require("andrew.utils.file_picker").find_files(vim.fn.stdpath("config"))
            end,
          },
          -- Resolves to persistence.nvim's load(), i.e. <leader>qs.
          { icon = " ", key = "s", desc = "Restore Session", section = "session" },
          { icon = "󰒲 ", key = "l", desc = "Lazy", action = ":Lazy" },
          { icon = " ", key = "q", desc = "Quit", action = ":qa" },
        },
      },
    },

    -- The dashboard does not fill its window, and the rows below it would
    -- show the `~` end-of-buffer markers. Local to the dashboard's window;
    -- the file that replaces it gets the global 'fillchars' back.
    styles = {
      dashboard = {
        wo = { fillchars = "eob: " },
      },
    },

    -- =======================================================================
    -- vim.ui.input  (was dressing.nvim)
    -- =======================================================================
    -- dressing.nvim is archived upstream and still calls the REMOVED
    -- `vim.validate{ <table> }` form on every vim.ui.input / vim.ui.select,
    -- which is a deprecation now and a hard error at nvim 1.0. It also loaded
    -- on VeryLazy -- i.e. AFTER this spec's setup() -- so it silently stole
    -- vim.ui.input back from snacks and `:checkhealth snacks` reported
    -- "`vim.ui.input` is not set to `Snacks.input`". Deleting the dressing spec
    -- hands both handlers to snacks for good.
    --
    -- The one behavioural gap: snacks' own `input` style maps insert-mode <Esc>
    -- to `stopinsert` (so you land in normal mode and need a SECOND <Esc>/`q`
    -- to abort), while dressing cancelled on the first <Esc>. Every caller in
    -- this config -- vault prompts, the markdown URL/table/callout prompts,
    -- `vim.lsp.buf.rename` -- is written for "one <Esc> means cancel, callback
    -- gets nil", so i_esc is re-pointed at `cancel`. `cmp_close` stays first in
    -- the list so an open blink/completion popup is dismissed by the first
    -- <Esc> instead of throwing the prompt away.
    input = {
      enabled = true,
      win = {
        keys = {
          i_esc = { "<esc>", { "cmp_close", "cancel" }, mode = "i", expr = true },
        },
      },
    },

    -- =======================================================================
    -- Picker: vim.ui.select (was dressing.nvim) + the file finder
    -- =======================================================================
    -- fzf-lua stays the config's main interactive picker (grep/LSP/colorschemes
    -- and the fortran Makefile picker all call fzf-lua directly, and
    -- lsp_keymaps.lua's <leader>ca uses fzf-lua's own temporary ui_select).
    -- The snacks picker is used for two things: vim.ui.select (`ui_select`)
    -- and the "snacks" backend of the file finder on <leader>ff /
    -- <leader><space> (andrew/utils/file_picker.lua). The git pickers in
    -- plugins/git.lua are fzf-lua pickers.
    --
    -- snacks.picker.setup() does nothing except `vim.ui.select = Snacks.picker.select`
    -- (snacks/picker/init.lua:92-96) -- no keymaps, no user commands -- so
    -- enabling it displaces fzf-lua nowhere by itself.
    -- `format_item` is honoured via Snacks.picker.format.ui_select, and
    -- `opts.kind` selects a `kinds[<kind>]` override table (none needed here;
    -- snacks already special-cases kind == "codeaction" in its formatter).
    picker = {
      enabled = true,
      ui_select = true,

      -- See the module for why the box title cannot be coloured with a
      -- highlight group alone.
      on_show = function(picker)
        require("andrew.utils.snacks_look").style_box_titles(picker)
      end,

      -- dressing delegated vim.ui.select to fzf-lua here (fzf-lua was the
      -- highest-priority backend installed), where ONE <Esc> aborts. The snacks
      -- picker starts in insert mode and maps <Esc> to `cancel` in NORMAL mode
      -- only (snacks/picker/config/defaults.lua:233), so the first <Esc> merely
      -- left insert mode and a second was needed. Scoped to the `select` source
      -- so that this only affects vim.ui.select -- the real snacks pickers
      -- (files, git) keep snacks' own two-stage <Esc>.
      sources = {
        select = {
          win = {
            input = {
              keys = {
                ["<Esc>"] = { "cancel", mode = { "n", "i" } },
              },
            },
          },
        },

        -- File finder, as in craftzdog's dotfiles: the stock picker plus
        -- `hidden = true`, so dotfiles are listed. .gitignore is still
        -- respected and snacks always skips .git.
        --
        -- `exclude` is this config's addition, mirroring the `--exclude
        -- .obsidian` on fzf-lua's fd command (plugins/fzf-lua.lua): with hidden
        -- files on, Obsidian's config folder would otherwise add ~100
        -- JSON/CSS/JS files whenever the cwd is the vault. The folder exists
        -- nowhere else, so it is a no-op in every other project.
        files = {
          hidden = true,
          exclude = { ".obsidian" },
        },

        -- The GitHub pickers (<leader>gi / gI / gp / gP in plugins/git.lua)
        -- and the diff picker they open: <C-d> / <C-u> page the preview, as
        -- in every fzf-lua picker. Their colours come from the same module,
        -- applied in config() below.
        gh_issue = require("andrew.utils.snacks_look").preview_paging_opts(),
        gh_pr = require("andrew.utils.snacks_look").preview_paging_opts(),
        gh_diff = require("andrew.utils.snacks_look").preview_paging_opts(),
      },
    },

    -- Smooth (animated) scrolling is OFF by default -- a deliberate divergence
    -- from LazyVim, which ships `scroll = { enabled = true }`. <leader>uS
    -- (Snacks.toggle.scroll, below) calls Snacks.scroll.enable() directly, so
    -- it still turns the animation on for a session.
    --
    -- `animate` stays enabled: dim still consumes it, and scroll does when
    -- toggled on -- both are gated behind vim.g.snacks_animate (<leader>ua).
    --
    -- The speed is spelled out below so it can be tuned here; the values are
    -- snacks' own defaults (snacks/scroll.lua:28-38), which are also LazyVim's
    -- speed. Lower numbers are faster. The top-level `animate` table is left
    -- bare: it contributes fps=120 (snacks/animate/init.lua:33).
    animate = { enabled = true },
    scroll = {
      enabled = false,
      -- A single scroll: `step` ms per line scrolled, capped at `total` ms
      -- for the whole animation.
      animate = {
        duration = { step = 2, total = 200 },
        easing = "linear",
      },
      -- A scroll repeated within `delay` ms of the previous one (held <C-d>,
      -- mouse wheel) uses this faster profile instead.
      animate_repeat = {
        delay = 100,
        duration = { step = 5, total = 50 },
        easing = "linear",
      },
    },

    -- Scratch buffer (toggled via <leader>. in core/keymaps.lua)
    scratch = { enabled = true },

    -- LSP reference tracking. Powers the ]] / [[ / <a-n> / <a-p> reference
    -- jumps bound (gated on textDocument/documentHighlight) in
    -- andrew.lsp_keymaps. This module sets needs_setup, so WITHOUT this
    -- line Snacks.words.jump() is a silent no-op -- it places no extmarks, and
    -- jump() returns immediately when the cursor is not on a known reference,
    -- so the keys would appear bound and simply do nothing.
    words = { enabled = true },

    -- Lazygit float (<leader>gg / <leader>gG in plugins/git.lua). Both settings
    -- come from craftzdog's dotfiles. Only the differences from snacks' defaults
    -- are listed: `configure = true` and `os.editPreset = "nvim-remote"` stay,
    -- and `os.edit` / `os.editAtLine` take precedence over the preset's own.
    lazygit = {
      config = {
        -- `e` on a file opens it in the window lazygit was launched from,
        -- instead of the preset's new tab. See andrew/utils/lazygit.lua.
        os = {
          edit = require("andrew.utils.lazygit").edit_command(),
          editAtLine = require("andrew.utils.lazygit").edit_command({ at_line = true }),
        },
      },
      -- Active panel border; snacks' default is MatchParen.
      -- snacks declares every snacks.lazygit.Theme colour required, but the
      -- table is merged over its default theme (Snacks.config.get).
      ---@diagnostic disable-next-line: missing-fields
      theme = {
        activeBorderColor = { fg = "WarningMsg", bold = true },
      },
    },

    -- Inline image rendering in markdown buffers
    image = {
      enabled = true,

      -- Force rendering: Kitty terminal supports the graphics protocol
      -- but $TERM may report as xterm-256color, causing detection to fail.
      force = true,

      -- Add SVG to supported formats (not in snacks defaults, requires magick)
      formats = {
        "png",
        "jpg",
        "jpeg",
        "gif",
        "bmp",
        "webp",
        "tiff",
        "heic",
        "avif",
        "svg",
        "mp4",
        "mov",
        "avi",
        "mkv",
        "webm",
        "pdf",
        "icns",
      },

      doc = {
        enabled = true,
        -- Render images inline in the buffer (Kitty/Ghostty required)
        inline = true,
        -- Fallback: show images in floating windows on CursorMoved
        float = true,
        max_width = 80,
        max_height = 40,
        -- Only conceal math expressions, keep image paths visible for editing
        conceal = function(_, type)
          return type == "math"
        end,
      },

      -- Directories to search for images (relative to buffer or vault root)
      -- "attachments" matches the vault's image storage convention
      img_dirs = { "attachments", "assets", "images", "img", "media", "static", "public" },

      -- Resolve image paths for the Obsidian vault structure.
      -- Images are stored at <vault_root>/attachments/ but notes live in
      -- subdirectories, so relative paths need vault-root resolution.
      resolve = function(file, src)
        -- Skip Obsidian block refs (^blk-xxx) and heading refs (#Heading)
        -- that treesitter may misidentify as image sources.
        if src:match("^%^") or src:match("^#") or not src:match("%.%w+$") then
          return src -- return as-is; snacks will fail gracefully
        end

        -- Absolute paths and URLs pass through
        if src:match("^/") or src:match("^https?://") then
          return src
        end

        -- First try: resolve relative to the buffer's directory (default behavior)
        local buf_dir = vim.fs.dirname(file)
        local candidate = buf_dir .. "/" .. src
        if vim.uv.fs_stat(candidate) then
          return candidate
        end

        -- Second try: walk up to find the vault root (.obsidian dir) and
        -- resolve relative to it. This handles the common case where
        -- attachments/ lives at the vault root.
        local obsidian_dirs = vim.fs.find(".obsidian", {
          path = buf_dir,
          upward = true,
          type = "directory",
        })
        if obsidian_dirs[1] then
          local vault_root = vim.fs.dirname(obsidian_dirs[1])
          candidate = vault_root .. "/" .. src
          if vim.uv.fs_stat(candidate) then
            return candidate
          end

          -- Third try: search common image directories at vault root.
          -- Handles wikilink embeds like ![[image.png]] where the file
          -- lives in <vault_root>/attachments/image.png.
          for _, dir in ipairs({
            "attachments",
            "assets",
            "images",
            "img",
            "media",
            "static",
            "public",
          }) do
            candidate = vault_root .. "/" .. dir .. "/" .. src
            if vim.uv.fs_stat(candidate) then
              return candidate
            end
          end
        end

        -- Fall through to snacks default resolution
        return nil
      end,

      -- LaTeX math ($...$, $$...$$, ```math fences) rendered as real typeset
      -- inline images via the kitty graphics protocol. Needs `pdflatex` (or
      -- `tectonic`) for tex -> pdf and ImageMagick `convert`/`magick` for
      -- pdf -> png; `gs` is ImageMagick's PDF delegate. Check with
      -- :checkhealth snacks. render-markdown's own `latex` block is disabled
      -- in render-markdown.lua so each equation is not drawn twice.
      math = {
        enabled = true,

        latex = {
          -- Stock snacks uses `border=0pt`, which makes an equation with no
          -- typeset width (empty `$$ $$`, a half-typed `\hat{}`, an empty
          -- `align*`) compile to a PDF whose MediaBox is literally 0 wide.
          -- Ghostscript 10.02.1 refuses `/PageSize [0 h]` outright:
          --   Error: /undefined in --runpdf--
          -- convert then reports "no images defined" and snacks raises
          -- "Conversion failed at step `convert`". Since the LuaSnip `dm`/`mk`
          -- autosnippets (luasnippets/markdown.lua:1700-1710) insert both
          -- delimiters with an empty insert node between them, that empty
          -- state exists the instant the snippet expands, so the toast fires
          -- on every `$$`.
          --
          -- `border={0.75pt 0pt}` adds horizontal-only padding, so the page can
          -- never be 0 wide, and `-trim` (convert.magick.math) crops it back
          -- off. 0.75pt is deliberate: at the 192 dpi that convert.magick.math
          -- uses, 1px = 0.375pt, so 0.75pt is exactly 2px and the glyphs keep
          -- their pixel grid phase. A fractional-pixel border (plain `1pt` =
          -- 2.667px) renders identical dimensions but shifts antialiasing --
          -- measurably, `compare -metric AE` 497 / RMSE 8.6%. At 0.75pt the
          -- output for real equations is pixel-identical to stock (AE = 0),
          -- and degenerate equations yield a harmless 1x1 png instead of a
          -- failed job. Vertical border stays 0pt so nothing shifts there.
          -- Keep the rest of the template in sync with
          -- snacks/image/init.lua:156-164 on upgrade.
          tpl = [[
            \documentclass[preview,border={0.75pt 0pt},varwidth,12pt]{standalone}
            \usepackage{${packages}}
            \begin{document}
            ${header}
            { \${font_size} \selectfont
              \color[HTML]{${color}}
            ${content}}
            \end{document}]],
        },
      },

      convert = {
        notify = true,
      },
    },
  },

  config = function(_, opts)
    -- Inside tmux, snacks.image's terminal query came back as key input: a
    -- split tmux pane and `>|kitty(...)` typed into Neovim. Before setup(),
    -- so it is in place ahead of anything that asks.
    require("andrew.utils.snacks_tmux_terminal").setup()

    require("snacks").setup(opts)

    -- Colour snacks' pickers like the fzf-lua ones (andrew/utils/fzf_look.lua).
    require("andrew.utils.snacks_look").setup()

    -- Inline math: skip the equation under the cursor while it is being typed
    -- (otherwise every keystroke is a fresh pdflatex + convert job) and never
    -- re-run a conversion that already failed in an earlier session. Adds
    -- :SnacksImageRetryFailed. Rationale and pinned line refs in the module.
    require("andrew.utils.snacks-image-math").setup()

    -- =======================================================================
    -- Keep vim.ui.select snacks-owned after an ABORTED code action
    -- =======================================================================
    -- fzf-lua's `lsp_code_actions` (bound to <leader>ca in lsp_keymaps.lua)
    -- installs its OWN vim.ui.select for the duration of the call and only
    -- restores the previous handler from `post_action_cb`, i.e. when an action
    -- is actually APPLIED (fzf-lua providers/lsp.lua:968-973). Its self-healing
    -- path (providers/ui_select.lua:123) only covers the case where the picker
    -- never opened, because opening it clears `_OPTS_ONCE` (ui_select.lua:163).
    -- So dismissing the code-action picker with <Esc> left fzf-lua registered
    -- forever: the next vim.ui.select in the config -- :VaultSwitch, the
    -- markdown callout picker, a template picker -- rendered in fzf, still
    -- carrying the leftover "Code Actions" preview pane. Verified in a pty
    -- before this guard existed.
    --
    -- fzf-lua closes its window before anything else, and `deregister` restores
    -- whatever handler it displaced (so this only ever hands ownership BACK).
    -- Set `vim.g.fzf_lua_owns_ui_select = true` to opt out, e.g. after running
    -- `:FzfLua register_ui_select` on purpose.
    vim.api.nvim_create_autocmd("WinClosed", {
      group = vim.api.nvim_create_augroup("andrew_snacks_ui_select_owner", { clear = true }),
      desc = "Re-assert Snacks as the vim.ui.select owner after fzf-lua closes",
      callback = function(ev)
        if vim.g.fzf_lua_owns_ui_select then
          return
        end
        local win = tonumber(ev.match)
        if not win or not vim.api.nvim_win_is_valid(win) then
          return
        end
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype ~= "fzf" then
          return
        end
        vim.schedule(function()
          local ok, ui_select = pcall(require, "fzf-lua.providers.ui_select")
          if ok and ui_select.is_registered() then
            ui_select.deregister({}, true, true)
          end
        end)
      end,
    })

    -- =======================================================================
    -- UI / Toggle keymaps (<leader>u)
    -- =======================================================================
    -- Registered right after setup() so they exist regardless of VeryLazy.
    --
    -- Letters follow LazyVim (lazyvim/config/keymaps.lua:143-166) so its docs
    -- and videos match this config. Note ud/uD are DIAGNOSTICS/DIMMING, which
    -- is the reverse of what this config used before the alignment.
    --
    -- Snacks.toggle registers each key with which-key itself, including a
    -- live enabled/disabled icon and colour, so none of these need an entry in
    -- plugins/which-key.lua.
    Snacks.toggle.option("spell", { name = "Spelling" }):map("<leader>us")
    Snacks.toggle.option("wrap", { name = "Wrap" }):map("<leader>uw")
    Snacks.toggle.option("relativenumber", { name = "Relative Number" }):map("<leader>uL")
    Snacks.toggle.line_number():map("<leader>ul")
    Snacks.toggle.diagnostics():map("<leader>ud")
    Snacks.toggle
      .option("conceallevel", {
        off = 0,
        on = vim.o.conceallevel > 0 and vim.o.conceallevel or 2,
        name = "Conceal Level",
      })
      :map("<leader>uc")
    Snacks.toggle.treesitter():map("<leader>uT")
    Snacks.toggle.inlay_hints():map("<leader>uh")
    Snacks.toggle.dim():map("<leader>uD")
    Snacks.toggle.animate():map("<leader>ua")
    Snacks.toggle.scroll():map("<leader>uS")

    -- Format on save (LazyVim <leader>uf global / <leader>uF buffer-local).
    -- Snacks has no builtin format toggle, so these come from
    -- andrew.utils.autoformat, which is also what both format-on-save paths in
    -- plugins/formatting/conform.lua consult.
    require("andrew.utils.autoformat").snacks_toggle():map("<leader>uf")
    require("andrew.utils.autoformat").snacks_toggle(true):map("<leader>uF")

    -- Tabline. Nothing else manages 'showtabline' (andrew/utils/tabline.lua
    -- only sets 'tabline'); core/options.lua pins the visible value at 2.
    Snacks.toggle
      .option("showtabline", {
        off = 0,
        on = 2,
        global = true,
        name = "Tabline",
      })
      :map("<leader>uA")

    -- Indent guides (indent-blankline). Deliberately NOT `<cmd>IBLToggle<CR>`:
    -- the ibl spec declares only `ft`, no `cmd`, so lazy.nvim creates no
    -- command stub and that mapping threw E492 in any buffer where ibl had not
    -- loaded yet. `get` reads package.loaded rather than require()ing, so
    -- which-key can render this key's icon without dragging ibl in and undoing
    -- its filetype gate; `set` requires for real, since that is an explicit
    -- keypress.
    Snacks.toggle({
      name = "Indention Guides",
      get = function()
        local cfg = package.loaded["ibl.config"]
        if not cfg then
          return false -- not loaded here means no guides are drawn
        end
        return cfg.get_config(0).enabled
      end,
      set = function(state)
        require("ibl").setup_buffer(0, { enabled = state })
      end,
    }):map("<leader>ug")

    -- Zen mode (Snacks)
    vim.keymap.set("n", "<leader>uz", function()
      Snacks.zen()
    end, { desc = "Zen Mode" })

    -- Colorschemes picker (fzf-lua) -- applies on selection.
    vim.keymap.set("n", "<leader>uC", function()
      require("fzf-lua").colorschemes()
    end, { desc = "Colorschemes" })
  end,
}
