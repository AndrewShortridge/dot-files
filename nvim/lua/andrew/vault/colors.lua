--- Centralized color palette and highlight definitions for all vault modules.
--- Single source of truth. No requires from the vault module tree.
local M = {}

--- The currently active palette (set by detect_palette + define_highlights).
---@type table<string, string>
M.palette = {}

-- ---------------------------------------------------------------------------
-- Palette definitions per colorscheme family
-- ---------------------------------------------------------------------------

--- OneDark palette (default).
--- Source: hardcoded values extracted from wikilink_highlights, tag_highlights,
---         highlights, inline_fields, autolink, embed, calendar, and graph.
local onedark = {
  -- Wikilinks
  link_valid           = "#61afef",
  link_broken          = "#e06c75",
  link_heading         = "#98c379",
  link_heading_broken  = "#d19a66",
  link_self            = "#c678dd",
  link_alias           = "#61afef",
  link_bracket         = "#5c6370",

  -- Tags
  tag_default          = "#c678dd",
  tag_project          = "#61afef",
  tag_status           = "#98c379",
  tag_type             = "#e5c07b",
  tag_person           = "#56b6c2",
  tag_hash             = "#5c6370",

  -- Inline fields
  field_bracket        = "#5c6370",
  field_key            = "#e06c75",
  field_sep            = "#5c6370",
  field_value          = "#98c379",
  field_value_date     = "#e5c07b",
  field_value_number   = "#d19a66",
  field_value_link     = "#61afef",
  field_value_bool     = "#56b6c2",

  -- Highlight marks (==text==)
  highlight_bg         = "#4a3a10",
  highlight_fg         = "#e5c07b",
  highlight_delim      = "#5c6370",

  -- Autolinks
  autolink_hint_sp     = "#5c6370",
  autolink_icon        = "#5c6370",

  -- Embeds
  embed_content        = "#8888aa",
  embed_border         = "#555577",
  embed_cycle          = "#e06060",
  embed_depth          = "#c0a040",
  embed_truncated      = "#c0a040",
  embed_error          = "#e06060",

  -- Preview breadcrumbs
  preview_breadcrumb_path     = "#5c6370",
  preview_breadcrumb_note     = "#61afef",
  preview_breadcrumb_sep      = "#5c6370",
  preview_breadcrumb_fragment = "#98c379",

  -- Footnotes
  footnote_ref           = "#56b6c2",
  footnote_def           = "#5c6370",
  footnote_content       = "#8888aa",
  footnote_border        = "#555577",
  footnote_orphan        = "#e06c75",

  -- Calendar (originally Catppuccin Mocha values)
  calendar_header      = "#89b4fa",
  calendar_today_fg    = "#1e1e2e",
  calendar_today_bg    = "#a6e3a1",
  calendar_has_log     = "#f9e2af",
  calendar_deadline    = "#94e2d5",
  calendar_log_dead_fg = "#1e1e2e",
  calendar_log_dead_bg = "#fab387",
  calendar_weekend     = "#f38ba8",
  calendar_dim         = "#585b70",
  calendar_legend      = "#7f849c",
  calendar_scheduled   = "#c678dd",  -- purple for scheduled dates

  -- Kanban
  kanban_header        = "#61afef",  -- blue accent
  kanban_overdue       = "#e06c75",  -- red
  kanban_due_today     = "#e5c07b",  -- yellow
  kanban_p1            = "#e06c75",  -- red
  kanban_p2            = "#d19a66",  -- orange/peach
  kanban_default       = "#abb2bf",  -- fg
  kanban_divider       = "#585b70",  -- surface2

  -- Timeline
  timeline_overdue     = "#e06c75",  -- red
  timeline_today       = "#e5c07b",  -- yellow
  timeline_upcoming    = "#98c379",  -- green
  timeline_overdue_bg  = "#e06c75",  -- red bg
  timeline_task        = "#abb2bf",  -- fg
  timeline_dim         = "#585b70",  -- surface2
  timeline_undated     = "#c678dd",  -- mauve

  -- Timeline (additional)
  timeline_header      = "#98c379",  -- green (header title)
  timeline_priority    = "#c678dd",  -- purple (priority markers)

  -- Hierarchy
  hierarchy_progress   = "#e5c07b",  -- yellow
  hierarchy_complete   = "#98c379",  -- green
  hierarchy_connector  = "#585b70",  -- surface2
  hierarchy_parent     = "#abb2bf",  -- fg

  -- Graph
  graph_existing       = "#3b82f6",
  graph_unresolved     = "#ef4444",

  -- Query
  query_border         = "#c678dd",
  query_link           = "#3b82f6",

  -- Sidebar
  sidebar_tab_active   = "#61afef",
  sidebar_tab_inactive = "#5c6370",
  sidebar_sep          = "#3e4452",
  sidebar_header       = "#c678dd",
  sidebar_file         = "#abb2bf",
  sidebar_context      = "#5c6370",
  sidebar_line_nr      = "#4b5263",
  sidebar_field_key    = "#e06c75",
  sidebar_field_value  = "#98c379",
  sidebar_tag          = "#c678dd",
  sidebar_count        = "#5c6370",
  sidebar_empty        = "#5c6370",
  sidebar_cursor       = "#61afef",
}

--- Soft Paper Light palette.
--- Source: lua/andrew/themes/soft-paper.lua, M.palettes.light
local soft_paper_light = {
  link_valid           = "#1A7DA4",  -- c.accent
  link_broken          = "#BA7184",  -- c.red
  link_heading         = "#5BA57B",  -- c.green
  link_heading_broken  = "#DD7F67",  -- c.peach
  link_self            = "#9A85AE",  -- c.lavender
  link_alias           = "#1A7DA4",  -- c.accent
  link_bracket         = "#CAC1B9",  -- c.surface2

  tag_default          = "#9A85AE",  -- c.lavender
  tag_project          = "#1A7DA4",  -- c.accent
  tag_status           = "#5BA57B",  -- c.green
  tag_type             = "#D19548",  -- c.yellow
  tag_person           = "#669EA6",  -- c.teal
  tag_hash             = "#CAC1B9",  -- c.surface2

  field_bracket        = "#CAC1B9",  -- c.surface2
  field_key            = "#BA7184",  -- c.red
  field_sep            = "#CAC1B9",  -- c.surface2
  field_value          = "#5BA57B",  -- c.green
  field_value_date     = "#669EA6",  -- c.teal
  field_value_number   = "#DD7F67",  -- c.peach
  field_value_link     = "#1A7DA4",  -- c.accent
  field_value_bool     = "#286983",  -- c.sky

  highlight_bg         = "#E2C6A1",  -- c.search_active_bg
  highlight_fg         = "#4C4F69",  -- c.fg
  highlight_delim      = "#CAC1B9",  -- c.surface2

  autolink_hint_sp     = "#CAC1B9",  -- c.surface2
  autolink_icon        = "#CAC1B9",  -- c.surface2

  embed_content        = "#9A85AE",  -- c.lavender
  embed_border         = "#8D8D8D",  -- c.mauve
  embed_cycle          = "#BA7184",  -- c.red
  embed_depth          = "#D19548",  -- c.yellow
  embed_truncated      = "#D19548",  -- c.yellow
  embed_error          = "#BA7184",  -- c.red

  -- Preview breadcrumbs
  preview_breadcrumb_path     = "#CAC1B9",  -- c.surface2
  preview_breadcrumb_note     = "#1A7DA4",  -- c.accent
  preview_breadcrumb_sep      = "#CAC1B9",  -- c.surface2
  preview_breadcrumb_fragment = "#5BA57B",  -- c.green

  -- Footnotes
  footnote_ref           = "#669EA6",  -- c.teal
  footnote_def           = "#CAC1B9",  -- c.surface2
  footnote_content       = "#9A85AE",  -- c.lavender
  footnote_border        = "#8D8D8D",  -- c.mauve
  footnote_orphan        = "#BA7184",  -- c.red

  calendar_header      = "#1A7DA4",  -- c.accent
  calendar_today_fg    = "#EEE6DD",  -- c.bg
  calendar_today_bg    = "#5BA57B",  -- c.green
  calendar_has_log     = "#D19548",  -- c.yellow
  calendar_deadline    = "#669EA6",  -- c.teal
  calendar_log_dead_fg = "#EEE6DD",  -- c.bg
  calendar_log_dead_bg = "#DD7F67",  -- c.peach
  calendar_weekend     = "#D270A2",  -- c.pink
  calendar_dim         = "#CAC1B9",  -- c.surface2
  calendar_legend      = "#8D8D8D",  -- c.mauve
  calendar_scheduled   = "#9A85AE",  -- c.lavender

  -- Kanban
  kanban_header        = "#1A7DA4",  -- c.accent
  kanban_overdue       = "#BA7184",  -- c.red
  kanban_due_today     = "#D19548",  -- c.yellow
  kanban_p1            = "#BA7184",  -- c.red
  kanban_p2            = "#DD7F67",  -- c.peach
  kanban_default       = "#4C4F69",  -- c.fg
  kanban_divider       = "#CAC1B9",  -- c.surface2

  -- Timeline
  timeline_overdue     = "#BA7184",  -- c.red
  timeline_today       = "#D19548",  -- c.yellow
  timeline_upcoming    = "#5BA57B",  -- c.green
  timeline_overdue_bg  = "#BA7184",  -- c.red
  timeline_task        = "#4C4F69",  -- c.fg
  timeline_dim         = "#CAC1B9",  -- c.surface2
  timeline_undated     = "#9A85AE",  -- c.lavender

  -- Timeline (additional)
  timeline_header      = "#5BA57B",  -- c.green
  timeline_priority    = "#9A85AE",  -- c.lavender

  -- Hierarchy
  hierarchy_progress   = "#D19548",  -- c.yellow
  hierarchy_complete   = "#5BA57B",  -- c.green
  hierarchy_connector  = "#CAC1B9",  -- c.surface2
  hierarchy_parent     = "#4C4F69",  -- c.fg

  graph_existing       = "#1A7DA4",  -- c.accent
  graph_unresolved     = "#BA7184",  -- c.red

  query_border         = "#9A85AE",  -- c.lavender
  query_link           = "#1A7DA4",  -- c.accent

  -- Sidebar
  sidebar_tab_active   = "#1A7DA4",  -- c.accent
  sidebar_tab_inactive = "#CAC1B9",  -- c.surface2
  sidebar_sep          = "#CAC1B9",  -- c.surface2
  sidebar_header       = "#9A85AE",  -- c.lavender
  sidebar_file         = "#4C4F69",  -- c.fg
  sidebar_context      = "#CAC1B9",  -- c.surface2
  sidebar_line_nr      = "#CAC1B9",  -- c.surface2
  sidebar_field_key    = "#BA7184",  -- c.red
  sidebar_field_value  = "#5BA57B",  -- c.green
  sidebar_tag          = "#9A85AE",  -- c.lavender
  sidebar_count        = "#CAC1B9",  -- c.surface2
  sidebar_empty        = "#CAC1B9",  -- c.surface2
  sidebar_cursor       = "#1A7DA4",  -- c.accent
}

--- Soft Paper Dark palette.
--- Source: lua/andrew/themes/soft-paper.lua, M.palettes.dark
local soft_paper_dark = {
  link_valid           = "#11B7C5",  -- c.accent
  link_broken          = "#E78284",  -- c.red
  link_heading         = "#67C48F",  -- c.green
  link_heading_broken  = "#EF9F76",  -- c.peach
  link_self            = "#BB93D6",  -- c.lavender
  link_alias           = "#11B7C5",  -- c.accent
  link_bracket         = "#62677E",  -- c.surface2

  tag_default          = "#BB93D6",  -- c.lavender
  tag_project          = "#11B7C5",  -- c.accent
  tag_status           = "#67C48F",  -- c.green
  tag_type             = "#C9BE3E",  -- c.yellow
  tag_person           = "#11B7C5",  -- c.teal
  tag_hash             = "#62677E",  -- c.surface2

  field_bracket        = "#62677E",  -- c.surface2
  field_key            = "#E78284",  -- c.red
  field_sep            = "#62677E",  -- c.surface2
  field_value          = "#67C48F",  -- c.green
  field_value_date     = "#11B7C5",  -- c.teal
  field_value_number   = "#EF9F76",  -- c.peach
  field_value_link     = "#11B7C5",  -- c.accent
  field_value_bool     = "#99D1DB",  -- c.sky

  highlight_bg         = "#6D6B43",  -- c.search_active_bg
  highlight_fg         = "#C6CEEF",  -- c.fg
  highlight_delim      = "#62677E",  -- c.surface2

  autolink_hint_sp     = "#62677E",  -- c.surface2
  autolink_icon        = "#62677E",  -- c.surface2

  embed_content        = "#BB93D6",  -- c.lavender
  embed_border         = "#8D8D8D",  -- c.mauve
  embed_cycle          = "#E78284",  -- c.red
  embed_depth          = "#C9BE3E",  -- c.yellow
  embed_truncated      = "#C9BE3E",  -- c.yellow
  embed_error          = "#E78284",  -- c.red

  -- Preview breadcrumbs
  preview_breadcrumb_path     = "#62677E",  -- c.surface2
  preview_breadcrumb_note     = "#11B7C5",  -- c.accent
  preview_breadcrumb_sep      = "#62677E",  -- c.surface2
  preview_breadcrumb_fragment = "#67C48F",  -- c.green

  -- Footnotes
  footnote_ref           = "#11B7C5",  -- c.teal
  footnote_def           = "#62677E",  -- c.surface2
  footnote_content       = "#BB93D6",  -- c.lavender
  footnote_border        = "#8D8D8D",  -- c.mauve
  footnote_orphan        = "#E78284",  -- c.red

  calendar_header      = "#11B7C5",  -- c.accent
  calendar_today_fg    = "#303446",  -- c.bg
  calendar_today_bg    = "#67C48F",  -- c.green
  calendar_has_log     = "#C9BE3E",  -- c.yellow
  calendar_deadline    = "#11B7C5",  -- c.teal
  calendar_log_dead_fg = "#303446",  -- c.bg
  calendar_log_dead_bg = "#EF9F76",  -- c.peach
  calendar_weekend     = "#E58BB9",  -- c.pink
  calendar_dim         = "#62677E",  -- c.surface2
  calendar_legend      = "#8D8D8D",  -- c.mauve
  calendar_scheduled   = "#BB93D6",  -- c.lavender

  -- Kanban
  kanban_header        = "#11B7C5",  -- c.accent
  kanban_overdue       = "#E78284",  -- c.red
  kanban_due_today     = "#C9BE3E",  -- c.yellow
  kanban_p1            = "#E78284",  -- c.red
  kanban_p2            = "#EF9F76",  -- c.peach
  kanban_default       = "#C6CEEF",  -- c.fg
  kanban_divider       = "#62677E",  -- c.surface2

  -- Timeline
  timeline_overdue     = "#E78284",  -- c.red
  timeline_today       = "#C9BE3E",  -- c.yellow
  timeline_upcoming    = "#67C48F",  -- c.green
  timeline_overdue_bg  = "#E78284",  -- c.red
  timeline_task        = "#C6CEEF",  -- c.fg
  timeline_dim         = "#62677E",  -- c.surface2
  timeline_undated     = "#BB93D6",  -- c.lavender

  -- Timeline (additional)
  timeline_header      = "#67C48F",  -- c.green
  timeline_priority    = "#BB93D6",  -- c.lavender

  -- Hierarchy
  hierarchy_progress   = "#C9BE3E",  -- c.yellow
  hierarchy_complete   = "#67C48F",  -- c.green
  hierarchy_connector  = "#62677E",  -- c.surface2
  hierarchy_parent     = "#C6CEEF",  -- c.fg

  graph_existing       = "#11B7C5",  -- c.accent
  graph_unresolved     = "#E78284",  -- c.red

  query_border         = "#BB93D6",  -- c.lavender
  query_link           = "#11B7C5",  -- c.accent

  -- Sidebar
  sidebar_tab_active   = "#11B7C5",  -- c.accent
  sidebar_tab_inactive = "#62677E",  -- c.surface2
  sidebar_sep          = "#62677E",  -- c.surface2
  sidebar_header       = "#BB93D6",  -- c.lavender
  sidebar_file         = "#C6CEEF",  -- c.fg
  sidebar_context      = "#62677E",  -- c.surface2
  sidebar_line_nr      = "#62677E",  -- c.surface2
  sidebar_field_key    = "#E78284",  -- c.red
  sidebar_field_value  = "#67C48F",  -- c.green
  sidebar_tag          = "#BB93D6",  -- c.lavender
  sidebar_count        = "#62677E",  -- c.surface2
  sidebar_empty        = "#62677E",  -- c.surface2
  sidebar_cursor       = "#11B7C5",  -- c.accent
}

--- Registry: colorscheme name pattern -> palette.
--- Checked in order; first match wins. Falls back to onedark.
local scheme_palettes = {
  { pattern = "^soft%-paper%-light$", palette = soft_paper_light },
  { pattern = "^soft%-paper%-dark$",  palette = soft_paper_dark },
  { pattern = "^soft%-paper",         palette = soft_paper_light },
  -- Default: OneDark covers onedark, onedark_vivid, onedark_dark, etc.
  { pattern = ".",                    palette = onedark },
}

-- ---------------------------------------------------------------------------
-- Colorscheme detection
-- ---------------------------------------------------------------------------

--- Detect the active colorscheme and return the appropriate palette.
---@return table<string, string>
local function detect_palette()
  local name = vim.g.colors_name or ""
  for _, entry in ipairs(scheme_palettes) do
    if name:match(entry.pattern) then
      return entry.palette
    end
  end
  return onedark
end

-- ---------------------------------------------------------------------------
-- Highlight group builder
-- ---------------------------------------------------------------------------

--- Build highlight group definitions from a palette.
---@param p table<string, string> palette
---@return table<string, table>
local function build_hl_groups(p)
  return {
    -- Wikilinks
    VaultWikiLinkValid         = { fg = p.link_valid, underline = true },
    VaultWikiLinkBroken        = { fg = p.link_broken, undercurl = true, sp = p.link_broken },
    VaultWikiLinkHeading       = { fg = p.link_heading, italic = true },
    VaultWikiLinkHeadingBroken = { fg = p.link_heading_broken, undercurl = true, sp = p.link_heading_broken },
    VaultWikiLinkSelf          = { fg = p.link_self, italic = true },
    VaultWikiLinkAlias         = { fg = p.link_alias, bold = true },
    VaultWikiLinkBracket       = { fg = p.link_bracket },

    -- Tags
    VaultTag                   = { fg = p.tag_default, bold = true },
    VaultTagProject            = { fg = p.tag_project, bold = true },
    VaultTagStatus             = { fg = p.tag_status, bold = true },
    VaultTagType               = { fg = p.tag_type, bold = true },
    VaultTagPerson             = { fg = p.tag_person, bold = true },
    VaultTagHash               = { fg = p.tag_hash },

    -- Inline fields
    VaultFieldBracket          = { fg = p.field_bracket },
    VaultFieldKey              = { fg = p.field_key, bold = true },
    VaultFieldSep              = { fg = p.field_sep },
    VaultFieldValue            = { fg = p.field_value },
    VaultFieldValueDate        = { fg = p.field_value_date },
    VaultFieldValueNumber      = { fg = p.field_value_number },
    VaultFieldValueLink        = { fg = p.field_value_link, underline = true },
    VaultFieldValueBool        = { fg = p.field_value_bool, italic = true },

    -- Highlight marks (==text==)
    VaultHighlight             = { bg = p.highlight_bg, fg = p.highlight_fg },
    VaultHighlightDelim        = { fg = p.highlight_delim },

    -- Autolinks
    VaultAutoLinkHint          = { underline = true, sp = p.autolink_hint_sp },
    VaultAutoLinkIcon          = { fg = p.autolink_icon },

    -- Embeds
    VaultEmbedContent          = { italic = true, fg = p.embed_content },
    VaultEmbedBorder           = { fg = p.embed_border },
    VaultEmbedCycle            = { italic = true, fg = p.embed_cycle },
    VaultEmbedDepth            = { italic = true, fg = p.embed_depth },
    VaultEmbedTruncated        = { italic = true, fg = p.embed_truncated },
    VaultEmbedError            = { italic = true, fg = p.embed_error },

    -- Preview breadcrumbs
    VaultPreviewBreadcrumbPath     = { fg = p.preview_breadcrumb_path },
    VaultPreviewBreadcrumbNote     = { fg = p.preview_breadcrumb_note, bold = true },
    VaultPreviewBreadcrumbSep      = { fg = p.preview_breadcrumb_sep },
    VaultPreviewBreadcrumbFragment = { fg = p.preview_breadcrumb_fragment, italic = true },

    -- Footnotes
    VaultFootnoteRef           = { fg = p.footnote_ref, bold = true },
    VaultFootnoteDef           = { fg = p.footnote_def, italic = true },
    VaultFootnoteContent       = { italic = true, fg = p.footnote_content },
    VaultFootnoteBorder        = { fg = p.footnote_border },
    VaultFootnoteOrphan        = { fg = p.footnote_orphan, undercurl = true, sp = p.footnote_orphan },

    -- Calendar
    VaultCalendarHeader        = { bold = true, fg = p.calendar_header },
    VaultCalendarToday         = { bold = true, fg = p.calendar_today_fg, bg = p.calendar_today_bg },
    VaultCalendarHasLog        = { bold = true, fg = p.calendar_has_log },
    VaultCalendarDeadline      = { bold = true, fg = p.calendar_deadline },
    VaultCalendarLogDeadline   = { bold = true, fg = p.calendar_log_dead_fg, bg = p.calendar_log_dead_bg },
    VaultCalendarScheduled     = { bold = true, fg = p.calendar_scheduled },
    VaultCalendarWeekend       = { fg = p.calendar_weekend },
    VaultCalendarDim           = { fg = p.calendar_dim },
    VaultCalendarLegend        = { fg = p.calendar_legend },

    -- Kanban
    VaultKanbanHeader          = { bold = true, fg = p.kanban_header },
    VaultKanbanOverdue         = { bold = true, fg = p.kanban_overdue },
    VaultKanbanDueToday        = { bold = true, fg = p.kanban_due_today },
    VaultKanbanP1              = { fg = p.kanban_p1 },
    VaultKanbanP2              = { fg = p.kanban_p2 },
    VaultKanbanDefault         = { fg = p.kanban_default },
    VaultKanbanDivider         = { fg = p.kanban_divider },

    -- Timeline
    VaultTimelineOverdue       = { bold = true, fg = p.timeline_overdue },
    VaultTimelineToday         = { bold = true, fg = p.timeline_today },
    VaultTimelineUpcoming      = { bold = true, fg = p.timeline_upcoming },
    VaultTimelineOverdueBadge  = { fg = p.calendar_today_fg, bg = p.timeline_overdue_bg },
    VaultTimelineTask          = { fg = p.timeline_task },
    VaultTimelineDim           = { fg = p.timeline_dim },
    VaultTimelineUndated       = { italic = true, fg = p.timeline_undated },
    VaultTimelineHeader        = { bold = true, fg = p.timeline_header },
    VaultTimelinePriority      = { bold = true, fg = p.timeline_priority },

    -- Hierarchy
    VaultHierarchyProgress     = { italic = true, fg = p.hierarchy_progress },
    VaultHierarchyComplete     = { italic = true, fg = p.hierarchy_complete },
    VaultHierarchyConnector    = { fg = p.hierarchy_connector },
    VaultHierarchyParent       = { bold = true },

    -- Graph (linked groups are theme-independent, hardcoded groups use palette)
    VaultGraphDivider          = { link = "FloatBorder" },
    VaultGraphConnector        = { link = "NonText" },
    VaultGraphCount            = { link = "Comment" },
    VaultGraphExistingLink     = { fg = p.graph_existing, bold = true },
    VaultGraphUnresolvedLink   = { fg = p.graph_unresolved, italic = true },

    -- Query
    VaultQueryBorder           = { fg = p.query_border },
    VaultQueryHeader           = { link = "@markup.heading" },
    VaultQueryValue            = { link = "Normal" },
    VaultQueryNull             = { link = "Comment" },
    VaultQueryError            = { link = "DiagnosticError" },
    VaultQueryTaskDone         = { link = "Comment" },
    VaultQueryTaskOpen         = { link = "Normal" },
    VaultQueryGroupHeader      = { link = "Title" },
    VaultQueryLink             = { fg = p.query_link, bold = true },

    -- Sidebar
    VaultSidebarTabActive      = { fg = p.sidebar_tab_active, bold = true },
    VaultSidebarTabInactive    = { fg = p.sidebar_tab_inactive },
    VaultSidebarSep            = { fg = p.sidebar_sep },
    VaultSidebarHeader         = { fg = p.sidebar_header, bold = true },
    VaultSidebarFile           = { fg = p.sidebar_file, bold = true },
    VaultSidebarContext        = { fg = p.sidebar_context, italic = true },
    VaultSidebarLineNr         = { fg = p.sidebar_line_nr },
    VaultSidebarFieldKey       = { fg = p.sidebar_field_key, bold = true },
    VaultSidebarFieldValue     = { fg = p.sidebar_field_value },
    VaultSidebarTag            = { fg = p.sidebar_tag, bold = true },
    VaultSidebarCount          = { fg = p.sidebar_count },
    VaultSidebarEmpty          = { fg = p.sidebar_empty, italic = true },
    VaultSidebarCursor         = { fg = p.sidebar_cursor, bold = true },
  }
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- (Re-)define all Vault highlight groups based on the active colorscheme.
--- Called at setup time and on every ColorScheme event.
local function define_highlights()
  local p = detect_palette()
  M.palette = p

  local groups = build_hl_groups(p)
  for group, attrs in pairs(groups) do
    attrs.default = true
    vim.api.nvim_set_hl(0, group, attrs)
  end
end

--- Setup: define highlights now and register ColorScheme autocmd.
--- Call this once from the vault initialization path (init.lua).
function M.setup()
  define_highlights()

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("VaultColors", { clear = true }),
    callback = function()
      define_highlights()
    end,
    desc = "Vault: re-apply highlight groups for new colorscheme",
  })
end

return M
