-- tests/spec_helper.lua
-- Shared test harness for all vault specs.
-- Usage: local _H = dofile((debug.getinfo(1,"S").source:gsub("^@",""):match("^(.*)[/\\]") or ".") .. "/spec_helper.lua")
--
-- Load with the script-dir pattern so it works under both:
--   nvim --headless -u NONE -l tests/<spec>.lua  (cwd = anywhere)
--   run_all.lua (cwd = config root)

local M = {}

-- ============================================================================
-- Shared mutable state (one instance per dofile() call)
-- ============================================================================
local passed = 0
local failed = 0
local assertions = 0
local errors = {}

-- ============================================================================
-- Core runner
-- ============================================================================

--- Run a named test function and record pass/fail.
function M.test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("  PASS: " .. name)
  else
    failed = failed + 1
    table.insert(errors, { name = name, err = tostring(err) })
    print("  FAIL: " .. name .. " -> " .. tostring(err))
  end
end

-- ============================================================================
-- Core assertions (semantics byte-identical to all specs that use them)
-- ============================================================================

--- Assert two values are equal (==).
function M.assert_eq(got, expected, msg)
  assertions = assertions + 1
  if got ~= expected then
    error((msg or "") .. " expected: " .. vim.inspect(expected) .. ", got: " .. vim.inspect(got))
  end
end

--- Assert a value is truthy.
function M.assert_true(val, msg)
  assertions = assertions + 1
  if not val then
    error((msg or "assertion failed") .. " (got falsy)")
  end
end

--- Assert a value is nil.
function M.assert_nil(val, msg)
  assertions = assertions + 1
  if val ~= nil then
    error((msg or "expected nil") .. ", got: " .. vim.inspect(val))
  end
end

--- Assert a value is falsy.
--- Note: failure-path message varies across specs, but the suite is 100% green
--- so this branch is never executed — any consistent form is safe.
function M.assert_false(val, msg)
  assertions = assertions + 1
  if val then
    error((msg or "expected false") .. " (got truthy: " .. vim.inspect(val) .. ")")
  end
end

--- Assert a string matches a Lua pattern.
--- Note: failure-path message varies across specs (never fires on green suite).
function M.assert_match(s, pat, msg)
  assertions = assertions + 1
  if type(s) ~= "string" or not s:match(pat) then
    error((msg or "pattern mismatch") .. " expected to match: " .. pat .. ", got: " .. vim.inspect(s))
  end
end

-- ============================================================================
-- Canonical deep-equality (matches js2lua, task_logic, search_query canonical form)
-- NOTE: behavioral_upgrades, templates, ui_helpers keep their OWN deep_equal
-- (ui_helpers uses vim.deep_equal). Do NOT force those specs onto this version.
-- ============================================================================

--- Recursive deep structural equality for plain tables / scalars.
function M.deep_equal(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if not M.deep_equal(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

--- Assert deep structural equality using the canonical deep_equal above.
--- Used by: js2lua_spec, task_logic_spec.
--- NOT used for specs whose deep_equal diverges (behavioral_upgrades, templates, ui_helpers).
function M.assert_deep_eq(got, expected, msg)
  assertions = assertions + 1
  if not M.deep_equal(got, expected) then
    error((msg or "") .. " expected: " .. vim.inspect(expected) .. ", got: " .. vim.inspect(got))
  end
end

-- ============================================================================
-- Counter accessors (for specs that need to read them, e.g. search_query)
-- ============================================================================

function M.get_passed() return passed end
function M.get_failed() return failed end
function M.get_assertions() return assertions end
function M.get_errors() return errors end

-- ============================================================================
-- finish(opts) — print summary and exit
--
-- opts.style:
--   "plain"              -> "\n<N> passed, <M> failed"
--   "results"            -> "\n=== Results ===\n  <N> passed, <M> failed"    (default)
--   "dashes"             -> "\n--- Results: <N> passed, <M> failed ---"
--   "results_assertions" -> "\n=== Results ===\n  <N> passed, <M> failed (<A> assertions)"
--   "total"              -> "\n====...====\nResults: <N> passed, <M> failed, <T> total\n====...===="
--
-- opts.exit:
--   "os"       -> os.exit(failed > 0 and 1 or 0)           (most specs)
--   "os_guard" -> if #errors > 0 then os.exit(1) end        (batch_drain, watch_channel)
--   "cquit"    -> vim.cmd("cquit " .. ...)                  (test_vault_fixes)
-- ============================================================================

function M.finish(opts)
  opts = opts or {}
  local style = opts.style or "results"
  local exit_mode = opts.exit or "os"

  -- Print failures block (if any)
  local function print_failures(header)
    if #errors > 0 then
      print("\n" .. (header or "Failures:"))
      for _, e in ipairs(errors) do
        print("  " .. e.name .. ": " .. e.err)
      end
    end
  end

  -- Print the summary line in the requested style.
  -- IMPORTANT: the summary line containing "%d passed, %d failed" must be the
  -- LAST such line printed, so run_all.lua's last-match gmatch wins.
  if style == "plain" then
    -- batch_drain_spec, watch_channel_spec
    -- Print failures first, then the summary last.
    if #errors > 0 then
      print("\nFailures:")
      for _, e in ipairs(errors) do
        print("  " .. e.name .. ": " .. e.err)
      end
    end
    print(string.format("\n%d passed, %d failed", passed, failed))

  elseif style == "results" then
    -- Most specs: behavioral_upgrades, calendar_dates, embed_helpers,
    -- graph_traversal, js2lua, link_maintenance, link_utils, lru_cache,
    -- structural_sharing, summary_tree, task_logic, templates, ui_helpers,
    -- vault_index_snapshot
    print("\n=== Results ===")
    print(string.format("  %d passed, %d failed", passed, failed))
    print_failures("Failures:")

  elseif style == "dashes" then
    -- request_coalescer_spec
    print(string.format("\n--- Results: %d passed, %d failed ---", passed, failed))
    print_failures("Failures:")

  elseif style == "results_assertions" then
    -- search_query_spec
    print("\n=== Results ===")
    print(string.format("  %d passed, %d failed (%d assertions)", passed, failed, assertions))
    print_failures("Failures:")

  elseif style == "total" then
    -- test_vault_fixes
    print("\n" .. string.rep("=", 60))
    print(string.format("Results: %d passed, %d failed, %d total", passed, failed, passed + failed))
    print(string.rep("=", 60))
    if #errors > 0 then
      print("\nFailed tests:")
      for _, e in ipairs(errors) do
        print("  - " .. e.name .. ": " .. e.err)
      end
    end
  end

  -- Exit
  if exit_mode == "cquit" then
    vim.cmd("cquit " .. (failed > 0 and "1" or "0"))
  elseif exit_mode == "os_guard" then
    -- batch_drain / watch_channel: only exit non-zero when errors; no explicit exit 0
    if #errors > 0 then
      os.exit(1)
    end
  else
    -- "os" — standard
    os.exit(failed > 0 and 1 or 0)
  end
end

return M
