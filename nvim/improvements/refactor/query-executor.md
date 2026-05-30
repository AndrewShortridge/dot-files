# query/executor.lua Refactoring Plan

## File Stats
- **File:** `lua/andrew/vault/query/executor.lua`
- **Lines:** 1,300
- **Dead Code:** None
- **Public API:** Single entry point `M.execute(ast, index, current_file_path)`
- **Dependencies:** Only `andrew.vault.query.types`

## Current Structure

| Section | Lines | Purpose |
|---------|-------|---------|
| Module Setup & Imports | 1-3 | types dependency |
| Helper Functions | 5-57 | `shallow_copy()`, `group_key()`, `expr_to_name()` |
| Value Helpers | 59-145 | `compare_eq()`, `add_values()`, `sub_values()`, `contains_value()` — type-aware ops for Link/Date/Duration |
| Expression Evaluator | 147-905 | `eval_function()` (645 lines, 55+ builtins), `eval_expr()` (forward-declared, mutual recursion) |
| Pipeline Stages | 907-1033 | `resolve_source()`, `apply_flatten()`, `apply_where()`, `apply_sort()`, `apply_limit()`, `apply_group_by()` |
| Result Construction | 1035-1234 | TABLE: `build_table_headers/row/results`; LIST: `build_list_results`; TASK: `make_task_context`, `build_task_results` |
| Main Entry Point | 1240-1298 | `M.execute()` — pcall-wrapped pipeline orchestration |

## Duplicated Logic Patterns

### 1. Table Type Guard Clauses (15+ instances)
```lua
if type(list) ~= "table" then return list end
```
Appears across most built-in functions. Extract `ensure_table(val, default)`.

### 2. Numeric Conversion + Accumulation (8 instances)
```lua
for _, v in ipairs(list) do total = total + (tonumber(v) or 0) end
```
Extract `sum_values(list, map_fn)`.

### 3. Date Arithmetic (4 instances)
```lua
local d = os.date("*t")
d.day = d.day - n
local r = os.date("*t", os.time(d))
return types.Date.new(r.year, r.month, r.day)
```
Extract `date_offset(offset_days, offset_months, offset_years)`.

### 4. Grouped Result Building (3 instances)
`build_table_results`, `build_list_results`, `build_task_results` all follow identical group/ungroup structure. Extract `build_generic_results(pages, groups, item_builder)`.

### 5. String/List Type Dispatch (7 instances)
```lua
if type(x) == "string" then ... elseif type(x) == "table" then ... end
```

## Proposed Extraction Plan

### Subsystem A: Built-in Functions -> `executor_builtins.lua` (~645 lines)

**Functions:** All 55+ functions in the `fns` dispatch table inside `eval_function()`:
- List: contains, length, filter, reverse, sort, join, unique, first, last, slice, count, zip
- String: capitalize, startswith, endswith, padleft/right, trim, substring, truncate, replace, regexmatch, regexreplace, extract, lower, upper, split
- Numeric: abs, ceil, floor, round, min, max, sum, average, product, median
- Date/Range: today, now, yesterday, tomorrow, daysago, daysfromnow, weeksago, monthsago, sow, eow, som, eom, isbetween
- Utility: keys, values, object
- Type conversion: link, date, dur, number, string
- Control: default, choice
- Aggregate: all, any, none, nonnull
- Reflection: typeof

**Rationale:** Single largest subsystem (645 lines). Functions are mostly independent of pipeline logic. Enables separate testing and documentation.

**Interface:**
```lua
-- executor_builtins.lua
local M = {}
-- fns table keyed by builtin name, each value is function(args, eval_expr_fn, context)
M.fns = { ... }
return M
```

`eval_function()` in executor.lua becomes a thin dispatcher that looks up the name in the imported `fns` table and calls it, passing `eval_expr` and any needed context as arguments.

### Subsystem B: Value Operations -> `executor_values.lua` (~100 lines)

**Functions:** `compare_eq()`, `add_values()`, `sub_values()`, `contains_value()`

**Rationale:** Pure type-aware utilities with no state dependencies. Could be shared with other modules that need Link/Date/Duration arithmetic.

**Interface:**
```lua
-- executor_values.lua
local M = {}
M.compare_eq = function(a, b) ... end
M.add_values = function(a, b) ... end
M.sub_values = function(a, b) ... end
M.contains_value = function(collection, value) ... end
return M
```

### Subsystem C: Result Formatters -> `executor_results.lua` (~200 lines)

**Functions:** `build_table_headers()`, `build_table_row()`, `build_table_results()`, `build_list_results()`, `make_task_context()`, `build_task_results()`

**Rationale:** Query-type-specific formatting logic that is independent of evaluation and pipeline stages. Grouping all three output formats in one file makes it easy to add new output types.

**Interface:**
```lua
-- executor_results.lua
local M = {}
M.build_table_results = function(pages, groups, ast, eval_expr_fn) ... end
M.build_list_results  = function(pages, groups, ast, eval_expr_fn) ... end
M.build_task_results  = function(pages, groups, ast, eval_expr_fn) ... end
return M
```

### Subsystem D: Pipeline Stages (optional)

**Functions:** `resolve_source()`, `apply_flatten()`, `apply_where()`, `apply_sort()`, `apply_limit()`, `apply_group_by()`

**Rationale:** Already well-organized (~130 lines). Extract only if executor.lua remains too large after A-C. These functions depend on `eval_expr` and value operations, so extracting them requires passing those as parameters or using a shared context object.

## External Callers
- Only `query/init.lua` line 120: `executor.execute(ast, idx, current_file)`
- No other module imports executor directly.

## Implementation Order

1. **Extract builtins** (biggest win: 645 lines out, lowest risk since builtins are self-contained)
2. **Extract values** (pure utilities, zero coupling)
3. **Extract results** (formatting logic, independent of eval)
4. **Dedup within extracted modules** (guard clauses, date arithmetic, numeric accumulation)
5. **Pipeline extraction** (only if executor.lua still exceeds ~400 lines after steps 1-3)

Each step should be a separate commit with tests run between extractions.

## Expected Result

| File | Lines | Contents |
|------|-------|----------|
| `executor.lua` | ~350-400 | `eval_expr()`, `eval_function()` dispatcher, pipeline stages, `M.execute()` orchestrator |
| `executor_builtins.lua` | ~645 | 55+ builtin function implementations |
| `executor_values.lua` | ~100 | Type-aware comparison, arithmetic, containment |
| `executor_results.lua` | ~200 | TABLE/LIST/TASK output formatters |

## Risk Assessment

- **Low risk:** Builtins and values are stateless; extraction is mechanical.
- **Medium risk:** Result formatters reference `eval_expr` for column/template evaluation. The extracted module must accept `eval_expr` as a parameter rather than closing over it.
- **Mutual recursion:** `eval_function` and `eval_expr` call each other. After extraction, builtins receive `eval_expr` as a callback parameter to break the cycle without circular requires.
