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

return M
