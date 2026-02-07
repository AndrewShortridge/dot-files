-- =============================================================================
-- Fortran Build Integration with Make
-- =============================================================================
-- Uses fzf-lua to find Makefiles and runs commands in a split terminal.
-- Provides keymaps for common Make targets: build, debug, clean, run, all.

return {
  -- This is a virtual plugin for configuration only
  -- Dependencies: fzf-lua (for Makefile picker)
  "ibhagwan/fzf-lua",

  -- Load when any of the keymaps are triggered
  keys = {
    { "<leader>mb", desc = "Make: Build (pick Makefile)" },
    { "<leader>md", desc = "Make: Build Debug (pick Makefile)" },
    { "<leader>mc", desc = "Make: Clean (pick Makefile)" },
    { "<leader>mr", desc = "Make: Run (pick Makefile)" },
    { "<leader>ma", desc = "Make: All (pick Makefile)" },
    { "<leader>ml", desc = "Make: Re-run last Makefile" },
  },

  config = function()
    local fzf = require("fzf-lua")

    -- Store last selected Makefile for re-runs
    local last_makefile = nil

    -- ==========================================================================
    -- Helper: Run make command in a horizontal split terminal
    -- ==========================================================================
    local function run_make_in_split(makefile_path, target)
      -- Get directory containing the Makefile
      local makefile_dir = vim.fn.fnamemodify(makefile_path, ":h")
      local makefile_name = vim.fn.fnamemodify(makefile_path, ":t")
      local cmd = string.format("cd %s && make -f %s %s",
        vim.fn.shellescape(makefile_dir),
        vim.fn.shellescape(makefile_name),
        target or "")

      -- Open horizontal split with terminal
      vim.cmd("botright split | terminal " .. cmd)
      -- Enter insert mode in terminal
      vim.cmd("startinsert")
    end

    -- ==========================================================================
    -- Helper: Open fzf to pick Makefile, then run target
    -- ==========================================================================
    local function pick_makefile_and_run(target)
      fzf.files({
        prompt = "Select Makefile> ",
        cmd = "find . -name 'Makefile' -o -name '*.mk' -o -name 'GNUmakefile' 2>/dev/null",
        actions = {
          ["default"] = function(selected)
            if selected and selected[1] then
              local makefile = selected[1]
              last_makefile = makefile
              run_make_in_split(makefile, target)
            end
          end,
        },
      })
    end

    -- ==========================================================================
    -- Keymaps: <leader>m prefix for [M]ake commands
    -- ==========================================================================
    local keymap = vim.keymap

    -- <leader>mb - [M]ake [B]uild (default target)
    keymap.set("n", "<leader>mb", function()
      pick_makefile_and_run("")
    end, { desc = "Make: Build (pick Makefile)" })

    -- <leader>md - [M]ake [D]ebug (debug target with -g flags)
    keymap.set("n", "<leader>md", function()
      pick_makefile_and_run("debug")
    end, { desc = "Make: Build Debug (pick Makefile)" })

    -- <leader>mc - [M]ake [C]lean
    keymap.set("n", "<leader>mc", function()
      pick_makefile_and_run("clean")
    end, { desc = "Make: Clean (pick Makefile)" })

    -- <leader>mr - [M]ake [R]un
    keymap.set("n", "<leader>mr", function()
      pick_makefile_and_run("run")
    end, { desc = "Make: Run (pick Makefile)" })

    -- <leader>ma - [M]ake [A]ll (explicit 'all' target)
    keymap.set("n", "<leader>ma", function()
      pick_makefile_and_run("all")
    end, { desc = "Make: All (pick Makefile)" })

    -- <leader>ml - [M]ake [L]ast (re-run last Makefile with default target)
    keymap.set("n", "<leader>ml", function()
      if last_makefile then
        run_make_in_split(last_makefile, "")
      else
        vim.notify("No Makefile selected yet. Use <leader>mb first.", vim.log.levels.WARN)
      end
    end, { desc = "Make: Re-run last Makefile" })
  end,
}
