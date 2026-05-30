-- =============================================================================
-- Soft Paper Theme for Neovim
-- =============================================================================
-- Faithfully ported from:
--   https://github.com/nickmilo/soft-paper (Obsidian theme by Nick Milo)
--   https://github.com/AnubisNekhet/AnuPpuccin (structural base)
--
-- Light: Rose Pine Light base tones with soft-paper accent overrides.
-- Dark:  Catppuccin Frappe base with soft-paper accent overrides.
--
-- Palette values are extracted directly from the theme.css source.
-- Pre-computed blend colors match the CSS rgba() compositing over base.

local M = {}

-- =============================================================================
-- Color Palettes
-- =============================================================================

M.palettes = {
  -- =========================================================================
  -- LIGHT: Rose Pine Light base + Nick Milo's soft-paper overrides
  -- Source: .theme-light section of theme.css
  -- =========================================================================
  light = {
    -- Backgrounds (Rose Pine Light — warm paper tones)
    bg            = "#EEE6DD",  -- ctp-base: primary background (warm cream)
    bg_alt        = "#E6DBD1",  -- ctp-mantle: secondary bg, sidebar, status bar
    bg_dark       = "#DDD0C6",  -- ctp-crust: code blocks, tertiary bg

    -- Surfaces (warm neutral ramp)
    surface0      = "#DCD3CB",  -- ctp-surface0: interactive-normal
    surface1      = "#D1C9C2",  -- ctp-surface1: borders (light-mode specific)
    surface2      = "#CAC1B9",  -- ctp-surface2: border-hover, scrollbar
    gutter_bg     = "#B8D4E3",  -- helix soft-paper-light gutter (pale blue)
    gutter_fg     = "#3E6E75",  -- line number foreground (dark teal)
    gutter_cur_bg = "#5B8E94",  -- current line gutter background (deeper teal)
    gutter_cur_fg = "#E2F1F3",  -- current line number foreground (light teal)

    -- Text hierarchy
    fg            = "#4C4F69",  -- AnuPpuccin Latte --ctp-text: primary text
    fg_dim        = "#525252",  -- ctp-overlay2: text-muted
    fg_faint      = "#797593",  -- Rose Pine subtle: line numbers, ghost text

    -- Primary accent — sapphire throughout
    accent        = "#1A7DA4",  -- ctp-sapphire: links, active elements, accent
    accent_soft   = "#4B8FAB",  -- Softer sapphire: active sidebar tab (CSS hardcoded)
    cursor_bg     = "#1A7DA4",  -- sapphire accent: block/bar cursor background
    cursor_fg     = "#FFFFFF",  -- letter under the block cursor

    -- Semantic accent palette (all from .theme-light --ctp-* definitions)
    red           = "#BA7184",  -- ctp-red: bold, H1, errors, danger
    maroon        = "#B4637A",  -- ctp-maroon: failure callouts
    peach         = "#DD7F67",  -- ctp-peach: H2, orange, warm emphasis
    yellow        = "#D19548",  -- ctp-yellow: search, warnings, highlights
    green         = "#5BA57B",  -- ctp-green: italic, H4, success, strings
    teal          = "#669EA6",  -- ctp-teal: H3, info callouts, labels
    sky           = "#286983",  -- ctp-sky: operators, deep blue
    blue          = "#286983",  -- ctp-blue: same as sky in soft-paper light
    pink          = "#D270A2",  -- ctp-pink: preprocessor, imports
    lavender      = "#9A85AE",  -- ctp-lavender: H5, statements, keywords
    mauve         = "#8D8D8D",  -- ctp-mauve: H6, comments (intentionally gray)
    flamingo      = "#D6817D",  -- ctp-flamingo: special chars, constructors
    rosewater     = "#BC708D",  -- ctp-rosewater

    -- Pre-computed blends (CSS rgba() composited over base #EEE6DD)
    cursorline_bg    = "#E2DAD2",  -- rgba(surface1, 0.4) — AnuPpuccin active line
    visual_bg        = "#B9CCCF",  -- rgba(accent, 0.25) — text selection
    search_bg        = "#E8D6BF",  -- rgba(yellow, 0.2) — search highlight
    search_active_bg = "#E2C6A1",  -- rgba(yellow, 0.4) — active search match
    diff_add_bg      = "#DCDED1",  -- rgba(green, 0.12) — subtle diff add
    diff_del_bg      = "#E8D8D2",  -- rgba(red, 0.12) — subtle diff delete
    diff_change_bg   = "#EBDCCB",  -- rgba(yellow, 0.12) — subtle diff change
    hover_bg         = "#E3DBD6",  -- rgba(text, 0.075) — hover/suggestion
    blockquote_bg    = "#E6DBD2",  -- rgba(crust, 0.5) — blockquote fill

    none          = "NONE",
  },

  -- =========================================================================
  -- DARK: Catppuccin Frappe base + Nick Milo's soft-paper overrides
  -- Source: .theme-dark section of theme.css
  -- =========================================================================
  dark = {
    bg            = "#303446",
    bg_alt        = "#292C3C",
    bg_dark       = "#232634",
    surface0      = "#414559",
    surface1      = "#51566C",
    surface2      = "#62677E",
    gutter_bg     = "#303446",  -- line number / sign column background (matches bg)
    fg            = "#C6CEEF",
    fg_dim        = "#B5BDDC",
    fg_faint      = "#A5ADCE",
    accent        = "#11B7C5",
    accent_soft   = "#4B8FAB",
    cursor_bg     = "#11B7C5",  -- teal accent: block/bar cursor background
    cursor_fg     = "#FFFFFF",  -- letter under the block cursor
    red           = "#E78284",
    maroon        = "#EA999C",
    peach         = "#EF9F76",
    yellow        = "#C9BE3E",
    green         = "#67C48F",
    teal          = "#11B7C5",
    sky           = "#99D1DB",
    blue          = "#8CAAEE",
    pink          = "#E58BB9",
    lavender      = "#BB93D6",
    mauve         = "#8D8D8D",
    flamingo      = "#EEBEBE",
    rosewater     = "#BC708D",

    cursorline_bg    = "#414559",  -- surface0
    visual_bg        = "#285566",  -- rgba(accent, 0.25) over base
    search_bg        = "#4F5044",  -- rgba(yellow, 0.2) over base
    search_active_bg = "#6D6B43",  -- rgba(yellow, 0.4) over base
    diff_add_bg      = "#37454F",  -- rgba(green, 0.12) over base
    diff_del_bg      = "#463D4D",  -- rgba(red, 0.12) over base
    diff_change_bg   = "#424545",  -- rgba(yellow, 0.12) over base
    hover_bg         = "#414559",  -- surface0
    blockquote_bg    = "#292C3C",  -- mantle

    none          = "NONE",
  },
}

-- =============================================================================
-- Highlight Definitions
-- =============================================================================

--- Build highlight table from palette
---@param c table color palette
---@return table<string, table>
local function build_highlights(c)
  return {
    -- =========================================================================
    -- Editor UI
    -- =========================================================================
    Normal         = { fg = c.fg, bg = c.bg },
    NormalNC       = { fg = c.fg, bg = c.bg },
    NormalFloat    = { fg = c.fg, bg = c.bg_alt },
    FloatBorder    = { fg = c.accent, bg = c.bg_alt },
    FloatTitle     = { fg = c.accent, bg = c.bg_alt, bold = true },
    ColorColumn    = { bg = c.surface0 },
    Conceal        = { fg = c.mauve },

    -- Cursor: sapphire accent block (matches Obsidian titlebar/accent)
    Cursor         = { fg = c.cursor_fg, bg = c.cursor_bg },
    lCursor        = { fg = c.cursor_fg, bg = c.cursor_bg },
    CursorIM       = { fg = c.cursor_fg, bg = c.cursor_bg },

    -- Active line: AnuPpuccin rgba(surface1, 0.4) blend
    CursorColumn   = { bg = c.cursorline_bg },
    CursorLine     = { bg = c.cursorline_bg },
    CursorLineNr   = { fg = c.gutter_cur_fg, bg = c.gutter_cur_bg, bold = true },

    Directory      = { fg = c.accent },

    -- Diffs: subtle blended backgrounds (not harsh solid colors)
    DiffAdd        = { bg = c.diff_add_bg },
    DiffChange     = { bg = c.diff_change_bg },
    DiffDelete     = { bg = c.diff_del_bg },
    DiffText       = { bg = c.search_active_bg },

    EndOfBuffer    = { fg = c.bg },
    ErrorMsg       = { fg = c.red, bold = true },

    -- Borders: surface1 in light mode per CSS --background-modifier-border
    VertSplit      = { fg = c.surface1 },
    WinSeparator   = { fg = c.surface1 },

    Folded         = { fg = c.fg_faint, bg = c.bg_alt },
    FoldColumn     = { fg = c.surface2, bg = c.gutter_bg },

    -- Gutter: subtle warm tint distinct from editor bg
    SignColumn     = { fg = c.fg_dim, bg = c.gutter_bg },
    LineNr         = { fg = c.gutter_fg, bg = c.gutter_bg },
    LineNrAbove    = { fg = c.gutter_fg, bg = c.gutter_bg },
    LineNrBelow    = { fg = c.gutter_fg, bg = c.gutter_bg },

    -- Search: warm golden highlights from CSS rgba(yellow) blends
    Search         = { bg = c.search_bg, fg = c.fg },
    CurSearch      = { bg = c.search_active_bg, fg = c.fg, bold = true },
    IncSearch      = { bg = c.search_active_bg, fg = c.fg, bold = true },
    Substitute     = { bg = c.search_active_bg, fg = c.fg, bold = true },

    MatchParen     = { fg = c.peach, bold = true, underline = true },
    ModeMsg        = { fg = c.fg, bold = true },
    MsgArea        = { fg = c.fg },
    MoreMsg        = { fg = c.accent },
    NonText        = { fg = c.surface2 },

    -- Popup menu
    Pmenu          = { fg = c.fg, bg = c.bg_alt },
    PmenuSel       = { fg = c.fg, bg = c.hover_bg, bold = true },
    PmenuSbar      = { bg = c.surface0 },
    PmenuThumb     = { bg = c.surface2 },

    Question       = { fg = c.accent },
    QuickFixLine   = { bg = c.hover_bg, bold = true },
    SpecialKey     = { fg = c.surface2 },

    -- Spell: undercurl with palette-matched colors
    SpellBad       = { sp = c.red, undercurl = true },
    SpellCap       = { sp = c.yellow, undercurl = true },
    SpellLocal     = { sp = c.teal, undercurl = true },
    SpellRare      = { sp = c.lavender, undercurl = true },

    -- Status line: mantle bg (matches Obsidian status bar #E6DBD1)
    StatusLine     = { fg = c.fg, bg = c.bg_alt },
    StatusLineNC   = { fg = c.fg_dim, bg = c.bg_dark },

    -- Tabs: inactive on crust, active on base with accent text
    TabLine        = { fg = c.fg_dim, bg = c.bg_dark },
    TabLineFill    = { bg = c.bg_dark },
    TabLineSel     = { fg = c.accent, bg = c.bg, bold = true },

    Title          = { fg = c.accent, bold = true },

    -- Selection: teal-tinted from CSS rgba(accent, 0.25)
    Visual         = { bg = c.visual_bg },
    VisualNOS      = { bg = c.visual_bg },

    WarningMsg     = { fg = c.yellow },
    Whitespace     = { fg = c.surface1 },
    WildMenu       = { fg = c.bg, bg = c.accent },
    WinBar         = { fg = c.fg },
    WinBarNC       = { fg = c.fg_dim },

    -- =========================================================================
    -- Syntax Highlighting
    -- =========================================================================
    -- Bold = ctp-red, Italic = ctp-green (per both AnuPpuccin and soft-paper CSS)
    Comment        = { fg = c.mauve, italic = true },
    Constant       = { fg = c.peach },
    String         = { fg = c.green },
    Character      = { fg = c.green },
    Number         = { fg = c.peach },
    Boolean        = { fg = c.peach },
    Float          = { fg = c.peach },
    Identifier     = { fg = c.fg },
    Function       = { fg = c.accent, bold = true },
    Statement      = { fg = c.lavender },
    Conditional    = { fg = c.lavender },
    Repeat         = { fg = c.lavender },
    Label          = { fg = c.teal },
    Operator       = { fg = c.sky },
    Keyword        = { fg = c.lavender, bold = true },
    Exception      = { fg = c.red },
    PreProc        = { fg = c.pink },
    Include        = { fg = c.pink },
    Define         = { fg = c.pink },
    Macro          = { fg = c.pink },
    PreCondit      = { fg = c.pink },
    Type           = { fg = c.yellow },
    StorageClass   = { fg = c.yellow },
    Structure      = { fg = c.yellow },
    Typedef        = { fg = c.yellow },
    Special        = { fg = c.flamingo },
    SpecialChar    = { fg = c.flamingo },
    Tag            = { fg = c.accent },
    Delimiter      = { fg = c.fg_dim },
    SpecialComment = { fg = c.mauve, italic = true },
    Debug          = { fg = c.peach },
    Underlined     = { fg = c.accent, underline = true },
    Bold           = { bold = true },
    Italic         = { italic = true },
    Ignore         = { fg = c.surface2 },
    Error          = { fg = c.red },
    Todo           = { fg = c.bg, bg = c.accent, bold = true },

    -- =========================================================================
    -- Diagnostics
    -- =========================================================================
    DiagnosticError            = { fg = c.red },
    DiagnosticWarn             = { fg = c.yellow },
    DiagnosticInfo             = { fg = c.accent },
    DiagnosticHint             = { fg = c.teal },
    DiagnosticOk               = { fg = c.green },
    DiagnosticVirtualTextError = { fg = c.red, italic = true },
    DiagnosticVirtualTextWarn  = { fg = c.yellow, italic = true },
    DiagnosticVirtualTextInfo  = { fg = c.accent, italic = true },
    DiagnosticVirtualTextHint  = { fg = c.teal, italic = true },
    DiagnosticVirtualTextOk    = { fg = c.green, italic = true },
    DiagnosticUnderlineError   = { sp = c.red, undercurl = true },
    DiagnosticUnderlineWarn    = { sp = c.yellow, undercurl = true },
    DiagnosticUnderlineInfo    = { sp = c.accent, undercurl = true },
    DiagnosticUnderlineHint    = { sp = c.teal, undercurl = true },
    DiagnosticUnderlineOk      = { sp = c.green, underline = true },

    -- =========================================================================
    -- LSP
    -- =========================================================================
    LspReferenceText           = { bg = c.hover_bg },
    LspReferenceRead           = { bg = c.hover_bg },
    LspReferenceWrite          = { bg = c.hover_bg, bold = true },
    LspSignatureActiveParameter = { fg = c.peach, bold = true },
    LspInfoBorder              = { fg = c.accent },

    -- =========================================================================
    -- Treesitter
    -- =========================================================================
    ["@variable"]               = { fg = c.fg },
    ["@variable.builtin"]       = { fg = c.maroon, italic = true },
    ["@variable.parameter"]     = { fg = c.flamingo, italic = true },
    ["@variable.member"]        = { fg = c.teal },
    ["@constant"]               = { fg = c.peach },
    ["@constant.builtin"]       = { fg = c.peach, bold = true },
    ["@constant.macro"]         = { fg = c.peach },
    ["@module"]                 = { fg = c.lavender },
    ["@label"]                  = { fg = c.teal },
    ["@string"]                 = { fg = c.green },
    ["@string.documentation"]   = { fg = c.green, italic = true },
    ["@string.regexp"]          = { fg = c.flamingo },
    ["@string.escape"]          = { fg = c.pink },
    ["@string.special.symbol"]  = { fg = c.flamingo },
    ["@character"]              = { fg = c.green },
    ["@boolean"]                = { fg = c.peach },
    ["@number"]                 = { fg = c.peach },
    ["@number.float"]           = { fg = c.peach },
    ["@type"]                   = { fg = c.yellow },
    ["@type.builtin"]           = { fg = c.yellow, italic = true },
    ["@type.definition"]        = { fg = c.yellow },
    ["@attribute"]              = { fg = c.yellow },
    ["@property"]               = { fg = c.teal },
    ["@function"]               = { fg = c.accent, bold = true },
    ["@function.builtin"]       = { fg = c.accent },
    ["@function.call"]          = { fg = c.accent },
    ["@function.macro"]         = { fg = c.pink },
    ["@function.method"]        = { fg = c.accent },
    ["@function.method.call"]   = { fg = c.accent },
    ["@constructor"]            = { fg = c.flamingo },
    ["@operator"]               = { fg = c.sky },
    ["@keyword"]                = { fg = c.lavender, bold = true },
    ["@keyword.coroutine"]      = { fg = c.lavender },
    ["@keyword.function"]       = { fg = c.lavender },
    ["@keyword.operator"]       = { fg = c.sky },
    ["@keyword.import"]         = { fg = c.pink },
    ["@keyword.type"]           = { fg = c.lavender },
    ["@keyword.modifier"]       = { fg = c.lavender },
    ["@keyword.repeat"]         = { fg = c.lavender },
    ["@keyword.return"]         = { fg = c.lavender },
    ["@keyword.debug"]          = { fg = c.peach },
    ["@keyword.exception"]      = { fg = c.red },
    ["@keyword.conditional"]    = { fg = c.lavender },
    ["@keyword.directive"]      = { fg = c.pink },
    ["@keyword.directive.define"] = { fg = c.pink },
    ["@punctuation.delimiter"]  = { fg = c.fg_dim },
    ["@punctuation.bracket"]    = { fg = c.fg_dim },
    ["@punctuation.special"]    = { fg = c.flamingo },
    ["@comment"]                = { fg = c.mauve, italic = true },
    ["@comment.documentation"]  = { fg = c.mauve, italic = true },
    ["@comment.error"]          = { fg = c.red, bg = c.none },
    ["@comment.warning"]        = { fg = c.yellow, bg = c.none },
    ["@comment.todo"]           = { fg = c.accent, bg = c.none, bold = true },
    ["@comment.note"]           = { fg = c.teal, bg = c.none },

    -- Markup: bold=red, italic=green per CSS --bold-color/--italic-color
    -- Headings: H1=red H2=peach H3=teal H4=green H5=lavender H6=mauve
    --           per CSS --h1-color through --h6-color
    ["@markup.strong"]          = { fg = c.red, bold = true },
    ["@markup.italic"]          = { fg = c.green, italic = true },
    ["@markup.strikethrough"]   = { fg = c.mauve, strikethrough = true },
    ["@markup.underline"]       = { underline = true },
    ["@markup.heading"]         = { fg = c.accent, bold = true },
    ["@markup.heading.1"]       = { fg = c.red, bold = true },
    ["@markup.heading.2"]       = { fg = c.peach, bold = true },
    ["@markup.heading.3"]       = { fg = c.teal, bold = true },
    ["@markup.heading.4"]       = { fg = c.green, bold = true },
    ["@markup.heading.5"]       = { fg = c.lavender, bold = true },
    ["@markup.heading.6"]       = { fg = c.mauve, bold = true },
    ["@markup.quote"]           = { fg = c.fg_dim, italic = true },
    ["@markup.math"]            = { fg = c.accent },
    ["@markup.link"]            = { fg = c.accent },
    ["@markup.link.label"]      = { fg = c.accent },
    ["@markup.link.url"]        = { fg = c.teal, italic = true },
    ["@markup.raw"]             = { fg = c.flamingo },
    ["@markup.raw.block"]       = { fg = c.fg },
    ["@markup.list"]            = { fg = c.accent },
    ["@markup.list.checked"]    = { fg = c.green },
    ["@markup.list.unchecked"]  = { fg = c.surface2 },
    ["@diff.plus"]              = { fg = c.green },
    ["@diff.minus"]             = { fg = c.red },
    ["@diff.delta"]             = { fg = c.yellow },
    ["@tag"]                    = { fg = c.accent },
    ["@tag.attribute"]          = { fg = c.yellow, italic = true },
    ["@tag.delimiter"]          = { fg = c.fg_dim },

    -- =========================================================================
    -- Git Signs
    -- =========================================================================
    GitSignsAdd                = { fg = c.green },
    GitSignsChange             = { fg = c.yellow },
    GitSignsDelete             = { fg = c.red },
    GitSignsCurrentLineBlame   = { fg = c.surface2, italic = true },

    -- =========================================================================
    -- Telescope
    -- =========================================================================
    TelescopeBorder            = { fg = c.surface1 },
    TelescopeTitle             = { fg = c.accent, bold = true },
    TelescopePromptPrefix      = { fg = c.accent },
    TelescopePromptNormal      = { fg = c.fg, bg = c.bg },
    TelescopePromptBorder      = { fg = c.accent },
    TelescopeResultsNormal     = { fg = c.fg, bg = c.bg },
    TelescopeResultsBorder     = { fg = c.surface1 },
    TelescopePreviewNormal     = { fg = c.fg, bg = c.bg },
    TelescopePreviewBorder     = { fg = c.surface1 },
    TelescopeSelection         = { bg = c.hover_bg, bold = true },
    TelescopeSelectionCaret    = { fg = c.accent },
    TelescopeMatching          = { fg = c.peach, bold = true },

    -- =========================================================================
    -- FZF-Lua
    -- =========================================================================
    FzfLuaBorder               = { fg = c.surface1 },
    FzfLuaTitle                = { fg = c.accent, bold = true },
    FzfLuaCursorLine           = { bg = c.hover_bg },
    FzfLuaSearch               = { fg = c.peach, bold = true },

    -- =========================================================================
    -- Indent Blankline
    -- =========================================================================
    IblIndent                  = { fg = c.surface0 },
    IblScope                   = { fg = c.accent },

    -- =========================================================================
    -- Nvim-cmp
    -- =========================================================================
    CmpItemAbbr                = { fg = c.fg },
    CmpItemAbbrDeprecated      = { fg = c.surface2, strikethrough = true },
    CmpItemAbbrMatch           = { fg = c.accent, bold = true },
    CmpItemAbbrMatchFuzzy      = { fg = c.accent },
    CmpItemKind                = { fg = c.teal },
    CmpItemMenu                = { fg = c.fg_dim },
    CmpItemKindSnippet         = { fg = c.lavender },
    CmpItemKindKeyword         = { fg = c.lavender },
    CmpItemKindText            = { fg = c.fg },
    CmpItemKindMethod          = { fg = c.accent },
    CmpItemKindFunction        = { fg = c.accent },
    CmpItemKindConstructor     = { fg = c.flamingo },
    CmpItemKindVariable        = { fg = c.fg },
    CmpItemKindClass           = { fg = c.yellow },
    CmpItemKindInterface       = { fg = c.yellow },
    CmpItemKindModule          = { fg = c.lavender },
    CmpItemKindProperty        = { fg = c.teal },
    CmpItemKindField           = { fg = c.teal },
    CmpItemKindTypeParameter   = { fg = c.yellow },
    CmpItemKindEnum            = { fg = c.yellow },
    CmpItemKindEnumMember      = { fg = c.peach },
    CmpItemKindConstant        = { fg = c.peach },
    CmpItemKindStruct          = { fg = c.yellow },
    CmpItemKindEvent           = { fg = c.flamingo },
    CmpItemKindOperator        = { fg = c.sky },
    CmpItemKindValue           = { fg = c.peach },

    -- =========================================================================
    -- Which-key
    -- =========================================================================
    WhichKey                   = { fg = c.accent },
    WhichKeyGroup              = { fg = c.lavender },
    WhichKeyDesc               = { fg = c.fg },
    WhichKeySeperator          = { fg = c.surface2 },
    WhichKeySeparator          = { fg = c.surface2 },
    WhichKeyFloat              = { bg = c.bg_alt },
    WhichKeyBorder             = { fg = c.surface1 },
    WhichKeyValue              = { fg = c.fg_dim },

    -- =========================================================================
    -- Nvim-tree / Neo-tree (sidebar panels)
    -- CSS: sidebar bg = --background-secondary (mantle)
    -- Sidebar header = accent bg with cream text
    -- =========================================================================
    NvimTreeNormal             = { fg = c.fg, bg = c.bg_alt },
    NvimTreeNormalNC           = { fg = c.fg, bg = c.bg_alt },
    NvimTreeWinSeparator       = { fg = c.bg_alt, bg = c.bg_alt },
    NvimTreeCursorLine         = { bg = c.hover_bg },
    NvimTreeFolderIcon         = { fg = c.accent },
    NvimTreeFolderName         = { fg = c.accent },
    NvimTreeOpenedFolderName   = { fg = c.accent, bold = true },
    NvimTreeRootFolder         = { fg = c.lavender, bold = true },
    NvimTreeGitDirty           = { fg = c.yellow },
    NvimTreeGitNew             = { fg = c.green },
    NvimTreeGitDeleted         = { fg = c.red },
    NvimTreeSpecialFile        = { fg = c.flamingo },
    NvimTreeIndentMarker       = { fg = c.surface1 },
    NeoTreeNormal              = { fg = c.fg, bg = c.bg_alt },
    NeoTreeNormalNC            = { fg = c.fg, bg = c.bg_alt },
    NeoTreeWinSeparator        = { fg = c.bg_alt, bg = c.bg_alt },
    NeoTreeCursorLine          = { bg = c.hover_bg },

    -- =========================================================================
    -- Notify
    -- =========================================================================
    NotifyERRORBorder          = { fg = c.red },
    NotifyWARNBorder           = { fg = c.yellow },
    NotifyINFOBorder           = { fg = c.accent },
    NotifyDEBUGBorder          = { fg = c.mauve },
    NotifyTRACEBorder          = { fg = c.lavender },
    NotifyERRORIcon            = { fg = c.red },
    NotifyWARNIcon             = { fg = c.yellow },
    NotifyINFOIcon             = { fg = c.accent },
    NotifyDEBUGIcon            = { fg = c.mauve },
    NotifyTRACEIcon            = { fg = c.lavender },
    NotifyERRORTitle           = { fg = c.red },
    NotifyWARNTitle            = { fg = c.yellow },
    NotifyINFOTitle            = { fg = c.accent },
    NotifyDEBUGTitle           = { fg = c.mauve },
    NotifyTRACETitle           = { fg = c.lavender },

    -- =========================================================================
    -- Render-markdown
    -- Headings match CSS: H1=red H2=peach H3=teal H4=green H5=lavender H6=mauve
    -- Code bg = crust per CSS --code-background: var(--background-secondary-alt)
    -- =========================================================================
    RenderMarkdownH1           = { fg = c.red, bold = true },
    RenderMarkdownH1Bg         = { fg = c.red, bg = c.diff_del_bg, bold = true },
    RenderMarkdownH2           = { fg = c.peach, bold = true },
    RenderMarkdownH2Bg         = { fg = c.peach, bg = c.diff_change_bg, bold = true },
    RenderMarkdownH3           = { fg = c.teal, bold = true },
    RenderMarkdownH3Bg         = { fg = c.teal, bg = c.hover_bg, bold = true },
    RenderMarkdownH4           = { fg = c.green, bold = true },
    RenderMarkdownH4Bg         = { fg = c.green, bg = c.diff_add_bg, bold = true },
    RenderMarkdownH5           = { fg = c.lavender, bold = true },
    RenderMarkdownH5Bg         = { fg = c.lavender, bg = c.hover_bg, bold = true },
    RenderMarkdownH6           = { fg = c.mauve, bold = true },
    RenderMarkdownH6Bg         = { fg = c.mauve, bg = c.hover_bg, bold = true },
    RenderMarkdownCode         = { bg = c.bg_dark },
    RenderMarkdownCodeInline   = { fg = c.flamingo },
    RenderMarkdownBullet       = { fg = c.accent },
    RenderMarkdownQuote        = { fg = c.fg_dim, italic = true },
    RenderMarkdownDash         = { fg = c.surface2 },
    RenderMarkdownLink         = { fg = c.accent },
    RenderMarkdownMath         = { fg = c.accent },
    RenderMarkdownChecked        = { fg = c.green },
    RenderMarkdownUnchecked      = { fg = c.surface2 },
    RenderMarkdownCheckedScope   = { fg = c.fg_faint, strikethrough = true },
    RenderMarkdownCancelledScope = { fg = c.fg_faint, strikethrough = true },

    -- =========================================================================
    -- Snacks
    -- =========================================================================
    SnacksIndent               = { fg = c.surface0 },
    SnacksIndentScope          = { fg = c.accent },

    -- =========================================================================
    -- Bufferline
    -- CSS: inactive tab bg = --background-secondary-alt (crust)
    --      active tab bg = --background-primary (base)
    --      active tab text = #1A7DA4 (accent, hardcoded in CSS)
    --      inactive tab text = --text-faint
    --      tab container bg = accent
    -- =========================================================================
    BufferLineFill             = { bg = c.bg_dark },
    BufferLineBackground      = { fg = c.fg_faint, bg = c.bg_dark },
    BufferLineBuffer           = { fg = c.fg_faint, bg = c.bg_dark },
    BufferLineBufferSelected   = { fg = c.accent, bg = c.bg, bold = true },
    BufferLineBufferVisible    = { fg = c.fg_dim, bg = c.bg },
    BufferLineTab              = { fg = c.fg_faint, bg = c.bg_dark },
    BufferLineTabSelected      = { fg = c.accent, bg = c.bg, bold = true },
    BufferLineTabClose         = { fg = c.red, bg = c.bg_dark },
    BufferLineSeparator        = { fg = c.bg_dark, bg = c.bg_dark },
    BufferLineSeparatorSelected = { fg = c.bg_dark, bg = c.bg },
    BufferLineSeparatorVisible = { fg = c.bg_dark, bg = c.bg },
    BufferLineIndicatorSelected = { fg = c.accent },
    BufferLineModified         = { fg = c.yellow },
    BufferLineModifiedSelected = { fg = c.yellow, bg = c.bg },
    BufferLineCloseButton      = { fg = c.fg_faint, bg = c.bg_dark },
    BufferLineCloseButtonSelected = { fg = c.red, bg = c.bg },

    -- =========================================================================
    -- Trouble
    -- =========================================================================
    TroubleNormal              = { fg = c.fg, bg = c.bg_alt },
    TroubleNormalNC            = { fg = c.fg, bg = c.bg_alt },
  }
end

-- =============================================================================
-- Terminal Colors
-- =============================================================================

---@param c table color palette
local function set_terminal_colors(c)
  vim.g.terminal_color_0  = c.bg_dark
  vim.g.terminal_color_1  = c.red
  vim.g.terminal_color_2  = c.green
  vim.g.terminal_color_3  = c.yellow
  vim.g.terminal_color_4  = c.blue
  vim.g.terminal_color_5  = c.pink
  vim.g.terminal_color_6  = c.teal
  vim.g.terminal_color_7  = c.fg
  vim.g.terminal_color_8  = c.surface2
  vim.g.terminal_color_9  = c.red
  vim.g.terminal_color_10 = c.green
  vim.g.terminal_color_11 = c.yellow
  vim.g.terminal_color_12 = c.blue
  vim.g.terminal_color_13 = c.pink
  vim.g.terminal_color_14 = c.teal
  vim.g.terminal_color_15 = c.fg
end

-- =============================================================================
-- Lualine Theme
-- =============================================================================

--- Build a lualine theme from palette
--- Light: warm papery gradient matching Obsidian status bar (#E6DBD1 default)
--- Mode indicator matches the Obsidian titlebar accent convention.
---@param c table color palette
---@param variant "light"|"dark" active variant
---@return table
function M.lualine_theme(c, variant)
  if variant == "light" then
    return {
      normal = {
        a = { bg = c.accent, fg = c.bg, gui = "bold" },
        b = { bg = c.bg_dark, fg = c.fg },
        c = { bg = c.bg_alt, fg = c.fg_dim },
      },
      insert = {
        a = { bg = c.green, fg = c.bg, gui = "bold" },
        b = { bg = c.bg_dark, fg = c.fg },
        c = { bg = c.bg_alt, fg = c.fg_dim },
      },
      visual = {
        a = { bg = c.maroon, fg = c.bg, gui = "bold" },
        b = { bg = c.bg_dark, fg = c.fg },
        c = { bg = c.bg_alt, fg = c.fg_dim },
      },
      command = {
        a = { bg = c.yellow, fg = c.bg, gui = "bold" },
        b = { bg = c.bg_dark, fg = c.fg },
        c = { bg = c.bg_alt, fg = c.fg_dim },
      },
      replace = {
        a = { bg = c.red, fg = c.bg, gui = "bold" },
        b = { bg = c.bg_dark, fg = c.fg },
        c = { bg = c.bg_alt, fg = c.fg_dim },
      },
      inactive = {
        a = { bg = c.bg_alt, fg = c.surface2, gui = "bold" },
        b = { bg = c.bg_alt, fg = c.surface2 },
        c = { bg = c.bg_alt, fg = c.surface2 },
      },
    }
  else
    return {
      normal = {
        a = { bg = c.accent, fg = c.bg, gui = "bold" },
        b = { bg = c.surface0, fg = c.fg },
        c = { bg = c.bg_alt, fg = c.fg },
      },
      insert = {
        a = { bg = c.green, fg = c.bg, gui = "bold" },
        b = { bg = c.surface0, fg = c.fg },
        c = { bg = c.bg_alt, fg = c.fg },
      },
      visual = {
        a = { bg = c.lavender, fg = c.bg, gui = "bold" },
        b = { bg = c.surface0, fg = c.fg },
        c = { bg = c.bg_alt, fg = c.fg },
      },
      command = {
        a = { bg = c.yellow, fg = c.bg, gui = "bold" },
        b = { bg = c.surface0, fg = c.fg },
        c = { bg = c.bg_alt, fg = c.fg },
      },
      replace = {
        a = { bg = c.red, fg = c.bg, gui = "bold" },
        b = { bg = c.surface0, fg = c.fg },
        c = { bg = c.bg_alt, fg = c.fg },
      },
      inactive = {
        a = { bg = c.bg_dark, fg = c.fg_dim, gui = "bold" },
        b = { bg = c.bg_dark, fg = c.fg_dim },
        c = { bg = c.bg_dark, fg = c.fg_dim },
      },
    }
  end
end

-- =============================================================================
-- Apply Theme
-- =============================================================================

---@param variant "light"|"dark" which palette to use
function M.load(variant)
  local c = M.palettes[variant]
  if not c then
    vim.notify("soft-paper: unknown variant '" .. variant .. "'", vim.log.levels.ERROR)
    return
  end

  if vim.g.colors_name then
    vim.cmd("hi clear")
  end
  if vim.fn.exists("syntax_on") then
    vim.cmd("syntax reset")
  end

  vim.o.termguicolors = true
  vim.o.background = variant == "light" and "light" or "dark"
  vim.g.colors_name = "soft-paper-" .. variant

  local highlights = build_highlights(c)
  for group, attrs in pairs(highlights) do
    vim.api.nvim_set_hl(0, group, attrs)
  end

  set_terminal_colors(c)

  M.active_palette = c
  M.active_variant = variant
end

return M
