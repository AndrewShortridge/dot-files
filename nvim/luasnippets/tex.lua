local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node
local i = ls.insert_node
local fmta = require("luasnip.extras.fmt").fmta
local rep = require("luasnip.extras").rep
local tex = require("andrew.utils.tex")

-- Import shared math snippets
local math_snips, math_auto = tex.math_snippets()

-- TeX-specific regular snippets
local snippets = {
  s({ trig = "beg", desc = "\\begin{} / \\end{}" }, fmta(
    [[
    \begin{<>}
    	<>
    \end{<>}
    ]],
    { i(1), i(0), rep(1) }
  )),
  s({ trig = "sec", desc = "Section" }, fmta("\\section{<>}", { i(1) })),
  s({ trig = "ssec", desc = "Subsection" }, fmta("\\subsection{<>}", { i(1) })),
  s({ trig = "sssec", desc = "Subsubsection" }, fmta("\\subsubsection{<>}", { i(1) })),
  s({ trig = "eq", desc = "Equation" }, fmta(
    [[
    \begin{equation}
    	<>
    \end{equation}
    ]],
    { i(1) }
  )),
  s({ trig = "ali", desc = "Align*" }, fmta(
    [[
    \begin{align*}
    	<>
    \end{align*}
    ]],
    { i(1) }
  )),
  s({ trig = "enum", desc = "Enumerate" }, fmta(
    [[
    \begin{enumerate}
    	\item <>
    \end{enumerate}
    ]],
    { i(1) }
  )),
  s({ trig = "item", desc = "Itemize" }, fmta(
    [[
    \begin{itemize}
    	\item <>
    \end{itemize}
    ]],
    { i(1) }
  )),
  s({ trig = "fig", desc = "Figure" }, fmta(
    [[
    \begin{figure}[<>]
    	\centering
    	\includegraphics[width=<>\textwidth]{<>}
    	\caption{<>}
    	\label{fig:<>}
    \end{figure}
    ]],
    { i(1, "htbp"), i(2, "0.8"), i(3), i(4), i(5) }
  )),
}

-- TeX-specific autosnippets (math-mode entry)
local autosnippets = {
  s({ trig = "mk", snippetType = "autosnippet", desc = "Inline math $...$" },
    { t("$"), i(1), t("$") },
    { condition = tex.not_mathzone }
  ),
  s({ trig = "dm", snippetType = "autosnippet", desc = "Display math \\[...\\]" },
    { t({ "\\[", "\t" }), i(1), t({ "", "\\]" }) },
    { condition = tex.not_mathzone }
  ),
}

-- Merge shared math snippets
vim.list_extend(snippets, math_snips)
vim.list_extend(autosnippets, math_auto)

return snippets, autosnippets
