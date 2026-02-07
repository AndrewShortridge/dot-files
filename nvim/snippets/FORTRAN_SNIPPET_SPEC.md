# Fortran Snippet Generation Specification

## Overview

This specification defines requirements for systematically extracting code patterns from the [fortran90.org](https://www.fortran90.org/) documentation to generate comprehensive VSCode-compatible snippets for Neovim/LuaSnip.

---

## Source Documentation Structure

| Section | URL | Content Type |
|---------|-----|--------------|
| Best Practices | `/src/best-practices.html` | Idiomatic patterns, style guide |
| Rosetta Stone | `/src/rosetta.html` | Side-by-side Python/Fortran examples |
| FAQ | `/src/faq.html` | Common patterns, compiler flags |
| Gotchas | `/src/gotchas.html` | Anti-patterns and corrections |

---

## Snippet Categories to Extract

### 1. Precision and Type Declarations

**Source:** Best Practices > Floating Point Numbers

| Pattern | Description | Priority |
|---------|-------------|----------|
| Kind parameter definition | `integer, parameter :: dp = kind(0.d0)` | HIGH |
| Double precision real | `real(dp) :: var` | HIGH |
| Double precision literal | `1.0_dp` suffix usage | HIGH |
| Complex with precision | `complex(dp) :: z` | MEDIUM |
| Integer kinds | `int32`, `int64` from `iso_fortran_env` | MEDIUM |

**Extraction Criteria:**
- Include the `_dp` suffix in all real literal snippets
- Show correct vs incorrect literal assignment (gotcha #2)

---

### 2. Module Patterns

**Source:** Best Practices > Modules

| Pattern | Description | Priority |
|---------|-------------|----------|
| Module with explicit visibility | `private` default + `public ::` exports | HIGH |
| Module with precision parameter | Include `dp` kind definition | HIGH |
| Module procedure interface | Generic interface blocks | MEDIUM |
| Submodule pattern | Separate implementation from interface | LOW |

**Extraction Criteria:**
- Always include `implicit none`
- Show `private` as default with explicit `public` exports
- Include `contains` section structure

---

### 3. Array Patterns

**Source:** Best Practices > Arrays, Rosetta Stone

| Pattern | Description | Priority |
|---------|-------------|----------|
| Assumed-shape argument | `real(dp), intent(in) :: arr(:)` | HIGH |
| Assumed-shape 2D | `real(dp), intent(in) :: mat(:,:)` | HIGH |
| Allocatable declaration | `real(dp), allocatable :: arr(:)` | HIGH |
| Array constructor | `[(expr, i = start, end)]` | HIGH |
| Reshape with order | `reshape(arr, [m,n], order=[2,1])` | MEDIUM |
| Custom index bounds | `real(dp) :: arr(0:n-1)` | MEDIUM |
| Contiguous attribute | `real(dp), contiguous :: arr(:)` | LOW |

**Extraction Criteria:**
- Prefer assumed-shape over explicit-shape
- Include dimension specification variants
- Show column-major access patterns for performance

---

### 4. Procedure Patterns

**Source:** Best Practices > Elemental, Callbacks

| Pattern | Description | Priority |
|---------|-------------|----------|
| Elemental function | `elemental function` with scalar ops | HIGH |
| Elemental subroutine | `elemental subroutine` pattern | MEDIUM |
| Pure function | `pure function` without side effects | HIGH |
| Procedure argument | `procedure(interface)` callback | MEDIUM |
| Abstract interface | For procedure pointer types | MEDIUM |
| Module procedure | Internal procedure pattern | HIGH |

**Extraction Criteria:**
- Show `result()` clause usage
- Include intent declarations for all arguments
- Demonstrate return value patterns

---

### 5. Control Flow Patterns

**Source:** Rosetta Stone

| Pattern | Description | Priority |
|---------|-------------|----------|
| Named do loop | `loop_name: do i = 1, n` | HIGH |
| Do concurrent | `do concurrent (i = 1:n)` | HIGH |
| Where/elsewhere | Array conditional assignment | HIGH |
| Exit named loop | `exit loop_name` | MEDIUM |
| Cycle named loop | `cycle loop_name` | MEDIUM |
| Implied do | `[(expr, i = 1, n)]` | HIGH |

**Extraction Criteria:**
- Show named loop for nested exit/cycle
- Include locality clauses for `do concurrent`

---

### 6. I/O Patterns

**Source:** Best Practices > File I/O

| Pattern | Description | Priority |
|---------|-------------|----------|
| Open with newunit | `open(newunit=u, file=...)` | HIGH |
| Open with error handling | Include `iostat` and check | HIGH |
| Read with format | Formatted read patterns | MEDIUM |
| Write with format | Formatted write patterns | MEDIUM |
| Namelist I/O | `namelist` declaration and I/O | LOW |
| Stream I/O | `access='stream'` binary I/O | MEDIUM |

**Extraction Criteria:**
- Always use `newunit=` instead of hardcoded unit numbers
- Include `iostat` error checking
- Show `status=`, `action=` options

---

### 7. Interoperability Patterns

**Source:** Best Practices > Interoperability with C

| Pattern | Description | Priority |
|---------|-------------|----------|
| C function binding | `bind(c, name="func")` | HIGH |
| C type imports | `use, intrinsic :: iso_c_binding` | HIGH |
| C pointer handling | `type(c_ptr)`, `c_f_pointer` | MEDIUM |
| C string conversion | `c_char` array handling | MEDIUM |
| C struct equivalent | Interoperable derived type | MEDIUM |

**Extraction Criteria:**
- Show complete `iso_c_binding` import lists
- Include `value` attribute for pass-by-value
- Demonstrate pointer conversion patterns

---

### 8. Parallel Computing Patterns

**Source:** Best Practices > OpenMP, MPI

| Pattern | Description | Priority |
|---------|-------------|----------|
| OpenMP parallel do | `!$omp parallel do` | HIGH |
| OpenMP reduction | Reduction clause patterns | MEDIUM |
| OpenMP critical | Critical section | MEDIUM |
| MPI module import | `use mpi_f08` (modern) | HIGH |
| MPI init/finalize | Setup and teardown | HIGH |
| MPI send/recv | Point-to-point communication | MEDIUM |

**Extraction Criteria:**
- Use `!$omp` comment syntax for compatibility
- Prefer `mpi_f08` over legacy `include 'mpif.h'`

---

### 9. Error Handling Patterns

**Source:** Gotchas, Best Practices

| Pattern | Description | Priority |
|---------|-------------|----------|
| Allocate with stat | `allocate(..., stat=ierr)` | HIGH |
| Error stop | `error stop 'message'` | HIGH |
| IO error handling | `iostat` checking pattern | HIGH |
| Assert pattern | Runtime assertion macro | MEDIUM |

**Extraction Criteria:**
- Always check allocation status
- Use `error stop` over `stop` for errors
- Include descriptive error messages

---

### 10. Gotcha-Avoiding Patterns

**Source:** Gotchas

| Pattern | Description | Priority |
|---------|-------------|----------|
| Correct initialization | Avoid implicit `save` | HIGH |
| Precision literals | Always use `_dp` suffix | HIGH |
| C logical interop | Compiler flag comments | LOW |

**Anti-patterns to document in snippet descriptions:**
- `integer :: x = 5` adds implicit `save`
- `1.0` without suffix is single precision
- Integer literals `360_dp` remain integers

---

## Snippet Format Requirements

### Naming Convention

```
{category}_{pattern}_{variant}
```

Examples:
- `array_allocatable_1d`
- `module_with_precision`
- `proc_elemental_function`

### Trigger Design

| Type | Example Triggers |
|------|------------------|
| Full keyword | `subroutine`, `SUBROUTINE` |
| Abbreviated | `sub`, `SUB` |
| Descriptive | `elemental`, `allocarray` |

### Required Metadata

```json
{
  "name": "Descriptive Name",
  "prefix": ["trigger1", "TRIGGER1", "abbrev"],
  "body": ["..."],
  "description": "What it does. NOTE: gotcha warning if applicable."
}
```

---

## Extraction Process

### Phase 1: Pattern Identification

1. Parse each documentation section
2. Extract all code blocks
3. Classify by category (above)
4. Identify placeholder positions

### Phase 2: Template Creation

1. Convert literals to tabstop placeholders: `${1:default}`
2. Link related placeholders: `${1:name}` ... `end ${1:name}`
3. Add choice placeholders where applicable: `${1|in,out,inout|}`
4. Set final cursor position: `$0`

### Phase 3: Validation

1. Verify syntax correctness with `gfortran -fsyntax-only`
2. Test expansion in Neovim
3. Verify tabstop navigation order
4. Check placeholder defaults are sensible

---

## Output Format

Generate `fortran.json` compatible with VSCode snippet format:

```json
{
  "Snippet Name": {
    "prefix": ["trigger", "TRIGGER"],
    "body": [
      "line 1",
      "\tindented line",
      "${1:placeholder}",
      "$0"
    ],
    "description": "Description with gotcha warnings"
  }
}
```

---

## Priority Matrix

| Priority | Criteria |
|----------|----------|
| HIGH | Used in >50% of Fortran programs, prevents common errors |
| MEDIUM | Used regularly, improves productivity |
| LOW | Specialized use cases, advanced features |

---

## Acceptance Criteria

1. All HIGH priority patterns have snippets
2. Each snippet includes both lowercase and UPPERCASE triggers
3. Gotcha-prone patterns include warning in description
4. All snippets produce syntactically valid Fortran
5. Placeholders follow logical editing order
6. Related identifiers are linked (module name, function name, etc.)

---

## References

- [Fortran Best Practices](https://www.fortran90.org/src/best-practices.html)
- [Python Fortran Rosetta Stone](https://www.fortran90.org/src/rosetta.html)
- [Fortran FAQ](https://www.fortran90.org/src/faq.html)
- [Fortran Gotchas](https://www.fortran90.org/src/gotchas.html)
- [Modern Fortran Extension](https://github.com/fortran-lang/vscode-fortran-support)
