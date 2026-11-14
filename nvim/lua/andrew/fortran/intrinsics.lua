-- =============================================================================
-- Fortran intrinsic procedure names
-- =============================================================================
-- Standard intrinsic procedures through F2018, plus the widely-implemented
-- GNU/legacy extensions that appear in real code. Used by
-- `andrew.fortran.case` to decide which names the capitalization rule covers.
--
-- Deliberately NOT included: statements and control constructs that look like
-- calls (write, read, print, open, close, allocate, deallocate, if, do,
-- select, where, forall, inquire, ...). They are keywords, not procedures, and
-- listing them here would make the case checker rewrite control flow.
--
-- Also deliberately NOT included: `precision` and `procedure`, which only ever
-- occur as parts of `double precision` / `module procedure`.
--
-- All names are stored lowercase; lookup lowercases its argument.

---@type string[]
local NAMES = {
  -- Numeric
  "abs", "aimag", "aint", "anint", "ceiling", "cmplx", "conjg", "dble", "dim",
  "dprod", "floor", "int", "max", "min", "mod", "modulo", "nint", "real", "sign",
  -- Mathematical
  "acos", "acosh", "asin", "asinh", "atan", "atan2", "atanh", "bessel_j0",
  "bessel_j1", "bessel_jn", "bessel_y0", "bessel_y1", "bessel_yn", "cos", "cosh",
  "erf", "erfc", "erfc_scaled", "exp", "gamma", "hypot", "log", "log10",
  "log_gamma", "norm2", "sin", "sinh", "sqrt", "tan", "tanh",
  -- Character
  "achar", "adjustl", "adjustr", "char", "iachar", "ichar", "index", "len",
  "len_trim", "lge", "lgt", "lle", "llt", "new_line", "repeat", "scan", "trim",
  "verify",
  -- Kind / numeric model
  "digits", "epsilon", "huge", "maxexponent", "minexponent", "precision",
  "radix", "range", "selected_char_kind", "selected_int_kind",
  "selected_real_kind", "tiny", "kind", "storage_size",
  -- Floating point manipulation
  "exponent", "fraction", "nearest", "rrspacing", "scale", "set_exponent",
  "spacing",
  -- Bit manipulation
  "bge", "bgt", "ble", "blt", "bit_size", "btest", "dshiftl", "dshiftr", "iall",
  "iand", "iany", "ibclr", "ibits", "ibset", "ieor", "ior", "iparity", "ishft",
  "ishftc", "leadz", "maskl", "maskr", "merge_bits", "not", "popcnt", "poppar",
  "shifta", "shiftl", "shiftr", "trailz",
  -- Array inquiry / construction / reduction
  "all", "allocated", "any", "count", "cshift", "dot_product", "eoshift",
  "findloc", "is_contiguous", "lbound", "matmul", "maxloc", "maxval", "merge",
  "minloc", "minval", "pack", "parity", "product", "reshape", "shape", "size",
  "spread", "sum", "transpose", "ubound", "unpack",
  -- Pointer / argument inquiry
  "associated", "extends_type_of", "null", "present", "same_type_as",
  -- Transformational / type conversion
  "logical", "transfer",
  -- Coarray
  "atomic_add", "atomic_and", "atomic_cas", "atomic_define", "atomic_fetch_add",
  "atomic_fetch_and", "atomic_fetch_or", "atomic_fetch_xor", "atomic_or",
  "atomic_ref", "atomic_xor", "co_broadcast", "co_max", "co_min", "co_reduce",
  "co_sum", "event_query", "image_index", "lcobound", "num_images",
  "this_image", "ucobound", "failed_images", "stopped_images", "image_status",
  "get_team", "team_number", "coshape",
  -- System / environment (subroutines and functions)
  "command_argument_count", "cpu_time", "date_and_time", "execute_command_line",
  "get_command", "get_command_argument", "get_environment_variable",
  "move_alloc", "mvbits", "random_init", "random_number", "random_seed",
  "system_clock",
  -- ISO_C_BINDING
  "c_associated", "c_f_pointer", "c_f_procpointer", "c_funloc", "c_loc",
  "c_sizeof",
  -- IEEE_ARITHMETIC / IEEE_EXCEPTIONS (the commonly used ones)
  "ieee_class", "ieee_copy_sign", "ieee_is_finite", "ieee_is_nan",
  "ieee_is_negative", "ieee_is_normal", "ieee_logb", "ieee_next_after",
  "ieee_rem", "ieee_rint", "ieee_scalb", "ieee_selected_real_kind",
  "ieee_support_datatype", "ieee_unordered", "ieee_value",
  -- GNU / legacy extensions seen in production Fortran
  "abort", "access", "besj0", "besj1", "besjn", "besy0", "besy1", "besyn",
  "cdabs", "dabs", "dacos", "dasin", "datan", "datan2", "dcos", "dcosh",
  "ddim", "dexp", "dint", "dlog", "dlog10", "dmax1", "dmin1", "dmod", "dnint",
  "dsign", "dsin", "dsinh", "dsqrt", "dtan", "dtanh", "etime", "flush", "fdate",
  "getcwd", "getpid", "hostnm", "iargc", "idint", "idnint", "ifix", "isatty",
  "isnan", "loc", "rand", "second", "sizeof", "sleep", "srand", "time", "amax1",
  "amin1", "amod", "cabs", "ccos", "cexp", "clog", "csin", "csqrt", "float",
  "sngl",
}

local M = {}

---@type table<string, true>
M.set = {}
for _, name in ipairs(NAMES) do
  M.set[name] = true
end

M.names = NAMES

--- Type-specification intrinsics: names that are BOTH intrinsic functions and
--- type keywords. `real(8) :: x` is a declaration, `y = real(i)` is a call, and
--- they are textually identical up to context -- so occurrences of these are
--- suppressed in declaration position (see case.lua:is_type_spec_context).
---@type table<string, true>
M.type_spec = {
  real = true, integer = true, complex = true, logical = true,
  character = true, double = true, type = true, class = true, kind = true,
  len = true, int = true, char = true, cmplx = true, dble = true,
}

--- True when `name` (any case) is a Fortran intrinsic procedure.
---@param name string
---@return boolean
function M.is(name)
  return M.set[name:lower()] == true
end

return M
