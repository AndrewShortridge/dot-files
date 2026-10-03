-- Spec for three key/option ownership fixes found by the config audit:
--
--   1. plugins/blink-cmp.lua + plugins/lsp/lspconfig.lua -- insert-mode <C-k>.
--      lspconfig binds buffer-local i_<C-k> to signature help on LspAttach;
--      blink applies its own BUFFER-LOCAL maps on InsertEnter, i.e. later, so
--      whatever blink puts on <C-k> silently won and the signature-help map
--      (including its Python/ty branch) was dead. blink's `fallback` cannot
--      rescue it: keymap/fallback.lua snapshots the buffer-local map at apply
--      time -- before LspAttach on a fresh buffer -- and afterwards only
--      searches GLOBAL maps. Note the default PRESET also claims <C-k>
--      (show_signature), so the key has to be disabled explicitly, and
--      documentation scrolling has to stay reachable somewhere else.
--
--   2. lua/andrew/lazy.lua -- `rocks = { enabled = false }`. Nothing in this
--      config declares a luarocks dependency, and leaving rocks on produced one
--      ERROR + two WARNINGs in `:checkhealth lazy` and an extra
--      `luarocks/hererocks` plugin in the spec list.
--
--   3. plugins/vim-table-mode.lua -- the header comment documented a <Tab>
--      cell-motion the plugin does not map (insert-mode <Tab> is blink's) and
--      called the toggle <leader>tm while `table_mode_map_prefix` makes it
--      <leader>Tm.
--
-- Discriminating power:
--   * Putting any blink command back on <C-k>  -> the merged-mapping test fails.
--   * Removing scroll_documentation_up/down    -> the reachability test fails.
--   * Dropping lspconfig's i_<C-k>             -> the ownership test fails.
--   * Reverting the rocks option or the comment -> those tests fail.
--
-- Item 1 runs blink.cmp's REAL keymap merger over this config's REAL opts, so it
-- measures the mapping set blink would install, not the source text.
--
-- Run with: nvim --headless -u NONE -l tests/fix_plugins_keys_hygiene_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil, assert_match =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil, _H.assert_match

local cfg = vim.fn.stdpath("config")
local lazy_root = vim.fn.stdpath("data") .. "/lazy"

local function read(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

-- ---------------------------------------------------------------------------
-- 1. insert-mode <C-k>
-- ---------------------------------------------------------------------------

local blink = dofile(cfg .. "/lua/andrew/plugins/blink-cmp.lua")

test("blink-cmp.lua disables <C-k> outright (not just remaps it)", function()
  assert_eq(blink.opts.keymap["<C-k>"], false, "keymap['<C-k>']")
end)

test("blink's real keymap merger installs nothing on <C-k>", function()
  if vim.fn.isdirectory(lazy_root .. "/blink.cmp") == 0 then
    print("    (blink.cmp not installed -- merger check skipped)")
    return
  end
  vim.opt.runtimepath:prepend(lazy_root .. "/blink.cmp")
  local mappings = require("blink.cmp.keymap").get_mappings(blink.opts.keymap, "default")

  local normalized = {}
  for lhs, cmds in pairs(mappings) do
    normalized[vim.api.nvim_replace_termcodes(lhs, true, true, true)] = cmds
  end
  assert_nil(normalized[vim.keycode("<C-k>")], "blink still maps <C-k>")

  -- ...and documentation scrolling is still reachable in both directions.
  local up, down
  for lhs, cmds in pairs(mappings) do
    for _, c in ipairs(cmds) do
      if c == "scroll_documentation_up" then up = lhs end
      if c == "scroll_documentation_down" then down = lhs end
    end
  end
  assert_true(up ~= nil, "no key scrolls documentation up")
  assert_true(down ~= nil, "no key scrolls documentation down")
  assert_true(
    vim.api.nvim_replace_termcodes(up, true, true, true) ~= vim.keycode("<C-k>"),
    "scroll up must not be back on <C-k>"
  )
end)

test("lspconfig still owns insert-mode <C-k> for signature help", function()
  local src = read(cfg .. "/lua/andrew/plugins/lsp/lspconfig.lua")
  assert_match(src, 'keymap%.set%("i", "<C%-k>"', "the insert-mode signature-help map")
  assert_match(src, "blink%.cmp", "the key-ownership comment pointing at blink")
end)

-- ---------------------------------------------------------------------------
-- 2. lazy.nvim rocks
-- ---------------------------------------------------------------------------

test("lazy.setup disables luarocks/hererocks", function()
  local src = read(cfg .. "/lua/andrew/lazy.lua")
  assert_match(src, "rocks%s*=%s*{%s*enabled%s*=%s*false%s*}", "rocks = { enabled = false }")
end)

-- ---------------------------------------------------------------------------
-- 3. vim-table-mode header comment
-- ---------------------------------------------------------------------------

local tm_src = read(cfg .. "/lua/andrew/plugins/vim-table-mode.lua")

test("vim-table-mode's comment no longer promises a <Tab> cell motion", function()
  for _, line in ipairs(vim.split(tm_src, "\n")) do
    -- Only the usage comment matters; the plugin sets no <Tab> mapping at all.
    if line:match("^%-%-") and line:match("Move to next cell") then
      error("stale <Tab> line still present: " .. line)
    end
  end
  assert_true(not tm_src:match("%-%-%s+Tab%s"), "a bare `Tab` usage line survives")
end)

test("vim-table-mode's comment documents the real motions and the real toggle", function()
  for _, want in ipairs({ "<leader>Tm", "%]| / %[|", "}| / {|", "a| / i|" }) do
    assert_match(tm_src, want, "missing from the usage comment: " .. want)
  end
  -- The toggle really is <leader>T + "m".
  assert_match(tm_src, 'table_mode_map_prefix%s*=%s*"<leader>T"')
  assert_match(tm_src, 'table_mode_toggle_map%s*=%s*"m"')
  assert_true(not tm_src:match("<leader>tm"), "the old <leader>tm spelling is still there")
end)

_H.finish({ style = "results" })
