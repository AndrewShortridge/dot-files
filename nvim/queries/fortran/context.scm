; Context query for Fortran (nvim-treesitter-context).
;
; This REPLACES the query bundled with nvim-treesitter-context
; (lazy/nvim-treesitter-context/queries/fortran/context.scm), which is written
; against an older tree-sitter-fortran grammar and fails to compile against the
; one nvim-treesitter installs here:
;
;   Unable to load context query for fortran:
;   query.lua:374: Query error at 11:2. Invalid node type "do_loop"
;
; A query that fails to compile is dropped WHOLE, so the error meant Fortran had
; no sticky context at all, not merely no context on do-loops.
;
; Two node names went stale; every other pattern below is unchanged from
; upstream and was verified against the installed parser:
;   do_loop     -> do_loop_statement
;   do_statement -> gone; loop_control_expression is now a direct child
;
; Precedence note: vim.treesitter.query.get_files treats the FIRST file found on
; the runtimepath that carries no ";; extends" modeline as the base query and
; discards later bases. ~/.config/nvim precedes the lazy plugin dirs, so this
; file must NOT say "extends" -- that would append to the broken upstream query
; instead of replacing it, and the compile error would come straight back.
;
; If nvim-treesitter-context ever ships a fixed query, delete this file and
; re-check with :checkhealth or by opening a .f90.

(program
  (program_statement
    (_))
  (_) @context.end) @context

(derived_type_definition
  (derived_type_statement
    (_))
  (_) @context.end) @context

(do_loop_statement
  (loop_control_expression
    (_))
  (_) @context.end) @context

(subroutine
  (subroutine_statement
    (_))
  (_) @context.end) @context

(if_statement
  (parenthesized_expression
    (_))
  (_) @context.end) @context

(elseif_clause
  (parenthesized_expression
    (_))
  (_) @context.end) @context

(else_clause
  (_) @context.end) @context
