# Rust Dataview Engine for Neovim

## Context

The current vault query engine (`lua/andrew/vault/query/`) is 7,579 lines of Lua implementing DQL parsing, query execution, a JS→Lua transpiler, and vault indexing. The vault has 112 Dataview queries (89 DQL, 23 DataviewJS, 4 inline JS). The goal is to replace the performance-critical Lua modules with a Rust core compiled as a `.so` via nvim-oxi, while keeping the Lua rendering layer (`render.lua`) and command/keybinding orchestration. The architecture should be extractable into a standalone plugin later.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Neovim Process                        │
│                                                         │
│  Lua Layer (kept/rewritten)         Rust Core (.so)     │
│  ┌──────────────────────┐    ┌─────────────────────┐    │
│  │ query/init.lua       │───▶│ Vault Indexer       │    │
│  │  (rewritten)         │    │  walkdir + rayon    │    │
│  │  autocommands        │    │  gray_matter        │    │
│  │  commands/keymaps    │    ├─────────────────────┤    │
│  │                      │    │ DQL Parser          │    │
│  │ render.lua           │◀───│  winnow combinators │    │
│  │  (OVERHAULED)        │    ├─────────────────────┤    │
│  │  extmarks/virt_lines │    │ Query Executor      │    │
│  │  conceal_lines hide  │    │  eval, builtins     │    │
│  │  render-md.nvim sync │    ├─────────────────────┤    │
│  └──────────────────────┘    │ DataviewJS Runtime  │    │
│                              │  boa_engine         │    │
│                              │  dv.* API bindings  │    │
│                              ├─────────────────────┤    │
│                              │ File Watcher        │    │
│                              │  notify crate       │    │
│                              └─────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

### Interface Contract

Rust functions return Lua tables matching the existing render item format consumed by `render.lua`:

```lua
-- Table result
{ type = "table", headers = {"Col1", "Col2"}, rows = {{"val1", "val2"}}, group = nil }
-- List result
{ type = "list", items = {"item1", "item2"}, group = nil }
-- Task list result (status: " "=unchecked, "x"=done, "/"=in-progress, "-"=cancelled, ">"=deferred)
{ type = "task_list", groups = {{name = "Source", tasks = {{text = "...", completed = false, status = " "}}}} }
-- Header result
{ type = "header", level = 3, text = "Section" }
-- Paragraph result
{ type = "paragraph", text = "Some text" }
-- Error result
{ type = "error", message = "Parse error: ..." }
```

This means `render.lua`'s rendering logic is **overhauled** to produce Obsidian-style seamless output: no wrapper box, styling matched to render-markdown.nvim, and full code block concealment via `conceal_lines` (see below).

---

## Obsidian-Style Rendering Overhaul

### Goal

Match Obsidian's rendering behavior: when query results are rendered, the code block fences and query source **collapse vertically** (not just hidden characters — the lines disappear entirely), and the rendered output appears **seamlessly in the document flow** with styling identical to render-markdown.nvim's native output. No wrapper box, no "Results" label, no visual distinction between query output and hand-written markdown.

### Current behavior (before)
```
# My Notes
```dataview                         <-- visible
TABLE status FROM "Projects"         <-- visible
```                                  <-- visible
╭─ Results ────────────────────╮     <-- virtual lines below fence (wrapper box)
│ ┌──────────┬──────────┐      │     <-- custom VaultQuery* highlights
│ │ Name     │ Status   │      │
│ ...                          │
╰──────────────────────────────╯
Some paragraph continues...
```

### Target behavior (after)
```
# My Notes
╭──────────┬──────────╮              <-- code block COLLAPSED, output replaces it
│ Name     │ Status   │              <-- styled with RenderMarkdownTableHead/Row
├──────────┼──────────┤              <-- same box-drawing chars as render-markdown.nvim
│ val1     │ val2     │
╰──────────┴──────────╯
Some paragraph continues...              <-- no gap, seamless document flow
```

### Technical Approach

Full overhaul of `render.lua`: (1) use `conceal_lines` to collapse code blocks, (2) remove the "Results" wrapper box, (3) match render-markdown.nvim's exact characters, icons, and highlight groups for all output types.

#### 1. Code Block Collapse via `conceal_lines`

**Why not `conceal=""`:** Character-level concealment hides text but leaves the line occupying vertical space. A 5-line code block becomes 5 blank lines — nothing like Obsidian.

**Correct approach: `conceal_lines=""`** (Neovim 0.11+):
- Completely hides lines from display, collapsing them vertically
- render-markdown.nvim already uses this for code block fences (confirmed in its source at `render/markdown/code.lua:189`)
- Each line of the code block gets its own `conceal_lines=""` extmark
- Virtual lines (query output) are anchored to `open_line` with `virt_lines_above = false`
- Net effect: code block vanishes, query output appears in its place

```lua
-- For each line from open_line to close_line (inclusive):
vim.api.nvim_buf_set_extmark(buf, ns, i, 0, {
  conceal_lines = "",
  priority = 250,  -- above render-markdown.nvim's ~200
})

-- Virtual lines anchored at open_line
vim.api.nvim_buf_set_extmark(buf, ns, open_line, 0, {
  virt_lines = content_lines,
  virt_lines_above = false,
  virt_lines_leftcol = true,
  priority = 250,
})
```

**Cursor behavior:** When cursor moves to a `conceal_lines` line, the line becomes visible (standard Neovim conceal cursor behavior). This naturally provides Obsidian's "click to edit" UX.

**Interaction with render-markdown.nvim:**
- render-markdown.nvim applies `conceal_lines` to code block closing fences at priority ~200
- Vault query extmarks at priority 250 take precedence
- When vault query extmarks are cleared, render-markdown.nvim's normal styling reappears

#### 2. Remove Results Wrapper Box

The `wrap_in_border()` function is **deleted entirely**. Content lines from type-specific renderers are placed directly as virtual lines — no `╭─ Results ─╮`, no left/right `│` borders, no `╰─╯`.

#### 3. render-markdown.nvim-Matched Styling

All output types are restyled to match render-markdown.nvim's exact visual conventions:

**Tables** — Use render-markdown.nvim's "round" preset characters and highlight groups:
```
╭──────┬──────╮     RenderMarkdownTableHead (top border + header row + delimiter)
│ Name │ Stat │     RenderMarkdownTableHead
├──────┼──────┤     RenderMarkdownTableHead
│ val1 │ val2 │     RenderMarkdownTableRow (data rows + bottom border)
╰──────┴──────╯     RenderMarkdownTableRow
```
Characters: `╭ ┬ ╮ ├ ┼ ┤ ╰ ┴ ╯ │ ─` (matches the "round" preset already configured)

**Lists** — Match render-markdown.nvim bullet icon:
- Icon: `●` (level 1 from `icons = { '●', '○', '◆', '◇' }`)
- Highlight: `RenderMarkdownBullet`

**Tasks** — Match render-markdown.nvim checkbox icons per state:

| State | Icon | Highlight |
|-------|------|-----------|
| `[ ]` unchecked | `󰄱 ` | `RenderMarkdownUnchecked` |
| `[x]` checked | `󰱒 ` | `RenderMarkdownChecked` |
| `[/]` in-progress | `󰔟 ` | `RenderMarkdownWarn` |
| `[-]` cancelled | `✘ ` | `RenderMarkdownError` |
| `[>]` deferred | `󰒊 ` | `RenderMarkdownInfo` |

Requires the `status` field in the task interface contract (see above).

**Headers** — Match render-markdown.nvim per-level styling:
- Icons: `{ '󰲡 ', '󰲣 ', '󰲥 ', '󰲧 ', '󰲩 ', '󰲫 ' }` per level
- Foreground: `RenderMarkdownH{N}` (links to `@markup.heading.N.markdown`)
- Background: `RenderMarkdownH{N}Bg`
- Combined highlight groups computed at setup time:
  ```lua
  for level = 1, 6 do
    local fg = vim.api.nvim_get_hl(0, { name = "RenderMarkdownH" .. level, link = false })
    local bg = vim.api.nvim_get_hl(0, { name = "RenderMarkdownH" .. level .. "Bg", link = false })
    vim.api.nvim_set_hl(0, "VaultQueryH" .. level, { fg = fg.fg, bg = bg.bg })
  end
  ```
- Padded to window width for full-line background (since `hl_eol` doesn't apply to virtual lines)

**Paragraphs** — `Normal` highlight, word-wrap at window width (not hardcoded 80).

**Inline expressions** — Seamless replacement:
- `conceal=""` on the source expression span (`` `$=expr` ``)
- `virt_text` with `Normal` highlight for the result value
- No `│ result │` border characters

**Group headers** (for GROUP BY) — `RenderMarkdownLink` highlight (matches how Obsidian renders source file links in grouped results).

**Error results** — `DiagnosticError` highlight (unchanged, already correct).

#### 4. Highlight Group Cleanup

**Removed (no longer needed):**
- `VaultQueryBorder` — no wrapper box
- `VaultQuerySep` — table separators use render-markdown groups
- `VaultQueryHeader` — tables use `RenderMarkdownTableHead`
- `VaultQueryValue` — tables use `RenderMarkdownTableRow`, paragraphs use `Normal`
- `VaultQueryNull` — null values use `Comment` directly
- `VaultQueryGroupHeader` — replaced by `RenderMarkdownLink`
- `VaultQueryTaskDone` — replaced by `RenderMarkdownChecked`
- `VaultQueryTaskOpen` — replaced by `RenderMarkdownUnchecked`

**Added:**
- `VaultQueryH1` through `VaultQueryH6` — combined fg+bg from render-markdown heading groups (computed at setup)

**Kept:**
- `VaultQueryError` — links to `DiagnosticError`

**ColorScheme autocmd:** `setup_highlights()` registers a `ColorScheme` autocmd to recompute `VaultQueryH{N}` groups when the colorscheme changes.

#### 5. Function Signature Changes

```lua
-- render.lua (new signatures)
M.render(buf, open_line, close_line, results)    -- was: M.render(buf, line, results)
M.clear(buf, open_line, close_line)              -- was: M.clear(buf, line)
M.is_rendered(buf, open_line, close_line)         -- was: M.is_rendered(buf, line)

-- render.lua (new flow in M.render)
function M.render(buf, open_line, close_line, results)
  M.clear(buf, open_line, close_line)
  if not results or #results == 0 then return end

  -- Step 1: Collapse every line of the code block
  for i = open_line, close_line do
    vim.api.nvim_buf_set_extmark(buf, ns, i, 0, {
      conceal_lines = "",
      priority = 250,
    })
  end

  -- Step 2: Build content lines (NO wrapper box, render-markdown.nvim styling)
  local content_lines = {}
  for _, item in ipairs(results) do
    if item.group then
      content_lines[#content_lines + 1] = { { item.group, "RenderMarkdownLink" } }
    end
    local renderer = renderers[item.type]
    if renderer then
      for _, vl in ipairs(renderer(item)) do
        content_lines[#content_lines + 1] = vl
      end
    end
  end

  -- Step 3: Place virtual lines at open_line
  vim.api.nvim_buf_set_extmark(buf, ns, open_line, 0, {
    virt_lines = content_lines,
    virt_lines_above = false,
    virt_lines_leftcol = true,
    priority = 250,
  })
end
```

#### 6. Changes to `init.lua`

- Thread `open_line` through all render call paths (already available from `find_code_block_at_cursor()`)
- `render_all()` block collection stores `open_line` per block
- Inline render calls pass `start_col` for seamless concealment

#### Why Virtual Lines (Not Buffer Injection)

Buffer injection (writing real markdown into the buffer for render-markdown.nvim to style natively) was considered and rejected for speed/memory reasons:

| Factor | Virtual Lines | Buffer Injection |
|--------|--------------|-----------------|
| Buffer mutation | None | Yes (undo pollution, save risk) |
| Treesitter re-parse | None | ~5-20ms per injection |
| render-markdown re-render | None | ~10-50ms per injection |
| 13-query render_all() | ~2.6ms total | 13 * (inject + reparse + re-render) |
| Clear/toggle | Delete extmarks (instant) | Remove lines + reparse + re-render |
| Cursor position management | No impact | Line shifts on inject/remove |
| File save safety | Cannot save virtual lines | Must prevent saving injected content |

Virtual lines with manually-matched styling is a one-time implementation cost with zero ongoing runtime overhead. The visual result is indistinguishable from native render-markdown.nvim output.

---

## Project Structure

```
~/.config/nvim/
├── rust/
│   └── dataview-core/
│       ├── Cargo.toml
│       ├── build.rs                    # Post-build: copy .so to lua/
│       └── src/
│           ├── lib.rs                  # nvim-oxi entry point, exports Lua-callable functions
│           ├── index/
│           │   ├── mod.rs              # Index struct, page storage
│           │   ├── scanner.rs          # Parallel file scanning (walkdir + rayon)
│           │   ├── frontmatter.rs      # YAML frontmatter extraction (gray_matter)
│           │   ├── inline_fields.rs    # [key:: value] extraction from body
│           │   ├── tasks.rs            # Checkbox task parsing with inline metadata
│           │   ├── tags.rs             # Tag extraction (frontmatter + body #tags)
│           │   ├── wikilinks.rs        # Outlink extraction, inlink computation
│           │   └── watcher.rs          # File change detection (notify)
│           ├── parser/
│           │   ├── mod.rs
│           │   ├── lexer.rs            # DQL tokenizer
│           │   ├── ast.rs              # DQL AST types
│           │   └── dql.rs              # winnow parser combinators
│           ├── executor/
│           │   ├── mod.rs              # Query execution orchestrator
│           │   ├── eval.rs             # Expression evaluator
│           │   ├── functions.rs        # 60+ built-in functions
│           │   └── types.rs            # Date, Duration, Link, PageValue
│           ├── js/
│           │   ├── mod.rs              # DataviewJS execution via boa_engine
│           │   ├── runtime.rs          # boa_engine Context setup
│           │   └── api.rs              # dv.* API as native JS objects
│           ├── cache.rs                # LRU query result cache + parsed AST cache
│           └── output.rs               # RenderItem types → nvim-oxi Object conversion
│
└── lua/andrew/vault/query/
    ├── init.lua                        # REWRITTEN: loads Rust .so, orchestrates
    ├── render.lua                      # OVERHAULED: conceal_lines collapse + render-markdown.nvim-matched styling
    ├── parser.lua                      # DELETED (replaced by Rust)
    ├── executor.lua                    # DELETED (replaced by Rust)
    ├── index.lua                       # DELETED (replaced by Rust)
    ├── api.lua                         # DELETED (replaced by Rust)
    ├── types.lua                       # DELETED (replaced by Rust)
    └── js2lua.lua                      # DELETED (replaced by Rust)
```

---

## Critical Files

| File | Action | Purpose |
|------|--------|---------|
| `lua/andrew/vault/query/render.lua` | **OVERHAUL** | Obsidian-style rendering: `conceal_lines` collapse, remove wrapper box, render-markdown.nvim-matched styling |
| `lua/andrew/vault/query/init.lua` | **REWRITE** | Replace Lua calls with `require("dataview_core")` |
| `lua/andrew/vault/query/parser.lua` | **DELETE** | Replaced by Rust DQL parser |
| `lua/andrew/vault/query/executor.lua` | **DELETE** | Replaced by Rust executor |
| `lua/andrew/vault/query/index.lua` | **DELETE** | Replaced by Rust indexer |
| `lua/andrew/vault/query/api.lua` | **DELETE** | Replaced by Rust DataviewJS runtime |
| `lua/andrew/vault/query/types.lua` | **DELETE** | Replaced by Rust types |
| `lua/andrew/vault/query/js2lua.lua` | **DELETE** | Replaced by boa_engine (native JS execution) |

---

## Rust Crate Dependencies

```toml
[package]
name = "dataview-core"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
nvim-oxi = { version = "0.4", features = ["libuv"] }
winnow = "0.6"
gray_matter = "0.2"
serde = { version = "1", features = ["derive"] }
serde_yaml = "0.9"
walkdir = "2"
rayon = "1.10"
dashmap = "6"
notify = "7"
chrono = "0.4"
regex = "1"
parking_lot = "0.12"
lru = "0.12"
boa_engine = "0.19"
boa_gc = "0.19"
```

---

## Performance Architecture

### Performance Targets

| Metric | Lua (current) | Rust Target |
|--------|--------------|-------------|
| Vault index build (200+ files) | ~2-5s | <200ms |
| Single DQL query execution | ~200-500ms | <50ms |
| `render_all()` on Home.md (13 queries) | ~3-8s | <500ms |
| DataviewJS query execution | ~300-800ms | <100ms |
| Inline expression evaluation | ~100-200ms | <20ms |
| Memory footprint (index + caches) | ~50 MB | <30 MB |
| `.so` load + lazy init | N/A | <50ms |

### 1. Async Non-Blocking Indexing

**Problem:** `index_vault()` as a synchronous FFI call freezes Neovim for the full indexing duration.

**Solution:** Two-tier indexing via nvim-oxi's libuv integration:

```
Lua: core.ensure_index(vault_path, callback)
         │
         ▼
Rust: if cached index is fresh → return immediately
      if stale → return stale index + spawn background rebuild
      if no index → spawn background build, return empty
         │
         ▼ (background thread via libuv)
Rust: rayon parallel scan → atomic swap into DashMap
         │
         ▼ (libuv callback to main thread)
Lua: callback(true) → re-render if needed
```

**Exported functions:**
- `ensure_index(path) -> bool` — returns `true` if index is ready (fresh or stale-but-usable), `false` if building from scratch
- `rebuild_index_async(path, callback)` — triggers background rebuild, calls `callback` on completion
- `index_status() -> { ready: bool, age_ms: number, page_count: number }` — for diagnostics

**Staleness strategy:** Index is "fresh" if `age < watcher_debounce` (file watcher keeps it live). On explicit rebuild (`<leader>vqi`), spawn background thread and show "Rebuilding..." notification. Serve stale results during rebuild.

### 2. Query Batching

**Problem:** `render_all()` makes N sequential FFI calls for N code blocks, each with serialization overhead.

**Solution:** Batch endpoint that executes all queries in a single FFI call:

```rust
// Single FFI call for all queries in a buffer
fn execute_batch(
    queries: Vec<(String, String, String)>,  // (block_type, content, current_file)
    vault_path: String,
) -> Vec<Object>  // One result set per query
```

**Benefits:**
- Index loaded once, shared across all queries
- DQL ASTs parsed in parallel via rayon
- Single Lua→Rust→Lua round trip instead of N
- Results returned as a single Lua table of tables

**Lua side (`init.lua` `render_all()`):**
```lua
-- Collect all blocks first
local blocks = {}  -- { {type, content, open_line, close_line}, ... }
-- ... scan buffer for blocks ...
-- Single FFI call
local all_results = core.execute_batch(blocks, vault_path, current_file)
-- Render each result
for i, result in ipairs(all_results) do
  render.render(buf, blocks[i].open_line, blocks[i].close_line, result)
end
```

### 3. boa_engine Context Pooling

**Problem:** Creating a new boa_engine `Context` per `execute_js()` call costs ~50-100ms. With 23 DataviewJS queries, that's 1-2s of pure overhead.

**Solution:** Thread-local singleton Context with lazy initialization:

```rust
thread_local! {
    static JS_CONTEXT: RefCell<Option<Context>> = RefCell::new(None);
}

fn get_or_init_context() -> &Context {
    JS_CONTEXT.with(|ctx| {
        if ctx.borrow().is_none() {
            let mut context = Context::default();
            register_dv_api(&mut context);  // one-time setup
            *ctx.borrow_mut() = Some(context);
        }
        ctx.borrow().as_ref().unwrap()
    })
}
```

**Per-query cost after init:** Only the script compilation + execution (~5-10ms), not engine setup.

**Cache compiled scripts:** Store parsed JS ASTs in `HashMap<u64, CompiledScript>` keyed by content hash. Re-compilation only on content change.

### 4. Query Result Caching

**Problem:** Re-rendering unchanged queries wastes computation. 13 queries on Home.md re-execute even if vault hasn't changed.

**Solution:** LRU cache keyed on `(query_hash, index_version)`:

```rust
struct QueryCache {
    entries: LruCache<(u64, u64), Vec<RenderItem>>,  // (query_hash, index_version) -> results
    max_size_bytes: usize,
}
```

**Cache invalidation:**
- `index_version` is a monotonic counter incremented on every index update (file watcher or rebuild)
- Cache key includes `query_hash` (content hash of the code block)
- LRU eviction when cache exceeds `max_size_bytes` (default: 10 MB)
- Explicit invalidation via `clear_cache()` exposed to Lua

**Hit rate expectation:** ~90%+ on repeated `render_all()` calls when vault hasn't changed. Cache miss only on first render or after vault modification.

### 5. Progress Feedback

**Problem:** `render_all()` on a buffer with 13+ queries shows no feedback — user sees a frozen editor.

**Solution:** Progress notifications via Lua callback:

```lua
-- init.lua render_all() with progress
function M.render_all()
  local blocks = collect_blocks(buf)
  local total = #blocks
  vim.notify("Rendering " .. total .. " queries...", vim.log.levels.INFO)

  -- Batch execute (fast — single FFI call)
  local all_results = core.execute_batch(blocks, vault_path, current_file)

  -- Render results (Lua-side, sequential but fast)
  for i, result in ipairs(all_results) do
    render.render(buf, blocks[i].open_line, blocks[i].close_line, result)
  end

  vim.notify("Rendered " .. total .. " queries", vim.log.levels.INFO)
end
```

For long-running operations (index rebuild), use `vim.schedule()` callbacks:
```lua
core.rebuild_index_async(vault_path, function()
  vim.schedule(function()
    vim.notify("Index rebuilt — re-rendering...", vim.log.levels.INFO)
    M.render_all()
  end)
end)
```

### 6. Serialization Optimization

**Problem:** Converting Rust `Vec<RenderItem>` to Lua tables via nvim-oxi allocates per-row. Large tables (500+ rows) may be slow.

**Mitigation strategies:**
- **Result size limits:** DQL executor enforces a default `LIMIT 500` when no explicit LIMIT is set. Configurable via `core.set_default_limit(n)`.
- **Pre-allocated Lua tables:** Use `nvim_oxi::Array::with_capacity(n)` and `nvim_oxi::Dictionary::with_capacity(n)` to avoid reallocation.
- **Lazy field serialization:** Only serialize fields that `render.lua` actually reads (`type`, `headers`, `rows`, `items`, `text`, `group`, `message`, `level`, `tasks`, `completed`, `status`, `name`). Skip internal fields.
- **Benchmark gate:** Phase 2 includes a serialization benchmark. If 500-row tables take >50ms to serialize, implement streaming pagination.

### 7. Debouncing & Cancellation

**Problem:** Rapid re-triggers of `render_all()` or `render_block()` waste computation.

**Solution:**
- **Debounce `render_all()`:** 100ms debounce timer in Lua. If triggered again within 100ms, cancel previous and restart.
- **Query timeout:** `execute_batch()` accepts an optional `timeout_ms` parameter (default: 5000ms). If exceeded, returns partial results + error for timed-out queries.
- **Cancellation token:** Rust executor checks an `AtomicBool` flag between major operations (source resolution, filtering, sorting). Lua can set this flag to abort in-flight execution.

---

## Implementation Phases

### Phase 0: Rendering Overhaul (Pre-Rust, Lua-only)
**Goal:** Obsidian-style visual output using existing Lua engine — validates rendering before Rust migration adds complexity

This phase modifies only `render.lua` and `init.lua`. It can be tested immediately with the existing Lua query engine.

1. Change `M.render()` signature to `(buf, open_line, close_line, results)` — update `M.clear()` and `M.is_rendered()` signatures to match
2. Update all callers in `init.lua` to pass `open_line` (already available from `find_code_block_at_cursor()`)
3. Implement `conceal_lines=""` extmarks on code block lines (open_line through close_line inclusive)
4. Anchor virtual lines at `open_line` with `virt_lines_above = false` (output appears where block was)
5. **Remove `wrap_in_border()` entirely** — render items directly, no wrapper box
6. Rewrite `render_table()`: use render-markdown.nvim's round preset characters (`╭┬╮├┼┤╰┴╯│─`) with `RenderMarkdownTableHead` (header + top border + delimiter) and `RenderMarkdownTableRow` (data rows + bottom border)
7. Rewrite `render_list()`: use `●` icon with `RenderMarkdownBullet` highlight
8. Rewrite `render_task_list()`: use render-markdown.nvim checkbox icons per status (`󰄱`/`󰱒`/`󰔟`/`✘`/`󰒊`) with corresponding `RenderMarkdownUnchecked`/`Checked`/`Warn`/`Error`/`Info` highlights. Fall back to `completed` boolean if `status` field not present.
9. Rewrite `render_header()`: use per-level icons (`󰲡`..`󰲫`) with combined `VaultQueryH{N}` fg+bg highlights computed from render-markdown.nvim groups. Pad to window width for full-line background.
10. Rewrite `render_paragraph()`: use `Normal` highlight, word-wrap at window width
11. Rewrite `render_inline()`: conceal source expression span, place result as `virt_text` with `Normal` highlight (no `│` border characters)
12. Replace `setup_highlights()`: compute `VaultQueryH{N}` combined groups, register `ColorScheme` autocmd for recomputation, remove unused VaultQuery* groups
13. **Test:** Render `Home.md` queries → verify output visually matches render-markdown.nvim native tables/lists. Compare screenshots.
14. **Test:** Cursor on concealed line → verify source code reveals. Toggle/clear → verify code block reappears with render-markdown.nvim styling.

### Phase 1: Scaffold + Vault Indexer
**Goal:** Rust .so loads in Neovim, indexes vault in <200ms with async support

1. Create `rust/dataview-core/` with Cargo.toml
2. Implement `lib.rs` with nvim-oxi `#[nvim_oxi::plugin]` entry point
3. Implement `index/scanner.rs` — parallel directory walk with rayon
4. Implement `index/frontmatter.rs` — gray_matter YAML extraction
5. Implement `index/inline_fields.rs` — regex extraction of `[key:: value]`, `(key:: value)`, `key:: value`
6. Implement `index/tasks.rs` — checkbox parsing with `[due::]`, `[priority::]`, `[completion::]`
7. Implement `index/tags.rs` — frontmatter `tags:` + body `#tag` with hierarchy expansion
8. Implement `index/wikilinks.rs` — `[[path]]`, `[[path|display]]` extraction, inlink computation
9. Implement `index/mod.rs` — `Page` struct with `file.*` properties matching existing Lua schema:
   - `file.link`, `file.name`, `file.folder`, `file.path`, `file.tags`, `file.outlinks`, `file.tasks`, `file.mday`, `file.ctime`
10. Implement `output.rs` — convert Rust result types to nvim-oxi `Object` with pre-allocated tables
11. Implement async indexing: `ensure_index()` (sync fast path), `rebuild_index_async()` (background via libuv)
12. Implement `index_status()` for diagnostics (ready, age_ms, page_count)
13. Write `build.rs` to copy `.so` to `lua/dataview_core.so`
14. **Benchmark:** index build time for full vault, compare with Lua. Target: <200ms.
15. Test: compare Rust index output against Lua `index.lua` output

### Phase 2: DQL Parser + Basic Executor
**Goal:** `TABLE` and `LIST` queries work end-to-end in <50ms each

1. Implement `parser/lexer.rs` — tokenizer for DQL keywords, identifiers, strings, numbers, operators
2. Implement `parser/ast.rs` — AST types: Query, QueryType, Source, WhereClause, SortClause, GroupByClause, FlattenClause, LimitClause, Expression
3. Implement `parser/dql.rs` — winnow combinators for full DQL grammar:
   - `TABLE [WITHOUT ID] field [AS "alias"], ... FROM source WHERE expr SORT field ASC|DESC GROUP BY field FLATTEN field LIMIT n`
   - `LIST [WITHOUT ID] [expr] FROM source WHERE ...`
   - `TASK FROM source WHERE ...`
4. Implement `executor/types.rs` — Value enum: Null, Bool, Number, String, Date, Duration, Link, List, Object
5. Implement `executor/eval.rs` — expression evaluator: field access, arithmetic, comparison, boolean, contains, lambdas
6. Implement `executor/functions.rs` — start with 20 core functions: `contains`, `length`, `default`, `choice`, `date`, `dur`, `link`, `list`, `object`, `typeof`, `round`, `min`, `max`, `sum`, `sort`, `reverse`, `flat`, `join`, `split`, `regexmatch`
7. Implement `executor/mod.rs` — orchestrate: parse → resolve source → filter → sort → group → flatten → limit → format output
8. Implement parsed AST cache: `HashMap<u64, Arc<Query>>` keyed by content hash — parse once, execute many
9. Implement query result cache: `LruCache<(u64, u64), Vec<RenderItem>>` keyed by `(query_hash, index_version)`
10. Implement `execute_batch()` — single FFI call for multiple queries, parallel DQL parsing via rayon
11. Implement cancellation token: `AtomicBool` checked between major executor operations
12. Implement default `LIMIT 500` for queries without explicit LIMIT (configurable)
13. Export `execute_dql(query, vault_path, current_file) -> Object` and `execute_batch(queries) -> Vec<Object>`
14. **Benchmark:** serialization of 100/500/1000-row tables. Target: <50ms per query, <500ms for batch of 13.
15. Test: run all 89 DQL queries and compare with Lua output

### Phase 3: Remaining Built-in Functions + TASK Type
**Goal:** All 89 DQL queries pass, including TASK

1. Implement remaining ~40 built-in functions: `filter`, `map`, `any`, `all`, `none`, `nonnull`, `replace`, `regexreplace`, `lower`, `upper`, `trim`, `padleft`, `padright`, `substring`, `startswith`, `endswith`, `dateformat`, `localtime`, `striptime`, `meta`, `extract`, `reduce`, `unique`, `slice`, `number`, `string`, `elink`, `embed`, `truncate`, `foldername`
2. Implement `file.*` implicit fields fully (link rendering with display text)
3. Implement `this.file.*` for current file reference
4. Implement combined AND/OR source resolution
5. Handle `FROM ""` (all pages), `FROM #tag/subtag`, `FROM "folder" OR #tag`
6. TASK query type: return structured task groups by source file

### Phase 4: DataviewJS Engine (boa_engine)
**Goal:** All 23 DataviewJS queries work natively in <100ms each

1. Implement `js/runtime.rs` — thread-local singleton boa_engine `Context` with lazy initialization
   - Context created once on first `execute_js()` call, reused for all subsequent calls
   - `dv.*` API registered once during initialization
2. Implement compiled script cache: `HashMap<u64, CompiledScript>` keyed by content hash
   - Parse JS once per unique script, re-execute without re-parsing
3. Implement `js/api.rs` — expose to JS:
   - `dv.pages(source)` → returns PageArray (custom JS class with `.where()`, `.sort()`, `.filter()`, `.map()`, `.length`)
   - `dv.current()` → current file's Page object
   - `dv.date(string)` → Date object with `.plus()`, `.minus()`, comparisons
   - `dv.fileLink(path, embed, display)` → Link object
   - `dv.table(cols, rows)` → push TableResult to output
   - `dv.header(level, text)` → push HeaderResult to output
   - `dv.paragraph(text)` → push ParagraphResult to output
   - `dv.list(items)` → push ListResult to output
   - `dv.taskList(tasks)` → push TaskListResult to output
   - `dv.span(text)` → push ParagraphResult (alias used in inline queries)
4. Expose Page objects with full `file.*` properties as JS properties
5. Expose `file.tasks` as JS array with `.where()`, `.completed`, `.due`, `.priority`, `.text`
6. Support `new Map()`, `Array.from()`, `Math.round()`, `RegExp`, template literals
7. Export `execute_js(code: String, vault_path: String, current_file: String) -> Object`
8. **Benchmark:** Context init time, per-query time with warm Context, compiled script reuse speedup
9. Test: run all 23 DataviewJS queries and compare

### Phase 5: Inline Queries + File Watcher
**Goal:** Complete feature parity with Lua engine, live index updates

1. Export `execute_inline_js(expr: String, vault_path: String, current_file: String) -> String`
   - For `$=dv.pages().length` style inline expressions
2. Implement `index/watcher.rs` — `notify` crate watches vault directory
   - On file change: atomically update single Page in DashMap (insert/remove/replace)
   - Increment `index_version` counter on every update → invalidates query result cache
   - Debounce: batch file events within 200ms window before updating index
   - Expose `start_watcher(vault_path)` and `stop_watcher()` to Lua
3. Implement `index_version() -> u64` — monotonic counter, used as cache key component
4. Replace 30-second Lua cache: watcher keeps index live, no polling needed
5. Implement `mem_usage() -> { index_bytes, cache_bytes, js_context_bytes }` for diagnostics

### Phase 6: Integration + Migration
**Goal:** Swap Lua engine for Rust in production

**Note:** `render.lua` is already overhauled in Phase 0 — this phase only rewires `init.lua` to call Rust instead of Lua.

1. Rewrite `query/init.lua`:
   ```lua
   local core = require("dataview_core")
   local render = require("andrew.vault.query.render")

   -- core.ensure_index(path) replaces index_mod.Index.new(path):build_sync()
   -- core.execute_batch(queries) replaces N sequential parse+execute calls
   -- core.execute_dql(query, path, file) replaces parser.parse() + executor.execute()
   -- core.execute_js(code, path, file) replaces js2lua.transpile() + api.execute_block()
   -- core.execute_inline_js(expr, path, file) replaces js2lua + api inline
   -- core.rebuild_index_async(path, callback) replaces synchronous rebuild
   ```
2. Keep all user commands and keybindings (same interface)
3. `render.lua` already overhauled in Phase 0 — no further rendering changes needed
4. Add debouncing to `render_all()`: 100ms debounce timer, cancel previous if re-triggered
5. Add progress feedback: notify "Rendering N queries..." before batch, "Rendered N queries" after
6. Add async rebuild: `<leader>vqi` triggers `rebuild_index_async()` with callback to re-render
7. Start file watcher on first index load: `core.start_watcher(vault_path)`
8. Delete replaced Lua files: `parser.lua`, `executor.lua`, `index.lua`, `api.lua`, `types.lua`, `js2lua.lua`
9. Add lazy.nvim build step for automatic compilation

---

## Build Integration

In `lua/andrew/plugins/` (or wherever vault is loaded), add build configuration:

```lua
-- In init.lua or a plugin spec
vim.api.nvim_create_user_command("DataviewBuild", function()
  local handle = vim.system(
    { "cargo", "build", "--release" },
    { cwd = vim.fn.expand("~/.config/nvim/rust/dataview-core") }
  )
  handle:wait()
  -- Copy .so to lua path
  vim.fn.system("cp ~/.config/nvim/rust/dataview-core/target/release/libdataview_core.so ~/.config/nvim/lua/dataview_core.so")
end, {})
```

Or via `build.rs`:
```rust
fn main() {
    // Post-build: symlink .so to lua/ directory
    println!("cargo:rerun-if-changed=src/");
}
```

---

## Verification Plan

### Unit Tests (Rust)
- Parser tests: one test per DQL clause type
- Executor tests: one test per built-in function
- Index tests: test frontmatter/inline field/task/tag extraction against sample .md files
- Type tests: Date arithmetic, Duration parsing, Link resolution

### Integration Tests
- **Golden file tests**: Run each of the 112 queries through both Lua and Rust engines, compare JSON output
- Create a test harness that:
  1. Indexes the vault with Rust
  2. Executes each query
  3. Serializes results to JSON
  4. Compares with pre-captured Lua output

### Manual Testing

**Phase 0 (Rendering Overhaul — test with existing Lua engine):**
1. Open `Home.md` → `<leader>vqa` → verify all 13 query results render with render-markdown.nvim-matched styling
2. **Visual fidelity:** Compare a rendered TABLE query output with a hand-written markdown table in the same buffer — they should use identical characters, colors, and spacing
3. **Visual fidelity:** Compare rendered LIST output with a hand-written bullet list — same `●` icon, same highlight
4. **Concealment:**
   - Render a block → verify code fences and query source **collapse vertically** (no blank lines), only rendered output visible
   - Move cursor onto a collapsed line → verify Neovim reveals the source for editing
   - Move cursor away → verify source collapses again
   - Toggle with `<leader>vqq` → verify code block reappears with render-markdown.nvim styling
   - Clear all with `<leader>vqx` → verify all code blocks become visible again
   - Test with multiple adjacent code blocks — each should collapse/reveal independently
5. **Inline expressions:** Verify `$=expr` source text is concealed and replaced by result value inline (no `│` borders)
6. **Headers/Tasks:** Verify per-level heading icons/colors match render-markdown.nvim, checkbox icons match configured custom checkboxes

**Phase 1-6 (Rust engine — additional tests):**
7. Open `Home.md` → `<leader>vqa` → verify identical visual output as Lua engine
8. Open each Project Dashboard → verify task progress, simulation tables
9. Test `<leader>vqi` (rebuild index) timing vs. Lua
10. Verify file watcher: edit a note in another buffer, re-render queries to see updated data

### Performance Benchmarks
All benchmarks must meet targets defined in Performance Architecture section.

- **Index build:** Time `ensure_index()` for cold start and warm (cached) calls. Target: <200ms cold, <1ms warm.
- **Single query:** Time `execute_dql()` for simple (LIST FROM folder) and complex (TABLE with WHERE + SORT + GROUP BY). Target: <50ms.
- **Batch execution:** Time `execute_batch()` for Home.md's 13 queries. Target: <500ms total.
- **Cache hit:** Time `execute_batch()` on second call with no index changes. Target: <10ms (pure cache).
- **DataviewJS cold:** Time first `execute_js()` (includes Context init). Target: <150ms.
- **DataviewJS warm:** Time subsequent `execute_js()` with pooled Context. Target: <100ms.
- **Serialization:** Time conversion of 100/500/1000-row Rust results to Lua tables. Target: <50ms for 500 rows.
- **Memory:** Measure `mem_usage()` after full index + cache population. Target: <30 MB.
- **File watcher latency:** Time from file save to index update. Target: <500ms.
- **Async rebuild:** Verify Neovim remains responsive during `rebuild_index_async()` (no frame drops).

---

## Key Design Decisions

1. **boa_engine for DataviewJS** — Pure Rust JS engine. Handles arrow functions, Map/Set, Array methods, regex, template literals. No C dependencies. The 23 DataviewJS queries use a specific subset that boa_engine supports fully.

2. **Keep render.lua in Lua, overhaul for Obsidian-style output** — Extmark rendering is lightweight and tightly coupled to Neovim's Lua API. Moving it to Rust adds complexity with no performance benefit. The rendering layer uses `conceal_lines` (Neovim 0.11+) for vertical line collapse and manually replicates render-markdown.nvim's exact characters, icons, and highlight groups. This is a one-time implementation cost with zero ongoing runtime overhead — the visual result is indistinguishable from native render-markdown.nvim output. Buffer injection was rejected: it causes undo pollution, treesitter re-parse overhead, and file-save risks.

3. **DashMap for concurrent index** — The vault index is shared between the main thread (query execution) and background thread (file watcher). DashMap provides lock-free concurrent reads.

4. **winnow over pest** — Parser combinator approach allows incremental development and runtime flexibility. pest requires a separate grammar file and compile-time code generation.

5. **Shared `.so` in-process** — The Rust code runs in Neovim's process via nvim-oxi FFI. This means zero serialization overhead for returning query results (tables with hundreds of rows). The tradeoff is that a panic would crash Neovim, but nvim-oxi uses safe Rust throughout.

6. **Incremental migration** — Phase 1 can be tested independently (index only). Each phase adds capability while the Lua fallback remains available until Phase 6.

7. **Async-first indexing** — Indexing never blocks Neovim's event loop. `ensure_index()` returns immediately with a stale-but-usable index, while background rebuild completes via libuv. This is critical for perceived performance — the editor must never freeze.

8. **Batch FFI calls** — `execute_batch()` processes all queries in a single Lua→Rust→Lua round trip. This eliminates N-1 FFI call overhead and allows rayon to parallelize DQL parsing across queries within a single call.

9. **Multi-layer caching** — Three cache tiers: (1) parsed DQL AST cache (avoid re-parsing identical queries), (2) query result cache keyed on `(query_hash, index_version)` (avoid re-executing unchanged queries), (3) compiled JS script cache (avoid re-parsing identical DataviewJS blocks). Cache invalidation is precise: index version bump invalidates results but not parsed ASTs.

10. **boa_engine singleton** — JS Context initialization (~50-100ms) happens once per Neovim session, not per query. Thread-local `RefCell<Option<Context>>` pattern ensures zero contention.

11. **`conceal_lines` over `conceal=""`** — Character-level concealment (`conceal=""`) hides text but leaves lines occupying vertical space, producing blank gaps. `conceal_lines=""` (Neovim 0.11+) completely collapses lines from display, matching Obsidian's behavior. render-markdown.nvim already uses this for code block fences.

12. **No wrapper box** — The `╭─ Results ─╮` border was removed entirely. Obsidian renders query output as seamless document content with no visual container. Removing the wrapper and matching render-markdown.nvim's styling for each output type (tables, lists, tasks, headers) makes query output indistinguishable from hand-written markdown.

13. **Phase 0 before Rust** — The rendering overhaul is implemented first (Phase 0) using the existing Lua engine. This validates the visual approach independently of the Rust migration, reduces risk, and provides immediate visual improvement before any Rust code is written.

---

## Obsidian Vault Query Inventory (Reference)

### Query Statistics
- **Total Dataview queries**: 112
- **Standard DQL blocks**: 89
- **DataviewJS blocks**: 23
- **Inline JS queries**: 4
- **Files containing queries**: 31

### Query Types Used
| Query Type | Count | Primary Purpose |
|-----------|-------|-----------------|
| TABLE | 58 | Structured data display |
| DataviewJS | 23 | Complex logic, multi-source |
| LIST | 18 | Content navigation |
| TASK | 2 | Task management |
| Inline JS | 4 | Real-time statistics |

### DQL Features Required
- FROM: folder paths, tags (#tag/subtag), combined AND/OR, quoted strings
- WHERE: field access, comparison, boolean logic, contains(), function calls
- SORT: single/multi field, ASC/DESC
- GROUP BY: field grouping with render per-group
- FLATTEN: array expansion
- LIMIT: result count cap
- TABLE WITHOUT ID: suppress filename column
- Column aliases: `field AS "Display Name"`
- Link rendering: `link(file.link, display_text)`
- Image rendering: `("![|150](" + cover + ")")`

### DataviewJS API Surface Used
- `dv.pages(source)` with `.where()`, `.sort()`, `.filter()`, `.map()`, `.length`
- `dv.current()`, `dv.date("today")`, `dv.fileLink()`
- `dv.table()`, `dv.header()`, `dv.paragraph()`, `dv.list()`, `dv.span()`
- `file.tasks.where(t => t.completed)`, `file.folder`, `file.name`, `file.outlinks`
- `new Map()`, `Array.from()`, `Math.round()`, `RegExp`, template literals
- Date arithmetic: `.plus({days: 7})`, `.minus({days: 7})`, comparisons

### Frontmatter Fields (Load-Bearing)
- `type` — Primary filter in nearly every query (50+ exact matches)
- `status` — Workflow state with type-specific allowed values
- `tags` — YAML list, always present
- `parent-project` — Wiki-link reference: `'[[ProjectName/Dashboard]]'`
- `due`, `priority`, `date_completed`, `created`, `updated`
- `area`, `domain`, `frequency`, `next_due`, `category`, `deadline`, `target`

### Hardcoded Folder Paths in Queries
- `"Projects"`, `"Projects/[Name]/Simulations"`, `"Projects/[Name]/Tasks"`, etc.
- `"Areas"`, `"Areas/[Name]"`
- `"Domains"`, `"Library"`, `"Library/Books"`, `"Methods"`, `"Log"`

---

## Addendum: Speed + Low Memory Optimization

*Added after analysis focused on minimizing binary size and runtime memory.*

### Dependency Reduction: 15 → 5 Crates

| Dependency | Verdict | Replacement | Savings |
|-----------|---------|-------------|---------|
| `nvim-oxi` | **KEEP** | Non-negotiable FFI bridge | — |
| `walkdir` | **KEEP** | Tiny, handles symlinks/permissions | — |
| `rayon` | **KEEP** | Work-stealing threadpool for parallel scan | — |
| `parking_lot` | **KEEP** | Fast RwLock, tiny binary impact | — |
| `regex` | **KEEP** | Needed for inline fields + `regexmatch()` | — |
| `boa_engine + boa_gc` | **REPLACE** | Custom JS-subset interpreter (~1,500-2,000 lines) | **~10-20 MB binary, ~15-25 MB runtime** |
| `gray_matter + serde_yaml + serde` | **REPLACE** | Custom frontmatter parser (~200 lines, port from `index.lua`) | ~3 MB binary |
| `winnow` | **REPLACE** | Hand-written recursive descent (~400 lines, port from `parser.lua`) | ~200 KB |
| `chrono` | **REPLACE** | Custom Date/Duration types (~150 lines, port from `types.lua`) | ~500 KB |
| `dashmap` | **REPLACE** | `parking_lot::RwLock<VaultIndex>` (read-heavy, 200 entries) | ~100 KB + simpler |
| `notify` | **REMOVE** | Lua `BufWritePost` autocmd + optional `vim.uv.fs_event` | ~2 MB |
| `lru` | **REPLACE** | HashMap + timestamp eviction (~30 lines) | 1 fewer dep |

### Revised Cargo.toml

```toml
[dependencies]
nvim-oxi = { version = "0.4", features = ["libuv"] }
walkdir = "2"
rayon = "1.10"
parking_lot = "0.12"
regex = "1"

[profile.release]
opt-level = "s"
lto = true
codegen-units = 1
strip = true
panic = "abort"
```

### The Big Win: Custom JS-Subset Interpreter (Replaces boa_engine)

The 23 DataviewJS queries use a **narrow JS subset**: arrow functions, template literals, `.where()/.sort()/.map()` chains, `dv.*` API, `new Map()`, `Array.from()`, `Math.round()`, `RegExp`. They do **not** use: prototypal inheritance, `this` binding, generators, async/await, classes, Proxy, Symbol.

| Factor | boa_engine | Custom Interpreter |
|--------|-----------|-------------------|
| Init time | ~50-100ms | **<1ms** |
| Per-query time | ~5-10ms (compiled) | **~2-5ms** |
| Memory | ~15-25 MB (Context + GC) | **~0 MB additional** |
| Binary size | ~8-15 MB | **~50-100 KB** |
| Lines of code | ~200K (dependency) | **~1,500-2,000 (owned)** |

The existing `js2lua.lua` (2,615 lines) is a working tokenizer + grammar definition for the exact subset — it serves as the specification.

### Memory-Efficient Index Architecture

Replace `DashMap<String, Page>` with:

```rust
struct VaultIndex {
    pages: Vec<Page>,                           // arena: pages[PageId]
    path_to_id: HashMap<CompactString, PageId>,
    name_to_id: HashMap<CompactString, PageId>,
    strings: StringInterner,                     // intern repeated tags, folders, field names
    version: AtomicU64,                          // cache invalidation counter
}

type PageId = u32;
```

Key optimizations:
- **String interning** for tags, folder paths, field names (~50-70% string memory reduction)
- **`SmallVec<[(SymbolId, Value); 8]>`** for frontmatter fields (most pages have 4-8 fields, avoids HashMap overhead)
- **`RwLock`** instead of DashMap (200 entries don't benefit from sharding)
- **`u64` timestamps** instead of Date objects for `mtime`/`ctime`

### File Watcher: Use Neovim's Built-in Event Loop

Instead of the `notify` crate (separate inotify thread, ~2 MB binary), use Lua-side `BufWritePost` autocmd to trigger `core.reindex_file(path)` on vault `.md` saves. Catches all in-Neovim edits. External edits handled by manual rebuild (`<leader>vqi`).

### "Build From Scratch" Summary

| Component | Custom Lines of Rust | What It Replaces |
|-----------|---------------------|-----------------|
| JS-subset interpreter | ~1,500-2,000 | boa_engine + boa_gc (~200K lines of deps) |
| Frontmatter parser | ~200 | gray_matter + serde_yaml + serde |
| DQL recursive descent parser | ~400 | winnow |
| Date/Duration types | ~150 | chrono |
| Cache with timestamp eviction | ~30 | lru |
| **Total** | **~2,300 lines** | **~16-26 MB of dependency weight** |

### Revised Performance Targets

| Metric | Original Target | Revised Target |
|--------|----------------|---------------|
| `.so` file size | unspecified | **<4 MB** |
| Runtime memory (index + caches) | <30 MB | **<8 MB** |
| `.so` load + init | <50ms | **<10ms** |
| DataviewJS cold | <150ms | **<20ms** |
| DataviewJS warm | <100ms | **<5ms** |
| Vault index build | <200ms | **<100ms** |
| Compile time (release) | unspecified | **<60s** |

### Rendering Caveat: CursorMoved Autocmd

`conceal_lines` does **not** auto-reveal when the cursor lands on the line (unlike character-level `conceal`). Phase 0 should add a thin `CursorMoved` autocmd that unconceals the block when cursor is within `[open_line, close_line]` and re-conceals when cursor leaves, providing Obsidian's "click to edit" UX.
