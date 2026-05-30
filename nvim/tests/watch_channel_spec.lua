-- Unit tests for lua/andrew/vault/watch_channel.lua
-- Run with: nvim --headless -u NONE -l tests/watch_channel_spec.lua

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

-- ============================================================================
-- Tests
-- ============================================================================

print("\n=== watch_channel tests ===")

local watch = require("andrew.vault.watch_channel")

-- Helper: process pending vim.schedule callbacks and libuv timers.
-- vim.wait() pumps both the libuv event loop AND the vim.schedule queue.
local function flush(ms)
  ms = ms or 50
  vim.wait(ms, function() return false end)
end

test("new() returns send function and handle table", function()
  local send, handle = watch.new(nil)
  assert_eq(type(send), "function", "send should be function")
  assert_eq(type(handle), "table", "handle should be table")
  assert_eq(type(handle.subscribe), "function", "subscribe should be function")
  assert_eq(type(handle.get), "function", "get should be function")
  assert_eq(type(handle.close), "function", "close should be function")
  handle.close()
end)

test("get() returns initial value", function()
  local send, handle = watch.new("initial")
  assert_eq(handle.get(), "initial", "initial value")
  handle.close()
end)

test("get() returns latest sent value synchronously", function()
  local send, handle = watch.new(nil)
  send("hello")
  assert_eq(handle.get(), "hello", "after send")
  send("world")
  assert_eq(handle.get(), "world", "after second send")
  handle.close()
end)

test("multiple sends within same tick coalesce into one notification", function()
  local send, handle = watch.new(nil)
  local call_count = 0
  local last_value = nil

  handle.subscribe(function(val)
    call_count = call_count + 1
    last_value = val
  end)

  -- Simulate rapid sends (all within one Lua call stack)
  send("a")
  send("b")
  send("c")

  -- Before event loop tick: no notification yet
  assert_eq(call_count, 0, "before tick")

  -- Let the timer fire
  flush()

  assert_eq(call_count, 1, "should fire exactly once")
  assert_eq(last_value, "c", "should have latest value")
  handle.close()
end)

test("sends after notification schedule a new notification", function()
  local send, handle = watch.new(nil)
  local values = {}

  handle.subscribe(function(val) table.insert(values, val) end)

  send("first")
  flush()
  assert_eq(#values, 1, "first batch")
  assert_eq(values[1], "first", "first value")

  send("second")
  flush()
  assert_eq(#values, 2, "second batch")
  assert_eq(values[2], "second", "second value")

  handle.close()
end)

test("unsubscribe prevents callback", function()
  local send, handle = watch.new(nil)
  local called = false

  local unsub = handle.subscribe(function() called = true end)
  unsub()
  send("ignored")
  flush()

  assert_eq(called, false, "should not be called after unsub")
  handle.close()
end)

test("close prevents further notifications", function()
  local send, handle = watch.new(nil)
  local called = false

  handle.subscribe(function() called = true end)
  handle.close()
  send("ignored") -- should silently do nothing
  flush()

  assert_eq(called, false, "should not fire after close")
end)

test("close is idempotent", function()
  local send, handle = watch.new(nil)
  handle.close()
  handle.close() -- should not error
end)

test("multiple subscribers all receive notification", function()
  local send, handle = watch.new(nil)
  local count_a = 0
  local count_b = 0

  handle.subscribe(function() count_a = count_a + 1 end)
  handle.subscribe(function() count_b = count_b + 1 end)

  send(true)
  flush()

  assert_eq(count_a, 1, "subscriber a")
  assert_eq(count_b, 1, "subscriber b")
  handle.close()
end)

test("unsubscribe only removes the specific callback", function()
  local send, handle = watch.new(nil)
  local count_a = 0
  local count_b = 0

  local unsub_a = handle.subscribe(function() count_a = count_a + 1 end)
  handle.subscribe(function() count_b = count_b + 1 end)

  unsub_a()
  send(true)
  flush()

  assert_eq(count_a, 0, "unsubbed callback should not fire")
  assert_eq(count_b, 1, "remaining callback should fire")
  handle.close()
end)

test("nil is a valid value", function()
  local send, handle = watch.new("start")
  local received = "sentinel"

  handle.subscribe(function(val) received = val end)
  send(nil)
  flush()

  assert_eq(received, nil, "should receive nil")
  assert_eq(handle.get(), nil, "get should return nil")
  handle.close()
end)

test("no notification if no sends occur", function()
  local send, handle = watch.new(nil)
  local called = false

  handle.subscribe(function() called = true end)
  flush()

  assert_eq(called, false, "no sends means no notification")
  handle.close()
end)

-- ============================================================================
-- Summary
-- ============================================================================

print(string.format("\n%d passed, %d failed", passed, failed))
if #errors > 0 then
  print("\nFailures:")
  for _, e in ipairs(errors) do
    print("  " .. e.name .. ": " .. e.err)
  end
  os.exit(1)
end
