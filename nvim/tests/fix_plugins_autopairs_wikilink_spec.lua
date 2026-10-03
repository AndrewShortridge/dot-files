-- Spec for the markdown `[[` -> blink re-show hook in plugins/autopairs.lua.
--
-- THE BUG. nvim-autopairs maps `[` as an expr mapping that returns
-- `[` .. `]` .. <Left>, so BOTH characters travel through InsertCharPre.
-- blink.cmp records only the last one (lib/buffer_events.lua: InsertCharPre
-- stores `vim.v.char`, TextChangedI reads it), so after typing `[[` blink saw
-- `]` -- neither one of the wikilink source's trigger characters (`[ # ^`) nor
-- a keyword character -- and called trigger.hide(). Measured in a real pty:
-- `[[` gave `[[]]` with 0 items and no menu; `[[a` gave items. Disabling
-- autopairs made the same keystrokes produce 32 items, proving the cause.
--
-- THE FIX. The `[` rule's end_pair callback still returns `]` (the pair is
-- wanted: vault/completion.lua strips the `]]` from insertText when it is
-- already after the cursor, which is what keeps an accepted item at exactly
-- one `[[Note]]`), but when the character before the typed `[` is another `[`
-- in a markdown buffer it schedules `require("blink.cmp").show()`.
--
-- Discriminating power:
--   * Removing the hook                -> "schedules a show" test fails.
--   * Hooking it for every `[`         -> the single-bracket / non-markdown
--                                         tests fail.
--   * Returning anything but "]"       -> "still auto-closes" test fails
--                                         (autopairs would insert the wrong
--                                         closing text).
--
-- Drives the REAL plugin spec: the config() body runs against the REAL
-- nvim-autopairs on the runtimepath, and the assertions call the rule callback
-- autopairs itself would call.
--
-- Run with: nvim --headless -u NONE -l tests/fix_plugins_autopairs_wikilink_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

local cfg = vim.fn.stdpath("config")
local lazy_root = vim.fn.stdpath("data") .. "/lazy"

if vim.fn.isdirectory(lazy_root .. "/nvim-autopairs") == 0 then
  print("  SKIP: nvim-autopairs not installed")
  _H.finish({ style = "results" })
  return
end
vim.opt.runtimepath:prepend(lazy_root .. "/nvim-autopairs")

-- blink.cmp is stubbed: the point of the hook is THAT it asks blink to show,
-- and a real blink needs a running UI/binary.
local shown = 0
package.loaded["blink.cmp"] = { show = function() shown = shown + 1 end }

local spec = dofile(cfg .. "/lua/andrew/plugins/autopairs.lua")
spec.config(spec, spec.opts)

local autopairs = require("nvim-autopairs")
local rule = autopairs.get_rule("[")
rule = rule and (rule.replace_endpair and rule or rule[1])

test("the `[` rule exists and now has an end-pair callback", function()
  assert_true(rule ~= nil, "no `[` rule registered")
  assert_eq(type(rule.end_pair_func), "function", "end_pair_func")
end)

--- Make a scratch buffer of the given filetype.
local function buf_of(ft)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = ft
  return b
end

local md, lua_buf = buf_of("markdown"), buf_of("lua")

--- Call the rule exactly as nvim-autopairs' autopairs_map does: `col` is the
--- 1-based index of the `[` being typed, `line` is the line BEFORE insertion.
--- Returns the end pair plus how many blink shows were scheduled.
local function pair(opts)
  shown = 0
  local real_mode = vim.api.nvim_get_mode
  -- The scheduled callback bails unless we are still in insert mode.
  vim.api.nvim_get_mode = function() return { mode = "i" } end
  local ret = rule:get_end_pair(opts)
  vim.wait(100, function() return shown > 0 end)
  vim.api.nvim_get_mode = real_mode
  return ret, shown
end

test("second `[` in markdown still auto-closes AND schedules a blink show", function()
  local ret, n = pair({ char = "[", line = "link: [", col = 8, bufnr = md })
  assert_eq(ret, "]", "the pair must still be inserted")
  assert_eq(n, 1, "blink.cmp.show() should have been scheduled exactly once")
end)

test("a single `[` in markdown pairs without touching blink", function()
  local ret, n = pair({ char = "[", line = "see ", col = 5, bufnr = md })
  assert_eq(ret, "]")
  assert_eq(n, 0, "a lone `[` is not a wikilink opener")
end)

test("`[[` at the very start of a line does not index off the front", function()
  local ret, n = pair({ char = "[", line = "[", col = 2, bufnr = md })
  assert_eq(ret, "]")
  assert_eq(n, 1)
  -- col = 1 means there is no preceding character at all.
  local ret2, n2 = pair({ char = "[", line = "", col = 1, bufnr = md })
  assert_eq(ret2, "]")
  assert_eq(n2, 0)
end)

test("`[[` outside markdown is left alone", function()
  local ret, n = pair({ char = "[", line = "local t = a[", col = 13, bufnr = lua_buf })
  assert_eq(ret, "]")
  assert_eq(n, 0, "only markdown has wikilinks")
end)

test("typing the closing `]` does not schedule a show", function()
  local ret, n = pair({ char = "]", line = "link: [[", col = 9, bufnr = md })
  assert_eq(ret, "]")
  assert_eq(n, 0)
end)

test("the hook survives blink.cmp being absent", function()
  local saved = package.loaded["blink.cmp"]
  package.loaded["blink.cmp"] = nil
  package.preload["blink.cmp"] = function() error("blink not installed") end
  local real_mode = vim.api.nvim_get_mode
  vim.api.nvim_get_mode = function() return { mode = "i" } end
  local ok, err = pcall(rule.get_end_pair, rule, { char = "[", line = "x [", col = 4, bufnr = md })
  vim.wait(80)
  vim.api.nvim_get_mode = real_mode
  package.preload["blink.cmp"] = nil
  package.loaded["blink.cmp"] = saved
  assert_true(ok, "rule raised without blink: " .. tostring(err))
end)

_H.finish({ style = "results" })
