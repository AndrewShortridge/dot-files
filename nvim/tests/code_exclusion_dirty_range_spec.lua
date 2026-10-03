-- Perf + correctness spec for build_code_exclusion incremental rescan (T7).
--
-- build_code_exclusion() used to be a changedtick memo, so it rebuilt on EVERY
-- keystroke and ran iter_captures(root, bufnr, 0, -1) over the WHOLE buffer on
-- the markdown + markdown_inline trees — the most expensive per-keystroke TS op
-- in the link pipeline on large files. The fix keeps a per-buffer cache of the
-- full range set and, on an edit, rescans ONLY the dirty span (expanded to any
-- enclosing fenced code block), retaining out-of-range ranges verbatim.
--
-- PERF (fence precheck, discriminating): a markdown parser:parse() transitively
-- reparses the buffer's injected markdown_inline trees, so it costs ~O(file)
-- (~20ms on a 123KB note) EVERY call regardless of dirty-line count — the
-- dominant per-keystroke render cost on large notes. A fenced/indented code
-- BLOCK can only change if an edited line is a fence/indented-code boundary or
-- the edit fell inside a cached block; otherwise the cached block ranges are
-- retained verbatim and the block parse is SKIPPED ENTIRELY. So a fence-free far
-- edit must produce ZERO block iter_captures; a fence-delimiter edit must still
-- run a bounded (never (0,-1)) block rescan. Setting the precheck config false
-- (or touching a fence) reintroduces the parse -> the assertions flip.
--
-- PERF (markdown_inline gate, issue E): on the incremental path, the expensive
-- markdown_inline (code_span) injection reparse + sweep must be SKIPPED when the
-- (fence-expanded) dirty span contains no backtick AND no cached code_span sat
-- on the dirty rows — a code_span can only appear/disappear where a backtick was
-- edited. We count inline (code_span) sweeps by the root node type passed to
-- iter_captures: the markdown tree root is `document`, the markdown_inline tree
-- root is `inline`. A backtick-free far edit must produce ZERO `inline` sweeps.
-- Reintroducing an unconditional inline reparse makes that assertion fail.
-- DISCRIMINATING POWER (verified manually):
--   * Drop the "cached span overlaps dirty rows" clause from scan_inline and the
--     "delete the only backtick" case retains a stale span -> its parity fails.
--   * Force scan_inline = true always (set the precheck config false) and the
--     "no inline sweep on far backtick-free edit" perf assertion fails.
--
-- CORRECTNESS: the closure is consumed as a WHOLE-buffer query (every consumer
-- asks about arbitrary rows), so after any edit it must answer identically to a
-- fresh whole-buffer recompute for EVERY row — including code-fence rows far
-- from the edit, fences straddling the edit, and line-count-changing edits that
-- shift a fence. Breaking the retain-out-of-range logic makes this fail.
--
-- Drives the REAL link_scan module against scratch .md buffers. The only
-- instrumentation is a behavioral wrapper around the real query iter_captures
-- (allowed, like the render_diff spec wrapping real apply_diff) — no source
-- introspection.
--
-- Run with: nvim --headless -u NONE -l tests/code_exclusion_dirty_range_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false = _H.test, _H.assert_eq, _H.assert_true, _H.assert_false

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local link_scan = require("andrew.vault.link_scan")

print("\n=== Code-Exclusion Dirty-Range Tests ===\n")

-- ---------------------------------------------------------------------------
-- Behavioral instrumentation of the REAL treesitter query iter_captures.
-- Wrap the method on the Query metatable so we observe the (start, stop) row
-- arguments every build_code_exclusion() pass uses. Records pairs into `calls`.
-- ---------------------------------------------------------------------------
local _q = vim.treesitter.query.parse("markdown", "(fenced_code_block) @code")
local _mt = getmetatable(_q)
local _orig_iter = _mt.iter_captures
local calls = {}
-- Count code_span sweeps separately: the markdown_inline tree root node type is
-- `inline`, the markdown tree root is `document`. The module's code_span query
-- is the only query iter_captured against an `inline` root, so this isolates the
-- expensive injection sweep the backtick precheck gates.
local inline_sweeps = 0
_mt.iter_captures = function(self, node, source, start, stop, ...)
  calls[#calls + 1] = { start = start, stop = stop }
  if node and node.type and node:type() == "inline" then
    inline_sweeps = inline_sweeps + 1
  end
  return _orig_iter(self, node, source, start, stop, ...)
end

local function reset_calls()
  calls = {}
  inline_sweeps = 0
end

-- Build a scratch markdown buffer and seed the exclusion cache.
local function fresh_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/note.md")
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  -- Ensure treesitter parsers attach for this buffer.
  pcall(vim.treesitter.get_parser, buf, "markdown")
  link_scan.build_code_exclusion(buf) -- seed
  return buf
end

-- Compute a reference closure by clearing the cache and recomputing whole-buffer.
local function reference_closure(buf)
  link_scan.clear_cache(buf)
  local f = link_scan.build_code_exclusion(buf)
  -- Re-seed the live (incremental) cache afterwards is unnecessary; caller
  -- captures the incremental closure BEFORE calling this.
  return f
end

-- Assert two closures agree on every row (and representative cols) of the buffer.
local function assert_closures_agree(buf, got, want)
  local n = vim.api.nvim_buf_line_count(buf)
  for row = 0, n - 1 do
    local line = (vim.api.nvim_buf_get_lines(buf, row, row + 1, false))[1] or ""
    local cols = { 0, 1, math.max(0, #line - 1), #line + 5 }
    for _, col in ipairs(cols) do
      assert_eq(
        got(row, col),
        want(row, col),
        string.format("mismatch at row %d col %d", row, col)
      )
    end
  end
end

-- ---------------------------------------------------------------------------
-- PERF: an in-place edit far from any code block rebuilds with a bounded range.
-- ---------------------------------------------------------------------------
test("far in-place edit: no whole-buffer scan; block parse skipped entirely", function()
  local lines = {}
  -- Fenced code block near the top (lines 5..12, 0-indexed 4..11).
  lines[1] = "# Title"
  lines[2] = "intro prose"
  lines[3] = ""
  lines[4] = "before fence"
  lines[5] = "```lua"
  lines[6] = "local x = 1"
  lines[7] = "local y = 2"
  lines[8] = "print(x + y)"
  lines[9] = "```"
  for i = 10, 600 do
    lines[i] = "prose line " .. i .. " with words"
  end
  local buf = fresh_buf(lines)

  -- Edit ONE line far from the code block, keeping the line count constant.
  reset_calls()
  vim.api.nvim_buf_set_lines(buf, 499, 500, false, { "edited prose line 500 here" })
  local f = link_scan.build_code_exclusion(buf)
  assert_true(type(f) == "function", "build returns a closure")

  -- PERF (fence precheck, issue: O(file) injection reparse): the edited line is
  -- not a fence/indented-code boundary and does not fall inside a cached block,
  -- so the block set provably cannot change. The markdown parser:parse() (which
  -- transitively reparses the buffer's injected markdown_inline trees, ~O(file)
  -- per keystroke) is SKIPPED ENTIRELY — the cached block ranges are retained
  -- verbatim. Reintroducing an unconditional block reparse (set the precheck
  -- config false) makes this assertion fail.
  assert_eq(#calls, 0, "expected NO iter_captures on a fence-free far edit")
end)

-- ---------------------------------------------------------------------------
-- PERF: editing a fence DELIMITER line still triggers a bounded block rescan
-- (never whole-buffer). This proves the precheck does NOT over-skip: when a
-- code-fence boundary is touched, the block path must run.
-- ---------------------------------------------------------------------------
test("fence-delimiter edit: bounded block rescan, never whole-buffer", function()
  local lines = {}
  lines[1] = "# Title"
  lines[2] = "intro prose"
  lines[3] = ""
  lines[4] = "before fence"
  lines[5] = "```lua"
  lines[6] = "local x = 1"
  lines[7] = "```"
  for i = 8, 600 do
    lines[i] = "prose line " .. i .. " with words"
  end
  local buf = fresh_buf(lines)

  -- Edit the OPENING fence delimiter (0-indexed row 4) — changes the block.
  reset_calls()
  vim.api.nvim_buf_set_lines(buf, 4, 5, false, { "```python" })
  local f = link_scan.build_code_exclusion(buf)
  assert_true(type(f) == "function", "build returns a closure")

  -- A fence boundary was touched, so the block path must run.
  assert_true(#calls > 0, "expected block iter_captures on a fence-delimiter edit")
  -- ...but never over the whole buffer.
  for _, c in ipairs(calls) do
    assert_false(c.stop == -1, "fence-edit rebuild used whole-buffer scan (0,-1)")
  end
  local bounded_found = false
  for _, c in ipairs(calls) do
    if c.stop ~= -1 and (c.stop - c.start) < 50 then bounded_found = true end
  end
  assert_true(bounded_found, "expected a tightly bounded iter_captures range")
end)

-- ---------------------------------------------------------------------------
-- CORRECTNESS: far edit -> closure identical to fresh whole-buffer recompute.
-- ---------------------------------------------------------------------------
test("far in-place edit: closure matches whole-buffer recompute for every row", function()
  local lines = {}
  lines[1] = "before"
  lines[2] = "```python"
  lines[3] = "a = 1  # `inline` inside fence"
  lines[4] = "b = 2"
  lines[5] = "```"
  for i = 6, 300 do
    lines[i] = "prose `code span` line " .. i
  end
  local buf = fresh_buf(lines)

  vim.api.nvim_buf_set_lines(buf, 199, 200, false, { "edited line two hundred" })
  local incremental = link_scan.build_code_exclusion(buf)

  local reference = reference_closure(buf)
  assert_closures_agree(buf, incremental, reference)
end)

-- ---------------------------------------------------------------------------
-- CORRECTNESS: edit INSIDE the fence still matches whole-buffer recompute.
-- ---------------------------------------------------------------------------
test("edit inside fence: closure matches whole-buffer recompute", function()
  local lines = {
    "before",
    "```lua",
    "local x = 1",
    "local y = 2",
    "```",
    "after prose",
    "more `span` prose",
  }
  local buf = fresh_buf(lines)

  -- Edit a line inside the fence body (0-indexed row 2).
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "local x = 999 -- changed" })
  local incremental = link_scan.build_code_exclusion(buf)

  local reference = reference_closure(buf)
  assert_closures_agree(buf, incremental, reference)
end)

-- ---------------------------------------------------------------------------
-- CORRECTNESS: line-count change (insert) that shifts a fence below it.
-- ---------------------------------------------------------------------------
test("insert above fence: shifted fence still matches whole-buffer recompute", function()
  local lines = {}
  lines[1] = "intro"
  lines[2] = "```lua"
  lines[3] = "local x = 1"
  lines[4] = "```"
  for i = 5, 120 do
    lines[i] = "prose line " .. i
  end
  local buf = fresh_buf(lines)

  -- Insert two lines at the very top -> the fence shifts down by 2.
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new line A", "new line B" })
  local incremental = link_scan.build_code_exclusion(buf)

  local reference = reference_closure(buf)
  assert_closures_agree(buf, incremental, reference)
end)

-- ---------------------------------------------------------------------------
-- CORRECTNESS: deleting lines (negative delta) that shifts a fence upward.
-- ---------------------------------------------------------------------------
test("delete above fence: shifted fence still matches whole-buffer recompute", function()
  local lines = {}
  lines[1] = "filler 1"
  lines[2] = "filler 2"
  lines[3] = "filler 3"
  lines[4] = "```lua"
  lines[5] = "local x = 1"
  lines[6] = "local y = 2"
  lines[7] = "```"
  for i = 8, 150 do
    lines[i] = "prose line " .. i
  end
  local buf = fresh_buf(lines)

  -- Delete the first two filler lines -> fence shifts up by 2.
  vim.api.nvim_buf_set_lines(buf, 0, 2, false, {})
  local incremental = link_scan.build_code_exclusion(buf)

  local reference = reference_closure(buf)
  assert_closures_agree(buf, incremental, reference)
end)

-- ---------------------------------------------------------------------------
-- CORRECTNESS: edit straddling the fence boundary (turns prose into a fence).
-- ---------------------------------------------------------------------------
test("edit that opens a new fence: closure matches whole-buffer recompute", function()
  local lines = {}
  lines[1] = "prose start"
  for i = 2, 100 do
    lines[i] = "prose line " .. i
  end
  -- Create a fence by editing a contiguous block: open + close.
  lines[50] = "```"
  lines[55] = "```"
  local buf = fresh_buf(lines)

  -- Edit a line inside the new fence body.
  vim.api.nvim_buf_set_lines(buf, 51, 52, false, { "inside the fence now" })
  local incremental = link_scan.build_code_exclusion(buf)

  local reference = reference_closure(buf)
  assert_closures_agree(buf, incremental, reference)
end)

-- ---------------------------------------------------------------------------
-- PERF (issue E): a backtick-free far edit must NOT reparse markdown_inline.
-- Discriminating: forcing an unconditional inline rescan makes inline_sweeps>0.
-- ---------------------------------------------------------------------------
test("far backtick-free edit: markdown_inline (code_span) NOT swept", function()
  local lines = {}
  -- A real code span near the top so the cache holds a span range.
  lines[1] = "intro `a code span` here"
  lines[2] = "second prose line"
  lines[3] = ""
  for i = 4, 400 do
    -- Backtick-FREE prose far from the span.
    lines[i] = "plain prose line " .. i .. " no ticks"
  end
  local buf = fresh_buf(lines)

  reset_calls()
  -- Edit a far, backtick-free line, keeping the line count constant.
  vim.api.nvim_buf_set_lines(buf, 299, 300, false, { "edited plain prose line 300" })
  local incremental = link_scan.build_code_exclusion(buf)

  -- The fast path: no inline (code_span) sweep on this rebuild.
  assert_eq(inline_sweeps, 0, "markdown_inline reparsed on backtick-free far edit")
  -- And no block sweep either: the edited line is not a fence/indented-code
  -- boundary and does not fall inside a cached block, so the markdown
  -- parser:parse() (whose injection reparse is the dominant O(file) cost) is
  -- skipped and the cached block ranges are retained verbatim.
  assert_eq(#calls, 0, "block iter_captures ran on a fence-free backtick-free far edit")

  -- Parity: closure still matches a fresh whole-buffer recompute everywhere,
  -- so retaining the cached span verbatim was correct.
  local reference = reference_closure(buf)
  assert_closures_agree(buf, incremental, reference)
end)

-- ---------------------------------------------------------------------------
-- CORRECTNESS: inserting a NEW backtick span far from the cache is detected.
-- The precheck must see the new backtick and trigger an inline rescan.
-- ---------------------------------------------------------------------------
test("insert backtick span far from cache: new span detected", function()
  local lines = {}
  lines[1] = "intro `seed span` here"
  for i = 2, 300 do
    lines[i] = "plain prose line " .. i .. " no ticks"
  end
  local buf = fresh_buf(lines)

  reset_calls()
  -- Edit a far line to INSERT a brand-new code span.
  vim.api.nvim_buf_set_lines(buf, 199, 200, false, { "now with `a new span` inside" })
  local incremental = link_scan.build_code_exclusion(buf)

  -- A backtick is present in the dirty span -> inline MUST be reparsed.
  assert_true(inline_sweeps > 0, "markdown_inline NOT reparsed despite new backtick")

  local reference = reference_closure(buf)
  assert_closures_agree(buf, incremental, reference)
  -- Sanity: the new span's interior is now reported as in-code.
  -- Line 200 (0-indexed 199): "now with `a new span` inside" — col inside span.
  local span_col = string.find("now with `a new span` inside", "new", 1, true) - 1
  assert_true(incremental(199, span_col), "new code span not excluded")
end)

-- ---------------------------------------------------------------------------
-- CORRECTNESS (the trap): deleting the ONLY backticks on a span line must drop
-- the stale span. The post-edit line has NO backtick, so the precheck alone
-- would wrongly skip the inline rescan; the "cached span overlaps dirty rows"
-- guard forces it. Dropping that guard makes this case fail.
-- ---------------------------------------------------------------------------
test("delete the only backtick on a span line: stale span dropped", function()
  local lines = {}
  for i = 1, 300 do
    lines[i] = "plain prose line " .. i .. " no ticks"
  end
  -- A span sits on a far line (0-indexed 199).
  lines[200] = "prose `span` here"
  local buf = fresh_buf(lines)

  -- Confirm the span is initially excluded.
  local seed = link_scan.build_code_exclusion(buf)
  local span_col = string.find("prose `span` here", "span", 1, true) - 1
  assert_true(seed(199, span_col), "seed span should be excluded")

  -- Remove BOTH backticks -> the post-edit line has no backtick at all.
  vim.api.nvim_buf_set_lines(buf, 199, 200, false, { "prose span here" })
  local incremental = link_scan.build_code_exclusion(buf)

  -- Parity: the former span columns must now be OUTSIDE code.
  local reference = reference_closure(buf)
  assert_closures_agree(buf, incremental, reference)
  assert_false(incremental(199, span_col), "stale code span not dropped after backtick deletion")
end)

-- Restore the real iter_captures.
_mt.iter_captures = _orig_iter

_H.finish({ style = "results", exit = "os" })
