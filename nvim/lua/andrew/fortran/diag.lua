-- =============================================================================
-- Fortran compiler-diagnostic post-processing shared by every lint path
-- =============================================================================
--
-- Lives outside lua/andrew/plugins/linting.lua for the same reason
-- andrew.fortran.unused does: linting.lua is a lazy.nvim plugin spec, and the
-- locals inside its `config` function are unreachable from a spec.

local M = {}

--- True when `msg` is a bare caret-marker label rather than a real message.
---
--- gfortran renders a diagnostic that names two source locations as TWO lines
--- under -fdiagnostics-plain-output: one carrying only the marker label, and
--- one carrying the prose that refers to the markers by number.
---
---     Share-EAM.f90:14:29: Warning: (1)
---     Share-EAM.f90:11:29: Warning: Array reference at (1) out of bounds
---                                   (26 > 18) in loop beginning at (2) [-Wdo-subscript]
---
--- Every parser here matches on `file:line:col: severity: message`, so the
--- first line becomes a diagnostic whose entire message is the string "(1)" --
--- a marker floating in the gutter attached to no statement. Four of them
--- appeared on one file the moment MPI includes started resolving, which is
--- how a wart that predates this change became visible.
---
--- Dropping it loses the secondary location and keeps the prose. The reverse
--- -- merging the two into one diagnostic with related information -- needs
--- pairing logic across lines that the output does not reliably support (the
--- marker line comes FIRST, and nothing in it names the diagnostic it belongs
--- to), and vim.diagnostic renders related information nowhere by default.
---
--- Deliberately anchored and digits-only: a real message never consists of
--- nothing but a parenthesised number, but plenty of real messages CONTAIN
--- one, so an unanchored test would silently discard genuine diagnostics.
---@param msg string|nil
---@return boolean
function M.is_location_marker(msg)
  if type(msg) ~= "string" then
    return false
  end
  return msg:match("^%(%d+%)$") ~= nil
end

return M
