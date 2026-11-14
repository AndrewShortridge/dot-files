-- =============================================================================
-- Git Signs and Hunk Actions (gitsigns.nvim)
-- =============================================================================
-- Sign-column git markers plus every hunk operation, ported from LazyVim.
--
-- Hunk keys moved from <leader>h* to <leader>gh* to match LazyVim, which nests
-- "hunks" inside the "git" group. The old <leader>h prefix is gone; the letters
-- themselves are unchanged (s r S R u p b B d D), so muscle memory only has to
-- absorb the `g`.
--
-- Every map below is BUFFER-LOCAL and created from on_attach, so it exists only
-- in files gitsigns actually attaches to -- i.e. files inside a git work tree.
--
-- =============================================================================
-- Bracket navigation -- read before changing
-- =============================================================================
-- LazyVim navigates hunks with ]h / [h. In this config those are already taken
-- TWICE in markdown: ftplugin/markdown.lua binds them to next/previous heading,
-- and vault/highlights.lua rebinds them to next/previous ==highlight==. Both are
-- buffer-local, like these, so a blind port would make the winner depend on
-- autocmd ordering.
--
-- Resolution: ]h / [h are bound here ONLY in non-markdown buffers, and ]g / [g
-- are kept as the alias that works everywhere including markdown. ]H / [H
-- (first/last hunk) are free in every filetype and bound unconditionally.
--
-- Note gs.nav_hunk() replaces gs.next_hunk()/gs.prev_hunk(), which gitsigns
-- deprecated (gitsigns/actions.lua marks both `@deprecated`).

return {
  -- Plugin: gitsigns.nvim - git decorations and hunk actions
  -- Repository: https://github.com/lewis6991/gitsigns.nvim
  "lewis6991/gitsigns.nvim",

  event = { "BufReadPre", "BufNewFile" },

  -- opts is a function so the <leader>uG toggle can be registered when gitsigns
  -- loads. Registering it eagerly from snacks.lua instead would mean which-key
  -- calling `get` -- and therefore require("gitsigns") -- just to draw the
  -- popup, pulling gitsigns in ahead of its BufReadPre event.
  --
  -- gitsigns owns the SIGN COLUMN here. mini.diff deliberately renders through
  -- the line number instead (mini-diff.lua pins view.style = "number"), so this
  -- toggle is unambiguous: it is the sign-column markers, and mini.diff's
  -- indicators are unaffected.
  opts = function()
    Snacks.toggle({
      name = "Git Signs",
      get = function()
        return require("gitsigns.config").config.signcolumn
      end,
      set = function(state)
        require("gitsigns").toggle_signs(state)
      end,
    }):map("<leader>uG")

    return {
      on_attach = function(bufnr)
      local gs = package.loaded.gitsigns

      local function map(mode, l, r, desc)
        vim.keymap.set(mode, l, r, { buffer = bufnr, desc = desc, silent = true })
      end

      -- =======================================================================
      -- Navigation
      -- =======================================================================
      -- In a diff split, defer to vim's own ]c / [c change motions.
      local function next_hunk()
        if vim.wo.diff then
          vim.cmd.normal({ "]c", bang = true })
        else
          gs.nav_hunk("next")
        end
      end

      local function prev_hunk()
        if vim.wo.diff then
          vim.cmd.normal({ "[c", bang = true })
        else
          gs.nav_hunk("prev")
        end
      end

      -- Always available, and the only hunk motion in markdown buffers.
      map("n", "]g", next_hunk, "Next Hunk")
      map("n", "[g", prev_hunk, "Prev Hunk")

      -- LazyVim's keys. Skipped in markdown, where headings and ==highlights==
      -- own ]h / [h -- see the banner above.
      if vim.bo[bufnr].filetype ~= "markdown" then
        map("n", "]h", next_hunk, "Next Hunk")
        map("n", "[h", prev_hunk, "Prev Hunk")
      end

      -- =======================================================================
      -- Diff splits
      -- =======================================================================
      -- gitsigns' diffthis() deliberately hands focus BACK to the original
      -- window (actions/diffthis.lua:161 -- `api.nvim_set_current_win(cwin)`),
      -- because `:diffsplit` would otherwise leave you in the new one. The
      -- consequence is that a reflexive `:q` closes YOUR file's window and
      -- strands you in gitsigns' `gitsigns://<gitdir>//<rev>:<file>` buffer --
      -- which is unlisted (so `:bnext` will not cycle back) and `bufhidden=wipe`.
      -- Nothing is lost, but the file, its signs and any mini.diff overlay all
      -- vanish from view with no obvious way back.
      --
      -- So move into the diff window instead: `:q` then closes the diff and
      -- returns you to your file, which is what the keystroke implies.
      --
      -- diffthis is async (actions.lua wraps it in async_run), so the split may
      -- not exist yet when it returns -- hence the completion callback rather
      -- than acting on the return. If anything about that changes upstream the
      -- worst case is that focus simply stays put, i.e. today's behaviour.
      local function diffthis_focused(base)
        local before = {}
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          before[w] = true
        end

        gs.diffthis(base, {}, function()
          vim.schedule(function()
            for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
              -- Only a window that did not exist before, so an existing diff
              -- (where diffthis is a no-op) never yanks the cursor away.
              if not before[w] and vim.api.nvim_win_is_valid(w) then
                local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
                if name:match("^gitsigns://") then
                  vim.api.nvim_set_current_win(w)
                  return
                end
              end
            end
          end)
        end)
      end

      -- stylua: ignore start
      map("n", "]H", function() gs.nav_hunk("last") end, "Last Hunk")
      map("n", "[H", function() gs.nav_hunk("first") end, "First Hunk")

      -- =======================================================================
      -- Hunk actions (<leader>gh)
      -- =======================================================================
      -- The Ex-command form is what makes stage/reset work in visual mode:
      -- :Gitsigns picks up the '<,'> range automatically.
      map({ "n", "x" }, "<leader>ghs", ":Gitsigns stage_hunk<CR>", "Stage Hunk")
      map({ "n", "x" }, "<leader>ghr", ":Gitsigns reset_hunk<CR>", "Reset Hunk")
      map("n", "<leader>ghS", gs.stage_buffer, "Stage Buffer")
      map("n", "<leader>ghu", gs.undo_stage_hunk, "Undo Stage Hunk")
      map("n", "<leader>ghR", gs.reset_buffer, "Reset Buffer")
      map("n", "<leader>ghp", gs.preview_hunk_inline, "Preview Hunk Inline")
      map("n", "<leader>ghb", function() gs.blame_line({ full = true }) end, "Blame Line")
      map("n", "<leader>ghB", function() gs.blame() end, "Blame Buffer")
      map("n", "<leader>ghd", function() diffthis_focused() end, "Diff This")
      map("n", "<leader>ghD", function() diffthis_focused("~") end, "Diff This ~")

      -- Not a LazyVim key. Kept because the old <leader>hB was this toggle, and
      -- LazyVim's <leader>ghB (blame buffer) is a different feature, so the
      -- port would otherwise silently lose always-on inline blame.
      map("n", "<leader>ght", gs.toggle_current_line_blame, "Toggle Line Blame")

      -- Text object: `dih` deletes the hunk under the cursor.
      map({ "o", "x" }, "ih", ":<C-U>Gitsigns select_hunk<CR>", "Select Hunk")
      -- stylua: ignore end
    end,
    }
  end,
}
