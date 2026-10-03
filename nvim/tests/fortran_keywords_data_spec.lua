-- Spec for the two hand-authored documentation data files:
--
--   lua/andrew/fortran/data/keywords.lua   -- the Fortran language keywords
--   snippets/overrides/openmp.lua          -- the OpenMP 5.2 directives, clauses,
--                                             module and runtime-routine prose
--
-- WHY THIS SPEC EXISTS
--
-- Both files are DATA, not code: nothing type-checks them, and a malformed
-- entry does not fail until a user presses K on the one word that reaches it.
-- Three classes of defect have already been observed in the legacy
-- snippets/fortran-docs.json and must not come back:
--
--   1. Keys that can never be reached. The lookup folds the cursor word to
--      lowercase and indexes the table, so a key holding a space or a "!" --
--      "omp barrier", "!$omp atomic" -- is dead weight that no K press can
--      ever produce (omp-audit/data-lookup.md section 2, six dead keys).
--      Hence: every key is an identifier AND equals name:lower() with blanks
--      folded to underscores, which also pins the multi-word directives
--      ("PARALLEL DO" -> parallel_do).
--   2. OpenMP prose leaking onto plain Fortran words. docs.get("reduction")
--      and docs.get("critical") returned [PARALLEL:OPENMP] bodies, so hovering
--      a variable named "reduction", or an F2008 critical block, showed OpenMP
--      documentation (same report, findings 6). Hence: those two keys must NOT
--      exist in keywords.lua at all; they live in the OpenMP overrides only.
--   3. Renderer-hostile markup. basedpyright emits "&nbsp;" for indentation and
--      backslash-escapes "*" and "_"; both render LITERALLY in Neovim floats
--      and in blink's documentation window (bp-study/live-wire.md sections 3-4).
--      Our prose is authored as markdown and escapes nothing.
--
-- The last test is the one that keeps the file mergeable: keywords.lua has no
-- generator, so the only defence against a hand edit that reflows the whole
-- table is that the file IS the output of a fixed serializer -- sorted keys at
-- every level, two-space indent, "\n" escapes, no trailing whitespace. The
-- serializer is written here rather than imported so that the spec fails when
-- the file drifts, not when a shared helper changes underneath it.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "keys are reachable identifiers" fails on a key with a space or a
--     leading "!", and on a key that disagrees with its own name field.
--   * "every entry carries kind, summary and description" fails if an entry is
--     added with prose missing -- which renders as an empty hover body.
--   * "clauses declare valid_on / directives declare clauses" fails if a
--     clause is added without the list the "**Valid on**" line is built from.
--   * "every keyword states a standard" fails if standard is dropped: 26 of
--     136 legacy entries had one, and that gap is the reason this file exists.
--   * "reduction and critical are OpenMP-only" fails the moment either word is
--     given a plain-Fortran entry again.
--   * "the overrides carry the anchor entries" fails if private, parallel, do
--     or omp_lib is renamed or dropped -- they are what gen-omp.lua merges and
--     what the directive-line hover path resolves.
--   * "no renderer-hostile markup" fails on a single "&nbsp;" or "\*".
--   * "keywords.lua is byte-idempotent under the canonical serializer" fails on
--     any hand edit that changes key order, indent, or string escaping.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_keywords_data_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true
local assert_nil = _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local CONFIG = vim.fn.stdpath("config")
local KEYWORDS_PATH = CONFIG .. "/lua/andrew/fortran/data/keywords.lua"
local OVERRIDES_PATH = CONFIG .. "/snippets/overrides/openmp.lua"

local KINDS = {
  subroutine = true,
  ["function"] = true,
  constant = true,
  directive = true,
  clause = true,
  module = true,
  keyword = true,
  type = true,
}

-- Canonical serializer ------------------------------------------------------
-- Sorted keys at every level, two-space indent, %q-style strings with literal
-- "\n", Lua keywords bracketed (do/end/if/... are legal entry names but not
-- legal bare table keys), no trailing whitespace.

local RESERVED = {
  ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
  ["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true, ["goto"] = true,
  ["if"] = true, ["in"] = true, ["local"] = true, ["nil"] = true, ["not"] = true,
  ["or"] = true, ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
  ["until"] = true, ["while"] = true,
}

---@param s string
---@return string
local function quote(s)
  return (string.format("%q", s):gsub("\\\n", "\\n"))
end

---@param k string
---@return string
local function key_str(k)
  if k:match("^[%a_][%w_]*$") and not RESERVED[k] then
    return k
  end
  return "[" .. quote(k) .. "]"
end

---@param t table
---@return boolean
local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then
      return false
    end
    n = n + 1
  end
  return n == #t
end

---@param v any
---@param ind integer
---@return string
local function ser(v, ind)
  local ty = type(v)
  if ty == "string" then
    return quote(v)
  elseif ty == "number" or ty == "boolean" then
    return tostring(v)
  elseif ty == "table" then
    local pad = string.rep(" ", ind + 2)
    local out = {}
    if is_array(v) then
      if #v == 0 then
        return "{}"
      end
      for i = 1, #v do
        out[#out + 1] = pad .. ser(v[i], ind + 2) .. ","
      end
    else
      local keys = {}
      for k in pairs(v) do
        keys[#keys + 1] = k
      end
      table.sort(keys)
      if #keys == 0 then
        return "{}"
      end
      for _, k in ipairs(keys) do
        out[#out + 1] = pad .. key_str(k) .. " = " .. ser(v[k], ind + 2) .. ","
      end
    end
    return "{\n" .. table.concat(out, "\n") .. "\n" .. string.rep(" ", ind) .. "}"
  end
  error("unserializable value of type " .. ty)
end

---@param tbl table
---@return string
local function serialize(tbl)
  return "return " .. ser(tbl, 0) .. "\n"
end

-- Loading -------------------------------------------------------------------

---@param path string
---@return table
local function load_data(path)
  local chunk, err = loadfile(path)
  assert_true(chunk ~= nil, "loadfile(" .. path .. ") failed: " .. tostring(err))
  local ok, tbl = pcall(chunk)
  assert_true(ok and type(tbl) == "table", "chunk did not return a table: " .. path)
  return tbl
end

---@param path string
---@return string
local function read_file(path)
  local fh = assert(io.open(path, "rb"))
  local raw = fh:read("*a")
  fh:close()
  return raw
end

--- Every entry, _meta excluded, as {key, entry} pairs sorted by key.
---@param tbl table
---@return table[]
local function entries(tbl)
  local out = {}
  for k, v in pairs(tbl) do
    if k ~= "_meta" then
      out[#out + 1] = { k, v }
    end
  end
  table.sort(out, function(a, b)
    return a[1] < b[1]
  end)
  return out
end

--- Walk every string in a table, depth first, calling fn(path, string).
---@param v any
---@param path string
---@param fn fun(path: string, s: string)
local function walk_strings(v, path, fn)
  if type(v) == "string" then
    fn(path, v)
  elseif type(v) == "table" then
    for k, sub in pairs(v) do
      walk_strings(sub, path .. "." .. tostring(k), fn)
    end
  end
end

local keywords = load_data(KEYWORDS_PATH)
local overrides = load_data(OVERRIDES_PATH)

-- Tests ---------------------------------------------------------------------

test("both files load and are non-trivial", function()
  assert_true(#entries(keywords) >= 80, "keywords.lua should cover the declaration/structural set")
  assert_true(#entries(overrides) >= 100, "overrides should cover directives, clauses and routines")
  assert_true(type(keywords._meta) == "table", "keywords.lua carries _meta")
  assert_eq(keywords._meta.generator, "hand-authored", "keywords.lua has no generator:")
end)

test("keys are reachable identifiers that agree with their name", function()
  for _, file in ipairs({ { "keywords", keywords }, { "overrides", overrides } }) do
    for _, pair in ipairs(entries(file[2])) do
      local key, entry = pair[1], pair[2]
      assert_true(
        key:match("^[%a_][%w_]*$") ~= nil,
        file[1] .. " key is not an identifier: " .. key
      )
      assert_true(type(entry.name) == "string", file[1] .. "." .. key .. " has no name")
      local folded = entry.name:lower():gsub(" ", "_")
      assert_eq(key, folded, file[1] .. " key disagrees with name (" .. entry.name .. "):")
    end
  end
end)

test("every entry carries a known kind, a summary and a description", function()
  for _, file in ipairs({ { "keywords", keywords }, { "overrides", overrides } }) do
    for _, pair in ipairs(entries(file[2])) do
      local key, entry = pair[1], pair[2]
      local where = file[1] .. "." .. key
      assert_true(KINDS[entry.kind] == true, where .. " has an unknown kind: " .. tostring(entry.kind))
      assert_true(
        type(entry.summary) == "string" and #entry.summary > 0,
        where .. " has no summary"
      )
      assert_true(
        type(entry.description) == "string" and #entry.description > 0,
        where .. " has no description"
      )
    end
  end
end)

test("clauses declare valid_on and directives declare clauses plus a signature", function()
  local nclause, ndirective = 0, 0
  for _, pair in ipairs(entries(overrides)) do
    local key, entry = pair[1], pair[2]
    if entry.kind == "clause" then
      nclause = nclause + 1
      assert_true(type(entry.valid_on) == "table", key .. " is a clause with no valid_on")
      assert_true(#entry.valid_on > 0, key .. " has an empty valid_on")
      assert_true(type(entry.signature) == "string", key .. " is a clause with no signature")
    elseif entry.kind == "directive" then
      ndirective = ndirective + 1
      assert_true(type(entry.clauses) == "table", key .. " is a directive with no clauses list")
      assert_true(type(entry.signature) == "string", key .. " is a directive with no signature")
      assert_true(
        entry.signature:match("^!%$OMP ") ~= nil,
        key .. " signature is not a !$OMP directive line: " .. entry.signature
      )
    end
  end
  assert_true(nclause >= 45, "the clause set is incomplete: " .. nclause)
  assert_true(ndirective >= 40, "the directive set is incomplete: " .. ndirective)
end)

test("every keyword states the standard that introduced it", function()
  for _, pair in ipairs(entries(keywords)) do
    local key, entry = pair[1], pair[2]
    assert_true(
      type(entry.standard) == "string" and #entry.standard > 0,
      "keywords." .. key .. " has no standard"
    )
    assert_true(
      entry.standard:match("^F%d+") ~= nil,
      "keywords." .. key .. " standard is not a Fortran revision: " .. entry.standard
    )
    assert_eq(entry.module, "Fortran", "keywords." .. key .. " provenance:")
  end
end)

test("reduction and critical are OpenMP-only, never plain Fortran words", function()
  assert_nil(keywords.reduction, "keywords.lua must not define 'reduction'")
  assert_nil(keywords.critical, "keywords.lua must not define 'critical'")
  assert_true(overrides.reduction ~= nil, "the REDUCTION clause lives in the overrides")
  assert_eq(overrides.reduction.kind, "clause", "REDUCTION is a clause:")
  assert_true(overrides.critical ~= nil, "the CRITICAL directive lives in the overrides")
  assert_eq(overrides.critical.kind, "directive", "CRITICAL is a directive:")
end)

test("the overrides carry the anchor entries the merge and the hover path need", function()
  assert_true(overrides.private ~= nil, "PRIVATE clause missing")
  assert_eq(overrides.private.kind, "clause", "private is a clause:")
  assert_true(overrides.parallel ~= nil, "PARALLEL directive missing")
  assert_eq(overrides.parallel.kind, "directive", "parallel is a directive:")
  assert_true(overrides["do"] ~= nil, "DO directive missing")
  assert_eq(overrides["do"].kind, "directive", "do is a directive:")
  assert_true(overrides.omp_lib ~= nil, "omp_lib module entry missing")
  assert_eq(overrides.omp_lib.kind, "module", "omp_lib is a module:")
  assert_eq(overrides.omp_lib.signature, "use omp_lib", "omp_lib signature:")
  -- The sentinel fact the module hover exists to surface.
  assert_true(
    overrides.omp_lib.description:find("-fopenmp", 1, true) ~= nil,
    "omp_lib must explain the -fopenmp sentinel"
  )
end)

test("runtime routines carry a standard but no hand-written interface", function()
  local n = 0
  for _, pair in ipairs(entries(overrides)) do
    local key, entry = pair[1], pair[2]
    if key:match("^omp_") and key ~= "omp_lib" and key ~= "omp_lib_kinds" then
      n = n + 1
      assert_true(
        type(entry.standard) == "string" and entry.standard:match("^OpenMP "),
        key .. " has no OpenMP standard"
      )
      -- omp_lib.f90 is the machine truth for these two fields; an override
      -- that carried them would silently outrank the generator.
      assert_nil(entry.interface, key .. " must not hand-author an interface")
      assert_nil(entry.signature, key .. " must not hand-author a signature")
      if entry.kind == "function" then
        assert_true(type(entry.result) == "string", key .. " is a function with no result prose")
      end
    end
  end
  assert_true(n >= 30, "the runtime routine set is incomplete: " .. n)
end)

test("no renderer-hostile markup in either file", function()
  for _, file in ipairs({ { "keywords", keywords }, { "overrides", overrides } }) do
    walk_strings(file[2], file[1], function(path, s)
      assert_true(s:find("&nbsp;", 1, true) == nil, path .. " contains &nbsp;")
      assert_true(s:find("\\*", 1, true) == nil, path .. " contains an escaped \\*")
      assert_true(s:find("\\_", 1, true) == nil, path .. " contains an escaped \\_")
      assert_true(s:find("\r", 1, true) == nil, path .. " contains a carriage return")
      assert_true(s:find("\t", 1, true) == nil, path .. " contains a tab")
    end)
  end
end)

test("keywords.lua is byte-idempotent under the canonical serializer", function()
  local on_disk = read_file(KEYWORDS_PATH)
  local round_trip = serialize(keywords)
  assert_eq(#round_trip, #on_disk, "serialized length differs from the file:")
  assert_true(round_trip == on_disk, "keywords.lua is not the canonical serialization of its own table")
  -- and the canonical form has no trailing whitespace on any line
  for line in on_disk:gmatch("[^\n]*") do
    assert_true(line:match("%s$") == nil, "trailing whitespace: " .. line)
  end
end)

_H.finish()
