-- Spec for andrew.lsp_float -- the wrapper around
-- vim.lsp.util.open_floating_preview that every LSP float in this config goes
-- through (hover, signature help, the Fortran custom-documentation float).
--
-- WHY THIS MODULE EXISTS AT ALL
--
-- The code used to sit inside the `config` function of the nvim-lspconfig
-- plugin spec, where no spec could reach it without booting lazy.nvim and the
-- whole plugin set. Two defects lived there unnoticed until the float was
-- captured out of a running editor on 2026-09-13. Moving it to
-- andrew.lsp_float (at the andrew.* level, NOT under andrew/plugins/, which
-- lazy.lua imports wholesale as plugin specs) is what makes the four
-- assertions below possible.
--
-- WHAT IT PINS
--
--   1. The size is a CAP, not a size. The old code SET every float to
--      `clamp(0.5*columns,40,120) x clamp(0.3*lines,8,40)`, which is wrong in
--      both directions at once: a 2-line fortls hover (`INTEGER :: nsz`) was
--      inflated to 18 rows of empty float, and a 151-line intrinsic doc was
--      truncated to 18 -- 84 buffer lines in a 15-line window, 82% of it
--      off-screen. Neovim already sizes a float to its contents; the only
--      legitimate job here is an upper bound.
--   2. `wrap` is on. open_floating_preview's own default is
--      `opts.wrap = opts.wrap ~= false` (vim/lsp/util.lua:1682, applied at
--      :1796) -- and the captured float still came back `wrap=false`, with a
--      617-character line cut off horizontally rather than wrapped. The
--      default is not enough; the window option is set explicitly after the
--      window exists, and asserted here.
--   3. The title says what the float IS. Every Fortran hover, on all five
--      probes, was titled "PY-LSP Function Documentation Preview" and every
--      signature float "TY Function Parameter Popup" -- hardcoded strings
--      naming whichever Python server the config was tuned for last.
--   4. `vim.b.lsp_popup_kind` is cleared. It is set in four places (the K
--      handler, the <C-k> handler, the Python/ty branch, and
--      andrew.lsp_keymaps.signature_help) and was never reset, so any
--      unrelated float opened later in the same buffer inherited the last
--      kind and was titled accordingly.
--
-- Headless nvim with no UI attached reports lines=24, columns=80, so the caps
-- are `min(floor(80*0.50), 120) = 40` columns and `min(floor(24*0.30), 40) = 7`
-- lines. The numbers are asserted literally as well as through max_size(), so a
-- change to the fractions cannot quietly pass.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "a short float keeps its own height" fails the moment the cap becomes an
--     assignment again -- verified by restoring `new_cfg.height = target_h`,
--     which inflates the 3-line float to 7.
--   * "a long float is capped" fails if the cap is dropped: nvim sizes a
--     200-line float to the available screen height, well past 7.
--   * "the cap never grows a float" is the same property stated on width, and
--     fails if `math.min` becomes `clamp` with a minimum again.
--   * "wrap is on" fails if the float is opened with wrap off (verified by
--     defaulting `opts.wrap` to false). It does NOT discriminate against
--     deleting the explicit `vim.wo[winid].wrap` line: nvim's own default
--     already yields true under `-u NONE` with no UI. The explicit set stays
--     because a real editor WAS captured with wrap=false and a 617-character
--     line running off the right edge -- this assertion is the guard, not the
--     reproduction. "a caller can still turn wrap off" pins the other half.
--   * "a hover float is titled Documentation" / "a signature float is titled
--     Signature Help" fail if the hardcoded PY-LSP/TY strings come back.
--   * "a caller-supplied title survives" fails if the title is assigned
--     unconditionally -- nvim's own signature_help passes the function name,
--     which is strictly better than anything this layer can derive.
--   * "the popup kind is cleared" fails if the reset is removed: the third
--     float in the sequence, opened with no kind set, is then still titled
--     "Documentation".
--   * "the kind is cleared on the SOURCE buffer, not on the float" fails if
--     the reset goes back to bare `vim.b.lsp_popup_kind = nil` after the call
--     (verified by reverting that one line): on the focus-reuse path -- the
--     second K on the same word -- nvim has already made the float the current
--     window, so the clear lands on the float's scratch buffer and the file
--     being edited stays marked "hover" for the rest of the session.
--   * "setup is idempotent" fails if the wrapper stacks -- a second layer
--     would re-enter the title logic after the kind was already cleared, and
--     the plugin spec's config CAN re-run.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_hover_float_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local float = require("andrew.lsp_float")
float.setup()

-- Headless nvim, no UI: the dimensions the caps are computed from.
local EDITOR_LINES, EDITOR_COLUMNS = 24, 80
local MAX_W, MAX_H = 40, 7

--- `n` lines of content, each long enough to be worth wrapping.
---@param n integer
---@return string[]
local function lines(n)
  local out = {}
  for i = 1, n do
    out[i] = "line " .. i .. " " .. string.rep("w", 30)
  end
  return out
end

--- Open a float and hand back its config plus its window options, then close
--- it -- floats left open would be reused or closed by the next probe's
--- close_events and make the following assertions depend on order.
---@param contents string[]
---@param opts table|nil
---@return table cfg nvim_win_get_config of the float
---@return boolean wrap
local function open(contents, opts)
  local _, winid = vim.lsp.util.open_floating_preview(contents, "markdown", opts or {})
  assert(winid and vim.api.nvim_win_is_valid(winid), "no float was created")
  local cfg = vim.api.nvim_win_get_config(winid)
  local wrap = vim.wo[winid].wrap
  pcall(vim.api.nvim_win_close, winid, true)
  return cfg, wrap
end

--- The title as a plain string (nvim returns it as {{text, hl}, ...} chunks).
---@param cfg table
---@return string|nil
local function title_of(cfg)
  if type(cfg.title) ~= "table" then
    return cfg.title
  end
  local parts = {}
  for _, chunk in ipairs(cfg.title) do
    parts[#parts + 1] = type(chunk) == "table" and chunk[1] or chunk
  end
  return table.concat(parts)
end

-- ---------------------------------------------------------------------------
-- The editor this runs in
-- ---------------------------------------------------------------------------

test("the headless editor is the 24x80 the caps assume", function()
  assert_eq(vim.o.lines, EDITOR_LINES, "lines:")
  assert_eq(vim.o.columns, EDITOR_COLUMNS, "columns:")
  local w, h = float.max_size()
  assert_eq(w, MAX_W, "max width (floor(80*0.50), under the 120 ceiling):")
  assert_eq(h, MAX_H, "max height (floor(24*0.30), under the 40 ceiling):")
end)

-- ---------------------------------------------------------------------------
-- Cap, not set
-- ---------------------------------------------------------------------------

test("a short float keeps its own height", function()
  -- THE regression test. Three lines of content stay three rows; the old code
  -- forced this to 7 here (and to 18 on the 60-line terminal it was captured
  -- on, for a two-line hover).
  local cfg = open(lines(3))
  assert_eq(cfg.height, 3, "3 lines of content:")
  assert_true(cfg.height < MAX_H, "and it is genuinely below the cap:")
end)

test("a long float is capped", function()
  local cfg = open(lines(200))
  assert_eq(cfg.height, MAX_H, "200 lines of content:")
end)

test("the cap never grows a float", function()
  -- Width states the same property: the content here is ~37 columns wide, and
  -- a float sized rather than capped would be widened to 40.
  local cfg = open(lines(3))
  assert_true(cfg.width <= MAX_W, "width is within the cap:")
  assert_true(cfg.width < MAX_W, "and not padded out to it:")
end)

test("enforce_float_size ignores non-floating and dead windows", function()
  -- Called on every float; it must not throw on the ordinary window it is
  -- handed if a caller ever gets that wrong, nor on an already-closed one.
  float.enforce_float_size(nil)
  float.enforce_float_size(vim.api.nvim_get_current_win())
  float.enforce_float_size(999999)
  assert_true(true, "no error:")
end)

-- ---------------------------------------------------------------------------
-- Wrap
-- ---------------------------------------------------------------------------

test("wrap is on", function()
  local _, wrap = open(lines(3))
  assert_true(wrap, "float window wrap:")
end)

test("a caller can still turn wrap off", function()
  local _, wrap = open(lines(3), { wrap = false })
  assert_true(wrap == false, "explicit wrap = false:")
end)

-- ---------------------------------------------------------------------------
-- Title
-- ---------------------------------------------------------------------------

test("a hover float is titled Documentation", function()
  vim.b.lsp_popup_kind = "hover"
  local cfg = open(lines(3))
  assert_eq(title_of(cfg), "Documentation", "title:")
end)

test("a signature float is titled Signature Help", function()
  vim.b.lsp_popup_kind = "signature"
  local cfg = open(lines(3))
  assert_eq(title_of(cfg), "Signature Help", "title:")
end)

test("an unmarked float is titled LSP Preview", function()
  vim.b.lsp_popup_kind = nil
  local cfg = open(lines(3))
  assert_eq(title_of(cfg), "LSP Preview", "title:")
end)

test("no title names a language server", function()
  -- The two strings that shipped: a Fortran hover read "PY-LSP Function
  -- Documentation Preview" on every probe.
  for _, kind in ipairs({ "hover", "signature" }) do
    vim.b.lsp_popup_kind = kind
    local t = title_of(open(lines(3)))
    assert_true(not t:match("PY%-LSP"), kind .. ": no PY-LSP:")
    assert_true(not t:match("^TY "), kind .. ": no TY:")
  end
end)

test("a caller-supplied title survives", function()
  vim.b.lsp_popup_kind = "signature"
  local cfg = open(lines(3), { title = "MPI_Comm_rank(comm, rank, ierror)" })
  assert_eq(title_of(cfg), "MPI_Comm_rank(comm, rank, ierror)", "title:")
end)

test("the border is rounded unless the caller says otherwise", function()
  vim.b.lsp_popup_kind = nil
  local cfg = open(lines(3))
  assert_true(type(cfg.border) == "table" or cfg.border == "rounded", "border present:")
end)

-- ---------------------------------------------------------------------------
-- The popup-kind marker
-- ---------------------------------------------------------------------------

test("the popup kind is cleared", function()
  vim.b.lsp_popup_kind = "hover"
  open(lines(3))
  assert_nil(vim.b.lsp_popup_kind, "after the float is created:")
end)

test("the kind is cleared on the SOURCE buffer, not on the float", function()
  -- The focus-reuse path, which is what the second `K` takes.
  -- open_floating_preview with `focus_id` + `focus` finds the float already
  -- open for this buffer and does `nvim_set_current_win(float)` (util.lua
  -- :1704-1709), so by the time it returns, the CURRENT buffer is the float's.
  -- Clearing `vim.b.lsp_popup_kind` at that point marks the float's throwaway
  -- scratch buffer and leaves the source buffer marked "hover" forever: every
  -- later float in the file the user is editing is titled "Documentation".
  local src_win = vim.api.nvim_get_current_win()
  local src_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(src_win, src_buf)

  local reuse = { focus_id = "spec_reuse", focus = true, focusable = true }

  vim.b[src_buf].lsp_popup_kind = "hover"
  local _, first = vim.lsp.util.open_floating_preview(lines(3), "markdown", vim.deepcopy(reuse))
  assert_true(first and vim.api.nvim_win_is_valid(first), "the first float opened:")
  assert_eq(vim.api.nvim_get_current_win(), src_win, "and the cursor stayed in the source window:")

  -- The second K, on the same word: nvim enters the existing float.
  vim.b[src_buf].lsp_popup_kind = "hover"
  local _, second = vim.lsp.util.open_floating_preview(lines(3), "markdown", vim.deepcopy(reuse))
  assert_eq(second, first, "the same float was reused:")
  assert_eq(vim.api.nvim_get_current_win(), first, "and nvim focused it:")

  vim.api.nvim_set_current_win(src_win)
  pcall(vim.api.nvim_win_close, first, true)

  assert_nil(vim.b[src_buf].lsp_popup_kind, "the SOURCE buffer's marker after the reuse:")
  assert_eq(title_of(open(lines(3))), "LSP Preview", "so the next unmarked float is not a hover:")

  vim.api.nvim_buf_delete(src_buf, { force = true })
end)

test("a later unrelated float does not inherit the kind", function()
  -- The failure the reset prevents: K sets "hover", the float opens, and the
  -- next float in that buffer -- a diagnostic preview, a plugin's popup -- was
  -- titled "Documentation" because nothing ever put the marker back.
  vim.b.lsp_popup_kind = "hover"
  assert_eq(title_of(open(lines(3))), "Documentation", "first float:")
  assert_eq(title_of(open(lines(3))), "LSP Preview", "second, unmarked float:")
end)

-- ---------------------------------------------------------------------------
-- Installation
-- ---------------------------------------------------------------------------

test("setup is idempotent", function()
  -- The lspconfig spec's `config` can run more than once (a lazy reload, a
  -- :Lazy reload); a second wrapper layer would clear the kind marker before
  -- the outer layer reads it and every float would read "LSP Preview".
  local wrapped = vim.lsp.util.open_floating_preview
  float.setup()
  assert_true(vim.lsp.util.open_floating_preview == wrapped, "same function after a second setup:")
  vim.b.lsp_popup_kind = "hover"
  assert_eq(title_of(open(lines(3))), "Documentation", "title still resolves:")
end)

_H.finish()
