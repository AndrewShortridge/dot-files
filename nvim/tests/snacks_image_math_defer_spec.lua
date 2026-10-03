-- Spec for lua/andrew/utils/snacks-image-math.lua and the `math.latex.tpl`
-- override in lua/andrew/plugins/snacks.lua.
--
-- THE BUGS.
--   1. Empty / zero-width math (`$$ $$` the instant the `dm` autosnippet
--      expands, a half-typed `\hat{}`, an empty `align*`) compiled under
--      snacks' stock `border=0pt` template to a PDF with a 0-wide MediaBox,
--      which Ghostscript 10.02.1 rejects (`/undefined in --runpdf--`,
--      `[/PageSize [0 42.839]]`) -> "Conversion failed at step `convert`".
--   2. Every keystroke inside an equation is a new content hash -> a new
--      pdflatex + convert pair and an orphan `.tex` in the cache (1288 files
--      had piled up).
--   3. No cross-session negative cache: a permanently failing equation is
--      re-run (and re-toasted) on every nvim start.
--
-- THE FIXES.
--   1. `border={0.75pt 0pt}` in the tpl: horizontal-only, exactly 2px at the
--      192 dpi convert uses, so glyph grid phase is preserved (AE = 0 vs stock)
--      while a 0-wide page becomes impossible.
--   2. `doc._img` returns nil for a generated image whose node contains the
--      cursor in Insert/Replace mode; a ModeChanged `i*:*` hook re-renders on
--      insert exit.
--   3. `<png>.failed` marker + `Convert.run` short-circuit for cache-dir
--      sources; `:SnacksImageRetryFailed` clears it.
--
-- Discriminating power:
--   * Revert the tpl border -> test 1 fails.
--   * Drop the `_img` wrap -> "insert mode inside the equation" tests fail
--     (a match and a `.tex` are produced).
--   * Drop the mode/buffer/range gates -> the "normal mode", "other buffer",
--     "cursor outside", "file-backed image" tests fail.
--   * Drop the marker write or the `run` override -> negative-cache tests fail.
--
-- Drives the REAL config against the REAL snacks.nvim + treesitter parsers.
-- Insert mode is simulated by stubbing `nvim_get_mode` (the repo convention,
-- see fix_plugins_autopairs_wikilink_spec.lua) because a `-l` process has no
-- main loop for feedkeys to enter it.
--
-- Run with: nvim --headless -u NONE -l tests/snacks_image_math_defer_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil
local assert_false, assert_match = _H.assert_false, _H.assert_match

local cfg = vim.fn.stdpath("config")
local lazy_root = vim.fn.stdpath("data") .. "/lazy"

if vim.fn.isdirectory(lazy_root .. "/snacks.nvim") == 0 then
  print("  SKIP: snacks.nvim not installed")
  _H.finish({ style = "results" })
  return
end

vim.opt.runtimepath:prepend(lazy_root .. "/nvim-treesitter") -- latex parser
vim.opt.runtimepath:prepend(lazy_root .. "/snacks.nvim")
vim.opt.runtimepath:prepend(cfg)

-- Isolated cache so the spec never touches ~/.cache/nvim/snacks/image.
local cache = vim.fn.tempname() .. "-snacks-image"
vim.fn.mkdir(cache, "p")

local spec = dofile(cfg .. "/lua/andrew/plugins/snacks.lua")
spec.opts.image.cache = cache
spec.opts.image.convert.notify = false
spec.config(spec, spec.opts)

local Image = Snacks.image
local doc = Image.doc
local mod = require("andrew.utils.snacks-image-math")

-- ---------------------------------------------------------------------------
-- 1. template guard against zero-width pages
-- ---------------------------------------------------------------------------

test("math.latex.tpl uses a horizontal-only, integer-pixel border", function()
  local tpl = Image.config.math.latex.tpl
  assert_match(tpl, "border={0%.75pt 0pt}", "tpl border option")
  assert_false(tpl:find("border=0pt", 1, true), "stock border=0pt must be gone")
  -- rest of the template still matches snacks 882c996 defaults
  assert_match(tpl, "%${packages}")
  assert_match(tpl, "\\%${font_size}")
  assert_match(tpl, "%${content}}")
end)

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local real_get_mode = vim.api.nvim_get_mode
local function with_mode(mode, fn)
  vim.api.nvim_get_mode = function()
    return { mode = mode, blocking = false }
  end
  local ok, err = pcall(fn)
  vim.api.nvim_get_mode = real_get_mode
  if not ok then
    error(err, 0)
  end
end

local function md_buf(lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_set_current_buf(buf)
  return buf
end

-- Synchronous wrapper over the async doc.find.
local function find_all(buf)
  local got
  doc.find(buf, function(imgs)
    got = imgs
  end)
  vim.wait(2000, function()
    return got ~= nil
  end, 10)
  assert_true(got ~= nil, "doc.find never called back")
  return got
end

local function math_matches(imgs)
  return vim.tbl_filter(function(i)
    return i.type == "math"
  end, imgs)
end

local function tex_count()
  return #vim.fn.glob(cache .. "/*-content.math.tex", true, true)
end

-- ---------------------------------------------------------------------------
-- 2. cursor_in_range (pure)
-- ---------------------------------------------------------------------------

test("cursor_in_range: inside / before / after a single-line node", function()
  local r = { 3, 5, 0, 3, 9, 0 } -- $x=1$ on row 3, cols 5..9
  assert_true(mod.cursor_in_range(r, 3, 5))
  assert_true(mod.cursor_in_range(r, 3, 7))
  assert_true(mod.cursor_in_range(r, 3, 9), "end col is inclusive (appending after `$`)")
  assert_false(mod.cursor_in_range(r, 3, 4))
  assert_false(mod.cursor_in_range(r, 3, 10))
  assert_false(mod.cursor_in_range(r, 2, 7))
  assert_false(mod.cursor_in_range(r, 4, 7))
end)

test("cursor_in_range: node ending at col 0 really ends on the previous line", function()
  local r = { 1, 0, 0, 4, 0, 0 } -- `$$` block rows 1..3, node end reported as (4, 0)
  assert_true(mod.cursor_in_range(r, 2, 0))
  assert_true(mod.cursor_in_range(r, 3, 2), "closing `$$` line, any column")
  assert_true(mod.cursor_in_range(r, 3, 99))
  assert_false(mod.cursor_in_range(r, 4, 0), "<CR> after the closing `$$` leaves the block")
end)

-- ---------------------------------------------------------------------------
-- 3. the `_img` wrap: real parser, real query, stubbed mode
-- ---------------------------------------------------------------------------

local lines = {
  "# t",
  "",
  "$$",
  "E = mc^2",
  "$$",
  "",
  "inline $a+b$ here",
  "",
  "![img](does-not-exist.png)",
}

test("normal mode: both equations match and their .tex files are written", function()
  local buf = md_buf(lines)
  vim.api.nvim_win_set_cursor(0, { 4, 3 }) -- inside the $$ block
  local before = tex_count()
  local imgs = find_all(buf) -- a -l process really is in normal mode
  local maths = math_matches(imgs)
  assert_eq(#maths, 2, "math matches in normal mode")
  assert_true(tex_count() >= before + 2, ".tex files written for both equations")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("insert mode inside the $$ block: that equation is skipped, the other still renders", function()
  -- an equation no earlier test has hashed, so a write here would be visible
  local edited = vim.deepcopy(lines)
  edited[4] = "E = mc^2 + never_seen_before"
  local buf = md_buf(edited)
  vim.api.nvim_win_set_cursor(0, { 4, 3 })
  local before = tex_count()
  local maths
  with_mode("i", function()
    maths = math_matches(find_all(buf))
  end)
  assert_eq(#maths, 1, "only the inline equation should match")
  assert_eq(maths[1].range[1], 7, "the surviving match is the inline one on line 7")
  -- the skipped equation must not have produced a .tex either (the whole
  -- point of bailing out in _img rather than after find_visible)
  local written = tex_count() - before
  assert_eq(written, 0, "the skipped equation must not write a .tex (inline one was cached already)")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("insert mode on the closing $$ line still counts as editing", function()
  local buf = md_buf(lines)
  vim.api.nvim_win_set_cursor(0, { 5, 2 })
  local maths
  with_mode("i", function()
    maths = math_matches(find_all(buf))
  end)
  assert_eq(#maths, 1)
  assert_eq(maths[1].range[1], 7)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("replace mode is treated like insert mode", function()
  local buf = md_buf(lines)
  vim.api.nvim_win_set_cursor(0, { 7, 9 }) -- inside $a+b$
  local maths
  with_mode("R", function()
    maths = math_matches(find_all(buf))
  end)
  assert_eq(#maths, 1)
  assert_eq(maths[1].range[1], 3, "the $$ block survives, the inline one is skipped")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("insert mode with the cursor outside every equation: nothing is skipped", function()
  local buf = md_buf(lines)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local maths
  with_mode("i", function()
    maths = math_matches(find_all(buf))
  end)
  assert_eq(#maths, 2)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("insert mode in ANOTHER buffer never filters this one", function()
  local buf = md_buf(lines)
  local other = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(other)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local maths
  with_mode("i", function()
    maths = math_matches(find_all(buf))
  end)
  assert_eq(#maths, 2)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.api.nvim_buf_delete(other, { force = true })
end)

test("file-backed ![]() images are never deferred", function()
  local buf = md_buf(lines)
  vim.api.nvim_win_set_cursor(0, { 9, 5 }) -- inside the ![img](...) node
  local files
  with_mode("i", function()
    files = vim.tbl_filter(function(i)
      return i.type == "image"
    end, find_all(buf))
  end)
  assert_eq(#files, 1, "the ![]() match must survive insert mode")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("the ModeChanged re-render hook exists and targets insert/replace exits", function()
  local aus = vim.api.nvim_get_autocmds({ group = "andrew_snacks_image_math", event = "ModeChanged" })
  assert_true(#aus >= 2, "expected i*:* and R*:* ModeChanged autocmds")
  local pats = {}
  for _, a in ipairs(aus) do
    pats[a.pattern] = true
  end
  assert_true(pats["i*:*"], "i*:* pattern")
  assert_true(pats["R*:*"], "R*:* pattern")
end)

test("inline.update records the instance so the hook can reach it", function()
  local inline = Image.inline
  local fake = setmetatable({ buf = 4242, imgs = {}, idx = {} }, inline)
  -- swap the real body out for this call only
  local raw = getmetatable(fake).update
  assert_true(raw ~= nil)
  local called = false
  local orig_find = doc.find_visible
  doc.find_visible = function(_, cb)
    called = true
    cb({})
  end
  fake:update()
  doc.find_visible = orig_find
  assert_true(called, "wrapped update must still call the real update loop")
  assert_eq(mod._instances[4242], fake, "instance registered under its buf")
  mod._instances[4242] = nil
end)

-- ---------------------------------------------------------------------------
-- 4. negative cache
-- ---------------------------------------------------------------------------

local convert = Image.convert

test("a failed conversion of a cache-dir source writes a .failed marker", function()
  -- a src under the cache dir that does not exist -> Convert:run takes the
  -- "File not found" path (convert.lua:457-461) without spawning anything.
  local src = cache .. "/deadbeef-content.math.tex"
  local done
  local c = convert.convert({
    src = src,
    on_done = function(cc)
      done = cc
    end,
  })
  c:run()
  assert_true(done ~= nil, "on_done called")
  assert_true(done:error() ~= nil, "conversion reported an error")
  assert_eq(vim.fn.filereadable(c.file .. mod.MARKER), 1, "marker written next to " .. c.file)
end)

test("a second Convert for the same source is short-circuited: no run, no toast, still on_done", function()
  local src = cache .. "/deadbeef-content.math.tex"
  local done, toasts = nil, 0
  local real_error = Snacks.notify.error
  Snacks.notify.error = function()
    toasts = toasts + 1
  end
  Image.config.convert.notify = true -- would toast if Convert:on_done ran
  local c = convert.convert({
    src = src,
    on_done = function(cc)
      done = cc
    end,
  })
  local stepped = false
  c.step = function()
    stepped = true
  end
  c:run()
  Image.config.convert.notify = false
  Snacks.notify.error = real_error
  assert_false(stepped, "step() must not run for a known-failed source")
  assert_true(done ~= nil, "on_done still called so the placement settles")
  assert_true(done:done(), "marked done")
  assert_match(done:error(), "SnacksImageRetryFailed")
  assert_eq(toasts, 0, "no notification for a cached failure")
end)

test("the marker survives a fresh in-memory state (cross-session)", function()
  local src = cache .. "/deadbeef-content.math.tex"
  mod._failed = {} -- simulate a new nvim
  local stepped = false
  local c = convert.convert({ src = src })
  c.step = function()
    stepped = true
  end
  c:run()
  assert_false(stepped, "on-disk marker alone must short-circuit")
end)

test("sources OUTSIDE the cache dir are never negative-cached", function()
  local src = vim.fn.tempname() .. "-not-yet.png"
  local c = convert.convert({ src = src })
  c:run()
  assert_true(c:error() ~= nil, "missing file is an error")
  assert_eq(vim.fn.filereadable(c.file .. mod.MARKER), 0, "no marker for a file-backed src")
  local c2 = convert.convert({ src = src })
  local stepped = false
  c2.step = function()
    stepped = true
  end
  -- still missing -> still the File-not-found path, but via the REAL run
  c2:run()
  assert_false(stepped)
  assert_match(c2:error(), "File not found", "real run path, not the cached-failure message")
end)

test(":SnacksImageRetryFailed clears markers and memory", function()
  local src = cache .. "/deadbeef-content.math.tex"
  local c = convert.convert({ src = src })
  assert_eq(vim.fn.filereadable(c.file .. mod.MARKER), 1, "precondition: marker present")
  assert_eq(vim.fn.exists(":SnacksImageRetryFailed"), 2, "user command registered")
  vim.cmd("SnacksImageRetryFailed")
  assert_eq(vim.fn.filereadable(c.file .. mod.MARKER), 0, "marker deleted")
  assert_nil(next(mod._failed), "in-memory set cleared")
  local stepped = false
  local c2 = convert.convert({ src = src })
  c2.step = function()
    stepped = true
  end
  c2:run()
  -- src still missing, so the real run reports File not found again (and
  -- re-marks it) -- the point is that it went through the real path.
  assert_match(c2:error(), "File not found")
end)

vim.fn.delete(cache, "rf")
_H.finish({ style = "results" })
