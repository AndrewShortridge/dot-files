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
  max_scan_lines = 30, -- lines to read when looking for frontmatter on save
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
}

-- ---------------------------------------------------------------------------
-- Embed / transclusion
-- ---------------------------------------------------------------------------
M.embed = {
  max_lines = 20,
}

-- ---------------------------------------------------------------------------
-- Query index
-- ---------------------------------------------------------------------------
M.query = {
  index_ttl = 30, -- seconds before the index is considered stale
}

return M
