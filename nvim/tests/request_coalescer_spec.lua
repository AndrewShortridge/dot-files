-- Unit tests for lua/andrew/vault/request_coalescer.lua
-- Run with: nvim --headless -u NONE -l tests/request_coalescer_spec.lua

local passed = 0
local failed = 0
local errors = {}

local function test(name, fn)
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

local function assert_eq(got, expected, msg)
  if got ~= expected then
    error((msg or "") .. " expected: " .. vim.inspect(expected) .. ", got: " .. vim.inspect(got))
  end
end

local function assert_true(val, msg)
  if not val then
    error((msg or "assertion failed") .. " (got falsy)")
  end
end

local function assert_nil(val, msg)
  if val ~= nil then
    error((msg or "expected nil") .. ", got: " .. vim.inspect(val))
  end
end

-- ============================================================================
-- Stub dependencies
-- ============================================================================

-- vault_log stub
local log_stub = { debug = function() end, info = function() end, warn = function() end, error = function() end }
package.loaded["andrew.vault.vault_log"] = { scope = function() return log_stub end }

-- resource_cleanup stub
package.loaded["andrew.vault.resource_cleanup"] = {
  close_timer = function(timer)
    if timer and timer.stop then pcall(timer.stop, timer) end
    if timer and timer.close then pcall(timer.close, timer) end
  end,
}

-- ============================================================================
-- Load module under test
-- ============================================================================
package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local coalescer = require("andrew.vault.request_coalescer")

-- ============================================================================
-- Tests
-- ============================================================================

print("\n=== Request Coalescer Tests ===\n")

-- ---------------------------------------------------------------------------
-- 1. Pool creation
-- ---------------------------------------------------------------------------

test("new creates pool with default config", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "test1" })
  assert_eq(pool.name, "test1")
  local s = pool:stats()
  assert_eq(s.total_operations, 0)
  assert_eq(s.total_coalesced, 0)
  assert_eq(s.total_cancelled, 0)
  assert_eq(s.in_flight, 0)
end)

test("new creates pool with custom config", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "test2", max_waiters = 5, timeout_ms = 1000, done_linger_ms = 0 })
  assert_eq(pool.name, "test2")
  -- Verify config applied by testing max_waiters behavior later
end)

test("pools() returns all registered pools", function()
  coalescer._reset()
  coalescer.new({ name = "a" })
  coalescer.new({ name = "b" })
  local pools = coalescer.pools()
  assert_true(pools["a"] ~= nil, "pool a should exist")
  assert_true(pools["b"] ~= nil, "pool b should exist")
end)

-- ---------------------------------------------------------------------------
-- 2. Single request with synchronous resolve (operation throws)
-- ---------------------------------------------------------------------------

test("operation_fn throw resolves with error", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "throw_test", done_linger_ms = 0 })
  local got_result, got_err
  pool:request("k1", function()
    error("boom")
  end, function(result, err)
    got_result = result
    got_err = err
  end)
  -- pcall catches the error and calls _resolve_entry synchronously
  assert_nil(got_result, "result should be nil on throw")
  assert_true(got_err ~= nil, "err should be set on throw")
  assert_true(got_err:find("boom") ~= nil, "err should contain 'boom'")
  local s = pool:stats()
  assert_eq(s.total_operations, 1)
end)

-- ---------------------------------------------------------------------------
-- 3. resolve_now (synchronous resolution)
-- ---------------------------------------------------------------------------

test("resolve_now resolves entry and notifies waiters", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "resolve_now_test", done_linger_ms = 0 })
  local got_result, got_err
  local captured_resolve
  pool:request("k1", function(resolve)
    captured_resolve = resolve
    -- Don't call resolve yet — we'll use resolve_now instead
  end, function(result, err)
    got_result = result
    got_err = err
  end)

  assert_true(pool:is_pending("k1"), "should be pending before resolve_now")
  pool:resolve_now("k1", "hello", nil)
  assert_eq(got_result, "hello")
  assert_nil(got_err)
  assert_true(not pool:is_pending("k1"), "should not be pending after resolve_now")
end)

test("resolve_now is idempotent", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "idempotent_test", done_linger_ms = 0 })
  local call_count = 0
  pool:request("k1", function() end, function()
    call_count = call_count + 1
  end)
  pool:resolve_now("k1", true, nil)
  pool:resolve_now("k1", true, nil) -- second call should be no-op
  assert_eq(call_count, 1, "callback should be called exactly once")
end)

-- ---------------------------------------------------------------------------
-- 4. Request coalescing (deduplication)
-- ---------------------------------------------------------------------------

test("second request for same key coalesces", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "coalesce_test", done_linger_ms = 0 })
  local results = {}
  local op_count = 0

  pool:request("shared", function(resolve)
    op_count = op_count + 1
    -- Don't resolve yet
  end, function(result, err)
    results[#results + 1] = { result = result, err = err }
  end)

  pool:request("shared", function()
    -- This operation_fn should NOT be called (coalescing)
    op_count = op_count + 1
  end, function(result, err)
    results[#results + 1] = { result = result, err = err }
  end)

  assert_eq(op_count, 1, "operation should only run once")
  assert_eq(#results, 0, "no results yet")

  local s = pool:stats()
  assert_eq(s.total_coalesced, 1, "one request should be coalesced")
  assert_eq(s.in_flight, 1, "one in-flight operation")

  -- Resolve and verify both waiters get the result
  pool:resolve_now("shared", 42, nil)
  assert_eq(#results, 2, "both waiters should receive result")
  assert_eq(results[1].result, 42)
  assert_eq(results[2].result, 42)
end)

-- ---------------------------------------------------------------------------
-- 5. Cancel
-- ---------------------------------------------------------------------------

test("cancel notifies waiters with cancelled error", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "cancel_test", done_linger_ms = 0 })
  local got_err
  pool:request("k1", function() end, function(_, err)
    got_err = err
  end)

  assert_true(pool:is_pending("k1"))
  local ok = pool:cancel("k1")
  assert_true(ok, "cancel should return true for in-flight key")
  assert_eq(got_err, "cancelled")
  assert_true(not pool:is_pending("k1"))
end)

test("cancel returns false for unknown key", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "cancel_miss" })
  assert_true(not pool:cancel("nonexistent"))
end)

test("cancel increments total_cancelled", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "cancel_stats", done_linger_ms = 0 })
  pool:request("k1", function() end, function() end)
  pool:cancel("k1")
  local s = pool:stats()
  assert_eq(s.total_cancelled, 1)
end)

-- ---------------------------------------------------------------------------
-- 6. Max waiters
-- ---------------------------------------------------------------------------

test("exceeding max_waiters returns error via callback", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "maxw", max_waiters = 2, done_linger_ms = 0 })

  pool:request("k1", function() end, function() end) -- waiter 1
  pool:request("k1", function() end, function() end) -- waiter 2

  local got_err
  pool:request("k1", function() end, function(_, err) -- waiter 3 (overflow)
    got_err = err
  end)
  assert_eq(got_err, "max waiters exceeded")
end)

-- ---------------------------------------------------------------------------
-- 7. Pool isolation
-- ---------------------------------------------------------------------------

test("pools have independent state", function()
  coalescer._reset()
  local pool_a = coalescer.new({ name = "iso_a", done_linger_ms = 0 })
  local pool_b = coalescer.new({ name = "iso_b", done_linger_ms = 0 })

  pool_a:request("shared_key", function() end, function() end)
  assert_true(pool_a:is_pending("shared_key"), "pool_a should have pending key")
  assert_true(not pool_b:is_pending("shared_key"), "pool_b should NOT have pending key")

  pool_b:request("shared_key", function() end, function() end)
  pool_a:cancel("shared_key")
  assert_true(not pool_a:is_pending("shared_key"))
  assert_true(pool_b:is_pending("shared_key"), "pool_b should still be pending")
end)

-- ---------------------------------------------------------------------------
-- 8. pending_count and pending_keys
-- ---------------------------------------------------------------------------

test("pending_count tracks in-flight operations", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "pc_test", done_linger_ms = 0 })
  assert_eq(pool:pending_count(), 0)

  pool:request("a", function() end, function() end)
  pool:request("b", function() end, function() end)
  assert_eq(pool:pending_count(), 2)

  pool:resolve_now("a", true, nil)
  assert_eq(pool:pending_count(), 1)
end)

test("pending_keys returns key info", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "pk_test", done_linger_ms = 0 })
  pool:request("my_op", function() end, function() end)

  local keys = pool:pending_keys()
  assert_eq(#keys, 1, "should have one pending key")
  assert_true(keys[1]:find("my_op") ~= nil, "key info should contain the key name")
end)

-- ---------------------------------------------------------------------------
-- 9. Stats
-- ---------------------------------------------------------------------------

test("stats tracks coalesce_rate correctly", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "rate_test", done_linger_ms = 0 })

  -- 1 operation, 2 coalesced = 3 total requests, rate = 2/3 * 100
  pool:request("k", function() end, function() end) -- op 1
  pool:request("k", function() end, function() end) -- coalesced
  pool:request("k", function() end, function() end) -- coalesced
  pool:resolve_now("k", true, nil) -- completes 1 operation

  local s = pool:stats()
  assert_eq(s.total_operations, 1)
  assert_eq(s.total_coalesced, 2)
  -- coalesce_rate = 2 / (1 + 2) * 100 = 66.666...
  assert_true(s.coalesce_rate > 66 and s.coalesce_rate < 67, "coalesce_rate ~66.67%")
end)

-- ---------------------------------------------------------------------------
-- 10. Configure
-- ---------------------------------------------------------------------------

test("configure applies pool-level settings", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "cfg_test", max_waiters = 10 })
  pool:configure({ max_waiters = 3 })

  -- Verify by testing max_waiters enforcement
  pool:request("k", function() end, function() end) -- 1
  pool:request("k", function() end, function() end) -- 2
  pool:request("k", function() end, function() end) -- 3
  local got_err
  pool:request("k", function() end, function(_, err) got_err = err end) -- overflow
  assert_eq(got_err, "max waiters exceeded")
end)

test("M.configure stores config for late-registered pools", function()
  coalescer._reset()
  coalescer.configure({ pools = { late_pool = { max_waiters = 2 } } })

  -- Pool created after configure() should receive the stored config
  local pool = coalescer.new({ name = "late_pool" })
  pool:request("k", function() end, function() end) -- 1
  pool:request("k", function() end, function() end) -- 2
  local got_err
  pool:request("k", function() end, function(_, err) got_err = err end) -- overflow
  assert_eq(got_err, "max waiters exceeded")
end)

-- ---------------------------------------------------------------------------
-- 11. Reset
-- ---------------------------------------------------------------------------

test("_reset clears all state", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "reset_test", done_linger_ms = 0 })
  pool:request("k", function() end, function() end)
  pool:resolve_now("k", true, nil)
  assert_eq(pool:stats().total_operations, 1)

  pool:_reset()
  assert_eq(pool:stats().total_operations, 0)
  assert_eq(pool:pending_count(), 0)
end)

-- ---------------------------------------------------------------------------
-- 12. Multiple waiters all receive error on reject
-- ---------------------------------------------------------------------------

test("all coalesced waiters receive error on reject", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "reject_test", done_linger_ms = 0 })
  local errs = {}
  pool:request("k", function() end, function(_, err) errs[#errs + 1] = err end)
  pool:request("k", function() end, function(_, err) errs[#errs + 1] = err end)

  pool:resolve_now("k", nil, "something failed")
  assert_eq(#errs, 2)
  assert_eq(errs[1], "something failed")
  assert_eq(errs[2], "something failed")
end)

-- ---------------------------------------------------------------------------
-- 13. Different keys are independent
-- ---------------------------------------------------------------------------

test("different keys are independent operations", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "indep_test", done_linger_ms = 0 })
  local results = {}
  pool:request("a", function() end, function(r) results.a = r end)
  pool:request("b", function() end, function(r) results.b = r end)

  pool:resolve_now("a", "alpha", nil)
  assert_eq(results.a, "alpha")
  assert_nil(results.b, "b should not be resolved yet")

  pool:resolve_now("b", "beta", nil)
  assert_eq(results.b, "beta")
end)

-- ---------------------------------------------------------------------------
-- 14. Per-subscriber cancellation handles
-- ---------------------------------------------------------------------------

test("request returns a handle with cancel()", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "handle_test", done_linger_ms = 0 })
  local handle = pool:request("k", function() end, function() end)
  assert_true(handle ~= nil, "request should return a handle")
  assert_true(type(handle.cancel) == "function", "handle should have cancel()")
end)

test("handle:cancel() prevents callback invocation", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "handle_cancel_test", done_linger_ms = 0 })
  local results = {}
  local h1 = pool:request("k", function() end, function(r) results[1] = r end)
  local _h2 = pool:request("k", function() end, function(r) results[2] = r end)

  -- Cancel first subscriber
  local ok = h1:cancel()
  assert_true(ok, "first cancel should return true")

  -- Resolve — only second subscriber should receive result
  pool:resolve_now("k", "value", nil)
  assert_nil(results[1], "cancelled subscriber should not receive result")
  assert_eq(results[2], "value", "active subscriber should receive result")
end)

test("handle:cancel() is idempotent", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "handle_idem_test", done_linger_ms = 0 })
  local h = pool:request("k", function() end, function() end)
  -- Also add a second subscriber so auto-cancel doesn't fire
  pool:request("k", function() end, function() end)

  assert_true(h:cancel(), "first cancel returns true")
  assert_true(not h:cancel(), "second cancel returns false")
end)

test("auto-cancel when last subscriber cancels", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "autocancel_test", done_linger_ms = 0 })
  local errs = {}
  local h1 = pool:request("k", function() end, function(_, err) errs[1] = err end)
  local h2 = pool:request("k", function() end, function(_, err) errs[2] = err end)

  -- Cancel both subscribers — should auto-cancel the operation
  h1:cancel()
  assert_true(pool:is_pending("k"), "should still be pending with one subscriber")
  h2:cancel()
  -- Auto-cancel triggers pool:cancel(key) which resolves all with "cancelled"
  -- But both were already cancelled, so neither callback fires
  assert_true(not pool:is_pending("k"), "should no longer be pending")
end)

test("late arrival handle is noop", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "noop_test", done_linger_ms = 500 })
  -- Start and resolve an operation (enters linger phase)
  pool:request("k", function() end, function() end)
  pool:resolve_now("k", "done", nil)

  -- Late arrival gets noop handle
  local handle = pool:request("k", function() end, function() end)
  assert_true(not handle:cancel(), "noop handle cancel returns false")
end)

test("first subscriber can cancel without affecting operation", function()
  coalescer._reset()
  local pool = coalescer.new({ name = "first_cancel_test", done_linger_ms = 0 })
  local results = {}
  local h1 = pool:request("k", function() end, function(r) results[1] = r end)
  pool:request("k", function() end, function(r) results[2] = r end)
  pool:request("k", function() end, function(r) results[3] = r end)

  -- Cancel the initiator — operation should continue for others
  h1:cancel()
  assert_true(pool:is_pending("k"), "should still be pending")

  pool:resolve_now("k", "result", nil)
  assert_nil(results[1], "cancelled subscriber should not get result")
  assert_eq(results[2], "result")
  assert_eq(results[3], "result")
end)

-- ============================================================================
-- Summary
-- ============================================================================
print(string.format("\n--- Results: %d passed, %d failed ---", passed, failed))
if #errors > 0 then
  print("\nFailures:")
  for _, e in ipairs(errors) do
    print("  " .. e.name .. ": " .. e.err)
  end
end
os.exit(failed > 0 and 1 or 0)
