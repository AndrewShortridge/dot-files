-- Regression spec for the vault-c audit fixes in the query stack.
-- Run with: nvim --headless -u NONE -l tests/audit_vaultc_query_spec.lua
--
-- Covers, behaviourally (no source introspection):
--   1. js2lua `.sort(...)` must stay chainable and must NOT emit table.sort()
--      (table.sort returns nil, so `const x = a.sort(f)` lost the array).
--   2. PageArray:sort() must accept a 1-arg Dataview key extractor as well as a
--      2-arg comparator (number or boolean result).
--   3. js2lua `.length` must not swallow the enclosing call: `f(a.length)`.
--   4. Nested array literals `[[1, 2]]` must transpile to loadable Lua.
--   5. PageArray implicit field access (`dv.pages().file.tasks`) flattens.
--   6. render_error must not embed a raw newline in a virt_line chunk.

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

-- Stub the logger so requiring real modules does not pull the full vault infra.
-- The catch-all __index also satisfies module-level calls like vault_log.configure().
package.loaded["andrew.vault.vault_log"] = setmetatable({
  scope = function()
    return setmetatable({}, { __index = function() return function() end end })
  end,
}, { __index = function() return function() end end })

local js2lua = require("andrew.vault.query.js2lua")
local api = require("andrew.vault.query.api")
local render = require("andrew.vault.query.render")

local function loads(src)
  local f = (loadstring or load)(src)
  return f ~= nil
end

-- ── 1. .sort() stays chainable ─────────────────────────────────────────────

test(".sort(key) does not emit table.sort (which returns nil)", function()
  local out = js2lua.transpile('const p = dv.pages("x").sort(p => p.file.name);')
  assert_true(out ~= nil, "transpile produced output")
  assert_true(out:find("table.sort", 1, true) == nil,
    "must not emit table.sort(): " .. tostring(out))
  assert_true(out:find(":sort(", 1, true) ~= nil, "must emit :sort(): " .. tostring(out))
  assert_true(loads(out), "emitted Lua must load: " .. tostring(out))
end)

test(".where().sort().map() chain stays a single expression", function()
  local out = js2lua.transpile(
    'dv.list(dv.pages("x").where(p => true).sort(p => p.file.name).map(p => p.file.name));')
  assert_true(loads(out), "emitted Lua must load: " .. tostring(out))
  assert_true(out:find(":where%(") ~= nil and out:find(":sort%(") ~= nil and out:find(":map%(") ~= nil,
    "all three links of the chain must be method calls: " .. tostring(out))
end)

-- ── 2. PageArray:sort arity handling ───────────────────────────────────────

test("PageArray:sort(key) sorts by the extracted key and returns a new array", function()
  -- PageArray has no public constructor: build one through the real dv env.
  local index = {
    all_pages = function()
      return { { n = "c" }, { n = "a" }, { n = "b" } }
    end,
    resolve_source = function() return {} end,
    current_page = function() return nil end,
    get_page = function() return nil end,
  }
  local captured
  local results, err = api.execute_block([[
    local src = dv.pages()
    local sorted = src:sort(function(p) return p.n end)
    dv.paragraph(sorted[1].n .. sorted[2].n .. sorted[3].n .. "|" .. src[1].n)
  ]], index, "/tmp/Note.md")
  assert_true(err == nil, "no error: " .. tostring(err))
  for _, item in ipairs(results or {}) do
    if item.type == "paragraph" then captured = item.text end
  end
  assert_eq(captured, "abc|c", "key extractor sorts ascending and leaves the source untouched")
end)

test("PageArray:sort(key, 'desc') reverses", function()
  local index = {
    all_pages = function() return { { n = "a" }, { n = "c" }, { n = "b" } } end,
    resolve_source = function() return {} end,
    current_page = function() return nil end,
    get_page = function() return nil end,
  }
  local out
  local results = api.execute_block([[
    local s = dv.pages():sort(function(p) return p.n end, "desc")
    dv.paragraph(s[1].n .. s[2].n .. s[3].n)
  ]], index, "/tmp/Note.md")
  for _, item in ipairs(results or {}) do
    if item.type == "paragraph" then out = item.text end
  end
  assert_eq(out, "cba")
end)

test("PageArray:sort(comparator) accepts both boolean and JS-number results", function()
  local index = {
    all_pages = function() return { { n = 3 }, { n = 1 }, { n = 2 } } end,
    resolve_source = function() return {} end,
    current_page = function() return nil end,
    get_page = function() return nil end,
  }
  local bool_out, num_out
  local r1 = api.execute_block([[
    local s = dv.pages():sort(function(a, b) return a.n < b.n end)
    dv.paragraph(tostring(s[1].n) .. tostring(s[2].n) .. tostring(s[3].n))
  ]], index, "/tmp/Note.md")
  for _, i in ipairs(r1 or {}) do if i.type == "paragraph" then bool_out = i.text end end
  local r2 = api.execute_block([[
    local s = dv.pages():sort(function(a, b) return a.n - b.n end)
    dv.paragraph(tostring(s[1].n) .. tostring(s[2].n) .. tostring(s[3].n))
  ]], index, "/tmp/Note.md")
  for _, i in ipairs(r2 or {}) do if i.type == "paragraph" then num_out = i.text end end
  assert_eq(bool_out, "123", "boolean comparator")
  assert_eq(num_out, "123", "JS-style numeric comparator")
end)

-- ── 3. .length inside an argument list ─────────────────────────────────────

test(".length as a sole call argument becomes #arg, not #(call)", function()
  local out = js2lua.transpile("dv.paragraph(a.length)")
  assert_eq(vim.trim(out), "dv.paragraph(#a)")
  assert_true(loads(out))
end)

test(".length after a comma argument stays inside the call", function()
  local out = js2lua.transpile("dv.table(h, r.length)")
  assert_true(loads(out), "must load: " .. tostring(out))
  assert_true(out:find("dv.table%(h, #r") ~= nil, "got: " .. tostring(out))
end)

test(".length on a call result stays inside the enclosing call", function()
  local out = js2lua.transpile("dv.paragraph(dv.pages().length)")
  assert_true(loads(out), "must load: " .. tostring(out))
  assert_true(out:find("dv.paragraph%(#") ~= nil, "got: " .. tostring(out))
end)

-- ── 4. Nested array literals ──────────────────────────────────────────────

test("nested array literal [[1, 2]] transpiles to loadable Lua", function()
  local out = js2lua.transpile('dv.table(["a"], [[1, 2]])')
  assert_true(loads(out), "must load: " .. tostring(out))
  assert_true(out:find("{{1, 2}}", 1, true) ~= nil, "got: " .. tostring(out))
end)

test("computed property access inside an array literal still transpiles", function()
  local out = js2lua.transpile("dv.list([a[1], b])")
  assert_true(loads(out), "must load: " .. tostring(out))
end)

-- ── 5. PageArray implicit field access ────────────────────────────────────

test("dv.pages().file.tasks flattens tasks across pages", function()
  local index = {
    all_pages = function()
      return {
        { file = { name = "a", tasks = { { text = "t1", completed = false } } } },
        { file = { name = "b", tasks = { { text = "t2", completed = true },
                                        { text = "t3", completed = false } } } },
      }
    end,
    resolve_source = function() return {} end,
    current_page = function() return nil end,
    get_page = function() return nil end,
  }
  local out
  local results, err = api.execute_block([[
    local t = dv.pages().file.tasks
    dv.paragraph(tostring(#t) .. ":" .. t[1].text .. t[2].text .. t[3].text)
  ]], index, "/tmp/Note.md")
  assert_true(err == nil, "no error: " .. tostring(err))
  for _, i in ipairs(results or {}) do if i.type == "paragraph" then out = i.text end end
  assert_eq(out, "3:t1t2t3")
end)

test("implicit field access chains into :where()", function()
  local index = {
    all_pages = function()
      return {
        { file = { tasks = { { text = "open", completed = false } } } },
        { file = { tasks = { { text = "done", completed = true } } } },
      }
    end,
    resolve_source = function() return {} end,
    current_page = function() return nil end,
    get_page = function() return nil end,
  }
  local out
  local results = api.execute_block([[
    local t = dv.pages().file.tasks:where(function(x) return not x.completed end)
    dv.paragraph(tostring(#t) .. ":" .. t[1].text)
  ]], index, "/tmp/Note.md")
  for _, i in ipairs(results or {}) do if i.type == "paragraph" then out = i.text end end
  assert_eq(out, "1:open")
end)

test("an underscore-prefixed key on a PageArray still reads as nil", function()
  local index = {
    all_pages = function() return { { a = 1 } } end,
    resolve_source = function() return {} end,
    current_page = function() return nil end,
    get_page = function() return nil end,
  }
  local out
  local results = api.execute_block([[
    dv.paragraph(tostring(dv.pages()._nope))
  ]], index, "/tmp/Note.md")
  for _, i in ipairs(results or {}) do if i.type == "paragraph" then out = i.text end end
  assert_eq(out, "nil")
end)

-- ── 6. Error rendering must be newline-free ───────────────────────────────

test("render_error flattens embedded newlines (virt_line chunks cannot hold them)", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "```vault", "x", "```", "after" })
  render.render(buf, 2, { { type = "error", message = "syntax error:\n[string \"q\"]:1: boom" } })
  local ns = vim.api.nvim_create_namespace("vault_query")
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  assert_true(#marks > 0, "an extmark is placed")
  local found = false
  for _, m in ipairs(marks) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      for _, chunk in ipairs(vl) do
        assert_true(chunk[1]:find("\n", 1, true) == nil,
          "no raw newline in chunk: " .. vim.inspect(chunk[1]))
        if chunk[1]:find("boom", 1, true) then found = true end
      end
    end
  end
  assert_true(found, "the error text still reaches the output")
end)

test("query output extmark sits on the line AFTER the closing fence, above", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "```vault", "x", "```", "after" })
  render.render(buf, 2, { { type = "paragraph", text = "hi" } })
  local ns = vim.api.nvim_create_namespace("vault_query")
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  assert_eq(#marks, 1)
  assert_eq(marks[1][2], 3, "row is close_line + 1")
  assert_true(marks[1][4].virt_lines_above == true, "virt_lines_above must be set")
end)

test("clear_inline_line removes only that line's inline marks", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a `$=1+1`", "b `$=2+2`" })
  render.render_inline(buf, 0, 8, "2", false)
  render.render_inline(buf, 1, 8, "4", false)
  local ns = vim.api.nvim_create_namespace("vault_query_inline")
  assert_eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 2)
  render.clear_inline_line(buf, 0)
  local left = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
  assert_eq(#left, 1)
  assert_eq(left[1][2], 1, "the surviving mark is on line 1")
end)

_H.finish({ style = "results", exit = "os" })
