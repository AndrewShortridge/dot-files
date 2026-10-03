-- =============================================================================
-- Snacks.nvim Configuration
-- =============================================================================
-- Utility collection by folke. Modules are opt-in.
-- Currently enabled: input + picker.ui_select (the vim.ui.input / vim.ui.select
-- backends, replacing the archived dressing.nvim), image (inline rendering).

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
    if vim.env.SNACKS_KITTY == "1"
      and Snacks
      and Snacks.image
      and Snacks.image.terminal
    then
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
    -- vim.ui.select  (was dressing.nvim)
    -- =======================================================================
    -- `ui_select` is the ONLY reason the picker module is enabled: fzf-lua
    -- stays the config's interactive picker (files/grep/LSP/colorschemes and
    -- the fortran Makefile picker all call fzf-lua directly, and
    -- lsp_keymaps.lua's <leader>ca uses fzf-lua's own temporary ui_select).
    -- snacks.picker.setup() does nothing except `vim.ui.select = Snacks.picker.select`
    -- (snacks/picker/init.lua:92-96) -- no keymaps, no user commands -- so this
    -- adds a vim.ui.select backend without displacing fzf-lua anywhere.
    -- `format_item` is honoured via Snacks.picker.format.ui_select, and
    -- `opts.kind` selects a `kinds[<kind>]` override table (none needed here;
    -- snacks already special-cases kind == "codeaction" in its formatter).
    picker = {
      enabled = true,
      ui_select = true,

      -- dressing delegated vim.ui.select to fzf-lua here (fzf-lua was the
      -- highest-priority backend installed), where ONE <Esc> aborts. The snacks
      -- picker starts in insert mode and maps <Esc> to `cancel` in NORMAL mode
      -- only (snacks/picker/config/defaults.lua:233), so the first <Esc> merely
      -- left insert mode and a second was needed. Scoped to the `select` source
      -- so that this only affects vim.ui.select -- if a real snacks picker is
      -- ever enabled it keeps snacks' own two-stage <Esc>.
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
      },
    },

    -- Smooth scrolling (LazyVim parity). snacks.scroll animates window scroll
    -- via snacks.animate; both are gated behind vim.g.snacks_animate, which
    -- <leader>ua flips. Terminal buffers are excluded by scroll's own default
    -- filter. Enabling `animate` here is what gives <leader>ua something to
    -- turn off -- dim and scroll are its only consumers in this config.
    --
    -- Both are deliberately BARE. LazyVim passes `scroll = { enabled = true }`
    -- with no overrides (lazyvim/plugins/ui.lua:279) and no top-level `animate`
    -- table at all, so snacks' own defaults ARE the LazyVim scroll speed:
    -- 10ms/step capped at 200ms, linear; a scroll repeated within 100ms uses
    -- the faster 5ms/step, 50ms-cap profile (snacks/scroll.lua:28-43), and
    -- animate contributes fps=120 (snacks/animate/init.lua:33). Adding a
    -- duration/easing override here would silently break that parity.
    animate = { enabled = true },
    scroll = { enabled = true },

    -- Scratch buffer (toggled via <leader>. in core/keymaps.lua)
    scratch = { enabled = true },

    -- LSP reference tracking. Powers the ]] / [[ / <a-n> / <a-p> reference
    -- jumps bound (gated on textDocument/documentHighlight) in
    -- andrew.lsp_keymaps. This module sets needs_setup, so WITHOUT this
    -- line Snacks.words.jump() is a silent no-op -- it places no extmarks, and
    -- jump() returns immediately when the cursor is not on a known reference,
    -- so the keys would appear bound and simply do nothing.
    words = { enabled = true },

    -- Inline image rendering in markdown buffers
    image = {
      enabled = true,

      -- Force rendering: Kitty terminal supports the graphics protocol
      -- but $TERM may report as xterm-256color, causing detection to fail.
      force = true,

      -- Add SVG to supported formats (not in snacks defaults, requires magick)
      formats = {
        "png", "jpg", "jpeg", "gif", "bmp", "webp", "tiff", "heic", "avif",
        "svg", "mp4", "mov", "avi", "mkv", "webm", "pdf", "icns",
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
        conceal = function(_lang, type)
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
          for _, dir in ipairs({ "attachments", "assets", "images", "img", "media", "static", "public" }) do
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
    require("snacks").setup(opts)

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
    Snacks.toggle.option("conceallevel", {
      off = 0,
      on = vim.o.conceallevel > 0 and vim.o.conceallevel or 2,
      name = "Conceal Level",
    }):map("<leader>uc")
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

    -- Tabline. bufferline owns showtabline by default and re-asserts it on
    -- every redraw, which would undo this toggle; bufferline.lua sets
    -- auto_toggle_bufferline = false to hand the option over, and
    -- core/options.lua pins the visible value at 2.
    Snacks.toggle.option("showtabline", {
      off = 0,
      on = 2,
      global = true,
      name = "Tabline",
    }):map("<leader>uA")

    -- Light / dark. LazyVim just flips vim.o.background, which only works for
    -- schemes that redraw themselves on OptionSet background. This config needs
    -- two DIFFERENT colorschemes, so it drives andrew.themes.toggle, which
    -- swaps via :colorscheme (firing ColorScheme for vault/colors.lua) and
    -- re-themes lualine to match.
    Snacks.toggle({
      name = "Dark Background",
      get = function()
        return require("andrew.themes.toggle").is_dark()
      end,
      set = function(state)
        require("andrew.themes.toggle").set_dark(state)
      end,
    }):map("<leader>ub")

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
    -- <leader>ub used to be a second, identical binding for this; it now holds
    -- the light/dark toggle, matching LazyVim.
    vim.keymap.set("n", "<leader>uC", function()
      require("fzf-lua").colorschemes()
    end, { desc = "Colorschemes" })
  end,
}
