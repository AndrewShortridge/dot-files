# 28 — Pattern Compilation Cache

## Priority: LOW (modest performance impact, significant code quality improvement)
## Inspired By: Zed's `LazyLock<Regex>`, per-query regex caching, Aho-Corasick automaton reuse

## Problem

The vault plugin uses Lua patterns (`match`, `gmatch`, `find`, `gsub`) extensively — 1,300+
occurrences across 130+ modules (206 total .lua files in `lua/andrew/vault/`). Several
inefficiencies exist in how patterns are defined and compiled.

### Pattern Duplication

The same logical patterns appear as string literals scattered across many modules:

| Pattern | Meaning | Modules Using It |
|---------|---------|------------------|
| `"%[%[(.-)%]%]"` | Wikilink extraction | link_utils (line 7, as `M.WIKILINK_PAT`), vault_index_parser (line 47, local mirror), backlinks (line 232, via gmatch), export (line 278, via `link_utils.WIKILINK_PAT`), query/render (lines 70, 170), inline_fields (line 29), completion (lines 86, 134) |
| `"!%[%[(.-)%]%]"` | Embed extraction | vault_index_parser (line 48, local mirror), export (line 272), link_utils (line 119) |
| `"!%[%[.-%]%]"` | Embed detection | embed_state (line 13, as `M.EMBED_PAT`), line_parse_cache (line 362) |
| `"#([%w_%-][%w_%-/]*)"` | Tag extraction | vault_index_parser (lines 219, 413) |
| `"#([%w_/-]*)$"` | Tag completion | completion_tags (line 89, trigger check) |
| `"^(#+)%s+(.*)"` | Heading extraction | vault_index_parser (line 239), link_utils (line 269), outline (line 34) |
| `"%[([%w_%-]+)::%s*(.-)%]"` | Inline field (bracket) | vault_index_parser (lines 332, 462), inline_fields (line 135), completion_inline_fields (line 14) |
| `"%(([%w_%-]+)::%s*(.-)%)"` | Inline field (paren) | vault_index_parser (lines 365, 465), inline_fields (line 155) |
| `"^([%w_%-]+)::%s*(.*)"` | Inline field (standalone) | inline_fields (line 222), vault_index_parser (line 457) |
| `"^([%w_%-]+):%s*(.*)"` | Frontmatter key-value | vault_index_parser (line 146), frontmatter_parser (line 66), user_templates (lines 182, 212, 231, 250), sidebar_meta (line 90) |
| `"[^\n]*"` | Line iteration (incl. empty) | vault_index_parser (lines 107, 237), block_patterns (line 46), rename (line 179) |
| `"[^\n]+"` | Line iteration (non-empty) | vault_index_parser (lines 296, 453), search_filter/ripgrep (line 130), linkcheck (line 301), navigate |
| `"(.-)\n"` | Line capture with newline | export (lines 264, 276), user_templates (line 161), tags (line 42) |
| `"[^,]+"` | CSV split | vault_index_parser (line 167), search_query (line 68), frontmatter_parser (line 84), user_templates (line 191), frontmatter_editor/editors |
| `"([^/]+)$"` | Basename extraction | vault_index_parser (line 288) |
| `"^(.+)/[^/]+$"` | Parent path extraction | vault_index_parser (line 197) |
| `"%.md$"` | .md extension match/strip | vault_index_parser (lines 267, 493, 528), vault_index (lines 43, 461), vault_index_build (line 200), export (line 295), link_utils (line 96), frecency (line 83), navigate (line 236), calendar (line 190), user_templates (line 340), + others (23 occurrences in 16 files) |
| `"^%s*```"` | Code fence detection | vault_index_parser (lines 108, 399), link_utils (line 104, incl. tilde variant `"^%s*~~~"`) |
| `"^%-%-%-"` | Frontmatter delimiter | vault_index_parser (lines 122-133), export (lines 136, 139), graph/collect, rename (line 485), user_templates (lines 99, 101, 104) |
| `"^%d%d%d%d%-%d%d%-%d%d$"` | ISO date validation | date_utils (line 132), inline_fields (line 27), query/index (line 350), frontmatter_editor/type_utils (line 26), vault_index_parser (line 515) |
| `"==[^=]+=="` | Highlight marks | line_parse_cache (LPEG tokenizer, line 82: `highlight_mark = P"==" * (1 - P"==")^1 * P"=="`) |
| `"%[%^([%w_-]+)%]"` | Footnote reference | line_parse_cache (line 46, as `M.FOOTNOTE_REF_PAT`), footnotes (line 30, imported from line_parse_cache) |
| `"https?://..."` | URL matching | link_utils (line 14, as `M.URL_PAT`), link_scan, wikilinks, url_validate |

Each module defines these patterns as inline string literals. When a pattern needs
updating (e.g., expanding valid tag characters), every occurrence must be found and
changed independently — a maintenance hazard.

### Existing Partial Centralization

Several modules already centralize their pattern constants, establishing a precedent:

- **`block_patterns.lua`** — `BLOCK_ID_PATTERN` (line 10), `BLOCK_ID_STRIP` (line 13)
  + helper functions (`match_id`, `extract_ids_from_lines`, `existing_ids_in_content`)
- **`link_utils.lua`** — `M.WIKILINK_PAT = "%[%[(.-)%]%]"` (line 7),
  `M.WIKILINK_EXACT_PAT = "^%[%[(.-)%]%]$"` (line 11),
  `M.URL_PAT = "https?://..."` (line 14); used by some modules but not all
  (vault_index_parser defines its own `WIKILINK_PAT` local at line 47)
- **`embed_state.lua`** — `M.EMBED_PAT = "!%[%[.-%]%]"` (line 13, non-capturing)
- **`tasks.lua`** — `M.CHECKBOX_PATTERN = "^(.*%- %[)(.)(%].*)$"` (line 14)
- **`line_parse_cache.lua`** — `M.FOOTNOTE_REF_PAT = "%[%^([%w_-]+)%]"` (line 44);
  also owns LPEG-based highlight tokenizer (`highlight_mark = P"==" * ...`, line 82)
  replacing the former regex-based `HIGHLIGHT_PATTERN`
- **`footnotes.lua`** — `local REF_PAT` (line 30, imported from `line_parse_cache`),
  `local DEF_PAT` (line 32), `local CONT_PAT` (line 34),
  `local CONT_TAB_PAT` (line 35)

These demonstrate the pattern-as-constant approach works, but each module only
centralizes its own patterns — no shared constants module exists.

### Pattern Compilation Cost

Lua's `string.match`, `string.gmatch`, `string.find`, and `string.gsub` compile their
pattern argument on every call. There is no internal compilation cache. For hot paths
this adds measurable overhead:

```
vault_index_parser.lua single-pass parse:
  - 8+ pattern compilations per line (FM key, heading, task, tag, link, embed, inline field)
  - 10,000 files × 50 avg lines = 500,000 lines
  - ~4 million pattern compilations per full index build

link_utils.extract_line_links() (lines 111-141):
  - 3 pattern compilations per call (embed position scan, embed extract, link extract)
  - Called per-line for every wikilink-highlighting buffer

slug.lua heading_to_slug():
  - 5 gsub patterns compiled per call (special chars, spaces, dashes, trim)
  - Mitigated by LRU result cache (_slug_cache), but still fires on every cache miss
```

### Wikilink Parsing Fragility

The wikilink pattern is particularly subtle. Multiple modules implement their own
bracket-matching loops (`find("%[%[", pos)` followed by manual `]]` scanning)
because the simple `gmatch` pattern cannot handle nested brackets or escaped content.
A total of 9 independent bracket-scanning implementations exist:

| Module | Function | Lines | Embed Handling |
|--------|----------|-------|----------------|
| `link_utils.lua` | `get_wikilink_on_line()` (local) | 195-210 | None (caller context); uses pattern find for both open/close |
| `link_utils.lua` | `extract_line_links()` | 111-141 | Explicit: pre-scans `![[` positions, skips in wikilink pass |
| `link_scan.lua` | `get_link_ranges()` | 184-200 | Implicit: checks `line:sub(s - 1, s - 1) == "!"` and adjusts start position |
| `wikilinks.lua` | `find_links_on_line()` (local) | 405-429 | No closing bracket match (opens only); also scans markdown links |
| `url_validate.lua` | `extract_urls()` | 98-116 | No embed skipping; HTTP URL filter on inner content |
| `link_repair.lua` | `repair_vault()` callback | 456-480 | No embed check; pattern find for open, plain find for close |
| `line_parse_cache.lua` | `tokenize_line_legacy()` (local) | 185-236 | Explicit dual-pass: embeds first (`!%[%[`, lines 192-210), then wikilinks (lines 214-236) with `!` char skip |
| `vault_index_parser.lua` | `extract_links()` (local) | 280-319 | gmatch for embeds (lines 284-293), while-loop find for wikilinks (lines 296-316) with `!` char check |
| `graph/collect.lua` | `collect_forward_links()` | 73-109 | Implicit: checks `line:sub(s - 1, s - 1) == "!"` via goto; also skips inline field patterns |

Note: `backlinks.lua` (line 232) uses a `gmatch` for link extraction but does not
implement a bracket-scanning loop. `wikilink_highlights.lua` has been refactored
(now ~57 lines) and no longer contains a bracket-scanning loop. `linkdiag.lua` uses
vault index for link detection rather than bracket scanning.

Note: `line_parse_cache.lua` also has an LPEG-based tokenizer as a modern replacement
for `tokenize_line_legacy()`, which handles wikilinks, embeds, highlights, footnotes,
and inline fields via a unified grammar.

These ad-hoc parsers drift from each other over time. Some use `line:find("]]", pos, true)`
(plain match), others use `line:find("%]%]", pos, false)` (pattern match). Some check for
preceding `!` to skip embeds, others don't. Only two implementations (link_utils
`extract_line_links` and line_parse_cache `tokenize_line_legacy`) use explicit
dual-pass strategies. The LPEG tokenizer in `line_parse_cache.lua` represents the
future direction but the legacy regex scanners remain active in all other modules.

### Zed's Approach

From `crates/project/src/search.rs` (lines 57-78, 80-84, 335-336):

```rust
// Compiled once at program start, reused forever (line 80)
static WORD_MATCH_TEST: LazyLock<Regex> = LazyLock::new(|| {
    RegexBuilder::new(r"\B")
        .build()
        .expect("Failed to create WORD_MATCH_TEST")
});

// Line 335 — declared inside function scope, still lazily initialized once
static TEXT_REPLACEMENT_SPECIAL_CHARACTERS_REGEX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\\\\|\\n|\\t").unwrap());

// Per-query: compiled once during SearchQuery construction, shared via Arc (lines 57-78)
pub enum SearchQuery {
    Text {
        search: AhoCorasick,        // Automaton built once per query (line 60)
        replacement: Option<String>,
        whole_word: bool,
        case_sensitive: bool,
        include_ignored: bool,
        inner: SearchInputs,
    },
    Regex {
        regex: Regex,               // fancy_regex::Regex, compiled once (line 69)
        replacement: Option<String>,
        multiline: bool,
        whole_word: bool,
        case_sensitive: bool,
        include_ignored: bool,
        one_match_per_line: bool,
        inner: SearchInputs,
    },
}
// SearchQuery is wrapped in Arc<SearchQuery> and shared across buffer searches.
// Arc<SearchQuery> found in 3 files: buffer_search.rs, terminal_view.rs, searchable.rs.
// Several other files (text_thread_editor.rs, dap_log.rs, lsp_log.rs, items.rs) use
// SearchQuery directly but not via Arc.
```

Note: Zed uses `fancy_regex::Regex` (not standard `regex` crate) for SearchQuery::Regex,
enabling advanced features like lookahead/lookbehind. Standard `regex` crate is used for
LazyLock static patterns.

Zed uses multiple complementary caching strategies — 27 `LazyLock<Regex>` instances
across 17 production crate files (29 total including 2 test/fixture files):

| Strategy | Use Case | Example |
|----------|----------|---------|
| `LazyLock<Regex>` | Global static patterns (compile-time known) | `WORD_MATCH_TEST` (search.rs:80), `USERNAME_REGEX` (remote.rs:11), `EMOJI_REGEX` (util.rs:1003), `RELAXED_HEX_REGEX` / `STRICT_HEX_REGEX` / `RELAXED_RGB_OR_HSL_REGEX` / `STRICT_RGB_OR_HSL_REGEX` (color_extractor.rs:10-31), `LINE_HINT_REGEX` (edit_parser.rs:161), `ASSISTANT_CONTEXT_REGEX` (context_store.rs:785), `REDACT_REGEX` (reqwest_client.rs:18), `DISABLED_GLOBS_REGEX` (inline_completion_button.rs:918), `LINE_SEPARATORS_REGEX` (text.rs:46), `SUFFIX_RE` (paths.rs:403) |
| `OnceLock<T>` | One-time initialization of complex data (not regex) | Highlight style data, search data, PathBuf, HeaderName, etc. (~84 instances across ~37 files, none for regex) |
| `Arc<SearchQuery>` | Share compiled queries across threads | `active_search: Option<Arc<SearchQuery>>` in `buffer_search.rs` (line 109); found in 3 files (buffer_search.rs, terminal_view.rs, searchable.rs) |
| `AhoCorasick` in enum | Text search automaton stored in query | `SearchQuery::Text { search: AhoCorasick }` — built dynamically per query, not cached as static |
| `thread_local!` | Per-thread regex cache (test-only) | `TEST_REGEX_SEARCHES: RefCell<RegexSearches>` in `terminal_hyperlinks.rs` (lines 1186-1188, test code only) |
| `const &str` | Pattern string constants | `ROW_COL_CAPTURE_REGEX` (paths.rs:264), `URL_REGEX` (terminal_hyperlinks.rs:11), `WORD_REGEX` (terminal_hyperlinks.rs:14), `PYTHON_FILE_LINE_REGEX` (terminal_hyperlinks.rs:17) |
| `RegexBuilder` with flags | LazyLock with case_insensitive etc. | `color_extractor.rs` uses `RegexBuilder::new().case_insensitive(true)` for strict color patterns |

Key LazyLock<Regex> files by domain (27 production instances across 17 files):
- Color extraction (4 instances): `color_extractor.rs` (lines 10, 17, 24, 31)
- Language diagnostics (6 instances): `go.rs` (lines 40, 43, 427), `rust.rs` (lines 265, 284, 353)
- Search (2 instances): `search.rs` (lines 80, 335)
- Git/networking (4 instances): `chromium.rs` (line 22), `github.rs` (line 21), `remote.rs` (line 11), `telemetry.rs` (line 77)
- Terminal/paths (2 instances): `terminal_hyperlinks.rs` (line 19), `paths.rs` (line 403)
- Text processing (4 instances): `text.rs` (line 46), `markdown_writer.rs` (lines 12, 18), `util.rs` (line 1003)
- Editing/completion (4 instances): `inline_completion_button.rs` (line 918), `context_store.rs` (line 785), `edit_parser.rs` (lines 161, 305)
- HTTP (1 instance): `reqwest_client.rs` (line 18)
- Test/fixture (2 instances): `buffer_tests.rs` (line 32, `TRAILING_WHITESPACE_REGEX` as `LazyLock<regex::Regex>`), evals fixture `before.rs` (line 44, `GRAMMAR_NAME_REGEX`)

Key insight: patterns are compiled at the narrowest appropriate scope — static patterns
at program start, per-query patterns at query construction — and never recompiled.
Some LazyLock<Regex> instances are declared inside function scopes (search.rs:335,
inline_completion_button.rs:918) rather than at module level, but are still lazily
initialized once.

## Proposed Solution

### 1. Pattern Constants Module

Create `lua/andrew/vault/patterns.lua` as the single source of truth for all pattern
strings used across the vault plugin. Follows the existing precedent set by
`block_patterns.lua`:

```lua
--- Centralized pattern definitions for the vault plugin.
--- Single source of truth — all modules require patterns from here.
---
--- Inspired by Zed's LazyLock<Regex> static pattern definitions
--- and the existing block_patterns.lua module.

local M = {}

-- Wikilinks
M.WIKILINK = "%[%[(.-)%]%]"
M.WIKILINK_OPEN = "%[%["
M.WIKILINK_INNER = "%[%[([^%]]+)%]%]"
M.WIKILINK_WITH_POS = "()%[%[(.-)%]%]()"
M.EMBED = "!%[%[(.-)%]%]"
M.EMBED_OPEN = "!%[%["
M.EMBED_INNER = "!%[%[([^%]]+)%]%]"
M.EMBED_STATE = "!%[%[.-%]%]"
M.EMBED_POS = "()!%[%["

-- Wikilink component parsing (used in link_utils.parse_target)
M.LINK_PIPE = "^(.+)|(.+)$"
M.LINK_SELF_HEADING_BLOCK = "^#([^%^]+)%^(.+)$"
M.LINK_NAME_HEADING_BLOCK = "^([^#%^]+)#([^%^]+)%^(.+)$"
M.LINK_NAME_BLOCK = "^([^#%^]+)%^(.+)$"
M.LINK_NAME_HEADING = "^([^#%^]+)#(.+)$"
M.LINK_ALIAS = "%|([^%]]+)%]%]"
M.LINK_TARGET = "%[%[([^|%]]+)%]%]"
M.LINK_TARGETS_SIMPLE = "%[%[([^%]|#]+)"

-- Tags
M.TAG = "#([%w_%-][%w_%-/]*)"
M.TAG_COMPLETION = "#([%w_/-]*)$"
M.TAG_TRIGGER = "[%s^]#[%w_/-]*$"

-- Headings
M.HEADING = "^(#+)%s+(.*)"
M.HEADING_TEXT = "^#+%s+(.*)"

-- Inline fields
M.INLINE_FIELD_BRACKET = "%[([%w_%-]+)::%s*(.-)%]"
M.INLINE_FIELD_PAREN = "%(([%w_%-]+)::%s*(.-)%)"
M.INLINE_FIELD_STANDALONE = "^([%w_%-]+)::%s*(.*)"
M.INLINE_FIELD_LIST_ITEM = "^(%s*[-*]%s+)([%w_%-]+)::%s*(.*)"
M.INLINE_FIELD_DELIM = "::"

-- Frontmatter
M.FM_OPEN = "^%-%-%-$"
M.FM_OPEN_LINE = "^%-%-%-\n"
M.FM_CLOSE = "\n%-%-%-\n"
M.FM_CLOSE_EOF = "\n%-%-%-$"
M.FM_KEY_VALUE = "^([%w_%-]+):%s*(.*)"
M.FM_KEY_PREFIX = "^([%w_%-]+):"
M.FM_LIST_ITEM = "^%s+%- (.*)"
M.FM_LIST_ITEM_CHECK = "^%s+%- "

-- Tasks
M.TASK_CHECKBOX = "^(.*%- %[)(.)(%].*)$"
M.TASK_DETECT = "^%s*[-*] %[(.)%] "
M.TASK_TEXT = "^%s*[-*] %[.%] (.*)"

-- Block IDs (mirrors block_patterns.lua for consolidation)
M.BLOCK_ID = "%^([%w%-]+)%s*$"
M.BLOCK_ID_STRIP = "%s*%^[%w%-]+%s*$"

-- Code fences
M.CODE_FENCE_BACKTICK = "^%s*```"
M.CODE_FENCE_TILDE = "^%s*~~~"

-- Dates
M.ISO_DATE = "^%d%d%d%d%-%d%d%-%d%d$"
M.ISO_DATE_MD = "^%d%d%d%d%-%d%d%-%d%d%.md$"
M.ISO_DATE_CAPTURE = "^(%d%d%d%d%-%d%d%-%d%d)%.md$"
M.ISO_DATE_PARTS = "(%d+)-(%d+)-(%d+)"
M.ISO_DATETIME_FULL = "^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)"
M.ISO_DATETIME_SHORT = "^(%d%d%d%d)-(%d%d)-(%d%d)"
M.ISO_DATE_PREFIX = "^(%d%d%d%d%-%d%d%-%d%d)"
M.RELATIVE_DURATION = "^(%d+)d$"

-- Highlights
M.HIGHLIGHT = "==[^=]+=="

-- Footnotes
M.FOOTNOTE_REF = "%[%^([%w_-]+)%]"
M.FOOTNOTE_DEF = "^%[%^([%w_-]+)%]:%s?(.*)"
M.FOOTNOTE_ID = "%[%^(%d+)%]"
M.FOOTNOTE_CONT = "^%s%s%s%s(.*)"      -- continuation with 4 spaces
M.FOOTNOTE_CONT_TAB = "^\t(.*)"         -- continuation with tab

-- URLs
M.URL = "https?://[%w%-%.%_%~%:%/%?#%[%]@!%$&'%(%)%*%+,;=%%]+"

-- Line iteration
M.LINE = "[^\n]*"
M.LINE_NONEMPTY = "[^\n]+"
M.LINE_CAPTURE = "(.-)\n"
M.LINE_WITH_NEWLINE = "([^\n]*)\n?"

-- Slug construction (gsub patterns)
M.SLUG_STRIP_SPECIAL = "[^%w%s%-]"
M.SLUG_COLLAPSE_SPACES = "%s+"
M.SLUG_COLLAPSE_DASHES = "%-+"
M.SLUG_TRIM_LEADING = "^%-+"
M.SLUG_TRIM_TRAILING = "%-+$"

-- Common list/CSV
M.CSV_ITEM = "[^,]+"
M.CSV_ITEM_COMPLEX = '[^,%[%]"]+' -- for list items with bracket/quote delimiters

-- Path
M.PARENT_PATH = "^(.+)/[^/]+$"
M.BASENAME = "([^/]+)$"
M.BASENAME_NO_EXT = "^(.+)%.[^.]+$"
M.PATH_SEGMENT = "[^/]+"
M.DOTTED_SEGMENT = "[^%.]+"
M.WORD_SEGMENT = "%S+"
M.MD_EXTENSION = "%.md$"

-- File extension
M.STRIP_MD = "%.md$"

-- Regex escaping
M.LUA_SPECIAL_CHARS = "([%.%+%*%?%[%]%^%$%(%)%{%}%|\\])"
M.LUA_PATTERN_ESCAPE = "[%(%)%.%%%+%-%*%?%[%]%^%$]"

-- Markdown links (non-wiki)
M.MARKDOWN_LINK = "%[.-%]%(.-%)"

-- Prefilter (for string.find quick checks before full pattern match)
M.HAS_WIKILINK = "%[%["
M.HAS_EMBED = "!%[%["
M.HAS_TAG = "#"
M.HAS_HEADING = "^#"
M.HAS_INLINE_FIELD = "::"
M.HAS_HIGHLIGHT = "=="

return M
```

### 2. Pre-bound Iterator Factories

For hot paths that iterate lines or extract all links from a string, provide pre-bound
iterator factories that avoid re-specifying the pattern string:

```lua
--- Return an iterator over all wikilink inner content in a line.
--- @param line string
--- @return fun(): string?
function M.gmatch_wikilinks(line)
  return line:gmatch(M.WIKILINK_INNER)
end

--- Return an iterator over all embed inner content in a line.
--- @param line string
--- @return fun(): string?
function M.gmatch_embeds(line)
  return line:gmatch(M.EMBED_INNER)
end

--- Return an iterator over all inline fields (bracket form) in text.
--- @param text string
--- @return fun(): string?, string?
function M.gmatch_inline_fields(text)
  return text:gmatch(M.INLINE_FIELD_BRACKET)
end

--- Return an iterator over all lines in a string.
--- @param text string
--- @return fun(): string?
function M.gmatch_lines(text)
  return text:gmatch(M.LINE)
end

--- Return an iterator over non-empty lines in a string.
--- @param text string
--- @return fun(): string?
function M.gmatch_lines_nonempty(text)
  return text:gmatch(M.LINE_NONEMPTY)
end

--- Return an iterator over all tags in text.
--- @param text string
--- @return fun(): string?
function M.gmatch_tags(text)
  return text:gmatch(M.TAG)
end

--- Return an iterator over CSV items.
--- @param text string
--- @return fun(): string?
function M.gmatch_csv(text)
  return text:gmatch(M.CSV_ITEM)
end

--- Return an iterator over path segments.
--- @param path string
--- @return fun(): string?
function M.gmatch_path_segments(path)
  return path:gmatch(M.PATH_SEGMENT)
end

--- Check if a line is inside a code fence.
--- Handles both backtick and tilde fences.
--- @param line string
--- @return boolean
function M.is_code_fence(line)
  return line:match(M.CODE_FENCE_BACKTICK) ~= nil
    or line:match(M.CODE_FENCE_TILDE) ~= nil
end
```

### 3. Bracket-Matching Scanner

Consolidate the 9 ad-hoc bracket-scanning loops into a single reusable scanner:

```lua
--- Scan for wikilinks by matching brackets (handles edge cases that gmatch misses).
--- Used by modules that need position-aware or nested-bracket-safe scanning.
--- @param line string
--- @param callback fun(inner: string, start_col: number, end_col: number): boolean?
---   Return true to stop scanning.
function M.scan_wikilinks(line, callback)
  local pos = 1
  while pos <= #line do
    local open_start, open_end = line:find(M.WIKILINK_OPEN, pos, false)
    if not open_start then break end
    -- Skip if preceded by ! (that's an embed, not a wikilink)
    if open_start > 1 and line:byte(open_start - 1) == 33 then -- '!'
      pos = open_start + 2
    else
      local close_start, close_end = line:find("]]", open_end + 1, true)
      if not close_start then break end
      local inner = line:sub(open_end + 1, close_start - 1)
      if callback(inner, open_start, close_end) then return end
      pos = close_end + 1
    end
  end
end

--- Same as scan_wikilinks but for embed syntax (![[...]]).
--- @param line string
--- @param callback fun(inner: string, start_col: number, end_col: number): boolean?
function M.scan_embeds(line, callback)
  local pos = 1
  while pos <= #line do
    local open_start, open_end = line:find(M.EMBED_OPEN, pos, false)
    if not open_start then break end
    local close_start, close_end = line:find("]]", open_end + 1, true)
    if not close_start then break end
    local inner = line:sub(open_end + 1, close_start - 1)
    if callback(inner, open_start, close_end) then return end
    pos = close_end + 1
  end
end

--- Scan for both wikilinks and embeds, distinguishing between them.
--- @param line string
--- @param callback fun(inner: string, start_col: number, end_col: number, is_embed: boolean): boolean?
function M.scan_all_links(line, callback)
  local pos = 1
  while pos <= #line do
    local open_start, open_end = line:find(M.WIKILINK_OPEN, pos, false)
    if not open_start then break end
    local is_embed = open_start > 1 and line:byte(open_start - 1) == 33
    if is_embed then open_start = open_start - 1 end
    local close_start, close_end = line:find("]]", open_end + 1, true)
    if not close_start then break end
    local inner = line:sub(open_end + 1, close_start - 1)
    if callback(inner, open_start, close_end, is_embed) then return end
    pos = close_end + 1
  end
end
```

### 4. vim.regex() Cache (Future-Proofing)

The vault plugin currently does not use `vim.regex()`, but several Neovim plugins do
and the vault may adopt it for Vim-regex features (e.g., `\v`, `\zs`). Provide a
cache for when it's needed:

```lua
local _regex_cache = {}
local _regex_count = 0
local _regex_max = 100

--- Get or compile a vim.regex() object.
--- Cached by pattern string, bounded to config.patterns.regex_cache_size entries.
--- @param pattern string Vim regex pattern
--- @return vim.regex Compiled regex object
function M.vim_regex(pattern)
  local cached = _regex_cache[pattern]
  if cached then return cached end

  if _regex_count >= _regex_max then
    _regex_cache = {}
    _regex_count = 0
  end

  local ok, regex = pcall(vim.regex, pattern)
  if not ok then
    error("pattern_cache: invalid vim.regex pattern: " .. pattern .. " — " .. regex)
  end

  _regex_cache[pattern] = regex
  _regex_count = _regex_count + 1
  return regex
end
```

### 5. Debug Introspection

```lua
--- Return cache statistics for :VaultCacheStats integration.
--- @return table
function M.stats()
  return {
    regex_cache_size = _regex_count,
    regex_cache_max = _regex_max,
    pattern_constants = vim.tbl_count(M),  -- Number of exported patterns
  }
end
```

## Integration Points

### Phase 1: Adopt Pattern Constants (Low Risk)

Replace inline pattern literals with `patterns.X` references. Each change is a
one-line substitution with no behavioral difference.

#### vault_index_parser.lua (50+ pattern uses — index hot path, highest priority)

```lua
-- BEFORE:
local WIKILINK_PAT = "%[%[(.-)%]%]"          -- line 47
local EMBED_PAT = "!%[%[(.-)%]%]"            -- line 48
local key, value = line:match("^([%w_%-]+):%s*(.*)")  -- line 146
for tag in clean_body:gmatch("#([%w_%-][%w_%-/]*)") do  -- line 219
local level_str, text = line:match("^(#+)%s+(.*)")   -- line 239
for line in content:gmatch("[^\n]*") do       -- lines 107, 237
for key, value in clean:gmatch("%[([%w_%-]+)::%s*(.-)%]") do  -- line 332
for key, value in clean:gmatch("%(([%w_%-]+)::%s*(.-)%)") do  -- line 365

-- AFTER:
local P = require("andrew.vault.patterns")
-- Replace all local pattern definitions with P.WIKILINK, P.EMBED, etc.
local key, value = line:match(P.FM_KEY_VALUE)
for tag in clean_body:gmatch(P.TAG) do
local level_str, text = line:match(P.HEADING)
for line in content:gmatch(P.LINE) do
for key, value in clean:gmatch(P.INLINE_FIELD_BRACKET) do
for key, value in clean:gmatch(P.INLINE_FIELD_PAREN) do
```

#### link_utils.lua (27 pattern uses — second highest concentration)

```lua
-- BEFORE:
M.WIKILINK_PAT = "%[%[(.-)%]%]"              -- line 7
M.WIKILINK_EXACT_PAT = "^%[%[(.-)%]%]$"      -- line 11
M.URL_PAT = "https?://..."                    -- line 14
line:gmatch("()!%[%[")                        -- line 115
line:gmatch("!%[%[([^%]]+)%]%]")              -- line 119
line:gmatch("()%[%[([^%]]+)%]%]")             -- line 129
line:match("^%s*```") or line:match("^%s*~~~")  -- line 104

-- AFTER:
local P = require("andrew.vault.patterns")
M.WIKILINK_PAT = P.WIKILINK  -- maintain backward compat, delegates to patterns.lua
line:gmatch(P.EMBED_POS)
line:gmatch(P.EMBED_INNER)
line:gmatch(P.WIKILINK_WITH_POS) -- or custom variant
P.is_code_fence(line)
```

#### embed_state.lua

```lua
-- BEFORE:
M.EMBED_PAT = "!%[%[.-%]%]"                  -- line 13

-- AFTER:
local P = require("andrew.vault.patterns")
M.EMBED_PAT = P.EMBED_STATE
```

#### slug.lua

```lua
-- BEFORE:
  :gsub("[^%w%s%-]", "")
  :gsub("%s+", "-")
  :gsub("%-+", "-")
  :gsub("^%-+", "")
  :gsub("%-+$", "")

-- AFTER:
local P = require("andrew.vault.patterns")
  :gsub(P.SLUG_STRIP_SPECIAL, "")
  :gsub(P.SLUG_COLLAPSE_SPACES, "-")
  :gsub(P.SLUG_COLLAPSE_DASHES, "-")
  :gsub(P.SLUG_TRIM_LEADING, "")
  :gsub(P.SLUG_TRIM_TRAILING, "")
```

#### block_patterns.lua (consolidation candidate)

```lua
-- BEFORE (lines 10, 13):
M.BLOCK_ID_PATTERN = "%^([%w%-]+)%s*$"
M.BLOCK_ID_STRIP = "%s*%^[%w%-]+%s*$"

-- AFTER:
local P = require("andrew.vault.patterns")
M.BLOCK_ID_PATTERN = P.BLOCK_ID
M.BLOCK_ID_STRIP = P.BLOCK_ID_STRIP
-- Or: merge block_patterns.lua into patterns.lua entirely
```

#### Additional modules with verified pattern uses

| Module | Pattern Types | Count | Lines |
|--------|--------------|-------|-------|
| `backlinks.lua` | wikilink target extraction (gmatch) | 1 | 232 |
| `export.lua` | embed gsub, wikilink gsub, FM delimiters, line iteration | 6 | 136, 139, 264, 272, 276, 278 |
| `linkdiag.lua` | vault index link detection (no bracket scan) | 1 | 159 |
| `wikilink_highlights.lua` | refactored (~57 lines), no bracket scan | 0 | — |
| `link_scan.lua` | bracket scan, code fence, backtick scan | 3 | 184-200 |
| `wikilinks.lua` | bracket scan (opens only), markdown link scan | 2 | 405-429 |
| `url_validate.lua` | bracket scan, HTTP filter | 2 | 98-116 |
| `link_repair.lua` | bracket scan | 2 | 456-480 |
| `completion.lua` | heading patterns | 2 | 86, 134 |
| `completion_tags.lua` | tag trigger pattern | 1 | 89 |
| `completion_inline_fields.lua` | inline field bracket pattern | 1 | 14 |
| `inline_fields.lua` | bracket/paren/standalone fields, ISO date, delimiter scan | 5 | 27, 29, 135, 155, 213, 222 |
| `frontmatter_parser.lua` | FM key-value, CSV split | 2 | 66, 84 |
| `frontmatter_editor/editors.lua` | CSV split | 1 | (gmatch `[^,]+`) |
| `frontmatter_editor/type_utils.lua` | ISO date | 1 | 26 |
| `query/index.lua` | stem extraction, ISO date | 2 | 61, 350 |
| `query/render.lua` | wikilink detection | 2 | 70, 170 |
| `linkcheck.lua` | line iteration, wikilink parsing | 2 | 301, 303 |
| `breadcrumbs.lua` | wikilink detection (type guard) | 1 | 13 |
| `outline.lua` | heading extraction | 1 | 34 |
| `graph/collect.lua` | FM delimiters, wikilink bracket scan | 3 | 73-109 |
| `rename.lua` | wikilink gsub, FM gsub, line iteration | 3 | 179, 181, 485 |
| `tags.lua` | line iteration | 1 | 42 |
| `calendar.lua` | ISO date | 1 | 190 |
| `navigate.lua` | daily log date extraction, line iteration | 2 | 236 |
| `date_utils.lua` | ISO date/datetime, is_iso_date | 3 | 103, 111, 132 |
| `recurrence.lua` | ISO date parsing, inline field gsub | 2 | 71, 166 |
| `tasks.lua` | checkbox pattern, completion field cleanup | 3 | 14, 24, 27 |
| `line_parse_cache.lua` | LPEG tokenizer + legacy bracket scanner, footnote ref pat | 3+ | 44, 82, 185-236 |
| `footnotes.lua` | footnote ref (imported)/def/cont patterns | 4 | 30, 32, 34, 35 |
| `user_templates.lua` | FM delimiters, FM key-value, CSV, line iteration, .md check | 8 | 99, 101, 104, 161, 182, 191, 237, 340 |
| `sidebar_meta.lua` | FM key prefix | 1 | 90 |
| `search_query.lua` | CSV split | 1 | 68 |
| `search_filter/ripgrep.lua` | line iteration | 1 | 130 |
| `search_filter/match_helpers.lua` | dot-separated path segments | 1 | (gmatch `[^%.]+`) |
| `vault_index_parser.lua` | bracket scan, all major patterns | 50+ | 47-528 (see Phase 1 detail) |
| `vault_index.lua` | .md extension, path segments | 4 | 43, 461 |
| `vault_index_build.lua` | .md extension filter | 1 | 200 |
| `embed_state.lua` | embed pattern | 1 | 13 |
| `frecency.lua` | .md extension | 1 | 83 |

### Phase 2: Consolidate Bracket Scanners

Replace the 9 ad-hoc bracket-matching loops with `patterns.scan_wikilinks()`:

```lua
-- BEFORE (wikilink_highlights.lua, link_scan.lua, wikilinks.lua, etc.):
local pos = 1
while pos <= #line do
  local s = line:find("%[%[", pos)
  if not s then break end
  local e = line:find("]]", s + 2, true)
  if not e then break end
  local inner = line:sub(s + 2, e - 1)
  -- ... process inner, s, e+1 ...
  pos = e + 2
end

-- AFTER:
local P = require("andrew.vault.patterns")
P.scan_wikilinks(line, function(inner, start_col, end_col)
  -- ... use inner, start_col, end_col ...
end)
```

Affected modules (verified with line numbers):
- `link_utils.lua` — `get_wikilink_on_line()` (lines 195-210, local)
- `link_utils.lua` — `extract_line_links()` (lines 111-141, gmatch-based dual-pass)
- `link_scan.lua` — `get_link_ranges()` (lines 184-200)
- `wikilinks.lua` — `find_links_on_line()` (lines 405-429, local)
- `url_validate.lua` — `extract_urls()` (lines 98-116)
- `link_repair.lua` — `repair_vault()` callback (lines 456-480)
- `line_parse_cache.lua` — `tokenize_line_legacy()` (lines 185-236, dual-pass: embeds 192-210, wikilinks 214-236)
- `vault_index_parser.lua` — `extract_links()` (lines 280-319, gmatch for embeds + while-loop find for wikilinks)
- `graph/collect.lua` — `collect_forward_links()` (lines 73-109, while loop with search_start and inline-field skip)

Note: Each loop has slight variations (embed skip logic, position tracking, early
exit conditions) that the callback-based scanner must accommodate. The `scan_wikilinks`
function handles embed skipping by default; modules needing both wikilinks and embeds
should use `scan_all_links` instead. The `line_parse_cache.lua` scanner has both a
legacy regex path (`tokenize_line_legacy`, lines 185-236) and a modern LPEG tokenizer;
the LPEG path is the future direction but does not yet cover all consumers. The legacy
scanner performs explicit dual-pass (embeds then wikilinks) with `!` char checking to
prevent double-matches. `backlinks.lua` (line 232) uses gmatch for link extraction
but does not implement a bracket-scanning loop and would not use `scan_wikilinks()`.

### Phase 3: Pre-bound Iterators in Hot Paths

For the highest-frequency callers, switch from `line:gmatch(P.TAG)` to
`P.gmatch_tags(line)`. This is a micro-optimization (avoids one table lookup per
call) and primarily serves as documentation of the hot path.

## Configuration

```lua
-- In config.lua:
M.patterns = {
  regex_cache_size = 100,   -- Max cached vim.regex() objects
  debug = false,            -- Log cache statistics on :VaultCacheStats
}
```

Minimal configuration surface — the pattern constants themselves are not configurable
(they define the plugin's syntax and must be consistent).

## Expected Impact

### Performance

| Hot Path | Calls (10K vault) | Pattern Compilations Saved | Est. Time Saved |
|----------|-------------------|---------------------------|-----------------|
| Index parse (full build) | 500K lines | ~4M (8 patterns/line) | ~200ms |
| Wikilink highlights (per buffer) | ~1K lines | ~3K (3 patterns/line) | ~5ms |
| Slug computation (cache miss) | ~10K unique | ~50K (5 gsubs/call) | ~10ms |
| Tag extraction (per buffer) | ~1K lines | ~1K | ~2ms |
| Link extraction (per buffer) | ~1K lines | ~3K | ~5ms |

**Total estimated savings: ~220ms on full index build, ~12ms per buffer render.**

These are modest but compound with vault size. The primary value is code quality.

### Code Quality

| Metric | Before | After |
|--------|--------|-------|
| Wikilink pattern definitions | 15+ files | 1 file (patterns.lua) |
| Tag pattern definitions | 2 files | 1 file |
| Heading pattern definitions | 4 files | 1 file |
| FM key-value pattern definitions | 3 files | 1 file |
| Inline field pattern definitions | 2 files | 1 file |
| CSV split pattern definitions | 6 files | 1 file |
| Line iteration pattern definitions | 6+ files | 1 file |
| Bracket-scanner implementations | 9 files | 1 shared function |
| Risk of pattern drift | High (independent copies) | None (single source) |
| Pattern discoverability | Grep across codebase | Read patterns.lua |

### Maintenance

When vault syntax rules change (e.g., "allow Unicode in tag names"), the change is
made in one place and all 40+ consuming modules pick it up automatically. Today,
such a change requires finding and updating every inline pattern string — with the
risk of missing one.

## Implementation Notes

### Lua Pattern Compilation

Lua's pattern matching functions (`match`, `gmatch`, `find`, `gsub`) compile the
pattern string into an internal representation on every call. There is no compilation
cache in PUC Lua or LuaJIT. The compilation cost is proportional to pattern length
and complexity.

For simple patterns like `"#(%w+)"`, compilation is fast (~1μs). For longer patterns
with character classes and captures like `"^([%w_%-]+):%s*(.*)"`, it's still fast but
adds up across millions of calls.

Centralizing patterns into module-level constants does not avoid recompilation (Lua
has no compiled-pattern object like Python's `re.compile()`), but it:
1. Avoids creating new pattern *string* objects on each call (Lua interns string
   literals at load time, so `require` gives the same string object)
2. Provides a single location for pattern definitions
3. Enables future optimization if LuaJIT adds pattern compilation caching

### Why Not vim.regex() Everywhere

`vim.regex()` returns a compiled object that can be reused, making it a candidate for
replacing hot Lua patterns. However:
- Vim regex syntax differs from Lua patterns (no `%w`, `%d` shortcuts)
- Crossing the Lua→C boundary has overhead (~5μs per call)
- `vim.regex()` objects lack capture groups (only match positions)
- Lua patterns are sufficient for the vault's structural parsing needs

The `vim_regex()` cache is provided for specific cases where Vim regex features are
needed (e.g., `\v` very-magic mode, `\zs`/`\ze` match bounds).

### Relationship to block_patterns.lua

`block_patterns.lua` already centralizes block ID patterns and provides helper
functions (`match_id`, `extract_ids_from_lines`, `existing_ids_in_content`). Two
options for integration:

1. **Delegate**: `block_patterns.lua` sources its patterns from `patterns.lua`
   (keeps existing API, removes pattern duplication)
2. **Merge**: Move `block_patterns.lua` functionality into `patterns.lua`
   (simpler, but changes require paths for all consumers)

Option 1 is recommended — it preserves existing `require` paths and the
block_patterns API while eliminating the duplicate pattern definitions.

### Relationship to Doc 12 (String Interning)

Doc 12 addresses duplication of *result* strings (tags, FM keys, paths). This
document addresses duplication of *pattern* strings and the absence of shared
pattern definitions. They are complementary — interning deduplicates data, pattern
caching deduplicates parsing infrastructure.

### Relationship to Doc 13 (Early-Exit Prefiltering)

Doc 13 proposes fast rejection before full parsing. Pattern constants enable
prefiltering patterns to be defined alongside their full-parse counterparts:

```lua
M.HAS_WIKILINK = "%[%["         -- For string.find() quick check
M.WIKILINK = "%[%[(.-)%]%]"     -- For full extraction
```

### Module Load Order

`patterns.lua` has zero dependencies (pure constants + closures over `string`
library). It can be required by any vault module at any point in the init lifecycle,
including before `engine.lua` sets up the vault.

## Testing Strategy

1. **Correctness**: Replace patterns one module at a time, verify behavior unchanged
   via existing test suite and manual smoke testing
2. **Consistency**: Grep for raw pattern strings after migration — none should remain
   outside `patterns.lua` (CI lint rule)
3. **Performance**: Benchmark full index build before/after on 10K vault
4. **vim.regex cache**: Unit test hit/miss/eviction behavior
5. **Bracket scanner**: Test edge cases — empty links `[[]]`, nested brackets
   `[[a[b]c]]`, unclosed brackets `[[abc`, multiple per line, embed vs wikilink
   discrimination, consumed-range overlap (as in `line_parse_cache.lua`),
   search_start position tracking (as in `vault_index_parser.lua` and `graph/collect.lua`)

## Dependencies

- Independent module (no requires except standard Lua `string` library)
- No dependency on vault_index, config, or engine — can be adopted incrementally
- `block_patterns.lua` can delegate to `patterns.lua` for its pattern strings
- Complements doc 12 (string interning) and doc 13 (early-exit prefiltering)
- Foundation for potential future "compiled pattern object" optimization if LuaJIT
  adds support

## Scope

- **New file**: `lua/andrew/vault/patterns.lua` (~180 lines, covering all pattern
  categories: wikilinks, embeds, tags, headings, inline fields, frontmatter, tasks,
  block IDs, code fences, dates, highlights, footnotes, URLs, slugs, CSV, paths,
  line iteration, regex escaping, markdown links, prefilters)
- **Refactored files**: 40+ vault modules (pattern string → constant substitution)
- **Bracket scanner consolidation**: 9 modules → shared `scan_wikilinks()` function
- **block_patterns.lua integration**: delegate pattern strings to patterns.lua
- **No behavioral changes**: Pure refactor, all pattern semantics preserved
