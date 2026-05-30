# 11 - Missing Snippets Implementation

## Status: Planned

## Overview

This document provides copy-paste-ready LuaSnip code for all missing snippet categories
identified in the Neovim config. Each section is self-contained with complete code blocks.

### Files Referenced

- `/home/andrew-cmmg/.config/nvim/luasnippets/markdown.lua` -- current LuaSnip markdown snippets
- `/home/andrew-cmmg/.config/nvim/snippets/markdown.json` -- current VSCode-format markdown snippets
- `/home/andrew-cmmg/.config/nvim/lua/andrew/utils/tex.lua` -- shared math snippet definitions
- `/home/andrew-cmmg/.config/nvim/luasnippets/tex.lua` -- LaTeX-specific snippets
- `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/templates/` -- all 24 vault templates
- `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/config.lua` -- vault config with note types

---

## A. Meeting Notes Template Snippet

**File to edit:** `/home/andrew-cmmg/.config/nvim/luasnippets/markdown.lua`

Add this inside the `local snippets = { ... }` table, after the table snippet block (line ~297).

The existing meeting template (`/home/andrew-cmmg/.config/nvim/lua/andrew/vault/templates/meeting.lua`)
has these sections: Agenda, Discussion Notes, Feedback / Guidance, Action Items, Decisions Made,
Follow-Up, Notes. This snippet provides a quick inline version without the full template wizard.

```lua
  ---------------------------------------------------------------------------
  -- Meeting Notes template snippet
  ---------------------------------------------------------------------------

  s({ trig = ";meeting-full", desc = "Meeting notes template (full)" }, {
    t({ "---", "type: meeting", "date: " }), i(1, "YYYY-MM-DD"),
    t({ "", "attendees:", "  - '" }), i(2, "[[Name]]"), t("'"),
    t({ "", "parent-project: " }), i(3),
    t({ "", "tags:", "  - meeting", "---", "", "# Meeting -- " }), i(4, "Title"),
    t({ "", "", "**Attendees:** " }), i(5, "[[Name]]"),
    t({ "", "**Project:** " }), i(6, "[[Project]]"),
    t({ "", "", "---", "", "## Agenda", "", "1. " }), i(7, "Item"),
    t({ "", "", "## Discussion Notes", "", "" }), i(8),
    t({ "", "", "## Feedback / Guidance", "", "> [!important] Specific feedback on drafts, methods, direction", "", "- " }), i(9),
    t({ "", "", "## Action Items", "", "- [ ] " }), i(10),
    t({ "", "- [ ] " }), i(11),
    t({ "", "", "## Decisions Made", "", "| Decision | Rationale |", "| -------- | --------- |", "| " }), i(12), t(" | "), i(13), t({ " |", "" }),
    t({ "", "## Follow-Up", "", "- **Next meeting:** " }), i(14),
    t({ "", "- **Items to prepare:** " }), i(15),
    t({ "", "", "## Notes", "" }),
  }),

  s({ trig = ";meeting-quick", desc = "Quick meeting notes (attendees + actions)" }, {
    t("## Meeting -- "), i(1, "Title"),
    t({ "", "", "**Date:** " }), i(2, "YYYY-MM-DD"),
    t({ "", "**Attendees:** " }), i(3, "[[Name]]"),
    t({ "", "", "### Agenda", "", "1. " }), i(4),
    t({ "", "", "### Action Items", "", "- [ ] " }), i(5),
    t({ "", "- [ ] " }), i(6),
    t({ "", "", "### Decisions", "", "- " }), i(7),
    t({ "", "", "### Notes", "", "" }), i(8),
    t({ "", "" }),
  }),
```

---

## B. Research Article Template Snippet

**File to edit:** `/home/andrew-cmmg/.config/nvim/luasnippets/markdown.lua`

Add immediately after the meeting snippets above. Based on the existing literature template
(`/home/andrew-cmmg/.config/nvim/lua/andrew/vault/templates/literature.lua`) which has:
Core Claim, Key Results, Methodology, Relevance to My Work, Figures Worth Referencing,
Methods Worth Noting, Questions This Raises, Quotes, Related Papers.

```lua
  ---------------------------------------------------------------------------
  -- Research Article template snippet
  ---------------------------------------------------------------------------

  s({ trig = ";research-article", desc = "Research article reading note" }, {
    t({ "---", "type: literature", 'title: "' }), i(1, "Paper Title"), t('"'),
    t({ "", 'authors: "' }), i(2, "Author(s)"), t('"'),
    t({ "", "year: " }), i(3, "2025"),
    t({ "", 'journal: "' }), i(4, "Journal Name"), t('"'),
    t({ "", "doi: " }), i(5),
    t({ "", "date_read: " }), i(6, "YYYY-MM-DD"),
    t({ "", "rating: /5" }),
    t({ "", "tags:", "  - lit", "---", "" }),
    t({ "", "# " }), i(7, "Authors"), t(" ("), i(8, "Year"), t(") -- "), i(9, "Title"),
    t({ "", "", "> [!cite] Citation", "> " }), i(10, "Full citation here"),
    t({ "", "", "---", "" }),
    t({ "", "## Core Claim / Thesis", "", "> [!summary]", "> " }), i(11),
    t({ "", "", "## Key Results", "", "1. " }), i(12),
    t({ "", "", "## Methodology", "", "- **Simulation / Experimental approach:** " }), i(13),
    t({ "", "- **Potential / Material:** " }), i(14),
    t({ "", "- **Key parameters:** " }), i(15),
    t({ "", "- **Boundary conditions:** " }), i(16),
    t({ "", "", "## Relevance to My Work", "", "> [!important] Why does this paper matter for my research?", "> " }), i(17),
    t({ "", "", "### Points of Agreement", "", "- " }), i(18),
    t({ "", "", "### Points of Difference", "", "- " }), i(19),
    t({ "", "", "### Gaps / Opportunities", "", "> [!tip] What didn't they do that I can?", "> " }), i(20),
    t({ "", "", "## Keywords / Methods", "", "- " }), i(21),
    t({ "", "", "## Questions This Raises", "", "- [ ] " }), i(22),
    t({ "", "", "## Related Papers", "", "- [[" }), i(23), t("]]"),
    t({ "", "", "## Notes", "" }),
  }),

  s({ trig = ";research-quick", desc = "Quick research article note" }, {
    t("## "), i(1, "Authors"), t(" ("), i(2, "Year"), t(") -- "), i(3, "Title"),
    t({ "", "", "**Journal:** " }), i(4),
    t({ "", "**DOI:** " }), i(5),
    t({ "", "", "### Key Findings", "", "1. " }), i(6),
    t({ "", "", "### Relevance", "", "- " }), i(7),
    t({ "", "", "### Methods of Interest", "", "- " }), i(8),
    t({ "", "", "### Notes", "", "" }), i(9),
    t({ "", "" }),
  }),
```

---

## C. Nested Callouts and Callouts with Metadata

**File to edit:** `/home/andrew-cmmg/.config/nvim/luasnippets/markdown.lua`

Add after the existing callout snippet block (~line 160). The current config defines
`callout_snippet`, `callout_collapsed_snippet`, and `callout_expanded_snippet` helpers
but has no nested or metadata-bearing variants.

### C.1 Nested Callout Snippets

```lua
  ---------------------------------------------------------------------------
  -- Nested callout snippets
  ---------------------------------------------------------------------------

  s({ trig = "callout-nested", desc = "Nested callout (callout inside callout)" }, {
    t("> [!"), callout_type_choices(), t("] "), i(2, "Outer Title"),
    t({ "", "> " }), i(3, "Outer content"),
    t({ "", ">", "> > [!" }), callout_type_choices(), t("] "), i(4, "Inner Title"),
    t({ "", "> > " }), i(5, "Inner content"),
    t({ "", "", "" }),
  }),

  s({ trig = "note-nested", desc = "Nested NOTE callout" }, {
    t("> [!NOTE] "), i(1, "Outer Title"),
    t({ "", "> " }), i(2, "Outer content"),
    t({ "", ">", "> > [!TIP] " }), i(3, "Inner Title"),
    t({ "", "> > " }), i(4, "Inner content"),
    t({ "", "", "" }),
  }),

  s({ trig = "warning-nested", desc = "Nested WARNING callout" }, {
    t("> [!WARNING] "), i(1, "Outer Title"),
    t({ "", "> " }), i(2, "Outer content"),
    t({ "", ">", "> > [!IMPORTANT] " }), i(3, "Inner Title"),
    t({ "", "> > " }), i(4, "Inner content"),
    t({ "", "", "" }),
  }),

  s({ trig = "example-nested", desc = "Nested EXAMPLE with INFO" }, {
    t("> [!EXAMPLE] "), i(1, "Outer Title"),
    t({ "", "> " }), i(2, "Outer content"),
    t({ "", ">", "> > [!INFO] " }), i(3, "Inner Title"),
    t({ "", "> > " }), i(4, "Inner content"),
    t({ "", "", "" }),
  }),

  s({ trig = "callout-triple", desc = "Triple-nested callout" }, {
    t("> [!"), callout_type_choices(), t("] "), i(2, "Level 1 Title"),
    t({ "", "> " }), i(3, "Level 1 content"),
    t({ "", ">", "> > [!" }), callout_type_choices(), t("] "), i(4, "Level 2 Title"),
    t({ "", "> > " }), i(5, "Level 2 content"),
    t({ "", "> >", "> > > [!" }), callout_type_choices(), t("] "), i(6, "Level 3 Title"),
    t({ "", "> > > " }), i(7, "Level 3 content"),
    t({ "", "", "" }),
  }),
```

### C.2 Callouts with Metadata Fields

```lua
  ---------------------------------------------------------------------------
  -- Callouts with metadata
  ---------------------------------------------------------------------------

  s({ trig = "callout-meta", desc = "Callout with metadata (date, author, status)" }, {
    t("> [!"), callout_type_choices(), t("] "), i(2, "Title"),
    t({ "", "> **Date:** " }), i(3, "YYYY-MM-DD"),
    t({ "", "> **Author:** " }), i(4, "Name"),
    t({ "", "> **Status:** " }), c(5, {
      t("Draft"),
      t("In Review"),
      t("Final"),
      t("Superseded"),
    }),
    t({ "", ">", "> " }), i(6, "Content"),
    t({ "", "" }),
  }),

  s({ trig = "finding-meta", desc = "FINDING callout with metadata" }, {
    t("> [!FINDING] "), i(1, "Finding Title"),
    t({ "", "> **Date:** " }), i(2, "YYYY-MM-DD"),
    t({ "", "> **Source:** " }), i(3, "[[Simulation or Analysis]]"),
    t({ "", "> **Status:** " }), c(4, {
      t("In Progress"),
      t("Resolved"),
      t("Needs Investigation"),
    }),
    t({ "", ">", "> " }), i(5, "Description of finding"),
    t({ "", "" }),
  }),

  s({ trig = "simulation-meta", desc = "SIMULATION callout with metadata" }, {
    t("> [!SIMULATION] "), i(1, "Run Title"),
    t({ "", "> **Run ID:** " }), i(2, "run_id"),
    t({ "", "> **Software:** " }), c(3, { t("LAMMPS"), t("GEMMS") }),
    t({ "", "> **Status:** " }), c(4, {
      t("Queued"),
      t("Running"),
      t("Complete"),
      t("Failed"),
    }),
    t({ "", ">", "> " }), i(5, "Purpose / Key result"),
    t({ "", "" }),
  }),

  s({ trig = "literature-meta", desc = "LITERATURE callout with metadata" }, {
    t("> [!LITERATURE] "), i(1, "Paper Title"),
    t({ "", "> **Authors:** " }), i(2, "Author(s)"),
    t({ "", "> **Year:** " }), i(3, "2025"),
    t({ "", "> **Journal:** " }), i(4, "Journal"),
    t({ "", "> **DOI:** " }), i(5, "10.xxxx/xxxxx"),
    t({ "", ">", "> " }), i(6, "Key takeaway"),
    t({ "", "" }),
  }),

  s({ trig = "analysis-meta", desc = "ANALYSIS callout with metadata" }, {
    t("> [!ANALYSIS] "), i(1, "Analysis Title"),
    t({ "", "> **Date:** " }), i(2, "YYYY-MM-DD"),
    t({ "", "> **Status:** " }), c(3, {
      t("In Progress"),
      t("Complete"),
      t("Needs Revision"),
    }),
    t({ "", "> **Project:** " }), i(4, "[[Project]]"),
    t({ "", ">", "> " }), i(5, "Summary"),
    t({ "", "" }),
  }),

  s({ trig = "meeting-meta", desc = "MEETING callout with metadata" }, {
    t("> [!MEETING] "), i(1, "Meeting Title"),
    t({ "", "> **Date:** " }), i(2, "YYYY-MM-DD"),
    t({ "", "> **Attendees:** " }), i(3, "[[Person]]"),
    t({ "", "> **Project:** " }), i(4, "[[Project]]"),
    t({ "", ">", "> " }), i(5, "Key outcome or decision"),
    t({ "", "" }),
  }),
```

---

## D. LaTeX Snippet Convention Update (CRITICAL)

**File to edit:** `/home/andrew-cmmg/.config/nvim/lua/andrew/utils/tex.lua`

### D.1 Current Snippet Inventory

Every autosnippet currently defined in `M.math_snippets()`:

| # | Trigger | Output | Category |
|---|---------|--------|----------|
| 1 | `ff` | `\frac{}{}` | Fractions |
| 2 | `//` | `\frac{}{}` | Fractions |
| 3 | `td` | `^{}` | Sub/super |
| 4 | `sb` | `_{}` | Sub/super |
| 5 | `sr` | `^2` | Sub/super |
| 6 | `cb` | `^3` | Sub/super |
| 7 | `inv` | `^{-1}` | Sub/super |
| 8 | `;a` | `\alpha` | Greek |
| 9 | `;b` | `\beta` | Greek |
| 10 | `;g` | `\gamma` | Greek |
| 11 | `;G` | `\Gamma` | Greek |
| 12 | `;d` | `\delta` | Greek |
| 13 | `;D` | `\Delta` | Greek |
| 14 | `;e` | `\epsilon` | Greek |
| 15 | `;z` | `\zeta` | Greek |
| 16 | `;h` | `\eta` | Greek |
| 17 | `;t` | `\theta` | Greek |
| 18 | `;T` | `\Theta` | Greek |
| 19 | `;i` | `\iota` | Greek |
| 20 | `;k` | `\kappa` | Greek |
| 21 | `;l` | `\lambda` | Greek |
| 22 | `;L` | `\Lambda` | Greek |
| 23 | `;m` | `\mu` | Greek |
| 24 | `;n` | `\nu` | Greek |
| 25 | `;x` | `\xi` | Greek |
| 26 | `;X` | `\Xi` | Greek |
| 27 | `;p` | `\pi` | Greek |
| 28 | `;P` | `\Pi` | Greek |
| 29 | `;r` | `\rho` | Greek |
| 30 | `;s` | `\sigma` | Greek |
| 31 | `;S` | `\Sigma` | Greek |
| 32 | `;u` | `\tau` | Greek |
| 33 | `;f` | `\phi` | Greek |
| 34 | `;F` | `\Phi` | Greek |
| 35 | `;c` | `\chi` | Greek |
| 36 | `;y` | `\psi` | Greek |
| 37 | `;Y` | `\Psi` | Greek |
| 38 | `;o` | `\omega` | Greek |
| 39 | `;O` | `\Omega` | Greek |
| 40 | `;ve` | `\varepsilon` | Greek variant |
| 41 | `;vt` | `\vartheta` | Greek variant |
| 42 | `;vf` | `\varphi` | Greek variant |
| 43 | `<=` | `\leq` | Relations |
| 44 | `>=` | `\geq` | Relations |
| 45 | `!=` | `\neq` | Relations |
| 46 | `~~` | `\approx` | Relations |
| 47 | `~=` | `\cong` | Relations |
| 48 | `>>` | `\gg` | Relations |
| 49 | `<<` | `\ll` | Relations |
| 50 | `xx` | `\times` | Operators |
| 51 | `**` | `\cdot` | Operators |
| 52 | `->` | `\to` | Arrows |
| 53 | `<-` | `\gets` | Arrows |
| 54 | `=>` | `\implies` | Arrows |
| 55 | `iff` | `\iff` | Logic |
| 56 | `inn` | `\in` | Sets |
| 57 | `notin` | `\notin` | Sets |
| 58 | `sset` | `\subset` | Sets |
| 59 | `ssq` | `\subseteq` | Sets |
| 60 | `uu` | `\cup` | Sets |
| 61 | `nn` | `\cap` | Sets |
| 62 | `EE` | `\exists` | Logic |
| 63 | `AA` | `\forall` | Logic |
| 64 | `sum` | `\sum_{}^{}` | Big ops |
| 65 | `prod` | `\prod_{}^{}` | Big ops |
| 66 | `lim` | `\lim_{n\to\infty}` | Big ops |
| 67 | `dint` | `\int_{}^{} \,dx` | Big ops |
| 68 | `ooo` | `\infty` | Symbols |
| 69 | `par` | `\partial` | Symbols |
| 70 | `nab` | `\nabla` | Symbols |
| 71 | `...` | `\ldots` | Symbols |
| 72 | `ddd` | `\,d` | Symbols |
| 73 | `hat` | `\hat{}` | Decorators |
| 74 | `bar` | `\bar{}` | Decorators |
| 75 | `vec` | `\vec{}` | Decorators |
| 76 | `dot` | `\dot{}` | Decorators |
| 77 | `ddot` | `\ddot{}` | Decorators |
| 78 | `tld` | `\tilde{}` | Decorators |
| 79 | `lr(` | `\left(\right)` | Delimiters |
| 80 | `lr[` | `\left[\right]` | Delimiters |
| 81 | `lr{` | `\left\{\right\}` | Delimiters |
| 82 | `lr\|` | `\left\|\right\|` | Delimiters |
| 83 | `lra` | `\langle\rangle` | Delimiters |
| 84 | `pmat` | `\begin{pmatrix}` | Environments |
| 85 | `bmat` | `\begin{bmatrix}` | Environments |
| 86 | `case` | `\begin{cases}` | Environments |
| 87 | `textt` | `\text{}` | Fonts |
| 88 | `mcal` | `\mathcal` | Fonts |
| 89 | `mbb` | `\mathbb` | Fonts |
| 90 | `mbf` | `\mathbf` | Fonts |
| 91 | `mrm` | `\mathrm` | Fonts |
| 92 | `RR` | `\mathbb{R}` | Sets |
| 93 | `ZZ` | `\mathbb{Z}` | Sets |
| 94 | `NN` | `\mathbb{N}` | Sets |
| 95 | `QQ` | `\mathbb{Q}` | Sets |
| 96 | `CC` | `\mathbb{C}` | Sets |

**Total existing: 96 autosnippets**

### D.2 Naming Convention

Pattern: `;readable-name` or `;name-modifier`

- Semicolon `;` prefix for all readable snippets (already used by Greek letters)
- Lowercase readable English name matching the LaTeX command
- Hyphen separates modifiers: `;delta-dot` inserts `\dot{\Delta}`
- Existing short triggers (`;a`, `ff`, `<=`, etc.) are KEPT as fast aliases
- New readable names are ADDED alongside, not replacing

### D.3 Complete Readable-Name Snippet Code

Add this code block at the END of the `autosnippets` table in
`/home/andrew-cmmg/.config/nvim/lua/andrew/utils/tex.lua`, right before the closing `}` of the
table (before the `return snippets, autosnippets` on line 257).

```lua
    -- =======================================================================
    -- READABLE NAME ALIASES (;name convention)
    -- All existing short triggers above are preserved.
    -- =======================================================================

    -- -----------------------------------------------------------------------
    -- Fractions
    -- -----------------------------------------------------------------------
    ma(";frac", fmta("\\frac{<>}{<>}", { i(1), i(2) }), { wordTrig = false }),
    ma(";dfrac", fmta("\\dfrac{<>}{<>}", { i(1), i(2) }), { wordTrig = false }),
    ma(";tfrac", fmta("\\tfrac{<>}{<>}", { i(1), i(2) }), { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Sub / superscripts
    -- -----------------------------------------------------------------------
    ma(";super", fmta("^{<>}", { i(1) }), { wordTrig = false }),
    ma(";sub", fmta("_{<>}", { i(1) }), { wordTrig = false }),
    mr(";squared", "^2", { wordTrig = false }),
    mr(";cubed", "^3", { wordTrig = false }),
    mr(";inverse", "^{-1}", { wordTrig = false }),
    mr(";complement", "^{c}", { wordTrig = false }),
    mr(";transpose", "^{T}", { wordTrig = false }),
    mr(";dagger", "^{\\dagger}", { wordTrig = false }),
    ma(";power", fmta("^{<>}", { i(1) }), { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Greek letters (readable aliases for all existing + missing letters)
    -- -----------------------------------------------------------------------
    mr(";alpha", "\\alpha", { wordTrig = false }),
    mr(";beta", "\\beta", { wordTrig = false }),
    mr(";gamma", "\\gamma", { wordTrig = false }),
    mr(";Gamma", "\\Gamma", { wordTrig = false }),
    mr(";delta", "\\delta", { wordTrig = false }),
    mr(";Delta", "\\Delta", { wordTrig = false }),
    mr(";epsilon", "\\epsilon", { wordTrig = false }),
    mr(";varepsilon", "\\varepsilon", { wordTrig = false }),
    mr(";zeta", "\\zeta", { wordTrig = false }),
    mr(";eta", "\\eta", { wordTrig = false }),
    mr(";theta", "\\theta", { wordTrig = false }),
    mr(";Theta", "\\Theta", { wordTrig = false }),
    mr(";vartheta", "\\vartheta", { wordTrig = false }),
    mr(";iota", "\\iota", { wordTrig = false }),
    mr(";kappa", "\\kappa", { wordTrig = false }),
    mr(";lambda", "\\lambda", { wordTrig = false }),
    mr(";Lambda", "\\Lambda", { wordTrig = false }),
    mr(";mu", "\\mu", { wordTrig = false }),
    mr(";nu", "\\nu", { wordTrig = false }),
    mr(";xi", "\\xi", { wordTrig = false }),
    mr(";Xi", "\\Xi", { wordTrig = false }),
    mr(";pi", "\\pi", { wordTrig = false }),
    mr(";Pi", "\\Pi", { wordTrig = false }),
    mr(";rho", "\\rho", { wordTrig = false }),
    mr(";varrho", "\\varrho", { wordTrig = false }),
    mr(";sigma", "\\sigma", { wordTrig = false }),
    mr(";Sigma", "\\Sigma", { wordTrig = false }),
    mr(";varsigma", "\\varsigma", { wordTrig = false }),
    mr(";tau", "\\tau", { wordTrig = false }),
    mr(";upsilon", "\\upsilon", { wordTrig = false }),
    mr(";Upsilon", "\\Upsilon", { wordTrig = false }),
    mr(";phi", "\\phi", { wordTrig = false }),
    mr(";Phi", "\\Phi", { wordTrig = false }),
    mr(";varphi", "\\varphi", { wordTrig = false }),
    mr(";chi", "\\chi", { wordTrig = false }),
    mr(";psi", "\\psi", { wordTrig = false }),
    mr(";Psi", "\\Psi", { wordTrig = false }),
    mr(";omega", "\\omega", { wordTrig = false }),
    mr(";Omega", "\\Omega", { wordTrig = false }),
    mr(";varpi", "\\varpi", { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Operators and relations
    -- -----------------------------------------------------------------------
    mr(";leq", "\\leq", { wordTrig = false }),
    mr(";geq", "\\geq", { wordTrig = false }),
    mr(";neq", "\\neq", { wordTrig = false }),
    mr(";approx", "\\approx", { wordTrig = false }),
    mr(";cong", "\\cong", { wordTrig = false }),
    mr(";sim", "\\sim", { wordTrig = false }),
    mr(";simeq", "\\simeq", { wordTrig = false }),
    mr(";equiv", "\\equiv", { wordTrig = false }),
    mr(";propto", "\\propto", { wordTrig = false }),
    mr(";gg", "\\gg", { wordTrig = false }),
    mr(";ll", "\\ll", { wordTrig = false }),
    mr(";times", "\\times", { wordTrig = false }),
    mr(";cdot", "\\cdot", { wordTrig = false }),
    mr(";div", "\\div", { wordTrig = false }),
    mr(";pm", "\\pm", { wordTrig = false }),
    mr(";mp", "\\mp", { wordTrig = false }),
    mr(";ast", "\\ast", { wordTrig = false }),
    mr(";star", "\\star", { wordTrig = false }),
    mr(";circ", "\\circ", { wordTrig = false }),
    mr(";bullet", "\\bullet", { wordTrig = false }),
    mr(";oplus", "\\oplus", { wordTrig = false }),
    mr(";otimes", "\\otimes", { wordTrig = false }),
    mr(";odot", "\\odot", { wordTrig = false }),
    mr(";doteq", "\\doteq", { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Arrows
    -- -----------------------------------------------------------------------
    mr(";to", "\\to", { wordTrig = false }),
    mr(";gets", "\\gets", { wordTrig = false }),
    mr(";implies", "\\implies", { wordTrig = false }),
    mr(";impliedby", "\\impliedby", { wordTrig = false }),
    mr(";iff", "\\iff", { wordTrig = false }),
    mr(";rightarrow", "\\rightarrow", { wordTrig = false }),
    mr(";leftarrow", "\\leftarrow", { wordTrig = false }),
    mr(";Rightarrow", "\\Rightarrow", { wordTrig = false }),
    mr(";Leftarrow", "\\Leftarrow", { wordTrig = false }),
    mr(";leftrightarrow", "\\leftrightarrow", { wordTrig = false }),
    mr(";Leftrightarrow", "\\Leftrightarrow", { wordTrig = false }),
    mr(";uparrow", "\\uparrow", { wordTrig = false }),
    mr(";downarrow", "\\downarrow", { wordTrig = false }),
    mr(";Uparrow", "\\Uparrow", { wordTrig = false }),
    mr(";Downarrow", "\\Downarrow", { wordTrig = false }),
    mr(";updownarrow", "\\updownarrow", { wordTrig = false }),
    mr(";Updownarrow", "\\Updownarrow", { wordTrig = false }),
    mr(";mapsto", "\\mapsto", { wordTrig = false }),
    mr(";longmapsto", "\\longmapsto", { wordTrig = false }),
    mr(";longrightarrow", "\\longrightarrow", { wordTrig = false }),
    mr(";longleftarrow", "\\longleftarrow", { wordTrig = false }),
    mr(";Longrightarrow", "\\Longrightarrow", { wordTrig = false }),
    mr(";Longleftarrow", "\\Longleftarrow", { wordTrig = false }),
    mr(";Longleftrightarrow", "\\Longleftrightarrow", { wordTrig = false }),
    mr(";hookrightarrow", "\\hookrightarrow", { wordTrig = false }),
    mr(";hookleftarrow", "\\hookleftarrow", { wordTrig = false }),
    mr(";nearrow", "\\nearrow", { wordTrig = false }),
    mr(";searrow", "\\searrow", { wordTrig = false }),
    mr(";nwarrow", "\\nwarrow", { wordTrig = false }),
    mr(";swarrow", "\\swarrow", { wordTrig = false }),
    mr(";rightharpoonup", "\\rightharpoonup", { wordTrig = false }),
    mr(";rightharpoondown", "\\rightharpoondown", { wordTrig = false }),
    mr(";leftharpoonup", "\\leftharpoonup", { wordTrig = false }),
    mr(";leftharpoondown", "\\leftharpoondown", { wordTrig = false }),
    mr(";rightleftharpoons", "\\rightleftharpoons", { wordTrig = false }),
    mr(";leftrightharpoons", "\\leftrightharpoons", { wordTrig = false }),
    mr(";xrightarrow", "\\xrightarrow", { wordTrig = false }),
    mr(";xleftarrow", "\\xleftarrow", { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Set theory and logic
    -- -----------------------------------------------------------------------
    mr(";in", "\\in", { wordTrig = false }),
    mr(";notin", "\\notin", { wordTrig = false }),
    mr(";ni", "\\ni", { wordTrig = false }),
    mr(";subset", "\\subset", { wordTrig = false }),
    mr(";supset", "\\supset", { wordTrig = false }),
    mr(";subseteq", "\\subseteq", { wordTrig = false }),
    mr(";supseteq", "\\supseteq", { wordTrig = false }),
    mr(";subsetneq", "\\subsetneq", { wordTrig = false }),
    mr(";supsetneq", "\\supsetneq", { wordTrig = false }),
    mr(";cup", "\\cup", { wordTrig = false }),
    mr(";cap", "\\cap", { wordTrig = false }),
    mr(";bigcup", "\\bigcup", { wordTrig = false }),
    mr(";bigcap", "\\bigcap", { wordTrig = false }),
    mr(";sqcup", "\\sqcup", { wordTrig = false }),
    mr(";sqcap", "\\sqcap", { wordTrig = false }),
    mr(";setminus", "\\setminus", { wordTrig = false }),
    mr(";emptyset", "\\emptyset", { wordTrig = false }),
    mr(";varnothing", "\\varnothing", { wordTrig = false }),
    mr(";exists", "\\exists", { wordTrig = false }),
    mr(";nexists", "\\nexists", { wordTrig = false }),
    mr(";forall", "\\forall", { wordTrig = false }),
    mr(";neg", "\\neg", { wordTrig = false }),
    mr(";land", "\\land", { wordTrig = false }),
    mr(";lor", "\\lor", { wordTrig = false }),
    mr(";vee", "\\vee", { wordTrig = false }),
    mr(";wedge", "\\wedge", { wordTrig = false }),
    mr(";vdash", "\\vdash", { wordTrig = false }),
    mr(";dashv", "\\dashv", { wordTrig = false }),
    mr(";models", "\\models", { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Order relations
    -- -----------------------------------------------------------------------
    mr(";prec", "\\prec", { wordTrig = false }),
    mr(";succ", "\\succ", { wordTrig = false }),
    mr(";preceq", "\\preceq", { wordTrig = false }),
    mr(";succeq", "\\succeq", { wordTrig = false }),
    mr(";parallel", "\\parallel", { wordTrig = false }),
    mr(";perp", "\\perp", { wordTrig = false }),
    mr(";mid", "\\mid", { wordTrig = false }),
    mr(";nmid", "\\nmid", { wordTrig = false }),
    mr(";bowtie", "\\bowtie", { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Big operators (readable)
    -- -----------------------------------------------------------------------
    ma(";sum", fmta("\\sum_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") }), { wordTrig = false }),
    ma(";prod", fmta("\\prod_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") }), { wordTrig = false }),
    ma(";coprod", fmta("\\coprod_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") }), { wordTrig = false }),
    ma(";limit", fmta("\\lim_{<> \\to <>} ", { i(1, "n"), i(2, "\\infty") }), { wordTrig = false }),
    ma(";limsup", fmta("\\limsup_{<>} ", { i(1, "n \\to \\infty") }), { wordTrig = false }),
    ma(";liminf", fmta("\\liminf_{<>} ", { i(1, "n \\to \\infty") }), { wordTrig = false }),
    ma(";int", fmta("\\int_{<>}^{<>} <> \\,d<>", { i(1, "a"), i(2, "b"), i(3), i(4, "x") }), { wordTrig = false }),
    ma(";iint", fmta("\\iint_{<>} <> \\,dA", { i(1, "D"), i(2) }), { wordTrig = false }),
    ma(";iiint", fmta("\\iiint_{<>} <> \\,dV", { i(1, "V"), i(2) }), { wordTrig = false }),
    ma(";oint", fmta("\\oint_{<>} <> \\,d<>", { i(1, "C"), i(2), i(3, "s") }), { wordTrig = false }),
    ma(";bigcup-op", fmta("\\bigcup_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") }), { wordTrig = false }),
    ma(";bigcap-op", fmta("\\bigcap_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") }), { wordTrig = false }),
    ma(";bigoplus", fmta("\\bigoplus_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") }), { wordTrig = false }),
    ma(";bigotimes", fmta("\\bigotimes_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") }), { wordTrig = false }),
    ma(";bigsqcup", fmta("\\bigsqcup_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") }), { wordTrig = false }),
    ma(";bigvee", fmta("\\bigvee_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") }), { wordTrig = false }),
    ma(";bigwedge", fmta("\\bigwedge_{<>}^{<>} ", { i(1, "i=1"), i(2, "n") }), { wordTrig = false }),
    mr(";inf", "\\inf", { wordTrig = false }),
    mr(";sup", "\\sup", { wordTrig = false }),
    mr(";max", "\\max", { wordTrig = false }),
    mr(";min", "\\min", { wordTrig = false }),
    mr(";arg", "\\arg", { wordTrig = false }),
    mr(";argmax", "\\operatorname{argmax}", { wordTrig = false }),
    mr(";argmin", "\\operatorname{argmin}", { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Misc symbols (readable)
    -- -----------------------------------------------------------------------
    mr(";infty", "\\infty", { wordTrig = false }),
    mr(";infinity", "\\infty", { wordTrig = false }),
    mr(";partial", "\\partial", { wordTrig = false }),
    mr(";nabla", "\\nabla", { wordTrig = false }),
    mr(";grad", "\\nabla", { wordTrig = false }),
    mr(";ldots", "\\ldots", { wordTrig = false }),
    mr(";cdots", "\\cdots", { wordTrig = false }),
    mr(";vdots", "\\vdots", { wordTrig = false }),
    mr(";ddots", "\\ddots", { wordTrig = false }),
    mr(";ell", "\\ell", { wordTrig = false }),
    mr(";hbar", "\\hbar", { wordTrig = false }),
    mr(";aleph", "\\aleph", { wordTrig = false }),
    mr(";wp", "\\wp", { wordTrig = false }),
    mr(";Re", "\\Re", { wordTrig = false }),
    mr(";Im", "\\Im", { wordTrig = false }),
    mr(";angle", "\\angle", { wordTrig = false }),
    mr(";measuredangle", "\\measuredangle", { wordTrig = false }),
    mr(";triangle", "\\triangle", { wordTrig = false }),
    mr(";square", "\\square", { wordTrig = false }),
    mr(";diamond", "\\diamond", { wordTrig = false }),
    mr(";prime", "\\prime", { wordTrig = false }),
    mr(";backslash", "\\backslash", { wordTrig = false }),
    mr(";therefore", "\\therefore", { wordTrig = false }),
    mr(";because", "\\because", { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Trig / math functions
    -- -----------------------------------------------------------------------
    mr(";sin", "\\sin", { wordTrig = false }),
    mr(";cos", "\\cos", { wordTrig = false }),
    mr(";tan", "\\tan", { wordTrig = false }),
    mr(";sec", "\\sec", { wordTrig = false }),
    mr(";csc", "\\csc", { wordTrig = false }),
    mr(";cot", "\\cot", { wordTrig = false }),
    mr(";arcsin", "\\arcsin", { wordTrig = false }),
    mr(";arccos", "\\arccos", { wordTrig = false }),
    mr(";arctan", "\\arctan", { wordTrig = false }),
    mr(";sinh", "\\sinh", { wordTrig = false }),
    mr(";cosh", "\\cosh", { wordTrig = false }),
    mr(";tanh", "\\tanh", { wordTrig = false }),
    mr(";log", "\\log", { wordTrig = false }),
    mr(";ln", "\\ln", { wordTrig = false }),
    mr(";exp", "\\exp", { wordTrig = false }),
    mr(";det", "\\det", { wordTrig = false }),
    mr(";dim", "\\dim", { wordTrig = false }),
    mr(";ker", "\\ker", { wordTrig = false }),
    mr(";deg", "\\deg", { wordTrig = false }),
    mr(";gcd", "\\gcd", { wordTrig = false }),
    mr(";lcm", "\\operatorname{lcm}", { wordTrig = false }),
    mr(";hom", "\\hom", { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Decorators (readable)
    -- -----------------------------------------------------------------------
    ma(";hat", fmta("\\hat{<>}", { i(1) }), { wordTrig = false }),
    ma(";widehat", fmta("\\widehat{<>}", { i(1) }), { wordTrig = false }),
    ma(";bar", fmta("\\bar{<>}", { i(1) }), { wordTrig = false }),
    ma(";overline", fmta("\\overline{<>}", { i(1) }), { wordTrig = false }),
    ma(";underline", fmta("\\underline{<>}", { i(1) }), { wordTrig = false }),
    ma(";vec", fmta("\\vec{<>}", { i(1) }), { wordTrig = false }),
    ma(";dot", fmta("\\dot{<>}", { i(1) }), { wordTrig = false }),
    ma(";ddot", fmta("\\ddot{<>}", { i(1) }), { wordTrig = false }),
    ma(";dddot", fmta("\\dddot{<>}", { i(1) }), { wordTrig = false }),
    ma(";tilde", fmta("\\tilde{<>}", { i(1) }), { wordTrig = false }),
    ma(";widetilde", fmta("\\widetilde{<>}", { i(1) }), { wordTrig = false }),
    ma(";breve", fmta("\\breve{<>}", { i(1) }), { wordTrig = false }),
    ma(";check", fmta("\\check{<>}", { i(1) }), { wordTrig = false }),
    ma(";acute", fmta("\\acute{<>}", { i(1) }), { wordTrig = false }),
    ma(";grave", fmta("\\grave{<>}", { i(1) }), { wordTrig = false }),
    ma(";overbrace", fmta("\\overbrace{<>}^{<>}", { i(1), i(2) }), { wordTrig = false }),
    ma(";underbrace", fmta("\\underbrace{<>}_{<>}", { i(1), i(2) }), { wordTrig = false }),
    ma(";overrightarrow", fmta("\\overrightarrow{<>}", { i(1) }), { wordTrig = false }),
    ma(";overleftarrow", fmta("\\overleftarrow{<>}", { i(1) }), { wordTrig = false }),
    ma(";boxed", fmta("\\boxed{<>}", { i(1) }), { wordTrig = false }),
    ma(";cancel", fmta("\\cancel{<>}", { i(1) }), { wordTrig = false }),
    ma(";bcancel", fmta("\\bcancel{<>}", { i(1) }), { wordTrig = false }),
    ma(";xcancel", fmta("\\xcancel{<>}", { i(1) }), { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Composite decorators: ;letter-modifier
    -- -----------------------------------------------------------------------
    mr(";alpha-hat", "\\hat{\\alpha}", { wordTrig = false }),
    mr(";alpha-bar", "\\bar{\\alpha}", { wordTrig = false }),
    mr(";alpha-dot", "\\dot{\\alpha}", { wordTrig = false }),
    mr(";alpha-vec", "\\vec{\\alpha}", { wordTrig = false }),
    mr(";alpha-tilde", "\\tilde{\\alpha}", { wordTrig = false }),
    mr(";beta-hat", "\\hat{\\beta}", { wordTrig = false }),
    mr(";beta-dot", "\\dot{\\beta}", { wordTrig = false }),
    mr(";beta-bar", "\\bar{\\beta}", { wordTrig = false }),
    mr(";gamma-hat", "\\hat{\\gamma}", { wordTrig = false }),
    mr(";gamma-dot", "\\dot{\\gamma}", { wordTrig = false }),
    mr(";gamma-bar", "\\bar{\\gamma}", { wordTrig = false }),
    mr(";delta-hat", "\\hat{\\delta}", { wordTrig = false }),
    mr(";delta-dot", "\\dot{\\delta}", { wordTrig = false }),
    mr(";delta-bar", "\\bar{\\delta}", { wordTrig = false }),
    mr(";Delta-hat", "\\hat{\\Delta}", { wordTrig = false }),
    mr(";Delta-dot", "\\dot{\\Delta}", { wordTrig = false }),
    mr(";epsilon-hat", "\\hat{\\epsilon}", { wordTrig = false }),
    mr(";epsilon-dot", "\\dot{\\epsilon}", { wordTrig = false }),
    mr(";epsilon-bar", "\\bar{\\epsilon}", { wordTrig = false }),
    mr(";theta-hat", "\\hat{\\theta}", { wordTrig = false }),
    mr(";theta-dot", "\\dot{\\theta}", { wordTrig = false }),
    mr(";theta-bar", "\\bar{\\theta}", { wordTrig = false }),
    mr(";lambda-hat", "\\hat{\\lambda}", { wordTrig = false }),
    mr(";lambda-bar", "\\bar{\\lambda}", { wordTrig = false }),
    mr(";mu-hat", "\\hat{\\mu}", { wordTrig = false }),
    mr(";mu-bar", "\\bar{\\mu}", { wordTrig = false }),
    mr(";nu-hat", "\\hat{\\nu}", { wordTrig = false }),
    mr(";sigma-hat", "\\hat{\\sigma}", { wordTrig = false }),
    mr(";sigma-bar", "\\bar{\\sigma}", { wordTrig = false }),
    mr(";sigma-tilde", "\\tilde{\\sigma}", { wordTrig = false }),
    mr(";Sigma-hat", "\\hat{\\Sigma}", { wordTrig = false }),
    mr(";tau-hat", "\\hat{\\tau}", { wordTrig = false }),
    mr(";tau-bar", "\\bar{\\tau}", { wordTrig = false }),
    mr(";phi-hat", "\\hat{\\phi}", { wordTrig = false }),
    mr(";phi-bar", "\\bar{\\phi}", { wordTrig = false }),
    mr(";psi-hat", "\\hat{\\psi}", { wordTrig = false }),
    mr(";psi-dot", "\\dot{\\psi}", { wordTrig = false }),
    mr(";omega-hat", "\\hat{\\omega}", { wordTrig = false }),
    mr(";omega-bar", "\\bar{\\omega}", { wordTrig = false }),
    mr(";omega-dot", "\\dot{\\omega}", { wordTrig = false }),
    mr(";Omega-hat", "\\hat{\\Omega}", { wordTrig = false }),
    mr(";rho-hat", "\\hat{\\rho}", { wordTrig = false }),
    mr(";rho-bar", "\\bar{\\rho}", { wordTrig = false }),
    mr(";rho-dot", "\\dot{\\rho}", { wordTrig = false }),
    mr(";xi-hat", "\\hat{\\xi}", { wordTrig = false }),
    mr(";pi-hat", "\\hat{\\pi}", { wordTrig = false }),
    mr(";kappa-hat", "\\hat{\\kappa}", { wordTrig = false }),
    mr(";kappa-bar", "\\bar{\\kappa}", { wordTrig = false }),
    mr(";eta-hat", "\\hat{\\eta}", { wordTrig = false }),
    mr(";eta-bar", "\\bar{\\eta}", { wordTrig = false }),
    mr(";zeta-hat", "\\hat{\\zeta}", { wordTrig = false }),
    mr(";chi-hat", "\\hat{\\chi}", { wordTrig = false }),
    mr(";iota-hat", "\\hat{\\iota}", { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Delimiters (readable)
    -- -----------------------------------------------------------------------
    ma(";paren", fmta("\\left( <> \\right)", { i(1) }), { wordTrig = false }),
    ma(";bracket", fmta("\\left[ <> \\right]", { i(1) }), { wordTrig = false }),
    ma(";brace", fmta("\\left\\{ <> \\right\\}", { i(1) }), { wordTrig = false }),
    ma(";abs", fmta("\\left| <> \\right|", { i(1) }), { wordTrig = false }),
    ma(";norm", fmta("\\left\\| <> \\right\\|", { i(1) }), { wordTrig = false }),
    ma(";angle-bracket", fmta("\\left\\langle <> \\right\\rangle", { i(1) }), { wordTrig = false }),
    ma(";floor", fmta("\\left\\lfloor <> \\right\\rfloor", { i(1) }), { wordTrig = false }),
    ma(";ceil", fmta("\\left\\lceil <> \\right\\rceil", { i(1) }), { wordTrig = false }),
    ma(";inner", fmta("\\langle <>, <> \\rangle", { i(1), i(2) }), { wordTrig = false }),
    ma(";set", fmta("\\{ <> \\mid <> \\}", { i(1), i(2) }), { wordTrig = false }),
    ma(";eval", fmta("\\left. <> \\right|_{<>}", { i(1), i(2) }), { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Math environments (readable)
    -- -----------------------------------------------------------------------
    ma(";pmatrix", fmta("\\begin{pmatrix} <> \\end{pmatrix}", { i(1) }), { wordTrig = false }),
    ma(";bmatrix", fmta("\\begin{bmatrix} <> \\end{bmatrix}", { i(1) }), { wordTrig = false }),
    ma(";vmatrix", fmta("\\begin{vmatrix} <> \\end{vmatrix}", { i(1) }), { wordTrig = false }),
    ma(";Vmatrix", fmta("\\begin{Vmatrix} <> \\end{Vmatrix}", { i(1) }), { wordTrig = false }),
    ma(";matrix", fmta("\\begin{matrix} <> \\end{matrix}", { i(1) }), { wordTrig = false }),
    ma(";cases", fmta("\\begin{cases} <> \\end{cases}", { i(1) }), { wordTrig = false }),
    ma(";aligned", fmta("\\begin{aligned} <> \\end{aligned}", { i(1) }), { wordTrig = false }),
    ma(";gathered", fmta("\\begin{gathered} <> \\end{gathered}", { i(1) }), { wordTrig = false }),
    ma(";array", fmta("\\begin{array}{<>} <> \\end{array}", { i(1, "cc"), i(2) }), { wordTrig = false }),
    ma(";smallmatrix", fmta("\\left(\\begin{smallmatrix} <> \\end{smallmatrix}\\right)", { i(1) }), { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Font commands (readable)
    -- -----------------------------------------------------------------------
    ma(";text", fmta("\\text{<>}", { i(1) }), { wordTrig = false }),
    ma(";mathrm", fmta("\\mathrm{<>}", { i(1) }), { wordTrig = false }),
    ma(";mathbf", fmta("\\mathbf{<>}", { i(1) }), { wordTrig = false }),
    ma(";mathcal", fmta("\\mathcal{<>}", { i(1) }), { wordTrig = false }),
    ma(";mathbb", fmta("\\mathbb{<>}", { i(1) }), { wordTrig = false }),
    ma(";mathfrak", fmta("\\mathfrak{<>}", { i(1) }), { wordTrig = false }),
    ma(";mathscr", fmta("\\mathscr{<>}", { i(1) }), { wordTrig = false }),
    ma(";mathsf", fmta("\\mathsf{<>}", { i(1) }), { wordTrig = false }),
    ma(";mathtt", fmta("\\mathtt{<>}", { i(1) }), { wordTrig = false }),
    ma(";bold", fmta("\\boldsymbol{<>}", { i(1) }), { wordTrig = false }),
    ma(";operatorname", fmta("\\operatorname{<>}", { i(1) }), { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Common sets (readable)
    -- -----------------------------------------------------------------------
    mr(";reals", "\\mathbb{R}", { wordTrig = false }),
    mr(";integers", "\\mathbb{Z}", { wordTrig = false }),
    mr(";naturals", "\\mathbb{N}", { wordTrig = false }),
    mr(";rationals", "\\mathbb{Q}", { wordTrig = false }),
    mr(";complex", "\\mathbb{C}", { wordTrig = false }),
    mr(";field", "\\mathbb{F}", { wordTrig = false }),
    mr(";primes", "\\mathbb{P}", { wordTrig = false }),
    mr(";hilbert", "\\mathcal{H}", { wordTrig = false }),
    mr(";lagrangian", "\\mathcal{L}", { wordTrig = false }),
    mr(";hamiltonian", "\\mathcal{H}", { wordTrig = false }),
    mr(";fourier", "\\mathcal{F}", { wordTrig = false }),
    mr(";laplace-transform", "\\mathcal{L}", { wordTrig = false }),
    mr(";powerset", "\\mathcal{P}", { wordTrig = false }),

    -- -----------------------------------------------------------------------
    -- Roots and miscellaneous (NEW)
    -- -----------------------------------------------------------------------
    ma(";sqrt", fmta("\\sqrt{<>}", { i(1) }), { wordTrig = false }),
    ma(";nroot", fmta("\\sqrt[<>]{<>}", { i(1, "n"), i(2) }), { wordTrig = false }),
    ma(";binom", fmta("\\binom{<>}{<>}", { i(1, "n"), i(2, "k") }), { wordTrig = false }),
    ma(";stackrel", fmta("\\stackrel{<>}{<>}", { i(1), i(2) }), { wordTrig = false }),
    ma(";overset", fmta("\\overset{<>}{<>}", { i(1), i(2) }), { wordTrig = false }),
    ma(";underset", fmta("\\underset{<>}{<>}", { i(1), i(2) }), { wordTrig = false }),
    mr(";phantom", "\\phantom", { wordTrig = false }),
    mr(";quad", "\\quad", { wordTrig = false }),
    mr(";qquad", "\\qquad", { wordTrig = false }),
```

### D.4 Summary of New Readable-Name Snippets

| Category | Existing | New Readable Aliases | New Commands |
|----------|----------|---------------------|-------------|
| Fractions | 2 | 3 | `\dfrac`, `\tfrac` |
| Sub/super | 5 | 9 | `^{c}`, `^{T}`, `^{\dagger}` |
| Greek | 35 | 41 | `\varrho`, `\varsigma`, `\upsilon`, `\Upsilon`, `\varpi` |
| Operators/relations | 21 | 24 | `\sim`, `\simeq`, `\equiv`, `\propto`, `\div`, `\pm`, `\mp`, `\oplus`, `\otimes`, `\odot` |
| Arrows | 3 | 36 | Full arrow family |
| Set/logic | 0 (inline) | 29 | `\ni`, `\sqcup`, `\sqcap`, `\nexists`, `\neg`, `\vdash`, `\models` |
| Order relations | 0 | 9 | `\prec`, `\succ`, `\parallel`, `\perp`, `\mid`, `\nmid`, `\bowtie` |
| Big operators | 4 | 23 | `\coprod`, `\limsup`, `\liminf`, `\iint`, `\iiint`, `\oint`, `\bigoplus`, etc. |
| Misc symbols | 5 | 24 | `\ell`, `\hbar`, `\aleph`, `\therefore`, `\because`, etc. |
| Trig/functions | 0 | 22 | All standard trig + `\log`, `\ln`, `\exp`, `\det`, `\ker`, etc. |
| Decorators | 6 | 23 generic + 53 composite | `\widehat`, `\overline`, `\breve`, `\boxed`, `\cancel`, + `;letter-modifier` combos |
| Delimiters | 5 | 11 | `\norm`, `\floor`, `\ceil`, `\inner`, `\set`, `\eval` |
| Environments | 3 | 10 | `\vmatrix`, `\Vmatrix`, `\matrix`, `\aligned`, `\gathered`, `\array` |
| Fonts | 5 | 11 | `\mathfrak`, `\mathscr`, `\mathsf`, `\mathtt`, `\boldsymbol` |
| Sets (named) | 5 | 13 | `\mathbb{F}`, `\mathbb{P}`, `\mathcal{H}`, `\mathcal{L}`, `\mathcal{F}`, `\mathcal{P}` |
| Roots/misc | 0 | 9 | `\sqrt`, `\binom`, `\stackrel`, `\overset`, `\underset`, `\quad` |

**Total new readable-name snippets: ~317**
**Grand total (existing + new): ~413 math autosnippets**

---

## E. Template Section Snippets (CRITICAL)

**File to edit:** `/home/andrew-cmmg/.config/nvim/luasnippets/markdown.lua`

Convention: `;templatename-sectionname` inserts just that section from the template.
These are added to the `local snippets = { ... }` table in markdown.lua.

### E.1 Template and Section Inventory

All 24 templates from `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/templates/` with their sections:

#### 1. daily_log (Daily Log)
- Morning Plan > Carried Forward
- Morning Plan > Today's Focus
- Morning Plan > Other Priorities
- Morning Plan > Tasks Due Today
- Work Log
- Scratchpad
- End of Day > Completed Today
- End of Day > Blockers and Open Questions
- End of Day > Reflection
- End of Day > Tomorrow's Priorities

#### 2. task (Task Note)
- Objective
- Subtasks
- Context and Dependencies
- Approach
- Notes
- Log

#### 3. meeting (Meeting Note)
- Agenda
- Discussion Notes
- Feedback / Guidance
- Action Items
- Decisions Made
- Follow-Up
- Notes

#### 4. concept (Concept Note)
- Core Idea
- Explanation
- Evidence / Support
- Counterpoints / Limitations
- Connections > Related Concepts
- Connections > Relevant Methods
- Connections > Projects Where This Applies
- Origin
- Open Questions
- Notes

#### 5. literature (Literature Note)
- Core Claim / Thesis
- Key Results
- Methodology
- Relevance to My Work > Points of Agreement
- Relevance to My Work > Points of Difference
- Relevance to My Work > Gaps / Opportunities
- Figures Worth Referencing
- Methods Worth Noting
- Questions This Raises
- Quotes / Key Passages
- Related Papers
- Notes

#### 6. recurring_task (Recurring Task)
- What This Is
- Checklist
- Completion Log

#### 7. methodology (Methodology Note)
- Purpose
- Approach > Description
- Approach > Implementation Details
- Approach > Algorithm / Procedure
- Approach > Code Snippet
- Parameters and Configuration
- Validation > Validated Against
- Validation > Validation Results
- Known Limitations
- Comparison to Alternatives
- Used In > Simulations
- Used In > Papers / Drafts
- References
- Changelog
- Notes

#### 8. changelog (Changelog)
- Summary
- Major Changes > Section-Level Modifications
- Major Changes > Figure Changes
- Minor Changes
- Motivation
- Data Dependencies
- Open Issues Remaining
- Links

#### 9. presentation (Presentation Note)
- Audience and Goal
- Slide Outline
- Key Figures Used
- Talking Points
- Anticipated Questions
- Changes from Previous Version
- Post-Presentation Notes
- Notes

#### 10. draft (Draft Note)
- What Changed from Previous Version
- Structure
- Figures
- Data Dependencies
- Feedback Received
- Submission Notes
- Notes

#### 11. financial_snapshot (Financial Snapshot)
- Net Worth Summary
- Income
- Expenses Summary
- Key Events This Period
- Goals Progress
- Action Items
- Reflection
- Previous Snapshot

#### 12. simulation (Simulation Note)
- Purpose
- Parameters
- Input Files
- Methods Used
- Results > Summary
- Results > Key Metrics
- Results > Figures
- Comparison to Previous Runs
- Issues / Troubleshooting
- Feeds Into
- Post-Processing
- Notes

#### 13. project_dashboard (Project Dashboard)
- Objective
- Current Focus
- Pipeline Status
- Key Resources
- Task Progress
- Task Tracker > Active
- Task Tracker > Backlog
- Recently Completed
- All Open Tasks
- Collaborators and Contacts
- Decision Log
- Related Knowledge Base
- Sub-Notes
- Backlinks
- Log
- Notes

#### 14. weekly_review (Weekly Review)
- This Week's Log Entries
- Research Accomplishments
- Personal / Life Accomplishments
- Progress by Project
- Areas Check-In
- Tasks Completed This Week
- Overdue Tasks
- Overdue Recurring Tasks
- Key Insights
- Decisions Made
- What Didn't Work
- Vault Maintenance
- Training This Week
- Next Week's Priorities

#### 15. monthly_review (Monthly Review)
- Monthly Summary
- Weekly Reviews This Month
- Research Accomplishments
- Personal / Life Accomplishments
- Project Progress
- Areas Health Check
- Tasks Completed This Month
- Key Decisions and Insights
- What Worked
- What Didn't Work
- Goals for Next Month

#### 16. quarterly_review (Quarterly Review)
- Quarter Overview
- Monthly Reviews This Quarter
- Strategic Assessment
- Project Status Summary
- OKR / Goal Progress
- Areas Deep Dive
- Key Wins
- Key Challenges
- Lessons Learned
- Next Quarter Priorities

#### 17. yearly_review (Yearly Review)
- Year Overview
- Quarterly Reviews
- Major Accomplishments
- Projects Completed This Year
- Projects Started / In Progress
- Areas Annual Assessment
- Biggest Lessons
- Biggest Surprises
- What I'd Do Differently
- Theme / Word for Next Year
- Goals for Next Year

#### 18. area_dashboard (Area Dashboard)
- Purpose
- Current Status
- Active Projects
- Recurring Tasks and Maintenance
- Key Documents and References
- Key People / Contacts
- Upcoming Deadlines
- Decision Log
- Review Checklist
- Notes

#### 19. journal (Journal Entry)
- Observations
- What Worked
- Challenges
- Open Questions
- Notes

#### 20. analysis (Analysis Note)
- Objective
- Runs Compared
- Methods / Approach
- Results > Findings
- Results > Key Data
- Results > Figures
- Interpretation
- Comparison to Literature
- Implications for Paper
- Open Questions
- Follow-Up Work Needed
- Feeds Into
- Notes

#### 21. finding (Finding Note)
- Summary
- Context
- Details > Observation
- Details > Root Cause
- Details > Evidence
- Impact
- Resolution
- Action Items
- Lessons Learned
- Notes

#### 22. domain_moc (Domain MOC)
- Core Concepts
- Sub-Domains
- Active Projects
- Completed Projects
- Key Methods
- Key Literature
- Key People
- Open Questions
- Emerging Ideas
- Resources
- Timeline / Milestones
- Notes

#### 23. person (Person Note)
- Context
- Shared Projects
- Meeting Notes
- Their Papers / Work
- Feedback Patterns
- Preferences and Communication Style
- Key Conversations and Decisions
- Notes

#### 24. asset (Asset Note)
- Key Details
- Associated Recurring Tasks
- Documents
- Service / Transaction History
- Upcoming
- Notes

### E.2 Complete Snippet Code

Add to the `local snippets = { ... }` table in
`/home/andrew-cmmg/.config/nvim/luasnippets/markdown.lua`.

```lua
  ---------------------------------------------------------------------------
  -- Template Section Snippets
  -- Convention: ;templatename-sectionname
  ---------------------------------------------------------------------------

  -- =========================================================================
  -- DAILY LOG sections
  -- =========================================================================

  s({ trig = ";dailylog-focus", desc = "Daily Log: Today's Focus section" }, {
    t({ "### Today's Focus", "", "> [!target] The single biggest task to complete today. Link to its parent project.", "", "- [ ]", "" }),
  }),

  s({ trig = ";dailylog-priorities", desc = "Daily Log: Other Priorities section" }, {
    t({ "### Other Priorities", "", "- [ ] " }), i(1),
    t({ "", "- [ ] " }), i(2),
    t({ "", "- [ ] " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";dailylog-worklog", desc = "Daily Log: Work Log section" }, {
    t({ "## Work Log", "", "> Add an entry for each work block. Include the time range, project, and what you did.", "" }),
    t({ "", "- **__:__ - __:__** | " }), i(1),
    t({ "", "- **__:__ - __:__** | " }), i(2),
    t({ "", "- **__:__ - __:__** | " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";dailylog-scratchpad", desc = "Daily Log: Scratchpad section" }, {
    t({ "## Scratchpad", "", "> Fleeting thoughts, ideas, links, questions. Process into proper notes later.", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";dailylog-completed", desc = "Daily Log: Completed Today section" }, {
    t({ "### Completed Today", "", "- [x] " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";dailylog-blockers", desc = "Daily Log: Blockers section" }, {
    t({ "### Blockers & Open Questions", "", "> [!warning] What's preventing progress? What needs to be resolved?", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";dailylog-reflection", desc = "Daily Log: Reflection section" }, {
    t({ "### Reflection", "", "> One thing I learned, one decision I made, or one thing that clicked.", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";dailylog-tomorrow", desc = "Daily Log: Tomorrow's Priorities section" }, {
    t({ "### Tomorrow's Priorities", "", "- [ ] " }), i(1),
    t({ "", "- [ ] " }), i(2),
    t({ "", "- [ ] " }), i(3),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- TASK sections
  -- =========================================================================

  s({ trig = ";task-objective", desc = "Task: Objective section" }, {
    t({ '## Objective', '', '> [!abstract] What does "done" look like for this task?', '>', '', "" }),
  }),

  s({ trig = ";task-subtasks", desc = "Task: Subtasks section" }, {
    t({ "## Subtasks", "", "- [ ] **[due:: ]** : [priority:: ] : " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";task-context", desc = "Task: Context & Dependencies section" }, {
    t({ "## Context & Dependencies", "", "> [!info] What prerequisite work, resources, or people does this depend on?", "" }),
    t({ "", "- **Blocked by:** " }), i(1),
    t({ "", "- **Related notes:** [[" }), i(2), t("]]"),
    t({ "", "" }),
  }),

  s({ trig = ";task-approach", desc = "Task: Approach section" }, {
    t({ "## Approach", "", "> [!tip] How will you tackle this? Key steps or strategy.", "", "1. " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";task-log", desc = "Task: Log entry" }, {
    t("### "), i(1, "YYYY-MM-DD"),
    t({ "", "- " }), i(2, "Entry"),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- MEETING sections
  -- =========================================================================

  s({ trig = ";meeting-agenda", desc = "Meeting: Agenda section" }, {
    t({ "## Agenda", "", "1. " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";meeting-discussion", desc = "Meeting: Discussion Notes section" }, {
    t({ "## Discussion Notes", "", "" }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";meeting-feedback", desc = "Meeting: Feedback / Guidance section" }, {
    t({ "## Feedback / Guidance", "", "> [!important] Specific feedback on drafts, methods, direction", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";meeting-actions", desc = "Meeting: Action Items section" }, {
    t({ "## Action Items", "", "- [ ] " }), i(1),
    t({ "", "- [ ] " }), i(2),
    t({ "", "" }),
  }),

  s({ trig = ";meeting-decisions", desc = "Meeting: Decisions Made section" }, {
    t({ "## Decisions Made", "", "| Decision | Rationale |", "| -------- | --------- |", "| " }), i(1), t(" | "), i(2), t({ " |", "" }),
  }),

  s({ trig = ";meeting-followup", desc = "Meeting: Follow-Up section" }, {
    t({ "## Follow-Up", "", "- **Next meeting:** " }), i(1),
    t({ "", "- **Items to prepare:** " }), i(2),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- CONCEPT sections
  -- =========================================================================

  s({ trig = ";concept-coreidea", desc = "Concept: Core Idea section" }, {
    t({ "## Core Idea", "", "> [!abstract] State the concept in 2-3 sentences. If you can't, it might need to be split into multiple notes.", ">", "", "" }),
  }),

  s({ trig = ";concept-explanation", desc = "Concept: Explanation section" }, {
    t({ "## Explanation", "", "" }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";concept-evidence", desc = "Concept: Evidence / Support section" }, {
    t({ "## Evidence / Support", "", "> [!check] What observations, data, or literature support this idea?", "", "- [[" }), i(1), t("]]"),
    t({ "", "" }),
  }),

  s({ trig = ";concept-counterpoints", desc = "Concept: Counterpoints / Limitations section" }, {
    t({ "## Counterpoints / Limitations", "", "> [!warning] Where does this idea break down or not apply?", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";concept-connections", desc = "Concept: Connections section" }, {
    t({ "## Connections", "", "> [!link] How does this relate to other concepts in your vault?", "" }),
    t({ "", "### Related Concepts", "", "- [[" }), i(1), t("]]"),
    t({ "", "", "### Relevant Methods", "", "- [[" }), i(2), t("]]"),
    t({ "", "", "### Projects Where This Applies", "", "- [[" }), i(3), t("]]"),
    t({ "", "" }),
  }),

  s({ trig = ";concept-origin", desc = "Concept: Origin section" }, {
    t({ "## Origin", "", "> Where did this idea first come up?", "", "- First noted in: [[" }), i(1), t("]]"),
    t({ "", "- Triggered by: " }), i(2),
    t({ "", "" }),
  }),

  s({ trig = ";concept-questions", desc = "Concept: Open Questions section" }, {
    t({ "## Open Questions", "", "- [ ] " }), i(1),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- LITERATURE sections
  -- =========================================================================

  s({ trig = ";literature-claim", desc = "Literature: Core Claim / Thesis section" }, {
    t({ "## Core Claim / Thesis", "", "> [!summary]", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";literature-results", desc = "Literature: Key Results section" }, {
    t({ "## Key Results", "", "1. " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";literature-methodology", desc = "Literature: Methodology section" }, {
    t({ "## Methodology", "" }),
    t({ "", "- **Simulation / Experimental approach:** " }), i(1),
    t({ "", "- **Potential / Material:** " }), i(2),
    t({ "", "- **Key parameters:** " }), i(3),
    t({ "", "- **Boundary conditions:** " }), i(4),
    t({ "", "" }),
  }),

  s({ trig = ";literature-relevance", desc = "Literature: Relevance to My Work section" }, {
    t({ "## Relevance to My Work", "", "> [!important] Why does this paper matter for my research?", "> " }), i(1),
    t({ "", "", "### Points of Agreement", "", "- " }), i(2),
    t({ "", "", "### Points of Difference", "", "- " }), i(3),
    t({ "", "", "### Gaps / Opportunities", "", "> [!tip] What didn't they do that I can?", "> " }), i(4),
    t({ "", "" }),
  }),

  s({ trig = ";literature-figures", desc = "Literature: Figures Worth Referencing section" }, {
    t({ "## Figures Worth Referencing", "", "| Their Figure | What It Shows | Comparison to My Work |", "| ------------ | ------------- | --------------------- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t({ " |", "" }),
  }),

  s({ trig = ";literature-methods", desc = "Literature: Methods Worth Noting section" }, {
    t({ "## Methods Worth Noting", "", "> [!warning] Methodological choices to be aware of (thermostat, boundary conditions, filtering, etc.)", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";literature-questions", desc = "Literature: Questions This Raises section" }, {
    t({ "## Questions This Raises", "", "- [ ] " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";literature-quotes", desc = "Literature: Quotes / Key Passages section" }, {
    t({ "## Quotes / Key Passages", "", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";literature-related", desc = "Literature: Related Papers section" }, {
    t({ "## Related Papers", "", "- [[" }), i(1), t("]]"),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- METHODOLOGY sections
  -- =========================================================================

  s({ trig = ";methodology-purpose", desc = "Methodology: Purpose section" }, {
    t({ "## Purpose", "", "> [!abstract] What problem does this method solve?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";methodology-approach", desc = "Methodology: Approach section" }, {
    t({ "## Approach", "" }),
    t({ "", "### Description", "", "" }), i(1),
    t({ "", "", "### Implementation Details", "" }),
    t({ "", "- **Software / Tool:** " }), i(2),
    t({ "", "- **Key commands / functions:** " }), i(3),
    t({ "", "- **Language / Scripts:** [[" }), i(4), t("]]"),
    t({ "", "", "### Algorithm / Procedure", "", "1. " }), i(5),
    t({ "", "", "### Code Snippet", "", "```", "# Key implementation detail", "```", "" }),
  }),

  s({ trig = ";methodology-params", desc = "Methodology: Parameters & Configuration section" }, {
    t({ "## Parameters & Configuration", "", "| Parameter | Value | Justification |", "| --------- | ----- | ------------- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t({ " |", "" }),
  }),

  s({ trig = ";methodology-validation", desc = "Methodology: Validation section" }, {
    t({ "## Validation", "", "> [!check] How was this method validated?", "" }),
    t({ "", "### Validated Against", "", "- [[" }), i(1), t("]]"),
    t({ "", "", "### Validation Results", "", "- " }), i(2),
    t({ "", "" }),
  }),

  s({ trig = ";methodology-limitations", desc = "Methodology: Known Limitations section" }, {
    t({ "## Known Limitations", "", "> [!warning]", "", "1. " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";methodology-comparison", desc = "Methodology: Comparison to Alternatives section" }, {
    t({ "## Comparison to Alternatives", "", "| Method | Pros | Cons | When to Use |", "| ------ | ---- | ---- | ----------- |", "| **This method** | " }), i(1), t(" | "), i(2), t(" | "), i(3), t({ " |", "" }),
    t("| [["), i(4), t("]] | "), i(5), t(" | "), i(6), t(" | "), i(7), t({ " |", "" }),
  }),

  s({ trig = ";methodology-usedin", desc = "Methodology: Used In section" }, {
    t({ "## Used In", "", "> [!info] Simulations and papers that use this method", "" }),
    t({ "", "### Simulations", "", "- [[" }), i(1), t("]]"),
    t({ "", "", "### Papers / Drafts", "", "- [[" }), i(2), t("]]"),
    t({ "", "" }),
  }),

  s({ trig = ";methodology-changelog", desc = "Methodology: Changelog section" }, {
    t({ "## Changelog", "", "| Date | Change | Reason |", "| ---- | ------ | ------ |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t({ " |", "" }),
  }),

  -- =========================================================================
  -- SIMULATION sections
  -- =========================================================================

  s({ trig = ";simulation-purpose", desc = "Simulation: Purpose section" }, {
    t({ "## Purpose", "", "> [!abstract] What question is this run trying to answer?", ">", "", "" }),
  }),

  s({ trig = ";simulation-params", desc = "Simulation: Parameters table" }, {
    t({ "## Parameters", "", "| Parameter | Value |", "| --------- | ----- |", "| Software | " }), i(1),
    t({ " |", "| Potential | " }), i(2),
    t({ " |", "| Material | " }), i(3),
    t({ " |", "| Sample geometry | " }), i(4),
    t({ " |", "| Domain size | " }), i(5),
    t({ " |", "| Timestep | " }), i(6),
    t({ " |", "| Boundary conditions | " }), i(7),
    t({ " |", "" }),
  }),

  s({ trig = ";simulation-inputfiles", desc = "Simulation: Input Files section" }, {
    t({ "## Input Files", "", "- **Script:** " }), i(1),
    t({ "", "- **Data file:** " }), i(2),
    t({ "", "- **Potential file:** " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";simulation-methods", desc = "Simulation: Methods Used section" }, {
    t({ "## Methods Used", "", "- [[" }), i(1), t("]]"),
    t({ "", "" }),
  }),

  s({ trig = ";simulation-results", desc = "Simulation: Results section" }, {
    t({ "## Results", "", "> [!success] Key findings", "" }),
    t({ "", "### Summary", "", "" }), i(1),
    t({ "", "", "### Key Metrics", "", "| Metric | Value | Notes |", "| ------ | ----- | ----- |", "| " }), i(2), t(" | "), i(3), t(" | "), i(4), t({ " |", "" }),
    t({ "", "### Figures", "", "> Embed key output plots here", "", "" }),
  }),

  s({ trig = ";simulation-comparison", desc = "Simulation: Comparison to Previous Runs section" }, {
    t({ "## Comparison to Previous Runs", "", "| Run | Key Difference | Result Difference |", "| --- | -------------- | ----------------- |", "| [[" }), i(1), t("]] | "), i(2), t(" | "), i(3), t({ " |", "" }),
  }),

  s({ trig = ";simulation-issues", desc = "Simulation: Issues / Troubleshooting section" }, {
    t({ "## Issues / Troubleshooting", "", "> [!bug] Problems encountered during this run", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";simulation-feedsinto", desc = "Simulation: Feeds Into section" }, {
    t({ "## Feeds Into", "", "> [!info] Where do these results go?", "" }),
    t({ "", "- **Draft:** [[" }), i(1), t("]]"),
    t({ "", "- **Figure(s):** " }), i(2),
    t({ "", "- **Analysis:** [[" }), i(3), t("]]"),
    t({ "", "" }),
  }),

  s({ trig = ";simulation-postprocess", desc = "Simulation: Post-Processing section" }, {
    t({ "## Post-Processing", "", "- [ ] Data extracted", "- [ ] Plots generated", "- [ ] Results documented", "- [ ] Compared against previous runs", "" }),
  }),

  s({ trig = ";simulation-figures", desc = "Simulation: Figures subsection" }, {
    t({ "### Figures", "", "> Embed key output plots here", "", "![[" }), i(1), t("]]"),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- ANALYSIS sections
  -- =========================================================================

  s({ trig = ";analysis-objective", desc = "Analysis: Objective section" }, {
    t({ "## Objective", "", "> [!abstract] What question does this analysis answer?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";analysis-runs", desc = "Analysis: Runs Compared section" }, {
    t({ "## Runs Compared", "", "| Simulation | Key Variable | Relevant Output |", "| ---------- | ------------ | --------------- |", "| [[" }), i(1), t("]] | "), i(2), t(" | "), i(3), t({ " |", "" }),
  }),

  s({ trig = ";analysis-methods", desc = "Analysis: Methods / Approach section" }, {
    t({ "## Methods / Approach", "", "> [!info] How was this analysis performed?", "" }),
    t({ "", "- **Tools used:** " }), i(1),
    t({ "", "- **Scripts:** [[" }), i(2), t("]]"),
    t({ "", "- **Post-processing steps:**", "", "1. " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";analysis-results", desc = "Analysis: Results section" }, {
    t({ "## Results", "", "### Findings", "", "" }), i(1),
    t({ "", "", "### Key Data", "", "| Condition | Metric 1 | Metric 2 | Notes |", "| --------- | -------- | -------- | ----- |", "| " }), i(2), t(" | "), i(3), t(" | "), i(4), t(" | "), i(5), t({ " |", "" }),
    t({ "", "### Figures", "", "> Embed or link key plots", "> `![[]]`", "" }),
  }),

  s({ trig = ";analysis-interpretation", desc = "Analysis: Interpretation section" }, {
    t({ "## Interpretation", "", "> [!tip] What do these results mean physically?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";analysis-litcompare", desc = "Analysis: Comparison to Literature section" }, {
    t({ "## Comparison to Literature", "", "| Source | Their Result | My Result | Agreement? |", "| ------ | ------------ | --------- | ---------- |", "| [[" }), i(1), t("]] | "), i(2), t(" | "), i(3), t(" | "), i(4), t({ " |", "" }),
  }),

  s({ trig = ";analysis-implications", desc = "Analysis: Implications for Paper section" }, {
    t({ "## Implications for Paper", "", "> [!important] How does this shape the narrative?" }),
    t({ "", "", "- **Section affected:** " }), i(1),
    t({ "", "- **Figure(s) generated:** " }), i(2),
    t({ "", "- **Key claim supported:** " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";analysis-followup", desc = "Analysis: Follow-Up Work Needed section" }, {
    t({ "## Follow-Up Work Needed", "", "- [ ] " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";analysis-feedsinto", desc = "Analysis: Feeds Into section" }, {
    t({ "## Feeds Into", "", "- **Draft:** [[" }), i(1), t("]]"),
    t({ "", "- **Changelog:** [[" }), i(2), t("]]"),
    t({ "", "- **Presentation:** [[" }), i(3), t("]]"),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- FINDING sections
  -- =========================================================================

  s({ trig = ";finding-summary", desc = "Finding: Summary section" }, {
    t({ "## Summary", "", "> [!abstract] What was discovered?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";finding-context", desc = "Finding: Context section" }, {
    t({ "## Context", "", "> [!info] What were you doing when this came up?" }),
    t({ "", "", "- **Task / analysis:** " }), i(1),
    t({ "", "- **Simulation run:** [[" }), i(2), t("]]"),
    t({ "", "- **Relevant data:** " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";finding-details", desc = "Finding: Details section" }, {
    t({ "## Details", "", "### Observation", "", "" }), i(1),
    t({ "", "", "### Root Cause", "", "" }), i(2),
    t({ "", "", "### Evidence", "", "| Source | What it shows |", "| ------ | ------------- |", "| [[" }), i(3), t("]] | "), i(4), t({ " |", "" }),
  }),

  s({ trig = ";finding-impact", desc = "Finding: Impact section" }, {
    t({ "## Impact", "", "> [!warning] What does this affect?" }),
    t({ "", "", "- **Affected simulations:** " }), i(1),
    t({ "", "- **Affected analyses:** " }), i(2),
    t({ "", "- **Effect on conclusions:** " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";finding-resolution", desc = "Finding: Resolution section" }, {
    t({ "## Resolution", "", "> [!success] What was done to address this?", "", "1. " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";finding-lessons", desc = "Finding: Lessons Learned section" }, {
    t({ "## Lessons Learned", "", "> [!tip] What should be done differently next time?", "", "- " }), i(1),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- CHANGELOG sections
  -- =========================================================================

  s({ trig = ";changelog-summary", desc = "Changelog: Summary section" }, {
    t({ "## Summary", "", "> [!abstract] One-line summary of what this version accomplishes", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";changelog-major", desc = "Changelog: Major Changes section" }, {
    t({ "## Major Changes", "", "### Section-Level Modifications", "", "| Section | Change Type | Description |", "| ------- | ----------- | ----------- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t({ " |", "" }),
    t({ "", "### Figure Changes", "", "| Figure | Action | Description |", "| ------ | ------ | ----------- |", "| " }), i(4), t(" | "), i(5), t(" | "), i(6), t({ " |", "" }),
  }),

  s({ trig = ";changelog-minor", desc = "Changelog: Minor Changes section" }, {
    t({ "## Minor Changes", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";changelog-motivation", desc = "Changelog: Motivation section" }, {
    t({ "## Motivation", "", "> [!question] Why were these changes made?", "> Sources: advisor feedback, reviewer comments, new data, etc.", "", "- " }), i(1),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- PRESENTATION sections
  -- =========================================================================

  s({ trig = ";presentation-audience", desc = "Presentation: Audience & Goal section" }, {
    t({ "## Audience & Goal", "", "> [!abstract] Who is this for and what should they walk away understanding?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";presentation-outline", desc = "Presentation: Slide Outline section" }, {
    t({ "## Slide Outline", "", "| # | Slide Title | Content / Key Point | Data Source |", "| - | ----------- | ------------------- | ----------- |", "| 1 | Title slide |  |  |", "| 2 | " }), i(1), t(" | "), i(2), t(" | [["), i(3), t({ "]] |", "" }),
  }),

  s({ trig = ";presentation-talking", desc = "Presentation: Talking Points section" }, {
    t({ "## Talking Points", "", "> [!note] Things to say that aren't on the slides", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";presentation-questions", desc = "Presentation: Anticipated Questions section" }, {
    t({ "## Anticipated Questions", "", "| Question | Prepared Answer |", "| -------- | --------------- |", "| " }), i(1), t(" | "), i(2), t({ " |", "" }),
  }),

  s({ trig = ";presentation-postnotes", desc = "Presentation: Post-Presentation Notes section" }, {
    t({ "## Post-Presentation Notes", "", "> [!people] Feedback received, questions asked, follow-ups needed", "", "- " }), i(1),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- DRAFT sections
  -- =========================================================================

  s({ trig = ";draft-structure", desc = "Draft: Structure section" }, {
    t({ "## Structure", "", "| Section | Status | Notes |", "| ------- | ------ | ----- |" }),
    t({ "", "| Abstract | " }), i(1), t(" | "), i(2), t(" |"),
    t({ "", "| Introduction | " }), i(3), t(" | "), i(4), t(" |"),
    t({ "", "| Methodology | " }), i(5), t(" | "), i(6), t(" |"),
    t({ "", "| Results | " }), i(7), t(" | "), i(8), t(" |"),
    t({ "", "| Discussion | " }), i(9), t(" | "), i(10), t(" |"),
    t({ "", "| Conclusion | " }), i(11), t(" | "), i(12), t({ " |", "" }),
  }),

  s({ trig = ";draft-figures", desc = "Draft: Figures section" }, {
    t({ "## Figures", "", "| Figure | Source | Description | Status |", "| ------ | ------ | ----------- | ------ |", "| Fig. 1 | [[" }), i(1), t("]] | "), i(2), t({ " | Draft / Final |", "" }),
  }),

  s({ trig = ";draft-feedback", desc = "Draft: Feedback Received section" }, {
    t({ "## Feedback Received", "", "> [!people] Reviewer / advisor comments", "", "- [ ] " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";draft-submission", desc = "Draft: Submission Notes section" }, {
    t({ "## Submission Notes", "", "> [!note] Journal formatting requirements, cover letter status, supplementary materials", "", "- " }), i(1),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- JOURNAL ENTRY sections
  -- =========================================================================

  s({ trig = ";journal-observations", desc = "Journal: Observations section" }, {
    t({ "## Observations", "", "> [!abstract] What did I notice or learn today?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";journal-worked", desc = "Journal: What Worked section" }, {
    t({ "## What Worked", "", "> [!success] What went well? What should I keep doing?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";journal-challenges", desc = "Journal: Challenges section" }, {
    t({ "## Challenges", "", "> [!warning] What was difficult? What slowed me down?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";journal-questions", desc = "Journal: Open Questions section" }, {
    t({ "## Open Questions", "", "> [!question] What remains unresolved? What should I investigate next?", "", "- [ ] " }), i(1),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- RECURRING TASK sections
  -- =========================================================================

  s({ trig = ";recurring-whatis", desc = "Recurring Task: What This Is section" }, {
    t({ "## What This Is", "", "> [!abstract] What needs to happen, and why does it matter if it's skipped?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";recurring-checklist", desc = "Recurring Task: Checklist section" }, {
    t({ "## Checklist", "", "- [ ] " }), i(1),
    t({ "", "- [ ] " }), i(2),
    t({ "", "- [ ] " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";recurring-completionlog", desc = "Recurring Task: Completion Log section" }, {
    t({ "## Completion Log", "", "| Date | Notes |", "| ---- | ----- |", "| " }), i(1), t(" | "), i(2), t({ " |", "" }),
  }),

  -- =========================================================================
  -- FINANCIAL SNAPSHOT sections
  -- =========================================================================

  s({ trig = ";financial-networth", desc = "Financial: Net Worth Summary section" }, {
    t({ "## Net Worth Summary", "", "| Category | Amount | Change from Last Period | Notes |", "| -------- | ------ | ----------------------- | ----- |" }),
    t({ "", "| Checking |  |  |  |" }),
    t({ "", "| Savings / Emergency |  |  |  |" }),
    t({ "", "| Retirement (401k/IRA) |  |  |  |" }),
    t({ "", "| Investments |  |  |  |" }),
    t({ "", "| **Total Assets** |  |  |  |" }),
    t({ "", "| Credit Cards |  |  |  |" }),
    t({ "", "| Student Loans |  |  |  |" }),
    t({ "", "| Other Debt |  |  |  |" }),
    t({ "", "| **Total Liabilities** |  |  |  |" }),
    t({ "", "| **Net Worth** |  |  |  |", "" }),
  }),

  s({ trig = ";financial-income", desc = "Financial: Income section" }, {
    t({ "## Income", "", "| Source | Amount | Notes |", "| ------ | ------ | ----- |" }),
    t({ "", "| Stipend / Salary |  |  |" }),
    t({ "", "| Side Income |  |  |" }),
    t({ "", "| Other |  |  |" }),
    t({ "", "| **Total** |  |  |", "" }),
  }),

  s({ trig = ";financial-expenses", desc = "Financial: Expenses Summary section" }, {
    t({ "## Expenses Summary", "", "| Category | Budgeted | Actual | Delta | Notes |", "| -------- | -------- | ------ | ----- | ----- |" }),
    t({ "", "| Housing |  |  |  |  |" }),
    t({ "", "| Transportation |  |  |  |  |" }),
    t({ "", "| Food / Groceries |  |  |  |  |" }),
    t({ "", "| Insurance |  |  |  |  |" }),
    t({ "", "| Subscriptions |  |  |  |  |" }),
    t({ "", "| Health |  |  |  |  |" }),
    t({ "", "| Personal |  |  |  |  |" }),
    t({ "", "| **Total** |  |  |  |  |", "" }),
  }),

  s({ trig = ";financial-goals", desc = "Financial: Goals Progress section" }, {
    t({ "## Goals Progress", "", "| Goal | Target | Current | On Track? |", "| ---- | ------ | ------- | --------- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t(" | "), i(4), t({ " |", "" }),
  }),

  s({ trig = ";financial-reflection", desc = "Financial: Reflection section" }, {
    t({ "## Reflection", "", "> [!tip] What went well? What needs to change next period?", "> " }), i(1),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- PROJECT DASHBOARD sections
  -- =========================================================================

  s({ trig = ";project-objective", desc = "Project: Objective section" }, {
    t({ "## Objective", "", '> [!abstract] What is the concrete deliverable and definition of "done"?', "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";project-focus", desc = "Project: Current Focus section" }, {
    t({ "## Current Focus", "", "> [!target] What am I working on right now?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";project-pipeline", desc = "Project: Pipeline Status section" }, {
    t({ "## Pipeline Status", "", "| Stage | Status | Next Action | Blocked By |", "| ----- | ------ | ----------- | ---------- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t(" | "), i(4), t({ " |", "" }),
  }),

  s({ trig = ";project-decisionlog", desc = "Project: Decision Log section" }, {
    t({ "## Decision Log", "", "> [!info] Key decisions and their rationale", "", "| Date | Decision | Rationale | Revisit? |", "| ---- | -------- | --------- | -------- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t(" | "), i(4), t({ " |", "" }),
  }),

  s({ trig = ";project-resources", desc = "Project: Key Resources section" }, {
    t({ "## Key Resources", "", "> [!info] Links to subfolders, key documents, external tools, repos", "" }),
    t({ "", "- **HPC path:** `" }), i(1), t("`"),
    t({ "", "- **Code repo:** `" }), i(2), t("`"),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- AREA DASHBOARD sections
  -- =========================================================================

  s({ trig = ";area-purpose", desc = "Area: Purpose section" }, {
    t({ "## Purpose", "", '> [!abstract] What standard am I maintaining? What does "healthy" look like for this area?', "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";area-status", desc = "Area: Current Status section" }, {
    t({ "## Current Status", "", "> [!target] How is this area doing right now? What needs attention?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";area-deadlines", desc = "Area: Upcoming Deadlines section" }, {
    t({ "## Upcoming Deadlines", "", "| Date | Item | Notes |", "| ---- | ---- | ----- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t({ " |", "" }),
  }),

  s({ trig = ";area-reviewchecklist", desc = "Area: Review Checklist section" }, {
    t({ "## Review Checklist", "", "> [!check] Run through this list at the review frequency", "" }),
    t({ "", "- [ ] Is the current status accurate?" }),
    t({ "", "- [ ] Are all recurring tasks up to date?" }),
    t({ "", "- [ ] Any upcoming deadlines I'm not tracking?" }),
    t({ "", "- [ ] Any active projects that should be created?" }),
    t({ "", "- [ ] Update `last_reviewed` in frontmatter", "" }),
  }),

  -- =========================================================================
  -- DOMAIN MOC sections
  -- =========================================================================

  s({ trig = ";domain-concepts", desc = "Domain MOC: Core Concepts section" }, {
    t({ "## Core Concepts", "", "> [!info] Foundational ideas and principles", "", "- [[" }), i(1), t("]]"),
    t({ "", "" }),
  }),

  s({ trig = ";domain-subdomains", desc = "Domain MOC: Sub-Domains section" }, {
    t({ "## Sub-Domains", "", "> Narrower areas within this domain", "", "- [[" }), i(1), t("]]"),
    t({ "", "" }),
  }),

  s({ trig = ";domain-openquestions", desc = "Domain MOC: Open Questions section" }, {
    t({ "## Open Questions", "", "> [!question] Big-picture questions that span individual projects", "", "1. " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";domain-emergingideas", desc = "Domain MOC: Emerging Ideas section" }, {
    t({ "## Emerging Ideas", "", "> [!tip] Ideas that haven't crystallized into concept notes yet", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";domain-resources", desc = "Domain MOC: Resources section" }, {
    t({ "## Resources", "", "> External links, textbooks, course materials, reference documents", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";domain-timeline", desc = "Domain MOC: Timeline / Milestones section" }, {
    t({ "## Timeline / Milestones", "", "> [!calendar] Significant events in your engagement with this domain", "", "| Date | Event |", "| ---- | ----- |", "| " }), i(1), t(" | "), i(2), t({ " |", "" }),
  }),

  -- =========================================================================
  -- PERSON sections
  -- =========================================================================

  s({ trig = ";person-context", desc = "Person: Context section" }, {
    t({ "## Context", "", "> [!info] How do I know this person? What's the working relationship?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";person-feedback", desc = "Person: Feedback Patterns section" }, {
    t({ "## Feedback Patterns", "", "> [!tip] Recurring themes in their feedback", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";person-preferences", desc = "Person: Preferences & Communication Style section" }, {
    t({ "## Preferences & Communication Style", "", "> How do they prefer to work? What do they care about most?", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";person-conversations", desc = "Person: Key Conversations & Decisions section" }, {
    t({ "## Key Conversations & Decisions", "", "| Date | Topic | Outcome |", "| ---- | ----- | ------- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t({ " |", "" }),
  }),

  -- =========================================================================
  -- ASSET sections
  -- =========================================================================

  s({ trig = ";asset-details", desc = "Asset: Key Details section" }, {
    t({ "## Key Details", "", "> [!info] Core reference information for this asset", "", "| Field | Value |", "| ----- | ----- |" }),
    t({ "", "| Make / Type | " }), i(1), t(" |"),
    t({ "", "| Model / Description | " }), i(2), t(" |"),
    t({ "", "| Year | " }), i(3), t(" |"),
    t({ "", "| Serial # / VIN / Account # | " }), i(4), t(" |"),
    t({ "", "| Location / Institution | " }), i(5), t(" |"),
    t({ "", "| Contact / Agent | " }), i(6), t({ " |", "" }),
  }),

  s({ trig = ";asset-documents", desc = "Asset: Documents section" }, {
    t({ "## Documents", "", "> [!note] Where are the important documents stored?", "", "| Document | Location | Expiration |", "| -------- | -------- | ---------- |" }),
    t({ "", "| Title / Deed |  |  |" }),
    t({ "", "| Registration |  |  |" }),
    t({ "", "| Warranty |  |  |" }),
    t({ "", "| Insurance Policy |  |  |" }),
    t({ "", "| Manual |  |  |", "" }),
  }),

  s({ trig = ";asset-servicehistory", desc = "Asset: Service / Transaction History section" }, {
    t({ "## Service / Transaction History", "", "| Date | Description | Cost | Provider | Notes |", "| ---- | ----------- | ---- | -------- | ----- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t(" | "), i(4), t(" | "), i(5), t({ " |", "" }),
  }),

  s({ trig = ";asset-upcoming", desc = "Asset: Upcoming section" }, {
    t({ "## Upcoming", "", "| Date | Action Needed | Notes |", "| ---- | ------------- | ----- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t({ " |", "" }),
  }),

  -- =========================================================================
  -- WEEKLY REVIEW sections
  -- =========================================================================

  s({ trig = ";weekly-accomplishments", desc = "Weekly: Research Accomplishments section" }, {
    t({ "## Research Accomplishments", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";weekly-personal", desc = "Weekly: Personal / Life Accomplishments section" }, {
    t({ "## Personal / Life Accomplishments", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";weekly-progress", desc = "Weekly: Progress by Project section" }, {
    t({ "## Progress by Project", "", "| Project | Category | What Moved Forward | What Stalled |", "| ------- | -------- | ------------------ | ------------ |", "| [[" }), i(1), t("]] | "), i(2), t(" | "), i(3), t(" | "), i(4), t({ " |", "" }),
  }),

  s({ trig = ";weekly-areas", desc = "Weekly: Areas Check-In section" }, {
    t({ "## Areas Check-In", "", "> [!check] Quick health check on each life area", "", "| Area | Status | Action Needed? |", "| ---- | ------ | -------------- |" }),
    t({ "", "| [[Finance]] |  |  |" }),
    t({ "", "| [[Health & Fitness]] |  |  |" }),
    t({ "", "| [[Career]] |  |  |", "" }),
  }),

  s({ trig = ";weekly-insights", desc = "Weekly: Key Insights section" }, {
    t({ "## Key Insights", "", "> [!tip] Ideas, patterns, or connections that emerged this week", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";weekly-didntwork", desc = "Weekly: What Didn't Work section" }, {
    t({ "## What Didn't Work", "", "> [!warning] Blockers, dead ends, or wasted effort", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";weekly-maintenance", desc = "Weekly: Vault Maintenance section" }, {
    t({ "## Vault Maintenance", "" }),
    t({ "", "- [ ] Process any items in Home quick capture inbox" }),
    t({ "", "- [ ] Review stale project warnings on Home dashboard" }),
    t({ "", "- [ ] Promote any reusable notes out of project folders" }),
    t({ "", "- [ ] Update methodology notes if methods evolved this week" }),
    t({ "", "- [ ] File any loose literature notes into Library" }),
    t({ "", "- [ ] Update `next_due` on any completed recurring tasks", "" }),
  }),

  s({ trig = ";weekly-nextweek", desc = "Weekly: Next Week's Priorities section" }, {
    t({ "## Next Week's Priorities", "", "### Research", "1. " }), i(1),
    t({ "", "", "### Personal", "1. " }), i(2),
    t({ "", "", "### Life Admin", "1. " }), i(3),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- MONTHLY / QUARTERLY / YEARLY REVIEW sections (shared patterns)
  -- =========================================================================

  s({ trig = ";monthly-summary", desc = "Monthly: Summary section" }, {
    t({ "## Monthly Summary", "", "> [!note] High-level summary of the month", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";monthly-goals", desc = "Monthly: Goals for Next Month section" }, {
    t({ "## Goals for Next Month", "", "### Research", "1. " }), i(1),
    t({ "", "", "### Personal", "1. " }), i(2),
    t({ "", "", "### Life Admin", "1. " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";quarterly-overview", desc = "Quarterly: Overview section" }, {
    t({ "## Quarter Overview", "", "> [!note] High-level narrative of the quarter", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";quarterly-strategic", desc = "Quarterly: Strategic Assessment section" }, {
    t({ "## Strategic Assessment", "", "> [!info] Are you heading in the right direction? What needs to shift?", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";quarterly-okr", desc = "Quarterly: OKR / Goal Progress section" }, {
    t({ "## OKR / Goal Progress", "", "> [!check] Rate progress on each goal: 1 (no progress) to 5 (exceeded)", "", "| Goal | Rating (1-5) | Evidence | Notes |", "| ---- | ------------ | -------- | ----- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t(" | "), i(4), t({ " |", "" }),
  }),

  s({ trig = ";quarterly-wins", desc = "Quarterly: Key Wins section" }, {
    t({ "## Key Wins", "", "> [!tip] The biggest accomplishments of the quarter", "", "1. " }), i(1),
    t({ "", "2. " }), i(2),
    t({ "", "3. " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";quarterly-challenges", desc = "Quarterly: Key Challenges section" }, {
    t({ "## Key Challenges", "", "> [!warning] Biggest obstacles, setbacks, or frustrations", "", "1. " }), i(1),
    t({ "", "2. " }), i(2),
    t({ "", "3. " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";quarterly-lessons", desc = "Quarterly: Lessons Learned section" }, {
    t({ "## Lessons Learned", "", "> [!info] What did this quarter teach you?", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";yearly-overview", desc = "Yearly: Year Overview section" }, {
    t({ "## Year Overview", "", "> [!note] The year in one paragraph", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";yearly-accomplishments", desc = "Yearly: Major Accomplishments section" }, {
    t({ "## Major Accomplishments", "" }),
    t({ "", "### Research", "", "> [!tip] Papers, grants, experiments, discoveries, milestones", "", "1. " }), i(1),
    t({ "", "", "### Personal", "", "> [!tip] Skills, relationships, habits, growth", "", "1. " }), i(2),
    t({ "", "", "### Life", "", "> [!tip] Major life events, purchases, moves, milestones", "", "1. " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";yearly-lessons", desc = "Yearly: Biggest Lessons section" }, {
    t({ "## Biggest Lessons", "", "> [!info] What did this year teach you?", "", "1. " }), i(1),
    t({ "", "2. " }), i(2),
    t({ "", "3. " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";yearly-surprises", desc = "Yearly: Biggest Surprises section" }, {
    t({ "## Biggest Surprises", "", "> [!info] What caught you off guard?", "", "1. " }), i(1),
    t({ "", "2. " }), i(2),
    t({ "", "3. " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";yearly-different", desc = "Yearly: What I'd Do Differently section" }, {
    t({ "## What I'd Do Differently", "", "> [!warning] Hindsight is 20/20", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";yearly-theme", desc = "Yearly: Theme / Word for Next Year section" }, {
    t({ "## Theme / Word for Next Year", "", "> [!target] A single word or phrase to anchor the year ahead", "", "- " }), i(1),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- Generic reusable sections (appear in many templates)
  -- =========================================================================

  s({ trig = ";section-notes", desc = "Generic: Notes section" }, {
    t({ "## Notes", "", "" }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";section-openquestions", desc = "Generic: Open Questions section" }, {
    t({ "## Open Questions", "", "- [ ] " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";section-actionitems", desc = "Generic: Action Items section" }, {
    t({ "## Action Items", "", "- [ ] " }), i(1),
    t({ "", "- [ ] " }), i(2),
    t({ "", "" }),
  }),

  s({ trig = ";section-decisionlog", desc = "Generic: Decision Log section" }, {
    t({ "## Decision Log", "", "| Date | Decision | Rationale |", "| ---- | -------- | --------- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t({ " |", "" }),
  }),

  s({ trig = ";section-feedsinto", desc = "Generic: Feeds Into section" }, {
    t({ "## Feeds Into", "", "- **Draft:** [[" }), i(1), t("]]"),
    t({ "", "- **Analysis:** [[" }), i(2), t("]]"),
    t({ "", "- **Presentation:** [[" }), i(3), t("]]"),
    t({ "", "" }),
  }),

  s({ trig = ";section-log", desc = "Generic: Log section with date entry" }, {
    t("## Log"),
    t({ "", "", "### " }), i(1, "YYYY-MM-DD"),
    t({ "", "- " }), i(2, "Entry"),
    t({ "", "" }),
  }),
```

### E.3 Template Section Snippet Summary

| Template | Snippet Count | Trigger Prefix |
|----------|--------------|----------------|
| daily_log | 8 | `;dailylog-` |
| task | 5 | `;task-` |
| meeting | 6 | `;meeting-` |
| concept | 7 | `;concept-` |
| literature | 9 | `;literature-` |
| methodology | 8 | `;methodology-` |
| simulation | 9 | `;simulation-` |
| analysis | 8 | `;analysis-` |
| finding | 6 | `;finding-` |
| changelog | 4 | `;changelog-` |
| presentation | 5 | `;presentation-` |
| draft | 4 | `;draft-` |
| journal | 4 | `;journal-` |
| recurring_task | 3 | `;recurring-` |
| financial_snapshot | 5 | `;financial-` |
| project_dashboard | 5 | `;project-` |
| area_dashboard | 4 | `;area-` |
| domain_moc | 6 | `;domain-` |
| person | 4 | `;person-` |
| asset | 4 | `;asset-` |
| weekly_review | 8 | `;weekly-` |
| monthly_review | 2 | `;monthly-` |
| quarterly_review | 7 | `;quarterly-` |
| yearly_review | 5 | `;yearly-` |
| Generic (shared) | 6 | `;section-` |

**Total template section snippets: ~136**

---

## Implementation Summary

| Section | Snippet Count | Where to Add |
|---------|--------------|--------------|
| A. Meeting Notes Template | 2 | `luasnippets/markdown.lua` snippets table |
| B. Research Article Template | 2 | `luasnippets/markdown.lua` snippets table |
| C. Nested/Meta Callouts | 12 | `luasnippets/markdown.lua` snippets table |
| D. LaTeX Readable Names | ~317 | `lua/andrew/utils/tex.lua` autosnippets table |
| E. Template Sections | ~136 | `luasnippets/markdown.lua` snippets table |
| **Grand Total** | **~469 new snippets** | |

### Implementation Order

1. **Section D first** -- edit `lua/andrew/utils/tex.lua`, append readable-name block before closing `}`
2. **Sections A, B, C, E** -- edit `luasnippets/markdown.lua`, add all snippets to the `local snippets = { ... }` table before the closing `}`
3. **Reload** -- `:LuaSnipUnlinkCurrent` then `:source %` or restart Neovim
4. **Test** -- verify in a markdown file that `;meeting-agenda`, `;alpha`, `;nabla`, etc. all expand correctly
