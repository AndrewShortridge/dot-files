# Test-Coverage Expansion Report

Target: `/home/andrew-cmmg/.config/nvim`

This report covers an 8-issue test-coverage expansion. Each issue produced a new
spec file authored against the real product modules. All 8 issues are
**CONFIRMED** (each spec green; cross-validated v1/v2/e2e).

## Summary Table

| Issue | Spec File | Status | Attempts | Assertions | Product Change | Bug Found |
|-------|-----------|--------|----------|-----------:|----------------|-----------|
| js2lua | `tests/js2lua_spec.lua` | CONFIRMED | 1 | 59 | none | none |
| search | `tests/search_query_spec.lua` | CONFIRMED | 1 | 622 | none | none (1 pre-existing quirk noted, not pinned) |
| graph | `tests/graph_traversal_spec.lua` | CONFIRMED | 1 | 99 | none | none |
| tasks | `tests/task_logic_spec.lua` | CONFIRMED | 1 | 90 | none | none |
| links | `tests/link_maintenance_spec.lua` | CONFIRMED | 1 | 89 | 1 test-affordance export | 1 (pinned, reported not fixed) |
| ui | `tests/ui_helpers_spec.lua` | CONFIRMED | 1 | 222 | none | none |
| templates | `tests/templates_spec.lua` | CONFIRMED | 1 | 126 | 2 bug fixes | 2 (fixed) |
| weak-upgrade | `tests/behavioral_upgrades_spec.lua` | CONFIRMED | 1 | 260 | none | none |

New spec assertions total: **1567** across **8** new specs.

---

## Per-Issue Detail

### js2lua — `tests/js2lua_spec.lua`
- **Status:** CONFIRMED (1 attempt). Spec result: 59 passed, 0 failed.
- **Assertions:** 59.
- **Product bug discovered:** none. Every expected value from the investigation
  plan matched actual module behavior, verified empirically against the real
  modules before authoring the spec.
- **Product-code change:** none. No test affordances or fixes were needed; all
  targets were already public module functions.

### search — `tests/search_query_spec.lua`
- **Status:** CONFIRMED (1 attempt). Spec result: 119 passed, 0 failed.
- **Assertions:** 622.
- **Product bug discovered:** none blocking. The plan flagged a pre-existing
  quirk in `filter_utils.normalize_link_name`: a leading-fragment-only input
  like `"#Heading"` returns `"#heading"` instead of `nil` (the pattern
  `"^([^#^]+)"` fails to match, so the raw string falls through unstripped).
  This edge case was **deliberately not asserted** to avoid locking in
  suspected-buggy behavior; impact is limited because callers (e.g.
  `match_field` links-to/linked-from) independently guard empty note names via
  `link_utils.parse_target`.
- **Product-code change:** none.

### graph — `tests/graph_traversal_spec.lua`
- **Status:** CONFIRMED (1 attempt). Spec result: 24 passed, 0 failed.
- **Assertions:** 99.
- **Product bug discovered:** none. All expected values matched on first run,
  including BFS `max_nodes` truncation semantics, graph-id keying, BFS layer
  cache hit/miss counters, and the exact connections scoring breakdown
  (link=5.0 / colink=2.5 / temporal=1.0).
- **Product-code change:** none.

### tasks — `tests/task_logic_spec.lua`
- **Status:** CONFIRMED (1 attempt). Spec result: 90 passed, 0 failed.
- **Assertions:** 90.
- **Product bug discovered:** none. All plan-specified behaviors matched the
  product code exactly, including documented quirks: structural-only
  `is_iso_date`, `os.time` month-overflow normalization, and `completion_stats`
  ignoring a branch node's own completed flag.
- **Product-code change:** none.

### links — `tests/link_maintenance_spec.lua`
- **Status:** CONFIRMED (1 attempt). Spec result: 23 passed, 0 failed.
- **Assertions:** 89.
- **Product bug discovered:** yes (confirmed the investigator's suspicion in
  `url_validate.extract_urls`). A wikilink with an HTTP target
  (`[[https://wiki.link|alias]]`) yields **two** entries for the same URL — a
  `bare` entry (URL_PAT stops at `|`, captured in pass 2) plus the `wikilink`
  entry (pass 3) — because the dedup loop only suppresses overlap with markdown
  entries collected earlier, not the later wikilink pass.
  - **How handled:** per the HONESTY RULE, the test **pins the exact current
    behavior** (count==2, both `url='https://wiki.link'`, kinds bare+wikilink)
    with an explicit `SUSPECTED BUG` comment noting the count should become 1 if
    dedup is fixed. **Not fixed** in product code: the duplication is harmless
    (the same URL is validated once via the request coalescer) and the intended
    dedup semantics are a design decision, so it is reported rather than patched.
- **Product-code change:** one minimal test-affordance export in
  `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/rename.lua` —
  `M._compute_rename_changes = compute_rename_changes` (with a comment) added
  directly after the file-local function definition, exactly as the plan
  specified. No behavior change; it only exposes the pure change-computation
  step for testing. No other product code touched.

### ui — `tests/ui_helpers_spec.lua`
- **Status:** CONFIRMED (1 attempt). Spec result: 87 passed, 0 failed.
- **Assertions:** 222.
- **Product bug discovered:** none. All behaviors matched the plan exactly,
  including the order-dependent `_infer_category` dispatch
  (VaultDaily→Navigate, VaultEmbedDebug→Embed, VaultStickyTag→Meta) and the
  truncate ellipsis-collapse arithmetic.
- **Product-code change:** none. No test-affordance exports were needed; all
  targets were already public module functions.

### templates — `tests/templates_spec.lua`
- **Status:** CONFIRMED (1 attempt). Spec result: 26 passed, 0 failed.
- **Assertions:** 126.
- **Product bugs discovered:** two genuine bugs in the Obsidian
  template-variable path, both verified empirically before fixing:
  1. `engine_templates.lua` `OBSIDIAN_FORMAT_MAP` emitted doubled percents
     (`'YYYY'` → `'%%Y'`); since replacements are spliced directly into the
     `os.date` format (not via `gsub`), `format_obsidian('YYYY-MM-DD')` returned
     the literal string `'%Y-%m-%d'` instead of a date, breaking `{{date:FMT}}`
     and the `{{date}}`/`{{time}}` builtins.
  2. `config.lua` had no `template_vars` section, so the builtin
     `{{date}}`/`{{time}}` resolvers crashed with
     `attempt to index field 'template_vars' (a nil value)`.
- **How handled:** both fixes were small and unambiguous, so they were applied
  per the HONESTY RULE; the spec asserts the corrected behavior and documents
  the original bugs in comments.
- **Product-code changes (2 fixes, no affordances):**
  1. `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/engine_templates.lua` —
     changed all `OBSIDIAN_FORMAT_MAP` replacements from doubled to single
     percent (`'%%Y'` → `'%Y'`, etc.) and the literal-`%` escape from `'%%%%'`
     to `'%%'`. Before fix: `format_obsidian('YYYY-MM-DD') == '%Y-%m-%d'`
     literal; after fix it returns the actual date.
  2. `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/config.lua` — added the
     missing `M.template_vars = { date_format = 'YYYY-MM-DD', time_format = 'HH:mm' }`
     section (Obsidian defaults) that the `{{date}}`/`{{time}}` builtin
     resolvers dereference.
  - Full suite re-run after both changes: **all 18 specs green (849 passed, 0
    failed)**.

### weak-upgrade — `tests/behavioral_upgrades_spec.lua`
- **Status:** CONFIRMED (1 attempt). Spec result: 79 passed, 0 failed.
- **Assertions:** 260.
- **Product bug discovered:** none. All 79 tests passed on first run against the
  real modules; every expected value (including exact 0-indexed byte offsets for
  inline-field parsing) matched actual behavior.
- **Product-code change:** none.

---

## `run_all.lua` Aggregate

| | Specs | Assertions |
|---|------:|-----------:|
| Before | 11 | 421 |
| New (this expansion) | 8 | 1567 |
| **After** | **19** | **1988** |

The full aggregate suite is green (0 failures), inclusive of the two template
bug fixes (the templates re-run verified 18 specs / 849 passed at that
checkpoint; the final `run_all.lua` adds the remaining new specs for 19 specs /
1988 assertions total).

---

## Unresolved Issues & Next Steps

All 8 issues are CONFIRMED; none are UNRESOLVED. Two intentionally
un-remediated findings remain open as **reported, not fixed** (by design, per
the HONESTY RULE):

1. **`filter_utils.normalize_link_name` fragment-only quirk** (search). Input
   `"#Heading"` returns `"#heading"` instead of `nil` because `"^([^#^]+)"`
   fails to match and the raw string falls through unstripped.
   - *Next step:* decide whether fragment-only inputs should normalize to `nil`;
     if so, fix the pattern and add an asserting test. Currently unasserted to
     avoid locking in suspected-buggy behavior. Low impact — callers guard empty
     note names via `link_utils.parse_target`.

2. **`url_validate.extract_urls` double-counts HTTP wikilink targets** (links).
   `[[https://wiki.link|alias]]` yields two entries (bare + wikilink) because the
   dedup loop ignores the later wikilink pass.
   - *Next step:* if single-entry dedup is desired, extend the dedup loop to
     suppress overlap with the wikilink pass, then flip the pinned assertion from
     count==2 to count==1. Currently harmless (one validation via the request
     coalescer) and treated as a design decision.
