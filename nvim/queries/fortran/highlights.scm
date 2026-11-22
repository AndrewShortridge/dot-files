;; extends

; Additions to nvim-treesitter's Fortran highlights, so that the colour
; schemes' two rules -- every keyword italic, every procedure name bold --
; reach all of a Fortran file and not only the tokens upstream happens to
; capture. `;; extends` on purpose: this file adds to upstream's query (unlike
; context.scm next to it, which replaces a broken one). A node name the
; installed grammar does not have makes the WHOLE highlights query fail to
; compile, which is no Fortran highlighting at all;
; tests/fortran_highlights_query_spec.lua compiles it against the real parser.
;
; Two captures here are this config's own. Both fall back to
; `@function.builtin` in a colour scheme that does not define them:
;   @function.builtin.statement  keywords upstream colours as builtins
;                                (`write`, `allocate`): keywords, so italic
;   @function.builtin.intrinsic  intrinsic procedures (`sin`, `size`):
;                                procedures, so bold
; They exist because upstream's own `@function.builtin` list cannot be styled:
; it holds those keywords and also `character`, the type.

; Keywords upstream leaves without any capture.
[
  "assign"
  "assignment"
  "blockdata"
  "case"
  "change"
  "codimension"
  "critical"
  "end"
  "endblock"
  "endcritical"
  "endteam"
  "entry"
  "event"
  "fail"
  "form"
  "image"
  "images"
  "lock"
  "memory"
  "notify"
  "operator"
  "pause"
  "post"
  "sync"
  "team"
  "to"
  "unlock"
  "wait"
] @keyword

"only" @keyword.import

(coarray_statement
  "all" @keyword)

; `a .cross. b`: a word operator like `.and.`.
(user_defined_operator) @keyword.operator

; Statements written like calls, and `bind(c)`. Upstream has the first seven
; as `@function.builtin` and does not capture the rest.
[
  "bind"
  "close"
  "format"
  "open"
  "print"
  "read"
  "write"
  "allocate"
  "backspace"
  "endfile"
  "inquire"
  "rewind"
] @function.builtin.statement

; These three the grammar parses as a call of an ordinary name.
((call_expression
  .
  (identifier) @function.builtin.statement)
  (#match? @function.builtin.statement "\\c\\v^(deallocate|flush|nullify)$"))

; Intrinsic procedures, in call position: `sin(x)`, `call random_number(x)`.
; Fortran writes a call and an array element the same way, so an array NAMED
; like an intrinsic (`count(i)`) is painted as one; the capitalization rule
; (andrew.fortran.case) reads `NAME(` the same way. The list is
; andrew.fortran.intrinsics' `names`, sorted, without `flush` (the statement
; above; `call flush(6)` stays an ordinary call) -- the spec fails when the
; two differ. `\c`: Fortran is case-insensitive and the house style is
; capitals. The second branch is `-SIN(x)`: the grammar reads a signed call
; as a call of `-SIN`.
([
  (call_expression
    .
    (identifier) @function.builtin.intrinsic)
  (call_expression
    .
    (unary_expression
      argument: (identifier) @function.builtin.intrinsic))
  (subroutine_call
    subroutine: (identifier) @function.builtin.intrinsic)
]
  (#match? @function.builtin.intrinsic "\\c\\v^(abort|abs|access|achar|acos|acosh|adjustl|adjustr|aimag|aint|all|allocated|amax1|amin1|amod|anint|any|asin|asinh|associated|atan|atan2|atanh|atomic_add|atomic_and|atomic_cas|atomic_define|atomic_fetch_add|atomic_fetch_and|atomic_fetch_or|atomic_fetch_xor|atomic_or|atomic_ref|atomic_xor|besj0|besj1|besjn|bessel_j0|bessel_j1|bessel_jn|bessel_y0|bessel_y1|bessel_yn|besy0|besy1|besyn|bge|bgt|bit_size|ble|blt|btest|c_associated|c_f_pointer|c_f_procpointer|c_funloc|c_loc|c_sizeof|cabs|ccos|cdabs|ceiling|cexp|char|clog|cmplx|co_broadcast|co_max|co_min|co_reduce|co_sum|command_argument_count|conjg|cos|cosh|coshape|count|cpu_time|cshift|csin|csqrt|dabs|dacos|dasin|datan|datan2|date_and_time|dble|dcos|dcosh|ddim|dexp|digits|dim|dint|dlog|dlog10|dmax1|dmin1|dmod|dnint|dot_product|dprod|dshiftl|dshiftr|dsign|dsin|dsinh|dsqrt|dtan|dtanh|eoshift|epsilon|erf|erfc|erfc_scaled|etime|event_query|execute_command_line|exp|exponent|extends_type_of|failed_images|fdate|findloc|float|floor|fraction|gamma|get_command|get_command_argument|get_environment_variable|get_team|getcwd|getpid|hostnm|huge|hypot|iachar|iall|iand|iany|iargc|ibclr|ibits|ibset|ichar|idint|idnint|ieee_class|ieee_copy_sign|ieee_is_finite|ieee_is_nan|ieee_is_negative|ieee_is_normal|ieee_logb|ieee_next_after|ieee_rem|ieee_rint|ieee_scalb|ieee_selected_real_kind|ieee_support_datatype|ieee_unordered|ieee_value|ieor|ifix|image_index|image_status|index|int|ior|iparity|is_contiguous|isatty|ishft|ishftc|isnan|kind|lbound|lcobound|leadz|len|len_trim|lge|lgt|lle|llt|loc|log|log10|log_gamma|logical|maskl|maskr|matmul|max|maxexponent|maxloc|maxval|merge|merge_bits|min|minexponent|minloc|minval|mod|modulo|move_alloc|mvbits|nearest|new_line|nint|norm2|not|null|num_images|pack|parity|popcnt|poppar|precision|present|product|radix|rand|random_init|random_number|random_seed|range|real|repeat|reshape|rrspacing|same_type_as|scale|scan|second|selected_char_kind|selected_int_kind|selected_real_kind|set_exponent|shape|shifta|shiftl|shiftr|sign|sin|sinh|size|sizeof|sleep|sngl|spacing|spread|sqrt|srand|stopped_images|storage_size|sum|system_clock|tan|tanh|team_number|this_image|time|tiny|trailz|transfer|transpose|trim|ubound|ucobound|unpack|verify)$"))

; MPI and OpenMP runtime FUNCTIONS used in an expression (`MPI_Wtime()`,
; `omp_get_wtime()`). After `call` upstream already has them as
; `@function.call`. andrew.fortran.highlight puts their library colour on top
; of this; the bold comes from here.
([
  (call_expression
    .
    (identifier) @function.call)
  (call_expression
    .
    (unary_expression
      argument: (identifier) @function.call))
]
  (#match? @function.call "\\c\\v^p?(mpi|omp)_"))

; Type-bound procedures: where a type declares them, and where one is called.
(method_name) @function.method

(binding
  (binding_name
    (identifier) @function.method))

(subroutine_call
  subroutine: (derived_type_member_expression
    (type_member) @function.method.call))

; Names upstream leaves uncaptured, coloured as the other languages' queries
; colour theirs.
;
; A construct name is a `@label`, as a loop label is in Rust (`'outer: loop`),
; Go, C and JavaScript: where it is given (`outer: do`), on the statements that
; close or continue the construct (`end do outer`, `else outer`), and after
; `cycle` / `exit`. `"label"` is the grammar's token for the name before the
; colon. `stop code` is a keyword_statement too, hence the two keywords.
(block_label_start_expression
  "label" @label)

(block_label) @label

(keyword_statement
  [
    "cycle"
    "exit"
  ]
  (identifier) @label)

; The module a `use` names is a `@module`, as after Python's `import` and
; Rust's `use`; upstream already has the name in `module x` / `end module x`.
(use_statement
  (module_name) @module)
