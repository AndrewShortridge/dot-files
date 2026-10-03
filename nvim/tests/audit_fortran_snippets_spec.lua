-- Spec for the VS Code style Fortran snippets under snippets/ (loaded through
-- snippets/package.json by luasnip.loaders.from_vscode in
-- lua/andrew/plugins/blink-cmp.lua).
--
-- WHAT THIS PINS
--   * Both contributed files parse as JSON and every entry has a prefix and a
--     body. A single unparseable file makes LuaSnip load ZERO Fortran snippets.
--   * No prefix is defined twice, within a file or across the two. LuaSnip
--     keeps both, so a duplicate silently shadows one of the bodies.
--   * No body contains a BARE `$name` variable reference. This is the `!$omp`
--     bug: `$omp` is VS Code snippet syntax for a variable, and LuaSnip expanded
--     every OpenMP snippet to `!omp parallel do` -- a plain comment, not a
--     directive. The seven OpenMP bodies must write `\$omp`.
--   * `!$omp end critical` must not mirror the tabstop that carries the
--     `hint(...)` clause: `hint` is legal on `critical` and illegal on
--     `end critical`, and the mirror reproduced it.
--
-- Run with: nvim --headless -u NONE -l tests/audit_fortran_snippets_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

local SNIPPET_DIR = vim.fn.stdpath("config") .. "/snippets"

local function read_json(path)
  local f = assert(io.open(path, "r"), "cannot open " .. path)
  local content = f:read("*a")
  f:close()
  local ok, decoded = pcall(vim.json.decode, content)
  assert_true(ok, "JSON parse failed for " .. path .. ": " .. tostring(decoded))
  return decoded
end

--- The files package.json contributes, in order.
local function contributed_files()
  local manifest = read_json(SNIPPET_DIR .. "/package.json")
  local out = {}
  for _, entry in ipairs(manifest.contributes.snippets) do
    out[#out + 1] = { language = entry.language, path = SNIPPET_DIR .. "/" .. entry.path:gsub("^%./", "") }
  end
  return out
end

local function body_text(body)
  if type(body) == "table" then
    return table.concat(body, "\n")
  end
  return body
end

test("package.json contributes both Fortran snippet files", function()
  local files = contributed_files()
  assert_eq(#files, 2)
  for _, f in ipairs(files) do
    assert_eq(f.language, "fortran")
    assert_eq(vim.fn.filereadable(f.path), 1, f.path .. " is not readable:")
  end
end)

test("every snippet has a prefix and a body", function()
  for _, f in ipairs(contributed_files()) do
    for name, snip in pairs(read_json(f.path)) do
      assert_true(type(snip) == "table", name .. " is not an object:")
      assert_true(type(snip.prefix) == "string" or type(snip.prefix) == "table",
        name .. " has no usable prefix:")
      assert_true(type(snip.body) == "string" or type(snip.body) == "table",
        name .. " has no usable body:")
    end
  end
end)

test("no prefix is defined twice", function()
  local seen = {}
  for _, f in ipairs(contributed_files()) do
    local base = vim.fn.fnamemodify(f.path, ":t")
    for name, snip in pairs(read_json(f.path)) do
      local prefixes = type(snip.prefix) == "string" and { snip.prefix } or snip.prefix
      for _, p in ipairs(prefixes) do
        assert_true(seen[p] == nil,
          ("prefix %q is defined by both %s and %s/%s:"):format(p, tostring(seen[p]), base, name))
        seen[p] = base .. "/" .. name
      end
    end
  end
end)

test("no body contains a bare $name variable reference", function()
  for _, f in ipairs(contributed_files()) do
    local base = vim.fn.fnamemodify(f.path, ":t")
    for name, snip in pairs(read_json(f.path)) do
      local text = body_text(snip.body)
      -- A `$` that is neither escaped (`\$`) nor a tabstop (`$1`, `${1:x}`) is
      -- read by LuaSnip as a variable and expands to something else entirely.
      local prev_end = 0
      while true do
        local s, e, word = text:find("%$([A-Za-z_][%w_]*)", prev_end + 1)
        if not s then
          break
        end
        prev_end = e
        assert_true(text:sub(s - 1, s - 1) == "\\",
          ("%s/%s body has an unescaped $%s -- write \\$%s:"):format(base, name, word, word))
      end
    end
  end
end)

test("every OpenMP body writes an escaped sentinel", function()
  local snips = read_json(SNIPPET_DIR .. "/new-snippets.json")
  local names = {
    "OpenMP Atomic", "OpenMP Barrier", "OpenMP Critical Section",
    "OpenMP Parallel Do", "OpenMP Parallel Do Simd",
    "OpenMP Parallel Region", "OpenMP Reduction",
  }
  for _, name in ipairs(names) do
    local snip = snips[name]
    assert_true(snip ~= nil, name .. " is missing:")
    local text = body_text(snip.body)
    assert_true(text:find("!\\$omp", 1, true) ~= nil,
      name .. " does not write the directive sentinel as !\\$omp:")
    assert_true(text:find("!%$omp") == nil or text:find("!\\%$omp") ~= nil,
      name .. " still has a bare !$omp:")
  end
end)

test("end critical does not mirror the hint tabstop", function()
  local snips = read_json(SNIPPET_DIR .. "/new-snippets.json")
  local text = body_text(snips["OpenMP Critical Section"].body)
  local open_line, end_line
  for line in text:gmatch("[^\n]+") do
    if line:find("end critical", 1, true) then
      end_line = line
    elseif line:find("critical", 1, true) then
      open_line = line
    end
  end
  assert_true(open_line ~= nil and end_line ~= nil, "critical body lost a line:")
  -- The opening line's tabstop 1 carries the optional `, hint(...)` clause;
  -- `hint` is not permitted on `end critical`, so the end line must not repeat
  -- that tabstop.
  assert_true(open_line:find("${1:", 1, true) ~= nil, "open line no longer owns tabstop 1:")
  assert_true(end_line:find("${1:", 1, true) == nil,
    "end critical mirrors tabstop 1 and so reproduces the hint clause:")
end)

test("snippet prefix and definition counts are stable", function()
  local defs, prefixes = 0, 0
  for _, f in ipairs(contributed_files()) do
    for _, snip in pairs(read_json(f.path)) do
      defs = defs + 1
      prefixes = prefixes + (type(snip.prefix) == "string" and 1 or #snip.prefix)
    end
  end
  -- 48 + 115 definitions, 97 + 384 prefixes. LuaSnip creates one snippet per
  -- PREFIX, so `require("luasnip").get_snippets("fortran")` must report
  -- `prefixes`, not `defs`.
  assert_eq(defs, 163)
  assert_eq(prefixes, 481)
end)

_H.finish()
