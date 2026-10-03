-- Behavioral spec for DataviewJS '+' overloading (string concat vs numeric add).
-- Regression for ISSUE 5: JS `+` was emitted verbatim as Lua `+` (arithmetic),
-- so any string concatenation threw "attempt to perform arithmetic on a string
-- value" at runtime. The transpiler now rewrites every JS `+` into a call to the
-- runtime helper __js_add(a, b), which concatenates when either operand is a
-- string and adds numerically otherwise.
--
-- This spec exercises REAL module output: it transpiles via js2lua.transpile and
-- then compiles-and-RUNS the emitted Lua against a tiny __js_add mirroring the
-- one injected into the sandbox env (api.lua), asserting runtime VALUES. No
-- source-file introspection.
--
-- Run with: nvim --headless -u NONE -l tests/js2lua_string_concat_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_match = _H.test, _H.assert_eq, _H.assert_match

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local js2lua = require("andrew.vault.query.js2lua")

print("\n=== js2lua String Concatenation Tests ===\n")

-- Mirror of api.lua's sandbox helper so we can run the transpiled chunk in
-- isolation (no full vault index needed).
local function js_add(a, b)
  if type(a) == "string" or type(b) == "string" then
    return tostring(a) .. tostring(b)
  end
  return a + b
end

-- Transpile `js`, then compile and run it with __js_add (and any extra named
-- upvalues) in scope. Returns the runtime result of the chunk.
local function run(js, extra)
  local lua = assert(js2lua.transpile(js), "transpile returned nil")
  local sig = "local __js_add"
  local args = { js_add }
  if extra then
    for _, pair in ipairs(extra) do
      sig = sig .. "," .. pair[1]
      args[#args + 1] = pair[2]
    end
  end
  local fn = assert(loadstring(sig .. "=...; " .. lua), "transpiled Lua failed to compile")
  local unpk = table.unpack or unpack
  local ok, res = pcall(fn, unpk(args, 1, #args))
  assert(ok, "transpiled Lua errored at runtime: " .. tostring(res))
  return res
end

-- 1. String + string concatenates (the core reported failure).
test("string + string concatenates", function()
  assert_eq(run([[return "hello " + "world"]]), "hello world")
end)

-- 2. String + number coerces the number (JS semantics).
test("string + number coerces to string", function()
  assert_eq(run([[return "count: " + 5]]), "count: 5")
end)

-- 3. Number + number still adds numerically (regression guard, not "12").
test("number + number adds numerically", function()
  assert_eq(run([[return 1 + 2]]), 3)
end)

-- 4. Left-associative mixed chain.
test("string chain a + b + c is left-associative", function()
  assert_eq(run([[return "a" + "b" + "c"]]), "abc")
end)

-- 5. Numeric chain.
test("numeric chain 1 + 2 + 3 sums to 6", function()
  assert_eq(run([[return 1 + 2 + 3]]), 6)
end)

-- 6. RHS is a runtime member-access value (the exact reported repro shape).
test("string + member-access value concatenates at runtime", function()
  local lua = assert(js2lua.transpile([[return "x" + a.b]]))
  -- Assert the emitted module OUTPUT shape (allowed: this is module output,
  -- not reading source files).
  assert_match(lua, "__js_add%(", "emitted form should call __js_add")
  assert_match(lua, "a%.b", "emitted form should preserve the member access a.b")
  assert_eq(run([[return "x" + a.b]], { { "a", { b = "Y" } } }), "xY")
end)

-- 7. const binding via __js_add still binds the numeric value.
test("const x = 1 + 2 binds x to 3", function()
  assert_eq(run([[const x = 1 + 2; return x]]), 3)
end)

-- 8. Mixed-precedence: '*' binds tighter than '+' (JS semantics preserved).
test("1 + 2 * 3 respects precedence (= 7)", function()
  assert_eq(run([[return 1 + 2 * 3]]), 7)
end)

-- 9. Parenthesized addition is not swallowed by the helper.
test("(a + b) * c respects grouping (= 9 for 1,2,3)", function()
  assert_eq(
    run([[return (a + b) * c]], { { "a", 1 }, { "b", 2 }, { "c", 3 } }),
    9
  )
end)

-- 10. Inner '+' inside a call argument list stays scoped to that argument.
test("'+' inside call args binds only to that argument", function()
  -- f(1 + 2, 3) -> f(__js_add(1, 2), 3); define f to return its first arg.
  assert_eq(run([[return f(1 + 2, 3)]], { { "f", function(x) return x end } }), 3)
end)

-- 11-18. Regression guards for the additive rewrite: unary-prefixed RHS must
-- compile, and additive/subtractive chains must stay left-associative.
test("numeric add with unary-minus RHS compiles and evaluates", function()
  assert_eq(run([[return 1 + -2]]), -1)
end)
test("named operands with unary-minus RHS (total + -discount)", function()
  assert_eq(run([[return total + -discount]], { { "total", 10 }, { "discount", 3 } }), 7)
end)
test("unary-plus RHS is dropped (x + +y)", function()
  assert_eq(run([[return x + +y]], { { "x", 1 }, { "y", 2 } }), 3)
end)
test("mixed additive/subtractive stays left-associative (10 - 2 + 3 = 11)", function()
  assert_eq(run([[return 10 - 2 + 3]]), 11)
end)
test("a - b + c is (a - b) + c not a - (b + c)", function()
  assert_eq(run([[return a - b + c]], { { "a", 10 }, { "b", 2 }, { "c", 3 } }), 11)
end)
test("1 + 2 - 3 evaluates to 0", function()
  assert_eq(run([[return 1 + 2 - 3]]), 0)
end)
test("longer additive chain 1 - 2 + 3 - 4 = -2", function()
  assert_eq(run([[return 1 - 2 + 3 - 4]]), -2)
end)
test("string + unary-minus number concatenates (\"v\" + -1)", function()
  assert_eq(run([[return "v" + -1]]), "v-1")
end)

-- 19-23. String-literal LHS containing structural bracket chars must be
-- retained as the helper's first argument (regression for the backward
-- LHS-extraction scan miscounting brackets inside emitted Lua string literals).
-- Use long-bracket Lua delimiters so embedded `[[`/`]]` do not terminate the
-- enclosing Lua literal in this spec source.
test('"[" + x keeps the bracket literal as a non-empty first arg', function()
  assert_eq(run([==[return "[" + x]==], { { "x", "y" } }), "[y")
end)
test('"(" + a + ")" wraps a in parentheses', function()
  assert_eq(run([==[return "(" + a + ")"]==], { { "a", "x" } }), "(x)")
end)
test('"[[" + name + "]]" builds a wikilink', function()
  assert_eq(run([==[return "[[" + name + "]]"]==], { { "name", "Note" } }), "[[Note]]")
end)
test('"[" + label + "]" brackets the label', function()
  assert_eq(run([==[return "[" + label + "]"]==], { { "label", "L" } }), "[L]")
end)
test('string literal containing ")" has length 1', function()
  assert_eq(run([==[return ")".length]==]), 1)
end)

_H.finish({ style = "results", exit = "os" })
