# Vault Architecture Document

## Problem Statement

The vault plugin spans 55+ Lua modules across `lua/andrew/vault/` and its
subdirectories (`query/`, `templates/`). There is no unified document describing
how modules relate, what layer each module occupies, or how data flows from raw
`.md` files on disk through the index into user-facing features.

Contributors (including future-you) face several pain points:

1. **No entry-point map.** `init.lua` loads 40+ modules in sequence, but
   nothing explains *why* they are ordered that way or which modules depend on
   which.

2. **Implicit coupling.** Many modules call `engine.get_name_cache()`,
   `wikilinks.resolve_link()`, or `vault_index.current()`, but the dependency
   direction is only discoverable by reading source code.

3. **Layer ambiguity.** Some modules are pure data (slug, link_utils), some are
   infrastructure (engine, vault_index), some are UI features (graph, preview),
   and some bridge multiple layers (completion, linkdiag). Without explicit
   categorization, new features get bolted on in the wrong layer.

4. **42 improvement docs but no overview.** The `improvements/completed/`
   directory contains detailed per-feature design documents. Reading them all
   gives a fragmented view; nothing ties them together into a coherent whole.

## Proposed Document Structure

The architecture document should live at a well-known location and cover the
following sections. This improvement document itself serves as that architecture
overview.

```
1.  Module Inventory          -- Every .lua file with a one-line description
2.  Layer Architecture        -- Core / Indexing / Features / UI / Templates
3.  Module Dependency Map     -- ASCII diagram of require() relationships
4.  Data Flow                 -- File -> Index -> Features -> UI pipeline
5.  Init Lifecycle            -- Boot sequence from init.lua through to ready
6.  Cache & Invalidation      -- Central registry, fs watcher, event chain
7.  Key Abstractions          -- vault_index, engine, config, link_utils, pickers
8.  External Dependencies     -- fzf-lua, snacks.nvim, ripgrep, fd, blink-cmp
9.  Command & Keymap Index    -- Quick reference for all :Vault* commands
```

## Layer Architecture

The vault plugin is organized into five layers. Each layer may only depend on
layers below it (never above). Within a layer, modules should minimize cross-
dependencies.

```
+=========================================================================+
|                          LAYER 5: TEMPLATES                             |
|  templates/init.lua, templates/*.lua (22 template modules)              |
|  Stateless note generators. Depend on engine for I/O and pickers for    |
|  interactive selection. No side effects at require() time.              |
+=========================================================================+
|                          LAYER 4: UI FEATURES                           |
|  graph.lua, graph_filter.lua, preview.lua, embed.lua, calendar.lua,    |
|  breadcrumbs.lua, outline.lua, ui.lua                                   |
|  Visual displays (floating windows, extmarks, virtual text). Depend on  |
|  features layer for data and engine for vault path/IO.                  |
+=========================================================================+
|                          LAYER 3: FEATURES                              |
|  wikilinks.lua, backlinks.lua, search.lua, tags.lua, tasks.lua,        |
|  connections.lua, linkdiag.lua, linkcheck.lua, autolink.lua,            |
|  unlinked.lua, rename.lua, extract.lua, capture.lua, quicktask.lua,    |
|  images.lua, pins.lua, recent.lua, frecency.lua, export.lua,           |
|  navigate.lua, frontmatter.lua, frontmatter_editor.lua, metaedit.lua,  |
|  fragments.lua, saved_searches.lua, blockid.lua, autofile.lua,         |
|  autosave.lua, footnotes.lua, recurrence.lua,                          |
|  wikilink_highlights.lua, tag_highlights.lua, inline_fields.lua,       |
|  highlights.lua, callout_folds.lua,                                     |
|  completion.lua, completion_base.lua, completion_tags.lua,              |
|  completion_frontmatter.lua, completion_spell.lua,                      |
|  query/init.lua, query/index.lua, query/parser.lua,                    |
|  query/executor.lua, query/api.lua, query/render.lua, query/js2lua.lua,|
|  query/types.lua                                                        |
|  Vault-wide operations. Consume the index and engine. Each module       |
|  registers commands, keymaps, and/or caches during setup().             |
+=========================================================================+
|                          LAYER 2: INDEXING                              |
|  vault_index.lua                                                        |
|  Persistent singleton index. Single source of truth for all vault       |
|  metadata. Zero internal requires (uses only slug.lua). Provides        |
|  name/alias resolution, heading/tag/link lookups, change detection.     |
+=========================================================================+
|                          LAYER 1: CORE                                  |
|  engine.lua, config.lua, link_utils.lua, slug.lua,                     |
|  frontmatter_parser.lua, pickers.lua, ui.lua                           |
|  Foundational utilities. engine.lua owns the vault path, cache          |
|  registry, coroutine runner, file I/O, fs watcher, and template        |
|  variable substitution. config.lua is the single configuration source.  |
|  link_utils.lua and slug.lua provide pure parsing functions.            |
+=========================================================================+
|                          LAYER 0: ENTRY POINT                           |
|  init.lua                                                               |
|  Loads all modules in dependency order. Registers global autocmds for   |
|  cache invalidation and fs watching. Manages vault index lifecycle.     |
+=========================================================================+
```

## Module Dependency Map

The ASCII diagram below shows the primary `require()` relationships between
modules. Arrows point from the dependent module to its dependency. Transitive
dependencies (e.g., everything depends on config via engine) are omitted for
clarity.

```
                              init.lua
                                 |
          +----------+-----------+------------+-----------+
          |          |           |            |           |
       engine    templates   wikilinks    query/init   (40+ feature
          |        /    \       |   \        |    \      modules)
          |    engine  pickers  |  vault_    |   query/
          |       |      |     |  index   index  parser
          |       v      v     |    |       |   executor
          |    config  config  |    |       |   api
          |                    |    |       |   render
          |             link_utils  |       |   js2lua
          |                |       slug     |   types
          |                v                |
          |              slug               |
          |                                 |
          +-----------+---------------------+
                      |
                   config.lua

Core dependency chains:

  slug.lua           (zero deps - leaf node)
      ^
      |
  link_utils.lua     (depends on: slug)
      ^
      |
  vault_index.lua    (depends on: slug)
      ^
      |
  frontmatter_parser.lua  (depends on: config)
      ^
      |
  engine.lua         (depends on: config, vault_index [lazy])
      ^      ^
      |      |
  wikilinks.lua      (depends on: engine, config, link_utils, vault_index)
      ^
      |
  embed.lua          (depends on: engine, wikilinks, config, link_utils)
  preview.lua        (depends on: engine, config, link_utils, wikilinks)
  graph.lua          (depends on: engine, link_utils, wikilinks, ui)
  backlinks.lua      (depends on: engine, wikilinks)
  tags.lua           (depends on: engine, vault_index)
  connections.lua    (depends on: engine, config, vault_index, query/index)
  linkdiag.lua       (depends on: engine, link_utils, vault_index)
  completion.lua     (depends on: completion_base, engine, vault_index, fm_parser)
  query/init.lua     (depends on: engine, query/*, vault_index)
  query/index.lua    (depends on: query/types, vault_index)
```

### Circular Dependency Prevention

`vault_index.lua` has **zero requires** at the module level. It only depends on
`slug.lua`. This is a deliberate design choice to prevent circular dependency
chains (engine -> vault_index -> engine). Engine accesses vault_index lazily
through `package.loaded["andrew.vault.vault_index"]` checks.

## Data Flow

Data flows through the system in a pipeline from raw files on disk to
user-visible features:

```
  .md files on disk
       |
       | (1) fs_event / BufWritePost / FocusGained / startup
       v
  +-------------------+
  |  Change Detection  |  vault_index.lua: mtime + size comparison
  |  (incremental)     |  Identifies new / modified / deleted files
  +--------+----------+
           |
           | changed file list
           v
  +-------------------+
  |  Single-Pass       |  vault_index.lua: _parse_file()
  |  Parser            |  Extracts: frontmatter, aliases, tags, headings,
  |                    |  block_ids, outlinks, tasks, inline_fields
  +--------+----------+
           |
           | VaultIndexEntry per file
           v
  +-------------------+
  |  Vault Index       |  vault_index.lua: in-memory singleton
  |  (in-memory)       |  Derived indexes: _name_index, _alias_index, _inlinks
  |                    |  Persisted to .vault-index/index.json
  +--------+----------+
           |
     +-----+------+------+------+------+
     |     |      |      |      |      |
     v     v      v      v      v      v
  names  links  tags  headings  fm   tasks
     |     |      |      |      |      |
     v     v      v      v      v      v
  wikilinks  query   linkdiag  completion
  autolink   connections      wikilink_hl
  linkcheck  graph            tags
  unlinked   backlinks        frontmatter
  rename     embed            metaedit
```

### Read Path (feature consuming index data)

1. Feature module calls `vault_index.current()` to get the singleton.
2. If `idx:is_ready()`, reads from the in-memory data structures directly.
3. No disk I/O, no subprocess spawning, no cache TTL checks.
4. Example: `tags.lua` calls `idx:all_tags()` -- iterates `idx.files[*].tags`.

### Write Path (file change -> index update)

1. `BufWritePost` fires for a vault `.md` file.
2. `init.lua`'s unified `VaultCacheInvalidation` augroup calls
   `engine.invalidate_caches({ scope = "file", path = bufpath })`.
3. Engine iterates the `_cache_registry` and calls `invalidate_file(path)` on
   each registered cache.
4. Engine also propagates to `vault_index:update_file(path)` -- single-file
   re-parse, derived index rebuild, debounced persist.
5. Vault index increments `_generation`, notifying subscribers.
6. Downstream modules that track `_generation` (e.g., `query/init.lua`,
   `connections.lua`) detect staleness on their next access and rebuild their
   view of the data.

### External Change Path (fs watcher)

1. `engine.start_fs_watcher()` creates a `vim.uv.new_fs_event()` on the vault
   root with `{ recursive = true }`.
2. On `.md` file change, debounces 500ms, then:
   - Calls `vault_index:update_file(abs_path)` for targeted updates.
   - Falls back to `vault_index:build_async()` if the filename is unknown.
   - Fires `engine.invalidate_caches({ scope = "all" })` for backward compat.

## Init Lifecycle

The boot sequence runs when `lua/andrew/vault/init.lua` is loaded (typically
during Neovim startup via lazy.nvim plugin config):

```
 1. require("andrew.vault.init")
 2.   require("andrew.vault.engine")        -- Core utilities, vault path, cache registry
 3.   require("andrew.vault.pickers")       -- Project/area/domain pickers
 4.   require("andrew.vault.templates")     -- Template registry (22 templates)
 5.
 6.   -- Load feature modules (each calls .setup()):
 7.   require("andrew.vault.query")         -- Query system (dataview/vault blocks)
 8.   require("andrew.vault.wikilinks")     -- gf navigation, link resolution
 9.   require("andrew.vault.backlinks")     -- Backlink/forward link pickers
10.   require("andrew.vault.navigate")      -- Daily/weekly log navigation
11.   require("andrew.vault.search")        -- Vault-wide grep
12.   require("andrew.vault.outline")       -- Heading outline picker
13.   require("andrew.vault.tags")          -- Tag browsing and bulk operations
14.   require("andrew.vault.frontmatter")   -- Auto-update modified timestamp
15.   require("andrew.vault.linkcheck")     -- :VaultLinkCheckAll
16.   require("andrew.vault.footnotes")     -- Footnote navigation
17.   require("andrew.vault.extract")       -- Extract selection to new note
18.   require("andrew.vault.rename")        -- Rename note with link updates
19.   require("andrew.vault.frecency")      -- Frecency tracking
20.   require("andrew.vault.recent")        -- Recent notes picker
21.   pickers.setup()                       -- Project picker command/keymap
22.   require("andrew.vault.export")        -- Pandoc export
23.   require("andrew.vault.tasks")         -- Task aggregation pickers
24.   require("andrew.vault.capture")       -- Quick capture
25.   require("andrew.vault.preview")       -- Floating preview (K key)
26.   require("andrew.vault.images")        -- Clipboard image paste
27.   require("andrew.vault.pins")          -- Pinned/starred notes
28.   require("andrew.vault.embed")         -- Transclusion rendering
29.   require("andrew.vault.graph")         -- Local graph view
30.   require("andrew.vault.connections")   -- Smart related notes
31.   require("andrew.vault.fragments")     -- Template fragment insertion
32.   require("andrew.vault.metaedit")      -- MetaEdit frontmatter toggling
33.   require("andrew.vault.frontmatter_editor") -- Frontmatter editor float
34.   require("andrew.vault.quicktask")     -- Quick task capture
35.   require("andrew.vault.breadcrumbs")   -- Breadcrumb winbar
36.   require("andrew.vault.autofile")      -- Auto-file by type
37.   require("andrew.vault.linkdiag")      -- Real-time link diagnostics
38.   require("andrew.vault.wikilink_highlights") -- Resolution-aware link colors
39.   require("andrew.vault.blockid")       -- Block ID generation
40.   require("andrew.vault.saved_searches") -- Saved/pinned searches
41.   require("andrew.vault.tag_highlights") -- Inline tag highlighting
42.   require("andrew.vault.autolink")      -- Auto-link suggestions
43.   require("andrew.vault.inline_fields") -- Inline field highlighting
44.   require("andrew.vault.callout_folds") -- Callout fold persistence
45.   require("andrew.vault.unlinked")      -- Unlinked mentions scanner
46.   require("andrew.vault.highlights")    -- ==highlight== mark rendering
47.   require("andrew.vault.autosave")      -- Auto-save on focus loss
48.
49.   -- Register unified cache invalidation autocmds:
50.   --   BufWritePost *.md, FileChangedShellPost *.md, BufDelete *.md,
51.   --   FocusGained (200ms debounce)
52.
53.   -- Start filesystem watcher
54.   engine.start_fs_watcher()
55.
56.   -- Vault index lifecycle:
57.   --   vault_index.get(engine.vault_path)
58.   --   idx:load()          -- Load persisted index (instant if file exists)
59.   --   idx:build_async()   -- Incremental diff in background coroutine
60.   --   VimLeavePre -> idx:persist_now()
61.
62.   -- Pre-warm name cache on first BufReadPost *.md (100ms deferred):
63.   --   engine.prebuild_name_cache_async()
```

### Startup Timeline

```
t=0ms     init.lua loaded, engine.lua sets vault_path
t=0-5ms   All feature modules require()'d and setup() called
          (registers commands, keymaps, autocmds -- no heavy work)
t=5ms     fs watcher started
t=5ms     vault_index.load() reads persisted JSON (if exists)
          -> Index immediately ready with potentially stale data
t=5ms     vault_index.build_async() begins background coroutine
          -> Walks filesystem, compares mtimes, re-parses changed files
          -> Yields after each batch of 20 files
t=~100ms  First BufReadPost triggers prebuild_name_cache_async()
t=~150ms  First embed render (deferred 150ms from BufReadPost)
t=~200ms  Async index build completes (500-file vault, ~20 batches)
          -> Index fully up to date, _generation incremented
          -> Debounced persist scheduled (5s)
```

## Cache and Invalidation Architecture

### Central Cache Registry

`engine.lua` maintains a `_cache_registry` table. Each feature module that
maintains local state registers a `CacheSpec` during its `setup()` call:

```lua
engine.register_cache({
  name = "connections",            -- unique identifier
  module = "andrew.vault.connections",
  invalidate = function() ... end,           -- full reset
  invalidate_file = function(path) ... end,  -- per-file update (optional)
  stats = function() return { ... } end,     -- for :VaultCacheStatus
})
```

**Registered caches (as of current code):**
`name_cache`, `wikilinks`, `tags`, `heading_cache`, `connections`,
`completions`, `query_index`, `callout_folds`, `autolink`

### Invalidation Triggers

| Event                 | Scope    | What happens                                    |
|-----------------------|----------|-------------------------------------------------|
| `BufWritePost *.md`  | file     | `invalidate_file(path)` on each cache; `vault_index:update_file(path)` |
| `FileChangedShellPost`| file    | Same as BufWritePost                            |
| `BufDelete *.md`     | file     | Same as BufWritePost                            |
| `FocusGained`        | all      | 200ms debounce, then full invalidation + `vault_index:build_async()` |
| fs_event (`.md`)     | file/all | 500ms debounce, then targeted or full rebuild   |
| Vault switch          | all     | Full invalidation + restart fs watcher          |
| User autocmd          | all     | `User VaultCacheInvalidate` fires after each invalidation |

### Generation-Based Staleness Detection

The vault index maintains a monotonically increasing `_generation` counter.
Downstream modules like `query/init.lua` and `connections.lua` store the
generation they last consumed. On their next access, they compare against the
current generation -- if it differs, they rebuild their derived view from the
index.

This replaces the old TTL-based invalidation pattern where caches would expire
by wall-clock time regardless of whether anything had changed.

## Key Abstractions

### vault_index (Singleton Persistent Index)

- **File:** `lua/andrew/vault/vault_index.lua`
- **Pattern:** Singleton via `vault_index.get(vault_path)` /
  `vault_index.current()`
- **Persistence:** `{vault_path}/.vault-index/index.json`
- **Change detection:** mtime + size comparison on each file
- **Background processing:** Coroutine-based async build, yields every 20 files
- **Key API:**
  - `resolve_name(name)` -- case-insensitive name + alias resolution -> paths
  - `get_name_cache()` -- `{ names, paths }` compatible with old engine cache
  - `all_tags()` -- sorted unique tag list across vault
  - `get_headings(filepath)` -- slug set + heading list for a file
  - `update_file(abs_path)` -- single-file incremental update
  - `build_async()` -- full incremental rebuild in background
  - `subscribe(fn)` -- get notified on index updates

### engine (Core Utilities)

- **File:** `lua/andrew/vault/engine.lua`
- **Responsibilities:**
  - Vault path management and multi-vault switching
  - Cache registry and invalidation orchestration
  - Filesystem watcher (`vim.uv.new_fs_event`)
  - Coroutine-wrapped `vim.ui.input` / `vim.ui.select`
  - Template variable substitution (Obsidian-compatible `{{var}}` syntax)
  - File I/O helpers (`read_file`, `write_file`, `write_note`)
  - `fd`/`find` file enumeration (fallback when index unavailable)
  - fzf-lua option/action builders
  - JSON store for persistent per-vault data

### config (Centralized Configuration)

- **File:** `lua/andrew/vault/config.lua`
- **Pattern:** Module-level table with nested sections
- **Sections:** `dirs`, `frontmatter`, `task_states`, `note_types`, `preview`,
  `embed`, `template_vars`, `wikilink_highlights`, `tag_highlights`, `autolink`,
  `inline_fields`, `highlight_marks`, `callout_folds`, `autosave`,
  `temporal_aliases`, `query`, `connections`, `index`, `graph`, `scopes`,
  canonical field values (`status_values`, `priority_values`, `maturity_values`)

### link_utils (Pure Parsing)

- **File:** `lua/andrew/vault/link_utils.lua`
- **Pattern:** Stateless pure functions, no side effects
- **Key functions:**
  - `parse_target(inner)` -- parse `[[inner]]` into `{name, heading, block_id, alias}`
  - `heading_to_slug(text)` -- delegated to `slug.lua`
  - `get_wikilink_under_cursor()` -- find and parse wikilink at cursor position
  - `read_heading_section(source, heading)` -- extract heading content
  - `read_block_content(source, block_id)` -- extract block paragraph
  - `extract_headings(source)` -- slug set + heading text list

### pickers (Interactive Selection)

- **File:** `lua/andrew/vault/pickers.lua`
- **Pattern:** Coroutine-based pickers using `engine.select()`
- **Provides:** `project()`, `project_or_none()`, `area()`, `domain()` pickers
- **Also:** Sticky project tracking (auto-detected from buffer path)

## External Dependencies

| Dependency        | Used By                                   | Purpose                            |
|-------------------|-------------------------------------------|------------------------------------|
| `fzf-lua`         | search, tags, backlinks, pickers, graph,  | Fuzzy picker UI for all list-based |
|                   | connections, linkdiag, navigate, tasks,   | interactions                       |
|                   | recent, saved_searches, outline, export   |                                    |
| `snacks.nvim`     | embed.lua                                 | Kitty inline image rendering       |
| `blink-cmp`       | completion.lua, completion_base.lua,      | Completion framework (wikilink,    |
|                   | completion_tags.lua, completion_fm.lua,   | tag, frontmatter, spell sources)   |
|                   | completion_spell.lua                      |                                    |
| `ripgrep` (rg)    | search, backlinks, tags, graph, navigate, | Content search, pattern matching   |
|                   | linkcheck, unlinked                       |                                    |
| `fd` / `fdfind`   | engine.lua (fallback file enumeration)    | Fast file listing when index       |
|                   |                                           | is not yet ready                   |
| `render-markdown` | preview.lua                               | Markdown rendering in float        |
| `pandoc`          | export.lua                                | Document export (PDF, DOCX, etc.)  |
| `imagemagick`     | embed.lua (via snacks)                    | Image format conversion            |

## Files to Document: Complete Module Inventory

### Layer 0: Entry Point

| File | Description |
|------|-------------|
| `init.lua` | Entry point: loads all modules, registers global autocmds, manages vault index lifecycle |

### Layer 1: Core

| File | Description |
|------|-------------|
| `engine.lua` | Central utilities: vault path, cache registry, fs watcher, coroutine runner, file I/O, template substitution |
| `config.lua` | Centralized configuration for all vault modules (dirs, limits, feature toggles) |
| `link_utils.lua` | Pure wikilink parsing: `parse_target`, cursor detection, heading/block extraction |
| `slug.lua` | Zero-dependency heading-to-slug conversion for anchor matching |
| `frontmatter_parser.lua` | YAML frontmatter parser: field extraction, type coercion, list/scalar handling |
| `pickers.lua` | Interactive project/area/domain pickers with sticky project tracking |
| `ui.lua` | Shared floating window helpers: `create_float_input`, `create_float_display` |

### Layer 2: Indexing

| File | Description |
|------|-------------|
| `vault_index.lua` | Persistent singleton index: single-pass parser, mtime change detection, async build, name/alias/tag resolution |

### Layer 3: Features -- Navigation

| File | Description |
|------|-------------|
| `wikilinks.lua` | Wikilink resolution (`resolve_link`), `gf`/`gx` navigation, temporal aliases, link jumping |
| `backlinks.lua` | Backlink and forward-link pickers via `rg` search |
| `navigate.lua` | Daily log prev/next/today, weekly/monthly/quarterly/yearly review navigation |
| `footnotes.lua` | Footnote definition jumping (`gd` on `[^ref]`) |

### Layer 3: Features -- Search & Discovery

| File | Description |
|------|-------------|
| `search.lua` | Vault-wide live grep with scope filtering and type filtering |
| `tags.lua` | Tag browsing, bulk add/remove, vault-wide tag collection from index |
| `outline.lua` | Buffer heading outline picker via fzf-lua |
| `connections.lua` | Smart related notes: multi-signal scoring (tags, frontmatter, co-links, proximity, temporal) |
| `unlinked.lua` | Unlinked mention scanner: finds note name occurrences not wrapped in `[[]]` |
| `saved_searches.lua` | Persistent saved/pinned searches with quick-access picker |
| `recent.lua` | Recently-opened vault notes picker (frecency-backed) |
| `frecency.lua` | Frecency tracking: access count + recency decay, persisted to JSON |

### Layer 3: Features -- Link Health

| File | Description |
|------|-------------|
| `linkdiag.lua` | Real-time link diagnostics: broken note/heading detection, edit-distance suggestions, code actions |
| `linkcheck.lua` | Vault-wide batch link validation command |
| `autolink.lua` | Auto-link suggestions: highlights unlinked text matching note names |
| `wikilink_highlights.lua` | Resolution-aware wikilink coloring (valid, broken, self-ref, heading valid/broken, alias) |

### Layer 3: Features -- Editing

| File | Description |
|------|-------------|
| `frontmatter.lua` | Auto-updates `modified` timestamp in frontmatter on `BufWritePre` |
| `frontmatter_editor.lua` | Interactive frontmatter editor in a floating window |
| `metaedit.lua` | MetaEdit-style frontmatter field toggling (status, priority, tags) |
| `extract.lua` | Extract visual selection to a new note with automatic wikilink |
| `rename.lua` | Rename note with vault-wide link reference updates |
| `capture.lua` | Quick capture: append text to inbox or specified note |
| `quicktask.lua` | Quick task capture: add `- [ ] task` to a target note |
| `blockid.lua` | Block ID generation: `^blk-XXXXXX` appended to current line/paragraph |
| `images.lua` | Clipboard image paste to `attachments/` directory |
| `fragments.lua` | Template fragment insertion (reusable snippets) |
| `autofile.lua` | Auto-file new notes by frontmatter type to configured directories |
| `recurrence.lua` | Task recurrence helper (date arithmetic for recurring tasks) |

### Layer 3: Features -- Highlighting & Rendering

| File | Description |
|------|-------------|
| `tag_highlights.lua` | Inline `#tag` highlighting with category-based colors |
| `inline_fields.lua` | `key:: value` inline field highlighting |
| `highlights.lua` | `==highlighted text==` mark rendering via extmarks |
| `callout_folds.lua` | Persistent fold state for callout blocks |
| `autosave.lua` | Auto-save vault buffers on focus loss / buffer leave |

### Layer 3: Features -- Completion

| File | Description |
|------|-------------|
| `completion.lua` | blink-cmp source: wikilink note names, aliases, headings, block IDs |
| `completion_base.lua` | Shared completion source factory with cache management |
| `completion_tags.lua` | blink-cmp source: `#tag` completion from vault index |
| `completion_frontmatter.lua` | blink-cmp source: frontmatter field values (status, priority, etc.) |
| `completion_spell.lua` | blink-cmp source: spell suggestions for vault context |

### Layer 3: Features -- Query System

| File | Description |
|------|-------------|
| `query/init.lua` | Query orchestrator: finds code blocks, dispatches to parser/executor, renders output |
| `query/index.lua` | Query index: builds page objects from vault_index entries for dataview queries |
| `query/parser.lua` | DQL parser: tokenizer + recursive descent for `TABLE`/`LIST`/`TASK`/`CALENDAR` queries |
| `query/executor.lua` | Query executor: evaluates parsed AST against the index (WHERE, SORT, GROUP BY, LIMIT) |
| `query/api.lua` | Lua scripting API: sandboxed environment for `vault` code blocks |
| `query/render.lua` | Query output renderer: virtual text tables, lists, task lists, calendars, inline expressions |
| `query/js2lua.lua` | DataviewJS transpiler: converts JavaScript-style query syntax to Lua |
| `query/types.lua` | Shared types: `Date`, `Duration`, `Link` value objects with comparison operators |

### Layer 3: Features -- Other

| File | Description |
|------|-------------|
| `tasks.lua` | Task aggregation: vault-wide task pickers by state (`- [ ]`, `- [x]`, etc.) |
| `pins.lua` | Pinned/starred notes with persistent JSON storage |
| `export.lua` | Pandoc document export (PDF, DOCX, HTML) with frontmatter-based metadata |
| `calendar.lua` | Calendar view: monthly grid showing daily log entries |

### Layer 4: UI

| File | Description |
|------|-------------|
| `graph.lua` | Local graph view: ASCII two-column display of backlinks and forward links |
| `graph_filter.lua` | Graph filter system: depth, folder, date, tag, type filters with presets |
| `preview.lua` | Floating preview (`K` key): hover-to-read with scroll, edit-in-float (`<leader>vE`) |
| `embed.lua` | Transclusion rendering: `![[Note]]` as virtual text, `![[image.png]]` as inline images |
| `breadcrumbs.lua` | Winbar breadcrumbs showing vault path and heading hierarchy |

### Layer 5: Templates

| File | Description |
|------|-------------|
| `templates/init.lua` | Template registry: returns ordered list of all templates for the picker |
| `templates/daily_log.lua` | Daily log template with carry-forward of open tasks |
| `templates/weekly_review.lua` | Weekly review template with auto-collected achievements |
| `templates/monthly_review.lua` | Monthly review template |
| `templates/quarterly_review.lua` | Quarterly review template |
| `templates/yearly_review.lua` | Yearly review template |
| `templates/project_dashboard.lua` | Project dashboard template with embedded queries |
| `templates/simulation.lua` | Simulation note template |
| `templates/analysis.lua` | Analysis note template |
| `templates/finding.lua` | Finding note template |
| `templates/task.lua` | Task note template |
| `templates/meeting.lua` | Meeting note template |
| `templates/literature.lua` | Literature note template |
| `templates/concept.lua` | Concept note template |
| `templates/journal.lua` | Journal entry template |
| `templates/person.lua` | Person note template |
| `templates/domain_moc.lua` | Domain MOC (map of content) template |
| `templates/area_dashboard.lua` | Area dashboard template |
| `templates/methodology.lua` | Methodology note template |
| `templates/draft.lua` | Draft document template |
| `templates/presentation.lua` | Presentation note template |
| `templates/changelog.lua` | Changelog entry template |
| `templates/asset.lua` | Asset tracking template |
| `templates/recurring_task.lua` | Recurring task template |
| `templates/financial_snapshot.lua` | Financial snapshot template |

## Implementation Steps

This document is itself the deliverable. To maintain it going forward:

1. **Location:** This file lives at `improvements/14-vault-architecture-doc.md`.
   If a more permanent home is desired, copy the module inventory and dependency
   map sections to `lua/andrew/vault/ARCHITECTURE.md`.

2. **Update triggers:** Update this document when:
   - A new module is added to `lua/andrew/vault/`
   - A module's layer assignment changes (e.g., moves from feature to core)
   - The init.lua load order changes
   - A new external dependency is introduced
   - The cache invalidation chain is modified

3. **Automated staleness detection:** The module inventory can be validated
   against the actual filesystem with a simple script:
   ```bash
   # List all vault .lua files not mentioned in this document
   fd --type f --extension lua --base-directory lua/andrew/vault/ \
     | while read f; do
       grep -qF "$f" improvements/14-vault-architecture-doc.md || echo "MISSING: $f"
     done
   ```

4. **Relationship to improvement docs:** The 42 completed improvement documents
   in `improvements/completed/` provide detailed design rationale for individual
   features. This architecture document provides the structural overview that
   ties them together. Neither replaces the other.
