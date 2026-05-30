--- Centralized configuration for the vault plugin.
--- Override any value here to customize behavior across all vault modules.
local M = {}

-- ---------------------------------------------------------------------------
-- Directory structure (relative to vault root)
-- ---------------------------------------------------------------------------
M.dirs = {
  log = "Log",
  projects = "Projects",
  areas = "Areas",
  domains = "Domains",
  library = "Library",
  methods = "Methods",
  people = "People",
  inbox = "Inbox.md",
}

-- ---------------------------------------------------------------------------
-- Frontmatter
-- ---------------------------------------------------------------------------
M.frontmatter = {
  created_field = "created",
  modified_field = "modified",
  timestamp_format = "%Y-%m-%dT%H:%M:%S",
  max_scan_lines = 200, -- lines to read when looking for frontmatter on save
}

-- ---------------------------------------------------------------------------
-- Task checkbox states
-- ---------------------------------------------------------------------------
M.task_states = {
  { mark = " ", label = "open" },
  { mark = "/", label = "in-progress" },
  { mark = "x", label = "done" },
  { mark = "-", label = "cancelled" },
  { mark = ">", label = "deferred" },
}

-- ---------------------------------------------------------------------------
-- Note types (used by search_by_type)
-- ---------------------------------------------------------------------------
M.note_types = {
  "meeting",
  "analysis",
  "finding",
  "task",
  "simulation",
  "literature",
  "concept",
  "log",
  "journal",
}

-- ---------------------------------------------------------------------------
-- Preview
-- ---------------------------------------------------------------------------
M.preview = {
  max_lines = 25,
  max_width = 80,
  min_width = 20,
  -- Lines to scroll per <C-j>/<C-k> keypress in the preview float.
  scroll_lines = 3,
  -- History navigation within the preview float.
  -- Tracks previously-viewed targets for <C-o>/<C-i> navigation.
  history_max = 20,
  -- Allow following wikilinks inside the preview float (gf/K in float).
  nested_preview = true,
  -- Breadcrumb title style: "full" (vault-relative path), "short" (note name only), "none" (legacy title).
  breadcrumb_style = "full",
  -- Separator character between breadcrumb segments.
  breadcrumb_separator = " \u{203A} ",
  -- Edit float size (fraction of editor dimensions).
  edit_width_ratio = 0.8,
  edit_height_ratio = 0.6,
}

-- ---------------------------------------------------------------------------
-- Embed / transclusion
-- ---------------------------------------------------------------------------
M.embed = {
  max_lines = 20,
  max_depth = 5,  -- max nesting depth for recursive transclusion (0 = flat/no recursion)
  max_total_lines = 150,  -- total virt text lines across all embeds in a buffer (0 = unlimited)
  -- Total character width of embed header/footer border lines.
  border_width = 50,
  -- Delay (ms) before retrying image rendering after DA3 terminal detection.
  image_retry_delay_ms = 1200,
  -- Lazy rendering: only render embeds in/near the visible viewport initially.
  -- Off-screen embeds render on scroll via WinScrolled handler.
  lazy = true,                -- enable viewport-restricted lazy rendering
  lazy_scroll_debounce_ms = 80, -- debounce for WinScrolled-triggered renders
  sync = {
    enabled = true,           -- Enable live embed sync
    debounce_ms = 300,        -- Debounce for cross-file changes
    self_debounce_ms = 500,   -- Debounce for same-file (TextChanged) updates
  },
  --- File extensions recognized as images for embed rendering and export.
  --- Used by embed.lua (inline image placement) and export.lua (markdown image conversion).
  --- Keys are lowercase extensions; values are true.
  image_exts = {
    png = true, jpg = true, jpeg = true, gif = true, svg = true,
    webp = true, bmp = true, tiff = true, heic = true, avif = true,
  },
}

-- ---------------------------------------------------------------------------
-- Block ID generation
-- ---------------------------------------------------------------------------
M.blockid = {
  -- Length of the random alphanumeric suffix (e.g., 6 produces "blk-a1b2c3").
  suffix_length = 6,
  -- Maximum collision retry attempts before falling back to timestamp-based ID.
  max_retries = 100,
}

-- ---------------------------------------------------------------------------
-- Footnotes
-- ---------------------------------------------------------------------------
M.footnotes = {
  -- Render footnote definitions as virtual text below references.
  render = false,             -- off by default (opt-in)
  -- Maximum content lines to show in virtual text per footnote.
  max_lines = 5,
  -- Maximum content lines in the floating preview window.
  preview_max_lines = 20,
  -- Auto-render on BufReadPost (like embeds). Only applies when render = true.
  auto_render = false,
  -- Show orphan diagnostics (references without definitions, definitions without references).
  diagnostics = true,
  -- Total character width of footnote header/footer border lines.
  border_width = 40,
}


-- ---------------------------------------------------------------------------
-- User templates (vault-side .md template files)
-- ---------------------------------------------------------------------------
M.user_templates = {
  enabled = true,
  --- Directory name inside vault root containing user template .md files.
  --- Can be a relative path (e.g., "templates" or ".templates").
  dir = "templates",
  --- Prefix for user templates in the picker to distinguish from built-in Lua templates.
  --- Set to "" to show no prefix.
  picker_prefix = "",
  --- Separator between built-in and user templates in the picker.
  --- Set to nil to disable the separator.
  picker_separator = "--- User Templates ---",
}

-- ---------------------------------------------------------------------------
-- Wikilink highlights
-- ---------------------------------------------------------------------------
M.wikilink_highlights = {
  enabled = true,
}

-- ---------------------------------------------------------------------------
-- Tag highlights
-- ---------------------------------------------------------------------------
M.tag_highlights = {
  enabled = true,
  --- Category prefix -> highlight group mapping.
  --- First match wins (put more specific prefixes first).
  categories = {
    { prefix = "project/", highlight = "VaultTagProject" },
    { prefix = "status/", highlight = "VaultTagStatus" },
    { prefix = "type/", highlight = "VaultTagType" },
    { prefix = "person/", highlight = "VaultTagPerson" },
  },
}

-- ---------------------------------------------------------------------------
-- Auto-link suggestions
-- ---------------------------------------------------------------------------
M.autolink = {
  enabled = true, -- Off by default (opt-in feature)
  min_name_length = 3, -- Ignore note names shorter than this
  exclude_names = {}, -- Lowercase names to never suggest (e.g., {"the", "and"})
  batch = {
    -- Skip matches where the matched text case differs significantly from note name
    -- (reduces false positives like "set" matching note "SET")
    case_sensitive_single_word = false,
    -- Maximum names per ripgrep invocation (batching to avoid shell arg limits)
    max_pattern_names = 50,
  },
}

-- ---------------------------------------------------------------------------
-- Link repair
-- ---------------------------------------------------------------------------
M.link_repair = {
  -- Maximum edit distance for auto-fix (single candidate with dist <= threshold)
  auto_fix_threshold = 1,
  -- Maximum candidates to show per broken link
  max_candidates = 5,
  -- Include moved-file detection in suggestions
  detect_moved = true,
  -- Fuzzy matching: fraction of query length used as max edit distance.
  fuzzy_threshold = 0.6,
  -- Minimum edit distance floor for fuzzy matching regardless of query length.
  fuzzy_min_distance = 5,
}

-- ---------------------------------------------------------------------------
-- Inline field highlights
-- ---------------------------------------------------------------------------
M.inline_fields = {
  enabled = true,
}

-- ---------------------------------------------------------------------------
-- Highlight marks (==text==)
-- ---------------------------------------------------------------------------
M.highlight_marks = {
  enabled = true,
}

-- ---------------------------------------------------------------------------
-- Highlight coordinator (consolidated autocmd dispatch)
-- ---------------------------------------------------------------------------
-- The highlight coordinator is always active. A single set of autocmds
-- dispatches to all highlight modules, sharing code exclusion across them
-- (1 treesitter parse instead of N).
M.highlight_coordinator = {}


-- ---------------------------------------------------------------------------
-- Auto-save on focus loss
-- ---------------------------------------------------------------------------
M.autosave = {
  enabled = true,
  debounce_ms = 1000,   -- debounce interval between save attempts
  events = { "FocusLost", "BufLeave", "WinLeave" },
}

-- ---------------------------------------------------------------------------
-- Temporal wikilink aliases ([[today]], [[yesterday]], etc.)
-- ---------------------------------------------------------------------------
M.temporal_aliases = {
  enabled = true,
  --- Static aliases: name -> day offset from today.
  --- Case-insensitive matching. Keys must be lowercase.
  ---@type table<string, number>
  aliases = {
    ["today"]     = 0,
    ["yesterday"] = -1,
    ["tomorrow"]  = 1,
  },
  --- Enable relative weekday aliases like [[last monday]], [[next friday]].
  --- Adds dynamic resolution for "last <weekday>" and "next <weekday>".
  relative_weekdays = true,
}

-- ---------------------------------------------------------------------------
-- Smart connections
-- ---------------------------------------------------------------------------
M.connections = {
  cache_ttl = 60,       -- seconds before cached scores expire
  max_results = 30,     -- max related notes to show in picker
  score_batch_size = 200,  -- entries per yield in compute_async()
  weights = {
    tags = 3.0,         -- IDF-weighted shared tag score multiplier
    frontmatter = 2.0,  -- shared frontmatter field score multiplier
    colink = 2.5,       -- bibliographic coupling (shared outlink targets)
    link_1hop = 5.0,    -- direct link (A->B or B->A)
    link_2hop = 2.0,    -- 2-hop bridge connections
    temporal = 1.0,     -- temporal proximity multiplier
    max_2hop_bridges = 5, -- cap on 2-hop bridges counted
  },
}

-- ---------------------------------------------------------------------------
-- Canonical field value lists (single source of truth)
-- ---------------------------------------------------------------------------
M.status_values = { "Not Started", "In Progress", "Blocked", "Complete", "Cancelled" }
M.status_default = "Not Started"

M.priority_values = { 1, 2, 3, 4, 5 }
M.priority_default = 3

M.maturity_values = { "Seed", "Developing", "Mature", "Evergreen" }

-- ---------------------------------------------------------------------------
-- Vault search scopes
-- ---------------------------------------------------------------------------
M.scopes = {
  { key = "all",      label = "All notes", glob = "**/*.md" },
  { key = "projects", label = "Projects",  glob = M.dirs.projects .. "/**/*.md" },
  { key = "areas",    label = "Areas",     glob = M.dirs.areas .. "/**/*.md" },
  { key = "log",      label = "Log",       glob = M.dirs.log .. "/**/*.md" },
  { key = "domains",  label = "Domains",   glob = M.dirs.domains .. "/**/*.md" },
  { key = "library",  label = "Library",   glob = M.dirs.library .. "/**/*.md" },
  { key = "methods",  label = "Methods",   glob = M.dirs.methods .. "/**/*.md" },
  { key = "people",   label = "People",    glob = M.dirs.people .. "/**/*.md" },
}

--- Helper: get scope glob by key
--- @param key string
--- @return string|nil
function M.scope_glob(key)
  for _, s in ipairs(M.scopes) do
    if s.key == key then return s.glob end
  end
  return nil
end

--- Helper: get scope label by key
--- @param key string
--- @return string|nil
function M.scope_label(key)
  for _, s in ipairs(M.scopes) do
    if s.key == key then return s.label end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Tag tree picker
-- ---------------------------------------------------------------------------
M.tag_tree = {
  -- Show file counts as "direct/total" for branch nodes.
  show_totals = true,

  -- Sort order for tree nodes at each level.
  -- "alpha" = alphabetical, "count" = by file count (descending)
  sort = "alpha",

  -- Minimum file count to display a tag in the tree.
  -- Set to 0 to show all tags including those with 0 direct files.
  min_count = 0,
}

-- ---------------------------------------------------------------------------
-- Vault index
-- ---------------------------------------------------------------------------
M.index = {
  -- Directories to skip during filesystem traversal and watching.
  skip_dirs = {
    [".obsidian"] = true,
    [".git"] = true,
    [".trash"] = true,
    [".vault-index"] = true,
    ["node_modules"] = true,
  },

  -- Batch size for background parsing (files per vim.schedule tick).
  batch_size = 20,

  -- Debounce interval (ms) for persisting index to disk after updates.
  persist_debounce_ms = 5000,

  -- Minimum interval (ms) between full persists (adaptive burst protection).
  persist_min_interval_ms = 10000,

  -- Enable filesystem watcher for real-time change detection.
  watch = true,

  -- Warn about alias/name collisions after index builds.
  -- Set to false to suppress the notification.
  warn_collisions = true,

  -- Show progress notifications during index builds.
  show_progress = true,

  -- Minimum number of changed files before showing progress updates.
  -- Below this threshold, only the completion message is shown.
  progress_threshold = 50,

  -- Auto-dismiss timeout (ms) for collision notification window.
  collision_notify_ms = 5000,

  -- Enable snapshot-based reads in search, completion, and connections.
  -- When true, consumers take an immutable snapshot of the index before
  -- iterating, preventing inconsistent reads if build_async() mutates
  -- between coroutine yields.
  use_snapshots = true,

  -- Maximum number of one-shot waiters (wait_for / wait_for_ready).
  -- Safety cap to prevent unbounded accumulation from buggy callers.
  max_waiters = 50,

  -- Enable heading-based content chunking for incremental parsing.
  -- When true, only re-parses changed sections of a file instead of the full file.
  chunking_enabled = true,

  -- Only chunk files with more lines than this threshold.
  -- Below this, the overhead of splitting/hashing/merging exceeds savings.
  min_chunk_lines = 20,

  -- If more than this fraction of chunks changed, fall back to full re-parse.
  -- Handles heading insertion/deletion cascading digest mismatches.
  fallback_threshold = 0.5,

  -- Validate chunked parse results against full parse (dev-only, high overhead).
  -- Runs both paths and logs discrepancies via vault_log scope "chunker".
  chunking_validate = false,

  -- Enable file-level content hash for two-phase change detection.
  -- When true, files flagged by mtime+size are hash-checked before
  -- entering the chunked parse pipeline.
  content_hash_enabled = true,

  -- Hash algorithm for file-level content hashing.
  -- "crc32": fast LuaJIT bit ops (~0.01ms/file), adequate collision resistance
  -- "sha256": uses vim.fn.sha256() (~0.05ms/file), cryptographic certainty
  hash_algorithm = "crc32",
}

-- ---------------------------------------------------------------------------
-- Completion
-- ---------------------------------------------------------------------------
M.completion = {
  -- Number of vault index entries to process per coroutine batch before
  -- yielding to the event loop. Higher = faster builds, lower = more
  -- responsive UI during builds. 50 is a good default for most systems.
  batch_size = 50,

  -- Maximum seconds to suppress completion rebuilds while the vault index
  -- is building. After this timeout, rebuilds proceed regardless.
  index_build_timeout_secs = 30,

  -- Maximum number of completion items per source. Items are sorted by mtime
  -- (most recent first) and truncated. 0 = unlimited.
  max_items = 10000,

  -- Enable description string interning to deduplicate identical description
  -- strings across completion items (reduces memory for large vaults).
  intern_descriptions = true,
}

-- ---------------------------------------------------------------------------
-- Advanced search
-- ---------------------------------------------------------------------------
M.search = {
  -- Debounce interval (ms) for live advanced search re-evaluation.
  -- Applied internally by fzf-lua's fzf_live. Lower = more responsive,
  -- higher = fewer ripgrep invocations.
  live_debounce_ms = 150,

  -- Maximum number of files to pass to ripgrep via --files-from.
  -- If metadata filtering produces more matches than this, fall back
  -- to full vault ripgrep with post-filtering. This avoids hitting
  -- shell argument limits and is faster for large file sets.
  max_files_from = 500,

  -- Known field names shown in completion (auto-extended from vault index).
  -- These are recognized by the tokenizer as field prefixes for field:value
  -- syntax. Unknown identifiers before : are also treated as generic fields
  -- but won't appear in completion.
  builtin_fields = {
    "type", "tag", "path", "file", "folder", "status",
    "created", "modified", "day", "priority",
    "links-to", "linked-from", "alias",
  },

  -- Custom field aliases: maps user-friendly names to index field paths.
  -- Example: { area = "frontmatter.area", proj = "frontmatter.project" }
  -- When the user types area:xyz, it's evaluated as frontmatter.area = xyz.
  field_aliases = {},

  -- Valid targets for has: filters and completion.
  -- These correspond to VaultIndexEntry fields that can be checked for existence.
  has_targets = { "tags", "aliases", "tasks", "outlinks", "inlinks", "frontmatter" },

  -- Graph integration
  graph_operator = true,        -- enable graph: operator in search queries
  graph_max_depth = 5,          -- max depth for graph: operator (safety limit)

  -- Width (columns) of the advanced search prompt float.
  prompt_width = 72,
  -- Width (columns) of the search help reference float.
  help_width = 55,

  -- Search history with frecency ranking.
  history = {
    enabled = true,          -- record queries to history
    max_entries = 200,       -- maximum stored queries
  },

  -- Show result statistics (match count, file count, timing) in search results.
  show_stats = true,

  -- Field name correction: suggest similar field names on typos.
  field_correction = {
    enabled = true,          -- enable fuzzy field name correction
    max_distance = 2,        -- max edit distance for suggestions
    auto_correct = false,    -- silently use suggestion instead of warning
  },

  -- Predefined enum values for field completion.
  -- Maps field names to arrays of valid values. These take priority over
  -- index-aggregated values in Tab completion.
  field_enums = {
    maturity = { "Seed", "Developing", "Mature", "Evergreen" },
  },

  -- Result grouping
  grouping = {
    -- Default group mode when no group: directive is specified.
    -- Set to "none" to disable grouping by default.
    -- Set to "folder" to always group by folder, etc.
    default_mode = "none",

    -- For date/month grouping: show newest first by default.
    date_newest_first = true,

    -- Tag grouping: use top-level prefix ("project" from "project/active")
    -- or full tag path. "prefix" or "full".
    tag_level = "prefix",
  },

  -- Result limits (inspired by Zed's MAX_SEARCH_RESULT_FILES / MAX_SEARCH_RESULT_RANGES)
  max_result_files = 5000,       -- metadata evaluation cap (nil = unlimited)
  max_result_lines = 10000,      -- ripgrep output line cap (nil = unlimited)
  max_matches_per_file = 100,    -- rg --max-count per file (nil = unlimited)

  -- Concurrency limits for ripgrep subprocess spawning (semaphore-based).
  -- Bounds concurrent rg processes across all vault modules (search, rename,
  -- linkcheck, etc.) to prevent PID/memory exhaustion on complex queries.
  max_concurrent_rg = 3,         -- max simultaneous rg processes (semaphore permits)
  rg_queue_max = 5,              -- max queued rg requests (oldest dropped beyond this)

  -- Cooperative yielding: entries per yield in evaluate_async()
  evaluate_batch_size = 500,
}

-- ---------------------------------------------------------------------------
-- Pre-filtering (early exit optimizations for completion & search)
-- ---------------------------------------------------------------------------
M.prefilter = {
  enabled = true,
  completion_char_bag = true,     -- CharBag pre-filtering for completion
  search_pre_checks = true,       -- Early exit checks in search_filter
  precomputed_sets = true,        -- Index-level precomputed sets
  bloom_filter = true,            -- Bloom filter for tag membership pre-checks
  min_query_length = 2,           -- CharBag only useful for queries >= 2 chars
}

-- ---------------------------------------------------------------------------
-- Graph view
-- ---------------------------------------------------------------------------
M.graph = {
  max_depth = 5,          -- maximum allowed link depth
  max_nodes = 50,         -- safety cap for multi-hop collection
  bfs_batch_size = 100,    -- nodes per yield in async BFS
  default_depth = 1,      -- initial depth when opening graph
  show_filter_bar = true, -- show the filter status + keybinding hints
  -- Float dimensions (fraction of screen).
  float_width_ratio = 0.8,
  float_height_ratio = 0.6,

  -- Default toggle states
  show_unresolved = true,
  existing_only = false,

  -- Date range shortcuts recognized by the date filter input
  date_shortcuts = {
    ["today"]      = { offset_days = 0 },
    ["7d"]         = { offset_days = -7 },
    ["30d"]        = { offset_days = -30 },
    ["90d"]        = { offset_days = -90 },
    ["this-week"]  = "week",
    ["this-month"] = "month",
  },

  -- Search integration
  search_expr_enabled = true,   -- enable search expression filter in graph UI
  search_to_graph = true,       -- enable Ctrl-g "view as graph" in search results
  graph_to_search = true,       -- enable 's' "search in nodes" from graph view

  -- Graph filter UI float widths (columns).
  filter_input_width = 70,      -- date range, search expression inputs
  filter_menu_width = 60,       -- main filter menu
  filter_toggle_width = 45,     -- boolean toggle filter display
}

-- ---------------------------------------------------------------------------
-- Carry-forward (daily log task migration)
-- ---------------------------------------------------------------------------
M.carry_forward = {
  enabled = true,

  -- Maximum number of previous daily logs to scan for incomplete tasks.
  -- 1 = only the most recent previous log (default, current behavior).
  -- 7 = scan up to a week back, accumulating all incomplete tasks.
  lookback = 1,

  -- Task states to carry forward. Keys are checkbox characters.
  -- " " = open, "/" = in-progress, ">" = deferred
  states = {
    [" "] = true,   -- open tasks
    ["/"] = true,   -- in-progress tasks
    [">"] = false,  -- deferred tasks (opt-in)
  },

  -- Preserve sub-task hierarchy. When true, if a parent task is carried,
  -- its indented sub-tasks are carried as a group.
  preserve_subtasks = true,

  -- Add a backlink to the source daily log in the carry-forward callout.
  source_link = true,

  -- Show a notification when tasks are carried forward.
  notify = true,

  -- Heading under which carried tasks are inserted.
  heading = "### Carried Forward",

  -- Sections in the daily log to scan for tasks (heading text patterns).
  -- If empty, scans the entire file.
  scan_sections = {},

  -- Sections to SKIP when scanning for tasks.
  skip_sections = { "Completed Today", "Tomorrow's Priorities" },
}

-- ---------------------------------------------------------------------------
-- Calendar
-- ---------------------------------------------------------------------------
M.calendar = {
  -- Date fields to extract from vault index entries for calendar indicators.
  -- Each source is checked in order. "frontmatter.X" reads entry.frontmatter[X],
  -- "inline.X" reads entry.inline_fields[X], "task.X" reads entry.tasks[i][X].
  indicators = {
    {
      key = "due",
      label = "due",
      sources = { "frontmatter.due", "inline.due", "task.due" },
    },
    {
      key = "scheduled",
      label = "sched",
      sources = { "frontmatter.scheduled", "inline.scheduled", "task.scheduled" },
    },
  },

  -- Whether to show note creation dates as calendar indicators.
  show_created = false,
}

-- ---------------------------------------------------------------------------
-- Sidebar panels
-- ---------------------------------------------------------------------------
M.sidebar = {
  -- Default sidebar width in columns.
  width = 40,

  -- Side of the screen: "right" or "left".
  position = "right",

  -- Auto-open sidebar when entering a vault markdown buffer.
  auto_open = false,

  -- Which panel to show by default when sidebar opens.
  -- One of: "backlinks", "tags", "meta"
  default_panel = "backlinks",

  -- Backlinks panel: number of context lines to show around each link.
  backlinks_context = 1,

  -- Metadata panel: show inline fields alongside frontmatter.
  meta_show_inline = true,

}

-- ---------------------------------------------------------------------------
-- Vault stats display
-- ---------------------------------------------------------------------------
M.stats = {
  -- Width of section separator lines in :VaultStats output.
  separator_width = 50,
}

-- ---------------------------------------------------------------------------
-- External URL validation
-- ---------------------------------------------------------------------------
M.url_validation = {
  enabled = true,         -- opt-in (network requests are sensitive)
  -- Diagnostic integration (inline markers in buffer)
  diagnostics = true,
  -- Timeout per request (ms)
  timeout_ms = 10000,
  -- Maximum concurrent requests
  max_concurrent = 5,
  -- Maximum redirects to follow
  max_redirects = 5,
  -- Rate limit: minimum ms between requests to the same domain
  domain_rate_limit_ms = 1000,
  -- User-Agent string (some sites block curl's default)
  user_agent = "Mozilla/5.0 (compatible; VaultLinkCheck/1.0)",
  -- Cache TTLs (seconds)
  cache_ttl = {
    success = 7 * 86400,      -- 2xx: 7 days
    redirect = 3 * 86400,     -- 3xx: 3 days
    client_error = 86400,     -- 4xx: 1 day
    server_error = 86400,     -- 5xx: 1 day
    network_error = 4 * 3600, -- connection failure: 4 hours
  },
  -- URL patterns to skip (Lua patterns, matched against full URL)
  exclude_patterns = {
    "^https?://localhost",
    "^https?://127%.",
    "^https?://192%.168%.",
    "^https?://10%.",
    "^https?://0%.0%.0%.0",
  },
  -- Debounce interval (ms) for persisting URL validation cache to disk.
  cache_persist_debounce_ms = 5000,
  -- Specific domains to skip entirely
  exclude_domains = {},
  -- Status codes to treat as "OK" (beyond 2xx)
  accept_status_codes = {},
  -- Fall back to GET if HEAD fails with certain status codes
  head_fallback_to_get = { 403, 405, 501 },
  -- Maximum queued requests before rejecting new submissions
  max_queue_size = 200,
  -- Fallback timer interval (ms) for draining cooldown-expired domains
  queue_drain_interval_ms = 100,
}

-- ---------------------------------------------------------------------------
-- Kanban board
-- ---------------------------------------------------------------------------

M.kanban = {
  columns = nil,
  max_per_column = 50,
  show_priority = true,
  show_due = true,
}

-- ---------------------------------------------------------------------------
-- Task timeline
-- ---------------------------------------------------------------------------

M.timeline = {
  range_days = 14,
  show_done = false,
  show_undated = true,
  -- Float dimensions (fraction of screen).
  float_width_ratio = 0.8,
  float_height_ratio = 0.8,
}

-- ---------------------------------------------------------------------------
-- Task hierarchy
-- ---------------------------------------------------------------------------

M.hierarchy = {
  show_completion_vtext = true,
  debounce_ms = 500,
  default_fold = "expanded",
}

-- ---------------------------------------------------------------------------
-- Task notifications
-- ---------------------------------------------------------------------------

M.task_notify = {
  enabled = true,
  check_interval = 300,
  snooze_minutes = 60,
  system_notify = false,
  style = "detail",
  detail_limit = 3,
}

-- ---------------------------------------------------------------------------
-- Logging
-- ---------------------------------------------------------------------------
M.log = {
  --- Minimum level for vim.notify() output.
  --- "DEBUG" shows everything, "ERROR" shows only errors, "WARN" is a good default.
  notify_level = "WARN",
  --- Minimum level for file logging.
  file_level = "DEBUG",
  --- Log file path. nil disables file logging.
  --- Set to vim.fn.stdpath("data") .. "/vault.log" for debugging.
  file = nil,
}

-- ---------------------------------------------------------------------------
-- UI defaults (shared float dimensions)
-- ---------------------------------------------------------------------------
M.ui = {
  -- Default float dimensions (fraction of screen) for create_float_display.
  default_float_width_ratio = 0.8,
  default_float_height_ratio = 0.8,
  -- Default width (columns) for single-line input floats (capture, quick task, etc.).
  input_float_width = 60,
  -- Separator width for debug/status display outputs (VaultCacheStatus, VaultIndexStatus, etc.).
  status_separator_width = 40,
  -- Fallback screen dimensions when nvim_list_uis() is empty (headless mode).
  fallback_screen_width = 120,
  fallback_screen_height = 40,
}

-- ---------------------------------------------------------------------------
-- Frontmatter editor
-- ---------------------------------------------------------------------------
M.frontmatter_editor = {
  -- Float dimensions (fraction of screen).
  float_width_ratio = 0.8,
  float_height_ratio = 0.6,
}

-- ---------------------------------------------------------------------------
-- Command palette
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Cache size limits (LRU eviction)
-- ---------------------------------------------------------------------------
M.cache = {
  -- Count-based limits (hard item caps, also used by non-weighted caches)
  slug_max = 2000,
  date_parse_max = 5000,
  connections_max = 500,
  section_cache_max = 200,
  note_data_max = 1000,
  display_width_max = 2000,
  bfs_traversal_max = 100,
  image_path_max = 500,
  fold_state_max = 500,
  file_content_max = 100,

  -- Memory-weighted byte budgets (total: 15 MB)
  file_content_bytes = 5 * 1024 * 1024,       -- 5 MB
  section_cache_bytes = 2 * 1024 * 1024,       -- 2 MB
  section_outlinks_bytes = 2 * 1024 * 1024,    -- 2 MB
  connections_bytes = 3 * 1024 * 1024,          -- 3 MB
  note_data_bytes = 2 * 1024 * 1024,           -- 2 MB
  bfs_traversal_bytes = 1 * 1024 * 1024,       -- 1 MB
}

M.command_palette = {
  -- fzf-lua window dimensions (fraction of screen).
  width = 0.7,
  height = 0.6,
}

-- ---------------------------------------------------------------------------
-- String intern pool capacity limits
-- ---------------------------------------------------------------------------
M.intern = {
  tag_pool_max = 500,
  fm_key_pool_max = 200,
  fm_value_pool_max = 2000,
  folder_pool_max = 500,
  lowercase_pool_max = 5000,
}

-- ---------------------------------------------------------------------------
-- Table object pool capacity limits
-- ---------------------------------------------------------------------------
M.pools = {
  enabled = true,
  connection_result = 200,
  connection_breakdown = 200,
  completion_item = 1000,
  embed_descriptor = 50,
}

-- ---------------------------------------------------------------------------
-- Per-render arena allocation (scope-based bulk table recycling)
-- ---------------------------------------------------------------------------
M.arena = {
  initial_pool_size = 200,      -- Tables pre-allocated at module load
  max_pool_size = 2000,         -- Upper bound on pooled tables (excess GC'd)
  debug_validation = false,     -- Enable use-after-free proxy detection
}

-- Event coalescing / batching for autocmd consolidation.
M.events = {
  buf_enter_coalesce_ms = 16, -- BufEnter coalescing window (~1 frame)
  rapid_switch_threshold_ms = 50, -- Detect :bufdo-style rapid switching
  rapid_switch_delay_ms = 200, -- Extended delay during rapid switching
  max_batch_size = 32, -- Force flush at this many pending events
}

-- Request coalescer: deduplicates concurrent identical operations.
-- Per-pool config applied via request_coalescer.configure(); defaults are in Pool.new().
M.coalescer = {
  pools = {
    url_validate = { max_waiters = 10, timeout_ms = 30000, done_linger_ms = 200 },
    embed = { max_waiters = 10, timeout_ms = 30000, done_linger_ms = 100 },
    search = { max_waiters = 50, timeout_ms = 30000, done_linger_ms = 100 },
    index_rebuild = { max_waiters = 50, timeout_ms = 60000, done_linger_ms = 50 },
    connections = { max_waiters = 20, timeout_ms = 30000, done_linger_ms = 100 },
  },
}

-- ---------------------------------------------------------------------------
-- Layered transform pipeline (replaces per-updater buffer scanning)
-- ---------------------------------------------------------------------------
M.pipeline = {
  line_cache_max = 10000,            -- Max cached lines per buffer before eviction
  full_reparse_threshold = 100,      -- If >N dirty lines, do full reparse instead
  content_dedup = true,              -- Skip re-tokenizing lines with unchanged text
  use_lpeg = true,                   -- Use LPEG tokenizer (false = fallback to string.find loop)
  batch_extmarks = true,             -- Use nvim_call_atomic for extmark operations
}

-- ---------------------------------------------------------------------------
-- Viewport-restricted rendering
-- ---------------------------------------------------------------------------
M.viewport = {
  padding_lines = 50, -- Extra lines rendered beyond visible viewport edges
  cleanup_threshold = 3.0, -- Multiplier: GC placements beyond this × viewport_height from edge
  full_buffer_threshold = 200, -- Files with fewer lines skip viewport restriction (BufEnter uses full=true)
  render_margin = 5, -- Extra lines around viewport for lightweight renders (autolink, footnotes)
  prefetch_multiplier = 1.0, -- Prefetch zone size as viewport height multiple (1.0 = one full viewport above/below)
  prefetch_debounce_ms = 400, -- Delay before prefetch zone rendering (ms, matches Zed's invisible range delay)
}

-- ---------------------------------------------------------------------------
-- Batch drain defaults (threshold-based accumulation primitive)
-- ---------------------------------------------------------------------------
M.batch = {
  default_max_count = 100,    -- Items before auto-drain
  default_max_bytes = 524288, -- 512 KB before auto-drain
}

-- ---------------------------------------------------------------------------
-- Pattern compilation cache
-- ---------------------------------------------------------------------------
M.patterns = {
  regex_cache_size = 100, -- Max cached vim.regex() objects
}

-- ---------------------------------------------------------------------------
-- Hierarchical summary tree (replaces _ensure_aggregates O(N) iteration)
-- ---------------------------------------------------------------------------
M.summary_tree = {}

-- ---------------------------------------------------------------------------
-- Tiered cache invalidation
-- ---------------------------------------------------------------------------
M.invalidation = {
  enable_tiered = true,         -- Master switch; false = current behavior (always full)
  partial_file_threshold = 50,  -- Files changed above this count → escalate to FULL tier
  debug = false,                -- Log tier classification decisions
}

--- ---------------------------------------------------------------------------
--- Region-based invalidation tracking
--- ---------------------------------------------------------------------------
M.region_tracker = {
  max_per_buffer = 50,       -- Maximum valid regions tracked per buffer
  coalesce_threshold = 5,    -- Minimum gap (lines) to keep regions separate
}

-- ---------------------------------------------------------------------------
-- Generational slot map entity storage (slot_map.lua)
-- ---------------------------------------------------------------------------
M.slot_map = {
  leak_detect = false,  -- Enable allocation tracking with backtraces (debug only)
}

-- Structural sharing (table-level dedup across index versions)
-- ---------------------------------------------------------------------------
M.sharing = {
  enable = true,                  -- Master toggle for structural sharing
  debug_immutability = false,     -- Add __newindex guards to shared tables (dev only)
}

-- Memory profiling infrastructure
-- ---------------------------------------------------------------------------
M.profiler = {
  enable = false,                  -- Master switch (false = all functions are no-ops)
  health_check_interval_s = 60,    -- Periodic anomaly check (0 = disabled)
  gc_sample_interval_ms = 5000,    -- Memory sampling rate
  gc_sample_max = 720,             -- Max samples retained (1 hour at 5s)
  alert_memory_growth_mb = 10,     -- Warn if memory grows by this much between checks
  alert_hit_rate_min = 0.5,        -- Warn if any cache hit rate drops below this
}

-- Operation tracker (async staleness detection)
-- ---------------------------------------------------------------------------
M.operation_tracker = {
  stats_enabled = false,  -- Track started/completed/discarded counts for debugging
}

-- Memoized state checks (memoize.lua)
-- ---------------------------------------------------------------------------
M.memoize = {
  max_entries = 100, -- Maximum cache entries per MemoizedCheck instance
}

-- Dual-frame render cache (frame_cache.lua)
-- ---------------------------------------------------------------------------
M.render_cache = {
  -- Master toggle. When false, opts.frame_cache is nil and legacy updaters
  -- render unconditionally (current behavior). Allows quick disable if cache
  -- introduces regressions.
  enabled = true,

  -- Maximum entries per frame per buffer. Prevents runaway memory in
  -- extremely large files (e.g., 10k-line vault notes). When exceeded,
  -- new entries are silently dropped (eviction counter incremented).
  -- nil = unlimited (matches Zed's approach, relying on two-generation
  -- lifetime for implicit eviction).
  max_entries_per_frame = nil,
}

-- Prioritized work scheduler (work_scheduler.lua)
-- ---------------------------------------------------------------------------
-- Idle-time proactive cache warming (cache_warming.lua)
-- ---------------------------------------------------------------------------
M.cache_warming = {
  -- Master switch: enable/disable all proactive warming
  enabled = true,

  -- Delay before scheduling warmup tasks after BufEnter (ms).
  -- Allows BufEnter processing (embed autocmd, highlight setup) to complete first.
  idle_delay_ms = 2000,

  -- Maximum files to pre-read per adjacent-file warm cycle
  max_files_per_warm = 10,

  -- Per-strategy enable flags
  strategies = {
    adjacent_files = true, -- Pre-read linked/embedded files into file_cache
    connections = true, -- Pre-compute connection scores
  },
}

-- Prioritized work scheduler (work_scheduler.lua)
-- ---------------------------------------------------------------------------
M.scheduler = {
  -- Delay before DEFERRED items execute (ms). Long enough for NORMAL work to
  -- complete, short enough that deferred work doesn't feel permanently delayed.
  deferred_delay_ms = 300,

  -- Max IDLE items processed per CursorHold event. Processing more than 3
  -- items risks a perceptible pause at typical updatetime=300ms.
  max_idle_per_hold = 3,

  -- Track execution statistics (enqueue/execute/cancel counters).
  -- Negligible cost but unnecessary in normal operation.
  stats_enabled = false,
}

return M
