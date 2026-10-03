-- Spec for the LazyVim <leader>q quit/session port.
--
-- Covers the three files that have to agree:
--   * plugins/persistence.lua  -- the plugin spec + <leader>qs/qS/ql/qd
--   * core/keymaps.lua         -- the standalone <leader>qq (Quit All)
--   * plugins/which-key.lua    -- the <leader>q group
--   * core/options.lua         -- 'sessionoptions', which decides what is saved
--
-- THE ONE THAT MATTERS: `event`.
--
-- persistence.nvim only saves on a VimLeavePre autocmd, and that autocmd is
-- registered by setup(), which lazy.nvim calls when the plugin LOADS. Gate this
-- spec on `keys` alone and the plugin never loads in a normal session -- the
-- four keys are all for RESTORING, pressed at the start of a session if at all --
-- so nothing is ever written and the session directory silently stays empty.
-- There is no error to notice; you just find out later that no session exists.
-- Test 1 pins `event` and Test 2 pins the presence of `opts` (absent `opts` and
-- absent `config` means lazy.nvim never calls setup() at all, same silent end).
--
-- 'sessionoptions' must exclude `terminal`: this config's floating terminal
-- manages its own buffer reuse, and restored terminal buffers come back dead.
-- LazyVim excludes it too. Test 6 makes that unwritable.
--
-- Verified by an actual round-trip (not asserted here, it needs a UI and a real
-- quit): saving in a temp dir then restoring brings back both buffers, the cwd,
-- and leaves markdown on foldmethod=expr with the treesitter foldexpr intact;
-- readable_width pad windows are `nofile` so mksession skips them and window
-- count is stable at 3 across repeated save/restore cycles (no accumulation).
--
-- Drives the REAL specs (dofile). core/keymaps.lua is EXECUTED against a
-- recording stub of vim.keymap.set. No source introspection.
--
-- Discriminating power (verified by reintroducing each bug):
--   * Dropping `event` (keys-only lazy) -> fails test 1.
--   * Dropping `opts` -> fails test 2.
--   * Renaming/removing any of the 5 keys or changing a desc -> fails test 3/4.
--   * Removing the which-key group -> fails test 5.
--   * Adding `terminal` to sessionoptions -> fails test 6.
--
-- Run with: nvim --headless -u NONE -l tests/session_keymaps_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

local cfg = vim.fn.stdpath("config")

print("\n=== Quit/Session (<leader>q) Port Tests ===\n")

local spec = dofile(cfg .. "/lua/andrew/plugins/persistence.lua")

local pkeys = {}
for _, k in ipairs(spec.keys or {}) do
  pkeys[k[1]] = { desc = k.desc, rhs = k[2] }
end

-- ---------------------------------------------------------------------------
test("persistence loads on an event, NOT on keys alone", function()
  assert_eq(spec[1], "folke/persistence.nvim", "wrong repo")
  -- The save hook has to be armed before you quit; see the header.
  assert_eq(spec.event, "BufReadPre", "event must stay BufReadPre or sessions silently never save:")
  assert_true(spec.lazy ~= true, "an explicit lazy=true would defeat the event gate")
end)

test("opts is present, because its presence is what calls setup()", function()
  assert_true(type(spec.opts) == "table", "opts must exist (lazy.nvim only calls setup() when it does)")
  -- LazyVim keeps it empty; the defaults (dir, need=1, branch=true) are wanted.
  assert_eq(vim.tbl_count(spec.opts), 0, "opts must stay empty for LazyVim parity:")
end)

test("the four session keys match LazyVim exactly", function()
  local want = {
    ["<leader>qs"] = "Restore Session",
    ["<leader>qS"] = "Select Session",
    ["<leader>ql"] = "Restore Last Session",
    ["<leader>qd"] = "Don't Save Current Session",
  }
  for lhs, desc in pairs(want) do
    assert_true(pkeys[lhs] ~= nil, "missing key " .. lhs)
    assert_eq(pkeys[lhs].desc, desc, lhs .. " description drifted from LazyVim:")
    assert_eq(type(pkeys[lhs].rhs), "function", lhs .. " must call persistence directly")
  end
  assert_eq(#spec.keys, 4, "exactly the four LazyVim session keys belong here (qq lives in core):")
end)

test("<leader>qq Quit All is registered from core/keymaps.lua", function()
  -- LazyVim keeps Quit All in config/keymaps.lua, not the plugin spec, because
  -- it must work whether or not persistence has loaded.
  local seen = {}
  local real_set = vim.keymap.set
  vim.keymap.set = function(mode, lhs, rhs, opts)
    seen[lhs] = { mode = mode, rhs = rhs, desc = opts and opts.desc }
  end
  local ok, err = pcall(dofile, cfg .. "/lua/andrew/core/keymaps.lua")
  vim.keymap.set = real_set
  assert_true(ok, "core/keymaps.lua failed to load: " .. tostring(err))

  local qq = seen["<leader>qq"]
  assert_true(qq ~= nil, "<leader>qq must be mapped in core/keymaps.lua")
  assert_eq(qq.desc, "Quit All", "<leader>qq description drifted from LazyVim:")
  assert_eq(qq.rhs, "<cmd>qa<CR>", "<leader>qq must quit ALL windows:")
  -- The window-quit key is a different thing and must survive alongside it.
  assert_true(seen["<leader>wq"] ~= nil, "<leader>wq (quit a window) must still exist")
end)

test("which-key registers the Quit/Session group", function()
  local groups = {}
  package.loaded["which-key"] = {
    add = function(entries)
      for _, e in ipairs(entries) do
        if e.group then groups[e[1]] = e.group end
      end
    end,
    setup = function() end,
  }
  local wk = dofile(cfg .. "/lua/andrew/plugins/which-key.lua")
  if type(wk.config) == "function" then pcall(wk.config, nil, wk.opts or {}) end
  assert_eq(groups["<leader>q"], "Quit/Session", "<leader>q must be the Quit/Session group:")
end)

test("sessionoptions matches LazyVim and excludes terminal", function()
  local had = vim.o.sessionoptions
  vim.o.sessionoptions = ""
  dofile(cfg .. "/lua/andrew/core/options.lua")
  local got = {}
  for _, v in ipairs(vim.split(vim.o.sessionoptions, ",", { plain = true })) do
    if v ~= "" then got[v] = true end
  end
  for _, v in ipairs({ "buffers", "curdir", "tabpages", "winsize", "help", "globals", "skiprtp", "folds" }) do
    assert_true(got[v], "sessionoptions is missing '" .. v .. "' (LazyVim sets it)")
  end
  -- Load-bearing exclusions.
  assert_nil(got.terminal, "sessionoptions must NOT restore terminals -- the floating terminal owns its own buffers")
  assert_nil(got.blank, "sessionoptions must not save blank buffers (LazyVim drops it)")
  vim.o.sessionoptions = had
end)

_H.finish()
