# Design Decisions

## 1. Separate Query Language from DQL

**Decision:** The search query language is a separate module from the Dataview
Query Language (DQL) parsed by `query/parser.lua`.

**Rationale:**
- DQL is SQL-like (`TABLE ... FROM ... WHERE ...`) for rendering tables/lists
  in code blocks. It evaluates per-page with rich expressions.
- The search query language is optimized for quick interactive filtering:
  terse prefix-operator syntax, implicit AND, no clauses.
- Trying to unify them would compromise both: DQL would need search shortcuts,
  search would carry SQL-like clause overhead.
- The parser architectures are similar (recursive descent, same state pattern)
  but the grammars are fundamentally different.

**Trade-off:** Some code duplication in parser infrastructure. Acceptable
given the different semantics.

## 2. Hybrid Ripgrep + Index Approach

**Decision:** Metadata filters use the vault index (in-memory). Content
searches use ripgrep (filesystem). Results are combined with set operations.

**Rationale:**
- Pure in-memory search (loading all file contents) would be prohibitively
  expensive for content search across 500+ files.
- Pure ripgrep cannot evaluate structured metadata filters (frontmatter,
  inline fields, date comparisons, tag hierarchy).
- The hybrid approach uses each tool for what it does best.
- `--files-from` restricts ripgrep to metadata-matched files, providing
  significant speedup when metadata filters are selective.

**Trade-off:** Complexity in the filter pipeline (AST splitting, two
evaluation paths, result combination). Worth it for the speed benefit.

## 3. Implicit AND Semantics

**Decision:** Space-separated terms are combined with AND.
`type:meeting deploy` = `type:meeting AND deploy`.

**Rationale:**
- Matches Obsidian's search behavior.
- Most intuitive for users: "notes of type meeting that contain deploy."
- Explicit `AND`/`OR` available for when different behavior is needed.
- Google Search, Obsidian, and most search interfaces use implicit AND.

**Trade-off:** `a b OR c` parses as `(a AND b) OR c`, not `a AND (b OR c)`.
Could surprise users expecting OR to distribute. Documented clearly and
matches standard boolean precedence.

## 4. Case-Insensitive Matching by Default

**Decision:** Field value comparisons are case-insensitive. Tags are always
lowercase. Text terms inherit ripgrep's smart-case.

**Rationale:**
- Tags are stored lowercase in the vault index.
- Frontmatter values have inconsistent casing across notes.
- Ripgrep's `--smart-case` is case-insensitive unless the query has uppercase.
- Matching should be forgiving: `type:meeting` and `type:Meeting` should both
  work.

**Trade-off:** No way to force case-sensitive field matching in v1. Can be
added later with a `cs:` modifier or similar.

## 5. Graceful Degradation

**Decision:** When the vault index is not ready, advanced search falls back
to plain ripgrep search with a notification. Metadata filters are silently
ignored.

**Rationale:**
- The vault index loads quickly from persisted JSON (usually ready by the time
  the user tries to search), but on cold start there's a brief window.
- Text search should always work (ripgrep doesn't need the index).
- A partial result (text matches without metadata filtering) is better than
  no result.
- Notification informs the user that results may be incomplete.

**Trade-off:** Users may not notice the notification and get unexpected
results on cold start. Mitigated by the index's fast load time.

## 6. Query String in Saved Searches

**Decision:** Advanced queries are stored as the raw query string in
`.vault-searches.json`, not the serialized AST.

**Rationale:**
- Human-readable: users can inspect and hand-edit the JSON.
- Forward-compatible: if query syntax evolves, old queries are re-parsed
  with the current parser.
- Compact: query strings are shorter than serialized ASTs.
- Debuggable: easy to copy query strings for testing.

**Trade-off:** Re-parsing on every execution. Negligible cost (< 0.5ms).

## 7. FIELD Token as Compound Token

**Decision:** The tokenizer produces a single FIELD token for `type:meeting`
with structured value `{ name, op, value, value2 }`, rather than separate
tokens for field name, colon, and value.

**Rationale:**
- Simplifies the parser: field filters are single tokens, not multi-token
  productions.
- The colon in `field:value` is syntactically unambiguous (unlike standalone
  colons which could appear in text).
- Comparison operators (`>`, `>=`) and range operators (`..`) are parsed
  inside the field value, keeping the token count low.

**Trade-off:** The tokenizer is slightly more complex (field token parsing
logic). Worth it for parser simplicity.

## 8. fzf_live for Live Mode

**Decision:** Use fzf-lua's `fzf_live()` API with a function provider for
the live advanced search mode.

**Rationale:**
- `fzf_live` calls the provider function on each keystroke with the current
  query text, which is exactly what we need.
- The provider can parse the query, evaluate metadata filters in-memory, and
  run restricted ripgrep -- all per keystroke.
- fzf-lua handles debouncing internally.
- This is the first use of `fzf_live` in the codebase, but it's the
  natural choice for this feature.

**Trade-off:** Performance dependency on per-keystroke evaluation. Metadata
filtering is < 5ms, so the bottleneck is ripgrep for text terms. fzf-lua's
debouncing mitigates this.

## 9. --files-from via Temp File

**Decision:** When restricting ripgrep to metadata-matched files, write the
file list to a temporary file and use `--files-from`.

**Rationale:**
- Shell argument length limits prevent passing 500+ file paths as arguments.
- `--files-from` reads from a file or stdin, avoiding the limit.
- Temp file is simpler than piping to stdin (which requires `io.popen` with
  complex command construction).
- Temp file is cleaned up immediately after ripgrep completes.

**Trade-off:** Brief disk I/O for writing/reading the temp file. Negligible
for file lists under 1000 entries.

## 10. Max Files Threshold for --files-from

**Decision:** When metadata filtering matches more than `max_files_from` (500)
files, skip `--files-from` and search the full vault, then post-filter.

**Rationale:**
- When metadata filters are not selective (e.g., `has:frontmatter` in a vault
  where all files have frontmatter), listing all files adds overhead without
  benefit.
- Ripgrep is already optimized for scanning entire directories.
- Post-filtering against the metadata set is O(N) on the result count, which
  is fast.

**Trade-off:** For queries like `has:tasks deploy`, if most files have tasks,
ripgrep searches the full vault and we post-filter. Slightly less efficient
than the restricted approach but avoids the temp file overhead for large sets.

## 11. Error Handling: No Recovery

**Decision:** The parser stops on the first error and returns `nil, error_msg`.
No error recovery or partial parsing.

**Rationale:**
- Search queries are short (typically < 100 characters). The user can easily
  fix the error and retry.
- Error recovery adds significant complexity to the parser.
- In live mode, parse errors are silently ignored (empty results), which
  handles the "mid-typing" case naturally.
- In prompt mode, the error message is displayed, and the user can retry.

**Trade-off:** No "best effort" parsing for partially valid queries. Users
must fix errors before seeing any results.

## 12. Tag Prefix Matching

**Decision:** `tag:project` matches tags `project`, `project/active`,
`project/active/sprint-1`, etc. This is prefix matching on the tag hierarchy.

**Rationale:**
- Matches Obsidian's tag filtering behavior.
- Tags in the vault index already include parent expansion: if a note has
  `#project/active`, the index stores both `project` and `project/active`.
- Prefix matching is intuitive: "show me everything tagged project" includes
  sub-tags.

**Trade-off:** No way to match ONLY `project` without sub-tags in v1. Could
add `tag:=project` for exact matching later.

## 13. Generic Fields as Fallback

**Decision:** Unknown field names (not in the known fields list) are treated
as generic field filters that check both `frontmatter[name]` and
`inline_fields[name]`.

**Rationale:**
- Users may have custom frontmatter fields (e.g., `area`, `source`, `due`).
- Making unknown fields an error would be too restrictive.
- Checking both frontmatter and inline_fields covers both common patterns.
- The tokenizer accepts any valid identifier before `:` as a field name.

**Trade-off:** Typos in field names silently match nothing instead of showing
an error. Acceptable given the exploratory nature of search.
