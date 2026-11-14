# fortran-extras diagnostic rules

The in-process Fortran language server (`lua/andrew/fortran/lsp.lua`) publishes two
diagnostics of its own. Both report mistakes that **no compiler on this machine
reports** — that is the entire rule for admitting one. Anything gfortran can already
see arrives through `andrew.fortran.diag` and the linter, and a second opinion on it
would be noise.

Each diagnostic carries `source = "fortran-extras"`, the bare rule name in `code`, and a
`codeDescription.href` pointing at the matching section below. Virtual text shows the
rule name in brackets; `<leader>cH` opens the href.

---

## ompDirectiveWithoutFlag

Severity **Warning**, tagged `Unnecessary` (the line is greyed out, because as built it
really is dead code).

**What fires it.** An OpenMP sentinel — `!$OMP …`, or the conditional-compilation `!$ …`
— in a buffer whose project does not appear to be compiled with `-fopenmp`. Fixed-form
sentinels in column 1 (`C$OMP`, `*$OMP`, `!$OMP`) count too. One diagnostic per sentinel
line; the range covers the sentinel and the directive word after it.

**What never fires it.**

* **Another vendor's sentinel.** OpenMP 5.2 §3.2.2 requires a space, a tab or the end of
  the line after the conditional `!$`, and whitespace after `!$omp`. A `$` glued to a
  word is somebody else's: `!$acc parallel loop` is OpenACC, `!$dir` is a compiler
  directive, `!$x = 1` is neither. None of them has anything to do with `-fopenmp`, and
  none of them is reported.
* **`!$ use omp_lib`** (also `!$ use omp_lib_kinds`, `!$ use :: omp_lib`,
  `!$ use omp_lib, only: …`). That line is the *idiom*, not the mistake: the `!$` is
  exactly what keeps the file compilable both ways, and it is what the quickfix below
  inserts. Reporting it would mean the fix creates a fresh instance of the warning it
  just fixed. Any other conditional statement (`!$ nthreads = omp_get_max_threads()`)
  still reports.

**Why it matters.** Without `-fopenmp`, gfortran treats `!$OMP` as an ordinary comment.
Nothing is reported, the file compiles, the tests pass, and the loop runs
single-threaded — forever, silently. A malformed clause is equally invisible. This is
the worst failure mode available, and it is unreachable by any compiler diagnostic,
because to a compiler without the flag there is nothing there but a comment.

**How it decides.** In order:

1. `vim.g.fortran_openmp`, when it is set.
2. Otherwise the build files at the project root — `Makefile`, `GNUmakefile`,
   `makefile`, `makefile.in`, `CMakeLists.txt`, `fpm.toml`, `*.mk` — searched for the
   substring `openmp` (which catches `-fopenmp`, `-qopenmp`, `FOPENMP=`,
   `find_package(OpenMP)` and `OpenMP_Fortran_FLAGS` alike). The answer is cached per
   project root and re-read when one of those files is written.
3. Otherwise **not** built with it. The asymmetry is deliberate: the hazardous state is
   the default one, and a tree whose build system this cannot read is exactly where a
   directive is most likely to be quietly ignored.

**How to fix it.** Add `-fopenmp` to the compile flags. Note that it implies
`-frecursive`, which suppresses the `-Wsurprising` "moved from stack to static storage"
warnings — the right outcome, since that hazard only exists under threading. Under
`-fsyntax-only` no OpenMP runtime is linked, so the linter sets the flag unconditionally
(see `lua/andrew/plugins/linting.lua`).

**How to silence it.** Put this in your config or a project-local `.nvim.lua`:

```lua
vim.g.fortran_openmp = true
```

Setting it to `false` forces the warning on regardless of what the build files say.

**Quickfix.** When the buffer has a sentinel and no `use omp_lib`, the code-action menu
offers **Add `!$ use omp_lib`**, inserted after the header and any existing `use` lines
and before `implicit none`. The `!$` prefix is what keeps the statement legal in a build
without the flag: it is a comment until OpenMP is enabled.

---

## mpiArgumentCount

Severity **Error**.

**What fires it.** A `call MPI_xxx(…)` whose argument count disagrees with the `mpi`
binding's interface for that routine — for example

```fortran
call MPI_Comm_rank(MPI_COMM_WORLD, rank)
```

> MPI_Comm_rank expects 3 arguments in the `mpi` binding, 2 given — `ierror` is mandatory

The range covers the callee name. `data.missing` lists the mandatory trailing dummies
that were not supplied. The `codeDescription.href` is the routine's own Open MPI man
page, not this file.

**Why it matters.** In the F77 / `mpif.h` binding there is no explicit interface, so
nothing checks the count: the call is a legal reference to an external symbol. MPI then
writes its status through a dummy that was never passed, and the program corrupts a
stack slot or dies somewhere unrelated. This config sets
`-fallow-argument-mismatch` deliberately (the typeless MPI choice buffers need it), which
demotes even gfortran's accidental cross-call check to a warning. Omitting `ierror` is
the single most common Fortran MPI bug.

**Where the counts come from.** `lua/andrew/fortran/data/mpi.lua`, generated from the
installed `mpi.mod` — the compiler's own symbol table for the `mpi` module, not from
prose. In that binding `ierror` is a **mandatory** final dummy on every routine. The
`mpi_f08` binding makes it OPTIONAL and spells the handles as derived types; each
registry entry records that in its `binding_note`.

**Which binding you are judged by.** The buffer's own, not the project's — one tree
routinely holds `use mpi_f08` and `include 'mpif.h'` files side by side. A `use mpi_f08`
line anywhere in the buffer (in any case, with or without `::`, with or without a
trailing `, only: …`) makes the trailing `ierror` **optional**, so

```fortran
use mpi_f08
call MPI_Comm_rank(MPI_COMM_WORLD, rank)   ! correct — no diagnostic
```

is silent, while the same call under `use mpi`, `include 'mpif.h'` or no binding at all
is an Error. The message always names the binding it judged by — *expects 3 arguments in
the `mpi` binding* versus *expects 2 or 3 arguments in the `mpi_f08` binding* — so the
report says which standard section applies. A buffer carrying both modules is read
permissively as `mpi_f08`. Neither the **Add the missing `ierror` argument** nor the
**Add `include 'mpif.h'`** quickfix is offered in an `mpi_f08` buffer.

**What never fires it.**

* Functions. `t = MPI_Wtime()` takes no arguments and a count rule cannot tell a
  function reference from an array section.
* A call the parser could not follow to its closing paren (truncated, unbalanced, or
  past the continuation budget) — a half-typed line is not an error.
* A routine the **project itself** defines. If your tree has its own `MPI_SEND` wrapper,
  the wrapper's real dummy list is what the call must match, and the standard binding
  says nothing about it. The project signature index (shared with the inlay hints)
  makes that call.
* OpenMP runtime routines. `omp_lib` has explicit interfaces, so gfortran already checks
  them.

**How to fix it.** Pass the missing arguments. When the only thing missing is `ierror`,
the code-action menu offers **Add the missing `ierror` argument**, which inserts
`, <name>` before the call's closing paren — following continuation lines to find it —
using whatever the buffer already calls its status variable (`ierr`, `IERR`, `mpi_err`;
`ierr` when there is no example to copy).

**How to silence it.** There is no flag for this one; the fix is the fix. If the call is
genuinely to something other than the MPI routine of that name, define or declare it in
the project and the rule stands down.

---

## Related

* **Add `include 'mpif.h'`** — offered whenever the buffer references an `MPI_*` name and
  has neither `include 'mpif.h'` nor `use mpi` / `use mpi_f08` in scope. Not a diagnostic
  (gfortran reports the resulting implicit-typing errors well enough); a quickfix only.
* Inlay hints label the actual arguments of MPI and OpenMP calls with the dummy names
  from the same registry, and annotate a builtin function call with its result type. See
  `vim.g.fortran_inlay_hints` below.

---

## Settings

All three are plain global variables: set them in your config, or per project in a
`.nvim.lua`. None of them is read at startup — each is consulted on the request it
affects, so a change takes effect on the next hover, save or `:edit`.

### `vim.g.fortran_openmp`

`true` — the project *is* built with `-fopenmp`; silences `ompDirectiveWithoutFlag`
entirely. `false` — force the warning on regardless of what the build files say. Unset
(the default) — decide from the build files at the project root, as described above.

### `vim.g.fortran_inlay_hints`

Two independent families, both **on** by default:

| value | argument names | return types |
|---|---|---|
| unset (default) | on | on |
| `{}` | on | on |
| `{ argument_names = false }` | off | on |
| `{ return_types = false }` | on | off |
| `false` | off | off |

The table is a set of **overrides**, not an exhaustive statement: a field you leave out
keeps its default. To turn everything off, set the variable itself to `false` — which
leaves the `inlayHint` capability advertised, so `<leader>uh` keeps toggling.

### `vim.g.fortran_signature_display`

`"formatted"` (the default) or `"compact"`. It selects how a parameter list is laid out
in hover and signature help (`lua/andrew/fortran/render.lua`). `formatted` breaks the
list one dummy per line, indented four spaces, and only when there is **more than one**
dummy — so a 0- or 1-argument routine stays on a single line either way. `compact` joins
them with `, ` on one line, which is what a narrow signature-help window wants. Any value
other than the exact string `"compact"` is read as `"formatted"`.

---

## Regenerating the registry

`lua/andrew/fortran/data/mpi.lua` and `lua/andrew/fortran/data/openmp.lua` are
**generated and committed**. Nothing at runtime parses a `.mod` file. From the repository
root:

```sh
nvim --headless -u NONE -l snippets/gen-mpi.lua
nvim --headless -u NONE -l snippets/gen-omp.lua
```

Each accepts `--out <dir>` to write somewhere other than the repository (which is how the
spec below regenerates without touching the tree).

**Sources.**

* `gen-mpi.lua` reads `~/miniconda3/include/mpi.mod` — gfortran's own symbol table for
  the F90 `mpi` module — for every dummy name, order, intent and kind, plus
  `mpi_f08_interfaces.mod` for the `binding_note` alone and `mpif*.h` for the constants.
* `gen-omp.lua` reads `$(gfortran -print-file-name=finclude)/omp_lib.f90`, the runtime's
  whole interface as ordinary Fortran.

**Overrides.** Everything a compiler cannot know — what a routine is *for*, examples,
`href`s, and the directives and clauses, which are syntax rather than a library — lives
in `snippets/overrides/mpi.lua` and `snippets/overrides/openmp.lua` and is merged in. An
override that contradicts the machine data (a dummy name or order the `.mod` disagrees
with) is a fatal error in the generator rather than a silent win, so the two cannot drift.

**Staleness is a test failure.** `tests/fortran_registry_fresh_spec.lua` re-runs both
generators into a temp directory and compares the output **byte for byte** with the
committed files. Edit an override, or upgrade the MPI or gfortran install, and that spec
fails until you regenerate and commit. It skips itself (counted as a pass) on a machine
with no Open MPI or no gfortran.
