-- Spec for fixed-form detection in andrew.fortran.scan / andrew.fortran.case.
--
-- THE BUG THIS PINS
--   Both modules asked `vim.bo.filetype == "fortran_fixed"`. Neovim's own
--   ftdetect never sets that: every Fortran file gets filetype `fortran` and
--   the SOURCE FORM is recorded in `b:fortran_fixed_source`. So a `.f` file
--   opened normally was masked as FREE form, a `C` in column 1 stopped being a
--   comment, and the capitalization rule planted a diagnostic on the word
--   `size` inside English prose -- then `:FortranCaseFix workspace` rewrote it
--   on disk, because the workspace passes never set `opts.fixed` at all.
--
-- Run with: nvim --headless -u NONE -l tests/audit_fortran_fixed_form_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false = _H.test, _H.assert_eq, _H.assert_true, _H.assert_false

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local scan = require("andrew.fortran.scan")
local case = require("andrew.fortran.case")

-- A fixed-form source whose column-1 comment mentions an intrinsic. Free-form
-- masking leaves that comment as code; fixed-form masking blanks the line.
local FIXED_LINES = {
  "C     This comment uses size(x) in prose",
  "      SUBROUTINE OLDSUB(N, X)",
  "      INTEGER N",
  "      REAL X(N)",
  "      RETURN",
  "      END",
}

--- A loaded buffer holding FIXED_LINES under `name`, with the source form set
--- the way the runtime ftplugin sets it.
local function fixed_buf(name, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, FIXED_LINES)
  if name then
    vim.api.nvim_buf_set_name(buf, name)
  end
  vim.bo[buf].filetype = opts.filetype or "fortran"
  if opts.fixed_source ~= nil then
    vim.b[buf].fortran_fixed_source = opts.fixed_source
  end
  return buf
end

test("is_fixed honours b:fortran_fixed_source", function()
  local buf = fixed_buf("/tmp/audit_fortran/legacy.f90", { fixed_source = 1 })
  assert_true(scan.is_fixed(buf), "b:fortran_fixed_source=1 must mean fixed form:")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("is_fixed honours a free-form b:fortran_fixed_source", function()
  local buf = fixed_buf("/tmp/audit_fortran/free.f", { fixed_source = 0 })
  assert_false(scan.is_fixed(buf), "b:fortran_fixed_source=0 must mean free form:")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("is_fixed falls back to the extension", function()
  for _, ext in ipairs({ "f", "for", "ftn", "fpp", "f77" }) do
    local buf = fixed_buf("/tmp/audit_fortran/legacy." .. ext)
    assert_true(scan.is_fixed(buf), "." .. ext .. " must be fixed form:")
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  local free = fixed_buf("/tmp/audit_fortran/modern.f90")
  assert_false(scan.is_fixed(free), ".f90 must be free form:")
  vim.api.nvim_buf_delete(free, { force = true })
end)

test("the filetype still wins when it is explicit", function()
  local buf = fixed_buf("/tmp/audit_fortran/modern.f90", { filetype = "fortran_fixed" })
  assert_true(scan.is_fixed(buf), "filetype fortran_fixed must mean fixed form:")
  vim.api.nvim_buf_delete(buf, { force = true })

  local free = fixed_buf("/tmp/audit_fortran/legacy.f", { filetype = "fortran_free" })
  assert_false(scan.is_fixed(free), "filetype fortran_free must mean free form:")
  vim.api.nvim_buf_delete(free, { force = true })
end)

test("scan_buffer masks a column-1 comment in a .f buffer", function()
  local buf = fixed_buf("/tmp/audit_fortran/legacy.f", { fixed_source = 1 })
  local res = scan.scan_buffer(buf)
  assert_eq(res.masked[1], string.rep(" ", #FIXED_LINES[1]),
    "the column-1 comment must be blanked:")
  for _, ref in ipairs(res.refs) do
    assert_true(ref.lnum ~= 1, "a reference was taken from inside the comment:")
  end
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("the capitalization check ignores a column-1 comment", function()
  -- Only the intrinsic rule, so the test is about masking and not about which
  -- keyword classes are enabled.
  local saved = {
    keywords = vim.g.fortran_case_keywords,
    defined = vim.g.fortran_case_defined,
    units = vim.g.fortran_case_units,
  }
  vim.g.fortran_case_keywords = false
  vim.g.fortran_case_defined = false
  vim.g.fortran_case_units = false

  local buf = fixed_buf("/tmp/audit_fortran/legacy.f", { fixed_source = 1 })
  local count
  case.check(buf, function(n)
    count = n
  end)
  vim.wait(8000, function()
    return count ~= nil
  end)
  assert_eq(count, 0, "'size' inside a fixed-form comment was reported:")

  case.clear()
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.g.fortran_case_keywords = saved.keywords
  vim.g.fortran_case_defined = saved.defined
  vim.g.fortran_case_units = saved.units
end)

_H.finish()
