-- =============================================================================
-- fzf-lua Picker Look: snacks layout, Telescope colours
-- =============================================================================
-- One look for every fzf-lua picker in this config: laid out like the snacks
-- picker (two rounded boxes, a title on the list box, an icon for a prompt),
-- coloured like fzf-lua's `telescope` profile, with that profile's preview
-- paging on <C-d> / <C-u>.
--
-- The look itself is applied ONCE, in plugins/fzf-lua.lua's setup(), so the
-- built-in pickers (files, grep, buffers, LSP, ...) need nothing at the call
-- site. What a call site still owns is its LABEL. Snacks puts the picker's name
-- in the box title and keeps the prompt a bare icon; fzf-lua's older habit is
-- to put the name in the prompt ("Vault tags> "). Pickers with a custom label
-- go through titled():
--
--   fzf.fzf_exec(entries, fzf_look.titled("Vault tags", { actions = ... }))

local M = {}

--- The snacks picker's input-line icon, used as every fzf-lua prompt.
M.PROMPT = " "

--- fzf-lua options for a picker named `label`: the name goes in the box title,
--- the prompt becomes the shared icon. Returns a new table; `opts` is not
--- modified. A `prompt` or `winopts.title` already in `opts` is replaced.
---@param label string picker name without prompt punctuation, e.g. "Vault tags"
---@param opts? table other fzf-lua options for the call
---@return table
function M.titled(label, opts)
  return vim.tbl_deep_extend("force", opts or {}, {
    prompt = M.PROMPT,
    winopts = { title = " " .. label .. " ", title_pos = "center" },
  })
end

--- The look as an overlay for fzf-lua's setup() table: deep-merge it over the
--- rest of the configuration (plugins/fzf-lua.lua does). Everything here is a
--- global or `defaults` option, so it reaches the built-in pickers and every
--- fzf_exec / fzf_live call alike; a call site can still override any of it.
---@return table
function M.setup_opts()
  local load_profiles = require("fzf-lua.utils").load_profiles
  local git_preview = require("andrew.utils.fzf_git_preview")
  local git_previewer = git_preview.previewer
  local function titled_box(name)
    return { winopts = { title = " " .. name .. " " } }
  end

  -- <C-d> pages the preview in every picker (`keymap` at the bottom), and in
  -- a picker with a Neovim-window preview that mapping swallows the key
  -- before fzf sees it. Two git pickers bind an action of their own to it
  -- (commits: open that commit's diff; diff: open that file's hunks), which
  -- would be advertised in the header and unreachable. They move to <A-d>.
  local git_defaults = require("fzf-lua").defaults.git
  local function with_page_key_freed(default_actions)
    return { ["ctrl-d"] = false, ["alt-d"] = default_actions["ctrl-d"] }
  end

  -- Snacks frames its two layouts differently, and so does this:
  --   side by side (120+ columns)  -- list and preview are two separate boxes;
  --   stacked (narrower)           -- one box, the preview under a divider.
  -- The second is what fzf-lua's `border-fused` profile (its default) already
  -- draws, so the border functions below hand every case except side-by-side
  -- back to that profile's own. That covers a picker with no preview (one
  -- whole box) and one whose preview fzf itself draws (a `preview` that is a
  -- shell command or callback: registers, the tmux buffers, ...): fzf-lua has
  -- a single window to frame there, so those stay one box with a divider at
  -- any width. The git pickers were among them until they were given a
  -- Neovim-window previewer, further down.
  local fused_borders = load_profiles("border-fused", 1).winopts

  return {
    -- Colours come straight from fzf-lua's bundled `telescope` profile rather
    -- than a copy of it, so they follow upstream.
    --
    -- `hls` is a function because the profile decides WHICH groups to use when
    -- it is read: a Telescope* group the colorscheme leaves undefined is
    -- dropped, so that fzf-lua falls back to its own FzfLua* group. Which ones
    -- are defined changes with the colorscheme (<leader>ub, <leader>uC).
    -- fzf-lua calls a function-valued `hls` each time a picker opens, which
    -- keeps the answer current with no ColorScheme autocmd to order against
    -- the ones that define those groups.
    hls = function()
      return load_profiles("telescope", 1).hls
    end,
    -- `fzf_colors` holds group NAMES only; fzf-lua turns them into colours at
    -- every launch, so a plain table already follows the colorscheme.
    fzf_colors = load_profiles("telescope", 1).fzf_colors,

    -- Snacks' input line: its prompt icon, and no path in front of the query.
    -- These go through `defaults`, which fzf-lua merges into every picker:
    --   * `prompt` replaces fzf's "> " and, because it is set, stops the
    --     pickers that would compute a prompt at call time (grep and LSP
    --     workspace symbols show the search term, code actions "Code
    --     actions> ") from doing so;
    --   * `cwd_prompt = false` stops `files` and `global` from overwriting it
    --     with the working directory.
    defaults = {
      prompt = M.PROMPT,
      cwd_prompt = false,
    },

    -- The NAME of a built-in picker is mostly not set here: fzf-lua's default
    -- profile chain (default -> border-fused -> default-title) already puts it
    -- in `winopts.title`, and setup() keeps that chain as long as no other
    -- profile is named. These are the pickers that profile leaves untitled.
    changes = titled_box("Changes"),
    spellcheck = titled_box("Spellcheck"),
    serverlist = titled_box("Serverlist"),
    complete_path = titled_box("Complete Path"),
    complete_file = titled_box("Complete File"),
    complete_line = titled_box("Complete Line"),
    -- The git pickers preview with a shell command, which fzf would draw in
    -- its own window; fzf_git_preview moves that output into the Neovim
    -- preview window so they get the same two boxes as a file picker.
    -- git_status has a previewer of its own kind and gets that module's
    -- second class (`previewers` below); git_hunks previews a file and needs
    -- neither.
    git = {
      commits = {
        previewer = git_previewer,
        actions = with_page_key_freed(git_defaults.commits.actions),
      },
      bcommits = { previewer = git_previewer },
      blame = { previewer = git_previewer },
      stash = { previewer = git_previewer },
      diff = {
        winopts = titled_box("Git Diff").winopts,
        previewer = git_previewer,
        actions = with_page_key_freed(git_defaults.diff.actions),
      },
      hunks = titled_box("Git Hunks"),
      reflog = titled_box("Git Reflog"),
      tags = titled_box("Git Tags"),
    },
    previewers = { git_diff = git_preview.status_previewer },
    tmux = { buffers = titled_box("Tmux Buffers") },

    winopts = {
      -- Snacks' `default` layout preset: 80% x 80%, centred, list and preview
      -- sharing the width equally.
      height = 0.8,
      width = 0.8,
      row = 0.5,
      col = 0.5,
      title_pos = "center",
      border = function(window, metadata)
        if metadata.nwin == 2 and metadata.layout == "right" then
          return "rounded"
        end
        return fused_borders.border(window, metadata)
      end,
      preview = {
        horizontal = "right:50%",
        -- Under 120 EDITOR columns snacks switches to its `vertical` preset,
        -- with the preview below the list at 40% of the height. fzf-lua
        -- compares `flip_columns` with the PICKER's text width instead
        -- (win.lua `columns()`): 80% of the editor less the 4 border columns
        -- of the two side-by-side boxes, so 92 at 120 editor columns and 91 at
        -- 119. The test is a strict `>`. Measured in tmux at both widths.
        layout = "flex",
        flip_columns = 91,
        vertical = "down:40%",
        border = function(window, metadata)
          if metadata.type == "nvim" and metadata.layout == "right" then
            return "rounded"
          end
          return fused_borders.preview.border(window, metadata)
        end,
        scrollbar = false,
      },
    },

    fzf_opts = {
      -- The prompt again, for the pickers `defaults` does not reach (the DAP
      -- ones bar breakpoints). A picker's own `prompt` overrides this flag.
      ["--prompt"] = M.PROMPT,
      -- The rule snacks draws between the input line and the list.
      ["--input-border"] = "bottom",
      -- Snacks shows `matched/total`; fzf's stock info also appends the
      -- multi-select count, e.g. `1/5 (0)`.
      ["--info-command"] = 'echo "$FZF_MATCH_COUNT/$FZF_TOTAL_COUNT"',
      -- Snacks marks the current row with the cursorline colour only.
      ["--pointer"] = " ",
      ["--gutter"] = " ",
    },

    -- Preview scrolling as in the `telescope` profile: a page at a time on
    -- <C-d> / <C-u>. `builtin` drives fzf-lua's own previewer, `fzf` the native
    -- one. These are added to the rest of setup()'s keymap, so <C-j> / <C-k>
    -- still scroll the preview by line. The price is fzf's own <C-u> (clear
    -- the query), which is gone from every picker.
    keymap = {
      builtin = {
        ["<C-d>"] = "preview-page-down",
        ["<C-u>"] = "preview-page-up",
      },
      fzf = {
        ["ctrl-d"] = "preview-page-down",
        ["ctrl-u"] = "preview-page-up",
      },
    },
  }
end

return M
