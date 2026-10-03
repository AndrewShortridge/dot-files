-- Spec for the LazyVim <leader>g git group port.
--
-- Covers three files that have to agree with each other:
--   * plugins/git.lua       -- global <leader>g* keys (a snacks.nvim fragment)
--   * plugins/gitsigns.lua  -- buffer-local <leader>gh* hunk keys + bracket nav
--   * plugins/which-key.lua -- the group labels those keys hang under
--
-- THREE THINGS THIS PROTECTS.
--
-- 1. The <leader>h -> <leader>gh move. LazyVim nests hunks inside the git
--    group. Leaving a stray <leader>h* map, or the old "Git Hunks" which-key
--    group, would give two half-populated prefixes.
--
-- 2. The ]h / [h filetype guard. In markdown those keys are ALREADY taken
--    twice -- ftplugin/markdown.lua binds next/previous heading and
--    vault/highlights.lua rebinds next/previous ==highlight==. Both are
--    buffer-local, exactly like gitsigns' maps, so binding ]h unconditionally
--    makes the winner depend on autocmd ordering. gitsigns skips ]h/[h in
--    markdown and ]g/[g is the alias that works everywhere.
--
-- 3. The gh-binary gate on the GitHub keys. Snacks' gh_issue/gh_pr finders
--    shell out to `gh`; LazyVim binds them unconditionally, which would leave
--    four dead keys cluttering which-key on a machine without it.
--
-- Drives the REAL plugin specs (dofile). gitsigns' maps come from opts.on_attach,
-- so that is called against real scratch buffers with a stubbed gitsigns module
-- and an intercepted vim.keymap.set. No source introspection.
--
-- Discriminating power:
--   * Leaving any hunk key on <leader>h -> fails the no-leftovers assertion.
--   * Dropping the markdown guard in gitsigns -> ]h appears in the markdown
--     buffer, failing the guard assertion (this is the silent-breakage bug).
--   * Dropping ]g / [g -> fails the markdown-alias assertion, i.e. markdown
--     buffers would have no hunk motion at all.
--   * Binding the gh keys ungated -> fails the gate assertion on this machine.
--   * Restoring the which-key "Git Hunks" group at <leader>h -> fails the
--     group assertions.
--   * Omitting any LazyVim <leader>g key -> fails the completeness table.
--
-- Run with: nvim --headless -u NONE -l tests/git_keymaps_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

local cfg = vim.fn.stdpath("config")

-- ---------------------------------------------------------------------------
-- plugins/git.lua -- global <leader>g keys
-- ---------------------------------------------------------------------------

local git = dofile(cfg .. "/lua/andrew/plugins/git.lua")

local gkeys = {}
for _, k in ipairs(git.keys or {}) do
  local modes = k.mode or "n"
  if type(modes) == "string" then
    modes = { modes }
  end
  local set = {}
  for _, m in ipairs(modes) do
    set[m] = true
  end
  gkeys[k[1]] = { modes = set, desc = k.desc }
end

test("git.lua is a snacks.nvim spec fragment", function()
  -- A fragment, not a second plugin: lazy.nvim merges it into plugins/snacks.lua.
  assert_eq(git[1], "folke/snacks.nvim", "must be a folke/snacks.nvim fragment")
  assert_true(type(git.keys) == "table", "keys table must exist")
  assert_nil(git.opts, "fragment must not redeclare opts (snacks.lua owns them)")
  assert_nil(git.config, "fragment must not redeclare config (snacks.lua owns it)")
end)

test("every ungated LazyVim <leader>g key is present with its desc", function()
  local want = {
    ["<leader>gl"] = "Git Log",
    ["<leader>gL"] = "Git Log (cwd)",
    ["<leader>gf"] = "Git Current File History",
    ["<leader>gb"] = "Git Blame Line",
    ["<leader>gs"] = "Git Status",
    ["<leader>gS"] = "Git Stash",
    ["<leader>gd"] = "Git Diff (hunks)",
    ["<leader>gD"] = "Git Diff (origin)",
    ["<leader>gB"] = "Git Browse (open)",
    ["<leader>gY"] = "Git Browse (copy)",
  }
  for lhs, desc in pairs(want) do
    local k = gkeys[lhs]
    assert_true(k ~= nil, lhs .. " must be bound")
    assert_eq(k.desc, desc, lhs .. " desc must match LazyVim")
  end
end)

test("git browse works in visual mode as well as normal", function()
  -- LazyVim binds both in { "n", "x" } so a selection yields a line-range URL.
  for _, lhs in ipairs({ "<leader>gB", "<leader>gY" }) do
    assert_true(gkeys[lhs].modes["n"], lhs .. " must be normal mode")
    assert_true(gkeys[lhs].modes["x"], lhs .. " must be visual mode")
  end
end)

test("lazygit keys follow the lazygit binary", function()
  local has = vim.fn.executable("lazygit") == 1
  if has then
    assert_eq(gkeys["<leader>gg"].desc, "Lazygit (Root Dir)", "gg must open lazygit at the git root")
    assert_eq(gkeys["<leader>gG"].desc, "Lazygit (cwd)", "gG must open lazygit at the cwd")
  else
    assert_nil(gkeys["<leader>gg"], "gg must not be bound without the lazygit binary")
    assert_nil(gkeys["<leader>gG"], "gG must not be bound without the lazygit binary")
  end
end)

test("GitHub keys follow the gh binary", function()
  -- THE GATE: unlike LazyVim, these are conditional. Snacks' gh_issue/gh_pr
  -- finders spawn `gh`; binding them without it leaves four dead keys.
  local has = vim.fn.executable("gh") == 1
  for _, lhs in ipairs({ "<leader>gi", "<leader>gI", "<leader>gp", "<leader>gP" }) do
    if has then
      assert_true(gkeys[lhs] ~= nil, lhs .. " must be bound when gh is installed")
    else
      assert_nil(gkeys[lhs], lhs .. " must not be bound without the gh binary")
    end
  end
end)

test("no <leader>g key collides with the hunks sub-prefix", function()
  -- A global "<leader>gh..." map would shadow the buffer-local hunk group.
  for lhs in pairs(gkeys) do
    assert_true(lhs:sub(1, 11) ~= "<leader>gh", lhs .. " must not sit under the <leader>gh hunks prefix")
  end
end)

-- ---------------------------------------------------------------------------
-- plugins/gitsigns.lua -- buffer-local hunk keys
-- ---------------------------------------------------------------------------

local gitsigns_spec = dofile(cfg .. "/lua/andrew/plugins/gitsigns.lua")

--- Run on_attach against a scratch buffer of the given filetype and collect
--- every "mode:lhs" -> desc it maps.
--- gitsigns' `opts` is a function: it registers the <leader>uG "Git Signs"
--- Snacks.toggle and then returns the options table. Resolve it behind a
--- stubbed Snacks so these specs keep reaching on_attach.
local function gitsigns_opts(spec)
  if type(spec.opts) ~= "function" then
    return spec.opts
  end
  local prev = _G.Snacks
  local noop_toggle = {}
  noop_toggle.map = function(self) return self end
  -- the spec calls Snacks.toggle({...}):map(...), so `toggle` is the callable
  _G.Snacks = { toggle = setmetatable({}, { __call = function() return noop_toggle end }) }
  local ok, res = pcall(spec.opts)
  _G.Snacks = prev
  assert(ok, "gitsigns opts() failed: " .. tostring(res))
  return res
end

local function attach(filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = filetype

  local noop = function() end
  package.loaded.gitsigns = {
    nav_hunk = noop,
    stage_buffer = noop,
    undo_stage_hunk = noop,
    reset_buffer = noop,
    preview_hunk_inline = noop,
    blame_line = noop,
    blame = noop,
    diffthis = noop,
    toggle_current_line_blame = noop,
  }

  local maps = {}
  local real_set = vim.keymap.set
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.keymap.set = function(mode, lhs, _, opts)
    local modes = type(mode) == "string" and { mode } or mode
    for _, m in ipairs(modes) do
      maps[m .. ":" .. lhs] = (opts or {}).desc or true
    end
  end
  local ok, err = pcall(gitsigns_opts(gitsigns_spec).on_attach, buf)
  vim.keymap.set = real_set
  package.loaded.gitsigns = nil
  vim.api.nvim_buf_delete(buf, { force = true })
  return maps, ok, err
end

local lua_maps, lua_ok, lua_err = attach("lua")
local md_maps, md_ok, md_err = attach("markdown")

test("gitsigns on_attach runs for both filetypes", function()
  assert_eq(gitsigns_spec[1], "lewis6991/gitsigns.nvim", "spec must point at gitsigns")
  assert_true(lua_ok, "on_attach must run for lua: " .. tostring(lua_err))
  assert_true(md_ok, "on_attach must run for markdown: " .. tostring(md_err))
end)

test("every LazyVim hunk action is under <leader>gh", function()
  local want = {
    ["n:<leader>ghs"] = "Stage Hunk",
    ["x:<leader>ghs"] = "Stage Hunk",
    ["n:<leader>ghr"] = "Reset Hunk",
    ["x:<leader>ghr"] = "Reset Hunk",
    ["n:<leader>ghS"] = "Stage Buffer",
    ["n:<leader>ghu"] = "Undo Stage Hunk",
    ["n:<leader>ghR"] = "Reset Buffer",
    ["n:<leader>ghp"] = "Preview Hunk Inline",
    ["n:<leader>ghb"] = "Blame Line",
    ["n:<leader>ghB"] = "Blame Buffer",
    ["n:<leader>ghd"] = "Diff This",
    ["n:<leader>ghD"] = "Diff This ~",
  }
  for key, desc in pairs(want) do
    assert_eq(lua_maps[key], desc, key .. " must be mapped in a lua buffer")
    assert_eq(md_maps[key], desc, key .. " must be mapped in a markdown buffer too")
  end
end)

test("the hunk text object stays on ih", function()
  assert_true(lua_maps["o:ih"] ~= nil, "ih must be an operator-pending text object")
  assert_true(lua_maps["x:ih"] ~= nil, "ih must work in visual mode")
end)

test("no hunk key is left behind on <leader>h", function()
  -- The whole point of the move. Any survivor means two half-full prefixes.
  for _, maps in ipairs({ lua_maps, md_maps }) do
    for key in pairs(maps) do
      local lhs = key:match("^%a:(.*)$")
      if lhs and lhs:sub(1, 9) == "<leader>h" then
        error("stale <leader>h map survived the move to <leader>gh: " .. key)
      end
    end
  end
end)

test("]g and [g navigate hunks in every filetype", function()
  -- The markdown-safe alias. Without it markdown has no hunk motion at all,
  -- because ]h/[h are guarded away there.
  assert_eq(lua_maps["n:]g"], "Next Hunk", "]g must navigate hunks in lua")
  assert_eq(lua_maps["n:[g"], "Prev Hunk", "[g must navigate hunks in lua")
  assert_eq(md_maps["n:]g"], "Next Hunk", "]g must navigate hunks in markdown")
  assert_eq(md_maps["n:[g"], "Prev Hunk", "[g must navigate hunks in markdown")
end)

test("]h and [h take hunks outside markdown but yield inside it", function()
  assert_eq(lua_maps["n:]h"], "Next Hunk", "]h must navigate hunks in a lua buffer")
  assert_eq(lua_maps["n:[h"], "Prev Hunk", "[h must navigate hunks in a lua buffer")
  -- THE GUARD: ftplugin/markdown.lua (headings) and vault/highlights.lua
  -- (==highlights==) both bind these buffer-locally in markdown.
  assert_nil(md_maps["n:]h"], "]h must NOT be taken in markdown -- headings/highlights own it")
  assert_nil(md_maps["n:[h"], "[h must NOT be taken in markdown -- headings/highlights own it")
end)

test("]H and [H jump to the last and first hunk everywhere", function()
  -- Free in every filetype, so no guard is needed.
  assert_eq(lua_maps["n:]H"], "Last Hunk", "]H must jump to the last hunk")
  assert_eq(lua_maps["n:[H"], "First Hunk", "[H must jump to the first hunk")
  assert_eq(md_maps["n:]H"], "Last Hunk", "]H must work in markdown too")
  assert_eq(md_maps["n:[H"], "First Hunk", "[H must work in markdown too")
end)

test("inline blame toggle survived the port", function()
  -- Not a LazyVim key. The old <leader>hB was this toggle, whereas LazyVim's
  -- <leader>ghB is "blame buffer" -- a different feature. Without <leader>ght
  -- the port would silently drop always-on inline blame.
  assert_eq(lua_maps["n:<leader>ght"], "Toggle Line Blame", "<leader>ght must toggle inline blame")
end)

-- ---------------------------------------------------------------------------
-- <leader>ghd must leave the cursor in the DIFF window
-- ---------------------------------------------------------------------------
--
-- THE PROBLEM. gitsigns' diffthis() deliberately restores focus to the original
-- window (actions/diffthis.lua:161, `api.nvim_set_current_win(cwin)`), because
-- `:diffsplit` would otherwise leave you in the new one. The consequence is
-- that a reflexive `:q` closes YOUR file's window and strands you in gitsigns'
-- `gitsigns://<gitdir>//<rev>:<file>` buffer -- unlisted, so `:bnext` will not
-- cycle back, and `bufhidden=wipe`. Nothing is lost, but the file, its signs
-- and any mini.diff overlay all vanish with no obvious way back.
--
-- So the mapping moves into the diff window, making `:q` close the diff.
-- diffthis is async, hence the completion callback rather than acting on the
-- return value.

local diff_calls = {}
local ghd_rhs, ghD_rhs
do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "lua"
  package.loaded.gitsigns = setmetatable({
    diffthis = function(base, _, cb)
      diff_calls[#diff_calls + 1] = { base = base, cb = cb }
    end,
  }, { __index = function() return function() end end })

  local real_set = vim.keymap.set
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.keymap.set = function(_, lhs, rhs)
    if lhs == "<leader>ghd" then
      ghd_rhs = rhs
    elseif lhs == "<leader>ghD" then
      ghD_rhs = rhs
    end
  end
  pcall(gitsigns_opts(gitsigns_spec).on_attach, buf)
  vim.keymap.set = real_set
  package.loaded.gitsigns = nil
  vim.api.nvim_buf_delete(buf, { force = true })
end

test("the diff mappings go through a wrapper, not gs.diffthis directly", function()
  assert_true(type(ghd_rhs) == "function", "<leader>ghd must have a function rhs")
  assert_true(type(ghD_rhs) == "function", "<leader>ghD must have a function rhs")

  diff_calls = {}
  ghd_rhs()
  assert_eq(#diff_calls, 1, "<leader>ghd must call diffthis once")
  assert_nil(diff_calls[1].base, "<leader>ghd must diff against the index (no base)")
  -- Acting on the return value would race: diffthis is async.
  assert_true(type(diff_calls[1].cb) == "function", "diffthis must be given a completion callback")

  diff_calls = {}
  ghD_rhs()
  assert_eq(diff_calls[1].base, "~", "<leader>ghD must diff against ~")
end)

test("focus moves to the gitsigns diff window once diffthis completes", function()
  local start_win = vim.api.nvim_get_current_win()
  diff_calls = {}
  ghd_rhs()

  -- The split gitsigns would have made: a NEW window on a gitsigns:// buffer.
  vim.cmd("new")
  local diff_win = vim.api.nvim_get_current_win()
  local diff_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(diff_buf, "gitsigns:///tmp/spec/.git//:0:f.txt")
  vim.api.nvim_set_current_win(start_win)

  diff_calls[1].cb()
  vim.wait(200, function()
    return vim.api.nvim_get_current_win() == diff_win
  end)
  assert_eq(vim.api.nvim_get_current_win(), diff_win, "cursor must end up in the gitsigns diff window")

  vim.api.nvim_set_current_win(start_win)
  vim.api.nvim_win_close(diff_win, true)
end)

test("an already-open diff never yanks the cursor away", function()
  -- diffthis is a no-op when the window is already in diff mode, so no NEW
  -- window appears. Only a window created after the keypress may take focus.
  vim.cmd("new")
  local pre_existing = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_name(vim.api.nvim_get_current_buf(), "gitsigns:///tmp/spec/.git//:0:old.txt")
  local start_win = vim.api.nvim_get_current_win()

  vim.cmd("wincmd p")
  start_win = vim.api.nvim_get_current_win()

  diff_calls = {}
  ghd_rhs()
  diff_calls[1].cb()
  vim.wait(150)
  assert_eq(vim.api.nvim_get_current_win(), start_win, "a pre-existing gitsigns window must not steal focus")

  vim.api.nvim_win_close(pre_existing, true)
end)

-- ---------------------------------------------------------------------------
-- plugins/which-key.lua -- group labels
-- ---------------------------------------------------------------------------

local groups = {}
do
  local added = {}
  package.loaded["which-key"] = {
    setup = function() end,
    add = function(spec)
      for _, e in ipairs(spec) do
        added[#added + 1] = e
      end
    end,
  }
  local wkspec = dofile(cfg .. "/lua/andrew/plugins/which-key.lua")
  local ok, err = pcall(wkspec.config, nil, wkspec.opts or {})
  package.loaded["which-key"] = nil
  for _, e in ipairs(added) do
    if e.group then
      groups[e[1]] = e.group
    end
  end
  test("which-key config runs", function()
    assert_true(ok, "which-key config must run: " .. tostring(err))
  end)
end

test("which-key nests Hunks under the Git group", function()
  assert_eq(groups["<leader>g"], "Git", "<leader>g must stay the Git group")
  assert_eq(groups["<leader>gh"], "Hunks", "<leader>gh must be the Hunks sub-group")
  -- The old top-level group would now label an empty prefix.
  assert_nil(groups["<leader>h"], "the old <leader>h 'Git Hunks' group must be gone")
end)

_H.finish({ style = "results", exit = "os" })
