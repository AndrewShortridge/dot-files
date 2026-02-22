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

  -- Greek letter shortcut: ;key → \command
  local function greek(key, cmd)
    return mr(";" .. key, "\\" .. cmd, { wordTrig = false })
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
    mr(";ve", "\\varepsilon", { wordTrig = false }),
    mr(";vt", "\\vartheta", { wordTrig = false }),
    mr(";vf", "\\varphi", { wordTrig = false }),

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
  }

  return snippets, autosnippets
end

return M
