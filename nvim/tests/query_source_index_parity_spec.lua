-- Behavioral spec for index-backed FROM #tag / FROM "folder" resolution.
--
-- pages_in_folder / pages_with_tag used to scan EVERY page on each query
-- execution (paid on every post-save cache miss); pages_with_tag additionally
-- called vault_index.tag_matches (an inner loop over each page's tags) per page.
-- They now resolve a candidate rel_path set from inverted tag/folder indexes
-- maintained inside the query Index (built in build_from_vault_index and
-- rebuilt in apply_partial).
--
-- This spec proves the index-backed resolvers return the IDENTICAL page set as
-- the old linear scan, including the load-bearing semantics:
--   * parent-tag matching (tag "project" matches "project/active")
--   * the prefix MUST be slash-bounded ("project" does NOT match "myproject")
--   * bare non-prefix tag segments are NOT registered ("active" does NOT match
--     "project/active")
--   * case-sensitive tag matching (no lowercasing)
--   * nested-folder semantics (FROM "Projects" matches Projects/... but not
--     ProjectsX)
--   * resolve_source AND/OR/NOT integration
--   * apply_partial keeps the maps consistent with a fresh full build
--
-- Drives the REAL vault_index + real query/index against a temp vault (no mock),
-- per repo conventions. Parity is compared against the REAL
-- vault_index.tag_matches and the real folder predicate, not a hand-rolled copy,
-- so the test stays honest if those semantics ever change.
--
-- Run with: nvim --headless -u NONE -l tests/query_source_index_parity_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local vault_index = require("andrew.vault.vault_index")
local QI = require("andrew.vault.query.index")

print("\n=== Query Source Index (tag/folder) Parity Tests ===\n")

-- ---------------------------------------------------------------------------
-- Temp vault helpers.
-- ---------------------------------------------------------------------------
local function write_file(dir, rel, lines)
  local abs = dir .. "/" .. rel
  local parent = abs:match("^(.*)/[^/]+$")
  if parent then vim.fn.mkdir(parent, "p") end
  local f = assert(io.open(abs, "w"))
  f:write(table.concat(lines, "\n"))
  f:close()
end

-- Exercise every semantic:
--  Projects/Alpha.md      tags: project, project/active
--  Projects/Sub/Beta.md   tag:  project/active
--  ProjectsX/Gamma.md     tag:  myproject       (prefix-trap decoy)
--  Other/Delta.md         tag:  project
--  Top.md                 no tags, root folder ""
local function make_vault()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  write_file(dir, "Projects/Alpha.md", {
    "---", "tags: [project, project/active]", "---", "", "Alpha",
  })
  write_file(dir, "Projects/Sub/Beta.md", {
    "---", "tags: [project/active]", "---", "", "Beta",
  })
  write_file(dir, "ProjectsX/Gamma.md", {
    "---", "tags: [myproject]", "---", "", "Gamma",
  })
  write_file(dir, "Other/Delta.md", {
    "---", "tags: [project]", "---", "", "Delta",
  })
  write_file(dir, "Top.md", { "---", "title: Top", "---", "", "Top" })
  return dir
end

local function fresh_vi(dir)
  vault_index._instance = nil
  local idx = vault_index.get(dir)
  idx:build_sync()
  return idx
end

-- Set of rel_paths from a page list.
local function rel_set(pages)
  local s = {}
  for _, p in ipairs(pages) do s[p.file.path] = true end
  return s
end

local function set_eq(a, b, msg)
  for k in pairs(a) do assert_true(b[k], (msg or "") .. ": missing " .. tostring(k)) end
  for k in pairs(b) do assert_true(a[k], (msg or "") .. ": extra " .. tostring(k)) end
end

local function keys(s)
  local t = {}
  for k in pairs(s) do t[#t + 1] = k end
  table.sort(t)
  return table.concat(t, ",")
end

-- The OLD linear-scan implementations, driven against the REAL semantics.
local function linear_tag(q, tag)
  local s = {}
  for rp, page in pairs(q.pages) do
    if vault_index.tag_matches(page.file.tags, tag) then s[rp] = true end
  end
  return s
end

local function linear_folder(q, folder)
  folder = folder:gsub("/$", "")
  local s = {}
  for rp, page in pairs(q.pages) do
    local pf = page.file.folder
    if pf == folder or pf:sub(1, #folder + 1) == folder .. "/" then s[rp] = true end
  end
  return s
end

-- ===========================================================================
-- 1. pages_with_tag parity (parent match, prefix-trap, bare-segment trap).
-- ===========================================================================
test("pages_with_tag matches the linear scan for every tag case", function()
  local dir = make_vault()
  local vi = fresh_vi(dir)
  local q = QI.Index.new(dir)
  q:build_from_vault_index()

  for _, tag in ipairs({ "project", "project/active", "myproject", "active", "Project" }) do
    local got = rel_set(q:pages_with_tag(tag))
    local want = linear_tag(q, tag)
    set_eq(got, want, "tag " .. tag .. " (got=" .. keys(got) .. " want=" .. keys(want) .. ")")
  end

  -- Spell out the load-bearing cases explicitly.
  local proj = rel_set(q:pages_with_tag("project"))
  assert_true(proj["Projects/Alpha.md"], "project matches Alpha (exact)")
  assert_true(proj["Projects/Sub/Beta.md"], "project matches Beta (parent of project/active)")
  assert_true(proj["Other/Delta.md"], "project matches Delta (exact)")
  assert_nil(proj["ProjectsX/Gamma.md"], "project does NOT match myproject (slash-bounded prefix)")

  -- Bare non-prefix segment must NOT match (the #1 correctness trap).
  assert_nil(next(linear_tag(q, "active")), "linear scan: 'active' matches nothing")
  assert_nil(next(rel_set(q:pages_with_tag("active"))),
    "index: 'active' matches nothing (no bare-segment registration)")

  -- Case-sensitivity: "Project" (capital P) matches nothing.
  assert_nil(next(rel_set(q:pages_with_tag("Project"))), "tag match is case-sensitive")
end)

-- ===========================================================================
-- 2. pages_in_folder parity (nesting + prefix-trap + root).
-- ===========================================================================
test("pages_in_folder matches the linear scan for every folder case", function()
  local dir = make_vault()
  local vi = fresh_vi(dir)
  local q = QI.Index.new(dir)
  q:build_from_vault_index()

  for _, folder in ipairs({ "Projects", "Projects/", "Projects/Sub", "ProjectsX", "Other", "", "Missing" }) do
    local got = rel_set(q:pages_in_folder(folder))
    local want = linear_folder(q, folder)
    set_eq(got, want, "folder '" .. folder .. "' (got=" .. keys(got) .. " want=" .. keys(want) .. ")")
  end

  local proj = rel_set(q:pages_in_folder("Projects"))
  assert_true(proj["Projects/Alpha.md"], "Projects matches Alpha")
  assert_true(proj["Projects/Sub/Beta.md"], "Projects matches nested Beta")
  assert_nil(proj["ProjectsX/Gamma.md"], "Projects does NOT match ProjectsX (slash-bounded)")

  assert_eq(keys(rel_set(q:pages_in_folder("Projects/Sub"))), "Projects/Sub/Beta.md",
    "Projects/Sub matches only Beta")

  -- Root folder.
  assert_true(rel_set(q:pages_in_folder(""))["Top.md"], "root folder matches Top.md")
  assert_nil(rel_set(q:pages_in_folder(""))["Projects/Alpha.md"], "root folder excludes nested pages")
end)

-- ===========================================================================
-- 3. resolve_source AND/OR/NOT integration parity.
-- ===========================================================================
test("resolve_source AND/OR/NOT match a from-scratch linear resolution", function()
  local dir = make_vault()
  local vi = fresh_vi(dir)
  local q = QI.Index.new(dir)
  q:build_from_vault_index()

  -- Linear reference resolver mirroring resolve_source's set logic.
  local function lin_resolve(node)
    if node.type == "folder" then return linear_folder(q, node.path) end
    if node.type == "tag" then return linear_tag(q, node.tag) end
    if node.type == "or" then
      local r = {}
      for k in pairs(lin_resolve(node.left)) do r[k] = true end
      for k in pairs(lin_resolve(node.right)) do r[k] = true end
      return r
    end
    if node.type == "and" then
      local l, rr = lin_resolve(node.left), lin_resolve(node.right)
      local r = {}
      for k in pairs(l) do if rr[k] then r[k] = true end end
      return r
    end
    if node.type == "not" then
      local op = lin_resolve(node.operand)
      local r = {}
      for k in pairs(q.pages) do if not op[k] then r[k] = true end end
      return r
    end
    return {}
  end

  local nodes = {
    { type = "or",
      left = { type = "tag", tag = "project/active" },
      right = { type = "folder", path = "Other" } },
    { type = "and",
      left = { type = "tag", tag = "project" },
      right = { type = "folder", path = "Projects" } },
    { type = "not", operand = { type = "tag", tag = "project" } },
    { type = "and",
      left = { type = "folder", path = "Projects" },
      right = { type = "not", operand = { type = "tag", tag = "project/active" } } },
  }

  for i, node in ipairs(nodes) do
    local got = rel_set(q:resolve_source(node))
    local want = lin_resolve(node)
    set_eq(got, want, "resolve_source node #" .. i ..
      " (got=" .. keys(got) .. " want=" .. keys(want) .. ")")
  end
end)

-- ===========================================================================
-- 4. apply_partial keeps the source indexes consistent with a full rebuild.
-- ===========================================================================
test("apply_partial rebuilds source indexes identically to a full build", function()
  local dir = make_vault()
  local vi = fresh_vi(dir)
  local q = QI.Index.new(dir)
  q:build_from_vault_index()

  -- Sanity baseline.
  assert_true(rel_set(q:pages_with_tag("project"))["Projects/Alpha.md"], "Alpha tagged project initially")

  -- Edit Alpha: drop "project", add "archive".
  write_file(dir, "Projects/Alpha.md", {
    "---", "tags: [archive]", "---", "", "Alpha",
  })
  vi:update_file(dir .. "/Projects/Alpha.md")
  local ctx = vi._last_inv_ctx
  assert_true(ctx ~= nil and ctx.tier ~= "full", "single-file edit is a non-full tier")
  q:update_incremental(vi, ctx)

  -- Alpha no longer matches project; now matches archive.
  assert_nil(rel_set(q:pages_with_tag("project"))["Projects/Alpha.md"],
    "Alpha dropped from #project after partial")
  assert_true(rel_set(q:pages_with_tag("archive"))["Projects/Alpha.md"],
    "Alpha added to #archive after partial")

  -- Beta/Delta unaffected.
  assert_true(rel_set(q:pages_with_tag("project"))["Projects/Sub/Beta.md"],
    "Beta still matches #project (project/active)")
  assert_true(rel_set(q:pages_with_tag("project"))["Other/Delta.md"],
    "Delta still matches #project")

  -- Compare against a fresh full build for every queried tag/folder.
  local full = QI.Index.new(dir)
  full:build_from_vault_index()
  for _, tag in ipairs({ "project", "project/active", "archive", "myproject" }) do
    set_eq(rel_set(q:pages_with_tag(tag)), rel_set(full:pages_with_tag(tag)),
      "partial vs full tag " .. tag)
  end
  for _, folder in ipairs({ "Projects", "Projects/Sub", "ProjectsX", "Other", "" }) do
    set_eq(rel_set(q:pages_in_folder(folder)), rel_set(full:pages_in_folder(folder)),
      "partial vs full folder '" .. folder .. "'")
  end
end)

-- ===========================================================================
-- 5. Discriminating power: a bare-segment registration (the bloom-style bug)
--    makes the parity assertion FAIL — proving the spec catches semantic drift.
-- ===========================================================================
test("a bare-segment registration would break parity (proves discriminating power)", function()
  local dir = make_vault()
  local vi = fresh_vi(dir)
  local q = QI.Index.new(dir)
  q:build_from_vault_index()

  -- Correct index: "active" matches nothing.
  assert_nil(next(rel_set(q:pages_with_tag("active"))),
    "correct index: bare segment 'active' matches nothing")

  -- Inject the WRONG (bloom-style) registration: register each bare slash
  -- segment too. This is exactly the trap the implementation must avoid.
  local function register(index, key, rp)
    local b = index[key]
    if not b then index[key] = { rp } else
      for i = 1, #b do if b[i] == rp then return end end
      b[#b + 1] = rp
    end
  end
  local bad = {}
  for rp, page in pairs(q.pages) do
    for _, t in ipairs(page.file.tags or {}) do
      register(bad, t, rp)
      local s = t:find("/", 1, true)
      while s do
        register(bad, t:sub(1, s - 1), rp)   -- prefix (correct)
        s = t:find("/", s + 1, true)
      end
      for seg in t:gmatch("[^/]+") do register(bad, seg, rp) end  -- bare segment (BUG)
    end
  end
  q._tag_index = bad

  -- With the bug, "active" wrongly matches Alpha + Beta.
  local got = rel_set(q:pages_with_tag("active"))
  assert_true(got["Projects/Alpha.md"] and got["Projects/Sub/Beta.md"],
    "bare-segment bug makes 'active' wrongly match project/active pages")
  -- And it diverges from the linear scan — the parity assertion would fail.
  assert_nil(next(linear_tag(q, "active")), "linear scan still matches nothing — drift detected")
end)

-- ===========================================================================
-- Summary
-- ===========================================================================
_H.finish({ style = "results", exit = "os" })
