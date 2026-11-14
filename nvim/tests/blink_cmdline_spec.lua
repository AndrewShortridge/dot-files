-- Spec for blink.cmp command-line (':' / '/' / '?') completion.
--
-- Two things this locks down.
--
-- 1) THE LOAD TRIGGER. blink registers its cmdline mappings as GLOBAL 'c'-mode
--    maps at setup() time (keymap/apply.lua apply.cmdline_keymaps). The spec
--    previously declared `event = "InsertEnter"` only, so on a fresh session
--    ':' never loaded the plugin and nothing completed until some unrelated
--    InsertEnter happened to fire first. "CmdlineEnter" is load-bearing, not
--    decoration.
--
-- 2) THE MODE-DISPATCH DELTAS. Cmdline is a separate blink mode that ignores
--    sources.default / sources.per_filetype entirely (sources/lib/init.lua
--    get_enabled_provider_ids) and reads cmdline.sources instead. Only SEVEN
--    config leaves are mode-dispatchable (config/init.lua apply_mode_specific):
--    the two trigger char lists, list.selection.preselect, .auto_insert,
--    menu.auto_show, menu.draw.columns and ghost_text.enabled. Everything else
--    is shared with insert mode. So `draw.columns` genuinely does leak: this
--    config's insert-mode columns carry a `source_name` column, which in
--    cmdline renders "Cmdline"/"Buffer" on every single row. Upstream LazyVim
--    never hits this because it keeps blink's default two-column draw.
--
-- Deliberate divergence from LazyVim, asserted below: LazyVim's auto_show is
-- `function(ctx) return vim.fn.getcmdtype() == ":" end`. getcmdtype() returns
-- "" inside the command-line window (q:), so LazyVim silently DISABLES the
-- cmdwin auto-show that blink enables by default. The cmdwin arm is kept here.
--
-- This drives the REAL plugin spec table (dofile) and calls the real auto_show
-- predicate against stubbed cmdtype values. No source introspection.
--
-- Discriminating power:
--   * Reverting to `event = "InsertEnter"` (string or table) -> fails the
--     CmdlineEnter assertion.
--   * Dropping the cmdline block -> fails every opts.cmdline assertion.
--   * Restoring preselect = true (blink's default) -> fails the preselect
--     assertion; that default auto-inserts the top match over what you typed.
--   * Copying LazyVim's auto_show verbatim -> cmdwin arm returns false, failing
--     the cmdwin case.
--   * Letting cmdline inherit the insert-mode draw.columns -> the source_name /
--     kind_icon assertions fail.
--   * Re-enabling <Right>/<Left> -> fails the arrow-key assertions.
--   * Adding any vault provider to cmdline.sources -> fails the leak guard.
--
-- Run with: nvim --headless -u NONE -l tests/blink_cmdline_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_false, _H.assert_nil

local plug = dofile(vim.fn.stdpath("config") .. "/lua/andrew/plugins/blink-cmp.lua")

test("plugin spec returns a table for saghen/blink.cmp", function()
  assert_true(type(plug) == "table", "spec must return a table")
  assert_eq(plug[1], "saghen/blink.cmp", "spec must point at saghen/blink.cmp")
end)

test("loads on CmdlineEnter as well as InsertEnter", function()
  -- Without CmdlineEnter the cmdline block below is dead config: blink installs
  -- its 'c'-mode maps at setup(), which never runs if ':' does not load it.
  assert_true(type(plug.event) == "table", "event must be a table (not the bare InsertEnter string)")
  local ev = {}
  for _, e in ipairs(plug.event) do
    ev[e] = true
  end
  assert_true(ev["InsertEnter"], "event must still contain InsertEnter")
  assert_true(ev["CmdlineEnter"], "event must contain CmdlineEnter or ':' never loads blink")
end)

test("cmdline block exists", function()
  assert_true(type(plug.opts) == "table", "opts must be a table")
  assert_true(type(plug.opts.cmdline) == "table", "opts.cmdline must be a table")
end)

test("arrow keys stay as cursor movement", function()
  local km = plug.opts.cmdline.keymap
  assert_true(type(km) == "table", "cmdline.keymap must be a table")
  assert_eq(km.preset, "cmdline", "cmdline keymap preset must be 'cmdline'")
  -- blink's cmdline preset binds these to select_next/select_prev; an explicit
  -- `false` unbinds them so they move the caret instead. This must be an
  -- identity check, NOT assert_false: a missing key is also falsy, but means
  -- the preset binding is live again -- the exact regression being guarded.
  assert_eq(km["<Right>"], false, "<Right> must be explicitly false (native cursor movement)")
  assert_eq(km["<Left>"], false, "<Left> must be explicitly false (native cursor movement)")
end)

test("no item is preselected when the menu opens", function()
  -- blink defaults preselect=true, which rewrites the typed command with the
  -- top match before the user has chosen anything.
  local sel = plug.opts.cmdline.completion.list.selection
  assert_false(sel.preselect, "cmdline preselect must be false")
end)

test("auto_show fires on ':' and in cmdwin, but not on '/' or '?'", function()
  local auto_show = plug.opts.cmdline.completion.menu.auto_show
  assert_true(type(auto_show) == "function", "auto_show must be a function")

  local real_getcmdtype = vim.fn.getcmdtype
  local cmdtype = ""
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.getcmdtype = function()
    return cmdtype
  end
  local ok, err = pcall(function()
    cmdtype = ":"
    assert_true(auto_show({ mode = "cmdline" }), "must auto-show for ':' commands")

    cmdtype = "/"
    assert_false(auto_show({ mode = "cmdline" }), "must NOT auto-show for '/' search")

    cmdtype = "?"
    assert_false(auto_show({ mode = "cmdline" }), "must NOT auto-show for '?' search")

    -- The LazyVim divergence: getcmdtype() is "" in the command-line window, so
    -- a bare `getcmdtype() == ":"` would drop blink's default cmdwin behaviour.
    cmdtype = ""
    assert_true(auto_show({ mode = "cmdwin" }), "must auto-show in the cmdline window (q:)")
  end)
  vim.fn.getcmdtype = real_getcmdtype
  if not ok then
    error(err, 0)
  end
end)

test("cmdline menu drops the insert-mode kind_icon / source_name columns", function()
  -- draw.columns IS mode-dispatchable, so without this override cmdline rows
  -- would each carry a kind icon and a literal "Cmdline"/"Buffer" label.
  local cols = plug.opts.cmdline.completion.menu.draw.columns
  assert_true(type(cols) == "table", "cmdline draw.columns must be a table")

  local seen = {}
  for _, column in ipairs(cols) do
    for _, component in ipairs(column) do
      seen[component] = true
    end
  end
  assert_true(seen["label"], "cmdline columns must render the label")
  assert_nil(seen["source_name"], "cmdline columns must not carry source_name")
  assert_nil(seen["kind_icon"], "cmdline columns must not carry kind_icon")

  -- align_to defaults to 'label'; blink validates that the target component is
  -- actually present in columns, so dropping 'label' would break setup().
  assert_true(seen["label"], "align_to='label' requires a label component")

  -- Guard the insert-mode menu still HAS source_name, i.e. this is a cmdline
  -- override and not an accidental global narrowing.
  local ins = {}
  for _, column in ipairs(plug.opts.completion.menu.draw.columns) do
    for _, component in ipairs(column) do
      ins[component] = true
    end
  end
  assert_true(ins["source_name"], "insert-mode menu must keep its source_name column")
end)

test("vault providers cannot leak into cmdline sources", function()
  -- Cmdline ignores sources.default/per_filetype, so the only way a vault
  -- source could fire on ':' is an explicit cmdline.sources entry.
  local srcs = plug.opts.cmdline.sources
  if srcs == nil then
    -- Unset is correct: blink's default is { "buffer", "cmdline" }.
    return
  end
  assert_true(type(srcs) == "table", "if set, cmdline.sources must be a table")
  local banned = {
    wikilinks = true,
    vault_tags = true,
    vault_frontmatter = true,
    vault_inline_fields = true,
    spell = true,
    fortran_docs = true,
    snippets = true,
  }
  for _, s in ipairs(srcs) do
    assert_nil(banned[s], "cmdline.sources must not contain the buffer-only source " .. tostring(s))
  end
end)

test("ghost text enabled for the noice-rendered cmdline", function()
  assert_true(plug.opts.cmdline.completion.ghost_text.enabled, "cmdline ghost_text must be enabled")
end)

_H.finish({ style = "results", exit = "os" })
