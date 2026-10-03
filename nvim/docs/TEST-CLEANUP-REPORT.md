# test_vault_fixes.lua Cleanup Report

## Final Spec Result
**181 passed, 0 failed, 181 total** — all green.

## Confirmation Status
Confirmed across three validation passes:
- v1 passed: ✅
- v2 passed: ✅
- e2 passed: ✅

## Attempts
Completed in **2 attempts**.

## Assertion Accounting
- **UPDATEd:** 0
- **CONVERTed:** 0
- **DELETEd:** 1

### Deletions (with justification)
Deleted the short-name assertion at the old `test_vault_fixes.lua:1427-1429`:

```lua
local short = rg_pipeline._build_rg_pattern({"ab"})
assert_true(short == "", ...)
```

**Justification:** The Phase-6 refactor moved `MIN_NAME_LENGTH` filtering *out* of
`build_rg_pattern`. The refactored `build_rg_pattern` (`rg_pipeline.lua:16-24`) only
escapes, sorts, and word-bounds the names and does **no** length filtering — verified
at runtime: `_build_rg_pattern({"ab"})` returns `\b(ab)\b`, not `""`. The old assertion
would now FAIL against the function.

The behavior was **relocated**, not removed: it now lives in
`utils.filter_by_min_length` (`unlinked/utils.lua:13`, driven by
`config.autolink.min_name_length = 3`) and is invoked upstream in `names.lua:62`.

Coverage was **not lost** — the deleted assertion was replaced with two assertions
against the new home:
- `#utils.filter_by_min_length({"ab","CFD","Mesh Convergence"}) == 2` (drops `"ab"`)
- `vim.tbl_contains(utils.filter_by_min_length({"ab","CFD"}), "CFD")` (keeps ≥3-char names)

## Inlink Failure: Product Bug?
**No functional product fix was needed.** The inlink REALBUG was already resolved by a
prior pass (the test was green on entry).

The only product-code change in this cleanup is a **test-affordance export**, not a
behavior change:
- `lua/andrew/vault/unlinked/rg_pipeline.lua`: added `M._build_rg_pattern = build_rg_pattern`
  (after line 24) to expose the file-local pattern builder so the test can exercise it.
  This mirrors the old backup export at `unlinked.lua:711`. No behavior change.

## Files Changed
- `test_vault_fixes.lua` — deleted the stale short-name assertion; added two
  `filter_by_min_length` assertions in its place.
- `lua/andrew/vault/unlinked/rg_pipeline.lua` — added the `_build_rg_pattern` test-affordance
  export (no behavior change).
