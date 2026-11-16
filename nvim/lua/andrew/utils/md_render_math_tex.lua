-- =============================================================================
-- md-render math: TeX -> cell-exact coverage masks (pdfTeX + MuPDF)
-- =============================================================================
-- md-render v3.11.2 shows the TeX of `$...$` and `$$...$$` as coloured raw
-- text. This module makes the pictures the rendered view shows instead; it
-- wraps no md-render function and knows nothing of buffers, terminals or
-- colours. Its caller (md_render_math.lua) asks with `lookup` on every rebuild
-- and with `request` for what is missing; md_render_math_kitty.lua tints a
-- mask with the view's colour when it sends it to the terminal.
--
-- What a picture is (Contract v2): a PNG, 8-bit greyscale (colour type 0), no
-- interlace, exactly `columns*cell_width` by `rows*cell_height` pixels, black
-- ink on white as `mutool draw -c gray` draws it (value v = coverage
-- (255 - v) / 255). After its IEND chunk it carries one record,
-- "\nmdmath <columns> <rows> <scale>\n", so that one file and one rename make
-- a picture. The colour is in neither the file nor any key: a colour scheme
-- change costs no TeX run (PipelineExperiments #3: re-making 150 pictures took
-- 280-330 ms, tinting a mask costs 0.3 us; a tinted mask is within 3/255 of
-- the old coloured picture).
--
-- How a picture is made:
--
--   * One `pdftex` run per batch, with a format dumped from the template below
--     AFTER `\begin{document}` with the math fonts loaded, and stored
--     gunzipped (a gzipped format costs ~50 ms a run to load).
--   * The run is usually started before it is needed, see "The standby"
--     below: ~33 ms of its ~45 ms are start-up (kpathsea, 19 MB format) that
--     then happen while nobody waits.
--   * `mutool draw` over the pages that came out right, split over several
--     processes started by ONE shell when there are many pages: the 0.2 bp
--     stroke makes a page ~1 ms of MuPDF (19 ms for 150 pages unstroked, 133
--     stroked), so 150 pages take 190 ms on one core and ~50 on six. One shell,
--     because each start of a process forks Neovim, 2-3 ms of its main thread
--     in the full config. Pages are settled chunk by chunk as the shell
--     reports each mutool's end, the first (smallest) chunk first.
--   * The PDF page IS the cell box: an inline picture is one cell row with the
--     TeX baseline on the terminal font's baseline pixel row, a display
--     picture whole rows. Nothing is cropped or measured afterwards.
--   * What happens to finished pages (check the PNG header, append the
--     record, rename into the cache) runs on a libuv worker thread, not on
--     Neovim's main thread (10-12 ms per 150 pictures there before).
--
-- The standby: a pdfTeX started ahead of need, used for exactly one batch
-- (one batch, so no TeX state ever passes from one batch to another). Why
-- each measure exists:
--
--   * Its `job.tex` is a FIFO (`mkfifo` through LuaJIT's FFI; `vim.uv` has
--     none), not a link to stdin: libuv gives a child a socketpair as stdin,
--     which /dev/stdin cannot open, and pdfTeX died at once.
--   * `-no-parse-first-line`: otherwise pdfTeX reads job.tex's first line
--     before it loads the format, and blocks there.
--   * Parked, pdfTeX waits in `open(job.tex)` for a writer. Neovim opens the
--     write end only when a batch takes the standby, WITHOUT blocking: that
--     fails (ENXIO) while pdfTeX still loads its format, and is then retried
--     every 2 ms until it opens. A blocking open would sit on a thread of
--     libuv's pool, and one that never returns (pdfTeX killed first, its
--     directory removed) kept Neovim from ever exiting: 8 of 10 `:qa` moments
--     during a session's first request hung (review). Polling from the spawn
--     on instead, to hold the write end from "ready" on, cost ~20 opens of
--     ~30 us on the main thread per standby, inside every batch (the next
--     standby loads while it runs). Any other error than ENXIO (the cache
--     was cleared under it) ends the standby at once: the batch runs again
--     instead of waiting out the time limit (2032 ms before).
--   * Nothing of Neovim's holds the FIFO, so Neovim's death does not end a
--     parked pdfTeX: it would wait in `open` for good (38 MB, no CPU, so
--     `ulimit -t` never ends it; for ever once the cache is removed). So it
--     runs under `setpriv --pdeathsig KILL`, and WITHOUT `setpriv` there is
--     no standby: every batch is a plain spawn (~35 ms more; `status()`
--     says why). Maintenance also opens the FIFO's write end in every run
--     directory whose Neovim is gone, which ends what outlived its Neovim.
--     Limit: "gone" is `kill(pid, 0)` in the maintainer's pid namespace; a
--     container sharing the cache sees another session's live standby as a
--     leftover and ends it (that session then runs plain spawns).
--   * `VimLeavePre` sets `is_leaving`: exit callbacks still arrive after it,
--     and are dropped (nothing may be started then: a standby started
--     during the exit kept Neovim waiting; and a reason made of that kill
--     would be a false warning).
--   * The wall-clock limit counts from when the job is written, not from the
--     spawn; the CPU limit (`ulimit -t`) costs an idle standby nothing.
--   * It is started only when something is missing (a `lookup` that found
--     nothing, a `request`), again right after one is used, and stopped after
--     STANDBY_IDLE_MILLISECONDS without either: 38 MB must not stay for a
--     session that left its notes, or start in one that never had math.
--     Noting that is one boolean in `lookup`.
--   * Anything wrong with it (no FFI, mkfifo fails, it died before reading
--     the job, it is built on a format since replaced) and the batch runs as
--     a plain spawn; a standby that died by itself turns standbys off for the
--     session (`retry` turns them on).
--
-- TeX runs note content. Sandboxed: `-no-shell-escape` (also for the format
-- build, which reads the user's preamble); `openin_any=p` and `openout_any=p`
-- (no reads or writes outside the job directory and the texmf trees,
-- `TEXMFOUTPUT` cleared because `p` lets TeX write there too); every
-- `MKTEX*=0`, because a missing format or font otherwise runs kpathsea's
-- mktexfmt/mktextfm, which create `~/.texlive<year>/texmf-var/...`. Every run
-- has a wall-clock limit (2 s: a batch of 150 takes ~80 ms, and one runaway
-- equation must not hold 149 others for long), a CPU limit of its own and a
-- cap on what it may print on stdout AND stderr (`\openin` of a forbidden
-- path prints to stderr each time: 109 MB in 5 s, 217 MB of Lua heap before
-- the cap). Its `job.log` goes to /dev/null.
--
-- Equations share a run, so one could leave something behind for the next
-- (`\gdef`, a `\catcode`, an extra page). An equation whose TeX can reach past
-- its own group runs alone instead (`ISOLATING_COMMANDS`, the job file's own
-- macros among them), and a run whose PDF has another number of pages than
-- it reported is not trusted. What a run prints is read defensively (a forged
-- `MDMATH BEGIN` names no item; any error in a callback abandons that run's
-- items instead of leaving them waiting). A run that dies at the end with
-- nobody to blame (pdfTeX finds a font without a Type 1 file only when it
-- closes the PDF) is split in halves until the culprit is alone: no innocent
-- equation fails. Definitions never carry from one equation to another; the
-- user preamble (`vim.g.md_render_math_preamble`) is the place for them. A
-- changed preamble (read by `setup` and `retry`) is another format and
-- another key for every picture; what was remembered or queued under the old
-- one is dropped or keyed anew (`template_generation`).
--
-- Two kinds of "no picture": `false` = this TeX does not compile, is too
-- large or ran away (`failure_of` says why: TeX's first error line); `nil`
-- with `is_available()` false = it could not be RUN (read-only cache, pdftex
-- gone, the format would not build). `retry()` forgets both. A cache
-- directory removed under a running session is not such a failure: every
-- batch makes its directories again, and a batch whose run directory went
-- away runs once more.
--
-- The disk: pictures in `masks/`, job and format-build directories in `run/`,
-- the format in the cache directory itself. A while after first use and on a
-- worker thread, maintenance touches the pictures this session read (`/home`
-- is mounted noatime, so mtime is the age) and deletes files of older
-- layouts, stale run directories and formats of other templates unused for a
-- day; once a session it also deletes the oldest pictures beyond
-- DISK_BUDGET_BYTES, never one younger than a day.
--
-- Pinned by tests/md_render_math_tex_spec.lua. Drop this file when md-render
-- renders math itself.

local M = {}

-- The three types the math modules pass to each other, defined here because
-- this module is what makes a picture from an equation and a look.

---@class MdRenderMathEquation
---@field kind "inline"|"display"
---@field tex string

---@class MdRenderMathLook
---@field cell_width integer pixels
---@field cell_height integer pixels

---@class MdRenderMathPicture
---@field path string absolute path of the mask: 8-bit grey PNG, ink = 255 - value
---@field columns integer cells
---@field rows integer cells
---@field scale number 1, or less for an inline equation shrunk to fit its row

-- -----------------------------------------------------------------------------
-- Sizing
-- -----------------------------------------------------------------------------

--- JetBrainsMono Nerd Font (hhea: ascent 1020, descent -300, gap 0, upm 1000):
--- the cell is 1.32 em high and the baseline 1.02 em below its top.
local FONT_LINE_HEIGHT_EM = 1.32
local FONT_ASCENDER_EM = 1.02
--- The template typesets at 10 TeX points.
local TEX_DESIGN_SIZE_BP = 10 * 72 / 72.27
--- TeX em / terminal em. 1.07 matches cap heights; 1.15 with the hairline
--- stroke below matches the terminal font's weight better.
local GLYPH_SCALE = 1.15
--- Fill + stroke of this width in bp: Computer Modern next to JetBrainsMono
--- looks too light without it. It is also most of MuPDF's time (see above);
--- drawing offset copies instead was measured and does not look the same.
local STROKE_BP = 0.2
--- Free space above and below a display picture, as a share of the cell height.
local DISPLAY_PADDING_FRACTION = 0.09

--- Pages larger than this are failures, not pictures: `\rule{1000cm}{1000cm}`
--- would otherwise make MuPDF draw a picture of gigabytes.
local MAXIMUM_COLUMNS = 300
local MAXIMUM_ROWS = 40

-- -----------------------------------------------------------------------------
-- Limits
-- -----------------------------------------------------------------------------

--- Equations per pdftex run.
local MAXIMUM_BATCH = 150
--- A run longer than this is killed (`\def\x{\x}\x` never ends). A batch of
--- 150 takes ~80 ms, the slowest seen under load ~115 ms.
local TIMEOUT_MILLISECONDS = 2000
--- TIMEOUT_MILLISECONDS, or what `setup` was given (the spec).
local timeout_milliseconds = TIMEOUT_MILLISECONDS
local FORMAT_BUILD_TIMEOUT_MILLISECONDS = 60000
--- CPU seconds a TeX run may use, enforced by the kernel (`ulimit -t`): the
--- wall-clock limits above live in Neovim and die with it.
local CPU_LIMIT_SECONDS = 15
local FORMAT_BUILD_CPU_LIMIT_SECONDS = 120
--- A run that prints more than this, on stdout and stderr together, is
--- killed: `\def\x{\message{..}\x}\x` prints 150 MB in 5 s. A batch of 150
--- prints ~50 kB.
local MAXIMUM_OUTPUT_BYTES = 1024 * 1024
--- Of stderr only the start is kept, for an error message.
local KEPT_STDERR_BYTES = 8192
--- Run directories a crashed session left behind are removed after this long.
local STALE_DIRECTORY_SECONDS = 3600

--- A standby nobody needed for this long is stopped (it holds 38 MB).
local STANDBY_IDLE_MILLISECONDS = 120000

--- mutool processes of one batch: start-up ~4-6 ms, a stroked page ~1 ms.
--- The first chunk is small so that what was asked for first settles first.
local FIRST_RASTER_CHUNK = 16
local MINIMUM_RASTER_CHUNK = 8
local MAXIMUM_RASTER_PROCESSES = math.max(1, math.min(6, (vim.uv.available_parallelism() or 2) - 1))

--- Maintenance runs this long after the first lookup of a session, so that
--- it never competes with the first pictures.
local MAINTENANCE_DELAY_MILLISECONDS = 10000
--- Bytes on disk (allocated) the pictures may take. A mask is ~1 kB in a
--- 4 kB block: ~8000 pictures.
local DISK_BUDGET_BYTES = 32 * 1024 * 1024
--- Never pruned when younger: a session that showed it may still send it.
local PRUNE_MINIMUM_AGE_SECONDS = 86400

--- `is_absent_on_disk` is emptied at this many entries: typing inside an
--- equation adds one per keystroke, and a miss costs one failed open to find
--- again.
local ABSENT_LIMIT = 256
--- Pictures remembered per generation; two generations are kept (one picture
--- entry is ~376 B: at most ~1.5 MB). A note whose working set is up to this
--- many pictures never reads them from disk again; with one bound of 1024
--- that dropped everything, a working set of 1500 cost 1500 opens and 16-21
--- ms per build. Larger working sets read the overflow from disk (~10 us
--- each).
local REMEMBERED_PICTURE_LIMIT = 2048
--- Disk hits remembered for maintenance to touch.
local USED_PATH_LIMIT = 4096

--- The record after IEND, "\nmdmath <columns> <rows> <scale>\n".
local RECORD_PATTERN = "\nmdmath (%d+) (%d+) ([%d.]+)\n$"
local RECORD_READ_BYTES = 48

-- -----------------------------------------------------------------------------
-- The template
-- -----------------------------------------------------------------------------

local TEMPLATE_VERSION = 5
--- Part of every key: a new layout is simply not found, and maintenance
--- removes the files of the old one.
local CACHE_LAYOUT = "mask1"

--- Precompiled into the format. Job file protocol (one page per equation):
---   \mdsetup{<pixel in bp>}{<cell w px>}{<cell h px>}{<baseline px from cell top>}
---   \mdstroke{<bp>}  \mdpad{<px above and below a display picture>}
---   \mdi{<id>}%  <newline> inline TeX  <newline> \mde
---   \mdd{<id>}%  <newline> display TeX <newline> \mdde
---   \mdfinish
--- Output protocol, on stdout, one line each:
---   MDMATH BEGIN <id>     (stdout is flushed right after it: `\message{}`)
---   MDMATH PAGE <id> cols=.. rows=.. wd=.. ht=.. dp=.. scale=.. shift=..
---   MDMATH DIRTY <id>     <id> left TeX in a damaged state (it failed); the run stops
---   MDMATH SKIP <id>      <id> began in a damaged state: run it again
---   MDMATH DONE
--- An inline equation taller than a cell is shrunk to fit it, however much:
--- whether the result is still legible is the caller's call (`scale`).
local TEX_PREAMBLE = [==[
\documentclass[10pt]{article}
\usepackage{amsmath,amssymb,amsfonts,amscd,mathtools,xcolor,graphicx}
\usepackage{cancel,bm,mathrsfs}
\nofiles
\pagestyle{empty}
\makeatletter
\newbox\md@box
\newdimen\md@px \newdimen\md@cw \newdimen\md@ch \newdimen\md@A \newdimen\md@D
\newdimen\md@W \newdimen\md@H \newdimen\md@nh \newdimen\md@nd \newdimen\md@nw
\newdimen\md@shift \newdimen\md@eps \newdimen\md@s \newdimen\md@pad
\newcount\md@cols \newcount\md@rows \newcount\md@id
\def\md@scale{1}
\def\md@on{}\def\md@off{}
\def\mdsetup#1#2#3#4{%
  \md@px=#1bp \md@cw=#2\md@px \md@ch=#3\md@px
  \md@A=#4\md@px \md@D=\dimexpr\md@ch-\md@A\relax
  \md@eps=.25\md@px}
\def\mdstroke#1{\ifdim#1pt>\z@ \def\md@on{\pdfliteral direct{2 Tr #1 w}}\def\md@off{\pdfliteral direct{0 Tr 0 w}}%
  \else \def\md@on{}\def\md@off{}\fi}
\def\mdpad#1{\md@pad=#1\md@px }
\outer\def\mdi#1{\md@begin{#1}%
  \setbox\md@box\hbox\bgroup\let\par\relax\md@on$}
\outer\def\mde{$\md@off\egroup\md@shipinline\md@check}
\outer\def\mdd#1{\md@begin{#1}%
  \setbox\md@box\hbox\bgroup\let\par\relax\md@on$\displaystyle}
\outer\def\mdde{$\md@off\egroup\md@shipdisplay\md@check}
\outer\def\mdfinish{\immediate\write16{MDMATH DONE}\@@end}
\newif\ifmd@clean
\def\md@test{\md@cleanfalse \ifnum\currentgrouplevel=\z@ \ifvmode\ifinner\else\md@cleantrue\fi\fi\fi}
\def\md@begin#1{\global\md@id=#1\relax \immediate\write16{MDMATH BEGIN #1}\message{}%
  \md@test \ifmd@clean\else \immediate\write16{MDMATH SKIP #1}\expandafter\@@end\fi}
\def\md@check{\md@test \ifmd@clean\else \immediate\write16{MDMATH DIRTY \number\md@id}\expandafter\@@end\fi}
\def\md@ceil#1#2#3#4{%
  #3=0 #4=\z@
  \loop\ifdim#4<#1 \advance#4 #2 \advance#3 \@ne \repeat
  \ifnum#3=0 #3=\@ne #4=#2 \fi}
\def\md@shipinline{%
  \md@nw=\wd\md@box \md@nh=\ht\md@box \md@nd=\dp\md@box
  \md@rows=\@ne \md@H=\md@ch \md@shift=\z@ \def\md@scale{1}%
  \ifdim\dimexpr\md@nh+\md@nd\relax>\md@ch
    \md@s=\dimexpr 1pt*\number\md@ch/\number\dimexpr\md@nh+\md@nd\relax\relax
    \edef\md@scale{\strip@pt\md@s}%
    \setbox\md@box\hbox{\scalebox{\md@scale}{\box\md@box}}%
  \fi
  \ifdim\ht\md@box>\dimexpr\md@H-\md@D\relax
    \md@shift=\dimexpr\md@H-\md@D-\ht\md@box\relax
  \else\ifdim\dp\md@box>\md@D
    \md@shift=\dimexpr\dp\md@box-\md@D\relax
    \ifdim\dimexpr\ht\md@box+\md@shift\relax>\dimexpr\md@H-\md@D\relax
      \md@shift=\dimexpr\md@H-\md@D-\ht\md@box\relax
    \fi
  \fi\fi
  \md@ceil{\wd\md@box}{\md@cw}{\md@cols}{\md@W}%
  \setbox\md@box\hbox to\md@W{\hss\raise\md@shift\box\md@box\hss}%
  \ht\md@box=\dimexpr\md@H-\md@D\relax \dp\md@box=\md@D
  \md@ship}
\def\md@shipdisplay{%
  \md@nw=\wd\md@box \md@nh=\ht\md@box \md@nd=\dp\md@box
  \md@shift=\z@ \def\md@scale{1}%
  \md@ceil{\dimexpr\md@nh+\md@nd+\tw@\md@pad\relax}{\md@ch}{\md@rows}{\md@H}%
  \md@ceil{\md@nw}{\md@cw}{\md@cols}{\md@W}%
  \setbox\md@box\vbox to\md@H{\vss\hbox to\md@W{\box\md@box\hss}\vss}%
  \md@ship}
\def\md@ship{%
  \immediate\write16{MDMATH PAGE \number\md@id\space cols=\number\md@cols\space rows=\number\md@rows\space
    wd=\the\md@nw\space ht=\the\md@nh\space dp=\the\md@nd\space scale=\md@scale\space shift=\the\md@shift}%
  \pdfpagewidth=\dimexpr\md@W-\md@eps\relax
  \pdfpageheight=\dimexpr\ht\md@box+\dp\md@box-\md@eps\relax
  \pdfhorigin=\z@ \pdfvorigin=\z@ \hoffset=\z@ \voffset=\z@
  \csname tex_shipout:D\endcsname\vbox{\box\md@box}}
\def\md@warm{\setbox\md@box\hbox{$a^{b^c}\mathbf{x^{y^z}}\mathrm{x^{y^z}}\mathcal{A}\mathbb{R^{R^R}}\mathit{x}\mathsf{x}\mathtt{x}
  \text{x}\sum\int\sqrt{\frac12}\left(\begin{pmatrix}1\end{pmatrix}\right)\lesssim\boldsymbol{\alpha}$}\setbox\md@box\box\voidb@x}
\def\md@alias#1#2{\expandafter\let\csname #1\expandafter\endcsname\csname #2\endcsname
  \expandafter\let\csname end#1\expandafter\endcsname\csname end#2\endcsname}
\md@alias{align}{aligned}\md@alias{align*}{aligned}
\md@alias{flalign}{aligned}\md@alias{flalign*}{aligned}
\md@alias{gather}{gathered}\md@alias{gather*}{gathered}
\md@alias{alignat}{alignedat}\md@alias{alignat*}{alignedat}
\md@alias{split}{aligned}
\md@alias{multline}{multlined}\md@alias{multline*}{multlined}
\renewenvironment{equation}{}{}\renewenvironment{equation*}{}{}
\renewenvironment{subequations}{}{}
\renewenvironment{eqnarray}{\begin{array}{@{}r@{\;}c@{\;}l@{}}}{\end{array}}
\renewenvironment{eqnarray*}{\begin{array}{@{}r@{\;}c@{\;}l@{}}}{\end{array}}
\def\dft@tag{\@ifstar\md@tagstar\md@tag}\let\tag\dft@tag
\def\md@tag#1{\qquad\text{(#1)}}\def\md@tagstar#1{\qquad\text{#1}}
\def\intertext#1{\noalign{\hbox{\normalfont #1}}}
\tracinglostchars=3
\def\@inmathwarn#1{\ifmmode\@latex@error{Command \protect#1 invalid in math mode}\@ehc\fi}
\let\md@AA\AA \DeclareRobustCommand\AA{\ifmmode\mathrm{\mathring{A}}\else\md@AA\fi}
\DeclareFontFamily{TS1}{cmr}{\hyphenchar\font\m@ne}
\DeclareFontShape{TS1}{cmr}{m}{n}{<-> ts1-lmr10}{}
\DeclareFontShape{TS1}{cmr}{m}{it}{<-> ts1-lmri10}{}
\DeclareFontShape{TS1}{cmr}{m}{sl}{<-> ts1-lmro10}{}
\DeclareFontShape{TS1}{cmr}{bx}{n}{<-> ts1-lmbx10}{}
\DeclareFontShape{TS1}{cmr}{bx}{it}{<-> ts1-lmbxi10}{}
\DeclareFontShape{TS1}{cmr}{b}{n}{<-> ssub * cmr/bx/n}{}
\def\md@u#1#2{\DeclareUnicodeCharacter{#1}{\ifmmode #2\else \ensuremath{#2}\fi}}
\def\md@ut#1#2#3{\DeclareUnicodeCharacter{#1}{\ifmmode #2\else #3\fi}}
\md@u{03B1}{\alpha}\md@u{03B2}{\beta}\md@u{03B3}{\gamma}\md@u{03B4}{\delta}
\md@u{03B5}{\varepsilon}\md@u{03F5}{\epsilon}\md@u{03B6}{\zeta}\md@u{03B7}{\eta}
\md@u{03B8}{\theta}\md@u{03D1}{\vartheta}\md@u{03B9}{\iota}\md@u{03BA}{\kappa}
\md@u{03BB}{\lambda}\md@u{03BC}{\mu}\md@ut{00B5}{\mu}{\textmu}\md@u{03BD}{\nu}
\md@u{03BE}{\xi}\md@u{03C0}{\pi}\md@u{03C1}{\rho}\md@u{03F1}{\varrho}
\md@u{03C3}{\sigma}\md@u{03C2}{\varsigma}\md@u{03C4}{\tau}\md@u{03C5}{\upsilon}
\md@u{03C6}{\varphi}\md@u{03D5}{\phi}\md@u{03C7}{\chi}\md@u{03C8}{\psi}
\md@u{03C9}{\omega}\md@u{0393}{\Gamma}\md@u{0394}{\Delta}\md@u{0398}{\Theta}
\md@u{039B}{\Lambda}\md@u{039E}{\Xi}\md@u{03A0}{\Pi}\md@u{03A3}{\Sigma}
\md@u{03A5}{\Upsilon}\md@u{03A6}{\Phi}\md@u{03A8}{\Psi}\md@u{03A9}{\Omega}
\md@ut{2126}{\Omega}{\textohm}\md@ut{00D7}{\times}{\texttimes}\md@ut{00F7}{\div}{\textdiv}
\md@ut{00B1}{\pm}{\textpm}\md@ut{00B7}{\cdot}{\textperiodcentered}\md@ut{00B0}{^\circ}{\textdegree}
\md@ut{00AC}{\neg}{\textlnot}\md@ut{00B2}{^2}{\texttwosuperior}\md@ut{00B3}{^3}{\textthreesuperior}
\md@ut{00B9}{^1}{\textonesuperior}\md@ut{2212}{-}{\textminus}\md@u{2213}{\mp}
\md@u{2215}{/}\md@u{2217}{\ast}\md@u{2218}{\circ}\md@u{2219}{\bullet}\md@u{22C5}{\cdot}
\md@u{221A}{\surd}\md@u{221D}{\propto}\md@u{221E}{\infty}\md@u{2202}{\partial}
\md@u{2207}{\nabla}\md@u{2206}{\Delta}\md@u{2211}{\sum}\md@u{220F}{\prod}\md@u{222B}{\int}
\md@u{222C}{\iint}\md@u{222D}{\iiint}\md@u{222E}{\oint}\md@u{2264}{\le}\md@u{2265}{\ge}
\md@u{2260}{\ne}\md@u{2248}{\approx}\md@u{2243}{\simeq}\md@u{2245}{\cong}\md@u{2261}{\equiv}
\md@u{223C}{\sim}\md@u{226A}{\ll}\md@u{226B}{\gg}\md@u{2272}{\lesssim}\md@u{2273}{\gtrsim}
\md@u{2208}{\in}\md@u{2209}{\notin}\md@u{220B}{\ni}\md@u{2282}{\subset}\md@u{2283}{\supset}
\md@u{2286}{\subseteq}\md@u{2287}{\supseteq}\md@u{222A}{\cup}\md@u{2229}{\cap}
\md@u{2205}{\emptyset}\md@u{2200}{\forall}\md@u{2203}{\exists}\md@u{2227}{\wedge}\md@u{2228}{\vee}
\md@u{2295}{\oplus}\md@u{2297}{\otimes}\md@u{22A5}{\perp}\md@u{2225}{\parallel}
\md@u{2192}{\to}\md@u{2190}{\leftarrow}\md@u{2194}{\leftrightarrow}\md@u{21D2}{\Rightarrow}
\md@u{21D0}{\Leftarrow}\md@u{21D4}{\Leftrightarrow}\md@u{21A6}{\mapsto}\md@u{2191}{\uparrow}
\md@u{2193}{\downarrow}\md@u{27E8}{\langle}\md@u{27E9}{\rangle}\md@ut{2026}{\ldots}{\textellipsis}
\md@u{22EF}{\cdots}\md@u{2032}{'}\md@u{2033}{''}\md@ut{2020}{\dagger}{\textdagger}
\md@u{210F}{\hbar}\md@u{2113}{\ell}\md@u{211D}{\mathbb{R}}\md@u{2102}{\mathbb{C}}
\md@u{2124}{\mathbb{Z}}\md@u{2115}{\mathbb{N}}\md@u{211A}{\mathbb{Q}}
\md@ut{212B}{\mathrm{\mathring{A}}}{\r A}\md@ut{00C5}{\mathrm{\mathring{A}}}{\r A}
\md@u{2070}{^0}\md@u{2074}{^4}\md@u{2075}{^5}\md@u{2076}{^6}\md@u{2077}{^7}\md@u{2078}{^8}
\md@u{2079}{^9}\md@u{207B}{^-}\md@u{207A}{^+}\md@u{2080}{_0}\md@u{2081}{_1}\md@u{2082}{_2}
\md@u{2083}{_3}\md@u{2084}{_4}\md@u{2085}{_5}\md@u{2086}{_6}\md@u{2087}{_7}\md@u{2088}{_8}
\md@u{2089}{_9}
\makeatother
]==]
-- Template notes, kept out of the string so that editing them neither changes
-- the cache key nor rebuilds the format:
--   * The page is 1/4 px short of N px each way (`\md@eps`): MuPDF's ceil()
--     then lands on exactly N.
--   * No colour anywhere: ink is black (PDF's default for fill and for the
--     stroke of `2 Tr`), the mask is drawn in grey.
--   * `\outer` on the five job macros turns a runaway argument (`\frac{`)
--     into an error at the next equation instead of the loss of the file.
--   * `\let\par\relax`: a blank line in a display is not an error.
--   * Before and after each equation TeX must be at group level 0 in outer
--     vertical mode; if an equation left it otherwise nothing after it can be
--     trusted (`\md@test`).
--   * `\message{}` after BEGIN flushes stdout, so a run killed by the timeout
--     names the equation it was in.
--   * `\tex_shipout:D` bypasses LaTeX's shipout hooks; `\md@warm` loads the
--     fonts a formula normally needs, so that they are in the format.
--   * A display is typeset as `\hbox{$\displaystyle ...$}`, where amsmath's
--     top-level environments are errors ("allowed only in paragraph mode"):
--     `align` & co. are their inner forms (`aligned`, ...), `equation` and
--     `subequations` nothing, `eqnarray` an array, and `\tag` text at the
--     right (installed as `\dft@tag`, which `aligned` re-instates). A real
--     `align` would be `\hsize` wide, and the page could not be the cell box.
--   * `\tracinglostchars=3`: a glyph the font lacks is an error. Before it,
--     `$3 × 10^5$` was drawn as "310⁵" -- a wrong picture, cached for good.
--   * TS1 (`µ °` in `\text`) from Latin Modern's Type 1 fonts: Computer
--     Modern's `tcrm*` exist only as Metafont here, and pdfTeX found that out
--     only when it closed the PDF, failing the whole batch.
--   * `\@inmathwarn` raises an error instead of a warning: a text command in
--     math (what inputenc makes of `— “ ¿ ł ℧` and U+200C outside the table
--     below) used the text font's slot in a MATH font, a wrong glyph that
--     `\tracinglostchars` cannot see (`—` came out as `|`, `“` as `\`).
--     `\AA` gets a math form of its own: `5\,\AA` is common in units.
--   * `\DeclareUnicodeCharacter`: Greek, operators, relations and arrows
--     typed as Unicode, in math and in `\text`.

local FORMAT_JOB_NAME = "mdmath"
local FORMAT_SOURCE = "\\input{mdmath-preamble.tex}\n\\begin{document}\n"
  .. "\\csname md@warm\\endcsname\n\\dump\n"

--- Environment of every pdftex run; see the top of the file.
local TEX_ENVIRONMENT = {
  openin_any = "p",
  openout_any = "p",
  TEXMFOUTPUT = "",
  MKTEXFMT = "0",
  MKTEXPK = "0",
  MKTEXTFM = "0",
  MKTEXMF = "0",
  -- No wrapping of long lines on stdout (pdfTeX's default is 79 columns), so
  -- that a PAGE line or an error line is always one line.
  max_print_line = "100000",
}

--- Control words (by name, without the backslash) that can reach past the
--- group an equation is typeset in. An equation with any of them runs in a
--- pdftex run of its own. Matched by name in the source, so conservatively: a
--- false match costs one run (~40 ms), a miss can put a wrong picture on disk
--- for good. Local definitions (`\def`, `\let`, `\newcommand`'s own
--- definition, `\setlength`) are undone when the equation's box closes and
--- need no run of their own.
-- stylua: ignore
local ISOLATING_COMMANDS = {
  -- Global assignments, and parameters that are always global.
  "global", "gdef", "xdef", "globaldefs", "afterassignment", "aftergroup",
  "fontdimen", "hyphenchar", "skewchar", "hyphenation", "patterns",
  "batchmode", "nonstopmode", "scrollmode", "errorstopmode", "interactionmode",
  "deadcycles", "insertpenalties", "prevgraf",
  -- Leaving the equation's group or box early.
  "bgroup", "egroup", "begingroup", "endgroup",
  -- Names and category codes made at run time: anything can follow.
  "csname", "ifcsname", "scantokens", "catcode", "lccode", "uccode", "sfcode",
  "mathcode", "delcode", "makeatletter", "makeatother", "ExplSyntaxOn", "ExplSyntaxOff",
  -- Pages, files, the terminal (where the PAGE lines are read).
  "shipout", "openout", "closeout", "write", "immediate", "message", "typeout",
  "special", "openin", "read", "readline", "input", "include", "endinput",
  "everyeof", "IfFileExists", "InputIfFileExists", "usepackage", "RequirePackage",
  "documentclass", "includegraphics", "mark", "marks", "insert", "vadjust",
  "footnote", "footnotemark", "footnotetext", "marginpar", "output",
  "enddocument", "stop", "dump",
  -- The job file's own macros: `q\mde\mdi{2}Z` ended its page and forged the
  -- next one, shifting every later picture of the batch (review: 8 of 8
  -- wrong, cached). Alone it can spoil only its own picture. This list is
  -- best effort (LaTeX reaches the same by other names); for the job
  -- protocol the real guard is the order check in `parse_tex_output`.
  "mdi", "mde", "mdd", "mdde", "mdfinish", "mdsetup", "mdstroke", "mdpad",
  -- LaTeX settings that are global.
  "mathtoolsset", "numberwithin", "xglobal",
  -- A name made at run time without `\csname` (`\UseName{mde}`,
  -- `\UseName{gdef}`), `@` made a letter without `\catcode`.
  "UseName", "ExpandArgs", "MHInternalSyntaxOn", "MHInternalSyntaxOff",
  -- The terminal without `\write`: a line of one's own choosing.
  "typein", "MessageBreak",
  -- Box registers: their sizes and their emptying are not undone by a group
  -- (`\ht\strutbox=30pt` made every later matrix twice as high).
  "ht", "wd", "dp", "box", "unhbox", "unvbox", "unhcopy", "unvcopy", "vsplit",
}
--- And every control word starting with one of these (`\DeclareMathOperator`,
--- `\newcounter`, `\pdfliteral`, `\pagegoal`, `\GenericWarning`,
--- `\AddToHook`) or naming a counter (`\setcounter`, `\stepcounter`). Not
--- `Set`: `\Set` is braket's. Besides names, `^^` (it can spell any
--- character, braces and backslashes too), a `$` and `\(` `\)` `\[` `\]`
--- (they leave math) isolate an equation.
-- stylua: ignore
local ISOLATING_PREFIXES = {
  "new", "renew", "provide", "New", "Renew", "Provide", "Declare", "pdf", "global", "page",
  "Generic", "AddTo", "RemoveFrom", "Use", "At", "Assign", "Debug", "Activate", "Disable", "Clear",
}

---@type table<string, true>
local is_isolating_command = {}
for _, name in ipairs(ISOLATING_COMMANDS) do
  is_isolating_command[name] = true
end

-- -----------------------------------------------------------------------------
-- State
-- -----------------------------------------------------------------------------

---@type string?
local cache_directory
---@type string? `cache_directory/masks`
local masks_directory
---@type string? `cache_directory/run`
local run_directory

--- Template + user preamble, and what is derived from them (`configure`).
---@type string
local template_text = TEX_PREAMBLE
---@type string
local template_hash
---@type string
local key_prefix
---@type string? path of the user preamble, when one is set
local user_preamble_path
local standby_idle_milliseconds = STANDBY_IDLE_MILLISECONDS
local disk_budget_bytes = DISK_BUDGET_BYTES
local remembered_picture_limit = REMEMBERED_PICTURE_LIMIT
--- Bumped when the template (the user preamble) changes: what was made from
--- the old one is not remembered.
local template_generation = 0
--- VimLeavePre has run (see the top of the file): nothing is started any more.
local is_leaving = false

---@type boolean?
local are_programs_installed
---@type string?
local pdftex_path
---@type string?
local mutool_path
--- Why nothing can be run right now; nil while things work. `retry` clears it.
---@type string?
local environment_failure
--- Each kind is announced once (until `retry`): an internal error must not
--- hide a later "pdftex did not start", nor the other way round.
---@type table<"internal"|"environment", true>
local has_reported = {}

--- Memory key -> picture, or false for a failure. Failures are never written
--- to disk: a fixed TeX Live may compile them in the next session.
---@type table<string, MdRenderMathPicture|false>
local settled = {}
local settled_picture_count = 0
--- The generation of pictures before: still found (and moved back), so a
--- working set up to `remembered_picture_limit` never goes to disk again.
---@type table<string, MdRenderMathPicture>
local previous_pictures = {}
--- Memory key -> why it is `false`.
---@type table<string, string>
local failure_reasons = {}
--- Memory keys whose disk cache was checked and found empty -> their file stem
--- (so that `request` does not hash them again).
---@type table<string, string>
local is_absent_on_disk = {}
local absent_count = 0
--- Pictures read from disk this session, for maintenance to touch.
---@type table<string, true>
local used_paths = {}
local used_path_count = 0
local is_maintenance_scheduled = false
local has_pruned = false

---@class MdRenderMathTexItem
---@field memory_key string
---@field kind "inline"|"display"
---@field tex string trimmed
---@field look MdRenderMathLook
---@field look_signature string
---@field file_stem string cache path without extension
---@field waiters MdRenderMathTexWaiter[]
---@field is_isolated boolean runs in a pdftex run of its own
---@field group table? only items of one group share a run (halving)
---@field generation integer `template_generation` its file stem was made in
---@field has_failed_to_write boolean? its run directory vanished once (`put_back`)

---@class MdRenderMathTexWaiter
---@field remaining integer
---@field on_settled fun()

---@type table<string, MdRenderMathTexItem>
local pending = {}
---@type MdRenderMathTexItem[]
local queue = {}

local is_running = false
local is_run_scheduled = false
--- Every process started and not yet ended -> whether it leads a process
--- group of its own (the shell of the parallel mutools). VimLeavePre kills
--- them, the whole group too: the mutools would go on writing into a run
--- directory being removed.
---@type table<vim.SystemObj, boolean>
local running_processes = {}
--- Run directories in use: VimLeavePre removes them.
---@type table<string, true>
local live_directories = {}
--- Starts where no other instance of this module in this process has been
--- (a reload; the spec loads dozens): theirs are removed later, on workers,
--- and a directory made under the same name meanwhile went with them.
local directory_counter = math.floor(vim.uv.hrtime() / 1e3) % 1000000000

---@class MdRenderMathTexFormat
---@field name string? file name without `.fmt`, from template + pdftex identity
---@field path string? without the `.fmt`, as `-fmt=` takes it; set once it exists
---@field rebuilds_left integer

---@type MdRenderMathTexFormat
local format = { rebuilds_left = 1 }

-- -----------------------------------------------------------------------------
-- Keys and sizing
-- -----------------------------------------------------------------------------

-- One look table per build: its signature is made once, not per lookup.
---@type MdRenderMathLook?
local last_look
local last_cell_width, last_cell_height, last_look_signature

---@param look MdRenderMathLook
---@return string
local function signature_of(look)
  if
    look ~= last_look
    or look.cell_width ~= last_cell_width
    or look.cell_height ~= last_cell_height
  then
    last_look, last_cell_width, last_cell_height = look, look.cell_width, look.cell_height
    last_look_signature = look.cell_width .. "x" .. look.cell_height
  end
  return last_look_signature
end

---@param equation MdRenderMathEquation
---@param look MdRenderMathLook
---@return string memory_key, string look_signature, string trimmed_tex
local function identify(equation, look)
  local look_signature = signature_of(look)
  local tex = equation.tex:match("^%s*(.-)%s*$")
  return equation.kind .. "\31" .. look_signature .. "\31" .. tex, look_signature, tex
end

---@class MdRenderMathTexGeometry
---@field pixel_in_bp string
---@field dpi string
---@field baseline_row integer
---@field display_padding integer

---@param cell_height integer
---@return MdRenderMathTexGeometry
local function compute_geometry(cell_height)
  local pixel_in_bp = TEX_DESIGN_SIZE_BP * FONT_LINE_HEIGHT_EM / (GLYPH_SCALE * cell_height)
  return {
    pixel_in_bp = string.format("%.6f", pixel_in_bp),
    dpi = string.format("%.4f", 72 / pixel_in_bp),
    baseline_row = math.floor(cell_height * FONT_ASCENDER_EM / FONT_LINE_HEIGHT_EM + 0.5),
    display_padding = math.max(1, math.floor(cell_height * DISPLAY_PADDING_FRACTION + 0.5)),
  }
end

---@param tex string
---@return boolean
local function has_balanced_braces(tex)
  local depth = 0
  local position = 1
  local length = #tex
  while position <= length do
    local character = tex:sub(position, position)
    if character == "\\" then
      position = position + 1
    elseif character == "%" then
      position = tex:find("\n", position, true) or length
    elseif character == "{" then
      depth = depth + 1
    elseif character == "}" then
      depth = depth - 1
      if depth < 0 then
        return false
      end
    end
    position = position + 1
  end
  return depth == 0
end

---@param name string control word without the backslash
---@return boolean
local function is_isolating(name)
  if is_isolating_command[name] or name:find("counter", 1, true) then
    return true
  end
  for _, prefix in ipairs(ISOLATING_PREFIXES) do
    if name:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

--- Whether the TeX can reach past its own group; see ISOLATING_COMMANDS.
---@param tex string
---@return boolean
local function needs_own_run(tex)
  if tex:find("^^", 1, true) then
    return true
  end
  local position = 1
  local length = #tex
  while position <= length do
    local character = tex:sub(position, position)
    if character == "$" then
      return true
    elseif character == "\\" then
      local name = tex:match("^%a+", position + 1)
      if name then
        if is_isolating(name) then
          return true
        end
        position = position + #name
      elseif tex:find("^[()%[%]]", position + 1) then
        return true
      else
        -- A control symbol (`\$`, `\{`, `\\`): skip the character it names.
        position = position + 1
      end
    end
    position = position + 1
  end
  return false
end

---@param kind string
---@param tex string
---@param look MdRenderMathLook
---@return string
local function file_stem_of(kind, tex, look)
  local geometry = compute_geometry(look.cell_height)
  local key = table.concat({
    key_prefix,
    kind,
    look.cell_width,
    look.cell_height,
    geometry.pixel_in_bp,
    geometry.dpi,
    geometry.baseline_row,
    geometry.display_padding,
    tex,
  }, "\31")
  return masks_directory .. "/" .. vim.fn.sha256(key):sub(1, 32)
end

-- -----------------------------------------------------------------------------
-- Memory
-- -----------------------------------------------------------------------------

---@param memory_key string
---@param picture MdRenderMathPicture
local function remember_picture(memory_key, picture)
  if settled_picture_count >= remembered_picture_limit then
    -- A new generation: the current pictures become the previous ones (the
    -- previous ones go), failures stay.
    previous_pictures = {}
    for key, value in pairs(settled) do
      if value then
        previous_pictures[key] = value
        settled[key] = nil
      end
    end
    settled_picture_count = 0
  end
  if not settled[memory_key] then
    settled_picture_count = settled_picture_count + 1
  end
  settled[memory_key] = picture
end

--- A picture of the previous generation, moved back into the current one.
---@param memory_key string
---@return MdRenderMathPicture?
local function recall_picture(memory_key)
  local picture = previous_pictures[memory_key]
  if picture then
    previous_pictures[memory_key] = nil
    remember_picture(memory_key, picture)
  end
  return picture
end

local function forget_all_absent()
  require("table.clear")(is_absent_on_disk)
  absent_count = 0
end

---@param memory_key string
---@param file_stem string
local function remember_absent(memory_key, file_stem)
  if absent_count >= ABSENT_LIMIT then
    forget_all_absent()
  end
  if not is_absent_on_disk[memory_key] then
    absent_count = absent_count + 1
  end
  is_absent_on_disk[memory_key] = file_stem
end

---@param memory_key string
local function forget_absent(memory_key)
  if is_absent_on_disk[memory_key] then
    is_absent_on_disk[memory_key] = nil
    absent_count = absent_count - 1
  end
end

-- -----------------------------------------------------------------------------
-- Disk
-- -----------------------------------------------------------------------------

---@param file_stem string
---@return MdRenderMathPicture?
local function read_picture_from_disk(file_stem)
  local path = file_stem .. ".png"
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local size = file:seek("end")
  file:seek("set", math.max(0, size - RECORD_READ_BYTES))
  local columns, rows, scale = (file:read(RECORD_READ_BYTES) or ""):match(RECORD_PATTERN)
  file:close()
  if not columns then
    return nil
  end
  if not used_paths[path] and used_path_count < USED_PATH_LIMIT then
    used_paths[path] = true
    used_path_count = used_path_count + 1
  end
  return {
    path = path,
    columns = tonumber(columns) --[[@as integer]],
    rows = tonumber(rows) --[[@as integer]],
    scale = tonumber(scale) --[[@as number]],
  }
end

---@param path string
---@param content string
---@return boolean
local function write_file(path, content)
  local file = io.open(path, "w")
  if not file then
    return false
  end
  local is_written = file:write(content) ~= nil
  return file:close() and is_written
end

--- Deletes a directory tree. Runs on a libuv worker (`vim.uv.new_work`), in a
--- Lua state of its own: no upvalues. Maintenance, a worker itself, gets it
--- as bytecode.
---@param root string
local function remove_tree_work(root)
  local libuv = vim.uv
  local function remove(path)
    local scanner = libuv.fs_scandir(path)
    while scanner do
      local name, kind = libuv.fs_scandir_next(scanner)
      if not name then
        break
      end
      if kind == "directory" then
        remove(path .. "/" .. name)
      else
        libuv.fs_unlink(path .. "/" .. name)
      end
    end
    libuv.fs_rmdir(path)
  end
  remove(root)
end

--- A finished run's directory goes on a worker thread.
---@param directory string
local function remove_directory_later(directory)
  vim.uv
    .new_work(remove_tree_work, function()
      live_directories[directory] = nil
    end)
    :queue(directory)
end

---@param prefix string
---@return string? directory
local function make_run_directory(prefix)
  directory_counter = directory_counter + 1
  local directory =
    string.format("%s/%s-%d-%d", run_directory, prefix, vim.uv.os_getpid(), directory_counter)
  if not vim.uv.fs_mkdir(directory, tonumber("700", 8)) then
    -- A crashed session with this pid and counter: take it over.
    vim.fn.delete(directory, "rf")
    if not vim.uv.fs_mkdir(directory, tonumber("700", 8)) then
      return nil
    end
  end
  live_directories[directory] = true
  return directory
end

--- `masks/` and `run/`, made again at the start of every batch (one stat
--- each when they exist; see the top of the file).
---@return boolean
local function make_directories()
  -- `mkdir()` raises (E739) where it cannot create.
  local is_made, result = pcall(function()
    return vim.fn.mkdir(masks_directory, "p") == 1 and vim.fn.mkdir(run_directory, "p") == 1
  end)
  return is_made and result
end

-- -----------------------------------------------------------------------------
-- Settling
-- -----------------------------------------------------------------------------

---@param kind "internal"|"environment"
---@param message string
local function report_once(kind, message)
  if has_reported[kind] then
    return
  end
  has_reported[kind] = true
  vim.notify("md-render math: " .. message .. "; equations show as text", vim.log.levels.WARN)
end

--- Out of `pending`; waiters told. Once per item: a second call (an error
--- path after a partial settle) changes nothing.
---@param item MdRenderMathTexItem
local function release(item)
  if pending[item.memory_key] ~= item then
    return
  end
  pending[item.memory_key] = nil
  for _, waiter in ipairs(item.waiters) do
    waiter.remaining = waiter.remaining - 1
    if waiter.remaining == 0 then
      vim.schedule(waiter.on_settled)
    end
  end
end

---@param item MdRenderMathTexItem
---@param picture MdRenderMathPicture|false
---@param reason string? why it is false
local function settle(item, picture, reason)
  if pending[item.memory_key] ~= item then
    return
  end
  -- Made from a template that has changed since (on disk it is under the
  -- old template's key, which is right): not this session's picture.
  if item.generation == template_generation then
    if picture then
      remember_picture(item.memory_key, picture)
    else
      settled[item.memory_key] = false
      failure_reasons[item.memory_key] = reason or "no picture came out"
    end
    forget_absent(item.memory_key)
  end
  release(item)
end

--- Could not be made, for reasons that are not its TeX: `lookup` keeps
--- answering nil.
---@param items MdRenderMathTexItem[]
local function abandon_all(items)
  for _, item in ipairs(items) do
    release(item)
  end
end

--- Runs `work`. An error in it (a bug, or output nobody foresaw) must never
--- leave a batch half done and `is_running` stuck for the session, as a
--- forged `MDMATH BEGIN` once did: what `items` still wait for is
--- abandoned (nil), it is reported once, and the caller moves on.
---@param work fun()
---@param items MdRenderMathTexItem[]
---@return boolean is_done false: it raised
local function guarded(work, items)
  local is_done, problem = xpcall(work, debug.traceback)
  if not is_done then
    abandon_all(items)
    report_once("internal", "internal error: " .. tostring(problem):match("[^\n]*"))
  end
  return is_done
end

--- What waits, when nothing can be run.
local function abandon_queue()
  local waiting = queue
  queue = {}
  abandon_all(waiting)
end

--- Nothing can be run: `is_available()` is false; `items` (the batch that
--- found out, asked for first) and what waits are abandoned.
---@param reason string
---@param items? MdRenderMathTexItem[]
local function fail_environment(reason, items)
  environment_failure = environment_failure or reason
  report_once("environment", reason)
  if items then
    abandon_all(items)
  end
  abandon_queue()
end

--- An item made from now on is made with the template of now: stored under
--- its key, not under that of the template it was asked for with.
---@param item MdRenderMathTexItem
local function rekey(item)
  if item.generation ~= template_generation then
    item.file_stem = file_stem_of(item.kind, item.tex, item.look)
    item.generation = template_generation
  end
end

--- Run again, ahead of what is queued: they were asked for first.
---@param items MdRenderMathTexItem[]
local function put_back(items)
  for index = #items, 1, -1 do
    local item = items[index]
    rekey(item)
    table.insert(queue, 1, item)
  end
end

-- -----------------------------------------------------------------------------
-- Processes
-- -----------------------------------------------------------------------------

---@class MdRenderMathTexRun
---@field code integer
---@field signal integer
---@field stdout string at most MAXIMUM_OUTPUT_BYTES
---@field stderr string at most KEPT_STDERR_BYTES
---@field has_started boolean false: the program never ran (spawn error, not found)
---@field was_killed boolean by the time limit, the CPU limit or the output cap
---@field was_over_cap boolean killed for printing too much

--- `setpriv`, looked up once (from a scheduled callback, not on the build
--- path); false when there is none. Without it there is no standby.
---@type string|false|nil
local setpriv_path

---@return string|false
local function find_setpriv()
  if setpriv_path == nil then
    local found = vim.fn.exepath("setpriv")
    setpriv_path = found ~= "" and found or false
  end
  return setpriv_path
end

--- `command` run by a shell that first sets a CPU limit, then becomes the
--- command (`exec`): same process, environment and directory, so a kill
--- reaches the command itself. `should_die_with_neovim`: also through
--- `setpriv --pdeathsig KILL` (one more exec in the same process), for the
--- standby, which may wait in `open` without CPU for as long as it likes.
---@param cpu_seconds integer
---@param command string[]
---@param should_die_with_neovim? boolean
---@return string[]
local function with_cpu_limit(cpu_seconds, command, should_die_with_neovim)
  local prefix = { "/bin/sh", "-c", "ulimit -t " .. cpu_seconds .. ' 2>/dev/null; exec "$@"', "sh" }
  if should_die_with_neovim then
    vim.list_extend(prefix, { assert(find_setpriv()), "--pdeathsig", "KILL" })
  end
  return vim.list_extend(prefix, command)
end

--- `vim.system` with stdout and stderr capped together at
--- MAXIMUM_OUTPUT_BYTES (the process is killed past it), its exit handled on
--- the main loop, and a spawn failure (binary gone) reported as an exit.
---@param command string[]
---@param options vim.SystemOpts
---@param on_exit fun(result: MdRenderMathTexRun)
---@param on_stdout? fun(data: string) each piece of stdout as it arrives (fast context)
---@param is_group? boolean the process leads a process group of its own
---@return vim.SystemObj?
local function run_process(command, options, on_exit, on_stdout, is_group)
  if is_leaving then
    -- Neovim is exiting: nothing new, and nobody waits for an answer.
    return nil
  end
  options.detach = is_group or nil
  local chunks, kept_stderr = {}, {}
  local size, stderr_size = 0, 0
  local is_over_cap = false
  ---@type vim.SystemObj?
  local process
  local function stop_at_cap()
    is_over_cap = true
    if process then
      process:kill("sigkill")
    end
  end
  options.text = true
  options.stdout = function(_, data)
    if not data or is_over_cap then
      return
    end
    if size + #data > MAXIMUM_OUTPUT_BYTES then
      -- Keep what fits: the last BEGIN may be in this very chunk.
      chunks[#chunks + 1] = data:sub(1, MAXIMUM_OUTPUT_BYTES - size)
      return stop_at_cap()
    end
    size = size + #data
    chunks[#chunks + 1] = data
    if on_stdout then
      on_stdout(data)
    end
  end
  options.stderr = function(_, data)
    if not data or is_over_cap then
      return
    end
    if stderr_size < KEPT_STDERR_BYTES then
      kept_stderr[#kept_stderr + 1] = data:sub(1, KEPT_STDERR_BYTES - stderr_size)
    end
    stderr_size = stderr_size + #data
    if size + stderr_size > MAXIMUM_OUTPUT_BYTES then
      stop_at_cap()
    end
  end
  local is_spawned, process_or_error = pcall(vim.system, command, options, function(result)
    vim.schedule(function()
      if process then
        running_processes[process] = nil
      end
      if is_leaving then
        -- Killed by VimLeavePre: nobody waits for an answer, and a reason
        -- made of that kill ("ran longer than ...") would be a false one.
        return
      end
      on_exit({
        code = result.code,
        signal = result.signal,
        stdout = table.concat(chunks),
        stderr = table.concat(kept_stderr),
        -- 126/127: the shell of `with_cpu_limit` could not run the command.
        has_started = result.code ~= 126 and result.code ~= 127,
        was_killed = is_over_cap or result.code == 124 or result.signal ~= 0,
        was_over_cap = is_over_cap,
      })
    end)
  end)
  if is_spawned then
    process = process_or_error
    running_processes[process] = is_group == true
    return process
  end
  vim.schedule(function()
    on_exit({
      code = -1,
      signal = 0,
      stdout = "",
      stderr = tostring(process_or_error),
      has_started = false,
      was_killed = false,
      was_over_cap = false,
    })
  end)
  return nil
end

--- pdfTeX on `job.tex` in `directory`. A standby dies with Neovim and has no
--- time limit of its own (see the top of the file).
---@param directory string
---@param format_path string
---@param is_standby boolean
---@param on_exit fun(result: MdRenderMathTexRun)
---@return vim.SystemObj?
local function start_tex(directory, format_path, is_standby, on_exit)
  return run_process(
    with_cpu_limit(CPU_LIMIT_SECONDS, {
      "pdftex",
      "-interaction=nonstopmode",
      "-no-shell-escape",
      "-no-parse-first-line",
      "-fmt=" .. format_path,
      "job.tex",
    }, is_standby),
    {
      cwd = directory,
      env = TEX_ENVIRONMENT,
      timeout = not is_standby and timeout_milliseconds or nil,
    },
    on_exit
  )
end

---@param output string?
---@return string at most 200 bytes
local function first_error_line(output)
  output = output or ""
  local line = output:sub(1, 2) == "! " and output:match("^! ([^\n]*)")
    or output:match("\n! ([^\n]*)")
  if not line then
    -- Line by line with a plain find: one pattern like `[^\n]*fatal` over the
    -- whole output is quadratic in the length of a line, and a flood has
    -- lines of 100 kB (a looping preamble froze Neovim for ~10 minutes).
    for candidate in output:gmatch("[^\n]+") do
      if candidate:find("fatal", 1, true) then
        line = candidate
        break
      end
    end
  end
  return (line or vim.trim(output:sub(1, 400))):sub(1, 200)
end

-- -----------------------------------------------------------------------------
-- The template and the format
-- -----------------------------------------------------------------------------

--- Template + user preamble -> hash and key prefix. A changed preamble is a
--- new format and new pictures.
---@return boolean is_read false: the user preamble could not be read
local function configure_template()
  local user_preamble = ""
  local is_read = true
  local configured = vim.g.md_render_math_preamble
  user_preamble_path = type(configured) == "string"
      and configured ~= ""
      and vim.fs.normalize(configured)
    or nil
  if user_preamble_path then
    local file = io.open(user_preamble_path, "r")
    if file then
      user_preamble = "% user preamble: " .. user_preamble_path .. "\n" .. file:read("*a") .. "\n"
      file:close()
    else
      is_read = false
    end
  end
  template_text = TEX_PREAMBLE .. user_preamble
  template_hash = vim.fn.sha256(template_text .. FORMAT_SOURCE):sub(1, 16)
  key_prefix = table.concat({
    CACHE_LAYOUT,
    "v" .. TEMPLATE_VERSION,
    template_hash,
    FONT_LINE_HEIGHT_EM,
    FONT_ASCENDER_EM,
    TEX_DESIGN_SIZE_BP,
    GLYPH_SCALE,
    STROKE_BP,
    DISPLAY_PADDING_FRACTION,
  }, "|")
  return is_read
end

--- The format's file name: template + which pdfTeX, told from the binary's
--- path, size and mtime (three stats), not from `pdftex --version` (a process:
--- 5-8 ms of main thread to start in the full config, ~10 ms to wait for). A
--- wrapper script that hides an upgrade is caught by the rebuild below ("not
--- one equation began").
---@return string?
local function format_name()
  if format.name then
    return format.name
  end
  local binary = pdftex_path and vim.uv.fs_realpath(pdftex_path)
  local stat = binary and vim.uv.fs_stat(binary)
  if not stat then
    return nil
  end
  local identity = table.concat({ binary, stat.size, stat.mtime.sec, stat.mtime.nsec }, "\31")
  format.name = string.format(
    "format-v%d-%s",
    TEMPLATE_VERSION,
    vim.fn.sha256(template_hash .. "\31" .. identity):sub(1, 16)
  )
  return format.name
end

---@param format_path string
---@param on_ready fun(path: string?)
local function build_format(format_path, on_ready)
  local build_directory = make_run_directory("format-build")
  local generation = template_generation
  ---@param reason string
  local function fail(reason)
    if build_directory then
      remove_directory_later(build_directory)
    end
    fail_environment(reason)
    on_ready(nil)
  end
  if not build_directory then
    return fail("cannot create a directory in " .. run_directory)
  end
  if
    not write_file(build_directory .. "/mdmath-preamble.tex", template_text)
    or not write_file(build_directory .. "/mdmath-format.tex", FORMAT_SOURCE)
  then
    return fail("cannot write in " .. build_directory)
  end
  run_process(
    with_cpu_limit(FORMAT_BUILD_CPU_LIMIT_SECONDS, {
      "pdftex",
      "-ini",
      "-interaction=nonstopmode",
      "-halt-on-error",
      -- The user preamble is note-vault content too.
      "-no-shell-escape",
      "-jobname=" .. FORMAT_JOB_NAME,
      "&pdflatex",
      "mdmath-format.tex",
    }),
    {
      cwd = build_directory,
      env = TEX_ENVIRONMENT,
      timeout = FORMAT_BUILD_TIMEOUT_MILLISECONDS,
    },
    function(result)
      local dumped = build_directory .. "/" .. FORMAT_JOB_NAME .. ".fmt"
      if not result.has_started then
        return fail("pdftex did not start: " .. first_error_line(result.stderr))
      end
      if result.was_killed then
        -- Its output is then the banner and whatever looped, not a reason.
        return fail(
          result.was_over_cap and "building the TeX format printed without end"
            or (
              "building the TeX format ran longer than "
              .. FORMAT_BUILD_TIMEOUT_MILLISECONDS
              .. " ms"
            )
        )
      end
      if result.code ~= 0 or not vim.uv.fs_stat(dumped) then
        return fail(
          "building the TeX format failed ("
            .. first_error_line(result.stdout .. result.stderr)
            .. ")"
        )
      end
      local function install(path)
        if not vim.uv.fs_rename(path, format_path .. ".fmt") then
          return fail("cannot move the format into " .. cache_directory)
        end
        remove_directory_later(build_directory)
        if generation ~= template_generation then
          -- The preamble changed while it was built: built for nothing now;
          -- the next run builds the new one.
          return on_ready(nil)
        end
        format.path = format_path
        on_ready(format_path)
      end
      -- pdfTeX reads a gunzipped format as it is, ~50 ms a run faster. Without
      -- gzip the compressed one serves.
      if vim.fn.executable("gzip") == 0 then
        return install(dumped)
      end
      run_process(
        { "gzip", "-d", "-f", "-S", ".fmt", FORMAT_JOB_NAME .. ".fmt" },
        { cwd = build_directory },
        function(gzip_result)
          local gunzipped = build_directory .. "/" .. FORMAT_JOB_NAME
          install((gzip_result.code == 0 and vim.uv.fs_stat(gunzipped)) and gunzipped or dumped)
        end
      )
    end
  )
end

--- The format of this template for this pdfTeX, once its file is there.
---@return string? path
local function find_format()
  if not format.path then
    local name = format_name()
    if name and vim.uv.fs_stat(cache_directory .. "/" .. name .. ".fmt") then
      format.path = cache_directory .. "/" .. name
    end
  end
  return format.path
end

--- The format, built on first use.
---@param on_ready fun(path: string?)
local function prepare_format(on_ready)
  local format_path = find_format()
  if format_path then
    return on_ready(format_path)
  end
  local name = format_name()
  if not name then
    fail_environment("pdftex is not where it was")
    return on_ready(nil)
  end
  build_format(cache_directory .. "/" .. name, on_ready)
end

-- -----------------------------------------------------------------------------
-- The standby (see the top of the file for why each piece is there)
-- -----------------------------------------------------------------------------

---@class MdRenderMathTexStandby
---@field directory string
---@field fifo string
---@field format_path string
---@field process vim.SystemObj
---@field has_exited boolean
---@field on_exit fun(result: MdRenderMathTexRun)? set once a batch took it

---@type MdRenderMathTexStandby?
local standby
--- Why there is no standby this session (until `retry`); nil: there may be.
---@type string?
local standby_off_reason
local is_standby_scheduled = false
--- A lookup found nothing or a request came since the idle timer last looked.
local has_recent_need = false
---@type uv.uv_timer_t?
local idle_timer
local is_mkfifo_declared = false
--- How often a standby that is still loading is asked whether it reads its
--- FIFO yet, once a job waits for it (each ask is a main-thread `open`).
local STANDBY_READY_POLL_MILLISECONDS = 2

---@param path string
---@return boolean
local function make_fifo(path)
  local is_loaded, ffi = pcall(require, "ffi")
  if not is_loaded then
    return false
  end
  if not is_mkfifo_declared then
    -- A second module instance declares it again: that error is harmless.
    pcall(ffi.cdef, "int mkfifo(const char *pathname, unsigned int mode);")
    is_mkfifo_declared = true
  end
  local is_called, result = pcall(function()
    return ffi.C.mkfifo(path, tonumber("600", 8))
  end)
  return is_called and result == 0
end

---@param descriptor integer the FIFO's write end
---@param job_text string
local function write_to_standby(descriptor, job_text)
  local pipe = vim.uv.new_pipe(false)
  if not pipe or not pipe:open(descriptor) then
    if pipe then
      pipe:close()
    end
    -- Closing the only write end is end-of-file: pdfTeX reads an empty job
    -- and stops at once; the batch ends as a run that began nothing (nil).
    vim.uv.fs_close(descriptor)
    return
  end
  pipe:write(job_text, function()
    -- Closing is the end of the job file for pdfTeX.
    pipe:close()
  end)
end

--- The FIFO's write end opens without blocking only once pdfTeX has its
--- format loaded and job.tex open for reading (ENXIO until then): the job
--- goes the moment it does. See the top of the file for why nothing may
--- wait in a blocking open, and why nothing polls while nobody waits.
---@param slot MdRenderMathTexStandby
---@param job_text string
local function write_when_ready(slot, job_text)
  local flags = vim.uv.constants.O_WRONLY + vim.uv.constants.O_NONBLOCK
  local descriptor, _, problem = vim.uv.fs_open(slot.fifo, flags, 0)
  if descriptor then
    return write_to_standby(descriptor, job_text)
  end
  if problem ~= "ENXIO" then
    -- Not "no reader yet": the FIFO is gone (the cache was cleared). It never
    -- opens; without this the batch waited out the whole time limit.
    return slot.process:kill("sigkill")
  end
  local ready_timer = assert(vim.uv.new_timer())
  -- libuv's callback, not a scheduled one: all it does is libuv.
  ready_timer:start(STANDBY_READY_POLL_MILLISECONDS, STANDBY_READY_POLL_MILLISECONDS, function()
    local is_over = slot.has_exited or is_leaving
    if not is_over then
      descriptor, _, problem = vim.uv.fs_open(slot.fifo, flags, 0)
      if not descriptor and problem == "ENXIO" then
        return
      end
    end
    ready_timer:stop()
    ready_timer:close()
    if descriptor then
      write_to_standby(descriptor, job_text)
    elseif not is_over then
      slot.process:kill("sigkill")
    end
  end)
end

--- The slot is free again (its pdfTeX was taken by a batch, stopped, or has
--- ended), and nothing counts idle time.
local function clear_standby()
  standby = nil
  if idle_timer then
    idle_timer:stop()
    idle_timer:close()
    idle_timer = nil
  end
end

--- Ends the parked standby, if there is one.
local function stop_standby()
  local slot = standby
  if slot then
    clear_standby()
    slot.process:kill("sigkill")
  end
end

local function start_idle_timer()
  idle_timer = vim.uv.new_timer()
  idle_timer:start(standby_idle_milliseconds, standby_idle_milliseconds, function()
    vim.schedule(function()
      if has_recent_need then
        has_recent_need = false
      else
        stop_standby()
      end
    end)
  end)
end

---@param format_path string
local function spawn_standby(format_path)
  if standby or standby_off_reason or environment_failure or is_leaving then
    return
  end
  local directory = make_run_directory("job")
  if not directory then
    return
  end
  local fifo = directory .. "/job.tex"
  vim.uv.fs_symlink("/dev/null", directory .. "/job.log")
  if not make_fifo(fifo) then
    standby_off_reason = "no FIFO could be made"
    remove_directory_later(directory)
    return
  end
  ---@type MdRenderMathTexStandby
  local slot = ---@diagnostic disable-next-line: missing-fields
    { directory = directory, fifo = fifo, format_path = format_path, has_exited = false }
  local process = start_tex(directory, format_path, true, function(result)
    slot.has_exited = true
    if standby == slot then
      clear_standby()
    end
    if slot.on_exit then
      return slot.on_exit(result)
    end
    -- Stopped or died before it was used. Died by itself (no kill of
    -- ours): the next one would too, so no more standbys this session.
    if result.signal == 0 then
      standby_off_reason = "a standby died by itself"
    end
    remove_directory_later(directory)
  end)
  if not process then
    -- Not spawned: the exit callback above still comes for it.
    return
  end
  slot.process = process
  standby = slot
  has_recent_need = false
  start_idle_timer()
end

--- Have a standby for the next batch, when the format is there already (one
--- is never built for a standby) and `setpriv` exists: without its
--- parent-death signal, every `kill -9` of Neovim left a parked pdfTeX (38
--- MB) for good once the cache was gone (final review: 41 of 41).
local function ensure_standby()
  is_standby_scheduled = false
  if
    standby
    or standby_off_reason
    or is_running
    or is_leaving
    or not M.is_available()
    or not make_directories()
  then
    return
  end
  if not find_setpriv() then
    standby_off_reason = "setpriv is not installed"
    return
  end
  local format_path = find_format()
  if format_path then
    spawn_standby(format_path)
  end
end

--- Something is missing: a request will follow. One boolean on the hot path.
local function note_need()
  has_recent_need = true
  if not standby and not is_standby_scheduled and not standby_off_reason then
    is_standby_scheduled = true
    vim.schedule(ensure_standby)
  end
end

-- -----------------------------------------------------------------------------
-- A batch
-- -----------------------------------------------------------------------------

---@param items MdRenderMathTexItem[]
---@param geometry MdRenderMathTexGeometry
---@return string
local function write_job(items, geometry)
  local look = items[1].look
  local lines = {
    -- An uncompressed PDF: pdfTeX ~7 ms faster on 135 equations, the
    -- pictures byte-identical (Latency L11).
    string.format(
      "\\pdfcompresslevel=0 \\pdfobjcompresslevel=0 "
        .. "\\mdsetup{%s}{%d}{%d}{%d}\\mdstroke{%s}\\mdpad{%d}",
      geometry.pixel_in_bp,
      look.cell_width,
      look.cell_height,
      geometry.baseline_row,
      STROKE_BP,
      geometry.display_padding
    ),
  }
  local count = 1
  for index, item in ipairs(items) do
    -- The TeX on lines of its own: a `%` in it cannot comment out the end.
    local is_inline = item.kind == "inline"
    lines[count + 1] = (is_inline and "\\mdi{" or "\\mdd{") .. index .. "}%"
    lines[count + 2] = item.tex
    lines[count + 3] = is_inline and "\\mde" or "\\mdde"
    count = count + 3
  end
  lines[count + 1] = "\\mdfinish"
  return table.concat(lines, "\n") .. "\n"
end

---@class MdRenderMathTexOutcome
---@field page { columns: integer, rows: integer, scale: string }?
---@field has_error boolean
---@field error string? TeX's first error line, with where it happened
---@field is_dirty boolean
---@field is_skipped boolean

---@class MdRenderMathTexReport
---@field outcomes table<integer, MdRenderMathTexOutcome>
---@field last_begun integer?
---@field page_lines integer PAGE lines printed, whoever printed them
---@field is_in_order boolean every BEGIN, PAGE, DIRTY and SKIP line is where the template prints it
---@field pages_written integer? pages in the PDF; nil when no whole PDF came out

---@param output string pdftex's stdout
---@return MdRenderMathTexReport
local function parse_tex_output(output)
  local outcomes = {}
  local current
  local page_lines = 0
  local is_context_wanted = false
  -- The template prints BEGIN 1, [PAGE 1], BEGIN 2, [PAGE 2], ... and one
  -- DIRTY or SKIP for the equation it is in. A line that is not the next one
  -- of that sequence was printed by an equation (a forged BEGIN of an earlier
  -- one emptied its outcome and shifted every later page). This, not the
  -- list of isolating names, is what guards the protocol.
  local is_in_order = true
  for line in output:gmatch("[^\n]+") do
    local begun = line:match("^MDMATH BEGIN (%d+)")
    if begun then
      is_in_order = is_in_order and tonumber(begun) == (current or 0) + 1
      current = tonumber(begun)
      outcomes[current] = { page = nil, has_error = false, is_dirty = false, is_skipped = false }
      is_context_wanted = false
    elseif line:sub(1, 2) == "! " then
      if current then
        local outcome = outcomes[current]
        outcome.has_error = true
        if not outcome.error then
          outcome.error = line:sub(3)
          is_context_wanted = true
        end
      end
    elseif is_context_wanted and line:find("^l%.%d+ ") then
      -- The line after the error: where in the equation it happened.
      outcomes[current].error = outcomes[current].error .. " -- at: " .. line:gsub("^l%.%d+ ", "")
      is_context_wanted = false
    elseif line:sub(1, 7) == "MDMATH " then
      local id, columns, rows, scale =
        line:match("^MDMATH PAGE (%d+) cols=(%d+) rows=(%d+) .* scale=([%d.]+) ")
      if line:sub(1, 12) == "MDMATH PAGE " then
        page_lines = page_lines + 1
      end
      local outcome = id and outcomes[tonumber(id)]
      if outcome then
        is_in_order = is_in_order and tonumber(id) == current and outcome.page == nil
        outcome.page = { columns = tonumber(columns), rows = tonumber(rows), scale = scale }
      else
        local state, state_id = line:match("^MDMATH (%u+) (%d+)")
        outcome = state_id and outcomes[tonumber(state_id)]
        is_in_order = is_in_order and (line == "MDMATH DONE" or tonumber(state_id) == current)
        if outcome and state == "DIRTY" then
          outcome.is_dirty = true
        elseif outcome and state == "SKIP" then
          outcome.is_skipped = true
        end
      end
    end
  end
  -- A run that died (`Emergency stop`, capacity exceeded, 100 errors) leaves
  -- a truncated PDF that MuPDF would "repair" and draw: only this line says
  -- the PDF is whole.
  local pages_written = output:match("\nOutput written on job%.pdf %((%d+) pages?,")
  return {
    outcomes = outcomes,
    last_begun = current,
    page_lines = page_lines,
    is_in_order = is_in_order,
    pages_written = tonumber(pages_written),
  }
end

---@param count integer pages to draw
---@return integer[] sizes of the chunks, in page order
local function plan_raster_chunks(count)
  local processes = math.min(MAXIMUM_RASTER_PROCESSES, math.floor(count / MINIMUM_RASTER_CHUNK))
  if processes <= 1 then
    return { count }
  end
  local first = math.min(FIRST_RASTER_CHUNK, math.ceil(count / processes))
  local rest = count - first
  local sizes = { first }
  for index = 1, processes - 1 do
    sizes[#sizes + 1] = math.floor(rest / (processes - 1))
      + (index <= rest % (processes - 1) and 1 or 0)
  end
  return sizes
end

--- Checks each drawn page and moves it into the cache with its record. Runs
--- on a libuv worker (`vim.uv.new_work`), in a Lua state of its own: no
--- upvalues. `entries`: one "<index> <page> <columns> <rows> <scale> <name>"
--- line each. Returns "<index> <code>" lines: 1 made, 2 not a mask of the
--- expected size (mutool or the template is wrong), 3 a file operation failed.
---@return string
local function read_back_work(job_directory, masks, cell_width, cell_height, entries)
  local libuv = vim.uv
  local results = {}
  local header
  local function big_endian(offset)
    local byte_1, byte_2, byte_3, byte_4 = header:byte(offset, offset + 3)
    return ((byte_1 * 256 + byte_2) * 256 + byte_3) * 256 + byte_4
  end
  for line in entries:gmatch("[^\n]+") do
    local index, page, columns, rows, scale, name =
      line:match("^(%d+) (%d+) (%d+) (%d+) (%S+) (%S+)$")
    local drawn = job_directory .. "/p-" .. page .. ".png"
    local code = 3
    local descriptor = libuv.fs_open(drawn, "r+", 0)
    if descriptor then
      local stat = libuv.fs_fstat(descriptor)
      header = libuv.fs_read(descriptor, 29, 0)
      if stat and header and #header == 29 then
        code = 2
        if
          header:sub(2, 4) == "PNG"
          and header:sub(13, 16) == "IHDR"
          and big_endian(17) == tonumber(columns) * cell_width
          and big_endian(21) == tonumber(rows) * cell_height
          -- 8-bit greyscale, not interlaced: what the terminal side tints.
          and header:byte(25) == 8
          and header:byte(26) == 0
          and header:byte(29) == 0
        then
          local record = "\nmdmath " .. columns .. " " .. rows .. " " .. scale .. "\n"
          code = libuv.fs_write(descriptor, record, stat.size) == #record and 1 or 3
        end
      end
      libuv.fs_close(descriptor)
      -- The record goes in before the name: one rename makes a whole
      -- picture appear, to any session that looks.
      if code == 1 and not libuv.fs_rename(drawn, masks .. "/" .. name .. ".png") then
        code = 3
      end
    end
    results[#results + 1] = index .. " " .. code
  end
  return table.concat(results, "\n")
end

---@param items MdRenderMathTexItem[]
---@param job_directory string
---@param geometry MdRenderMathTexGeometry
---@param good { item: MdRenderMathTexItem, page_number: integer, page: table }[]
---@param on_done fun()
local function rasterise(items, job_directory, geometry, good, on_done)
  local look = items[1].look
  ---@type { first: integer, last: integer, pages: string, is_settled: boolean }[]
  local chunks = {}
  local first = 1
  for chunk_index, size in ipairs(plan_raster_chunks(#good)) do
    local page_numbers = {}
    for index = first, first + size - 1 do
      page_numbers[#page_numbers + 1] = good[index].page_number
    end
    chunks[chunk_index] = {
      first = first,
      last = first + size - 1,
      pages = table.concat(page_numbers, ","),
      is_settled = false,
    }
    first = first + size
  end
  local is_parallel = #chunks > 1
  -- stylua: ignore
  local command = { "mutool", "draw", "-q", "-r", geometry.dpi, "-c", "gray", "-o", "p-%d.png", "job.pdf" }
  if is_parallel then
    -- One shell starts every mutool (`"$@"` is the command above) and reports
    -- each as it ends, in order. A TERM (the time limit) is passed on to them.
    local script = { "pids=", "trap 'kill $pids 2>/dev/null; exit 143' TERM INT" }
    for chunk_index, chunk in ipairs(chunks) do
      script[#script + 1] =
        string.format('"$@" %s & p%d=$!; pids="$pids $p%d"', chunk.pages, chunk_index, chunk_index)
    end
    for chunk_index in ipairs(chunks) do
      script[#script + 1] =
        string.format('wait $p%d; echo "MDMATH RASTER %d $?"', chunk_index, chunk_index)
    end
    command = vim.list_extend({ "/bin/sh", "-c", table.concat(script, "\n"), "sh" }, command)
  else
    -- Nothing to run side by side: mutool itself, no shell in between.
    command[#command + 1] = chunks[1].pages
  end

  local remaining = #chunks
  local function chunk_done()
    remaining = remaining - 1
    if remaining == 0 then
      on_done()
    end
  end

  ---@param chunk { first: integer, last: integer, is_settled: boolean }
  ---@param code integer mutool's exit code; 127/126: it could not be run
  local function settle_chunk(chunk, code)
    if chunk.is_settled then
      return
    end
    chunk.is_settled = true
    local entries = vim.list_slice(good, chunk.first, chunk.last)
    local chunk_items = vim.tbl_map(function(entry)
      return entry.item
    end, entries)
    if code ~= 0 then
      -- Not this TeX's fault: nil, not false.
      abandon_all(chunk_items)
      if code == 126 or code == 127 then
        fail_environment("mutool did not start")
      end
      return chunk_done()
    end
    local lines = {}
    for index, entry in ipairs(entries) do
      lines[index] = string.format(
        "%d %d %d %d %s %s",
        index,
        entry.page_number,
        entry.page.columns,
        entry.page.rows,
        entry.page.scale,
        vim.fs.basename(entry.item.file_stem)
      )
    end
    vim.uv
      .new_work(read_back_work, function(results)
        vim.schedule(function()
          guarded(function()
            for index, result_code in (results or ""):gmatch("(%d+) (%d)") do
              local entry = entries[tonumber(index)]
              if result_code == "1" then
                settle(entry.item, {
                  path = entry.item.file_stem .. ".png",
                  columns = entry.page.columns,
                  rows = entry.page.rows,
                  scale = tonumber(entry.page.scale) --[[@as number]],
                })
              elseif result_code == "2" then
                settle(entry.item, false, "mutool drew something else than a mask of its cells")
              else
                release(entry.item)
              end
            end
            -- Whatever the worker did not answer for: `release` is once per
            -- item, so this does nothing to those settled above.
            abandon_all(chunk_items)
          end, chunk_items)
          chunk_done()
        end)
      end)
      :queue(
        job_directory,
        masks_directory,
        look.cell_width,
        look.cell_height,
        table.concat(lines, "\n")
      )
  end

  ---@param output string
  local function settle_reported(output)
    for chunk_index, code in output:gmatch("MDMATH RASTER (%d+) (%d+)\n") do
      local chunk = chunks[tonumber(chunk_index)]
      if chunk then
        settle_chunk(chunk, tonumber(code) --[[@as integer]])
      end
    end
  end

  local reported = ""
  --- `on_done` is `finish` of the batch: once only, whoever calls it.
  ---@param work fun()
  local function guarded_or_done(work)
    if not guarded(work, items) then
      on_done()
    end
  end
  run_process(command, { cwd = job_directory, timeout = timeout_milliseconds }, function(result)
    guarded_or_done(function()
      if not is_parallel then
        local code = result.code
        if not result.has_started then
          code = 127
        elseif result.was_killed then
          code = -1
        end
        settle_chunk(chunks[1], code)
      else
        if not result.was_killed then
          settle_reported(result.stdout)
        end
        -- The shell itself did not start: the same end as a mutool that did
        -- not (127), not a silent nil.
        local code = result.has_started and -1 or 127
        for _, chunk in ipairs(chunks) do
          settle_chunk(chunk, code)
        end
      end
    end)
  end, is_parallel and function(data)
    reported = reported .. data
    if data:find("\n", 1, true) then
      local so_far = reported
      vim.schedule(function()
        guarded_or_done(function()
          settle_reported(so_far)
        end)
      end)
    end
  end or nil, is_parallel)
end

---@param result MdRenderMathTexRun
---@return string
local function kill_reason(result)
  if result.was_over_cap then
    return "killed: printed more than " .. MAXIMUM_OUTPUT_BYTES .. " bytes"
  end
  return "killed: ran longer than " .. timeout_milliseconds .. " ms"
end

---@param items MdRenderMathTexItem[]
---@param format_path string
---@param on_done fun()
local function run_batch(items, format_path, on_done)
  local geometry = compute_geometry(items[1].look.cell_height)
  local job_text = write_job(items, geometry)
  local slot = standby
  if slot and slot.format_path ~= format_path then
    stop_standby()
    slot = nil
  end
  local job_directory
  if slot then
    job_directory = slot.directory
  else
    job_directory = make_run_directory("job")
    if not job_directory or not write_file(job_directory .. "/job.tex", job_text) then
      if job_directory then
        remove_directory_later(job_directory)
      end
      fail_environment("cannot write in " .. run_directory, items)
      return on_done()
    end
    -- Everything needed is on stdout. A transcript that only a loop could
    -- make large is not written at all; without the link the cap bounds it.
    vim.uv.fs_symlink("/dev/null", job_directory .. "/job.log")
  end
  local is_finished = false
  local function finish()
    if is_finished then
      return
    end
    is_finished = true
    remove_directory_later(job_directory)
    on_done()
  end

  ---@param result MdRenderMathTexRun
  local function handle_result(result)
    local report = parse_tex_output(result.stdout)
    local outcomes, last_begun = report.outcomes, report.last_begun

    if not result.has_started then
      fail_environment("pdftex did not start: " .. first_error_line(result.stderr), items)
      return finish()
    end

    if not vim.uv.fs_stat(job_directory .. "/job.log") then
      -- Its directory went away under it (the cache was cleared, another
      -- session's sweep): pdfTeX "can't write on file job.pdf", which is not
      -- this TeX's fault (and a printed line would be forgeable; the missing
      -- directory is not). Once more in a directory made anew; twice is the
      -- environment.
      for _, item in ipairs(items) do
        if item.has_failed_to_write then
          fail_environment("pdfTeX cannot write in " .. run_directory, items)
          return finish()
        end
        item.has_failed_to_write = true
      end
      put_back(items)
      return finish()
    end

    if not last_begun and not result.was_killed then
      if slot then
        -- The standby never read the job (it died waiting): that says nothing
        -- about the format. These run again, as plain spawns from now on.
        standby_off_reason = "a standby never read its job"
        put_back(items)
      elseif not vim.uv.fs_stat(format_path .. ".fmt") then
        -- Gone (another session's maintenance, a cleared cache), not damaged:
        -- built again without counting against it.
        format.path = nil
        put_back(items)
      elseif format.rebuilds_left > 0 then
        -- pdftex ran and not one equation began: the format or pdftex itself
        -- is at fault. A damaged format is built again, once a session.
        format.rebuilds_left = format.rebuilds_left - 1
        vim.uv.fs_unlink(format_path .. ".fmt")
        format.path = nil
        put_back(items)
      else
        fail_environment(
          "pdftex failed: " .. first_error_line(result.stdout .. result.stderr),
          items
        )
      end
      return finish()
    end

    if result.was_killed then
      -- stdout is flushed after each BEGIN, so the last one is the equation
      -- the run was killed in (time, CPU or output). It fails alone; the
      -- rest run again. Bisecting instead would cost one timeout per
      -- halving, with every other request waiting behind it.
      -- A forged `MDMATH BEGIN <n>` may name no item of this run.
      if last_begun and items[last_begun] and report.is_in_order then
        local culprit = table.remove(items, last_begun)
        settle(culprit, false, kill_reason(result))
        put_back(items)
      elseif last_begun and #items == 1 then
        settle(items[1], false, kill_reason(result))
      elseif last_begun then
        -- Lines of an equation's own making: which one ran away is unknown.
        -- Each runs again alone.
        for _, item in ipairs(items) do
          item.is_isolated = true
        end
        put_back(items)
      else
        -- Nothing began (the standby was killed from outside, pdfTeX hung
        -- before it read the job): that is not this TeX's fault.
        abandon_all(items)
      end
      return finish()
    end

    if
      not report.is_in_order
      or (report.pages_written and report.pages_written ~= report.page_lines)
    then
      -- Pages shipped, or PAGE lines printed, by something other than the
      -- template: which page belongs to which equation is unknown. Each
      -- runs again alone; alone, it can only spoil its own picture.
      if #items == 1 then
        settle(items[1], false, "it shipped a page of its own")
      else
        for _, item in ipairs(items) do
          item.is_isolated = true
        end
        put_back(items)
      end
      return finish()
    end

    local good, again = {}, {}
    local page_number = 0
    local has_progressed = false
    local is_complete = report.pages_written ~= nil and (result.code == 0 or result.code == 1)
    for index, item in ipairs(items) do
      local outcome = outcomes[index]
      if outcome and outcome.page then
        -- Every PAGE line is one PDF page, in order.
        page_number = page_number + 1
      end
      if not outcome or outcome.is_skipped then
        -- Never reached, or began where an earlier equation left TeX broken.
        again[#again + 1] = item
      elseif outcome.has_error or outcome.is_dirty or not outcome.page then
        settle(item, false, outcome.error or "TeX stopped in it")
        has_progressed = true
      elseif not is_complete then
        -- Fine itself, but the run died later and took the PDF with it.
        again[#again + 1] = item
      elseif outcome.page.columns > MAXIMUM_COLUMNS or outcome.page.rows > MAXIMUM_ROWS then
        settle(
          item,
          false,
          string.format(
            "%d x %d cells, more than %d x %d",
            outcome.page.columns,
            outcome.page.rows,
            MAXIMUM_COLUMNS,
            MAXIMUM_ROWS
          )
        )
        has_progressed = true
      else
        good[#good + 1] = { item = item, page_number = page_number, page = outcome.page }
        has_progressed = true
      end
    end
    if not has_progressed and #again > 0 then
      -- A fatal error with nobody to blame (see the top of the file). Alone,
      -- it is the culprit; otherwise each half runs apart: the clean half
      -- becomes pictures, the other is halved again. log2(N) runs.
      if #again == 1 then
        settle(
          again[1],
          false,
          result.stdout:match("!pdfTeX error: ([^\n]*)") or "pdfTeX wrote no PDF"
        )
        again = {}
      else
        local first_half, second_half = {}, {}
        for index, item in ipairs(again) do
          item.group = index <= math.ceil(#again / 2) and first_half or second_half
        end
      end
    end
    put_back(again)
    if #good == 0 then
      return finish()
    end
    rasterise(items, job_directory, geometry, good, finish)
  end

  ---@param result MdRenderMathTexRun
  local function on_tex_exit(result)
    if not guarded(function()
      handle_result(result)
    end, items) then
      finish()
    end
  end

  if slot then
    -- The standby's directory is the job's from now on.
    clear_standby()
    -- The wall-clock limit counts from now, not from the spawn.
    local timer = assert(vim.uv.new_timer())
    timer:start(timeout_milliseconds, 0, function()
      timer:close()
      vim.schedule(function()
        if not slot.has_exited then
          slot.process:kill("sigkill")
        end
      end)
    end)
    slot.on_exit = function(result)
      -- Not left to live its 2 s, holding this batch's items.
      if not timer:is_closing() then
        timer:close()
      end
      on_tex_exit(result)
    end
    -- Still loading its format, it gets the job the moment it is ready,
    -- sooner than a plain spawn would get that far.
    write_when_ready(slot, job_text)
    -- The next batch finds a standby too.
    if not is_standby_scheduled then
      is_standby_scheduled = true
      vim.schedule(function()
        is_standby_scheduled = false
        spawn_standby(format_path)
      end)
    end
  else
    start_tex(job_directory, format_path, false, on_tex_exit)
  end
end

-- -----------------------------------------------------------------------------
-- Scheduling: one batch at a time; what arrives meanwhile waits for the next
-- -----------------------------------------------------------------------------

local function start_next_run()
  is_run_scheduled = false
  if is_running or is_leaving or #queue == 0 then
    return
  end
  if not M.is_available() then
    return abandon_queue()
  end
  if not make_directories() then
    return fail_environment("cannot create directories in " .. cache_directory)
  end
  is_running = true
  local is_done = false
  local function on_done()
    if is_done then
      return
    end
    is_done = true
    is_running = false
    if not is_run_scheduled and #queue > 0 then
      is_run_scheduled = true
      vim.schedule(start_next_run)
    end
    if not standby then
      note_need()
    end
  end
  prepare_format(function(format_path)
    if not format_path then
      -- The build failed (fail_environment has abandoned what waited), or
      -- the preamble changed while it ran: what is queued goes on with the
      -- new one (`on_done` starts the next run).
      return on_done()
    end
    -- One look and one group per run: the look sets the page geometry and
    -- MuPDF's dpi. An isolated equation runs alone, and no other run takes
    -- one in.
    local first = queue[1]
    if not first then
      return on_done()
    end
    local batch, rest = { first }, {}
    for index = 2, #queue do
      local item = queue[index]
      if
        not first.is_isolated
        and not item.is_isolated
        and item.look_signature == first.look_signature
        and item.group == first.group
        and #batch < MAXIMUM_BATCH
      then
        batch[#batch + 1] = item
      else
        rest[#rest + 1] = item
      end
    end
    queue = rest
    if not guarded(function()
      run_batch(batch, format_path, on_done)
    end, batch) then
      on_done()
    end
  end)
end

-- -----------------------------------------------------------------------------
-- Maintenance: on a worker thread, once a session
-- -----------------------------------------------------------------------------

--- Runs on a libuv worker (`vim.uv.new_work`), in a Lua state of its own: no
--- upvalues, so `remove_tree_work` comes as bytecode. Returns
--- "<pictures> <bytes> <pruned> <old files> <run directories>".
---@return string
local function maintenance_work(
  root,
  keep_format,
  budget,
  minimum_age,
  stale_age,
  now,
  touched,
  should_prune,
  remove_tree_code
)
  local libuv = vim.uv
  local remove_tree = loadstring(remove_tree_code)
  --- `for name, kind in entries_of(directory)`; nothing when it is not there.
  local function entries_of(directory)
    local scanner = libuv.fs_scandir(directory)
    return function()
      if scanner then
        return libuv.fs_scandir_next(scanner)
      end
    end
  end
  local function is_older_than(path, age)
    local stat = libuv.fs_stat(path)
    return stat and now - stat.mtime.sec > age
  end
  --- A run directory is `<prefix>-<pid>-<counter>`. One whose Neovim still
  --- runs is never stale (a standby may be parked for long). Any other goes
  --- when it is old (another container on the same cache has other pids),
  --- and a pdfTeX still waiting in `open` on its FIFO (a standby that
  --- outlived its Neovim) is ended at once, by a writer that opens and
  --- closes: once the FIFO is unlinked nothing could end it.
  local function is_stale(path, name)
    local pid = tonumber(name:match("%-(%d+)%-%d+$"))
    if pid then
      local is_signalled, problem = libuv.kill(pid, 0)
      if is_signalled == 0 or (problem and problem:find("EPERM", 1, true)) then
        return false
      end
    end
    local writer =
      libuv.fs_open(path .. "/job.tex", libuv.constants.O_WRONLY + libuv.constants.O_NONBLOCK, 0)
    if writer then
      libuv.fs_close(writer)
    end
    return is_older_than(path, stale_age)
  end
  for path in touched:gmatch("[^\n]+") do
    libuv.fs_utime(path, now, now)
  end
  local old_files, stale_directories = 0, 0
  -- The cache directory itself: older layouts (pictures and `.txt` sidecars
  -- beside the format), other formats, run directories of older layouts.
  for name, kind in entries_of(root) do
    local path = root .. "/" .. name
    if kind == "file" and (name:sub(-4) == ".png" or name:sub(-4) == ".txt") then
      libuv.fs_unlink(path)
      old_files = old_files + 1
    elseif
      kind == "file"
      and keep_format ~= ""
      and name:match("^format%-.*%.fmt$")
      and name ~= keep_format
      -- Another session with another preamble uses its own format: kept
      -- while it is younger than a day (each session touches its own).
      and is_older_than(path, minimum_age)
    then
      libuv.fs_unlink(path)
      old_files = old_files + 1
    elseif
      kind == "directory"
      and (name:match("^job%-") or name:match("^format%-build%-"))
      and is_stale(path, name)
    then
      remove_tree(path)
      stale_directories = stale_directories + 1
    end
  end
  for name, kind in entries_of(root .. "/run") do
    if kind == "directory" and is_stale(root .. "/run/" .. name, name) then
      remove_tree(root .. "/run/" .. name)
      stale_directories = stale_directories + 1
    end
  end
  local pictures, total, pruned = 0, 0, 0
  if should_prune then
    local entries = {}
    for name, kind in entries_of(root .. "/masks") do
      if kind == "file" then
        local stat = libuv.fs_stat(root .. "/masks/" .. name)
        if stat then
          local bytes = stat.blocks * 512
          total = total + bytes
          entries[#entries + 1] = { name, stat.mtime.sec, bytes }
        end
      end
    end
    pictures = #entries
    if total > budget then
      table.sort(entries, function(left, right)
        return left[2] < right[2]
      end)
      for _, entry in ipairs(entries) do
        if total <= budget * 0.8 or now - entry[2] < minimum_age then
          break
        end
        if libuv.fs_unlink(root .. "/masks/" .. entry[1]) then
          total = total - entry[3]
          pruned = pruned + 1
        end
      end
    end
  end
  return table.concat({ pictures, total, pruned, old_files, stale_directories }, " ")
end

--- Touch what this session read from disk, remove older layouts and stale
--- run directories, and (once a session) prune the pictures to the budget.
--- On a worker thread; `on_done(summary)` on the main loop. The once-a-session
--- timer calls it; the spec calls it directly.
---@param on_done? fun(summary: { pictures: integer, bytes: integer, pruned: integer, old_files: integer, stale_directories: integer })
function M.maintain(on_done)
  if not cache_directory then
    M.setup()
  end
  local paths = vim.tbl_keys(used_paths)
  if format.path then
    -- So that another session's maintenance sees it in use.
    paths[#paths + 1] = format.path .. ".fmt"
  end
  local touched = table.concat(paths, "\n")
  used_paths = {}
  used_path_count = 0
  local should_prune = not has_pruned
  has_pruned = true
  local keep_format = format_name()
  vim.uv
    .new_work(maintenance_work, function(summary)
      if not on_done then
        return
      end
      local pictures, bytes, pruned, old_files, stale_directories = (summary or ""):match(
        "^(%d+) (%d+) (%d+) (%d+) (%d+)$"
      )
      vim.schedule(function()
        on_done({
          pictures = tonumber(pictures) or 0,
          bytes = tonumber(bytes) or 0,
          pruned = tonumber(pruned) or 0,
          old_files = tonumber(old_files) or 0,
          stale_directories = tonumber(stale_directories) or 0,
        })
      end)
    end)
    :queue(
      cache_directory,
      keep_format and (keep_format .. ".fmt") or "",
      disk_budget_bytes,
      PRUNE_MINIMUM_AGE_SECONDS,
      STALE_DIRECTORY_SECONDS,
      os.time(),
      touched,
      should_prune,
      string.dump(remove_tree_work)
    )
end

--- Once a session, and again later only to touch what was read since.
local function schedule_maintenance()
  if is_maintenance_scheduled or (has_pruned and used_path_count == 0) then
    return
  end
  is_maintenance_scheduled = true
  vim.defer_fn(function()
    is_maintenance_scheduled = false
    M.maintain()
  end, MAINTENANCE_DELAY_MILLISECONDS)
end

-- -----------------------------------------------------------------------------
-- Public
-- -----------------------------------------------------------------------------

--- Read the user preamble again; when the template changed, nothing made
--- from the old one is used any more: the format, the standby and what is
--- remembered go, and what is queued is keyed anew (made with the new format,
--- it must not be stored under the old key). What a running batch makes is
--- stored under the old key, which is right, and not remembered (`settle`).
local function reconfigure_template()
  local previous_hash = template_hash
  if not configure_template() then
    environment_failure = environment_failure
      or ("cannot read the preamble " .. tostring(user_preamble_path))
  end
  if previous_hash == nil or template_hash == previous_hash then
    return
  end
  template_generation = template_generation + 1
  format.name, format.path = nil, nil
  settled, settled_picture_count = {}, 0
  previous_pictures = {}
  forget_all_absent()
  failure_reasons = {}
  stop_standby()
  for _, item in ipairs(queue) do
    rekey(item)
  end
end

--- Where pictures, the format and run directories live, and the user
--- preamble (`vim.g.md_render_math_preamble`, read here and on `retry`; a
--- changed one is a new format and new pictures). Idempotent; a different
--- directory takes effect for what is asked from then on.
--- `standby_idle_milliseconds`, `disk_budget_bytes`,
--- `remembered_picture_limit` and `timeout_milliseconds` exist for the spec.
---@param options? { cache_directory?: string, standby_idle_milliseconds?: integer, disk_budget_bytes?: integer, remembered_picture_limit?: integer, timeout_milliseconds?: integer }
function M.setup(options)
  options = options or {}
  local directory = options.cache_directory
    or cache_directory
    or (vim.fn.stdpath("cache") .. "/md-render-math")
  if directory ~= cache_directory then
    cache_directory = directory
    masks_directory = directory .. "/masks"
    run_directory = directory .. "/run"
  end
  standby_idle_milliseconds = options.standby_idle_milliseconds or standby_idle_milliseconds
  disk_budget_bytes = options.disk_budget_bytes or disk_budget_bytes
  remembered_picture_limit = options.remembered_picture_limit or remembered_picture_limit
  timeout_milliseconds = options.timeout_milliseconds or timeout_milliseconds
  reconfigure_template()
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("andrew_md_render_math_tex", { clear = true }),
    desc = "md-render math: stop TeX and mutool, remove their directories",
    callback = function()
      is_leaving = true
      for process, is_group in pairs(running_processes) do
        if is_group then
          -- The parallel mutools too, or they write on into what is removed.
          vim.uv.kill(-process.pid, "sigkill")
        end
        process:kill("sigkill")
      end
      for live_directory in pairs(live_directories) do
        -- Not `delete()`: it prints E484 when a worker is removing the same
        -- directory at this moment.
        remove_tree_work(live_directory)
      end
    end,
  })
end

--- pdftex and mutool are installed, and nothing has failed to run since the
--- last `retry`. No I/O after the first call.
---@return boolean
function M.is_available()
  if environment_failure then
    return false
  end
  if are_programs_installed == nil then
    pdftex_path = vim.fn.exepath("pdftex")
    mutool_path = vim.fn.exepath("mutool")
    are_programs_installed = pdftex_path ~= "" and mutool_path ~= ""
  end
  return are_programs_installed
end

--- The picture of an equation in a look: a picture, `false` (this TeX does
--- not compile; `failure_of` says why) or nil (not made yet, or it cannot be
--- made right now). Spawns nothing; a memory hit does no I/O.
---@param equation MdRenderMathEquation
---@param look MdRenderMathLook
---@return MdRenderMathPicture|false|nil
function M.lookup(equation, look)
  local memory_key, _, tex = identify(equation, look)
  local known = settled[memory_key]
  if known ~= nil then
    return known
  end
  known = recall_picture(memory_key)
  if known then
    return known
  end
  if pending[memory_key] or is_absent_on_disk[memory_key] then
    note_need()
    return nil
  end
  if tex == "" or not has_balanced_braces(tex) then
    -- Half-typed (`\frac{`, `x_{`) or nothing: no run needed to know, and
    -- nothing worth remembering (one key per keystroke otherwise).
    return false
  end
  if not cache_directory then
    M.setup()
  end
  local file_stem = file_stem_of(equation.kind, tex, look)
  local picture = read_picture_from_disk(file_stem)
  schedule_maintenance()
  if picture then
    remember_picture(memory_key, picture)
    return picture
  end
  remember_absent(memory_key, file_stem)
  note_need()
  return nil
end

--- Why `lookup` answers false; nil when it does not.
---@param equation MdRenderMathEquation
---@param look MdRenderMathLook
---@return string?
function M.failure_of(equation, look)
  local memory_key, _, tex = identify(equation, look)
  if tex == "" then
    return "empty equation"
  end
  if not has_balanced_braces(tex) then
    return "unbalanced braces"
  end
  if settled[memory_key] == false then
    return failure_reasons[memory_key]
  end
  return nil
end

--- Its file is gone (pruned, cache cleared): the next lookup looks on disk
--- again, and it can be requested again.
---@param equation MdRenderMathEquation
---@param look MdRenderMathLook
function M.forget(equation, look)
  local memory_key = identify(equation, look)
  if settled[memory_key] then
    settled_picture_count = settled_picture_count - 1
  end
  settled[memory_key] = nil
  previous_pictures[memory_key] = nil
  failure_reasons[memory_key] = nil
  forget_absent(memory_key)
end

--- Forget every failure, of TeX and of the environment, and read the user
--- preamble again (a changed one is a new format and new pictures).
function M.retry()
  for memory_key, value in pairs(settled) do
    if value == false then
      settled[memory_key] = nil
    end
  end
  failure_reasons = {}
  forget_all_absent()
  environment_failure = nil
  has_reported = {}
  are_programs_installed = nil
  standby_off_reason = nil
  setpriv_path = nil
  format.rebuilds_left = 1
  -- pdftex may have been upgraded: named again from its binary.
  format.name, format.path = nil, nil
  if not cache_directory then
    M.setup()
  else
    reconfigure_template()
  end
end

--- For `:MdRenderMath status`.
---@return { is_available: boolean, reason: string?, pdftex: string?, mutool: string?, format: string?, cache_directory: string, preamble: string?, standby_off: string?, remembered: { pictures: integer, absent: integer } }
function M.status()
  if not cache_directory then
    M.setup()
  end
  local is_available = M.is_available()
  local reason = environment_failure
  if not reason and not is_available then
    reason = (pdftex_path == "" and "pdftex" or "mutool") .. " is not installed"
  end
  return {
    is_available = is_available,
    reason = reason,
    pdftex = pdftex_path ~= "" and pdftex_path or nil,
    mutool = mutool_path ~= "" and mutool_path or nil,
    format = format.path and (format.path .. ".fmt") or nil,
    cache_directory = cache_directory,
    preamble = user_preamble_path,
    -- Why batches run as plain spawns (~35 ms more each); nil: they need not.
    standby_off = standby_off_reason or (not find_setpriv() and "setpriv is not installed" or nil),
    -- What memory holds, to show it stays bounded.
    remembered = {
      pictures = settled_picture_count + vim.tbl_count(previous_pictures),
      absent = absent_count,
    },
  }
end

--- Make the pictures `lookup` has none of yet. Requests are served in arrival
--- order; `on_settled` runs once, on the main loop and after this returns,
--- when each equation of this request is a picture, a failure, or could not
--- be made.
---@param equations MdRenderMathEquation[]
---@param look MdRenderMathLook
---@param on_settled fun()
function M.request(equations, look, on_settled)
  ---@type MdRenderMathTexWaiter
  local waiter = { remaining = 0, on_settled = on_settled }
  if not M.is_available() then
    vim.schedule(on_settled)
    return
  end
  local is_waited_for = {}
  for _, equation in ipairs(equations) do
    if M.lookup(equation, look) == nil then
      local memory_key, look_signature, tex = identify(equation, look)
      if not is_waited_for[memory_key] then
        is_waited_for[memory_key] = true
        local item = pending[memory_key]
        if not item then
          item = {
            memory_key = memory_key,
            kind = equation.kind,
            tex = tex,
            look = { cell_width = look.cell_width, cell_height = look.cell_height },
            look_signature = look_signature,
            file_stem = is_absent_on_disk[memory_key] or file_stem_of(equation.kind, tex, look),
            waiters = {},
            is_isolated = needs_own_run(tex),
            generation = template_generation,
          }
          pending[memory_key] = item
          queue[#queue + 1] = item
        end
        item.waiters[#item.waiters + 1] = waiter
        waiter.remaining = waiter.remaining + 1
      end
    end
  end
  if waiter.remaining == 0 then
    vim.schedule(on_settled)
    return
  end
  -- An idle maker starts in this very call, not in the next turn of the
  -- event loop, which in a view being opened comes only after md-render has
  -- made its window (13-26 ms later, Latency L4). A busy one takes what is
  -- queued when its batch is done.
  if not is_running and not is_run_scheduled then
    start_next_run()
  end
end

return M
