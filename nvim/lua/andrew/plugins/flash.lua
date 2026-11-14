-- =============================================================================
-- Jump Motions (flash.nvim)
-- =============================================================================
-- Three separate features, all from flash:
--
--   1. char mode  -- upgrades the built-in f/F/t/T/;/, motions. After `f<char>`
--      every match is highlighted, and f/; jumps to the next match while F/,
--      jumps back, so a mistyped target is corrected by pressing f again
--      instead of restarting. These maps are installed from inside setup(),
--      NOT from the `keys` table below.
--
--   2. jump (`s`) -- type a few characters, then press the label that appears
--      at a match to jump there. Works as a motion, so `ds<label>` deletes to it.
--
--   3. treesitter (`S`) -- labels every syntax node containing the cursor, from
--      innermost outward, and selects the one you pick. No search pattern is
--      involved; `;`/`,` grow and shrink the selection.
--
-- =============================================================================
-- Key ownership notes -- read before changing any of this
-- =============================================================================
-- `s` and `S` used to belong to substitute.nvim. Substitute has moved to
-- gs/gss/gS (see plugins/substitute.lua) so flash can take the LazyVim keys.
--
-- TWO DELIBERATE DEVIATIONS FROM LAZYVIM:
--
--   * `S` is bound in { "n", "o" } only, NOT { "n", "o", "x" }. Visual-mode `S`
--     is nvim-surround's "wrap the selection" (documented in KEYMAPS.md), which
--     has no replacement -- gS, where surround's visual-line variant lives, is
--     now substitute's. Flash treesitter in visual mode, by contrast, IS
--     replaceable: <C-space> below already grows a visual selection by syntax
--     node. Trading a unique binding for a duplicate one would be a bad deal.
--
--   * LazyVim also binds <C-space> to flash treesitter with next/prev actions.
--     Not done here: nvim-treesitter's own incremental selection already owns
--     <C-space>/<BS> (see plugins/treesitter.lua). LazyVim only added the flash
--     version because nvim-treesitter's `main` rewrite deleted that feature;
--     this config is pinned to `master`, which still ships it natively.
--
-- =============================================================================
-- KNOWN UPSTREAM CRASH (not caused by anything below) -- flash.nvim @ 5f0f270
-- =============================================================================
-- `plugins/char.lua:118-126` takes the "repeat" branch on `Repeat.is_repeat`
-- but dereferences `M.state` there without a nil check. `Repeat.is_repeat` is
-- set from a `vim.on_key` hook the moment a literal `.` is consumed in normal
-- mode and is only cleared on the next `vim.schedule`, while `M.state` stays
-- nil until the first successful char jump of the session. So a `.` that is
-- immediately followed by `f`/`F`/`t`/`T`/`;`/`,` in the SAME input batch (a
-- quick `.` after "nothing to repeat", a paste, a macro / --remote-send burst)
-- hits
--     E5108: .../flash/plugins/char.lua:123: attempt to index field 'state'
-- and wedges the session on a hit-enter prompt. Reproduced with `.fg` sent as
-- one batch on BOTH 0.12.5 and 0.12.2, and also under a bare
-- `require("flash").setup({})` with nothing else loaded -- so none of the opts
-- below are involved. Once any f/t jump has happened the branch is safe (40
-- f/t/;/, cycles across two buffers plus a `:bd!` never reproduced it). The
-- real fix belongs upstream:
--     if Repeat.is_repeat and M.state then
--
-- Until that lands, `config` below re-wraps flash's own f/F/t/T/;/, mappings
-- and clears the stale `Repeat.is_repeat` flag when `M.state` is nil, so the
-- keypress falls through to the ordinary (non-repeat) jump. Delete the whole
-- guard once lazy-lock.json moves flash.nvim past 5f0f270 with the nil check.
-- =============================================================================

return {
  -- Plugin: flash.nvim - navigate with search labels and enhanced motions
  -- Repository: https://github.com/folke/flash.nvim
  "folke/flash.nvim",

  -- VeryLazy is still required alongside `keys`: char mode's f/F/t/T maps are
  -- installed by setup(), and no key below would ever trigger it. Dropping this
  -- would silently break f/t cycling until the first `s` press.
  event = "VeryLazy",

  -- stylua: ignore
  keys = {
    { "s", mode = { "n", "x", "o" }, function() require("flash").jump() end, desc = "Flash jump to a label" },
    { "S", mode = { "n", "o" }, function() require("flash").treesitter() end, desc = "Flash treesitter node select" },
    -- Operator-pending only, so normal-mode `r` (replace char) is untouched.
    -- `yr<label>` yanks at a remote location and returns the cursor here.
    { "r", mode = "o", function() require("flash").remote() end, desc = "Remote flash (operate elsewhere)" },
    -- Search first, then label the syntax nodes around each hit.
    -- Not normal mode, so `R` (Replace mode) is untouched.
    { "R", mode = { "o", "x" }, function() require("flash").treesitter_search() end, desc = "Treesitter search" },
    -- At the / or ? prompt, turn jump labels on for the search in flight.
    { "<c-s>", mode = { "c" }, function() require("flash").toggle() end, desc = "Toggle flash search labels" },
  },

  ---@type Flash.Config
  opts = {
    modes = {
      -- Don't hook `/` and `?` by default -- search stays vanilla until the
      -- <c-s> toggle above is pressed, which is also LazyVim's default.
      search = { enabled = false },

      char = {
        -- Restrict f/t to the current line, matching vanilla Vim.
        -- Set to true to let a single f reach anywhere in the buffer.
        multi_line = false,

        -- Highlight matches without dimming the rest of the buffer
        highlight = { backdrop = false },
      },
    },
  },

  -- Default lazy `config` plus the char-mode repeat guard described above.
  ---@param opts Flash.Config
  config = function(_, opts)
    require("flash").setup(opts)

    -- Upstream bug guard (flash.nvim @ 5f0f270, plugins/char.lua:118-126).
    -- Whole thing is pcall'd and every field is checked, so a future flash
    -- that renames/reorganises any of this simply leaves the plugin's own
    -- mappings in place instead of throwing at startup.
    pcall(function()
      local ok_char, Char = pcall(require, "flash.plugins.char")
      local ok_repeat, Repeat = pcall(require, "flash.repeat")
      if not (ok_char and ok_repeat) or type(Char) ~= "table" or type(Repeat) ~= "table" then
        return
      end
      -- Nothing to guard if upstream already nil-checks (field gone/renamed).
      if Repeat.is_repeat == nil then
        return
      end

      for _, key in ipairs({ "f", "F", "t", "T", ";", "," }) do
        for _, mode in ipairs({ "n", "x", "o" }) do
          local map = vim.fn.maparg(key, mode, false, true)
          local orig = type(map) == "table" and map.callback or nil
          -- Only touch a mapping that really is flash char mode's own Lua
          -- callback -- `;`/`,` may belong to the user, and `f` may belong to
          -- some other plugin if flash ever stops installing it.
          local from_char = false
          if type(orig) == "function" and map.expr ~= 1 and map.buffer ~= 1 then
            local info = debug.getinfo(orig, "S")
            from_char = type(info) == "table"
              and type(info.source) == "string"
              and info.source:find("flash/plugins/char%.lua") ~= nil
          end
          if from_char then
            vim.keymap.set(mode, key, function()
              -- `.` sets Repeat.is_repeat via vim.on_key and only clears it on
              -- the next vim.schedule; char mode's repeat branch then indexes
              -- M.state, which is nil until the first char jump of the session.
              if Repeat.is_repeat and Char.state == nil then
                Repeat.is_repeat = false
              end
              return orig()
            end, {
              silent = map.silent == 1,
              nowait = map.nowait == 1,
              desc = map.desc or ("Flash char mode " .. key),
            })
          end
        end
      end
    end)
  end,
}
