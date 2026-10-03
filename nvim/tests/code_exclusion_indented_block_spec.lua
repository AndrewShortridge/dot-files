-- Regression spec for link_scan.build_code_exclusion's INDENTED-code-block
-- gate-line dependency on the incremental rescan path.
--
-- THE BUG (fixed in link_scan.lua): a CommonMark indented code block cannot
-- interrupt a paragraph, so the block's existence hinges on the BLANKNESS of the
-- line immediately above it (its "gate line"). That gate line sits one row
-- OUTSIDE the on_bytes-tracked dirty span [dmin, dmax], so an edit that toggles
-- its blankness can CREATE or DESTROY the adjacent indented block without the
-- dirty span ever touching the block's body. The incremental path used to shift
-- the cached block range into post-edit coordinates and retain it verbatim,
-- producing a STALE exclusion closure: it kept excluding a block that should
-- have vanished (gate turned non-blank), or missed a block that should have
-- appeared (paragraph line turned blank).
--
-- THE ORACLE: the incremental closure must answer identically to a FRESH full
-- recompute over the post-edit content. We obtain the fresh recompute on the
-- SAME buffer via link_scan.clear_cache() (which forces the next build to do a
-- cold whole-buffer scan), so the comparison reads the same treesitter tree and
-- isolates the incremental range bookkeeping under test.
--
-- DISCRIMINATING POWER: with the gate-line fix reverted, the DESTROY and CREATE
-- cases below FAIL (the incremental closure keeps / misses the indented block);
-- the far-prose CONTROL passes either way (it must, to prove the fix does not
-- just force a full reparse on every edit and destroy the precheck perf win).
--
-- Run with: nvim --headless -u NONE -l tests/code_exclusion_indented_block_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_true = _H.test, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
-- Enable the markdown injection harvest headless (see fence spec for rationale).
pcall(vim.treesitter.query.add_directive, "set-lang-from-info-string!", function() end,
  { force = true, all = false })
local link_scan = require("andrew.vault.link_scan")

print("\n=== link_scan indented-block gate-line exclusion Tests ===\n")

local function make_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  return buf
end

-- Snapshot the full per-(row,col) exclusion bitmap as a comparable string array.
local function snapshot(closure, lines)
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

-- Prime the incremental cache on `before`, apply `edit_fn` IN PLACE (so on_bytes
-- fires), then assert the incremental closure matches a fresh full recompute on
-- the SAME buffer's post-edit content.
local function assert_incremental_matches_fresh(before, edit_fn)
  local buf = make_buffer(before)
  link_scan.build_code_exclusion(buf) -- prime (cold full build)
  edit_fn(buf)
  local post = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local inc = snapshot(link_scan.build_code_exclusion(buf), post)
  link_scan.clear_cache(buf) -- force next build to be a cold full recompute
  local fresh = snapshot(link_scan.build_code_exclusion(buf), post)
  return snapshots_equal(inc, fresh), inc, fresh, post
end

-- ===========================================================================
-- 1. DESTROY: an indented code block at rows 2-3 exists because row 1 (the gate
--    line) is blank. Editing the gate line to non-blank must DESTROY the block;
--    the incremental closure must stop excluding rows 2-3, matching a fresh
--    recompute (which finds no indented block — it cannot interrupt the
--    paragraph that now occupies row 1).
-- ===========================================================================
test("gate-line edit DESTROYS an indented block (incremental == fresh)", function()
  local before = { "prose", "", "    code one", "    code two", "tail" }
  local ok = assert_incremental_matches_fresh(before, function(buf)
    -- Insert "x" at the start of the blank gate line (row 1) -> non-blank.
    vim.api.nvim_buf_set_text(buf, 1, 0, 1, 0, { "x" })
  end)
  assert_true(ok, "incremental closure must match fresh recompute after gate destroy")
end)

-- ===========================================================================
-- 2. CREATE: a paragraph line above an indented run keeps it from being a code
--    block. Turning that paragraph line blank must CREATE the indented block;
--    the incremental closure must start excluding the indented rows, matching a
--    fresh recompute.
-- ===========================================================================
test("gate-line edit CREATES an indented block (incremental == fresh)", function()
  local before = { "prose", "para", "    code one", "    code two", "tail" }
  local ok = assert_incremental_matches_fresh(before, function(buf)
    -- Replace the paragraph line (row 1) with a blank line.
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "" })
  end)
  assert_true(ok, "incremental closure must match fresh recompute after gate create")
end)

-- ===========================================================================
-- 3. CONTROL: a prose edit FAR from any indented/fenced block must also match a
--    fresh recompute. This guards against an over-broad fix that forces a full
--    reparse on every edit (which would "pass" the oracle but destroy the
--    per-keystroke precheck perf win). The indented block at rows 2-3 is well
--    away from the edited row 5, so the block precheck must skip the block
--    reparse AND the result must still be correct.
-- ===========================================================================
test("far-prose edit leaves the exclusion set correct (control)", function()
  local before = { "prose", "", "    code one", "    code two", "between", "tail prose", "more" }
  local ok = assert_incremental_matches_fresh(before, function(buf)
    -- Edit row 5 (well below the indented block) prose-to-prose.
    vim.api.nvim_buf_set_lines(buf, 5, 6, false, { "edited tail" })
  end)
  assert_true(ok, "far-prose incremental closure must match fresh recompute")
end)

_H.finish()
