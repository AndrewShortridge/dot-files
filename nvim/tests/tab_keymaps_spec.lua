-- Spec for the LazyVim <leader><Tab> tab-management port.
--
-- Covers the two files that have to agree:
--   * core/keymaps.lua      -- the seven <leader><Tab> keys
--   * plugins/which-key.lua -- the <leader><Tab> group
--
-- WHAT THIS IS GUARDING
--
-- 1. The seven keys and their EXACT LazyVim descriptions
--    (lazyvim/config/keymaps.lua:205-212). The descriptions are the whole point
--    of a "port" -- LazyVim's docs, videos and muscle memory all key off them,
--    so drifting "Close Other Tabs" to "Close others" quietly ends the parity.
--
-- 2. The old <leader>t tab keys SURVIVING. This port deliberately adds a second
--    tab prefix rather than replacing the first: five of the seven duplicate
--    <leader>to/tx/tn/tp, and <leader>t also carries the floating terminal
--    (<leader>tt), so the prefix cannot be retired wholesale. If someone later
--    "cleans up" the duplicates, test 2 turns that into a decision instead of
--    an accident.
--
-- 3. The <leader><Tab>f / <leader>tf trap. Same letter, different verb:
--    <leader><Tab>f is :tabfirst (LazyVim), <leader>tf opens the current buffer
--    in a new tab (this
--    config, pre-existing). Test 3 pins both so neither is "corrected" into the
--    other.
--
-- 4. The which-key group. Registered bare, with no `icon` field, because
--    which-key lowercases the group name before matching its built-in rules
--    (icons.lua:177) and rule `tab` (icons.lua:54) is the first that matches --
--    so Title Case "Tabs" lands on the same purple nf-md-tab glyph LazyVim gets
--    from its lowercase "tabs". Verified at runtime under a pty: the node
--    carries group=true, name="Tabs", 7 children, icon U+F04E9 /
--    WhichKeyIconPurple, byte-identical to Icons.get({desc="tabs"}).
--    (which_key_icons_spec separately requires EVERY group to resolve an icon,
--    so a rename to something the rules miss fails there too.)
--
-- NOT asserted here: `silent`. LazyVim's map helper forces silent=true
-- (LazyVim.safe_keymap_set, util/init.lua:206-226) and this port omits it, which
-- is a genuine difference in the opts table but not in behaviour -- <cmd>
-- mappings never echo, none of the seven commands prints on success, and the one
-- message you can provoke (E784 on closing the last tab page) is an error, which
-- 'silent' does not suppress. Asserting either way would pin a no-op.
--
-- Drives the REAL files (dofile). core/keymaps.lua is EXECUTED against a
-- recording stub of vim.keymap.set; which-key.lua against a stub of wk.add.
-- No source introspection.
--
-- Discriminating power (verified by reintroducing each bug):
--   * Deleting any of the 7 keys, or changing any desc -> fails test 1.
--   * Deleting an old <leader>t tab key or <leader>tt   -> fails test 2.
--   * Swapping <leader><Tab>f to :tabnew %              -> fails test 3.
--   * Reverting <leader>tf to the bare "<cmd>tabnew %<CR>" string (E499 on an
--     unnamed buffer)                                    -> fails test 3.
--   * Removing/renaming the which-key group             -> fails test 4.
--   * Pointing a key at the wrong :tab command          -> fails test 5.
--
-- Run with: nvim --headless -u NONE -l tests/tab_keymaps_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

local cfg = vim.fn.stdpath("config")

print("\n=== Tabs (<leader><Tab>) Port Tests ===\n")

-- Execute the real core/keymaps.lua against a recorder.
local function load_keymaps()
  local seen = {}
  local real_set = vim.keymap.set
  vim.keymap.set = function(mode, lhs, rhs, opts)
    seen[lhs] = { mode = mode, rhs = rhs, desc = opts and opts.desc }
  end
  local ok, err = pcall(dofile, cfg .. "/lua/andrew/core/keymaps.lua")
  vim.keymap.set = real_set
  assert_true(ok, "core/keymaps.lua failed to load: " .. tostring(err))
  return seen
end

local seen = load_keymaps()

-- LazyVim's seven, in LazyVim's own source order.
local LAZYVIM_TABS = {
  { "<leader><Tab>l", "<cmd>tablast<CR>", "Last Tab" },
  { "<leader><Tab>o", "<cmd>tabonly<CR>", "Close Other Tabs" },
  { "<leader><Tab>f", "<cmd>tabfirst<CR>", "First Tab" },
  { "<leader><Tab><Tab>", "<cmd>tabnew<CR>", "New Tab" },
  { "<leader><Tab>]", "<cmd>tabnext<CR>", "Next Tab" },
  { "<leader><Tab>d", "<cmd>tabclose<CR>", "Close Tab" },
  { "<leader><Tab>[", "<cmd>tabprevious<CR>", "Previous Tab" },
}

-- ---------------------------------------------------------------------------
test("all seven LazyVim tab keys exist with LazyVim's exact descriptions", function()
  for _, k in ipairs(LAZYVIM_TABS) do
    local lhs, _, desc = k[1], k[2], k[3]
    local got = seen[lhs]
    assert_true(got ~= nil, "missing key " .. lhs)
    assert_eq(got.mode, "n", lhs .. " must be normal-mode only:")
    assert_eq(got.desc, desc, lhs .. " description drifted from LazyVim:")
  end
end)

test("the pre-existing <leader>t tab keys still work", function()
  -- This port ADDS a prefix; it does not replace one. See the header.
  local legacy = {
    ["<leader>to"] = "Open new tab",
    ["<leader>tx"] = "Close current tab",
    ["<leader>tn"] = "Go to next tab (navigate right)",
    ["<leader>tp"] = "Go to previous tab (navigate left)",
    ["<leader>tf"] = "Open current buffer in new tab",
  }
  for lhs, desc in pairs(legacy) do
    assert_true(seen[lhs] ~= nil, lhs .. " was removed -- the <leader>t group is still in use")
    assert_eq(seen[lhs].desc, desc, lhs .. " description changed:")
  end
end)

test("<leader><Tab>f and <leader>tf stay different commands", function()
  -- Same letter, different verb. Easy to "fix" into a bug.
  assert_eq(seen["<leader><Tab>f"].rhs, "<cmd>tabfirst<CR>", "<leader><Tab>f must be First Tab:")

  -- <leader>tf is a FUNCTION, not "<cmd>tabnew %<CR>": `tabnew %` raises E499
  -- on an unnamed buffer (% expands to nothing), so the mapping branches on
  -- whether the buffer has a name. Drive the real callback with vim.cmd stubbed
  -- and assert the commands it issues on both branches.
  local tf = seen["<leader>tf"]
  assert_true(type(tf.rhs) == "function", "<leader>tf must be a function (E499 guard), got " .. type(tf.rhs))

  local function commands_for(bufname)
    local issued = {}
    local real_cmd = vim.cmd
    local real_name = vim.api.nvim_buf_get_name
    vim.cmd = function(c) issued[#issued + 1] = c end
    vim.api.nvim_buf_get_name = function() return bufname end
    local ok, err = pcall(tf.rhs)
    vim.cmd = real_cmd
    vim.api.nvim_buf_get_name = real_name
    assert_true(ok, "<leader>tf raised: " .. tostring(err))
    return table.concat(issued, "; ")
  end

  -- Named buffer: still exactly LazyVim-adjacent `tabnew %`.
  assert_eq(commands_for("/tmp/x.lua"), "tabnew %", "<leader>tf on a named buffer:")
  -- Unnamed buffer: split and promote the split to a tab instead of E499.
  assert_eq(commands_for(""), "split; wincmd T", "<leader>tf on an unnamed buffer:")
end)

test("which-key registers the Tabs group on <leader><Tab>", function()
  local groups = {}
  package.loaded["which-key"] = {
    add = function(entries)
      for _, e in ipairs(entries) do
        if e.group then groups[e[1]] = e end
      end
    end,
    setup = function() end,
  }
  local wk = dofile(cfg .. "/lua/andrew/plugins/which-key.lua")
  if type(wk.config) == "function" then pcall(wk.config, nil, wk.opts or {}) end

  local g = groups["<leader><Tab>"]
  assert_true(g ~= nil, "<leader><Tab> must be registered as a which-key group")
  assert_eq(g.group, "Tabs", "<leader><Tab> group name:")
  -- Bare on purpose -- the built-in `tab` rule already gives LazyVim's glyph.
  assert_true(g.icon == nil, "the Tabs group needs no explicit icon; the built-in `tab` rule matches")
  -- The old prefix keeps its own group; both coexist.
  assert_true(groups["<leader>t"] ~= nil, "<leader>t must keep its Tab/Terminal group")
end)

test("each key runs the tab command it claims to", function()
  for _, k in ipairs(LAZYVIM_TABS) do
    assert_eq(seen[k[1]].rhs, k[2], k[1] .. " points at the wrong command:")
  end
  -- Every one is a <cmd> mapping, so none of them echoes; see the header note
  -- about `silent`.
  for _, k in ipairs(LAZYVIM_TABS) do
    assert_true(k[2]:match("^<cmd>") ~= nil, k[1] .. " must be a <cmd> mapping")
  end
end)

_H.finish()
