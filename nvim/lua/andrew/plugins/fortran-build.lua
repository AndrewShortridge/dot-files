-- =============================================================================
-- Fortran Build Integration with Make
-- =============================================================================
-- Uses fzf-lua to find Makefiles and runs commands in a split terminal.
-- Provides keymaps for common Make targets: build, debug, clean, run, all.
--
-- IMPORTANT: this spec must NOT define a `config` function.
-- It is a FRAGMENT for "ibhagwan/fzf-lua", which plugins/fzf-lua.lua also
-- declares. lazy.nvim merges fragments that name the same repo but keeps only
-- the LAST fragment's `config`, so a `config` here would simply be discarded
-- (or would discard fzf-lua's own, depending on load order) -- which is exactly
-- how all six <leader>m keys came to be dead. The callbacks therefore live on
-- the `keys` entries below, where lazy.nvim merges rather than overwrites, and
-- the helpers live at module level.

-- Store last selected Makefile for re-runs
local last_makefile = nil

-- ==========================================================================
-- Helper: Run make command in a horizontal split terminal
-- ==========================================================================
local function run_make_in_split(makefile_path, target)
  -- Required lazily: this file is evaluated during lazy.nvim's spec import at
  -- startup, and the vault utils must not be pulled in that early.
  local lua_dirname = require("andrew.vault.link_utils").lua_dirname

  -- Get directory containing the Makefile
  local makefile_dir = lua_dirname(makefile_path)
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
-- Turn an fzf-lua `files` selection into a real filesystem path.
--
-- fzf.files() renders each entry as `<devicon><NBSP><path>` (plus ANSI colour),
-- so `selected[1]` is NOT a path. Using it raw produced
--   cd ' <icon>./code' && make -f 'Makefile'
-- i.e. "/bin/bash: line 1: cd: ./code: No such file or directory" for every one
-- of the six <leader>m keys -- the second time these keys were silently dead
-- (the first was the `config`-fragment problem described at the top of the
-- file). fzf-lua's own path helper strips the decoration and, given `cwd`,
-- returns an absolute path so the `cd` no longer depends on the window's cwd.
---@param entry string
---@return string
local function entry_path(entry)
  local ok, path = pcall(function()
    return require("fzf-lua.path").entry_to_file(entry, { cwd = vim.uv.cwd() }).path
  end)
  if ok and type(path) == "string" and path ~= "" then
    return path
  end
  return entry
end

local function pick_makefile_and_run(target)
  -- Lazy require: the keymap itself is what triggers fzf-lua's load.
  local fzf = require("fzf-lua")

  fzf.files({
    prompt = "Select Makefile> ",
    -- `files` defaults to cwd_prompt = true, which OVERWRITES opts.prompt with
    -- the shortened cwd (fzf-lua core.lua:818-825) -- so the prompt above never
    -- reached the screen and the picker was indistinguishable from :FzfLua
    -- files. Title added for the same reason: the default is " Files ".
    cwd_prompt = false,
    winopts = { title = " Select Makefile ", title_pos = "center" },
    cmd = "find . -name 'Makefile' -o -name '*.mk' -o -name 'GNUmakefile' 2>/dev/null",
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          local makefile = entry_path(selected[1])
          last_makefile = makefile
          run_make_in_split(makefile, target)
        end
      end,
    },
  })
end

return {
  -- This is a virtual plugin for configuration only
  -- Dependencies: fzf-lua (for Makefile picker)
  "ibhagwan/fzf-lua",

  -- Load when any of the keymaps are triggered. The callbacks are attached
  -- directly here -- see the note at the top of the file about `config`.
  keys = {
    -- <leader>mb - [M]ake [B]uild (default target)
    { "<leader>mb", function() pick_makefile_and_run("") end, desc = "Make: Build (pick Makefile)" },
    -- <leader>md - [M]ake [D]ebug (debug target with -g flags)
    { "<leader>md", function() pick_makefile_and_run("debug") end, desc = "Make: Build Debug (pick Makefile)" },
    -- <leader>mc - [M]ake [C]lean
    { "<leader>mc", function() pick_makefile_and_run("clean") end, desc = "Make: Clean (pick Makefile)" },
    -- <leader>mr - [M]ake [R]un
    { "<leader>mr", function() pick_makefile_and_run("run") end, desc = "Make: Run (pick Makefile)" },
    -- <leader>ma - [M]ake [A]ll (explicit 'all' target)
    { "<leader>ma", function() pick_makefile_and_run("all") end, desc = "Make: All (pick Makefile)" },
    -- <leader>ml - [M]ake [L]ast (re-run last Makefile with default target)
    {
      "<leader>ml",
      function()
        if last_makefile then
          run_make_in_split(last_makefile, "")
        else
          vim.notify("No Makefile selected yet. Use <leader>mb first.", vim.log.levels.WARN)
        end
      end,
      desc = "Make: Re-run last Makefile",
    },
  },
}
