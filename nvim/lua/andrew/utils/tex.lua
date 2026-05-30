-- =============================================================================
-- LaTeX Utilities: math-zone detection + shared math snippets
-- =============================================================================
local M = {}

-- Treesitter node types that represent math environments in .tex files
local math_nodes = {
  displayed_equation = true,
  inline_formula = true,
  math_environment = true,
}

--- Count unescaped $ before cursor on the current line.
--- Returns true if the count is odd (cursor is inside inline math).
local function dollar_count_heuristic()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before = line:sub(1, col):gsub("\\%$", "")
  local _, count = before:gsub("%$", "")
  return count % 2 == 1
end

--- Check if cursor is inside a LaTeX math zone.
--- Works in both .tex files (treesitter node walk) and markdown (latex injection).
--- Falls back to regex $-counting when treesitter is in an error state
--- (e.g., during typing before delimiters are complete).
function M.in_mathzone()
  local buf = vim.api.nvim_get_current_buf()
  local ft = vim.bo[buf].filetype

  -- Treesitter: detect language at cursor via the parser tree
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local col = vim.api.nvim_win_get_cursor(0)[2]

  local lok, lang = pcall(function()
    local parser = vim.treesitter.get_parser(buf)
    local lang_tree = parser:language_for_range({ row, col, row, col })
    return lang_tree:lang()
  end)

  if lok and lang then
    -- Markdown: cursor inside an injected latex region → math zone
    if ft == "markdown" and lang == "latex" then
      return true
    end

    -- TeX: walk ancestors looking for math environment nodes
    if ft == "tex" then
      local ok, node = pcall(vim.treesitter.get_node, { bufnr = buf })
      if ok and node then
        local cur = node
        while cur do
          if math_nodes[cur:type()] then
            return true
          end
          cur = cur:parent()
        end
      end
      -- Treesitter didn't find a math node (tree may be in error state
      -- during typing). Fall through to regex heuristic.
      return dollar_count_heuristic()
    end
  end

  -- Regex fallback for markdown or when treesitter is unavailable
  if ft == "markdown" or ft == "tex" then
    return dollar_count_heuristic()
  end

  return false
end

function M.not_mathzone()
  return not M.in_mathzone()
end

-- =============================================================================
-- Shared math-mode snippets (used by both tex.lua and markdown.lua)
-- =============================================================================
function M.math_snippets()
  local ls = require("luasnip")
  local s = ls.snippet
  local t = ls.text_node
  local i = ls.insert_node
  local fmta = require("luasnip.extras.fmt").fmta

  local cond = { condition = M.in_mathzone, show_condition = M.in_mathzone }

  -- math autosnippet: simple text replacement
  local function mr(trig, repl, opts)
    opts = opts or {}
    return s({
      trig = trig,
      snippetType = "autosnippet",
      wordTrig = opts.wordTrig ~= false,
      priority = opts.priority,
    }, { t(repl) }, cond)
  end

  -- math autosnippet: with nodes (insert nodes, etc.)
  local function ma(trig, nodes, opts)
    opts = opts or {}
    return s({
      trig = trig,
      snippetType = "autosnippet",
      wordTrig = opts.wordTrig ~= false,
      priority = opts.priority,
    }, nodes, cond)
  end

  -- regular math snippet: simple text replacement (shows in completions)
  local function sr(trig, repl, opts)
    opts = opts or {}
    return s({
      trig = trig,
      wordTrig = opts.wordTrig ~= false,
      priority = opts.priority,
    }, { t(repl) }, cond)
  end

  -- regular math snippet: with nodes (shows in completions)
  local function sa(trig, nodes, opts)
    opts = opts or {}
    return s({
      trig = trig,
      wordTrig = opts.wordTrig ~= false,
      priority = opts.priority,
    }, nodes, cond)
  end

  -- Greek letter shortcut: ;latex-key → \command (regular snippet)
  local function greek(key, cmd)
    return sr(";latex-" .. key, "\\" .. cmd, { wordTrig = false })
  end

  local snippets = {}
  local autosnippets = {
    -- =======================================================================
    -- Fractions
    -- =======================================================================
    ma("ff", fmta("\\frac{<>}{<>}", { i(1), i(2) })),
    ma("//", fmta("\\frac{<>}{<>}", { i(1), i(2) }), { wordTrig = false }),

    -- =======================================================================
    -- Sub / superscripts
    -- =======================================================================
    ma("td", fmta("^{<>}", { i(1) })),
    ma("sb", fmta("_{<>}", { i(1) })),
    mr("sr", "^2"),
    mr("cb", "^3"),
    mr("inv", "^{-1}"),

    -- =======================================================================
    -- Greek letters  (;a → \alpha, ;G → \Gamma, etc.)
    -- =======================================================================
    greek("a", "alpha"),
    greek("b", "beta"),
    greek("g", "gamma"),
    greek("G", "Gamma"),
    greek("d", "delta"),
    greek("D", "Delta"),
    greek("e", "epsilon"),
    greek("z", "zeta"),
    greek("h", "eta"),
    greek("t", "theta"),
    greek("T", "Theta"),
    greek("i", "iota"),
    greek("k", "kappa"),
    greek("l", "lambda"),
    greek("L", "Lambda"),
    greek("m", "mu"),
    greek("n", "nu"),
    greek("x", "xi"),
    greek("X", "Xi"),
    greek("p", "pi"),
    greek("P", "Pi"),
    greek("r", "rho"),
    greek("s", "sigma"),
    greek("S", "Sigma"),
    greek("u", "tau"),
    greek("f", "phi"),
    greek("F", "Phi"),
    greek("c", "chi"),
    greek("y", "psi"),
    greek("Y", "Psi"),
    greek("o", "omega"),
    greek("O", "Omega"),
    sr(";latex-ve", "\\varepsilon", { wordTrig = false }),
    sr(";latex-vt", "\\vartheta", { wordTrig = false }),
    sr(";latex-vf", "\\varphi", { wordTrig = false }),

    -- =======================================================================
    -- Operators & relations
    -- =======================================================================
    mr("<=", "\\leq", { wordTrig = false }),
    mr(">=", "\\geq", { wordTrig = false }),
    mr("!=", "\\neq", { wordTrig = false }),
    mr("~~", "\\approx", { wordTrig = false }),
    mr("~=", "\\cong", { wordTrig = false }),
    mr(">>", "\\gg", { wordTrig = false }),
    mr("<<", "\\ll", { wordTrig = false }),
    mr("xx", "\\times"),
    mr("**", "\\cdot", { wordTrig = false }),
    mr("->", "\\to", { wordTrig = false }),
    mr("<-", "\\gets", { wordTrig = false }),
    mr("=>", "\\implies", { wordTrig = false }),
    mr("iff", "\\iff"),
    mr("inn", "\\in"),
    mr("notin", "\\notin"),
    mr("sset", "\\subset"),
    mr("ssq", "\\subseteq"),
    mr("uu", "\\cup"),
    mr("nn", "\\cap"),
    mr("EE", "\\exists"),
    mr("AA", "\\forall"),

    -- =======================================================================
    -- Big operators
    -- =======================================================================
    ma("sum", fmta("\\sum_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") })),
    ma("prod", fmta("\\prod_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") })),
    ma("lim", fmta("\\lim_{<> \\to <>} ", { i(1, "n"), i(2, "\\infty") })),
    ma("dint", fmta("\\int_{<>}^{<>} <> \\,d<>", { i(1, "a"), i(2, "b"), i(3), i(4, "x") })),

    -- =======================================================================
    -- Misc symbols
    -- =======================================================================
    mr("ooo", "\\infty"),
    mr("par", "\\partial"),
    mr("nab", "\\nabla"),
    mr("...", "\\ldots", { wordTrig = false }),
    mr("ddd", "\\,d"),

    -- =======================================================================
    -- Decorators  (hat → \hat{}, etc.)
    -- =======================================================================
    ma("hat", fmta("\\hat{<>}", { i(1) })),
    ma("bar", fmta("\\bar{<>}", { i(1) })),
    ma("vec", fmta("\\vec{<>}", { i(1) })),
    ma("dot", fmta("\\dot{<>}", { i(1) })),
    ma("ddot", fmta("\\ddot{<>}", { i(1) }), { priority = 2000 }),
    ma("tld", fmta("\\tilde{<>}", { i(1) })),

    -- =======================================================================
    -- Delimiters  (lr( → \left( ... \right), etc.)
    -- =======================================================================
    ma("lr(", fmta("\\left( <> \\right)", { i(1) }), { wordTrig = false }),
    ma("lr[", fmta("\\left[ <> \\right]", { i(1) }), { wordTrig = false }),
    ma("lr{", fmta("\\left\\{ <> \\right\\}", { i(1) }), { wordTrig = false }),
    ma("lr|", fmta("\\left| <> \\right|", { i(1) }), { wordTrig = false }),
    ma("lra", fmta("\\left\\langle <> \\right\\rangle", { i(1) })),

    -- =======================================================================
    -- Math environments (inline)
    -- =======================================================================
    ma("pmat", fmta("\\begin{pmatrix} <> \\end{pmatrix}", { i(1) })),
    ma("bmat", fmta("\\begin{bmatrix} <> \\end{bmatrix}", { i(1) })),
    ma("case", fmta("\\begin{cases} <> \\end{cases}", { i(1) })),

    -- =======================================================================
    -- Text & font commands
    -- =======================================================================
    ma("textt", fmta("\\text{<>}", { i(1) })),
    mr("mcal", "\\mathcal"),
    mr("mbb", "\\mathbb"),
    mr("mbf", "\\mathbf"),
    mr("mrm", "\\mathrm"),

    -- Common sets
    mr("RR", "\\mathbb{R}"),
    mr("ZZ", "\\mathbb{Z}"),
    mr("NN", "\\mathbb{N}"),
    mr("QQ", "\\mathbb{Q}"),
    mr("CC", "\\mathbb{C}"),

    -- =======================================================================
    -- READABLE NAME ALIASES (;name convention)
    -- All existing short triggers above are preserved.
    -- =======================================================================

    -- -----------------------------------------------------------------------
    -- Fractions
    -- -----------------------------------------------------------------------
    sa(";latex-frac", fmta("\\frac{<>}{<>}", { i(1), i(2) }), { wordTrig = false }),
    sa(";latex-dfrac", fmta("\\dfrac{<>}{<>}", { i(1), i(2) }), { wordTrig = false }),
    sa(";latex-tfrac", fmta("\\tfrac{<>}{<>}", { i(1), i(2) }), { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Sub / superscripts
    -- -----------------------------------------------------------------------
    sa(";latex-super", fmta("^{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-sub", fmta("_{<>}", { i(1) }), { wordTrig = false }),
    sr(";latex-squared", "^2", { wordTrig = false }),
    sr(";latex-cubed", "^3", { wordTrig = false }),
    sr(";latex-inverse", "^{-1}", { wordTrig = false }),
    sr(";latex-complement", "^{c}", { wordTrig = false }),
    sr(";latex-transpose", "^{T}", { wordTrig = false }),
    sr(";latex-dagger", "^{\\dagger}", { wordTrig = false }),
    sa(";latex-power", fmta("^{<>}", { i(1) }), { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Greek letters (readable aliases for all existing + missing letters)
    -- -----------------------------------------------------------------------
    sr(";latex-alpha", "\\alpha", { wordTrig = false }),
    sr(";latex-beta", "\\beta", { wordTrig = false }),
    sr(";latex-gamma", "\\gamma", { wordTrig = false }),
    sr(";latex-Gamma", "\\Gamma", { wordTrig = false }),
    sr(";latex-delta", "\\delta", { wordTrig = false }),
    sr(";latex-Delta", "\\Delta", { wordTrig = false }),
    sr(";latex-epsilon", "\\epsilon", { wordTrig = false }),
    sr(";latex-varepsilon", "\\varepsilon", { wordTrig = false }),
    sr(";latex-zeta", "\\zeta", { wordTrig = false }),
    sr(";latex-eta", "\\eta", { wordTrig = false }),
    sr(";latex-theta", "\\theta", { wordTrig = false }),
    sr(";latex-Theta", "\\Theta", { wordTrig = false }),
    sr(";latex-vartheta", "\\vartheta", { wordTrig = false }),
    sr(";latex-iota", "\\iota", { wordTrig = false }),
    sr(";latex-kappa", "\\kappa", { wordTrig = false }),
    sr(";latex-lambda", "\\lambda", { wordTrig = false }),
    sr(";latex-Lambda", "\\Lambda", { wordTrig = false }),
    sr(";latex-mu", "\\mu", { wordTrig = false }),
    sr(";latex-nu", "\\nu", { wordTrig = false }),
    sr(";latex-xi", "\\xi", { wordTrig = false }),
    sr(";latex-Xi", "\\Xi", { wordTrig = false }),
    sr(";latex-pi", "\\pi", { wordTrig = false }),
    sr(";latex-Pi", "\\Pi", { wordTrig = false }),
    sr(";latex-rho", "\\rho", { wordTrig = false }),
    sr(";latex-varrho", "\\varrho", { wordTrig = false }),
    sr(";latex-sigma", "\\sigma", { wordTrig = false }),
    sr(";latex-Sigma", "\\Sigma", { wordTrig = false }),
    sr(";latex-varsigma", "\\varsigma", { wordTrig = false }),
    sr(";latex-tau", "\\tau", { wordTrig = false }),
    sr(";latex-upsilon", "\\upsilon", { wordTrig = false }),
    sr(";latex-Upsilon", "\\Upsilon", { wordTrig = false }),
    sr(";latex-phi", "\\phi", { wordTrig = false }),
    sr(";latex-Phi", "\\Phi", { wordTrig = false }),
    sr(";latex-varphi", "\\varphi", { wordTrig = false }),
    sr(";latex-chi", "\\chi", { wordTrig = false }),
    sr(";latex-psi", "\\psi", { wordTrig = false }),
    sr(";latex-Psi", "\\Psi", { wordTrig = false }),
    sr(";latex-omega", "\\omega", { wordTrig = false }),
    sr(";latex-Omega", "\\Omega", { wordTrig = false }),
    sr(";latex-varpi", "\\varpi", { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Operators and relations
    -- -----------------------------------------------------------------------
    sr(";latex-leq", "\\leq", { wordTrig = false }),
    sr(";latex-geq", "\\geq", { wordTrig = false }),
    sr(";latex-neq", "\\neq", { wordTrig = false }),
    sr(";latex-approx", "\\approx", { wordTrig = false }),
    sr(";latex-cong", "\\cong", { wordTrig = false }),
    sr(";latex-sim", "\\sim", { wordTrig = false }),
    sr(";latex-simeq", "\\simeq", { wordTrig = false }),
    sr(";latex-equiv", "\\equiv", { wordTrig = false }),
    sr(";latex-propto", "\\propto", { wordTrig = false }),
    sr(";latex-gg", "\\gg", { wordTrig = false }),
    sr(";latex-ll", "\\ll", { wordTrig = false }),
    sr(";latex-times", "\\times", { wordTrig = false }),
    sr(";latex-cdot", "\\cdot", { wordTrig = false }),
    sr(";latex-div", "\\div", { wordTrig = false }),
    sr(";latex-pm", "\\pm", { wordTrig = false }),
    sr(";latex-mp", "\\mp", { wordTrig = false }),
    sr(";latex-ast", "\\ast", { wordTrig = false }),
    sr(";latex-star", "\\star", { wordTrig = false }),
    sr(";latex-circ", "\\circ", { wordTrig = false }),
    sr(";latex-bullet", "\\bullet", { wordTrig = false }),
    sr(";latex-oplus", "\\oplus", { wordTrig = false }),
    sr(";latex-otimes", "\\otimes", { wordTrig = false }),
    sr(";latex-odot", "\\odot", { wordTrig = false }),
    sr(";latex-doteq", "\\doteq", { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Arrows
    -- -----------------------------------------------------------------------
    sr(";latex-to", "\\to", { wordTrig = false }),
    sr(";latex-gets", "\\gets", { wordTrig = false }),
    sr(";latex-implies", "\\implies", { wordTrig = false }),
    sr(";latex-impliedby", "\\impliedby", { wordTrig = false }),
    sr(";latex-iff", "\\iff", { wordTrig = false }),
    sr(";latex-rightarrow", "\\rightarrow", { wordTrig = false }),
    sr(";latex-leftarrow", "\\leftarrow", { wordTrig = false }),
    sr(";latex-Rightarrow", "\\Rightarrow", { wordTrig = false }),
    sr(";latex-Leftarrow", "\\Leftarrow", { wordTrig = false }),
    sr(";latex-leftrightarrow", "\\leftrightarrow", { wordTrig = false }),
    sr(";latex-Leftrightarrow", "\\Leftrightarrow", { wordTrig = false }),
    sr(";latex-uparrow", "\\uparrow", { wordTrig = false }),
    sr(";latex-downarrow", "\\downarrow", { wordTrig = false }),
    sr(";latex-Uparrow", "\\Uparrow", { wordTrig = false }),
    sr(";latex-Downarrow", "\\Downarrow", { wordTrig = false }),
    sr(";latex-updownarrow", "\\updownarrow", { wordTrig = false }),
    sr(";latex-Updownarrow", "\\Updownarrow", { wordTrig = false }),
    sr(";latex-mapsto", "\\mapsto", { wordTrig = false }),
    sr(";latex-longmapsto", "\\longmapsto", { wordTrig = false }),
    sr(";latex-longrightarrow", "\\longrightarrow", { wordTrig = false }),
    sr(";latex-longleftarrow", "\\longleftarrow", { wordTrig = false }),
    sr(";latex-Longrightarrow", "\\Longrightarrow", { wordTrig = false }),
    sr(";latex-Longleftarrow", "\\Longleftarrow", { wordTrig = false }),
    sr(";latex-Longleftrightarrow", "\\Longleftrightarrow", { wordTrig = false }),
    sr(";latex-hookrightarrow", "\\hookrightarrow", { wordTrig = false }),
    sr(";latex-hookleftarrow", "\\hookleftarrow", { wordTrig = false }),
    sr(";latex-nearrow", "\\nearrow", { wordTrig = false }),
    sr(";latex-searrow", "\\searrow", { wordTrig = false }),
    sr(";latex-nwarrow", "\\nwarrow", { wordTrig = false }),
    sr(";latex-swarrow", "\\swarrow", { wordTrig = false }),
    sr(";latex-rightharpoonup", "\\rightharpoonup", { wordTrig = false }),
    sr(";latex-rightharpoondown", "\\rightharpoondown", { wordTrig = false }),
    sr(";latex-leftharpoonup", "\\leftharpoonup", { wordTrig = false }),
    sr(";latex-leftharpoondown", "\\leftharpoondown", { wordTrig = false }),
    sr(";latex-rightleftharpoons", "\\rightleftharpoons", { wordTrig = false }),
    sr(";latex-leftrightharpoons", "\\leftrightharpoons", { wordTrig = false }),
    sr(";latex-xrightarrow", "\\xrightarrow", { wordTrig = false }),
    sr(";latex-xleftarrow", "\\xleftarrow", { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Set theory and logic
    -- -----------------------------------------------------------------------
    sr(";latex-in", "\\in", { wordTrig = false }),
    sr(";latex-notin", "\\notin", { wordTrig = false }),
    sr(";latex-ni", "\\ni", { wordTrig = false }),
    sr(";latex-subset", "\\subset", { wordTrig = false }),
    sr(";latex-supset", "\\supset", { wordTrig = false }),
    sr(";latex-subseteq", "\\subseteq", { wordTrig = false }),
    sr(";latex-supseteq", "\\supseteq", { wordTrig = false }),
    sr(";latex-subsetneq", "\\subsetneq", { wordTrig = false }),
    sr(";latex-supsetneq", "\\supsetneq", { wordTrig = false }),
    sr(";latex-cup", "\\cup", { wordTrig = false }),
    sr(";latex-cap", "\\cap", { wordTrig = false }),
    sr(";latex-bigcup", "\\bigcup", { wordTrig = false }),
    sr(";latex-bigcap", "\\bigcap", { wordTrig = false }),
    sr(";latex-sqcup", "\\sqcup", { wordTrig = false }),
    sr(";latex-sqcap", "\\sqcap", { wordTrig = false }),
    sr(";latex-setminus", "\\setminus", { wordTrig = false }),
    sr(";latex-emptyset", "\\emptyset", { wordTrig = false }),
    sr(";latex-varnothing", "\\varnothing", { wordTrig = false }),
    sr(";latex-exists", "\\exists", { wordTrig = false }),
    sr(";latex-nexists", "\\nexists", { wordTrig = false }),
    sr(";latex-forall", "\\forall", { wordTrig = false }),
    sr(";latex-neg", "\\neg", { wordTrig = false }),
    sr(";latex-land", "\\land", { wordTrig = false }),
    sr(";latex-lor", "\\lor", { wordTrig = false }),
    sr(";latex-vee", "\\vee", { wordTrig = false }),
    sr(";latex-wedge", "\\wedge", { wordTrig = false }),
    sr(";latex-vdash", "\\vdash", { wordTrig = false }),
    sr(";latex-dashv", "\\dashv", { wordTrig = false }),
    sr(";latex-models", "\\models", { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Order relations
    -- -----------------------------------------------------------------------
    sr(";latex-prec", "\\prec", { wordTrig = false }),
    sr(";latex-succ", "\\succ", { wordTrig = false }),
    sr(";latex-preceq", "\\preceq", { wordTrig = false }),
    sr(";latex-succeq", "\\succeq", { wordTrig = false }),
    sr(";latex-parallel", "\\parallel", { wordTrig = false }),
    sr(";latex-perp", "\\perp", { wordTrig = false }),
    sr(";latex-mid", "\\mid", { wordTrig = false }),
    sr(";latex-nmid", "\\nmid", { wordTrig = false }),
    sr(";latex-bowtie", "\\bowtie", { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Big operators (readable)
    -- -----------------------------------------------------------------------
    sa(";latex-sum", fmta("\\sum_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") }), { wordTrig = false }),
    sa(";latex-prod", fmta("\\prod_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") }), { wordTrig = false }),
    sa(";latex-coprod", fmta("\\coprod_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") }), { wordTrig = false }),
    sa(";latex-limit", fmta("\\lim_{<> \\to <>} ", { i(1, "n"), i(2, "\\infty") }), { wordTrig = false }),
    sa(";latex-limsup", fmta("\\limsup_{<>} ", { i(1, "n \\to \\infty") }), { wordTrig = false }),
    sa(";latex-liminf", fmta("\\liminf_{<>} ", { i(1, "n \\to \\infty") }), { wordTrig = false }),
    sa(";latex-int", fmta("\\int_{<>}^{<>} <> \\,d<>", { i(1, "a"), i(2, "b"), i(3), i(4, "x") }), { wordTrig = false }),
    sa(";latex-iint", fmta("\\iint_{<>} <> \\,dA", { i(1, "D"), i(2) }), { wordTrig = false }),
    sa(";latex-iiint", fmta("\\iiint_{<>} <> \\,dV", { i(1, "V"), i(2) }), { wordTrig = false }),
    sa(";latex-oint", fmta("\\oint_{<>} <> \\,d<>", { i(1, "C"), i(2), i(3, "s") }), { wordTrig = false }),
    sa(";latex-bigcup-op", fmta("\\bigcup_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") }), { wordTrig = false }),
    sa(";latex-bigcap-op", fmta("\\bigcap_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") }), { wordTrig = false }),
    sa(";latex-bigoplus", fmta("\\bigoplus_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") }), { wordTrig = false }),
    sa(";latex-bigotimes", fmta("\\bigotimes_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") }), { wordTrig = false }),
    sa(";latex-bigsqcup", fmta("\\bigsqcup_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") }), { wordTrig = false }),
    sa(";latex-bigvee", fmta("\\bigvee_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") }), { wordTrig = false }),
    sa(";latex-bigwedge", fmta("\\bigwedge_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") }), { wordTrig = false }),
    sr(";latex-inf", "\\inf", { wordTrig = false }),
    sr(";latex-sup", "\\sup", { wordTrig = false }),
    sr(";latex-max", "\\max", { wordTrig = false }),
    sr(";latex-min", "\\min", { wordTrig = false }),
    sr(";latex-arg", "\\arg", { wordTrig = false }),
    sr(";latex-argmax", "\\operatorname{argmax}", { wordTrig = false }),
    sr(";latex-argmin", "\\operatorname{argmin}", { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Misc symbols (readable)
    -- -----------------------------------------------------------------------
    sr(";latex-infty", "\\infty", { wordTrig = false }),
    sr(";latex-infinity", "\\infty", { wordTrig = false }),
    sr(";latex-partial", "\\partial", { wordTrig = false }),
    sr(";latex-nabla", "\\nabla", { wordTrig = false }),
    sr(";latex-grad", "\\nabla", { wordTrig = false }),
    sr(";latex-ldots", "\\ldots", { wordTrig = false }),
    sr(";latex-cdots", "\\cdots", { wordTrig = false }),
    sr(";latex-vdots", "\\vdots", { wordTrig = false }),
    sr(";latex-ddots", "\\ddots", { wordTrig = false }),
    sr(";latex-ell", "\\ell", { wordTrig = false }),
    sr(";latex-hbar", "\\hbar", { wordTrig = false }),
    sr(";latex-aleph", "\\aleph", { wordTrig = false }),
    sr(";latex-wp", "\\wp", { wordTrig = false }),
    sr(";latex-Re", "\\Re", { wordTrig = false }),
    sr(";latex-Im", "\\Im", { wordTrig = false }),
    sr(";latex-angle", "\\angle", { wordTrig = false }),
    sr(";latex-measuredangle", "\\measuredangle", { wordTrig = false }),
    sr(";latex-triangle", "\\triangle", { wordTrig = false }),
    sr(";latex-square", "\\square", { wordTrig = false }),
    sr(";latex-diamond", "\\diamond", { wordTrig = false }),
    sr(";latex-prime", "\\prime", { wordTrig = false }),
    sr(";latex-backslash", "\\backslash", { wordTrig = false }),
    sr(";latex-therefore", "\\therefore", { wordTrig = false }),
    sr(";latex-because", "\\because", { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Trig / math functions
    -- -----------------------------------------------------------------------
    sr(";latex-sin", "\\sin", { wordTrig = false }),
    sr(";latex-cos", "\\cos", { wordTrig = false }),
    sr(";latex-tan", "\\tan", { wordTrig = false }),
    sr(";latex-sec", "\\sec", { wordTrig = false }),
    sr(";latex-csc", "\\csc", { wordTrig = false }),
    sr(";latex-cot", "\\cot", { wordTrig = false }),
    sr(";latex-arcsin", "\\arcsin", { wordTrig = false }),
    sr(";latex-arccos", "\\arccos", { wordTrig = false }),
    sr(";latex-arctan", "\\arctan", { wordTrig = false }),
    sr(";latex-sinh", "\\sinh", { wordTrig = false }),
    sr(";latex-cosh", "\\cosh", { wordTrig = false }),
    sr(";latex-tanh", "\\tanh", { wordTrig = false }),
    sr(";latex-log", "\\log", { wordTrig = false }),
    sr(";latex-ln", "\\ln", { wordTrig = false }),
    sr(";latex-exp", "\\exp", { wordTrig = false }),
    sr(";latex-det", "\\det", { wordTrig = false }),
    sr(";latex-dim", "\\dim", { wordTrig = false }),
    sr(";latex-ker", "\\ker", { wordTrig = false }),
    sr(";latex-deg", "\\deg", { wordTrig = false }),
    sr(";latex-gcd", "\\gcd", { wordTrig = false }),
    sr(";latex-lcm", "\\operatorname{lcm}", { wordTrig = false }),
    sr(";latex-hom", "\\hom", { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Decorators (readable)
    -- -----------------------------------------------------------------------
    sa(";latex-hat", fmta("\\hat{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-widehat", fmta("\\widehat{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-bar", fmta("\\bar{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-overline", fmta("\\overline{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-underline", fmta("\\underline{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-vec", fmta("\\vec{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-dot", fmta("\\dot{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-ddot", fmta("\\ddot{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-dddot", fmta("\\dddot{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-tilde", fmta("\\tilde{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-widetilde", fmta("\\widetilde{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-breve", fmta("\\breve{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-check", fmta("\\check{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-acute", fmta("\\acute{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-grave", fmta("\\grave{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-overbrace", fmta("\\overbrace{<>}^{<>}", { i(1), i(2) }), { wordTrig = false }),
    sa(";latex-underbrace", fmta("\\underbrace{<>}_{<>}", { i(1), i(2) }), { wordTrig = false }),
    sa(";latex-overrightarrow", fmta("\\overrightarrow{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-overleftarrow", fmta("\\overleftarrow{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-boxed", fmta("\\boxed{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-cancel", fmta("\\cancel{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-bcancel", fmta("\\bcancel{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-xcancel", fmta("\\xcancel{<>}", { i(1) }), { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Composite decorators: ;letter-modifier
    -- -----------------------------------------------------------------------
    sr(";latex-alpha-hat", "\\hat{\\alpha}", { wordTrig = false }),
    sr(";latex-alpha-bar", "\\bar{\\alpha}", { wordTrig = false }),
    sr(";latex-alpha-dot", "\\dot{\\alpha}", { wordTrig = false }),
    sr(";latex-alpha-vec", "\\vec{\\alpha}", { wordTrig = false }),
    sr(";latex-alpha-tilde", "\\tilde{\\alpha}", { wordTrig = false }),
    sr(";latex-beta-hat", "\\hat{\\beta}", { wordTrig = false }),
    sr(";latex-beta-dot", "\\dot{\\beta}", { wordTrig = false }),
    sr(";latex-beta-bar", "\\bar{\\beta}", { wordTrig = false }),
    sr(";latex-gamma-hat", "\\hat{\\gamma}", { wordTrig = false }),
    sr(";latex-gamma-dot", "\\dot{\\gamma}", { wordTrig = false }),
    sr(";latex-gamma-bar", "\\bar{\\gamma}", { wordTrig = false }),
    sr(";latex-delta-hat", "\\hat{\\delta}", { wordTrig = false }),
    sr(";latex-delta-dot", "\\dot{\\delta}", { wordTrig = false }),
    sr(";latex-delta-bar", "\\bar{\\delta}", { wordTrig = false }),
    sr(";latex-Delta-hat", "\\hat{\\Delta}", { wordTrig = false }),
    sr(";latex-Delta-dot", "\\dot{\\Delta}", { wordTrig = false }),
    sr(";latex-epsilon-hat", "\\hat{\\epsilon}", { wordTrig = false }),
    sr(";latex-epsilon-dot", "\\dot{\\epsilon}", { wordTrig = false }),
    sr(";latex-epsilon-bar", "\\bar{\\epsilon}", { wordTrig = false }),
    sr(";latex-theta-hat", "\\hat{\\theta}", { wordTrig = false }),
    sr(";latex-theta-dot", "\\dot{\\theta}", { wordTrig = false }),
    sr(";latex-theta-bar", "\\bar{\\theta}", { wordTrig = false }),
    sr(";latex-lambda-hat", "\\hat{\\lambda}", { wordTrig = false }),
    sr(";latex-lambda-bar", "\\bar{\\lambda}", { wordTrig = false }),
    sr(";latex-mu-hat", "\\hat{\\mu}", { wordTrig = false }),
    sr(";latex-mu-bar", "\\bar{\\mu}", { wordTrig = false }),
    sr(";latex-nu-hat", "\\hat{\\nu}", { wordTrig = false }),
    sr(";latex-sigma-hat", "\\hat{\\sigma}", { wordTrig = false }),
    sr(";latex-sigma-bar", "\\bar{\\sigma}", { wordTrig = false }),
    sr(";latex-sigma-tilde", "\\tilde{\\sigma}", { wordTrig = false }),
    sr(";latex-Sigma-hat", "\\hat{\\Sigma}", { wordTrig = false }),
    sr(";latex-tau-hat", "\\hat{\\tau}", { wordTrig = false }),
    sr(";latex-tau-bar", "\\bar{\\tau}", { wordTrig = false }),
    sr(";latex-phi-hat", "\\hat{\\phi}", { wordTrig = false }),
    sr(";latex-phi-bar", "\\bar{\\phi}", { wordTrig = false }),
    sr(";latex-psi-hat", "\\hat{\\psi}", { wordTrig = false }),
    sr(";latex-psi-dot", "\\dot{\\psi}", { wordTrig = false }),
    sr(";latex-omega-hat", "\\hat{\\omega}", { wordTrig = false }),
    sr(";latex-omega-bar", "\\bar{\\omega}", { wordTrig = false }),
    sr(";latex-omega-dot", "\\dot{\\omega}", { wordTrig = false }),
    sr(";latex-Omega-hat", "\\hat{\\Omega}", { wordTrig = false }),
    sr(";latex-rho-hat", "\\hat{\\rho}", { wordTrig = false }),
    sr(";latex-rho-bar", "\\bar{\\rho}", { wordTrig = false }),
    sr(";latex-rho-dot", "\\dot{\\rho}", { wordTrig = false }),
    sr(";latex-xi-hat", "\\hat{\\xi}", { wordTrig = false }),
    sr(";latex-pi-hat", "\\hat{\\pi}", { wordTrig = false }),
    sr(";latex-kappa-hat", "\\hat{\\kappa}", { wordTrig = false }),
    sr(";latex-kappa-bar", "\\bar{\\kappa}", { wordTrig = false }),
    sr(";latex-eta-hat", "\\hat{\\eta}", { wordTrig = false }),
    sr(";latex-eta-bar", "\\bar{\\eta}", { wordTrig = false }),
    sr(";latex-zeta-hat", "\\hat{\\zeta}", { wordTrig = false }),
    sr(";latex-chi-hat", "\\hat{\\chi}", { wordTrig = false }),
    sr(";latex-iota-hat", "\\hat{\\iota}", { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Delimiters (readable)
    -- -----------------------------------------------------------------------
    sa(";latex-paren", fmta("\\left( <> \\right)", { i(1) }), { wordTrig = false }),
    sa(";latex-bracket", fmta("\\left[ <> \\right]", { i(1) }), { wordTrig = false }),
    sa(";latex-brace", fmta("\\left\\{ <> \\right\\}", { i(1) }), { wordTrig = false }),
    sa(";latex-abs", fmta("\\left| <> \\right|", { i(1) }), { wordTrig = false }),
    sa(";latex-norm", fmta("\\left\\| <> \\right\\|", { i(1) }), { wordTrig = false }),
    sa(";latex-angle-bracket", fmta("\\left\\langle <> \\right\\rangle", { i(1) }), { wordTrig = false }),
    sa(";latex-floor", fmta("\\left\\lfloor <> \\right\\rfloor", { i(1) }), { wordTrig = false }),
    sa(";latex-ceil", fmta("\\left\\lceil <> \\right\\rceil", { i(1) }), { wordTrig = false }),
    sa(";latex-inner", fmta("\\langle <>, <> \\rangle", { i(1), i(2) }), { wordTrig = false }),
    sa(";latex-set", fmta("\\{ <> \\mid <> \\}", { i(1), i(2) }), { wordTrig = false }),
    sa(";latex-eval", fmta("\\left. <> \\right|_{<>}", { i(1), i(2) }), { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Math environments (readable)
    -- -----------------------------------------------------------------------
    sa(";latex-pmatrix", fmta("\\begin{pmatrix} <> \\end{pmatrix}", { i(1) }), { wordTrig = false }),
    sa(";latex-bmatrix", fmta("\\begin{bmatrix} <> \\end{bmatrix}", { i(1) }), { wordTrig = false }),
    sa(";latex-vmatrix", fmta("\\begin{vmatrix} <> \\end{vmatrix}", { i(1) }), { wordTrig = false }),
    sa(";latex-Vmatrix", fmta("\\begin{Vmatrix} <> \\end{Vmatrix}", { i(1) }), { wordTrig = false }),
    sa(";latex-matrix", fmta("\\begin{matrix} <> \\end{matrix}", { i(1) }), { wordTrig = false }),
    sa(";latex-cases", fmta("\\begin{cases} <> \\end{cases}", { i(1) }), { wordTrig = false }),
    sa(";latex-aligned", fmta("\\begin{aligned} <> \\end{aligned}", { i(1) }), { wordTrig = false }),
    sa(";latex-gathered", fmta("\\begin{gathered} <> \\end{gathered}", { i(1) }), { wordTrig = false }),
    sa(";latex-array", fmta("\\begin{array}{<>} <> \\end{array}", { i(1, "cc"), i(2) }), { wordTrig = false }),
    sa(";latex-smallmatrix", fmta("\\left(\\begin{smallmatrix} <> \\end{smallmatrix}\\right)", { i(1) }), { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Font commands (readable)
    -- -----------------------------------------------------------------------
    sa(";latex-text", fmta("\\text{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-mathrm", fmta("\\mathrm{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-mathbf", fmta("\\mathbf{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-mathcal", fmta("\\mathcal{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-mathbb", fmta("\\mathbb{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-mathfrak", fmta("\\mathfrak{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-mathscr", fmta("\\mathscr{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-mathsf", fmta("\\mathsf{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-mathtt", fmta("\\mathtt{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-bold", fmta("\\boldsymbol{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-operatorname", fmta("\\operatorname{<>}", { i(1) }), { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Common sets (readable)
    -- -----------------------------------------------------------------------
    sr(";latex-reals", "\\mathbb{R}", { wordTrig = false }),
    sr(";latex-integers", "\\mathbb{Z}", { wordTrig = false }),
    sr(";latex-naturals", "\\mathbb{N}", { wordTrig = false }),
    sr(";latex-rationals", "\\mathbb{Q}", { wordTrig = false }),
    sr(";latex-complex", "\\mathbb{C}", { wordTrig = false }),
    sr(";latex-field", "\\mathbb{F}", { wordTrig = false }),
    sr(";latex-primes", "\\mathbb{P}", { wordTrig = false }),
    sr(";latex-hilbert", "\\mathcal{H}", { wordTrig = false }),
    sr(";latex-lagrangian", "\\mathcal{L}", { wordTrig = false }),
    sr(";latex-hamiltonian", "\\mathcal{H}", { wordTrig = false }),
    sr(";latex-fourier", "\\mathcal{F}", { wordTrig = false }),
    sr(";latex-laplace-transform", "\\mathcal{L}", { wordTrig = false }),
    sr(";latex-powerset", "\\mathcal{P}", { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Roots and miscellaneous (NEW)
    -- -----------------------------------------------------------------------
    sa(";latex-sqrt", fmta("\\sqrt{<>}", { i(1) }), { wordTrig = false }),
    sa(";latex-nroot", fmta("\\sqrt[<>]{<>}", { i(1, "n"), i(2) }), { wordTrig = false }),
    sa(";latex-binom", fmta("\\binom{<>}{<>}", { i(1, "n"), i(2, "k") }), { wordTrig = false }),
    sa(";latex-stackrel", fmta("\\stackrel{<>}{<>}", { i(1), i(2) }), { wordTrig = false }),
    sa(";latex-overset", fmta("\\overset{<>}{<>}", { i(1), i(2) }), { wordTrig = false }),
    sa(";latex-underset", fmta("\\underset{<>}{<>}", { i(1), i(2) }), { wordTrig = false }),
    sr(";latex-phantom", "\\phantom", { wordTrig = false }),
    sr(";latex-quad", "\\quad", { wordTrig = false }),
    sr(";latex-qquad", "\\qquad", { wordTrig = false }),
  }

  -- Move latex-* entries from autosnippets to snippets for completion visibility
  do
    local kept = {}
    for _, snip in ipairs(autosnippets) do
      if snip.trigger and snip.trigger:match("^;latex%-") then
        table.insert(snippets, snip)
      else
        table.insert(kept, snip)
      end
    end
    autosnippets = kept
  end

  return snippets, autosnippets
end

return M
