-- Behavioral spec for the DataviewJS `dv.taskList(...)` API.
-- Run with: nvim --headless -u NONE -l tests/dv_tasklist_spec.lua
--
-- Covers Issue 8: dv.taskList was never registered on the `dv` env, so calling
-- it threw "attempt to call a nil value". These assertions exercise the real
-- executor (api.execute_block) and the real renderer (render.render) end to
-- end -- they do NOT introspect source text.

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

-- Stub the logger so requiring real modules doesn't pull full vault infra.
package.loaded["andrew.vault.vault_log"] = {
  scope = function()
    return setmetatable({}, { __index = function() return function() end end })
  end,
}

local api = require("andrew.vault.query.api")
local render = require("andrew.vault.query.render")

-- Minimal fake index sufficient for the API surface used here.
-- `all_pages` returns task-shaped records so `dv.pages()` yields a real
-- PageArray we can feed to dv.taskList (exercising the PageArray branch).
local index = {
  all_pages = function()
    return {
      { text = "p", completed = true },
      { text = "q", completed = false },
    }
  end,
  resolve_source = function() return {} end,
  current_page = function() return nil end,
  get_page = function() return nil end,
}

local function run(code)
  return api.execute_block(code, index, "/tmp/Note.md")
end

-- ── Registration / flat input ──────────────────────────────────────────────

test("dv.taskList is registered (no nil-value error)", function()
  local results, err = run([[ dv.taskList({}) ]])
  assert_nil(err)
  assert_true(results ~= nil)
end)

test("flat array yields one task_list with one group of two tasks", function()
  local results, err = run([[
    dv.taskList({
      { text = "a", completed = false },
      { text = "b", completed = true },
    })
  ]])
  assert_nil(err)
  assert_eq(#results, 1)
  assert_eq(results[1].type, "task_list")
  assert_eq(#results[1].groups, 1)
  local tasks = results[1].groups[1].tasks
  assert_eq(#tasks, 2)
  assert_eq(tasks[1].text, "a")
  assert_eq(tasks[1].completed, false)
  assert_eq(tasks[2].text, "b")
  assert_eq(tasks[2].completed, true)
end)

test("completed is coerced to a strict boolean", function()
  -- A truthy non-boolean must NOT survive as-is; it becomes false unless == true.
  local results, err = run([[
    dv.taskList({ { text = "x", completed = "yes" } })
  ]])
  assert_nil(err)
  local t = results[1].groups[1].tasks[1]
  assert_eq(type(t.completed), "boolean")
  assert_eq(t.completed, false)
end)

-- ── PageArray input ────────────────────────────────────────────────────────

test("PageArray input is accepted and unwrapped", function()
  local results, err = run([[
    local pa = dv.pages()  -- real PageArray from the (fake) index
    dv.taskList(pa)
  ]])
  assert_nil(err)
  assert_eq(results[1].type, "task_list")
  local tasks = results[1].groups[1].tasks
  assert_eq(#tasks, 2)
  assert_eq(tasks[1].text, "p")
  assert_eq(tasks[1].completed, true)
  assert_eq(tasks[2].completed, false)
end)

-- ── Grouped input ──────────────────────────────────────────────────────────

test("grouped input keeps group names and per-task flags", function()
  local results, err = run([[
    dv.taskList({
      { name = "Project A", tasks = { { text = "a1", completed = false } } },
      { name = "Project B", tasks = { { text = "b1", completed = true }, { text = "b2", completed = false } } },
    })
  ]])
  assert_nil(err)
  local groups = results[1].groups
  assert_eq(#groups, 2)
  assert_eq(groups[1].name, "Project A")
  assert_eq(#groups[1].tasks, 1)
  assert_eq(groups[1].tasks[1].completed, false)
  assert_eq(groups[2].name, "Project B")
  assert_eq(#groups[2].tasks, 2)
  assert_eq(groups[2].tasks[1].completed, true)
  assert_eq(groups[2].tasks[2].completed, false)
end)

-- ── nil input ──────────────────────────────────────────────────────────────

test("nil input pushes empty groups", function()
  local results, err = run([[ dv.taskList() ]])
  assert_nil(err)
  assert_eq(results[1].type, "task_list")
  assert_eq(#results[1].groups, 0)
end)

-- ── Rendering: glyphs for open vs done tasks ───────────────────────────────

test("render emits an open circle for open and a check mark for done", function()
  local results = run([[
    dv.taskList({
      { text = "open one", completed = false },
      { text = "done one", completed = true },
    })
  ]])

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "```dataviewjs", "```", "after" })
  render.render(buf, 1, results)

  -- Read the placed extmark's virt_lines and flatten all chunk text.
  local ns = vim.api.nvim_get_namespaces()["vault_query"]
  assert_true(ns ~= nil, "render namespace must exist")
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  assert_true(#marks > 0, "an extmark must be placed")

  local blob = {}
  for _, m in ipairs(marks) do
    local vls = m[4] and m[4].virt_lines or {}
    for _, vl in ipairs(vls) do
      for _, chunk in ipairs(vl) do
        blob[#blob + 1] = chunk[1]
      end
    end
  end
  blob = table.concat(blob, "\n")

  assert_true(blob:find("\u{25CB}", 1, true) ~= nil, "open circle glyph expected for open task")
  assert_true(blob:find("\u{2713}", 1, true) ~= nil, "check mark glyph expected for done task")
  assert_true(blob:find("open one", 1, true) ~= nil)
  assert_true(blob:find("done one", 1, true) ~= nil)
end)

_H.finish({ style = "results", exit = "os" })
