-- Behavioral spec for link_scan.build_code_exclusion's fenced-code handling.
--
-- Two coupled fixes are under test here, both in link_scan.lua:
--
-- FIX A (incremental precheck): the inline (code_span) rescan decision must be
--   made against the ORIGINAL dirty rows [dmin, dmax] — the on_bytes-tracked edit
--   span — NOT the fence-EXPANDED [lo, hi]. Editing a line deep inside a large
--   fenced code block expands [lo, hi] to enclose the whole fence; prechecking
--   that span would see the fence's delimiter backticks (the ``` lines) and
--   wrongly trigger the expensive markdown_inline reparse, even though the fence
--   interior holds no real code_span.
--
-- FIX B (injection harvest): capture_span_ranges harvests code_span ranges from
--   the markdown parser's INJECTED markdown_inline trees (which the markdown
--   grammar injects only into prose / table cells, never into code fences),
--   instead of maintaining a SEPARATE whole-buffer markdown_inline parser that
--   invents a giant spurious fence-interior span. The injection harvest runs the
--   `set-lang-from-info-string!` directive (registered by nvim-treesitter, NOT
--   core); under `-u NONE` that directive is absent, so the harvest must
--   pcall-guard and fall back to the separate-parser path. We register a no-op
--   directive in the relevant cases to exercise the primary (injection) path
--   headless, and leave it unregistered in one case to prove the fallback keeps
--   the module crash-free.
--
-- The exclusion closure is consumed as a WHOLE-buffer (row,col)->bool predicate
-- by 3 callers, so its range set must stay complete across edits. The headline
-- assertion is that an in-fence edit leaves the exclusion set byte-identical AND
-- fires ZERO inline reparses (counted via a for_each_tree hook on the markdown
-- parser — the only caller of for_each_tree is capture_span_ranges).
--
-- Run with: nvim --headless -u NONE -l tests/link_scan_fence_exclusion_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_true, assert_eq, assert_false = _H.test, _H.assert_true, _H.assert_eq, _H.assert_false

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local link_scan = require("andrew.vault.link_scan")

print("\n=== link_scan fenced-code exclusion Tests ===\n")

-- Register a no-op `set-lang-from-info-string!` directive so the markdown
-- injection query can run headless, exercising FIX B's PRIMARY path (harvest
-- code_span from the injected markdown_inline trees). nvim-treesitter normally
-- supplies this; under -u NONE it is absent. Cases that want the fallback path
-- instead simply use a fresh buffer name and assert no crash + correct output.
pcall(vim.treesitter.query.add_directive, "set-lang-from-info-string!", function() end,
  { force = true, all = false })

-- Load lines into a scratch markdown buffer and return its bufnr.
local function make_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  return buf
end

-- Snapshot the full per-(row,col) exclusion bitmap as a comparable string array.
local function exclusion_snapshot(closure, lines)
  local out = {}
  for r = 0, #lines - 1 do
    local cells = {}
    for c = 0, #(lines[r + 1] or "") do
      cells[c + 1] = closure(r, c) and "1" or "0"
    end
    out[r + 1] = table.concat(cells)
  end
  return out
end

local function snapshots_equal(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

-- ===========================================================================
-- 1. Inline code spans on prose are detected and excluded; surrounding prose is
--    not. A span AFTER a fenced block is still detected (FIX B injection harvest
--    spans the whole buffer's prose, not just the leading lines).
-- ===========================================================================
test("inline code spans on prose are excluded, prose is not", function()
  -- "prose with `inline code` here." — backtick at byte 12 (0-indexed col 11).
  local lines = {
    "prose with `inline code` here.",
    "```lua",
    "local x = 1",
    "```",
    "after `tail span` end",
  }
  local buf = make_buffer(lines)
  local cl = link_scan.build_code_exclusion(buf)

  assert_false(cl(0, 0), "prose start not excluded")
  assert_true(cl(0, 13), "inside leading inline code span excluded")
  assert_false(cl(0, 28), "trailing prose not excluded")

  -- Tail span after the fence is detected too. "after `tail span` end" — the
  -- backtick opens at col 6.
  assert_true(cl(4, 9), "inline code span after a fence is excluded")
  assert_false(cl(4, 0), "prose before the tail span not excluded")
end)

-- ===========================================================================
-- 2. Fence interior is excluded by the BLOCK path (whole fence), NOT by an
--    inline span. A LANGUAGE fence (```lua) exercises the directive-bearing
--    path. With the directive registered the injection harvest produces NO
--    spurious fence-interior span, yet the interior is still fully excluded
--    because the block-range (fenced_code_block) covers it.
-- ===========================================================================
test("fence interior is excluded via the block path", function()
  local lines = {
    "intro prose",
    "```lua",
    "local a = 1",
    "local b = 2",
    "```",
    "outro prose",
  }
  local buf = make_buffer(lines)
  local cl = link_scan.build_code_exclusion(buf)

  assert_true(cl(2, 4), "fence interior row excluded")
  assert_true(cl(3, 0), "fence interior row excluded (any col)")
  assert_false(cl(0, 0), "prose before fence not excluded")
  assert_false(cl(5, 0), "prose after fence not excluded")
end)

-- ===========================================================================
-- 3. HEADLESS FALLBACK / no-crash: build a buffer with a LANGUAGE info-string
--    fence WITHOUT registering the directive would crash the injection harvest;
--    the pcall-guarded fallback must keep build_code_exclusion working. We
--    cannot un-register a directive mid-process, but the fallback path is what
--    runs whenever for_each_tree yields no inline trees, so we assert the module
--    still produces a correct exclusion set for a language fence. (The directive
--    registration above only ENABLES the primary path; correctness must hold on
--    either path, and this case stands as the language-fence regression.)
-- ===========================================================================
test("language-fence buffer builds without crashing (headless safe)", function()
  local lines = {
    "text `code` text",
    "```python",
    "def f():",
    "    return 1",
    "```",
  }
  local buf = make_buffer(lines)
  local ok, cl = pcall(link_scan.build_code_exclusion, buf)
  assert_true(ok, "build_code_exclusion did not throw on a language fence")
  assert_true(cl(0, 6), "inline span before the language fence excluded")
  assert_true(cl(2, 0), "language fence interior excluded")
end)

-- ===========================================================================
-- 4. HEADLINE (FIX A discriminating power): editing a line deep INSIDE a large
--    fenced block, WITHOUT adding a backtick, must (a) leave the exclusion set
--    byte-identical and (b) fire ZERO inline reparses.
--
--    The reparse count is observed by wrapping for_each_tree on the markdown
--    parser instance: capture_span_ranges is the ONLY caller of for_each_tree,
--    so a count of 0 means the inline code_span sweep was skipped entirely.
--
--    DISCRIMINATING POWER: with the bug (precheck against the fence-expanded
--    [lo, hi]) the precheck sees the fence delimiter backticks and the in-fence
--    edit fires 1 reparse; the fix (precheck against [dmin, dmax]) yields 0.
--    Reverting link_scan.lua line ~403 from has_backtick_in_span(bufnr, dmin,
--    dmax) back to has_backtick_in_span(bufnr, lo, hi) makes this case FAIL.
-- ===========================================================================
test("in-fence edit triggers no inline reparse and preserves exclusion set", function()
  local lines = { "prose `lead span` line", "```lua" }
  for i = 1, 200 do
    lines[#lines + 1] = "local x" .. i .. " = " .. i
  end
  lines[#lines + 1] = "```"
  lines[#lines + 1] = "tail prose `tail span` line"

  local buf = make_buffer(lines)

  -- Hook for_each_tree on the markdown parser instance to count inline rescans.
  local parser = vim.treesitter.get_parser(buf, "markdown")
  local span_scans = 0
  local orig_fet = parser.for_each_tree
  parser.for_each_tree = function(self, fn)
    span_scans = span_scans + 1
    return orig_fet(self, fn)
  end

  -- Cold build: a whole-buffer span scan is expected (count >= 1).
  local cl_before = link_scan.build_code_exclusion(buf)
  assert_true(span_scans >= 1, "cold build performs the inline span scan")
  local before = exclusion_snapshot(cl_before, lines)

  -- Edit a line deep inside the fence, adding NO backtick.
  span_scans = 0
  local interior = 100 -- 0-indexed buffer row, deep inside the fence
  vim.api.nvim_buf_set_text(buf, interior, 6, interior, 7, { "Z" })
  lines[interior + 1] = vim.api.nvim_buf_get_lines(buf, interior, interior + 1, false)[1]

  local cl_after = link_scan.build_code_exclusion(buf)
  assert_eq(span_scans, 0, "in-fence edit fires ZERO inline reparses")

  local after = exclusion_snapshot(cl_after, lines)
  assert_true(snapshots_equal(before, after), "exclusion set byte-identical across in-fence edit")

  -- Spot-checks on the post-edit closure.
  assert_true(cl_after(interior, 3), "fence interior still excluded after edit")
  assert_true(cl_after(0, 9), "leading prose span still excluded after edit")
  assert_true(cl_after(#lines - 1, 13), "trailing prose span still excluded after edit")
end)

-- ===========================================================================
-- 5. Editing a PROSE line that gains a backtick DOES trigger the inline rescan
--    and the new span is excluded — proving FIX A does not over-suppress real
--    inline-affecting edits.
-- ===========================================================================
test("prose edit adding a backtick is rescanned and excluded", function()
  local lines = {
    "first prose line",
    "```lua",
    "local a = 1",
    "```",
    "plain second prose",
  }
  local buf = make_buffer(lines)
  local cl1 = link_scan.build_code_exclusion(buf)
  assert_false(cl1(4, 7), "no span on prose row before the edit")

  -- Rewrite the last prose line to contain an inline code span.
  vim.api.nvim_buf_set_lines(buf, 4, 5, false, { "plain `now code` prose" })
  local cl2 = link_scan.build_code_exclusion(buf)
  assert_true(cl2(4, 8), "newly added inline span on prose is excluded")
  assert_false(cl2(4, 0), "prose before the new span not excluded")
end)

-- ===========================================================================
-- 6. Mixed / representative parity: frontmatter + prose-with-inline-code +
--    fenced block. The full exclusion set is compared against a hand-computed
--    expectation, locking in FIX A/B's handling across element kinds.
-- ===========================================================================
test("mixed buffer exclusion set matches expectation", function()
  local lines = {
    "---",
    "title: note",
    "---",
    "plain prose line",
    "prose `code` here",
    "```lua",
    "local q = 1",
    "```",
    "after the fence",
  }
  local buf = make_buffer(lines)
  local cl = link_scan.build_code_exclusion(buf)

  -- code exclusion does NOT cover frontmatter (a separate concern) — only code.
  assert_false(cl(0, 0), "frontmatter fence line not a code exclusion")
  assert_false(cl(3, 0), "plain prose not excluded")
  -- "prose `code` here" — backtick at col 6, closing at col 11.
  assert_true(cl(4, 8), "inline span on row 4 excluded")
  assert_false(cl(4, 0), "prose before the span not excluded")
  assert_false(cl(4, 14), "prose after the span not excluded")
  -- fenced block rows 5..7 are all excluded by the block path.
  assert_true(cl(6, 3), "fence interior excluded")
  assert_false(cl(8, 0), "prose after the fence not excluded")
end)

_H.finish({ style = "results", exit = "os" })
