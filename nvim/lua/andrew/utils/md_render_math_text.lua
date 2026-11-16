-- =============================================================================
-- md-render math: TeX as Unicode text
-- =============================================================================
-- What md-render's view shows for a `$...$` or `$$` equation that has no
-- picture: while the picture is being made, without terminal support or
-- pdftex, with `vim.g.md_render_math = "text"` (the full list is at the top of
-- andrew/utils/md_render_math.lua). md-render itself shows the TeX source,
-- coloured (markdown.lua:1311-1349 inline, content_builder.lua:2557-2565
-- blocks); md_render_math.lua puts what this module returns in its place.
--
--   inline(tex)  -> one row: `E_a^{th}` -> `Eₐᵗʰ`, `\frac{3V}{4\pi}` -> `3V/4π`
--   display(tex) -> rows: stacked fractions and binomials, limits under `∑`,
--                   matrices and `cases` with tall brackets, `aligned` and
--                   the top-level amsmath environments (`align`, `gather`,
--                   `multline`, `alignat{n}`, `eqnarray`, ...) lined up on
--                   `&`, `\tag{1}` as `(1)` at the right of its row, braces
--                   and `\boxed` frames of box-drawing characters
--
-- It is not typesetting: no italics, no sizes, an inline fraction is `a/b`.
-- One row has no room for a frame or a brace: there `\boxed{x}` is `x`,
-- `\underbrace{x}_n` is `x⏟ₙ`, `\xrightarrow{k}` is `─k→`, `\binom{n}{k}`
-- is `C(n, k)`. What it does promise:
--
--   * It never raises, and never takes long. Half-typed TeX (`\frac{`, `x_{`)
--     is drawn as far as it goes; whatever does trip the parser, nests more
--     than MAXIMUM_NESTING deep or is longer than MAXIMUM_TEX_LENGTH comes
--     back as the TeX itself.
--   * Nothing is dropped silently: a command it does not know stays `\name`,
--     followed by its braced arguments.
--   * A sub/superscript is drawn with Unicode's sub/superscript characters
--     only when EVERY character of it has one (there is no subscript b c d f
--     g q w y z, no subscript capital, no superscript q C F Q S X Y Z, no `/`
--     either way). Otherwise it keeps a linear form: `N_bulk`, `2^(5/8)`,
--     `z_(rear_surface)`, never `N_bᵤₗₖ`. One script that has to be linear
--     makes every other script of its kind in the same equation linear too,
--     so `L_x \times L_y` reads `L_x × L_y`, not `Lₓ × L_y`.
--
-- Fonts (JetBrainsMono Nerd Font 3.x, checked against its cmap): of the
-- script characters drawn here the font has only the digits ⁰-⁹ ₀-₉ and
-- ⁺ ⁼. Kitty takes every other one from a fallback font, at that font's weight
-- and height: ⁻ ⁽ ⁾ (U+207B, U+207D-207E), ₊ ₋ ₌ ₍ ₎ (U+208A-208E), the
-- subscript letters (U+2090-209C, U+1D62-1D6A, U+2C7C), the superscript
-- letters and Greek (U+02B0-02B8, U+02E1-02E3, U+2071, U+207F, U+1D2C-1D61,
-- U+1D9C-1DBF, U+2C7D). Same for the bold, script and fraktur letters
-- (U+1D400-1D7FF; double-struck is in the font), the combining marks of
-- `\vec`, `\overline`, `\underline` and `\bcancel` (U+20D7, U+0305, U+0332,
-- U+20E5), the braces ⏟ ⏞ of one row (U+23DF, U+23DE), and among the
-- symbols ϵ ∗ ∝ ⟹ ⟺ ∬ ∮ ℏ ∠ ⅓ ⅛. The all-or-nothing rule above is
-- what keeps one script from changing font halfway through a word.
--
-- Pure Lua: the only Neovim function used is nvim_strwidth, to line up the
-- rows of a display block in the cells the view will give them. Pinned by
-- tests/md_render_math_text_spec.lua.

local M = {}

-- =============================================================================
-- Unicode helpers
-- =============================================================================

local UTF8_CHARACTER_PATTERN = "[%z\1-\127\194-\244][\128-\191]*"
local UTF8_CHARACTER_AT_START = "^" .. UTF8_CHARACTER_PATTERN
local REPLACEMENT_CHARACTER = "\239\191\189"

---@param code_point integer
---@return string
local function encode_code_point(code_point)
  if code_point < 0x80 then
    return string.char(code_point)
  elseif code_point < 0x800 then
    return string.char(0xC0 + math.floor(code_point / 0x40), 0x80 + code_point % 0x40)
  elseif code_point < 0x10000 then
    return string.char(
      0xE0 + math.floor(code_point / 0x1000),
      0x80 + math.floor(code_point / 0x40) % 0x40,
      0x80 + code_point % 0x40
    )
  end
  return string.char(
    0xF0 + math.floor(code_point / 0x40000),
    0x80 + math.floor(code_point / 0x1000) % 0x40,
    0x80 + math.floor(code_point / 0x40) % 0x40,
    0x80 + code_point % 0x40
  )
end

--- Code point of the first character of `character`.
---@param character string
---@return integer
local function decode_code_point(character)
  local first, second, third, fourth = character:byte(1, 4)
  if first < 0x80 then
    return first
  elseif first < 0xE0 then
    return (first - 0xC0) * 0x40 + ((second or 0x80) - 0x80)
  elseif first < 0xF0 then
    return (first - 0xE0) * 0x1000 + ((second or 0x80) - 0x80) * 0x40 + ((third or 0x80) - 0x80)
  end
  return (first - 0xF0) * 0x40000
    + ((second or 0x80) - 0x80) * 0x1000
    + ((third or 0x80) - 0x80) * 0x40
    + ((fourth or 0x80) - 0x80)
end

---@param text string
---@return string[]
local function split_characters(text)
  local characters = {}
  for character in text:gmatch(UTF8_CHARACTER_PATTERN) do
    characters[#characters + 1] = character
  end
  return characters
end

---@param code_point integer
---@return boolean
local function is_combining_mark(code_point)
  return (code_point >= 0x300 and code_point <= 0x36F)
    or (code_point >= 0x20D0 and code_point <= 0x20FF)
end

--- A letter or digit a reader would run into the character before it: ASCII,
--- Greek, the letterlike block (ℝ, ℏ) and the mathematical alphabets (𝐯).
---@param character string
---@return boolean
local function is_word_character(character)
  if character:find("^%w") then
    return true
  end
  local code_point = decode_code_point(character)
  return (code_point >= 0x370 and code_point <= 0x3FF)
    or (code_point >= 0x2100 and code_point <= 0x214F)
    or (code_point >= 0x1D400 and code_point <= 0x1D7FF)
end

---@type fun(text: string): integer
local display_width = vim.api.nvim_strwidth

---@param words string
---@return table<string, true>
local function word_set(words)
  local set = {}
  for word in words:gmatch("%S+") do
    set[word] = true
  end
  return set
end

--- Pairs the characters of two equally long strings.
---@param keys string
---@param values string
---@return table<string, string>
local function character_map(keys, values)
  local key_characters, value_characters, map = split_characters(keys), split_characters(values), {}
  assert(#key_characters == #value_characters, "md_render_math_text: unequal character map")
  for index, key in ipairs(key_characters) do
    map[key] = value_characters[index]
  end
  return map
end

-- =============================================================================
-- Data
-- =============================================================================

--- Every superscript character Unicode really has. No small capitals or
--- script letters standing in for missing ones (markview.nvim's tables do
--- that): a lookalike reads as a different letter.
local SUPERSCRIPT_CHARACTERS = character_map(
  "0123456789+-−=()abcdefghijklmnoprstuvwxyzABDEGHIJKLMNOPRTUVWαβγδθιφχ",
  "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁻⁼⁽⁾ᵃᵇᶜᵈᵉᶠᵍʰⁱʲᵏˡᵐⁿᵒᵖʳˢᵗᵘᵛʷˣʸᶻᴬᴮᴰᴱᴳᴴᴵᴶᴷᴸᴹᴺᴼᴾᴿᵀᵁⱽᵂᵅᵝᵞᵟᶿᶥᵠᵡ"
)

--- Every subscript character Unicode really has.
local SUBSCRIPT_CHARACTERS = character_map(
  "0123456789+-−=()aehijklmnoprstuvxβγρφχ",
  "₀₁₂₃₄₅₆₇₈₉₊₋₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓᵦᵧᵨᵩᵪ"
)

-- stylua: ignore start

--- Superscripts that are already raised marks: `f^\prime`, `90^\circ`, `A^*`.
--- They are written as they are, and never count as a script that could not
--- be drawn.
local RAISED_MARKS = { ["′"] = "′", ["″"] = "″", ["*"] = "*", ["∗"] = "*", ["†"] = "†", ["‡"] = "‡", ["°"] = "°", ["∘"] = "°" }

local SYMBOLS = {
  -- Greek
  alpha = "α", beta = "β", gamma = "γ", delta = "δ", epsilon = "ϵ", varepsilon = "ε", zeta = "ζ",
  eta = "η", theta = "θ", vartheta = "ϑ", iota = "ι", kappa = "κ", lambda = "λ", mu = "μ", nu = "ν",
  xi = "ξ", pi = "π", varpi = "ϖ", rho = "ρ", varrho = "ϱ", sigma = "σ", varsigma = "ς", tau = "τ",
  upsilon = "υ", phi = "ϕ", varphi = "φ", chi = "χ", psi = "ψ", omega = "ω", Gamma = "Γ",
  Delta = "Δ", Theta = "Θ", Lambda = "Λ", Xi = "Ξ", Pi = "Π", Sigma = "Σ", Upsilon = "Υ", Phi = "Φ",
  Psi = "Ψ", Omega = "Ω",
  -- binary operators
  cdot = "·", times = "×", div = "÷", pm = "±", mp = "∓", ast = "∗", star = "⋆", circ = "∘",
  bullet = "∙", oplus = "⊕", ominus = "⊖", otimes = "⊗", odot = "⊙", cup = "∪", cap = "∩",
  setminus = "∖", wedge = "∧", land = "∧", vee = "∨", lor = "∨", neg = "¬", lnot = "¬",
  -- relations
  approx = "≈", sim = "∼", simeq = "≃", cong = "≅", equiv = "≡", propto = "∝", neq = "≠",
  ne = "≠", le = "≤", leq = "≤", ge = "≥", geq = "≥", leqslant = "⩽", geqslant = "⩾", ll = "≪",
  gg = "≫", lesssim = "≲", gtrsim = "≳", prec = "≺", succ = "≻", doteq = "≐", triangleq = "≜",
  coloneqq = "≔", ["in"] = "∈", notin = "∉", ni = "∋", subset = "⊂", supset = "⊃",
  subseteq = "⊆", supseteq = "⊇", perp = "⊥", parallel = "∥", mid = "∣", vdash = "⊢",
  models = "⊨",
  -- arrows
  to = "→", rightarrow = "→", leftarrow = "←", gets = "←", leftrightarrow = "↔",
  Rightarrow = "⇒", Leftarrow = "⇐", Leftrightarrow = "⇔", implies = "⟹", impliedby = "⟸",
  iff = "⟺", Longrightarrow = "⟹", Longleftrightarrow = "⟺", longrightarrow = "⟶",
  longleftarrow = "⟵", mapsto = "↦", longmapsto = "⟼", hookrightarrow = "↪", uparrow = "↑",
  downarrow = "↓", rightleftharpoons = "⇌",
  -- big operators and calculus
  sum = "∑", prod = "∏", coprod = "∐", int = "∫", iint = "∬", iiint = "∭", oint = "∮",
  bigcup = "⋃", bigcap = "⋂", bigoplus = "⨁", bigotimes = "⨂", bigwedge = "⋀", bigvee = "⋁",
  partial = "∂", nabla = "∇", infty = "∞",
  -- letterlike and miscellaneous
  hbar = "ℏ", ell = "ℓ", Re = "ℜ", Im = "ℑ", wp = "℘", aleph = "ℵ", imath = "ı", jmath = "ȷ",
  i = "ı", j = "ȷ",
  forall = "∀", exists = "∃", nexists = "∄", emptyset = "∅", varnothing = "∅", complement = "∁",
  angle = "∠", degree = "°", textdegree = "°", prime = "′", dagger = "†", dag = "†",
  ddagger = "‡", ldots = "…", dots = "…", dotsc = "…", dotsb = "⋯", cdots = "⋯", vdots = "⋮",
  ddots = "⋱", therefore = "∴", because = "∵", top = "⊤", bot = "⊥", surd = "√",
  triangle = "△", square = "□", Box = "□", diamond = "⋄", checkmark = "✓", angstrom = "Å",
  AA = "Å", colon = ":",
  -- delimiters
  langle = "⟨", rangle = "⟩", lfloor = "⌊", rfloor = "⌋", lceil = "⌈", rceil = "⌉", lbrace = "{",
  rbrace = "}", lbrack = "[", rbrack = "]", vert = "|", lvert = "|", rvert = "|", Vert = "‖",
  lVert = "‖", rVert = "‖", backslash = "\\",
}

--- `\not` followed by one of these is a character of its own.
local NEGATED_SYMBOLS = {
  ["="] = "≠", ["∈"] = "∉", ["≡"] = "≢", ["<"] = "≮", [">"] = "≯", ["≤"] = "≰", ["≥"] = "≱",
  ["∼"] = "≁", ["⊂"] = "⊄", ["∃"] = "∄",
}

--- Upright operator names, written as they are.
local OPERATOR_NAMES = word_set(
  "max min sup inf lim limsup liminf arg argmax argmin det dim ker gcd lcm deg exp log ln lg sin "
    .. "cos tan cot sec csc arcsin arccos arctan sinh cosh tanh coth Pr hom mod bmod tr Tr erf "
    .. "sgn sign"
)

--- In a display block their scripts go under and over them.
local LIMIT_OPERATORS = word_set(
  "sum prod coprod bigcup bigcap bigoplus bigotimes bigwedge bigvee max min sup inf lim limsup "
    .. "liminf argmax argmin"
)

--- Operators set apart from a letter that follows straight after them, as TeX
--- does with a thin space: `\sin\theta` is `sin θ`, `\sum_i x_i` is `∑ᵢ xᵢ`.
local SPACED_OPERATORS = word_set("sum prod coprod bigcup bigcap bigoplus bigotimes bigwedge bigvee int iint iiint oint")

--- Symbols that read as a prefix of the letter after them: the source space
--- in `\partial \rho` or `\Delta t` is dropped, giving `∂ρ`, `Δt`.
local PREFIX_SYMBOLS = word_set("partial Delta nabla delta")

--- Spacing commands, as a count of spaces (join_boxes merges neighbours).
local SPACING_WIDTHS = {
  [","] = 1, [":"] = 1, [";"] = 1, [">"] = 1, [" "] = 1, ["!"] = 0, thinspace = 1, medspace = 1,
  thickspace = 1, enspace = 1, negthinspace = 0, quad = 2, qquad = 3,
}

--- Accents, drawn as a combining mark after the character they sit on.
--- `\cancel` and `\bcancel` are strokes through it: U+0338 `/`, U+20E5 `\`.
local ACCENT_MARKS = {
  dot = 0x307, ddot = 0x308, bar = 0x304, hat = 0x302, widehat = 0x302, tilde = 0x303,
  widetilde = 0x303, vec = 0x20D7, check = 0x30C, breve = 0x306, acute = 0x301, grave = 0x300,
  mathring = 0x30A, overline = 0x305, underline = 0x332, cancel = 0x338, bcancel = 0x20E5,
}

--- Accents that span their whole argument, so every character gets the mark.
--- Any other accent over more than one character is written `hat(xy)`: a hat
--- on the first character alone would say it belongs to that one.
local SPANNING_ACCENTS = word_set("overline underline cancel bcancel")

--- The accents of prose, inside `\text{}`: `Schr\"odinger`, `\'{e}`, `\v c`.
local TEXT_ACCENT_MARKS = {
  ['"'] = encode_code_point(0x308), ["'"] = encode_code_point(0x301), ["`"] = encode_code_point(0x300),
  ["^"] = encode_code_point(0x302), ["~"] = encode_code_point(0x303), ["="] = encode_code_point(0x304),
  ["."] = encode_code_point(0x307), u = encode_code_point(0x306), v = encode_code_point(0x30C),
  H = encode_code_point(0x30B), c = encode_code_point(0x327), r = encode_code_point(0x30A),
}

--- Commands whose argument is math, written upright: the letters stay as
--- they are.
local UPRIGHT_COMMANDS = word_set("mathrm mathit mathsf mathtt mathnormal mathup")

--- Commands whose argument is prose: spaces kept, `-` stays a hyphen.
local TEXT_COMMANDS = word_set("text textrm textit textsf texttt textnormal textup mbox emph")

--- Commands that only change size or numbering, the old font switches that
--- keep letters as they are (`{\rm d}x`), and table rules: nothing to draw.
local IGNORED_COMMANDS = word_set(
  "displaystyle textstyle scriptstyle scriptscriptstyle limits nolimits nonumber notag big Big "
    .. "bigg Bigg bigl bigr Bigl Bigr biggl biggr Biggl Biggr bigm Bigm biggm Biggm strut allowbreak "
    .. "rm it sf tt hline hdashline"
)

--- Commands dropped together with their one argument: a label, a colour, an
--- `\end{name}` that no environment is waiting for.
local COMMANDS_WITHOUT_OUTPUT = word_set("label color vphantom cline end")

--- Old font switches that restyle the rest of their group: `{\bf x}`.
local FONT_SWITCHES = { bf = "bold", cal = "script" }

--- `{a \over b}`, `{n \choose k}`: everything before it in the group over
--- everything after it. The value says whether it is a binomial.
local INFIX_FRACTIONS = { over = false, choose = true }

--- `\frac{a}{b}` and its kin; the value says whether it is a binomial.
local FRACTION_COMMANDS = {
  frac = false, dfrac = false, tfrac = false, cfrac = false, binom = true, dbinom = true, tbinom = true,
}

--- Fractions Unicode has a character for, used when both sides are digits.
local VULGAR_FRACTIONS = {
  ["1/2"] = "½", ["1/3"] = "⅓", ["2/3"] = "⅔", ["1/4"] = "¼", ["3/4"] = "¾", ["1/5"] = "⅕",
  ["2/5"] = "⅖", ["3/5"] = "⅗", ["4/5"] = "⅘", ["1/6"] = "⅙", ["5/6"] = "⅚", ["1/8"] = "⅛",
  ["3/8"] = "⅜", ["5/8"] = "⅝", ["7/8"] = "⅞",
}

--- Roots with a character of their own.
local ROOT_SIGNS = { [""] = "√", ["3"] = "∛", ["4"] = "∜" }

--- Where each alphabet starts in the Mathematical Alphanumeric Symbols block,
--- and the letters that were in Unicode before it and are left out of it.
local MATH_ALPHABETS = {
  bold = { upper = 0x1D400, lower = 0x1D41A, digit = 0x1D7CE, greek_upper = 0x1D6A8, greek_lower = 0x1D6C2, older = {} },
  double_struck = {
    upper = 0x1D538, lower = 0x1D552, digit = 0x1D7D8,
    older = { C = 0x2102, H = 0x210D, N = 0x2115, P = 0x2119, Q = 0x211A, R = 0x211D, Z = 0x2124 },
  },
  script = {
    upper = 0x1D49C, lower = 0x1D4B6,
    older = { B = 0x212C, E = 0x2130, F = 0x2131, H = 0x210B, I = 0x2110, L = 0x2112, M = 0x2133, R = 0x211B, e = 0x212F, g = 0x210A, o = 0x2134 },
  },
  fraktur = { upper = 0x1D504, lower = 0x1D51E, older = { C = 0x212D, H = 0x210C, I = 0x2111, R = 0x211C, Z = 0x2128 } },
}

local FONT_COMMANDS = {
  mathbf = "bold", boldsymbol = "bold", bm = "bold", textbf = "bold", mathbb = "double_struck",
  mathcal = "script", mathscr = "script", mathfrak = "fraktur",
}

--- Pieces of a delimiter taller than one row: top, middle, bottom, and the
--- centre piece of a brace.
local TALL_DELIMITER_PIECES = {
  ["("] = { "⎛", "⎜", "⎝" }, [")"] = { "⎞", "⎟", "⎠" }, ["["] = { "⎡", "⎢", "⎣" },
  ["]"] = { "⎤", "⎥", "⎦" }, ["{"] = { "⎧", "⎪", "⎩", "⎨" }, ["}"] = { "⎫", "⎪", "⎭", "⎬" },
  ["|"] = { "│", "│", "│" }, ["‖"] = { "║", "║", "║" }, ["⌊"] = { "⎢", "⎢", "⎣" },
  ["⌋"] = { "⎥", "⎥", "⎦" }, ["⌈"] = { "⎡", "⎢", "⎢" }, ["⌉"] = { "⎤", "⎥", "⎥" },
}

local MATRIX_DELIMITERS = {
  matrix = { "", "" }, smallmatrix = { "", "" }, pmatrix = { "(", ")" }, bmatrix = { "[", "]" },
  Bmatrix = { "{", "}" }, vmatrix = { "|", "|" }, Vmatrix = { "‖", "‖" },
}

local CASES_BRACES = { cases = { "{", "" }, dcases = { "{", "" }, rcases = { "", "}" } }

local CENTRED_ENVIRONMENTS = word_set("gather gathered multline")

--- Environments with an argument after `\begin{name}` that is not content:
--- the columns of `array{lr}`, the column-pair count of `alignat{2}`.
local ENVIRONMENTS_WITH_ARGUMENT = word_set("array subarray alignat alignedat")

-- stylua: ignore end

--- Every sub/superscript character, to tell what is attached to a letter.
local SCRIPT_CHARACTER_SET = {}
for _, characters in ipairs({ SUBSCRIPT_CHARACTERS, SUPERSCRIPT_CHARACTERS }) do
  for _, script_character in pairs(characters) do
    SCRIPT_CHARACTER_SET[script_character] = true
  end
end

--- The 2-D layout gives up on anything nested deeper; the input is shown as it is.
local MAXIMUM_NESTING = 100

--- Longer TeX is shown as written. The layout is not linear in the length
--- (rows grow by concatenation, tall atoms are placed side by side again for
--- each one), and it runs on the main thread for every equation without a
--- picture; the longest of the 67 equations of /tmp/mdmath/corpus.json is 76
--- bytes. Slowest shapes found just under the cap (load 4): 46 ms for
--- `\bf x \bf x ...` (83 times) before a long tail, 36 ms for `\binom{n}{k}` repeated, 21 ms
--- for `\frac{a}{b}+` repeated, 11 ms for random soups. Not bounded by it but by
--- MAXIMUM_NESTING: 99 nested `\boxed` (600 bytes) take 110 ms.
local MAXIMUM_TEX_LENGTH = 4000

--- `alphabet name` -> character -> styled character, built once.
---@type table<string, table<string, string>>
local ALPHABET_MAPS = {}
for alphabet_name, alphabet in pairs(MATH_ALPHABETS) do
  local map = {}
  for offset = 0, 25 do
    local upper, lower = string.char(65 + offset), string.char(97 + offset)
    map[upper] = encode_code_point(alphabet.older[upper] or alphabet.upper + offset)
    map[lower] = encode_code_point(alphabet.older[lower] or alphabet.lower + offset)
  end
  for offset = 0, 9 do
    if alphabet.digit then
      map[string.char(48 + offset)] = encode_code_point(alphabet.digit + offset)
    end
  end
  for offset = 0, 24 do
    if alphabet.greek_upper and offset ~= 17 then -- U+03A2 is unassigned
      map[encode_code_point(0x391 + offset)] = encode_code_point(alphabet.greek_upper + offset)
      map[encode_code_point(0x3B1 + offset)] = encode_code_point(alphabet.greek_lower + offset)
    end
  end
  ALPHABET_MAPS[alphabet_name] = map
end

-- =============================================================================
-- Boxes: rows of text and the row the baseline is on
-- =============================================================================

---@class MdRenderMathTextBox
---@field rows string[]
---@field baseline integer
---@field needs_space_before_word? boolean an operator or a linear script: `sin θ`, `a_i b`
---@field needs_parentheses_for_script? boolean a linear fraction or root: `(a/b)²`
---@field is_linear_fraction? boolean

---@param text string
---@return MdRenderMathTextBox
local function text_box(text)
  return { rows = { text }, baseline = 1 }
end

---@param box MdRenderMathTextBox
---@return boolean
local function is_empty(box)
  return #box.rows == 1 and box.rows[1] == ""
end

--- Counted from the end: `text:match(" *$")` tries every position of `text`,
--- which makes a long equation cost the square of its length.
---@param text string
---@return integer
local function count_trailing_spaces(text)
  local index = #text
  while index > 0 and text:byte(index) == 32 do
    index = index - 1
  end
  return #text - index
end

---@param box MdRenderMathTextBox
---@return string
local function flatten(box)
  local rows = box.rows
  local text = #rows == 1 and rows[1] or table.concat(rows, " ")
  if text:byte(1) ~= 32 and text:byte(-1) ~= 32 then
    return text
  end
  return text:sub(text:find("[^ ]") or #text + 1, #text - count_trailing_spaces(text))
end

---@param box MdRenderMathTextBox
---@return integer
local function box_width(box)
  local width = 0
  for _, row in ipairs(box.rows) do
    width = math.max(width, display_width(row))
  end
  return width
end

---@param text string
---@param width integer
---@param alignment "left"|"right"|"centre"
---@return string
local function pad(text, width, alignment)
  local gap = math.max(width - display_width(text), 0)
  if alignment == "right" then
    return string.rep(" ", gap) .. text
  elseif alignment == "centre" then
    local left = math.floor(gap / 2)
    return string.rep(" ", left) .. text .. string.rep(" ", gap - left)
  end
  return text .. string.rep(" ", gap)
end

--- Boxes side by side with their baselines level, each padded to its width.
---@param boxes MdRenderMathTextBox[]
---@return MdRenderMathTextBox
local function place_side_by_side(boxes)
  local above, below, widths = 0, 0, {}
  for index, box in ipairs(boxes) do
    above = math.max(above, box.baseline - 1)
    below = math.max(below, #box.rows - box.baseline)
    widths[index] = index < #boxes and box_width(box) or 0
  end
  local rows = {}
  for offset = -above, below do
    local pieces = {}
    for index, box in ipairs(boxes) do
      pieces[index] = pad(box.rows[box.baseline + offset] or "", widths[index], "left")
    end
    rows[#rows + 1] = table.concat(pieces)
  end
  return { rows = rows, baseline = above + 1 }
end

--- `left` followed by `right`, baselines level. Spaces where they meet on the
--- baseline merge, the wider winning, so `x^2 \, dx` is not `x²  dx`; an
--- operator or a linear script is kept apart from a letter right after it.
---@param left MdRenderMathTextBox
---@param right MdRenderMathTextBox
---@return MdRenderMathTextBox
local function join_boxes(left, right)
  if is_empty(right) then
    return left
  elseif is_empty(left) then
    return right
  end
  local left_row, right_row = left.rows[left.baseline], right.rows[right.baseline]
  if #left.rows > 1 then
    left_row = pad(left_row, box_width(left), "left")
  end
  local is_one_row = #left.rows == 1 and #right.rows == 1
  local right_first = left.needs_space_before_word and right_row:match(UTF8_CHARACTER_AT_START)
  local joined
  if right_first and is_word_character(right_first) then
    joined = is_one_row and text_box(left_row .. " " .. right_row)
      or place_side_by_side({ left, text_box(" "), right })
  else
    local trailing, overlap = count_trailing_spaces(left_row), 0
    while overlap < trailing and right_row:byte(overlap + 1) == 32 do
      overlap = overlap + 1
    end
    if is_one_row then
      joined = text_box(left_row .. right_row:sub(overlap + 1))
    elseif #right.rows == 1 then
      joined = place_side_by_side({ left, text_box(right_row:sub(overlap + 1)) })
    elseif #left.rows == 1 then
      joined = place_side_by_side({ text_box(left_row:sub(1, #left_row - overlap)), right })
    else
      joined = place_side_by_side({ left, right })
    end
  end
  joined.needs_space_before_word = right.needs_space_before_word
  return joined
end

--- Boxes on top of each other, each centred; the baseline is that of
--- `boxes[baseline_index]`.
---@param boxes MdRenderMathTextBox[]
---@param baseline_index integer
---@return MdRenderMathTextBox
local function stack_vertically(boxes, baseline_index)
  local width = 0
  for _, box in ipairs(boxes) do
    width = math.max(width, box_width(box))
  end
  local rows, baseline = {}, 1
  for index, box in ipairs(boxes) do
    if index == baseline_index then
      baseline = #rows + box.baseline
    end
    for _, row in ipairs(box.rows) do
      rows[#rows + 1] = pad(row, width, "centre")
    end
  end
  return { rows = rows, baseline = baseline }
end

--- A delimiter as tall as `height` rows, from pieces where Unicode has them.
---@param delimiter string
---@param height integer
---@param baseline integer
---@return MdRenderMathTextBox
local function tall_delimiter(delimiter, height, baseline)
  if delimiter == "" then
    return text_box("")
  end
  local pieces, rows = TALL_DELIMITER_PIECES[delimiter], {}
  for row = 1, height do
    if height == 1 or not pieces then
      rows[row] = row == baseline and delimiter or string.rep(" ", display_width(delimiter))
    else
      rows[row] = row == 1 and pieces[1] or row == height and pieces[3] or pieces[2]
    end
  end
  if pieces and pieces[4] and height >= 3 then
    rows[math.ceil(height / 2)] = pieces[4]
  end
  return { rows = rows, baseline = baseline }
end

---@param opening string
---@param inner MdRenderMathTextBox
---@param closing string
---@return MdRenderMathTextBox
local function enclose(opening, inner, closing)
  if #inner.rows == 1 then
    return text_box(opening .. inner.rows[1] .. closing)
  end
  local height = #inner.rows
  return place_side_by_side({
    tall_delimiter(opening, height, inner.baseline),
    inner,
    tall_delimiter(closing, height, inner.baseline),
  })
end

--- Common left margin and trailing spaces off every row.
---@param box MdRenderMathTextBox
---@return MdRenderMathTextBox
local function trim_box(box)
  local margin = math.huge
  for _, row in ipairs(box.rows) do
    if row:find("%S") then
      margin = math.min(margin, #row:match("^ *"))
    end
  end
  local rows = {}
  for index, row in ipairs(box.rows) do
    rows[index] =
      row:sub((margin == math.huge and 0 or margin) + 1, #row - count_trailing_spaces(row))
  end
  return { rows = rows, baseline = box.baseline }
end

-- =============================================================================
-- Linear forms
-- =============================================================================

--- Characters that make a fraction side more than one term, unless they are
--- inside brackets: `(a+b)/c`, but `n(n+1)/2`.
local TERM_SEPARATORS =
  word_set("+ - * / = < > , ; − ± ∓ · × ÷ ≈ ≤ ≥ ≠ ∼ ∝ → ≡ ∗ ⋅")

---@param text string
---@return string
local function parenthesise_if_several_terms(text)
  local bracket_depth = 0
  for character in text:gmatch(UTF8_CHARACTER_PATTERN) do
    if character == "(" or character == "[" or character == "{" or character == "⟨" then
      bracket_depth = bracket_depth + 1
    elseif character == ")" or character == "]" or character == "}" or character == "⟩" then
      bracket_depth = math.max(bracket_depth - 1, 0)
    elseif bracket_depth == 0 and (character == " " or TERM_SEPARATORS[character]) then
      return "(" .. text .. ")"
    end
  end
  return text
end

--- One character with any combining marks, or digits: `√2`, `√12`, `√x̄`.
---@param text string
---@return boolean
local function is_one_symbol(text)
  if text:find("^%d+$") then
    return true
  end
  local count = 0
  for character in text:gmatch(UTF8_CHARACTER_PATTERN) do
    if not is_combining_mark(decode_code_point(character)) then
      count = count + 1
    end
  end
  return count == 1
end

--- Letters and digits only, so `_` before it cannot be misread: `N_bulk`.
---@param text string
---@return boolean
local function is_one_word(text)
  if text == "" then
    return false
  end
  for character in text:gmatch(UTF8_CHARACTER_PATTERN) do
    if not is_word_character(character) and not is_combining_mark(decode_code_point(character)) then
      return false
    end
  end
  return true
end

--- `text` in Unicode script characters, or nil when one of them has none.
---@param text string
---@param characters table<string, string>
---@return string?
local function to_script_characters(text, characters)
  local converted = {}
  if text:find(" ", 1, true) then
    text = text:gsub(" ", "")
  end
  for character in text:gmatch(UTF8_CHARACTER_PATTERN) do
    local script_character = characters[character]
    if not script_character then
      return nil
    end
    converted[#converted + 1] = script_character
  end
  return table.concat(converted)
end

-- =============================================================================
-- Tokens
-- =============================================================================

---@alias MdRenderMathTextTokenKind "command"|"symbol"|"row_break"|"space"|"open"|"close"|"subscript"|"superscript"|"column_break"|"character"

---@class MdRenderMathTextToken
---@field kind MdRenderMathTextTokenKind
---@field value? string command name, or the character
---@field has_star? boolean `\operatorname*`

-- Tokens without a value, and those of the printable ASCII characters, are
-- made once and shared: nothing writes to a token.
local SPACE_TOKEN, ROW_BREAK_TOKEN = { kind = "space" }, { kind = "row_break" }
local ESCAPED_SPACE_TOKEN = { kind = "symbol", value = " " }

--- Byte -> token of a printable ASCII character, plain and after `\`. Plain
--- `{ } _ ^ &` have a kind of their own and no value.
local ASCII_CHARACTER_TOKENS, ASCII_SYMBOL_TOKENS = {}, {}
for byte = 33, 126 do
  ASCII_CHARACTER_TOKENS[byte] = { kind = "character", value = string.char(byte) }
  ASCII_SYMBOL_TOKENS[byte] = { kind = "symbol", value = string.char(byte) }
end
-- stylua: ignore
for character, kind in pairs({ ["{"] = "open", ["}"] = "close", _ = "subscript", ["^"] = "superscript", ["&"] = "column_break" }) do
  ASCII_CHARACTER_TOKENS[character:byte()] = { kind = kind }
end

--- `%` starts a comment only in a display block: inline math has no line end
--- for it to run to, and `$50%$` should not lose its tail.
---@param tex string
---@param is_display boolean
---@return MdRenderMathTextToken[]
local function tokenize(tex, is_display)
  local tokens, count, position, length = {}, 0, 1, #tex
  while position <= length do
    local byte, token = tex:byte(position), nil
    if byte == 92 then -- `\`
      local name = tex:match("^%a+", position + 1)
      local next_byte = tex:byte(position + 1)
      if name then
        position = position + 1 + #name
        local has_star = tex:byte(position) == 42 -- `*`
        token = { kind = "command", value = name, has_star = has_star }
        position = position + (has_star and 1 or 0)
      elseif next_byte == 92 then
        token = ROW_BREAK_TOKEN
        -- `\\[4pt]`: extra space under the row, nothing to draw. `[%d.]+`, not
        -- `%d*%.?%d+`, which backtracks over a long run of digits.
        position = tex:match("^%[%s*%-?[%d.]+%s*%a*%s*%]()", position + 2) or position + 2
      elseif next_byte and ASCII_SYMBOL_TOKENS[next_byte] then
        token, position = ASCII_SYMBOL_TOKENS[next_byte], position + 2
      elseif next_byte and (next_byte <= 32 or next_byte == 127) then
        -- `\ ` and a backslash at the end of a line
        token, position = ESCAPED_SPACE_TOKEN, position + 2
      else
        local escaped = next_byte and tex:match(UTF8_CHARACTER_AT_START, position + 1)
        if escaped then
          token, position = { kind = "symbol", value = escaped }, position + 1 + #escaped
        else -- a lone backslash at the end stays visible
          token, position = ASCII_CHARACTER_TOKENS[92], position + 1
        end
      end
    elseif byte == 37 and is_display then -- `%`
      position = (tex:find("\n", position, true) or length) + 1
    elseif byte <= 32 or byte == 127 or byte == 126 then -- `~`
      token, position = SPACE_TOKEN, tex:match("^[%c ~]+()", position)
    elseif byte < 128 then
      token, position = ASCII_CHARACTER_TOKENS[byte], position + 1
    else
      local utf8_character = tex:match(UTF8_CHARACTER_AT_START, position)
      token = { kind = "character", value = utf8_character or REPLACEMENT_CHARACTER }
      position = position + (utf8_character and #utf8_character or 1)
    end
    if token then
      count = count + 1
      tokens[count] = token
    end
  end
  return tokens
end

-- =============================================================================
-- Parser: one pass, every construct returns its box
-- =============================================================================

---@class MdRenderMathTextParser
---@field tokens MdRenderMathTextToken[]
---@field position integer
---@field is_display boolean
---@field depth integer > 0 inside a script or a fraction: no 2-D layout there
---@field nesting integer
---@field may_use_script_characters { subscript: boolean, superscript: boolean }
---@field has_linear_script { subscript: boolean, superscript: boolean }
---@field tag? string a `\tag` of the grid row being read, for parse_cells
---@field intertext? string an `\intertext` of the grid row being read, for parse_cells

local parse_sequence, parse_atom

---@param parser MdRenderMathTextParser
---@return MdRenderMathTextToken?
local function peek(parser)
  return parser.tokens[parser.position]
end

---@param parser MdRenderMathTextParser
local function skip_spaces(parser)
  while peek(parser) and peek(parser).kind == "space" do
    parser.position = parser.position + 1
  end
end

---@param token MdRenderMathTextToken
local function is_close(token)
  return token.kind == "close"
end

local function never_stop()
  return false
end

---@param token MdRenderMathTextToken
local function is_environment_cell_end(token)
  return token.kind == "column_break"
    or token.kind == "row_break"
    or (token.kind == "command" and token.value == "end")
end

---@param token MdRenderMathTextToken
local function is_top_level_cell_end(token)
  return token.kind == "column_break" or token.kind == "row_break"
end

--- Tokens that end whatever is being read, so a missing argument leaves them
--- for their owner: in a half-typed `{\frac{a}}` the `}` still closes the group.
---@param token MdRenderMathTextToken
local function is_terminator(token)
  return is_environment_cell_end(token)
    or token.kind == "close"
    or (token.kind == "command" and token.value == "right")
end

--- The raw text of `{...}` (an environment name, a colour, the columns of an
--- `array`, with the braces inside it), or "".
---@param parser MdRenderMathTextParser
---@return string
local function read_raw_argument(parser)
  skip_spaces(parser)
  if not (peek(parser) and peek(parser).kind == "open") then
    return ""
  end
  parser.position = parser.position + 1
  local parts, depth = {}, 1
  while peek(parser) do
    local token = peek(parser)
    parser.position = parser.position + 1
    if token.kind == "open" then
      depth = depth + 1
    elseif token.kind == "close" then
      depth = depth - 1
      if depth == 0 then
        break
      end
    end
    parts[#parts + 1] = token.value
      or (token.kind == "space" and " ")
      or (token.kind == "open" and "{")
      or (token.kind == "close" and "}")
      or ""
  end
  return table.concat(parts)
end

--- An accent with nothing to sit on (`\^{}`, `\text{\"}`) is written as itself.
---@param token MdRenderMathTextToken
---@return string
local function accent_source(token)
  return (token.kind == "command" and "\\" or "") .. token.value
end

-- stylua: ignore
--- What the tokens without a value are in prose.
local PROSE_OF_TOKEN_KIND = { space = " ", row_break = " ", subscript = "_", superscript = "^", column_break = "&" }

--- The argument of `\text{...}`: prose, spaces kept, symbols converted.
---@param parser MdRenderMathTextParser
---@return MdRenderMathTextBox
local function read_text_argument(parser)
  skip_spaces(parser)
  local first = peek(parser)
  if not first or is_terminator(first) then
    return text_box("")
  end
  parser.position = parser.position + 1
  if first.kind ~= "open" then
    return text_box(first.value or "")
  end
  local parts, depth, pending_accent = {}, 1, nil
  while peek(parser) do
    local token = peek(parser)
    parser.position = parser.position + 1
    if pending_accent and token.kind == "close" then
      parts[#parts + 1], pending_accent = accent_source(pending_accent), nil
    end
    local mark = pending_accent and TEXT_ACCENT_MARKS[pending_accent.value] or ""
    if token.kind == "open" then
      depth = depth + 1
    elseif token.kind == "close" then
      depth = depth - 1
      if depth == 0 then
        break
      end
    elseif
      (token.kind == "command" or token.kind == "symbol") and TEXT_ACCENT_MARKS[token.value]
    then
      pending_accent = token
    elseif token.kind == "space" and pending_accent then -- `\" o`, `\v c`: TeX skips it too
    elseif token.kind == "command" then
      local spacing = SPACING_WIDTHS[token.value]
      if spacing then
        parts[#parts + 1] = string.rep(" ", spacing)
      elseif SYMBOLS[token.value] then -- `na\"{\i}ve`: the mark goes on the ı
        parts[#parts + 1] = SYMBOLS[token.value] .. mark
        pending_accent = nil
      elseif not (TEXT_COMMANDS[token.value] or FONT_COMMANDS[token.value]) then
        parts[#parts + 1] = "\\" .. token.value
      end
    elseif PROSE_OF_TOKEN_KIND[token.kind] then
      parts[#parts + 1] = PROSE_OF_TOKEN_KIND[token.kind]
    elseif token.kind == "character" then
      if token.value ~= "$" then -- math inside text: its dollars are not shown
        parts[#parts + 1] = token.value .. mark
        pending_accent = nil
      end
    else -- `\,` is a space, `\%` a percent sign; `,` itself stays a comma
      parts[#parts + 1] = SPACING_WIDTHS[token.value] and " " or token.value
    end
  end
  if pending_accent then -- half-typed: `\text{a\"`
    parts[#parts + 1] = accent_source(pending_accent)
  end
  return text_box(table.concat(parts))
end

--- One argument: a braced group, or the single token after the command.
---@param parser MdRenderMathTextParser
---@return MdRenderMathTextBox
local function parse_argument(parser)
  skip_spaces(parser)
  local token = peek(parser)
  if not token or is_terminator(token) then
    return text_box("")
  end
  if token.kind == "open" then
    parser.position = parser.position + 1
    local inner = parse_sequence(parser, is_close)
    parser.position = parser.position + 1
    return inner
  end
  -- Counted as nesting too: `\boxed\boxed\boxed x` never passes parse_sequence,
  -- and each level costs more than the last.
  parser.nesting = parser.nesting + 1
  if parser.nesting > MAXIMUM_NESTING then
    error("md_render_math_text: nested too deeply")
  end
  local atom = parse_atom(parser, true)
  parser.nesting = parser.nesting - 1
  return atom
end

--- An argument as one row, as in a script or an inline fraction.
---@param parser MdRenderMathTextParser
---@return string
local function parse_flat_argument(parser)
  parser.depth = parser.depth + 1
  local text = flatten(parse_argument(parser))
  parser.depth = parser.depth - 1
  return text
end

--- One script of a one-row base: raised marks (`′`, `°`) as they are, Unicode
--- script characters when every character has one, otherwise linear: `_x`,
--- `_bulk`, `^2`, `^∞`, `^(th)`, `^(n+1)`. Linear takes brackets unless the
--- script is one symbol or digits, or for a subscript one word; a word after
--- `^` would not read as one superscript: `e^iπ` could be e^i times π.
---@param parser MdRenderMathTextParser
---@param text string? flat text, nil when there is no such script
---@param kind "subscript"|"superscript"
---@param must_be_linear? boolean
---@return string drawn
---@return boolean is_linear
local function draw_script(parser, text, kind, must_be_linear)
  if not text or text == "" then
    return "", false
  end
  local is_subscript = kind == "subscript"
  local drawn = not is_subscript and to_script_characters(text, RAISED_MARKS)
  if not drawn and not must_be_linear and parser.may_use_script_characters[kind] then
    drawn =
      to_script_characters(text, is_subscript and SUBSCRIPT_CHARACTERS or SUPERSCRIPT_CHARACTERS)
  end
  if drawn then
    return drawn, false
  end
  parser.has_linear_script[kind] = true
  if is_subscript then
    return (is_one_word(text) or is_one_symbol(text)) and ("_" .. text) or ("_(" .. text .. ")"),
      true
  end
  return is_one_symbol(text) and ("^" .. text) or ("^(" .. text .. ")"), true
end

--- Attaches `subscript` and `superscript` (flat text, nil when absent) to `base`.
---@param parser MdRenderMathTextParser
---@param base MdRenderMathTextBox
---@param subscript string?
---@param superscript string?
---@param has_limits? boolean an operator whose scripts go under and over it in a display block
---@return MdRenderMathTextBox
local function place_scripts(parser, base, subscript, superscript, has_limits)
  if not subscript and not superscript then
    return base
  end

  if has_limits and parser.is_display and parser.depth == 0 then
    local parts, baseline_index = {}, 1
    if superscript then
      parts[1], baseline_index = text_box(superscript), 2
    end
    parts[#parts + 1] = base
    if subscript then
      parts[#parts + 1] = text_box(subscript)
    end
    local stacked = stack_vertically(parts, baseline_index)
    stacked.needs_space_before_word = true
    return stacked
  end

  if #base.rows > 1 then
    -- A tall base: the superscript at its top right, the subscript at its
    -- bottom right. The place says what they are.
    local width, rows = box_width(base), {}
    for index, row in ipairs(base.rows) do
      rows[index] = pad(row, width, "left")
    end
    if superscript then
      rows[1] = rows[1]
        .. (to_script_characters(superscript, SUPERSCRIPT_CHARACTERS) or superscript)
    end
    if subscript then
      rows[#rows] = rows[#rows]
        .. (to_script_characters(subscript, SUBSCRIPT_CHARACTERS) or subscript)
    end
    return { rows = rows, baseline = base.baseline }
  end

  local text = base.rows[1]
  if base.needs_parentheses_for_script then
    text = "(" .. text .. ")"
  end
  local subscript_text, is_subscript_linear = draw_script(parser, subscript, "subscript")
  -- `x_i²` would read as x sub i²; `x_i^2` cannot. It counts as linear, so
  -- the other superscripts of the equation follow.
  local superscript_text, is_superscript_linear =
    draw_script(parser, superscript, "superscript", is_subscript_linear)
  local result = text_box(text .. subscript_text .. superscript_text)
  result.needs_space_before_word = base.needs_space_before_word
    or is_subscript_linear
    or is_superscript_linear
  return result
end

--- Attaches the scripts that follow `base`.
---@param parser MdRenderMathTextParser
---@param base MdRenderMathTextBox
---@param has_limits? boolean an operator whose scripts go under and over it in a display block
---@return MdRenderMathTextBox
local function attach_scripts(parser, base, has_limits)
  local scripts, position = {}, parser.position
  while true do
    -- `\sum\limits_{i}`, `x _i`: TeX reads past both.
    while
      peek(parser)
      and (
        peek(parser).kind == "space"
        or (peek(parser).kind == "command" and IGNORED_COMMANDS[peek(parser).value])
      )
    do
      parser.position = parser.position + 1
    end
    local token = peek(parser)
    if not token or (token.kind ~= "subscript" and token.kind ~= "superscript") then
      break
    end
    parser.position = parser.position + 1
    scripts[token.kind] = parse_flat_argument(parser)
    position = parser.position
  end
  parser.position = position
  return place_scripts(parser, base, scripts.subscript, scripts.superscript, has_limits)
end

--- A fraction, or with `is_binomial` a binomial coefficient, of two boxes.
---@param parser MdRenderMathTextParser
---@param numerator MdRenderMathTextBox
---@param denominator MdRenderMathTextBox
---@param is_binomial? boolean
---@return MdRenderMathTextBox
local function fraction_box(parser, numerator, denominator, is_binomial)
  if parser.is_display and parser.depth == 0 then
    if is_binomial then
      return enclose("(", stack_vertically({ numerator, text_box(""), denominator }, 2), ")")
    end
    local rule =
      text_box(string.rep("─", math.max(box_width(numerator), box_width(denominator), 1)))
    return stack_vertically({ numerator, rule, denominator }, 2)
  end
  local numerator_text, denominator_text = flatten(numerator), flatten(denominator)
  if is_binomial then
    return text_box("C(" .. numerator_text .. ", " .. denominator_text .. ")")
  end
  local vulgar = VULGAR_FRACTIONS[numerator_text .. "/" .. denominator_text]
  if vulgar and parser.depth == 0 then
    return text_box(vulgar)
  end
  local result = text_box(
    parenthesise_if_several_terms(numerator_text)
      .. "/"
      .. parenthesise_if_several_terms(denominator_text)
  )
  result.needs_parentheses_for_script, result.is_linear_fraction = true, true
  return result
end

--- `\frac{a}{b}`, `\binom{n}{k}`: both read as in a script, so nothing in
--- them is stacked.
---@param parser MdRenderMathTextParser
---@param is_binomial? boolean
---@return MdRenderMathTextBox
local function parse_fraction(parser, is_binomial)
  parser.depth = parser.depth + 1
  local numerator, denominator = parse_argument(parser), parse_argument(parser)
  parser.depth = parser.depth - 1
  return fraction_box(parser, numerator, denominator, is_binomial)
end

---@param token MdRenderMathTextToken
local function is_closing_bracket(token)
  return token.kind == "character" and token.value == "]"
end

--- The flat text of `[...]` after `\sqrt` or `\xrightarrow`, nil without one.
---@param parser MdRenderMathTextParser
---@return string?
local function parse_optional_argument(parser)
  skip_spaces(parser)
  local token = peek(parser)
  if not (token and token.kind == "character" and token.value == "[") then
    return nil
  end
  parser.position = parser.position + 1
  parser.depth = parser.depth + 1
  local text = flatten(parse_sequence(parser, is_closing_bracket))
  parser.depth = parser.depth - 1
  parser.position = parser.position + 1
  return text
end

---@param parser MdRenderMathTextParser
---@return MdRenderMathTextBox
local function parse_root(parser)
  local index = parse_optional_argument(parser) or ""
  local sign = ROOT_SIGNS[index]
    or ((to_script_characters(index, SUPERSCRIPT_CHARACTERS) or ("[" .. index .. "]")) .. "√")
  local radicand = parse_argument(parser)
  if #radicand.rows > 1 then
    return place_side_by_side({
      tall_delimiter(sign, #radicand.rows, radicand.baseline),
      enclose("(", radicand, ")"),
    })
  end
  local text = radicand.rows[1]
  local result = text_box(sign .. (is_one_symbol(text) and text or ("(" .. text .. ")")))
  result.needs_parentheses_for_script = true
  return result
end

--- The delimiter after `\left`, `\right`, `\middle`; "" for `.`.
---@param parser MdRenderMathTextParser
---@return string
local function read_delimiter(parser)
  skip_spaces(parser)
  local token = peek(parser)
  if not token or token.kind == "close" or is_top_level_cell_end(token) then
    return ""
  end
  parser.position = parser.position + 1
  if token.kind == "command" then
    return SYMBOLS[token.value] or ("\\" .. token.value)
  elseif token.kind == "symbol" then
    return token.value == "|" and "‖" or token.value
  elseif token.kind == "character" then
    return token.value == "." and "" or token.value
  end
  return ""
end

---@param parser MdRenderMathTextParser
---@param name string
---@return MdRenderMathTextBox
local function parse_accent(parser, name)
  local inner = parse_argument(parser)
  local text = inner.rows[inner.baseline]
  local characters = split_characters(text)
  if #characters == 0 then
    return inner
  end
  local mark = encode_code_point(ACCENT_MARKS[name])
  -- `\hat{x_i}`: the hat goes on the x when everything after it is attached to it.
  local is_rest_attached = true
  for index = 2, #characters do
    local character = characters[index]
    is_rest_attached = is_rest_attached
      and (
        is_combining_mark(decode_code_point(character)) or SCRIPT_CHARACTER_SET[character] == true
      )
  end
  local rows = { unpack(inner.rows) }
  if SPANNING_ACCENTS[name] then
    for index, character in ipairs(characters) do
      characters[index] = character == " " and character or (character .. mark)
    end
    rows[inner.baseline] = table.concat(characters)
  elseif is_rest_attached then
    characters[1] = characters[1] .. mark
    rows[inner.baseline] = table.concat(characters)
  elseif #inner.rows == 1 then
    rows[1] = name .. "(" .. text .. ")"
  end
  return { rows = rows, baseline = inner.baseline }
end

---@param box MdRenderMathTextBox
---@param alphabet_name string
---@return MdRenderMathTextBox
local function restyle(box, alphabet_name)
  local map, rows = ALPHABET_MAPS[alphabet_name], {}
  for index, row in ipairs(box.rows) do
    rows[index] = row:gsub(UTF8_CHARACTER_PATTERN, map)
  end
  return { rows = rows, baseline = box.baseline }
end

---@class MdRenderMathTextGridRow: MdRenderMathTextBox[]
---@field tag? string `(1)` from `\tag{1}`, shown at the right of the row
---@field intertext? string from `\intertext{...}`, a line of its own above the row

--- Rows of cells up to `\end` (or the end of the input). A `\tag` or
--- `\intertext` read on the way is left in the parser, to be picked up here
--- for the row it was in.
---@param parser MdRenderMathTextParser
---@param is_cell_end fun(token: MdRenderMathTextToken): boolean
---@return MdRenderMathTextGridRow[]
local function parse_cells(parser, is_cell_end)
  local outer_tag, outer_intertext = parser.tag, parser.intertext
  parser.tag, parser.intertext = nil, nil
  local rows, cells = {}, {}
  while true do
    cells[#cells + 1] = trim_box(parse_sequence(parser, is_cell_end))
    local token = peek(parser)
    if not token then
      break
    end
    parser.position = parser.position + 1
    if token.kind == "row_break" then
      cells.tag, cells.intertext, parser.tag, parser.intertext =
        parser.tag, parser.intertext, nil, nil
      rows[#rows + 1], cells = cells, {}
    elseif token.kind == "command" then -- \end{name}
      read_raw_argument(parser)
      break
    end
  end
  cells.tag, cells.intertext = parser.tag, parser.intertext
  parser.tag, parser.intertext = outer_tag, outer_intertext
  -- A `\\` after the last row leaves one empty cell behind.
  if #cells > 1 or not is_empty(cells[1]) or cells.tag or cells.intertext then
    rows[#rows + 1] = cells
  end
  return rows
end

local COLUMN_ALIGNMENTS = { l = "left", c = "centre", r = "right" }

--- Most times `*{3}{c}` is taken: past it there are more columns than cells.
local MAXIMUM_COLUMN_REPEAT = 100

--- The alignment letters of an `array` column specification, one per column:
--- `p{3cm}` (and `m{}`, `b{}`) is a left-aligned column, `|`, `@{\,}`, `!{}`,
--- `>{}` and `<{}` are none, `*{3}{c}` is `ccc`.
---@param specification string
---@return string
local function array_column_letters(specification)
  local letters, position = {}, 1
  while position <= #specification do
    local character = specification:sub(position, position)
    position = position + 1
    if character:find("[lcr]") then
      letters[#letters + 1] = character
    elseif character:find("[pmb@!<>*]") then
      local group, after = specification:match("^%s*(%b{})()", position)
      position = after or position
      if character:find("[pmb]") then
        letters[#letters + 1] = "l"
      elseif character == "*" and group then
        local repeated, next_position = specification:match("^%s*(%b{})()", position)
        local count = math.min(tonumber(group:sub(2, -2)) or 0, MAXIMUM_COLUMN_REPEAT)
        letters[#letters + 1] = array_column_letters((repeated or "{}"):sub(2, -2)):rep(count)
        position = next_position or position
      end
    end
  end
  return table.concat(letters)
end

---@param name string environment
---@param column_letters string `lcr`, one per column (`array`, `eqnarray`)
---@param column integer
---@return "left"|"right"|"centre" alignment
---@return string gap before the column
local function column_layout(name, column_letters, column)
  if MATRIX_DELIMITERS[name] or CENTRED_ENVIRONMENTS[name] then
    return "centre", "  "
  elseif CASES_BRACES[name] then
    return "left", "   "
  elseif name == "array" or name == "eqnarray" then
    return COLUMN_ALIGNMENTS[column_letters:sub(column, column)] or "centre",
      name == "array" and "  " or " "
  end
  -- aligned, align, split and anything else: pairs of a right-aligned and a
  -- left-aligned column, so `E &= mc^2` lines up on the `=`.
  return column % 2 == 1 and "right" or "left", column % 2 == 0 and " " or "   "
end

---@param rows MdRenderMathTextGridRow[]
---@param name string
---@param column_letters string see column_layout
---@return MdRenderMathTextBox
local function layout_grid(rows, name, column_letters)
  local column_count, widths = 0, {}
  for _, cells in ipairs(rows) do
    column_count = math.max(column_count, #cells)
    for column, cell in ipairs(cells) do
      widths[column] = math.max(widths[column] or 0, box_width(cell))
    end
  end
  local alignments, gaps = {}, {}
  for column = 1, column_count do
    alignments[column], gaps[column] = column_layout(name, column_letters, column)
  end
  local grid = { rows = {}, baseline = 1 }
  for _, cells in ipairs(rows) do
    local pieces = {}
    for column = 1, column_count do
      local cell, padded = cells[column] or text_box(""), {}
      -- A cell of several rows moves as one block: its rows keep their places
      -- over each other (the `1` over the `─` of `E = ─`).
      local cell_width = #cell.rows > 1 and box_width(cell)
      for index, row in ipairs(cell.rows) do
        row = cell_width and pad(row, cell_width, "left") or row
        padded[index] = pad(row, widths[column], alignments[column])
      end
      if column > 1 then
        pieces[#pieces + 1] = text_box(gaps[column])
      end
      pieces[#pieces + 1] = { rows = padded, baseline = cell.baseline }
    end
    local line = place_side_by_side(pieces)
    if cells.intertext then
      grid.rows[#grid.rows + 1] = cells.intertext
    end
    for row_index, row in ipairs(line.rows) do
      if cells.tag and row_index == line.baseline then
        -- Every row is as wide as the grid (each cell is padded to its column),
        -- so the tags line up a `\qquad` after it, as in the picture
        -- (md_render_math_tex.lua's `\md@tag`).
        row = row .. string.rep(" ", SPACING_WIDTHS.qquad) .. cells.tag
      end
      grid.rows[#grid.rows + 1] = row
    end
  end
  grid.baseline = math.max(math.floor((#grid.rows + 1) / 2), 1)
  return grid
end

--- `\begin{name} ... \end{name}`: a grid in a display block, one row inline.
---@param parser MdRenderMathTextParser
---@return MdRenderMathTextBox
local function parse_environment(parser)
  local name = read_raw_argument(parser):gsub("%*$", "")
  local argument = ENVIRONMENTS_WITH_ARGUMENT[name] and read_raw_argument(parser) or ""
  local column_letters = name == "eqnarray" and "rcl"
    or name == "array" and array_column_letters(argument)
    or ""
  local rows = parse_cells(parser, is_environment_cell_end)
  local delimiters, braces = MATRIX_DELIMITERS[name], CASES_BRACES[name]
  local enclosure = delimiters or braces

  if not parser.is_display or parser.depth > 0 then
    local row_texts = {}
    for _, cells in ipairs(rows) do
      local cell_texts = {}
      for index, cell in ipairs(cells) do
        cell_texts[index] = flatten(cell)
      end
      if braces and #cell_texts == 2 and not cell_texts[2]:find("^%a%a") then
        -- `x \ge 0` is the condition; `\text{otherwise}` says so itself.
        row_texts[#row_texts + 1] = cell_texts[1] .. " if " .. cell_texts[2]
      else
        row_texts[#row_texts + 1] = table.concat(cell_texts, delimiters and ", " or " ")
      end
    end
    local text = table.concat(row_texts, "; ")
    return text_box(enclosure and (enclosure[1] .. text .. enclosure[2]) or text)
  end

  if #rows == 0 then
    return text_box("")
  end
  local grid = layout_grid(rows, name, column_letters)
  return enclosure and enclose(enclosure[1], grid, enclosure[2]) or grid
end

---@param token MdRenderMathTextToken
local function is_right_delimiter(token)
  return token.kind == "command" and token.value == "right"
end

--- `\underbrace{x}` in a display block: a brace of box-drawing characters
--- under (or over) `x`, its tick in the middle. The script goes under (or over)
--- it, as the limits of `\sum` do; on one row it is a mark after `x`.
---@param parser MdRenderMathTextParser
---@param is_under boolean
---@return MdRenderMathTextBox
local function parse_brace(parser, is_under)
  local inner = parse_argument(parser)
  if not (parser.is_display and parser.depth == 0) then
    return text_box(flatten(inner) .. (is_under and "⏟" or "⏞"))
  end
  local width = math.max(box_width(inner), 3)
  local left = math.floor((width - 1) / 2)
  local brace = text_box(
    (is_under and "╰" or "╭")
      .. string.rep("─", left - 1)
      .. (is_under and "┬" or "┴")
      .. string.rep("─", width - left - 2)
      .. (is_under and "╯" or "╮")
  )
  if is_under then
    return stack_vertically({ inner, brace }, 1)
  end
  return stack_vertically({ brace, inner }, 2)
end

--- `\boxed{x}`: framed in a display block; one row has no room for a frame.
---@param parser MdRenderMathTextParser
---@return MdRenderMathTextBox
local function parse_boxed(parser)
  local inner = parse_argument(parser)
  if not (parser.is_display and parser.depth == 0) then
    return inner
  end
  local width = box_width(inner)
  local edge = string.rep("─", width + 2)
  local rows = { "┌" .. edge .. "┐" }
  for _, row in ipairs(inner.rows) do
    rows[#rows + 1] = "│ " .. pad(row, width, "left") .. " │"
  end
  rows[#rows + 1] = "└" .. edge .. "┘"
  return { rows = rows, baseline = inner.baseline + 1 }
end

--- `\xrightarrow[below]{above}`: in a display block an arrow as long as its
--- labels, with them over and under it; on one row `─above→`.
---@param parser MdRenderMathTextParser
---@param is_right boolean
---@return MdRenderMathTextBox
local function parse_extensible_arrow(parser, is_right)
  local below = parse_optional_argument(parser)
  local above = parse_flat_argument(parser)
  below, above = below ~= "" and below or nil, above ~= "" and above or nil
  if parser.is_display and parser.depth == 0 then
    local shaft = string.rep(
      "─",
      math.max(above and display_width(above) or 0, below and display_width(below) or 0) + 1
    )
    local arrow = is_right and (shaft .. "→") or ("←" .. shaft)
    return place_scripts(parser, text_box(arrow), below, above, true)
  end
  local arrow = is_right and (above and ("─" .. above .. "→") or "→")
    or (above and ("←" .. above .. "─") or "←")
  return place_scripts(parser, text_box(arrow), below, nil)
end

--- `\substack{i<j \\ j \ne k}`: its rows as a list, `i<j, j ≠ k`. It sits in
--- a script, which is one row.
---@param parser MdRenderMathTextParser
---@return MdRenderMathTextBox
local function parse_substack(parser)
  skip_spaces(parser)
  if not (peek(parser) and peek(parser).kind == "open") then
    return parse_argument(parser)
  end
  parser.position = parser.position + 1
  local lines, is_row_break = {}, true
  while is_row_break do
    local line = flatten(parse_sequence(parser, is_terminator))
    if line ~= "" then
      lines[#lines + 1] = line
    end
    local token = peek(parser)
    is_row_break = token ~= nil and (token.kind == "row_break" or token.kind == "column_break")
    if is_row_break or (token and token.kind == "close") then
      parser.position = parser.position + 1
    end
  end
  return text_box(table.concat(lines, ", "))
end

--- A command and the arguments it reads.
---@param parser MdRenderMathTextParser
---@param token MdRenderMathTextToken
---@return MdRenderMathTextBox result
---@return boolean? has_limits
---@return boolean? should_skip_scripts a spacing or invisible command takes no scripts
local function parse_command(parser, token)
  local name = token.value
  if SYMBOLS[name] then
    local result = text_box(SYMBOLS[name])
    result.needs_space_before_word = SPACED_OPERATORS[name]
    if PREFIX_SYMBOLS[name] and peek(parser) and peek(parser).kind == "space" then
      local following = parser.tokens[parser.position + 1]
      local following_text = following
        and (following.kind == "character" and following.value or SYMBOLS[following.value or ""])
      if following_text and is_word_character(following_text) then
        parser.position = parser.position + 1
      end
    end
    return result, LIMIT_OPERATORS[name]
  elseif OPERATOR_NAMES[name] then
    local result = text_box(name == "bmod" and "mod" or name)
    result.needs_space_before_word = true
    return result, LIMIT_OPERATORS[name]
  elseif name == "operatorname" then
    local result = text_box(flatten(parse_argument(parser)))
    result.needs_space_before_word = true
    return result, token.has_star
  elseif SPACING_WIDTHS[name] then
    return text_box(string.rep(" ", SPACING_WIDTHS[name])), nil, true
  elseif FRACTION_COMMANDS[name] ~= nil then
    return parse_fraction(parser, FRACTION_COMMANDS[name])
  elseif name == "sqrt" then
    return parse_root(parser)
  elseif name == "left" or name == "right" or name == "middle" then
    local opening = read_delimiter(parser)
    if name ~= "left" then
      return text_box(opening)
    end
    local inner = parse_sequence(parser, is_right_delimiter)
    parser.position = parser.position + 1
    return enclose(opening, inner, read_delimiter(parser))
  elseif name == "begin" then
    return parse_environment(parser)
  elseif TEXT_COMMANDS[name] then
    return read_text_argument(parser)
  elseif UPRIGHT_COMMANDS[name] then
    return parse_argument(parser)
  elseif FONT_COMMANDS[name] then
    return restyle(parse_argument(parser), FONT_COMMANDS[name])
  elseif ACCENT_MARKS[name] then
    return parse_accent(parser, name)
  elseif name == "not" then
    local negated = flatten(parse_argument(parser))
    return text_box(
      NEGATED_SYMBOLS[negated] or negated:gsub(UTF8_CHARACTER_AT_START, "%0\204\184", 1)
    )
  elseif COMMANDS_WITHOUT_OUTPUT[name] then
    read_raw_argument(parser)
    return text_box(""), nil, true
  elseif IGNORED_COMMANDS[name] then
    return text_box(""), nil, true
  elseif FONT_SWITCHES[name] then
    return restyle(parse_sequence(parser, is_terminator), FONT_SWITCHES[name]), nil, true
  elseif name == "textcolor" then
    read_raw_argument(parser)
    return parse_argument(parser)
  elseif name == "underbrace" or name == "overbrace" then
    return parse_brace(parser, name == "underbrace"), true
  elseif name == "overset" or name == "stackrel" or name == "underset" then
    -- What is written over (under) the base: its superscript (subscript), as
    -- limits in a display block.
    local annotation = parse_flat_argument(parser)
    local base = parse_argument(parser)
    if name == "underset" then
      return place_scripts(parser, base, annotation, nil, true)
    end
    return place_scripts(parser, base, nil, annotation, true)
  elseif name == "xrightarrow" or name == "xleftarrow" then
    return parse_extensible_arrow(parser, name == "xrightarrow")
  elseif name == "substack" then
    return parse_substack(parser)
  elseif name == "boxed" then
    return parse_boxed(parser)
  elseif name == "tag" or name == "intertext" or name == "shortintertext" then
    -- Kept for the row they are in (parse_cells); on one row, written in place.
    local text = flatten(read_text_argument(parser))
    if name == "tag" and not token.has_star then
      text = "(" .. text .. ")"
    end
    if not (parser.is_display and parser.depth == 0) then
      return text_box(" " .. text .. " "), nil, true
    elseif name == "tag" then
      parser.tag = text
    else
      parser.intertext = text
    end
    return text_box(""), nil, true
  end
  -- Not known: left as written, with the braced arguments right after it.
  local result = text_box("\\" .. name)
  while peek(parser) and peek(parser).kind == "open" do
    local argument = parse_argument(parser)
    result = join_boxes(join_boxes(result, text_box("{")), join_boxes(argument, text_box("}")))
  end
  return result
end

--- One atom with its scripts.
---@param parser MdRenderMathTextParser
---@param is_bare? boolean an argument without braces: no scripts attached
---@return MdRenderMathTextBox
parse_atom = function(parser, is_bare)
  local token = peek(parser) --[[@as MdRenderMathTextToken]]
  local kind, value = token.kind, token.value
  if kind == "subscript" or kind == "superscript" then
    if is_bare then
      parser.position = parser.position + 1
      return text_box("")
    end
    return attach_scripts(parser, text_box("")) -- `{}^{14}C`, or a script at the very start
  end
  parser.position = parser.position + 1
  local result, has_limits, should_skip_scripts
  if kind == "open" then
    result = parse_sequence(parser, is_close)
    parser.position = parser.position + 1
  elseif kind == "space" then
    return text_box(" ")
  elseif kind == "character" then
    result = text_box(value == "-" and "−" or value == "'" and "′" or value)
  elseif kind == "symbol" then
    if SPACING_WIDTHS[value] then
      return text_box(string.rep(" ", SPACING_WIDTHS[value]))
    end
    result = text_box(value == "|" and "‖" or value)
  elseif kind == "command" then
    result, has_limits, should_skip_scripts = parse_command(parser, token)
    if should_skip_scripts then
      return result
    end
  else -- a stray `}`, `&` or `\\`
    return text_box(kind == "close" and "" or " ")
  end
  if is_bare then
    return result
  end
  return attach_scripts(parser, result, has_limits)
end

--- Atoms up to a token `should_stop` accepts (not consumed) or the end.
---@param parser MdRenderMathTextParser
---@param should_stop fun(token: MdRenderMathTextToken): boolean
---@return MdRenderMathTextBox
parse_sequence = function(parser, should_stop)
  parser.nesting = parser.nesting + 1
  if parser.nesting > MAXIMUM_NESTING then
    error("md_render_math_text: nested too deeply")
  end
  local result = text_box("")
  while peek(parser) and not should_stop(peek(parser)) do
    local token = peek(parser) --[[@as MdRenderMathTextToken]]
    if
      token.kind == "command"
      and INFIX_FRACTIONS[token.value] ~= nil
      and parser.tokens[parser.position + 1]
    then
      -- `{a \over b}`: the group so far over the rest of it, which is read as
      -- the denominator of `\frac` is (a chain of them stacked would cost the
      -- cube of its length). A `\over` that ends the input stays as written:
      -- it is `\overline` being typed.
      parser.position = parser.position + 1
      parser.depth = parser.depth + 1
      local denominator = trim_box(parse_sequence(parser, should_stop))
      parser.depth = parser.depth - 1
      result = fraction_box(parser, trim_box(result), denominator, INFIX_FRACTIONS[token.value])
      break
    end
    local atom = parse_atom(parser)
    local previous = result.rows[1]
    if
      atom.is_linear_fraction
      and #result.rows == 1
      and previous:sub(#previous - count_trailing_spaces(previous)):find("^/")
    then
      atom = text_box("(" .. atom.rows[1] .. ")") -- `x/\frac{a}{b}` is x/(a/b)
    end
    result = join_boxes(result, atom)
  end
  parser.nesting = parser.nesting - 1
  return result
end

---@param tokens MdRenderMathTextToken[]
---@param is_display boolean
---@param may_use_script_characters { subscript: boolean, superscript: boolean }
---@return MdRenderMathTextBox
---@return MdRenderMathTextParser
local function parse(tokens, is_display, may_use_script_characters)
  ---@type MdRenderMathTextParser
  local parser = {
    tokens = tokens,
    position = 1,
    is_display = is_display,
    depth = 0,
    nesting = 0,
    may_use_script_characters = may_use_script_characters,
    has_linear_script = { subscript = false, superscript = false },
  }
  if not is_display then
    return parse_sequence(parser, never_stop), parser
  end
  -- A display block may break rows with `\\` and align them on `&` without
  -- an environment, as KaTeX allows.
  local rows = parse_cells(parser, is_top_level_cell_end)
  if #rows == 0 then
    return text_box(""), parser
  elseif #rows == 1 and #rows[1] == 1 and not (rows[1].tag or rows[1].intertext) then
    return rows[1][1], parser
  end
  return layout_grid(rows, "aligned", ""), parser
end

--- Parses twice when a script had to be linear: the second time every script
--- of that kind is linear (see the top of this file).
---@param tex string
---@param is_display boolean
---@return MdRenderMathTextBox
local function render(tex, is_display)
  local tokens = tokenize(tex, is_display)
  local result, parser = parse(tokens, is_display, { subscript = true, superscript = true })
  local linear = parser.has_linear_script
  if linear.subscript or linear.superscript then
    result = parse(
      tokens,
      is_display,
      { subscript = not linear.subscript, superscript = not linear.superscript }
    )
  end
  return result
end

--- What is shown when the TeX cannot be drawn: itself, on one row.
---@param tex any
---@return string
local function readable_linear_form(tex)
  if type(tex) ~= "string" then
    return ""
  end
  return (tex:gsub("[%c ]+", " "):gsub("^ ", ""):gsub(" $", ""))
end

---@param tex string
---@return string
local function inline_text(tex)
  return flatten(render(tex, false))
end

---@param tex string
---@return string[]
local function display_rows(tex)
  local rows = trim_box(render(tex, true)).rows
  local first, last = 1, #rows
  while first < last and rows[first] == "" do
    first = first + 1
  end
  while last > first and rows[last] == "" do
    last = last - 1
  end
  if first == 1 and last == #rows then
    return rows
  end
  local kept = {} -- not `{ unpack(...) }`: LuaJIT's unpack fails past about 8000 values
  for index = first, last do
    kept[#kept + 1] = rows[index]
  end
  return kept
end

--- TeX of an inline equation (between the dollars) as one row of Unicode text.
--- Never raises; never contains a newline or a tab.
---@param tex string
---@return string
function M.inline(tex)
  if type(tex) ~= "string" or #tex > MAXIMUM_TEX_LENGTH then
    return readable_linear_form(tex)
  end
  local is_converted, text = pcall(inline_text, tex)
  return is_converted and text or readable_linear_form(tex)
end

--- TeX of a display block (between the `$$` lines, may hold newlines) as
--- rows of Unicode text: one or more, not necessarily equally wide, with the
--- common left margin and trailing spaces taken off. Never raises.
---@param tex string
---@return string[]
function M.display(tex)
  if type(tex) ~= "string" or #tex > MAXIMUM_TEX_LENGTH then
    return { readable_linear_form(tex) }
  end
  local is_converted, rows = pcall(display_rows, tex)
  return is_converted and rows or { readable_linear_form(tex) }
end

return M
