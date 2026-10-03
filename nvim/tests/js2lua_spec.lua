-- Unit tests for lua/andrew/vault/query/js2lua/ (DataviewJS-to-Lua transpiler)
-- Run with: nvim --headless -u NONE -l tests/js2lua_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil, assert_deep_eq =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil, _H.assert_deep_eq

-- ============================================================================
-- Load modules under test
-- ============================================================================
package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local js2lua = require("andrew.vault.query.js2lua")
local tokenizer = require("andrew.vault.query.js2lua.tokenizer")
local regex = require("andrew.vault.query.js2lua.regex")
local postprocess = require("andrew.vault.query.js2lua.postprocess")
local context = require("andrew.vault.query.js2lua.context")

print("\n=== js2lua Transpiler Tests ===\n")

-- ---------------------------------------------------------------------------
-- 1. Tokenizer
-- ---------------------------------------------------------------------------

test("tokenizer: simple arithmetic produces ident/ws/op/ws/num + eof", function()
  local toks = tokenizer.tokenize("x + 1")
  assert_eq(#toks, 6, "token count")
  assert_eq(toks[1].type, "ident")
  assert_eq(toks[1].value, "x")
  assert_eq(toks[2].type, "ws")
  assert_eq(toks[3].type, "op")
  assert_eq(toks[3].value, "+")
  assert_eq(toks[4].type, "ws")
  assert_eq(toks[5].type, "num")
  assert_eq(toks[5].value, "1")
  assert_eq(toks[6].type, "eof")
  assert_eq(toks[6].value, "")
end)

test("tokenizer: member-access + call tokens", function()
  local toks = tokenizer.tokenize("foo.bar(1, 2)")
  assert_eq(toks[1].type, "ident")
  assert_eq(toks[1].value, "foo")
  assert_eq(toks[2].type, "op", "dot is an op token")
  assert_eq(toks[2].value, ".")
  assert_eq(toks[3].type, "ident")
  assert_eq(toks[3].value, "bar")
  assert_eq(toks[4].type, "punct")
  assert_eq(toks[4].value, "(")
  -- collect significant (non-ws, non-eof) tokens
  local sig = {}
  for _, t in ipairs(toks) do
    if t.type ~= "ws" and t.type ~= "nl" and t.type ~= "eof" then
      sig[#sig + 1] = t
    end
  end
  local expected = {
    { type = "ident", value = "foo" },
    { type = "op", value = "." },
    { type = "ident", value = "bar" },
    { type = "punct", value = "(" },
    { type = "num", value = "1" },
    { type = "punct", value = "," },
    { type = "num", value = "2" },
    { type = "punct", value = ")" },
  }
  assert_eq(#sig, #expected, "significant token count")
  for i, e in ipairs(expected) do
    assert_eq(sig[i].type, e.type, "sig token " .. i .. " type")
    assert_eq(sig[i].value, e.value, "sig token " .. i .. " value")
  end
  -- last non-eof token is the closing paren
  assert_eq(toks[#toks - 1].type, "punct")
  assert_eq(toks[#toks - 1].value, ")")
end)

test("tokenizer: double-quoted string is one STR token with quotes retained", function()
  local toks = tokenizer.tokenize('a = "hi"')
  local str_tok
  for _, t in ipairs(toks) do
    if t.type == "str" then
      assert_nil(str_tok, "only one str token expected")
      str_tok = t
    end
  end
  assert_true(str_tok ~= nil, "expected a str token")
  assert_eq(str_tok.value, '"hi"', "quotes are retained")
end)

test("tokenizer: regex literal recognized at statement start", function()
  local toks = tokenizer.tokenize("/\\w+/g")
  assert_eq(toks[1].type, "regex")
  assert_eq(toks[1].value, "/\\w+/g")
end)

test("tokenizer: slash is division after identifier", function()
  local toks = tokenizer.tokenize("a / b")
  local slash_tok
  for _, t in ipairs(toks) do
    assert_true(t.type ~= "regex", "no regex token expected")
    if t.value == "/" then slash_tok = t end
  end
  assert_true(slash_tok ~= nil, "expected a '/' token")
  assert_eq(slash_tok.type, "op", "slash after ident is division")
end)

test("tokenizer: slash is division after closing paren", function()
  local toks = tokenizer.tokenize("(a)/b")
  assert_eq(#toks, 6, "token count")
  assert_eq(toks[1].type, "punct")
  assert_eq(toks[1].value, "(")
  assert_eq(toks[2].type, "ident")
  assert_eq(toks[2].value, "a")
  assert_eq(toks[3].type, "punct")
  assert_eq(toks[3].value, ")")
  assert_eq(toks[4].type, "op", "slash after ')' is division")
  assert_eq(toks[4].value, "/")
  assert_eq(toks[5].type, "ident")
  assert_eq(toks[5].value, "b")
  assert_eq(toks[6].type, "eof")
end)

test("tokenizer: numbers - hex, float, exponent each a single NUM", function()
  local toks = tokenizer.tokenize("0x1F 3.14 1e3")
  local nums = {}
  for _, t in ipairs(toks) do
    if t.type == "num" then nums[#nums + 1] = t.value end
  end
  assert_eq(#nums, 3, "three num tokens")
  assert_eq(nums[1], "0x1F")
  assert_eq(nums[2], "3.14")
  assert_eq(nums[3], "1e3")
end)

test("tokenizer: template literal parsed into text+expr parts", function()
  local toks = tokenizer.tokenize("`hi ${name}`")
  assert_eq(toks[1].type, "tmpl")
  assert_true(toks[1].parts ~= nil, "tmpl token carries .parts")
  assert_deep_eq(toks[1].parts, {
    { type = "text", value = "hi " },
    { type = "expr", value = "name" },
  })
end)

test("tokenizer: always appends EOF", function()
  local toks = tokenizer.tokenize("")
  assert_eq(#toks, 1)
  assert_eq(toks[1].type, "eof")
  assert_eq(toks[1].value, "")
end)

-- ---------------------------------------------------------------------------
-- 2. Regex -> Lua pattern conversion
-- ---------------------------------------------------------------------------

test("regex: \\w+ with g flag", function()
  local pat, is_global = regex.regex_to_lua_pattern("/\\w+/g")
  assert_eq(pat, "[%w_]+")
  assert_eq(is_global, true)
end)

test("regex: \\d+ no flag", function()
  local pat, is_global = regex.regex_to_lua_pattern("/\\d+/")
  assert_eq(pat, "%d+")
  assert_eq(is_global, false)
end)

test("regex: char class [a-z]+ with i flag (flag ignored, not global)", function()
  local pat, is_global = regex.regex_to_lua_pattern("/[a-z]+/i")
  assert_eq(pat, "[a-z]+")
  assert_eq(is_global, false)
end)

test("regex: negated class", function()
  local pat, is_global = regex.regex_to_lua_pattern("/[^0-9]/")
  assert_eq(pat, "[^0-9]")
  assert_eq(is_global, false)
end)

test("regex: escaped dot becomes %.", function()
  local pat, is_global = regex.regex_to_lua_pattern("/foo\\.bar/")
  assert_eq(pat, "foo%.bar")
  assert_eq(is_global, false)
end)

test("regex: non-capturing group (?:ab) -> (ab)", function()
  local pat, is_global = regex.regex_to_lua_pattern("/(?:ab)/")
  assert_eq(pat, "(ab)")
  assert_eq(is_global, false)
end)

test("regex: quantifier {2,4} expanded", function()
  local pat, is_global = regex.regex_to_lua_pattern("/a{2,4}/")
  assert_eq(pat, "aaa?a?")
  assert_eq(is_global, false)
end)

test("regex: quantifier {1,} -> +", function()
  local pat, is_global = regex.regex_to_lua_pattern("/a{1,}/")
  assert_eq(pat, "a+")
  assert_eq(is_global, false)
end)

test("regex: \\s -> %s", function()
  local pat, is_global = regex.regex_to_lua_pattern("/\\s/")
  assert_eq(pat, "%s")
  assert_eq(is_global, false)
end)

test("regex: alternation unsupported returns nil", function()
  local pat, is_global = regex.regex_to_lua_pattern("/a|b/")
  assert_nil(pat, "alternation should fail conversion")
  assert_eq(is_global, false)
end)

test("regex: non-regex string returns nil,false", function()
  local pat, is_global = regex.regex_to_lua_pattern("not a regex")
  assert_nil(pat)
  assert_eq(is_global, false)
end)

-- ---------------------------------------------------------------------------
-- 3. Postprocess
-- ---------------------------------------------------------------------------

test("postprocess: compound += rewrite", function()
  assert_eq(postprocess.postprocess("x += 1"), "x = x + 1")
end)

test("postprocess: compound -= rewrite", function()
  assert_eq(postprocess.postprocess("x -= 2"), "x = x - 2")
end)

test("postprocess: 0-based index arr[0] -> arr[1]", function()
  assert_eq(postprocess.postprocess("arr[0]"), "arr[1]")
end)

test("postprocess: 0-based index a[2] -> a[3]", function()
  assert_eq(postprocess.postprocess("a[2]"), "a[3]")
end)

-- ---------------------------------------------------------------------------
-- 4. Context helpers
-- ---------------------------------------------------------------------------

test("context: make_ctx initial state", function()
  local toks = tokenizer.tokenize("a b")
  local ctx = context.make_ctx(toks)
  assert_eq(ctx.pos, 1)
  assert_eq(#ctx.out, 0)
  assert_eq(ctx.indent, "")
  assert_true(ctx.tokens == toks, "ctx holds the token list")
end)

test("context: tk_cur / tk_advance / tk_is on a fresh ctx", function()
  local ctx = context.make_ctx(tokenizer.tokenize("a b"))
  assert_eq(context.tk_cur(ctx).value, "a")
  assert_eq(context.tk_is(ctx, "ident", "a"), true)
  assert_eq(context.tk_is(ctx, "ident", "b"), false, "value mismatch")
  assert_eq(context.tk_is(ctx, "num"), false, "type mismatch")
  local t = context.tk_advance(ctx)
  assert_eq(t.value, "a", "advance returns the token we passed")
  assert_eq(ctx.pos, 2, "pos incremented")
end)

test("context: tk_peek out of range returns eof token", function()
  local ctx = context.make_ctx(tokenizer.tokenize("a"))
  local t = context.tk_peek(ctx, 99)
  assert_eq(t.type, "eof")
  assert_eq(t.value, "")
end)

test("context: peek_significant skips whitespace", function()
  local ctx = context.make_ctx(tokenizer.tokenize("  x"))
  local t, off = context.peek_significant(ctx, 0)
  assert_eq(t.type, "ident")
  assert_eq(t.value, "x")
  assert_true(off > 0, "offset should have skipped past the ws token")
  assert_eq(ctx.pos, 1, "peek does not move the cursor")
end)

test("context: skip_ws consumes and returns whitespace, advances to significant", function()
  local ctx = context.make_ctx(tokenizer.tokenize("  x"))
  local s = context.skip_ws(ctx)
  assert_eq(s, "  ", "consumed whitespace returned")
  assert_eq(context.tk_cur(ctx).value, "x", "cursor sits on first significant token")
end)

test("context: emit appends to out buffer", function()
  local ctx = context.make_ctx({})
  context.emit(ctx, "foo")
  context.emit(ctx, "bar")
  assert_deep_eq(ctx.out, { "foo", "bar" })
  assert_eq(table.concat(ctx.out), "foobar")
end)

-- ---------------------------------------------------------------------------
-- 5. transpile input validation / error path
-- ---------------------------------------------------------------------------

test("transpile: nil input errors", function()
  local out, err = js2lua.transpile(nil)
  assert_nil(out)
  assert_eq(err, "transpile: input must be a non-empty string")
end)

test("transpile: non-string input errors", function()
  local out, err = js2lua.transpile(42)
  assert_nil(out)
  assert_eq(err, "transpile: input must be a non-empty string")
end)

test("transpile: empty string errors", function()
  local out, err = js2lua.transpile("")
  assert_nil(out)
  assert_eq(err, "transpile: input must be a non-empty string")
end)

-- ---------------------------------------------------------------------------
-- 6. End-to-end transpile
-- ---------------------------------------------------------------------------

local function assert_transpile(js, expected_lua)
  local out, err = js2lua.transpile(js)
  assert_nil(err, "unexpected transpile error")
  assert_eq(out, expected_lua)
end

test("e2e: arithmetic transpile (+ rewrites to __js_add runtime helper)", function()
  assert_transpile("const x = 1 + 2", "local x = __js_add(1, 2)")
end)

test("e2e: strict equality === -> ==", function()
  assert_transpile("const y = a === b", "local y = a == b")
end)

test("e2e: logical && || ! -> and/or/not", function()
  assert_transpile("return a && b || !c", "return a  and  b  or  not c")
end)

test("e2e: array literal [] -> {}", function()
  assert_transpile("const arr = [1, 2, 3]", "local arr = {1, 2, 3}")
end)

test("e2e: array literal in expression-bodied arrow -> table", function()
  assert_transpile(
    "dv.pages().map(p => [p.file.name, p.rating])",
    "dv.pages():map(function(p) return {p.file.name, p.rating} end)"
  )
end)

test("e2e: array literal in block-bodied arrow return -> table", function()
  local out, err = js2lua.transpile("const g = p => { return [p.a, p.b]; }")
  assert_nil(err, "unexpected transpile error")
  assert_true(out:find("return {p.a, p.b}", 1, true) ~= nil, "block arrow should return a Lua table")
  assert_true(load("return function() " .. out .. " end") ~= nil, "output must compile")
end)

test("e2e: arrow returning array literal compiles", function()
  local out = js2lua.transpile("dv.pages().map(p => [p.file.name, p.rating])")
  assert_true(load("return function() " .. out .. " end") ~= nil, "must be valid Lua")
end)

test("e2e: indexing after return stays as [] (not table)", function()
  assert_transpile("return arr[0]", "return arr[1]")
end)

test("e2e: .length -> # operator", function()
  assert_transpile("return arr.length", "return #arr")
end)

test("e2e: .toLowerCase() -> :lower()", function()
  assert_transpile("return s.toLowerCase()", "return s:lower()")
end)

test("e2e: for-of loop + .push -> ipairs + table.insert", function()
  assert_transpile(
    "for (const p of pages) { x.push(p) }",
    "for _, p in ipairs(pages) do table.insert(x, p)\nend"
  )
end)

test("e2e: if/else statement", function()
  assert_transpile(
    "if (a > 1) { return 1 } else { return 2 }",
    "if a > 1 then return 1\nelse return 2\nend"
  )
end)

test("e2e: new Map() -> {}", function()
  assert_transpile("const m = new Map()", "local m = {}")
end)

test("e2e: ternary -> IIFE (no space after return)", function()
  assert_transpile(
    "return a ? 1 : 2",
    "return(function() if a then return 1 else return 2 end end)()"
  )
end)

test("e2e: compound assignment via postprocess in pipeline", function()
  assert_transpile("let i = 0; i += 5", "local i = 0 i = i + 5")
end)

test("e2e: increment", function()
  assert_transpile("x++", "x = x + 1")
end)

test("e2e: decrement compound", function()
  assert_transpile("x -= 2", "x = x - 2")
end)

test("e2e: Math.round -> math.floor(x+0.5)", function()
  assert_transpile("return Math.round(3.7)", "return math.floor(3.7 + 0.5)")
end)

test("e2e: typeof -> type()", function()
  assert_transpile("return typeof x", "return type(x)")
end)

test("e2e: null -> nil", function()
  assert_transpile("return null", "return nil")
end)

test("e2e: undefined -> nil", function()
  assert_transpile("return undefined", "return nil")
end)

test("e2e: template literal -> concat with tostring", function()
  assert_transpile("return `hi ${name}`", 'return "hi " .. tostring(name)')
end)

test("e2e: 0-based index conversion", function()
  assert_transpile("return arr[0]", "return arr[1]")
end)

test("e2e: single-quoted string converted to double-quoted", function()
  assert_transpile("const s = 'hello'", 'local s = "hello"')
end)

test("e2e: .replace(/foo/g, 'bar') -> :gsub", function()
  assert_transpile("return s.replace(/foo/g, 'bar')", 'return s:gsub("foo", "bar")')
end)

test("e2e: .split(',') -> :split", function()
  assert_transpile("return s.split(',')", 'return s:split(",")')
end)

test("e2e: .includes('x') -> :find(...,1,true) ~= nil", function()
  assert_transpile("return a.includes('x')", 'return a:find("x", 1, true) ~= nil')
end)

test("e2e: console.log -> print", function()
  assert_transpile("console.log(x)", "print(x)")
end)

test("e2e: JSON.stringify -> vim.inspect", function()
  assert_transpile("return JSON.stringify(x)", "return vim.inspect(x)")
end)

test("e2e: Object.keys -> pairs-collecting IIFE", function()
  assert_transpile(
    "return Object.keys(x)",
    "return (function() local _k = {}; for k in pairs(x) do _k[#_k+1] = k end; return _k end)()"
  )
end)

-- ============================================================================
-- Optional chaining (?.) — Issue 7
-- ============================================================================

-- True when the transpiled Lua loads as a function body (catches malformed
-- output like `return .rating`).
local function loads(lua)
  return select(1, load("return function() " .. lua .. " end")) ~= nil
end

test("optional chaining: a?.b emits nil-safe access", function()
  local out = js2lua.transpile("a?.b")
  assert_eq(out, '__index_safe(a, "b")')
  assert_true(loads(out), "emitted Lua loads")
end)

test("optional chaining: dv.current()?.rating", function()
  local out = js2lua.transpile("dv.current()?.rating")
  assert_eq(out, '__index_safe(dv.current(), "rating")')
  assert_true(loads(out), "emitted Lua loads")
end)

test("optional chaining chains: a?.b?.c nests left-associative", function()
  local out = js2lua.transpile("a?.b?.c")
  assert_eq(out, '__index_safe(__index_safe(a, "b"), "c")')
  assert_true(loads(out), "emitted Lua loads")
end)

test("optional chaining with assignment: const x = a?.b", function()
  local out = js2lua.transpile("const x = a?.b")
  assert_true(out:find('__index_safe(a, "b")', 1, true) ~= nil, "contains nil-safe access")
  assert_true(loads(out), "emitted Lua loads")
end)

test("optional chaining computed: a?.[k]", function()
  local out = js2lua.transpile("a?.[k]")
  assert_eq(out, "__index_safe(a, k)")
  assert_true(loads(out), "emitted Lua loads")
end)

test("regression: ternary still works (cond ? x : y)", function()
  local out = js2lua.transpile("cond ? x : y")
  assert_eq(out, "(function() if cond then return x else return y end end)()")
  assert_true(loads(out), "emitted Lua loads")
end)

test("regression: mixed x = a?.b ? 1 : 2 (ternary cond is nil-safe access)", function()
  local out = js2lua.transpile("x = a?.b ? 1 : 2")
  assert_true(out:find('if __index_safe(a, "b") then', 1, true) ~= nil, "ternary condition is nil-safe")
  assert_true(loads(out), "emitted Lua loads")
end)

test("regression: plain member access unchanged (a.b.c)", function()
  assert_eq(js2lua.transpile("a.b.c"), "a.b.c")
end)

test("runtime: __index_safe returns nil for nil obj, value otherwise", function()
  local api = require("andrew.vault.query.api")
  local env = api.create_env(nil, nil)
  assert_nil(env.__index_safe(nil, "x"), "nil obj -> nil")
  assert_eq(env.__index_safe({ x = 1 }, "x"), 1, "present key -> value")
end)

-- ============================================================================
-- Summary
-- ============================================================================
_H.finish({ style = "results", exit = "os" })
