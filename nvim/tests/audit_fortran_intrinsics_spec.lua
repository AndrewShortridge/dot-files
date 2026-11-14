-- Spec for andrew.fortran.intrinsics against the intrinsic DATA this config
-- already ships.
--
-- THE GAP THIS PINS
--   snippets/f90-intrinsics.json lists the 72 canonical F90 intrinsics, every
--   one of which also has a hover entry in snippets/fortran-docs.json. `btest`
--   was in both of those and missing from the NAMES list here -- it sits
--   between `bit_size` and `dshiftl` in the bit-manipulation group -- so the
--   capitalization rule silently skipped `btest(flags, 3)` while uppercasing
--   `ibclr`, `ibits` and `ibset` on the same line.
--
-- Run with: nvim --headless -u NONE -l tests/audit_fortran_intrinsics_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local intrinsics = require("andrew.fortran.intrinsics")

local function read_json(path)
  local f = assert(io.open(path, "r"), "cannot open " .. path)
  local content = f:read("*a")
  f:close()
  return vim.json.decode(content)
end

test("every intrinsic the config documents is in the NAMES list", function()
  local data = read_json(vim.fn.stdpath("config") .. "/snippets/f90-intrinsics.json")
  local missing = {}
  local count = 0
  for name in pairs(data) do
    count = count + 1
    if not intrinsics.is(name) then
      missing[#missing + 1] = name
    end
  end
  assert_true(count > 60, "f90-intrinsics.json shrank unexpectedly (" .. count .. " names):")
  table.sort(missing)
  assert_eq(#missing, 0, "documented but unknown to the case checker: " .. table.concat(missing, ", "))
end)

test("btest is recognised alongside its neighbours", function()
  for _, name in ipairs({ "bit_size", "btest", "ibclr", "ibits", "ibset" }) do
    assert_true(intrinsics.is(name), name .. " is not recognised as an intrinsic:")
    assert_true(intrinsics.is(name:upper()), name:upper() .. " is not recognised as an intrinsic:")
  end
end)

test("statements that look like calls are still excluded", function()
  for _, name in ipairs({ "write", "read", "print", "open", "close", "allocate", "if", "do" }) do
    assert_true(not intrinsics.is(name), name .. " must NOT be treated as an intrinsic:")
  end
end)

_H.finish()
