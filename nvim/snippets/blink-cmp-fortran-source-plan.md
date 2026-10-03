# Superseded: the custom blink.cmp Fortran source

This file used to plan a bespoke blink.cmp source (`fortran_docs`) that read
`snippets/fortran-docs.json` and served every documented Fortran/MPI/OpenMP
name as a completion item. That source shipped as
`lua/andrew/fortran/blink-source.lua`.

**Both were removed on 2026-09-13.** Fortran completion is now served by the
in-process `fortran-extras` LSP server, so blink sees it through the ordinary
`lsp` provider alongside `fortls` -- no extra provider, one registry, one
renderer, and `completionItem/resolve` keeps the documentation bodies off the
wire until an item is actually selected (the old source shipped all 388
markdown bodies on every keystroke).

What replaced it:

* `lua/andrew/fortran/lsp_completion.lua` -- the completion handler, including
  the context rules the blink source never had (directives after the `!$OMP`
  sentinel, that directive's clauses after it, the registry elsewhere).
* `doc/fortran-extras.md` -- what the server answers and why.
