# Good Snippet Design Guide

## Golden Example: MATMUL from fortls

This guide establishes best practices for creating high-quality Fortran snippets, derived from the fortls language server's intrinsic documentation system.

---

## Architecture Overview

fortls uses a **two-tier documentation system**:

| File | Purpose | Used For |
|------|---------|----------|
| `intrinsic.procedures.json` | Minimal signature data | Completion menu, quick info |
| `intrinsic.procedures.markdown.json` | Full documentation | Hover tooltips, detailed help |

This separation allows:
- Fast completions with lightweight data
- Rich documentation on demand
- Easy maintenance of each layer independently

---

## Tier 1: Minimal Signature (JSON)

### Structure

```json
"MATMUL": {
  "args": "MATRIX_A,MATRIX_B",
  "doc": "MATMUL(MATRIX_A,MATRIX_B) performs a matrix multiplication on numeric or logical arguments.",
  "type": 3
}
```

### Field Specifications

#### `args` (string)
- Comma-separated parameter list
- **Required parameters**: `UPPERCASE` names only
- **Optional parameters**: `NAME=name` format (uppercase label, lowercase placeholder)
- **No spaces** after commas
- **No types** - just parameter names

**Examples:**
```
"args": "MATRIX_A,MATRIX_B"                      # All required
"args": "ARRAY,DIM=dim,MASK=mask"               # Mixed required/optional
"args": "SOURCE,MOLD=mold,SIZE=size"            # One required, rest optional
"args": ""                                       # No arguments (omit field)
```

#### `doc` (string)
- **First**: Full signature with parentheses
- **Then**: Single sentence description
- **Ends**: With period
- **Length**: Ideally under 120 characters

**Pattern:**
```
"doc": "FUNCTION(ARG1,ARG2) brief description of what it does."
```

**Examples:**
```
"doc": "MATMUL(MATRIX_A,MATRIX_B) performs a matrix multiplication on numeric or logical arguments."
"doc": "SUM(ARRAY,DIM=dim,MASK=mask) adds the elements of ARRAY along dimension DIM if the corresponding element in MASK is TRUE."
"doc": "TRANSPOSE(MATRIX) transpose an array of rank two."
```

#### `type` (integer)
| Value | Meaning |
|-------|---------|
| 2 | Subroutine |
| 3 | Function |

---

## Tier 2: Full Documentation (Markdown)

### Required Sections

```markdown
## function_name

### **Name**

**function_name** - \[CATEGORY:SUBCATEGORY\] Brief description

### **Synopsis**
```fortran
    result = function_name(arg1, arg2)
```
```fortran
     function function_name(arg1, arg2)

      type(TYPE1(kind=**)) :: arg1
      type(TYPE2(kind=**)) :: arg2
      type(TYPE_RESULT)    :: function_name
```

### **Characteristics**

 - **arg1** is a [type description and constraints]
 - **arg2** is a [type description and constraints]
 - [Additional constraints, relationships between args]
 - [Result type characteristics]

### **Description**

 **function_name** [detailed description of what the function does,
 including edge cases and important behavior notes].

### **Options**

- **arg1**
  : [Detailed description of this argument, valid values, constraints]

- **arg2**
  : [Detailed description of this argument, valid values, constraints]

### **Result**

  [Detailed description of the return value, including:
   - Shape/size rules
   - Type promotion rules
   - Special cases]

### **Examples**

Sample program:
```fortran
program demo_function_name
implicit none
  ! Variable declarations
  ! Setup code
  ! Function call examples
  ! Output verification
end program demo_function_name
```
Results:
```text
    [Expected output]
```

### **Standard**

Fortran [version: 77/90/95/2003/2008/2018/2023]

### **See Also**

[**related_function**(3)](#related_function),
[**another_function**(3)](#another_function)
```

### Optional Sections

```markdown
### **Resources**

- [Descriptive Link Text](URL)
- Additional references, papers, algorithms

### **Notes**

  [Implementation notes, gotchas, performance considerations]

### **History**

  [Version history, deprecation notices]
```

---

## Section Deep Dive

### Name Section

**Format:**
```markdown
**function_name** - \[CATEGORY:SUBCATEGORY\] Brief phrase description
```

**Categories for Fortran Intrinsics:**
| Category | Subcategory | Example Functions |
|----------|-------------|-------------------|
| ARRAY | TRANSFORMATIONAL | MATMUL, TRANSPOSE, RESHAPE |
| ARRAY | REDUCTION | SUM, PRODUCT, MAXVAL, MINVAL |
| ARRAY | INQUIRY | SIZE, SHAPE, LBOUND, UBOUND |
| ARRAY | CONSTRUCTION | SPREAD, PACK, UNPACK, MERGE |
| NUMERIC | ELEMENTAL | ABS, SIN, COS, SQRT |
| NUMERIC | CONVERSION | INT, REAL, DBLE, CMPLX |
| CHARACTER | ELEMENTAL | TRIM, ADJUSTL, LEN |
| CHARACTER | INQUIRY | LEN_TRIM, INDEX, SCAN |
| TYPE | INQUIRY | KIND, ALLOCATED, ASSOCIATED |
| TYPE | CONVERSION | TRANSFER, C_LOC, C_F_POINTER |
| BIT | ELEMENTAL | IAND, IOR, IEOR, NOT |
| BIT | MANIPULATION | IBSET, IBCLR, ISHFT |
| SYSTEM | SUBROUTINE | SYSTEM_CLOCK, CPU_TIME |
| IO | SUBROUTINE | FLUSH, INQUIRE |

**For Custom Snippets (non-intrinsics):**
| Category | Subcategory | Example Patterns |
|----------|-------------|------------------|
| STRUCTURE | PROGRAM | Program skeleton, module |
| STRUCTURE | PROCEDURE | Function, subroutine |
| STRUCTURE | TYPE | Derived type, abstract type |
| CONTROL | LOOP | Do, do concurrent, do while |
| CONTROL | CONDITIONAL | If, select case, select type |
| PARALLEL | OPENMP | Parallel do, critical, atomic |
| PARALLEL | MPI | Init, send, recv, collective |
| PARALLEL | COARRAY | Sync, image query |
| INTEROP | C_BINDING | C function, C pointer |
| IO | FILE | Open, read, write, close |
| MEMORY | ALLOCATION | Allocate, deallocate |
| ERROR | HANDLING | Assert, error stop |

### Synopsis Section

**Two code blocks required:**

1. **Usage synopsis** - How to call it:
```fortran
    result = function_name(required_arg, optional_arg)
```

2. **Interface synopsis** - Type signature:
```fortran
     function function_name(arg1, arg2) result(res)

      type(TYPE1(kind=**)), intent(in) :: arg1
      type(TYPE2(kind=**)), intent(in) :: arg2
      type(TYPE_RESULT)                :: res
```

**Conventions:**
- Use `**` for kind when multiple kinds are valid
- Use `(..)` for assumed-rank arrays
- Use `(:)`, `(:,:)` for assumed-shape arrays
- Show `intent` for procedure arguments
- Align `::` for readability

### Characteristics Section

**Use bullet points with bold argument names:**

```markdown
 - **arg_name** is a [type] with [constraints].
 - At least one argument must be [constraint].
 - The result [description of result characteristics].
```

**Key information to include:**
- Valid types (integer, real, complex, logical, character)
- Valid ranks (scalar, rank-1, rank-2, assumed-rank)
- Kind requirements
- Relationships between arguments (must be same type, etc.)
- Result type/shape determination rules

### Description Section

**Guidelines:**
- Start with the function name in bold
- Use present tense
- Explain the core operation in 1-3 sentences
- Cover the "what" not the "how"

```markdown
 **matmul** performs a matrix multiplication on numeric or logical
 arguments.
```

### Options Section

**Format each argument:**
```markdown
- **argument_name**
  : Description of the argument. Include valid values, constraints,
  and relationship to other arguments.
```

**Include:**
- What the argument represents
- Valid types and kinds
- Valid ranges or values
- Default value for optional arguments
- Relationship to other arguments

### Result Section

**Structure for complex results:**

```markdown
#### **Numeric Arguments**

  [Description for numeric case]

##### **Shape and Rank**

  [Rules for determining output shape]

##### **Values**

  [How values are computed]

#### **Logical Arguments**

  [Description for logical case, if different]
```

### Examples Section

**Requirements for good examples:**

1. **Complete** - Must compile and run standalone
2. **Demonstrates** - Shows primary use case
3. **Varied** - Shows different argument combinations
4. **Documented** - Comments explain what's happening
5. **Verified** - Includes expected output

**Template:**
```fortran
program demo_function_name
implicit none
  ! Declarations
  type :: var1
  type :: var2
  type :: result

  ! Setup
  var1 = ...
  var2 = ...

  ! Primary use case
  result = function_name(var1, var2)
  print *, 'Result:', result

  ! Alternative use case
  result = function_name(var1, optional_arg=value)
  print *, 'With optional:', result

end program demo_function_name
```

---

## Quality Checklist

### Tier 1 (JSON) Checklist

- [ ] `args` uses UPPERCASE for required params
- [ ] `args` uses `NAME=name` for optional params
- [ ] `args` has no spaces after commas
- [ ] `doc` starts with full signature
- [ ] `doc` is a single complete sentence
- [ ] `doc` ends with period
- [ ] `doc` is under 120 characters
- [ ] `type` is 2 (subroutine) or 3 (function)

### Tier 2 (Markdown) Checklist

- [ ] Has all required sections (Name, Synopsis, Characteristics, Description, Options, Result, Examples, Standard, See Also)
- [ ] Name includes category tag `\[CATEGORY:SUBCATEGORY\]`
- [ ] Synopsis has both usage and interface code blocks
- [ ] Characteristics covers all type/rank constraints
- [ ] Description is concise and accurate
- [ ] Options documents every argument
- [ ] Result explains shape/type determination
- [ ] Example compiles and runs standalone
- [ ] Example includes expected output
- [ ] Standard specifies Fortran version
- [ ] See Also links related functions

---

## VSCode Snippet Adaptation

When creating VSCode/LuaSnip snippets from this format:

### Mapping

| fortls Field | VSCode Field | Notes |
|--------------|--------------|-------|
| Key (e.g., "MATMUL") | `prefix` array | Add lowercase variant |
| `args` | `body` | Convert to tabstops |
| `doc` (first sentence) | `description` | Keep concise |
| Full markdown | N/A | Reference in comments |

### Conversion Rules

**Args to Body:**
```
"args": "MATRIX_A,MATRIX_B"
→ "body": "matmul(${1:matrix_a}, ${2:matrix_b})"

"args": "ARRAY,DIM=dim,MASK=mask"
→ "body": "sum(${1:array}${2:, dim=${3:1}}${4:, mask=${5:condition}})"
```

**Optional parameter pattern:**
```
${N:, KEYWORD=${M:default}}
```

### Example Conversion

**From fortls:**
```json
"MATMUL": {
  "args": "MATRIX_A,MATRIX_B",
  "doc": "MATMUL(MATRIX_A,MATRIX_B) performs a matrix multiplication on numeric or logical arguments.",
  "type": 3
}
```

**To VSCode:**
```json
"Matrix Multiplication": {
  "prefix": ["matmul", "MATMUL"],
  "body": "matmul(${1:matrix_a}, ${2:matrix_b})",
  "description": "MATMUL(MATRIX_A,MATRIX_B) performs a matrix multiplication on numeric or logical arguments."
}
```

---

## Anti-Patterns to Avoid

### In Args

```
BAD:  "args": "matrix_a, matrix_b"     # Lowercase, spaces
GOOD: "args": "MATRIX_A,MATRIX_B"

BAD:  "args": "ARRAY, DIM, MASK"       # Optional shown as required
GOOD: "args": "ARRAY,DIM=dim,MASK=mask"

BAD:  "args": "integer :: N"           # Types don't belong here
GOOD: "args": "N"
```

### In Doc

```
BAD:  "doc": "Matrix multiplication"           # No signature
GOOD: "doc": "MATMUL(A,B) performs matrix multiplication."

BAD:  "doc": "MATMUL(A,B) - matrix mult"       # Incomplete sentence
GOOD: "doc": "MATMUL(A,B) performs matrix multiplication."

BAD:  "doc": "This function performs..."       # Don't start with "This"
GOOD: "doc": "MATMUL(A,B) performs..."
```

### In Examples

```
BAD:  Incomplete program that won't compile
GOOD: Full program with implicit none, declarations, and output

BAD:  No expected output shown
GOOD: Results block with actual output

BAD:  Only shows one use case
GOOD: Shows primary + edge cases + variations
```

---

## File Organization

```
snippets/
├── package.json                    # VSCode snippet manifest
├── fortran.json                    # Original snippets (VSCode format)
├── new-snippets.json               # Additional snippets (VSCode format)
├── FORTRAN_SNIPPET_SPEC.md         # What to create
├── GOOD_SNIPPET_GUIDE.md           # How to create (this file)
└── intrinsics/                     # Optional: fortls-style files
    ├── procedures.json             # Tier 1: minimal signatures
    └── procedures.markdown.json    # Tier 2: full documentation
```

---

## References

- [fortls intrinsic.procedures.json](https://github.com/fortran-lang/fortls/blob/master/fortls/parsers/internal/intrinsic.procedures.json)
- [fortls intrinsic.procedures.markdown.json](https://github.com/fortran-lang/fortls/blob/master/fortls/parsers/internal/intrinsic.procedures.markdown.json)
- [VSCode Snippet Syntax](https://code.visualstudio.com/docs/editor/userdefinedsnippets)
- [fortran90.org Best Practices](https://www.fortran90.org/src/best-practices.html)
