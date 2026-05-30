-- Unit tests for lua/andrew/vault/batch_drain.lua
-- Run with: nvim --headless -u NONE -l tests/batch_drain_spec.lua

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

-- ============================================================================
-- Load module under test
-- ============================================================================
package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local batch_drain = require("andrew.vault.batch_drain")

print("\n=== batch_drain tests ===\n")

-- ============================================================================
-- 1. Threshold correctness: drain fires at exactly max_count
-- ============================================================================
test("drain fires at max_count", function()
  local drained = {}
  local b = batch_drain.new({
    max_count = 5,
    on_drain = function(items, stats)
      table.insert(drained, { items = items, stats = stats })
    end,
  })

  for i = 1, 5 do
    b:push(i)
  end
  assert_eq(#drained, 1, "should drain once at count=5")
  assert_eq(drained[1].stats.count, 5)
  assert_eq(drained[1].stats.drain_reason, "threshold")
  assert_true(b:is_empty())
end)

-- ============================================================================
-- 2. Threshold correctness: drain fires at max_bytes
-- ============================================================================
test("drain fires at max_bytes", function()
  local drained = {}
  local b = batch_drain.new({
    max_count = 1000, -- won't trigger by count
    max_bytes = 100,
    on_drain = function(items, stats)
      table.insert(drained, { items = items, stats = stats })
    end,
  })

  b:push("a", 40)
  b:push("b", 40)
  assert_eq(#drained, 0, "should not drain yet (80 bytes)")
  b:push("c", 30) -- total = 110 >= 100
  assert_eq(#drained, 1, "should drain at 110 bytes")
  assert_eq(drained[1].stats.count, 3)
  assert_eq(drained[1].stats.total_bytes, 110)
  assert_eq(drained[1].stats.drain_reason, "threshold")
end)

-- ============================================================================
-- 3. Either-or: byte threshold triggers before count
-- ============================================================================
test("byte threshold triggers before count threshold", function()
  local drain_count = 0
  local b = batch_drain.new({
    max_count = 100,
    max_bytes = 50,
    on_drain = function()
      drain_count = drain_count + 1
    end,
  })

  b:push("big", 60) -- 60 >= 50, drain immediately
  assert_eq(drain_count, 1)
  assert_eq(b:count(), 0)
end)

-- ============================================================================
-- 4. Flush completeness
-- ============================================================================
test("flush drains remaining items", function()
  local drained_items = nil
  local b = batch_drain.new({
    max_count = 100,
    on_drain = function(items, stats)
      drained_items = items
      assert_eq(stats.drain_reason, "flush")
    end,
  })

  b:push("x")
  b:push("y")
  assert_eq(b:count(), 2)
  b:flush()
  assert_true(b:is_empty())
  assert_eq(#drained_items, 2)
  assert_eq(drained_items[1], "x")
  assert_eq(drained_items[2], "y")
end)

-- ============================================================================
-- 5. Zero-item flush does not call on_drain
-- ============================================================================
test("flush on empty accumulator is a no-op", function()
  local called = false
  local b = batch_drain.new({
    max_count = 10,
    on_drain = function()
      called = true
    end,
  })

  b:flush()
  assert_true(not called, "should not call on_drain for empty flush")
end)

-- ============================================================================
-- 6. Re-entrancy: push inside on_drain goes into next batch
-- ============================================================================
test("re-entrancy: push inside on_drain goes to next batch", function()
  local drain_calls = 0
  local b
  b = batch_drain.new({
    max_count = 3,
    on_drain = function(items)
      drain_calls = drain_calls + 1
      if drain_calls == 1 then
        -- Push during drain — should go to new batch
        b:push("reentrant")
      end
    end,
  })

  b:push(1)
  b:push(2)
  b:push(3) -- triggers drain #1
  assert_eq(drain_calls, 1)
  assert_eq(b:count(), 1) -- "reentrant" is pending
  assert_eq(b:is_empty(), false)
  b:flush() -- drain #2
  assert_eq(drain_calls, 2)
  assert_true(b:is_empty())
end)

-- ============================================================================
-- 7. Stats accuracy
-- ============================================================================
test("cumulative stats are accurate", function()
  local b = batch_drain.new({
    max_count = 3,
    on_drain = function() end,
  })

  for i = 1, 10 do
    b:push(i, 10)
  end
  b:flush() -- drain the remaining 1 item

  local s = b:stats()
  assert_eq(s.pushes, 10)
  assert_eq(s.drains, 4) -- 3 threshold drains + 1 flush
  assert_eq(s.total_items, 10)
  assert_eq(s.total_bytes, 100) -- 10 * 10
end)

-- ============================================================================
-- 8. Count-only drain (no byte_size provided)
-- ============================================================================
test("count-only drain when no byte_size given", function()
  local drained = false
  local b = batch_drain.new({
    max_count = 2,
    max_bytes = 10, -- won't trigger without byte_size
    on_drain = function()
      drained = true
    end,
  })

  b:push("a") -- no byte_size
  b:push("b") -- no byte_size, but count=2 >= max_count
  assert_true(drained)
  assert_eq(b:bytes(), 0) -- no bytes tracked
end)

-- ============================================================================
-- 9. Clear discards without draining
-- ============================================================================
test("clear discards pending items without calling on_drain", function()
  local called = false
  local b = batch_drain.new({
    max_count = 100,
    on_drain = function()
      called = true
    end,
  })

  b:push("a", 50)
  b:push("b", 50)
  assert_eq(b:count(), 2)
  assert_eq(b:bytes(), 100)
  b:clear()
  assert_true(b:is_empty())
  assert_eq(b:bytes(), 0)
  assert_true(not called)
end)

-- ============================================================================
-- 10. Multiple drain cycles work correctly
-- ============================================================================
test("multiple drain cycles accumulate stats correctly", function()
  local batch_sizes = {}
  local b = batch_drain.new({
    max_count = 5,
    on_drain = function(items)
      table.insert(batch_sizes, #items)
    end,
  })

  for i = 1, 17 do
    b:push(i)
  end
  b:flush()

  assert_eq(#batch_sizes, 4) -- 5 + 5 + 5 + 2
  assert_eq(batch_sizes[1], 5)
  assert_eq(batch_sizes[2], 5)
  assert_eq(batch_sizes[3], 5)
  assert_eq(batch_sizes[4], 2)
end)

-- ============================================================================
-- 11. on_drain required assertion
-- ============================================================================
test("new() requires on_drain callback", function()
  local ok, err = pcall(function()
    batch_drain.new({ max_count = 10 })
  end)
  assert_true(not ok)
  assert_true(tostring(err):find("on_drain"), "error should mention on_drain")
end)

-- ============================================================================
-- 12. Coroutine integration
-- ============================================================================
test("works inside coroutine with yield in drain callback", function()
  local yields = 0
  local total_items = 0

  local co = coroutine.create(function()
    local b = batch_drain.new({
      max_count = 3,
      on_drain = function(items)
        total_items = total_items + #items
        if coroutine.isyieldable() then
          coroutine.yield()
          yields = yields + 1
        end
      end,
    })

    for i = 1, 9 do
      b:push(i)
    end
    b:flush()
  end)

  -- Resume until coroutine finishes
  while coroutine.status(co) ~= "dead" do
    coroutine.resume(co)
  end

  assert_eq(total_items, 9)
  assert_eq(yields, 3) -- 3 threshold drains yielded
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
