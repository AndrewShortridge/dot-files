-- =============================================================================
-- Diff Overlay and Hunk Operators (mini.diff)
-- =============================================================================
-- Runs ALONGSIDE gitsigns, not instead of it. LazyVim's `editor.mini-diff`
-- extra sets `{ "lewis6991/gitsigns.nvim", enabled = false }` and hands the
-- whole job to mini.diff; that is deliberately NOT done here, because gitsigns
-- provides blame (`<leader>ghb`/`ghB`/`ght`) and mini.diff has no equivalent.
--
-- The two are given non-overlapping jobs:
--
--   gitsigns   -- the sign column, hunk staging under <leader>gh, blame, and
--                 all hunk navigation (]g/[g, ]h/[h, ]H/[H).
--   mini.diff  -- the OVERLAY (its one genuinely unique feature: the reference
--                 text shown inline as virtual lines, so you see what the old
--                 content was without opening a diff split), plus operator-style
--                 apply/reset and a hunk textobject.
--
-- =============================================================================
-- Every upstream mapping is disabled; this file binds guarded replacements
-- =============================================================================
-- `opts.mappings` is entirely `''`. Two separate reasons:
--
-- 1. COLLISIONS. goto_first/prev/next/last default to [H / [h / ]h / ]H, every
--    one of which is already taken. gitsigns owns all four, and in markdown
--    ]h/[h are owned twice over by headings (ftplugin/markdown.lua) and
--    ==highlights== (vault/highlights.lua). These four are simply dropped --
--    mini.diff reads the same git index as gitsigns, so its hunks ARE gitsigns'
--    hunks and the navigation would be a duplicate that only fought for keys.
--
-- 2. HARD ERRORS ON UNATTACHED BUFFERS. mini.diff auto-attaches only to normal
--    listed text buffers (`buftype == ''`), so a picker preview, a diff scratch
--    buffer, a terminal or a help window never has a diff. Upstream's
--    `toggle_overlay()`, `textobject()` and `do_hunks()` all call `H.error()`
--    in that case, which surfaces as:
--
--      E5108: Lua: (mini.diff) Buffer 16 is not enabled.
--
--    Reachable just by pressing the key after closing a `<leader>gd` diff.
--    apply/reset/textobject are therefore re-bound below through `guard()`,
--    which explains the situation instead of raising. `toggle()` and
--    `export()` are safe as shipped and need no wrapper.
--
-- `gh` / `gH` keep their upstream letters. They shadow the built-in Select-mode
-- starters (`gh` charwise, `gH` linewise), which nothing here uses -- Select
-- mode exists for snippet plugins. Note `gh` is unrelated to the `<leader>gh`
-- hunks group; one is leader-prefixed and the other is not.
--
-- =============================================================================
-- The overlay is remembered per file
-- =============================================================================
-- `overlay` lives in mini.diff's per-buffer cache, and `MiniDiff.disable()`
-- deletes that cache wholesale; re-attaching re-initialises it to `false`
-- (`H.update_buf_cache`). `MiniDiff.enable()` registers `on_detach ->
-- MiniDiff.disable`, and nvim fires on_detach on ANY buffer reload -- upstream's
-- own comment says "including `:edit` command". So a reload silently turned the
-- overlay back off, e.g. after leaving a `<leader>ghd` diff.
--
-- `overlay_wanted` below records the choice per file path and a
-- `User MiniDiffUpdated` autocmd re-applies it whenever mini.diff re-attaches.
-- Keyed by path rather than buffer number so it also survives the buffer being
-- wiped and reopened.
--
-- =============================================================================
-- Why the number column
-- =============================================================================
-- Both plugins can draw hunk marks, and both would draw the SAME hunks. With
-- `style = "sign"` they would compete for the sign column. `style = "number"`
-- tints the line number instead, so gitsigns keeps the sign column and the two
-- coexist without visual duplication. This requires `number` or
-- `relativenumber` (core/options.lua sets both).
--
-- Upstream computes this default as `vim.go.number and 'number' or 'sign'`,
-- evaluated ONCE when the module table is built -- so it is pinned explicitly
-- here rather than left to whatever `number` happened to be at that moment.

return {
  -- Plugin: mini.diff - work with diff hunks
  -- Repository: https://github.com/echasnovski/mini.diff
  "echasnovski/mini.diff",
  version = false,

  event = { "BufReadPre", "BufNewFile" },

  -- =============================================================================
  -- Plugin Options
  -- =============================================================================
  opts = {
    view = {
      -- gitsigns keeps the sign column; see the banner above.
      style = "number",
      priority = 199,
    },

    -- All disabled. The keys are re-bound in `config` below, through a guard.
    mappings = {
      apply = "",
      reset = "",
      textobject = "",
      goto_first = "",
      goto_prev = "",
      goto_next = "",
      goto_last = "",
    },
  },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function(_, opts)
    local MiniDiff = require("mini.diff")
    MiniDiff.setup(opts)

    --- Is there a diff for the current buffer?
    --- Pure -- no side effects, safe to call while an expr mapping is being
    --- evaluated (where enabling a buffer would be a textlock risk).
    ---@return integer|nil buf
    local function diff_buf()
      local buf = vim.api.nvim_get_current_buf()
      return MiniDiff.get_buf_data(buf) ~= nil and buf or nil
    end

    --- Say why this buffer has no diff, in the terms the user can act on.
    local function explain()
      local bt = vim.bo.buftype
      local why = bt ~= "" and ("this is a " .. bt .. " buffer") or "not tracked by git here"
      vim.notify("mini.diff: no diff for this buffer (" .. why .. ")", vim.log.levels.WARN)
    end

    --- Wrap an action so an unattached buffer reports rather than errors.
    ---@param fn fun(buf: integer)
    ---@param expr boolean|nil true for `expr = true` mappings, which must
    ---       return a string ('' meaning "do nothing") rather than nil.
    local function guard(fn, expr)
      return function()
        local buf = diff_buf()
        if not buf then
          explain()
          return expr and "" or nil
        end
        return fn(buf)
      end
    end

    -- Overlay choice, keyed by full path. See the banner above.
    local overlay_wanted = {}

    --- Record whatever the overlay is set to right now for this buffer.
    local function remember(buf)
      local name = vim.api.nvim_buf_get_name(buf)
      if name == "" then
        return
      end
      local d = MiniDiff.get_buf_data(buf)
      overlay_wanted[name] = (d and d.overlay) or nil
    end

    -- Re-apply the remembered choice every time mini.diff finishes a diff
    -- update, which includes the first one after a re-attach. Toggling here
    -- cannot loop: it schedules another update, but by then `overlay` is true
    -- and the branch below is skipped.
    vim.api.nvim_create_autocmd("User", {
      pattern = "MiniDiffUpdated",
      group = vim.api.nvim_create_augroup("AndrewMiniDiffOverlay", { clear = true }),
      desc = "Restore the mini.diff overlay after a buffer reload",
      callback = function(ev)
        local name = vim.api.nvim_buf_get_name(ev.buf)
        if name == "" or not overlay_wanted[name] then
          return
        end
        local d = MiniDiff.get_buf_data(ev.buf)
        if d and not d.overlay then
          MiniDiff.toggle_overlay(ev.buf)
        end
      end,
    })

    local map = function(mode, lhs, rhs, o)
      vim.keymap.set(mode, lhs, rhs, vim.tbl_extend("force", { silent = true }, o or {}))
    end

    -- Operators. Mirrors upstream's own binding: `expr` returning `g@` so the
    -- action is dot-repeatable, in both normal and visual mode.
    map({ "n", "x" }, "gh", guard(function()
      return MiniDiff.operator("apply")
    end, true), { expr = true, desc = "Apply hunks" })

    map({ "n", "x" }, "gH", guard(function()
      return MiniDiff.operator("reset")
    end, true), { expr = true, desc = "Reset hunks" })

    -- Operator-pending only, because the textobject shares `gh` with apply --
    -- upstream drops the visual-mode binding in exactly this case.
    map("o", "gh", guard(function()
      MiniDiff.textobject()
    end), { desc = "Hunk range textobject" })

    -- The overlay. Unlike the operators this MAY enable a buffer that simply
    -- has not been attached yet, since pressing it is an explicit request.
    local function toggle_overlay()
      local buf = diff_buf()
      if not buf then
        if vim.bo.buftype ~= "" then
          return explain()
        end
        MiniDiff.enable(0)
        buf = diff_buf()
        if not buf then
          return explain()
        end
      end
      MiniDiff.toggle_overlay(buf)
      remember(buf)
    end

    map("n", "<leader>go", toggle_overlay, { desc = "Toggle Diff Overlay" })

    -- mini.diff ships NO user commands of its own; these are the discoverable
    -- entry points for the same API the mappings above use.
    local cmd = vim.api.nvim_create_user_command

    cmd("MiniDiffOverlay", toggle_overlay, { desc = "Toggle the mini.diff reference-text overlay" })

    -- `toggle` and `export` do not error on unattached buffers, so they are
    -- called directly.
    cmd("MiniDiffToggle", function()
      MiniDiff.toggle(0)
    end, { desc = "Enable/disable mini.diff for this buffer" })

    cmd("MiniDiffQuickfix", function()
      local items = MiniDiff.export("qf")
      if not items or #items == 0 then
        vim.notify("mini.diff: no hunks", vim.log.levels.INFO)
        return
      end
      vim.fn.setqflist(items)
      vim.cmd("copen")
    end, { desc = "Send every mini.diff hunk to the quickfix list" })
  end,
}
