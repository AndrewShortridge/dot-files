-- Behavioral spec for Obsidian-style readable line length (readable_width.lua).
--
-- Drives the REAL module against REAL windows in a temp session -- no mocks, no
-- source introspection. Window geometry is observable headless (nvim_win_get_width
-- works fine); only `columns` is pinned at 80, so the spec targets a 30-column
-- text width to leave room for pads.
--
-- What each test would catch:
--   * "caps the text area"      -- drop the corrective iteration in apply() and
--                                  the content text width lands off-target by
--                                  exactly `textoff`, failing the == assertion.
--   * "idempotent"              -- remove the coalescing early-out (the
--                                  left_w == want_left check) and the second
--                                  apply() returns "applied", not "unchanged".
--                                  Remove the `total` pad-reclaim instead and the
--                                  content shrinks on every pass.
--   * "survives a winfixwidth neighbour" -- drop the winfixwidth exemption in the
--                                  vertical-neighbour bail-out and opening the
--                                  vault sidebar tears the pads down.
--   * "bails on a real vsplit"  -- drop the bail-out entirely and padding is
--                                  applied to an ambiguous layout.
--   * "narrow window keeps its columns" -- drop the min_pad_width floor and a
--                                  small window gets pads it cannot afford.
--   * "disable() removes pads"  -- lifecycle.
--
-- Run with: nvim --headless -u NONE -l tests/readable_width_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_match = _H.test, _H.assert_eq, _H.assert_true, _H.assert_match

local root = vim.fn.stdpath("config")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local config = require("andrew.vault.config")
local rw = require("andrew.vault.readable_width")

local TARGET = 30
config.readable_width.columns = TARGET
config.readable_width.enabled = true

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function reset()
  rw.disable()
  vim.cmd("silent! only!")
  rw.enable()
end

local function md_buf()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# T", "- [ ] task", "body" })
  vim.bo[buf].filetype = "markdown"
  return buf
end

local function is_pad(win)
  local ok, v = pcall(vim.api.nvim_win_get_var, win, "vault_readable_pad")
  return ok and v == true
end

local function pads()
  local n = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_pad(w) then n = n + 1 end
  end
  return n
end

local function text_width(win)
  local info = vim.fn.getwininfo(win)[1]
  return vim.api.nvim_win_get_width(win) - info.textoff
end

-- ---------------------------------------------------------------------------

test("caps the markdown text area at the configured column count", function()
  reset()
  vim.api.nvim_set_current_buf(md_buf())
  local content = vim.api.nvim_get_current_win()
  vim.wo[content].number = true
  vim.wo[content].foldcolumn = "1"

  assert_eq(rw.apply(), "applied", "first apply should create pads:")
  assert_eq(pads(), 2, "should create exactly two pads:")
  -- The corrective iteration must absorb the gutter, so TEXT (not window) width
  -- is what lands on target.
  assert_eq(text_width(content), TARGET, "content text width:")
end)

test("is idempotent: a second apply is a no-op, not a further shrink", function()
  reset()
  vim.api.nvim_set_current_buf(md_buf())
  local content = vim.api.nvim_get_current_win()
  rw.apply()
  local after_first = text_width(content)

  assert_eq(rw.apply(), "unchanged", "second apply should coalesce to unchanged:")
  assert_eq(text_width(content), after_first, "width must not drift on re-apply:")
  assert_eq(rw.apply(), "unchanged", "third apply likewise:")
  assert_eq(text_width(content), after_first, "width still stable:")
  assert_eq(pads(), 2, "no extra pads accumulated:")
end)

test("survives a winfixwidth neighbour (the vault sidebar)", function()
  reset()
  local buf = md_buf()
  vim.api.nvim_set_current_buf(buf)
  local content = vim.api.nvim_get_current_win()
  rw.apply()

  -- Mimic sidebar.lua:102-110 -- botright vsplit, fixed width, winfixwidth.
  vim.cmd("botright vsplit")
  local sb = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(sb, vim.api.nvim_create_buf(false, true))
  vim.api.nvim_win_set_width(sb, 12)
  vim.wo[sb].winfixwidth = true
  vim.api.nvim_set_current_win(content)

  assert_true(rw.apply() ~= "removed", "sidebar must not tear down padding:")
  assert_eq(pads(), 2, "pads survive the sidebar:")
  assert_eq(text_width(content), TARGET, "text width held constant across sidebar open:")
end)

test("bails out on a genuine vertical split rather than guessing", function()
  reset()
  vim.api.nvim_set_current_buf(md_buf())
  rw.apply()
  assert_eq(pads(), 2, "precondition: padded:")

  vim.cmd("vsplit")
  vim.api.nvim_set_current_buf(md_buf())

  assert_eq(rw.apply(), "removed", "an ambiguous layout must remove padding:")
  assert_eq(pads(), 0, "all pads torn down:")
end)

test("a window too narrow to pad keeps all its columns", function()
  reset()
  vim.api.nvim_set_current_buf(md_buf())
  local content = vim.api.nvim_get_current_win()
  local saved = config.readable_width.columns
  -- Target wider than the window can afford alongside min_pad_width on both sides.
  config.readable_width.columns = vim.o.columns - 4

  local status = rw.apply()
  assert_true(status == "unchanged" or status == "removed", "should refuse to pad:")
  assert_eq(pads(), 0, "no pads on a too-narrow window:")
  assert_true(text_width(content) > 0, "content still has columns:")

  config.readable_width.columns = saved
end)

test("disable() removes every pad; enable() restores them", function()
  reset()
  vim.api.nvim_set_current_buf(md_buf())
  rw.apply()
  assert_eq(pads(), 2, "precondition: padded:")

  rw.disable()
  assert_eq(pads(), 0, "disable tears down pads:")
  assert_eq(rw.enabled(), false, "disable flips the flag:")

  rw.enable()
  assert_eq(rw.enabled(), true, "enable flips it back:")
  assert_eq(pads(), 2, "enable re-creates pads:")
end)

test("pad windows are scratch, fixed-width and unlisted", function()
  reset()
  vim.api.nvim_set_current_buf(md_buf())
  rw.apply()
  local seen = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_pad(w) then
      seen = seen + 1
      local b = vim.api.nvim_win_get_buf(w)
      assert_eq(vim.bo[b].buftype, "nofile", "pad buftype:")
      assert_eq(vim.bo[b].buflisted, false, "pad must not be listed:")
      -- winfixwidth is what stops 'equalalways' rebalancing the pads away.
      assert_eq(vim.wo[w].winfixwidth, true, "pad winfixwidth:")
      assert_eq(vim.wo[w].number, false, "pad has no number column:")
    end
  end
  assert_eq(seen, 2, "checked both pads:")
end)

test("never leaves the text NARROWER than the target it was asked for", function()
  -- The invariant that matters: padding may decline, but it must never make the
  -- reading column worse than doing nothing. apply() derives its budget from
  -- window widths, which can be stale in the same tick as a layout change; when
  -- that happens it over-pads, the corrective iteration hits the min_pad floor
  -- and declines, and without the verify-and-give-up guard the text ends up
  -- narrower than requested. Drop that guard and this fails.
  local saved = config.readable_width.columns
  local checked, applied = 0, 0
  for _, target in ipairs({ 20, 25, 30, 36, 44, 55, 70 }) do
    for _, gutter in ipairs({ { false, "0", "no" }, { true, "1", "yes" }, { true, "2", "yes:2" } }) do
      config.readable_width.columns = target
      reset()
      vim.api.nvim_set_current_buf(md_buf())
      local w = vim.api.nvim_get_current_win()
      vim.wo[w].number = gutter[1]
      vim.wo[w].foldcolumn = gutter[2]
      vim.wo[w].signcolumn = gutter[3]

      local status = rw.apply()
      checked = checked + 1
      if status == "applied" then
        applied = applied + 1
        assert_eq(text_width(w), target,
          string.format("target=%d gutter=%s must land exactly:", target, gutter[2]))
      else
        assert_eq(pads(), 0, "a declined apply must leave no pads behind:")
      end
    end
  end
  assert_true(checked == 21, "swept every combination:")
  assert_true(applied > 0, "at least some combinations should actually pad:")

  -- Restore: the loop leaves `columns` at its last value, which is wider than an
  -- 80-column test session can afford, so every later test would decline to pad.
  config.readable_width.columns = saved
  reset()
end)

-- Must run BEFORE the not-yet-settled-layout test below, which mutates the
-- global 'columns'. Headless nvim never re-settles window widths after that, so
-- anything following it sees stale geometry.
test("setup() registers the toggle command and the <leader>uW keybind", function()
  rw.setup()

  local cmds = vim.api.nvim_get_commands({})
  assert_true(cmds.VaultReadableWidth ~= nil, "VaultReadableWidth command:")

  local map = vim.fn.maparg("<leader>uW", "n", false, true)
  assert_true(map and map.callback ~= nil, "<leader>uW must be mapped to a callback:")
  assert_match(map.desc or "", "[Rr]eadable width", "keybind description:")

  -- The binding must actually round-trip: capped -> full window -> capped.
  reset()
  vim.api.nvim_set_current_buf(md_buf())
  local w = vim.api.nvim_get_current_win()
  rw.apply()
  local capped = text_width(w)
  assert_eq(pads(), 2, "precondition: padded:")

  map.callback()
  assert_eq(pads(), 0, "toggle off must remove pads (full window):")
  assert_true(text_width(w) > capped, "full width must exceed the capped width:")

  map.callback()
  assert_eq(pads(), 2, "toggle on must restore pads:")
  assert_eq(text_width(w), capped, "and restore the same capped width:")
end)

test("setup() pads a markdown window that is already visible", function()
  -- setup() runs from a scheduled tick inside the first markdown FileType, so
  -- that window's BufWinEnter has already fired. Drop the trailing schedule()
  -- and this window stays unpadded until the next unrelated window event.
  reset()
  vim.api.nvim_set_current_buf(md_buf())
  rw.apply()
  -- Strip the pads and the autocmds a previous setup() left behind, so the
  -- only thing that can re-pad this window is setup() itself.
  pcall(vim.api.nvim_del_augroup_by_name, "VaultReadableWidth")
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_pad(w) then vim.api.nvim_win_close(w, true) end
  end
  assert_eq(pads(), 0, "precondition: no pads before setup:")
  assert_true(rw.enabled(), "precondition: feature enabled:")

  rw.setup()
  assert_eq(pads(), 0, "setup() itself must not mutate the layout synchronously:")
  vim.wait(config.readable_width.debounce_ms + 200, function() return pads() == 2 end)
  assert_eq(pads(), 2, "setup() must pad the already-visible markdown window:")
end)

test("pads are removed when the content window switches to a non-markdown buffer", function()
  -- Drop the had_pads teardown in apply()'s no-content branch and the .txt
  -- buffer stays centred between two stale pads.
  reset()
  vim.api.nvim_set_current_buf(md_buf())
  rw.apply()
  assert_eq(pads(), 2, "precondition: padded:")

  local txt = vim.api.nvim_create_buf(true, false)
  vim.bo[txt].filetype = "text"
  vim.api.nvim_set_current_buf(txt)
  assert_eq(rw.apply(), "removed", "apply() with no markdown window must tear pads down:")
  assert_eq(pads(), 0, "no pads may remain around a non-markdown buffer:")

  -- And the pads come back when a markdown buffer is shown again.
  vim.api.nvim_set_current_buf(md_buf())
  assert_eq(rw.apply(), "applied", "re-pads when markdown returns:")
  assert_eq(pads(), 2, "padded again:")
end)

-- MUST STAY LAST IN THIS FILE. It mutates the global 'columns' to force the
-- stale-geometry path, and headless nvim does not re-settle window widths
-- afterwards, so any test ordered after this one would read stale widths.
test("declines cleanly when applied against a not-yet-settled layout", function()
  -- Reproduces the one case a width sweep found: apply() budgets from window
  -- widths, and immediately after the editor is resized those are still the
  -- PRE-resize values. Budgeting from a too-large total over-pads; the
  -- corrective iteration then hits the min_pad floor and declines, leaving the
  -- text narrower than doing nothing at all. M.schedule() defers past this in
  -- normal use, but a direct apply() (or a hand-rolled VimResized handler)
  -- can hit it, so apply() must verify and hand the columns back.
  --
  -- Discriminating power: stub out the `short` check and this reports a text
  -- width far below target; stub out the corrective iteration and the same.
  local saved_cols, saved_target = vim.o.columns, config.readable_width.columns
  reset()
  config.readable_width.columns = 30
  vim.api.nvim_set_current_buf(md_buf())
  local w = vim.api.nvim_get_current_win()
  vim.wo[w].number = false
  vim.wo[w].foldcolumn = "0"
  vim.wo[w].signcolumn = "no"

  -- Shrink the editor and apply in the SAME tick, with no scheduling in between.
  vim.o.columns = 60
  local status = rw.apply()

  if status == "applied" then
    assert_eq(text_width(w), 30, "if it claims success the width must be real:")
  else
    assert_eq(pads(), 0, "a declined apply must leave no pads behind:")
    assert_true(text_width(w) > 30, "content keeps its columns when padding declines:")
  end

  vim.o.columns = saved_cols
  config.readable_width.columns = saved_target
  reset()
end)

_H.finish({ style = "results", exit = "os" })
