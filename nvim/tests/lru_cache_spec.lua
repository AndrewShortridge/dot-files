-- Unit tests for lua/andrew/vault/lru_cache.lua
-- Run with: nvim --headless -u NONE -l tests/lru_cache_spec.lua

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
-- Load module under test
-- ============================================================================
package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local lru = require("andrew.vault.lru_cache")

-- ============================================================================
-- Tests
-- ============================================================================

print("\n=== LRU Cache Tests ===\n")

-- ---------------------------------------------------------------------------
-- 1. Basic get/put
-- ---------------------------------------------------------------------------
test("get returns nil on cache miss", function()
  local c = lru.new(5)
  assert_nil(c:get("nonexistent"))
end)

test("put then get returns stored value", function()
  local c = lru.new(5)
  c:put("a", 1)
  assert_eq(c:get("a"), 1)
end)

test("put stores different value types", function()
  local c = lru.new(5)
  c:put("str", "hello")
  c:put("num", 42)
  c:put("bool", true)
  c:put("tbl", { x = 1 })
  assert_eq(c:get("str"), "hello")
  assert_eq(c:get("num"), 42)
  assert_eq(c:get("bool"), true)
  assert_eq(c:get("tbl").x, 1)
end)

-- ---------------------------------------------------------------------------
-- 2. Eviction order (LRU eviction when at capacity)
-- ---------------------------------------------------------------------------
test("evicts least recently used when at capacity", function()
  local c = lru.new(3)
  c:put("a", 1)
  c:put("b", 2)
  c:put("c", 3)
  -- cache is full: [a, b, c]
  c:put("d", 4)
  -- "a" should be evicted as the oldest
  assert_nil(c:get("a"), "a should have been evicted")
  assert_eq(c:get("b"), 2)
  assert_eq(c:get("c"), 3)
  assert_eq(c:get("d"), 4)
end)

test("evicts multiple entries as new ones are inserted", function()
  local c = lru.new(2)
  c:put("a", 1)
  c:put("b", 2)
  c:put("c", 3) -- evicts a
  c:put("d", 4) -- evicts b
  assert_nil(c:get("a"))
  assert_nil(c:get("b"))
  assert_eq(c:get("c"), 3)
  assert_eq(c:get("d"), 4)
end)

-- ---------------------------------------------------------------------------
-- 3. Promotion on get (accessing an entry protects it from eviction)
-- ---------------------------------------------------------------------------
test("get promotes entry to most-recently-used", function()
  local c = lru.new(3)
  c:put("a", 1)
  c:put("b", 2)
  c:put("c", 3)
  -- Access "a" to promote it; now LRU order is [b, c, a]
  c:get("a")
  -- Insert "d" -> should evict "b" (now the LRU), not "a"
  c:put("d", 4)
  assert_nil(c:get("b"), "b should have been evicted, not a")
  assert_eq(c:get("a"), 1, "a should survive because it was promoted")
  assert_eq(c:get("d"), 4)
end)

test("multiple gets keep re-promoting", function()
  local c = lru.new(3)
  c:put("a", 1)
  c:put("b", 2)
  c:put("c", 3)
  -- Promote "a" twice
  c:get("a")
  c:get("a")
  -- Insert two new entries
  c:put("d", 4) -- evicts b
  c:put("e", 5) -- evicts c
  assert_eq(c:get("a"), 1, "a should still be alive after double promotion")
  assert_nil(c:get("b"))
  assert_nil(c:get("c"))
end)

-- ---------------------------------------------------------------------------
-- 4. Put update without growing
-- ---------------------------------------------------------------------------
test("updating existing key does not increase size", function()
  local c = lru.new(3)
  c:put("a", 1)
  c:put("b", 2)
  c:put("c", 3)
  assert_eq(c:size(), 3)
  -- Update "a" with a new value
  c:put("a", 100)
  assert_eq(c:size(), 3, "size should not grow on update")
  assert_eq(c:get("a"), 100, "value should be updated")
end)

test("updating existing key promotes it", function()
  local c = lru.new(3)
  c:put("a", 1)
  c:put("b", 2)
  c:put("c", 3)
  -- Update "a" -> promotes it; LRU order becomes [b, c, a]
  c:put("a", 100)
  c:put("d", 4) -- evicts b
  assert_nil(c:get("b"), "b should be evicted")
  assert_eq(c:get("a"), 100, "a should survive after update-promotion")
end)

-- ---------------------------------------------------------------------------
-- 5. Clear empties everything
-- ---------------------------------------------------------------------------
test("clear removes all entries", function()
  local c = lru.new(5)
  c:put("a", 1)
  c:put("b", 2)
  c:put("c", 3)
  c:clear()
  assert_eq(c:size(), 0, "size should be 0 after clear")
  assert_nil(c:get("a"))
  assert_nil(c:get("b"))
  assert_nil(c:get("c"))
end)

test("cache is usable after clear", function()
  local c = lru.new(3)
  c:put("a", 1)
  c:clear()
  c:put("b", 2)
  assert_eq(c:size(), 1)
  assert_eq(c:get("b"), 2)
  assert_nil(c:get("a"))
end)

-- ---------------------------------------------------------------------------
-- 6. Remove specific key
-- ---------------------------------------------------------------------------
test("remove deletes a specific key", function()
  local c = lru.new(5)
  c:put("a", 1)
  c:put("b", 2)
  c:put("c", 3)
  c:remove("b")
  assert_nil(c:get("b"), "b should be removed")
  assert_eq(c:get("a"), 1)
  assert_eq(c:get("c"), 3)
  assert_eq(c:size(), 2)
end)

test("remove non-existent key is a no-op", function()
  local c = lru.new(5)
  c:put("a", 1)
  c:remove("zzz")
  assert_eq(c:size(), 1)
  assert_eq(c:get("a"), 1)
end)

test("remove frees capacity for new entries", function()
  local c = lru.new(2)
  c:put("a", 1)
  c:put("b", 2)
  c:remove("a")
  c:put("c", 3)
  -- "b" should NOT be evicted because remove freed a slot
  assert_eq(c:get("b"), 2, "b should still exist")
  assert_eq(c:get("c"), 3)
  assert_eq(c:size(), 2)
end)

-- ---------------------------------------------------------------------------
-- 7. Size tracking accuracy
-- ---------------------------------------------------------------------------
test("size starts at 0", function()
  local c = lru.new(5)
  assert_eq(c:size(), 0)
end)

test("size increments on put", function()
  local c = lru.new(5)
  c:put("a", 1)
  assert_eq(c:size(), 1)
  c:put("b", 2)
  assert_eq(c:size(), 2)
end)

test("size does not exceed max_size", function()
  local c = lru.new(2)
  c:put("a", 1)
  c:put("b", 2)
  c:put("c", 3)
  assert_eq(c:size(), 2)
end)

test("size decrements on remove", function()
  local c = lru.new(5)
  c:put("a", 1)
  c:put("b", 2)
  c:remove("a")
  assert_eq(c:size(), 1)
end)

test("size is 0 after clear", function()
  local c = lru.new(5)
  c:put("a", 1)
  c:put("b", 2)
  c:clear()
  assert_eq(c:size(), 0)
end)

-- ---------------------------------------------------------------------------
-- 8. Entries iterator
-- ---------------------------------------------------------------------------
test("entries yields all key-value pairs", function()
  local c = lru.new(5)
  c:put("a", 1)
  c:put("b", 2)
  c:put("c", 3)
  local collected = {}
  for k, v in c:entries() do
    collected[k] = v
  end
  assert_eq(collected["a"], 1)
  assert_eq(collected["b"], 2)
  assert_eq(collected["c"], 3)
  -- Count entries
  local count = 0
  for _ in pairs(collected) do count = count + 1 end
  assert_eq(count, 3)
end)

test("entries on empty cache yields nothing", function()
  local c = lru.new(5)
  local count = 0
  for _ in c:entries() do
    count = count + 1
  end
  assert_eq(count, 0)
end)

test("entries reflects evictions", function()
  local c = lru.new(2)
  c:put("a", 1)
  c:put("b", 2)
  c:put("c", 3) -- evicts a
  local collected = {}
  for k, v in c:entries() do
    collected[k] = v
  end
  assert_nil(collected["a"], "a was evicted and should not appear")
  assert_eq(collected["b"], 2)
  assert_eq(collected["c"], 3)
end)

-- ---------------------------------------------------------------------------
-- 9. Edge cases
-- ---------------------------------------------------------------------------
test("max_size=1 keeps only the latest entry", function()
  local c = lru.new(1)
  c:put("a", 1)
  assert_eq(c:get("a"), 1)
  assert_eq(c:size(), 1)
  c:put("b", 2)
  assert_nil(c:get("a"), "a should be evicted with max_size=1")
  assert_eq(c:get("b"), 2)
  assert_eq(c:size(), 1)
end)

test("max_size=1 update keeps same key", function()
  local c = lru.new(1)
  c:put("a", 1)
  c:put("a", 2)
  assert_eq(c:get("a"), 2)
  assert_eq(c:size(), 1)
end)

test("putting nil value is treated as a miss by get", function()
  -- Because the implementation uses lookup[key] == nil to detect misses,
  -- storing nil means the key is effectively absent on subsequent gets.
  local c = lru.new(5)
  c:put("a", nil)
  -- The key will appear as a miss since lookup["a"] is nil
  assert_nil(c:get("a"), "nil-valued key should appear as a miss")
end)

test("max_size <= 0 raises an error", function()
  local ok_zero, err_zero = pcall(function() lru.new(0) end)
  assert_true(not ok_zero, "max_size=0 should error")
  assert_true(err_zero:match("positive"), "error message should mention 'positive'")

  local ok_neg, err_neg = pcall(function() lru.new(-1) end)
  assert_true(not ok_neg, "max_size=-1 should error")
  assert_true(err_neg:match("positive"), "error message should mention 'positive'")
end)

test("large number of insertions and evictions", function()
  local c = lru.new(10)
  for i = 1, 100 do
    c:put("k" .. i, i)
  end
  assert_eq(c:size(), 10, "size should be capped at 10")
  -- Only the last 10 should remain
  for i = 91, 100 do
    assert_eq(c:get("k" .. i), i, "k" .. i .. " should still be present")
  end
  for i = 1, 90 do
    assert_nil(c:get("k" .. i), "k" .. i .. " should have been evicted")
  end
end)

test("numeric keys work correctly", function()
  local c = lru.new(3)
  c:put(1, "one")
  c:put(2, "two")
  c:put(3, "three")
  assert_eq(c:get(1), "one")
  assert_eq(c:get(2), "two")
  assert_eq(c:get(3), "three")
  c:put(4, "four") -- evicts 1
  assert_nil(c:get(1))
end)

-- ============================================================================
-- Summary
-- ============================================================================
print("\n=== Results ===")
print(string.format("  %d passed, %d failed", passed, failed))
if #errors > 0 then
  print("\nFailures:")
  for _, e in ipairs(errors) do
    print("  " .. e.name .. ": " .. e.err)
  end
end

-- Exit with non-zero if any test failed
if failed > 0 then
  os.exit(1)
end
