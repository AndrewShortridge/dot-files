-- Spec for andrew.utils.md_render_math_text: the Unicode text md-render's view
-- shows for an equation that has no picture (yet).
--
-- WHAT THIS IS GUARDING
--
-- 1. Real inline equations from the notes come out as math a reader
--    recognises. The expected strings were checked by hand, one by one.
-- 2. A sub/superscript uses Unicode script characters only when every one of
--    its characters has one, and one linear script turns the others of its
--    kind in the equation linear too: never `N_bᵤₗₖ`, never `Lₓ × L_y`.
-- 3. Fractions get the brackets precedence needs, and no more.
-- 4. Display blocks: stacked fractions, limits under big operators, matrices
--    and cases with tall brackets, `aligned` lined up on `&`.
-- 5. Neither function ever raises, also on half-typed TeX (every prefix of
--    five long equations), and no row holds a newline or a tab.
-- 6. Unknown commands stay visible.
-- 7. The amsmath environments (`align`, `alignat{2}`, ...) are laid out as
--    `aligned`, `\tag` sits at the right of its row, `\hline` and
--    `\intertext` are not cell content, and the constructs a text grid
--    cannot typeset (`\binom`, `\underbrace`, `\xrightarrow`, `\boxed`, ...)
--    get a readable form instead of their source.
--
-- Run with: nvim --headless -u NONE -l tests/md_render_math_text_spec.lua

local _H =
  dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_deep_eq =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_deep_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local math_text = require("andrew.utils.md_render_math_text")

local COMBINING_DOT_ABOVE = "\204\135" -- U+0307
local COMBINING_MACRON = "\204\132" -- U+0304
local COMBINING_CIRCUMFLEX = "\204\130" -- U+0302
local COMBINING_TILDE = "\204\131" -- U+0303
local COMBINING_OVERLINE = "\204\133" -- U+0305
local COMBINING_RIGHT_ARROW_ABOVE = "\226\131\151" -- U+20D7
local COMBINING_ACUTE = "\204\129" -- U+0301
local COMBINING_DIAERESIS = "\204\136" -- U+0308
local COMBINING_DOUBLE_ACUTE = "\204\139" -- U+030B
local COMBINING_CARON = "\204\140" -- U+030C
local COMBINING_LONG_SOLIDUS = "\204\184" -- U+0338

local SUBSCRIPT_CHARACTERS =
  "₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓᵦᵧᵨᵩᵪ"
local SUPERSCRIPT_CHARACTERS =
  "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ᵃᵇᶜᵈᵉᶠᵍʰⁱʲᵏˡᵐⁿᵒᵖʳˢᵗᵘᵛʷˣʸᶻᴬᴮᴰᴱᴳᴴᴵᴶᴷᴸᴹᴺᴼᴾᴿᵀᵁⱽᵂᵅᵝᵞᵟᶿᶥᵠᵡ"

--- Each pair: TeX, the one row expected from inline().
---@param pairs_to_check string[][]
local function assert_inline(pairs_to_check)
  for _, pair in ipairs(pairs_to_check) do
    assert_eq(math_text.inline(pair[1]), pair[2], pair[1])
  end
end

--- Each pair: TeX, the rows expected from display().
---@param pairs_to_check { [1]: string, [2]: string[] }[]
local function assert_display(pairs_to_check)
  for _, pair in ipairs(pairs_to_check) do
    assert_deep_eq(math_text.display(pair[1]), pair[2], pair[1])
  end
end

---@param text string
---@param characters string
---@return boolean
local function contains_any(text, characters)
  for character in characters:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if text:find(character, 1, true) then
      return true
    end
  end
  return false
end

-- Inline equations from the notes, by what they exercise.
local CORPUS_SYMBOLS = {
  { [[\rho(z)]], "ρ(z)" },
  { [[\rho(z,t)]], "ρ(z,t)" },
  { [[\alpha \approx 2.3]], "α ≈ 2.3" },
  { [[T \approx 1.05 T_m]], "T ≈ 1.05 Tₘ" },
  { [[C_e = \gamma T_e]], "Cₑ = γ Tₑ" },
  { [[v_{tip} \sim 2-5 \times u_p]], "vₜᵢₚ ∼ 2−5 × uₚ" },
  { [[v_{tip} \propto k \cdot h_0]], "vₜᵢₚ ∝ k · h₀" },
  {
    [[m_{ej} \propto \rho_0 \cdot h_0 \cdot \lambda \cdot f(v_p / c_0)]],
    "mₑⱼ ∝ ρ₀ · h₀ · λ · f(vₚ / c₀)",
  },
  { [[(\partial T/\partial P)_S = VT\alpha/C_P]], "(∂T/∂P)_S = VTα/C_P" },
}

local CORPUS_UNICODE_SCRIPTS = {
  { "T_m", "Tₘ" },
  { "K_0", "K₀" },
  { "O_3", "O₃" },
  { "c_p", "cₚ" },
  { [[\psi_i]], "ψᵢ" },
  { "2u_p", "2uₚ" },
  { "u_p = 1.5", "uₚ = 1.5" },
  { "E_a^{th}", "Eₐᵗʰ" },
  { "E_a^c", "Eₐᶜ" },
  { "j^{th}", "jᵗʰ" },
  { "K_e(T_e)", "Kₑ(Tₑ)" },
  { "z_{tip}(t)", "zₜᵢₚ(t)" },
  { "z_{rear}(t)", "zᵣₑₐᵣ(t)" },
  { "m_{ej}(t)", "mₑⱼ(t)" },
  { "v_{tip}(t) = dz_{tip}/dt", "vₜᵢₚ(t) = dzₜᵢₚ/dt" },
  { "t_{arrival} = L_{sample} / U_s", "tₐᵣᵣᵢᵥₐₗ = Lₛₐₘₚₗₑ / Uₛ" },
  { [[N(R) \propto R^{-\alpha}]], "N(R) ∝ R⁻ᵅ" },
}

local CORPUS_LINEAR_SCRIPTS = {
  { "L_c", "L_c" },
  { "f_{QCGD}", "f_QCGD" },
  { [[z > z_{rear\_surface}]], "z > z_(rear_surface)" },
  { "v_{rs,peak} = 3.08", "v_(rs,peak) = 3.08" },
  { "2^{5/8}", "2^(5/8)" },
  {
    "N_{bulk} + N_{surface} + N_{remaining} = N_{ejected}",
    "N_bulk + N_surface + N_remaining = N_ejected",
  },
  { "N_{bulk}(t) + N_{ejecta}(t) = N_{total}", "N_bulk(t) + N_ejecta(t) = N_total" },
  -- One linear subscript makes the others linear: no `Lₓ × L_y`.
  { [[L_x \times L_y]], "L_x × L_y" },
  { [[N_x \times N_y \times N_z]], "N_x × N_y × N_z" },
  { [[\rho v_\alpha v_\beta]], "ρ v_α v_β" },
  { [[\rho = N \cdot m_{Cu} / V_{bin}]], "ρ = N · m_Cu / V_bin" },
  { [[P = -(\sigma_{xx} + \sigma_{yy} + \sigma_{zz}) / 3]], "P = −(σ_xx + σ_yy + σ_zz) / 3" },
  {
    [[v_{tip} \approx v_{fs} + C \cdot v_{fs} \cdot (k \cdot h_0)]],
    "v_tip ≈ v_fs + C · v_fs · (k · h_0)",
  },
}

local CORPUS_FRACTIONS_ROOTS_ALPHABETS = {
  { [[r_{nn} = a_0/\sqrt{2} = 2.55]], "rₙₙ = a₀/√2 = 2.55" },
  { [[R_{eq} = \left(\frac{3V}{4\pi}\right)^{1/3}]], "R_eq = (3V/4π)^(1/3)" },
  {
    [[T = \frac{2}{3k_B N} \sum \frac{1}{2} m_i |\mathbf{v}_i - \mathbf{v}_{cm}|^2]],
    "T = 2/(3k_B N) ∑ ½ m_i |𝐯_i − 𝐯_cm|²",
  },
  { [[KE_{bin} = \sum_i \frac{1}{2} m_i |\mathbf{v}_i|^2]], "KE_bin = ∑_i ½ m_i |𝐯_i|²" },
  { [[\mathbf{v}_{cm} = \sum m_i \mathbf{v}_i / \sum m_i]], "𝐯_cm = ∑ m_i 𝐯_i / ∑ m_i" },
  {
    [[\dot{h} = k \cdot h_0 \cdot \Delta v \cdot A^+]],
    "h" .. COMBINING_DOT_ABOVE .. " = k · h₀ · Δv · A⁺",
  },
}

-- Five long ones, for the half-typed states.
local LONG_EQUATIONS = {
  [[T = \frac{2}{3k_B N} \sum \frac{1}{2} m_i |\mathbf{v}_i - \mathbf{v}_{cm}|^2]],
  [[v_{tip} \approx v_{fs} + C \cdot v_{fs} \cdot (k \cdot h_0)]],
  [[m_{ej} \propto \rho_0 \cdot h_0 \cdot \lambda \cdot f(v_p / c_0)]],
  [[KE_{bin} = \sum_i \frac{1}{2} m_i |\mathbf{v}_i|^2]],
  [[\sigma = \sqrt{\frac{1}{N} \sum_{i=1}^{N} (x_i - \bar{x})^2}]],
}

-- ============================================================================
-- 1. Real equations
-- ============================================================================

test("corpus: symbols, Greek and operators", function()
  assert_inline(CORPUS_SYMBOLS)
end)

test("corpus: scripts whose every character has a Unicode script form", function()
  assert_inline(CORPUS_UNICODE_SCRIPTS)
end)

test("corpus: scripts Unicode cannot draw stay linear, and so do the others", function()
  assert_inline(CORPUS_LINEAR_SCRIPTS)
end)

test("corpus: fractions, roots, \\left..\\right, bold letters, accents", function()
  assert_inline(CORPUS_FRACTIONS_ROOTS_ALPHABETS)
end)

-- ============================================================================
-- 2. Scripts: all or nothing
-- ============================================================================

test("scripts: one character without a script form keeps the whole script linear", function()
  assert_inline({
    { "x_{ij}", "xᵢⱼ" },
    { "x_{ab}", "x_ab" }, -- no subscript b: never `xₐb`
    { "x^{n+1}", "xⁿ⁺¹" },
    { "x^{q}", "x^q" },
    { [[e^{i\pi}]], "e^(iπ)" }, -- `e^iπ` could be e^i times π
    { "j^{th} + 2^{5/8}", "j^(th) + 2^(5/8)" },
    { "e^{-x^2}", "e^(−x^2)" },
    { "x_{a_b}", "x_(a_b)" },
    { [[\int_0^\infty e^{-x}\,dx]], "∫₀^∞ e^(−x) dx" },
  })
end)

test("scripts: subscripts and superscripts are judged separately", function()
  assert_inline({
    { "x^2 + v_{fs}", "x² + v_fs" },
    { "x_2 + 2^{5/8}", "x₂ + 2^(5/8)" },
  })
end)

test("scripts: a superscript after a linear subscript is linear too", function()
  assert_inline({
    { "x_i^2 + y_{ab}", "x_i^2 + y_ab" },
    { "x_{ab}^2 + y^2", "x_ab^2 + y^2" },
  })
end)

test("scripts: a linear script is kept apart from a letter right after it", function()
  assert_inline({ { "a_ib", "aᵢb" }, { "a_ib + v_{fs}", "a_i b + v_fs" } })
end)

test("scripts: raised marks are written as they are", function()
  assert_inline({
    { [[90^\circ]], "90°" },
    { [[f^\prime(x)]], "f′(x)" },
    { "f'(x)", "f′(x)" },
    { "A^*", "A*" },
    { [[A^\dagger + v_{fs}]], "A† + v_fs" },
    { "{}^{14}C", "¹⁴C" },
  })
end)

test("scripts: no output mixes Unicode and linear scripts of one kind", function()
  local all = {}
  for _, list in ipairs({
    CORPUS_SYMBOLS,
    CORPUS_UNICODE_SCRIPTS,
    CORPUS_LINEAR_SCRIPTS,
    CORPUS_FRACTIONS_ROOTS_ALPHABETS,
  }) do
    vim.list_extend(all, list)
  end
  vim.list_extend(all, { { "x_i^2 + y_{ab}" }, { "x_{ab}^2 + y^2" }, { [[e^{i\pi} + x^2]] } })
  for _, pair in ipairs(all) do
    local text = math_text.inline(pair[1])
    assert_true(
      not (text:find("_", 1, true) and contains_any(text, SUBSCRIPT_CHARACTERS)),
      "mixed subscripts in " .. text
    )
    assert_true(
      not (text:find("^", 1, true) and contains_any(text, SUPERSCRIPT_CHARACTERS)),
      "mixed superscripts in " .. text
    )
  end
end)

-- ============================================================================
-- 3. Fractions, roots, accents, alphabets, text, spacing
-- ============================================================================

test("fractions: brackets where precedence needs them, vulgar fractions for digits", function()
  assert_inline({
    { [[\frac{a+b}{c}]], "(a+b)/c" },
    { [[\frac{a}{b + c}]], "a/(b + c)" },
    { [[\frac{n(n+1)}{2}]], "n(n+1)/2" },
    { [[\frac{dz}{dt}]], "dz/dt" },
    { [[\frac{\partial \rho}{\partial t}]], "∂ρ/∂t" },
    { [[\frac{a}{b}^2]], "(a/b)²" },
    { [[x/\frac{a}{b}]], "x/(a/b)" },
    { [[\frac{\frac{1}{2}}{x}]], "(1/2)/x" },
    { [[\frac12]], "½" },
    { [[\tfrac{3}{4}x]], "¾x" },
    { [[\frac{1}{3}]], "⅓" },
    { [[\frac{1}{7}]], "1/7" },
    { [[2^{\frac{1}{2}}]], "2^(1/2)" },
  })
end)

test("roots: brackets unless the radicand is one symbol", function()
  assert_inline({
    { [[\sqrt{2}]], "√2" },
    { [[\sqrt{12}]], "√12" },
    { [[\sqrt{2x}]], "√(2x)" },
    { [[\sqrt{x^2 + y^2}]], "√(x² + y²)" },
    { [[\sqrt[3]{x}]], "∛x" },
    { [[\sqrt[n]{x}]], "ⁿ√x" },
    { [[\sqrt{x}^2]], "(√x)²" },
  })
end)

test("accents: combining marks on one character, a named form over several", function()
  assert_inline({
    { [[\bar{x}]], "x" .. COMBINING_MACRON },
    { [[\hat{n}]], "n" .. COMBINING_CIRCUMFLEX },
    { [[\tilde{n}]], "n" .. COMBINING_TILDE },
    { [[\vec{v}]], "v" .. COMBINING_RIGHT_ARROW_ABOVE },
    { [[\dot{\psi} = -\lambda \psi]], "ψ" .. COMBINING_DOT_ABOVE .. " = −λ ψ" },
    { [[\hat{x_i}]], "x" .. COMBINING_CIRCUMFLEX .. "ᵢ" },
    { [[\hat{xy}]], "hat(xy)" },
    { [[\overline{AB}]], "A" .. COMBINING_OVERLINE .. "B" .. COMBINING_OVERLINE },
  })
end)

test("alphabets: bold, double-struck, script, fraktur", function()
  assert_inline({
    { [[\mathbf{u}]], "𝐮" },
    { [[\nabla \times \mathbf{B}]], "∇ × 𝐁" },
    { [[\boldsymbol{\alpha}]], "𝛂" },
    { [[\mathbb{R}^n]], "ℝⁿ" },
    { [[\mathbb{E}]], "𝔼" },
    { [[\mathcal{L}]], "ℒ" },
    { [[\mathcal{A}]], "𝒜" },
    { [[\mathfrak{g}]], "𝔤" },
  })
end)

test("text and upright: prose kept, operator names apart from what follows", function()
  assert_inline({
    { [[x \text{ and } y]], "x and y" },
    { [[\text{well-known}]], "well-known" },
    { [[\mathrm{d}x]], "dx" },
    { [[\operatorname{sgn}(x)]], "sgn(x)" },
    { [[\sin\theta + \cos x]], "sin θ + cos x" },
    { [[\log_2 n]], "log₂ n" },
    { [[\lim_{x \to 0} f(x)]], "lim_(x → 0) f(x)" },
  })
end)

test("delimiters and spacing", function()
  assert_inline({
    { [[\left(\frac{a}{b}\right)]], "(a/b)" },
    { [[\left. \frac{df}{dx} \right|_{x=0}]], "df/dx |ₓ₌₀" },
    { [[\langle a, b \rangle]], "⟨ a, b ⟩" },
    { [[\| x \|]], "‖ x ‖" },
    { [[\{x\}]], "{x}" },
    { [[a\,b\;c\!d]], "a b cd" },
    { [[x^2 \, dx]], "x² dx" },
    { [[x \quad y]], "x  y" },
    { "a~b", "a b" },
    { [[\Delta t]], "Δt" },
    { [[\sum_{i}x_i]], "∑ᵢ xᵢ" },
    { [[a \not= b]], "a ≠ b" },
    { [[50\%]], "50%" },
    { "a % b", "a % b" },
  })
end)

test("environments inline: one row", function()
  assert_inline({
    { [[\begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix}]], "(1, 2; 3, 4)" },
    {
      [[f(x) = \begin{cases} x^2 & x \ge 0 \\ -x & x < 0 \end{cases}]],
      "f(x) = {x² if x ≥ 0; −x if x < 0",
    },
    { [[\begin{cases} 1 & x > 0 \\ 0 & \text{otherwise} \end{cases}]], "{1 if x > 0; 0 otherwise" },
    { [[\begin{aligned} E &= mc^2 \\ p &= \gamma m v \end{aligned}]], "E = mc²; p = γ m v" },
    { [[\sum_{i=1}^n i]], "∑ᵢ₌₁ⁿ i" },
  })
end)

test("unknown commands stay readable with their arguments", function()
  assert_inline({
    { [[\dv{f}{x}]], [[\dv{f}{x}]] },
    { [[\foo{x}{y_i} + 1]], [[\foo{x}{yᵢ} + 1]] },
    { [[\unknownsymbol x]], [[\unknownsymbol x]] },
  })
end)

-- ============================================================================
-- 4. Display blocks
-- ============================================================================

test("display: stacked fraction (corpus)", function()
  assert_display({
    {
      [[\frac{\partial \rho}{\partial t} + \nabla \cdot (\rho \mathbf{u}) = 0]],
      { "∂ρ", "── + ∇ · (ρ 𝐮) = 0", "∂t" },
    },
    {
      [[\int_0^1 x^2 \, dx = \frac{1}{3}]],
      { "            1", "∫₀¹ x² dx = ─", "            3" },
    },
  })
end)

test("display: limits above and below big operators (corpus)", function()
  assert_display({
    {
      [[\sum_{i=1}^n i = \frac{n(n+1)}{2}]],
      { " n     n(n+1)", " ∑ i = ──────", "i=1      2" },
    },
    { [[\max_i |u_i| \, \Delta t \le \Delta x]], { "max |uᵢ| Δt ≤ Δx", " i" } },
    {
      [[\lim_{x \to 0} \frac{\sin x}{x} = 1]],
      { "     sin x", " lim ───── = 1", "x → 0  x" },
    },
  })
end)

test("display: a root over a tall radicand gets tall brackets (corpus)", function()
  assert_deep_eq(math_text.display(LONG_EQUATIONS[5]), {
    "     ⎛1  N          ⎞",
    "σ = √⎜─  ∑ (xᵢ − x̄)²⎟",
    "     ⎝N i=1         ⎠",
  })
end)

test("display: aligned lines up on &", function()
  assert_display({
    {
      [[\begin{aligned} E &= mc^2 \\ p &= \gamma m v \end{aligned}]],
      { "E = mc²", "p = γ m v" },
    },
    { [[\begin{aligned} f(x) &= a + b \\ &= c \end{aligned}]], { "f(x) = a + b", "     = c" } },
    -- Rows and `&` without an environment, as KaTeX allows.
    { [[a &= b \\ cc &= d]], { " a = b", "cc = d" } },
    { "x = 1 \\\\[2pt] y = 2", { "x = 1", "y = 2" } },
    -- A cell of several rows keeps them over each other when it is aligned.
    {
      [[\begin{aligned} \frac{a}{b} + c &= d \\ e &= f \end{aligned}]],
      { "a", "─ + c = d", "b", "    e = f" },
    },
  })
end)

test("display: matrices with their brackets", function()
  assert_display({
    {
      [[A = \begin{pmatrix} a_{11} & a_{12} \\ a_{21} & a_{22} \end{pmatrix}, \qquad \det A = a_{11} a_{22} - a_{12} a_{21}]],
      {
        "A = ⎛a₁₁  a₁₂⎞,   det A = a₁₁ a₂₂ − a₁₂ a₂₁",
        "    ⎝a₂₁  a₂₂⎠",
      },
    },
    { [[\begin{bmatrix} 1 & 0 \\ 0 & 1 \end{bmatrix}]], { "⎡1  0⎤", "⎣0  1⎦" } },
    { [[\begin{vmatrix} a & b \\ c & d \end{vmatrix}]], { "│a  b│", "│c  d│" } },
    { [[\begin{matrix} 1 & 10 \\ 100 & 1 \end{matrix}]], { " 1   10", "100  1" } },
    {
      [[\begin{pmatrix} \frac{1}{2} & 0 \\ 0 & 1 \end{pmatrix}]],
      { "⎛1   ⎞", "⎜─  0⎟", "⎜2   ⎟", "⎝0  1⎠" },
    },
  })
end)

test("display: cases with a brace", function()
  assert_display({
    {
      [[f(x) = \begin{cases} x^2 & x \ge 0 \\ -x & x < 0 \end{cases}]],
      { "f(x) = ⎧x²   x ≥ 0", "       ⎩−x   x < 0" },
    },
    {
      [[\begin{cases} a & b \\ c & d \\ e & f \end{cases}]],
      { "⎧a   b", "⎨c   d", "⎩e   f" },
    },
  })
end)

test("display: tall delimiters, nested fractions, array columns", function()
  assert_display({
    { [[\left( \frac{a}{b} \right)^2]], { "⎛ a ⎞²", "⎜ ─ ⎟", "⎝ b ⎠" } },
    { [[\frac{1}{1 + \frac{1}{x}}]], { "   1", "───────", "1 + 1/x" } },
    { [[\begin{array}{lr} a & bb \\ ccc & d \end{array}]], { "a    bb", "ccc   d" } },
  })
end)

test("display: array columns read from the whole specification", function()
  assert_display({
    -- `p{1cm}` is one left-aligned column; the `c` of `cm` is not a column.
    { [[\begin{array}{p{1cm}r} a & bbb \\ ccc & d \end{array}]], { "a    bbb", "ccc    d" } },
    {
      [[\begin{array}{m{2cm}b{1in}c} a & b & c \\ ddd & eee & fff \end{array}]],
      {
        "a    b     c",
        "ddd  eee  fff",
      },
    },
    -- `|`, `@{..}`, `!{..}` and `>{..}` are not columns.
    { [[\begin{array}{r@{\,}l} aaa & b \\ c & ddd \end{array}]], { "aaa  b", "  c  ddd" } },
    {
      [[\begin{array}{>{\bfseries}l!{:}r} a & bbb \\ ccc & d \end{array}]],
      { "a    bbb", "ccc    d" },
    },
    -- `*{n}{..}` repeats its columns.
    {
      [[\begin{array}{|c|*{2}{r}|} a & bb & c \\ ddd & e & ffff \end{array}]],
      {
        " a   bb     c",
        "ddd   e  ffff",
      },
    },
  })
end)

test("display: one row, empty input, comments, newlines in the TeX", function()
  assert_display({
    { "a^2 + b^2 = c^2", { "a² + b² = c²" } },
    { "", { "" } },
    { "x = 1\n% a comment\n+ 2", { "x = 1 + 2" } },
    { "\\begin{aligned}\n  a &= b \\\\\n  c &= d\n\\end{aligned}", { "a = b", "c = d" } },
  })
end)

-- ============================================================================
-- 5. amsmath environments, tags, prose accents, and readable forms
-- ============================================================================

test("display: top-level amsmath environments are laid out as aligned and gathered", function()
  assert_display({
    { "\\begin{align}\na &= b + c \\\\\nd &= e\n\\end{align}", { "a = b + c", "d = e" } },
    { "\\begin{align*}\na &= b + c \\\\\nd &= e\n\\end{align*}", { "a = b + c", "d = e" } },
    { "\\begin{equation}\nE = mc^2\n\\end{equation}", { "E = mc²" } },
    { "\\begin{equation*}\nE = mc^2 \\label{eq:e}\n\\end{equation*}", { "E = mc²" } },
    { "\\begin{gather}\na = b \\\\\nc = d + e\n\\end{gather}", { "  a = b", "c = d + e" } },
    { "\\begin{multline}\na + b + c \\\\\n+ d + e\n\\end{multline}", { "a + b + c", " + d + e" } },
    { "\\begin{eqnarray}\na &=& b \\\\\ncc &=& d\n\\end{eqnarray}", { " a = b", "cc = d" } },
    { "\\begin{split}\na &= b \\\\\n&= c\n\\end{split}", { "a = b", "  = c" } },
    {
      "\\begin{equation}\\begin{split}\na &= b \\\\\n&= c\n\\end{split}\\end{equation}",
      { "a = b", "  = c" },
    },
    -- `{2}` counts the column pairs; it is not content.
    { "\\begin{alignat}{2}\na &= b &\\quad c &= d\n\\end{alignat}", { "a = b   c = d" } },
    { [[\begin{alignedat}{2} a &= b & c &= d \end{alignedat}]], { "a = b   c = d" } },
  })
  assert_inline({ { [[\begin{alignat}{2} a &= b & c &= d \end{alignat}]], "a = b c = d" } })
end)

test("\\tag: `(..)` at the right of its row, `\\tag*` without brackets", function()
  assert_display({
    {
      "\\begin{align}\na &= b \\tag{1} \\\\\ncc &= d \\tag{2}\n\\end{align}",
      { " a = b   (1)", "cc = d   (2)" },
    },
    {
      "\\begin{align*}\na &= bbb \\\\\ncc &= d \\tag{2}\n\\end{align*}",
      { " a = bbb", "cc = d     (2)" },
    },
    { [[E = \frac{1}{2} m v^2 \tag{2}]], { "    1", "E = ─ m v²   (2)", "    2" } },
    { [[E = mc^2 \tag*{A}]], { "E = mc²   A" } },
    {
      "\\begin{equation}\\begin{split}\na &= b \\\\\n&= c\n\\end{split}\\tag{3.1}\\end{equation}",
      { "a = b   (3.1)", "  = c" },
    },
  })
  assert_inline({
    { [[E = mc^2 \tag{1}]], "E = mc² (1)" },
    { [[E = mc^2\tag{1}]], "E = mc² (1)" },
  })
end)

test("\\hline and \\intertext are not cell content", function()
  assert_display({
    { [[\begin{array}{c|c} a & b \\ \hline c & d \end{array}]], { "a  b", "c  d" } },
    {
      "\\begin{align*}\na &= b \\\\\n\\intertext{and so} c &= \\frac{1}{2}\n\\end{align*}",
      { "a = b", "and so", "    1", "c = ─", "    2" },
    },
  })
  assert_inline({
    { [[\begin{aligned} a &= b \\ \intertext{and} c &= d \end{aligned}]], "a = b; and c = d" },
  })
end)

test("text: prose accents, punctuation kept", function()
  assert_inline({
    { [[\text{Schr\"odinger}]], "Schro" .. COMBINING_DIAERESIS .. "dinger" },
    { [[\text{caf\'{e}}]], "cafe" .. COMBINING_ACUTE },
    {
      [[\text{Erd\H{o}s, Dvo\v r\'ak}]],
      "Erdo"
        .. COMBINING_DOUBLE_ACUTE
        .. "s, Dvor"
        .. COMBINING_CARON
        .. "a"
        .. COMBINING_ACUTE
        .. "k",
    },
    { [[\text{na\"{\i}ve}]], "naı" .. COMBINING_DIAERESIS .. "ve" },
    { [[\text{a, b: c; d!}]], "a, b: c; d!" },
    { [[\text{\$5, 3\,km}]], "$5, 3 km" },
    -- An accent with nothing to sit on is written as itself.
    { [[\text{10\^{}3}]], "10^3" },
    { [[\text{a\~{}b}]], "a~b" },
    { [[\text{\"}]], '"' },
    { [[\text{\c}]], [[\c]] },
    { [[\text{a\"]], 'a"' },
  })
end)

test("\\tag stays on its own row, and out of a grid nested in it", function()
  assert_display({
    { [[\begin{align} a &= b \tag{1} \\ c &= d \end{align}]], { "a = b   (1)", "c = d" } },
    {
      [[\begin{align} a \tag{1} &= \begin{pmatrix} 1 \\ 2 \end{pmatrix} \end{align}]],
      { "a = ⎛1⎞   (1)", "    ⎝2⎠" },
    },
  })
end)

test("a trailing \\over is `\\overline` being typed: left as written", function()
  assert_inline({ { [[a + b = \over]], [[a + b = \over]] } })
  assert_display({ { [[a + b = \over]], { [[a + b = \over]] } } })
end)

test("tokens: invalid bytes, escaped control characters, spaces in a script", function()
  assert_inline({
    { "a\128b", "a\239\191\189b" }, -- U+FFFD
    { "a\\\tb", "a b" },
    { "x_{i j}", "xᵢⱼ" },
  })
end)

test("display: blank first and last rows are dropped", function()
  assert_display({ { [[\\ x = 1]], { "x = 1" } }, { [[x = 1 \\ \\ ]], { "x = 1" } } })
end)

test("long or deeply chained TeX comes back as written, quickly", function()
  local rows = ("x = 1 \\\\ "):rep(10000)
  local start = vim.uv.hrtime()
  assert_deep_eq(math_text.display("\\\\ " .. rows), { "\\\\ " .. (rows:gsub(" $", "")) })
  -- Up to the cap (4000 bytes) it is still drawn; one byte over, it is not.
  local under = ("a + "):rep(998) .. "bbbb" -- 3996 bytes
  assert_eq(math_text.inline(under .. "^{2}"), under .. "²")
  assert_eq(math_text.inline(under .. "^{22}"), under .. "^{22}")
  -- Bare chains count as nesting: `\boxed` 400 deep was seconds of work.
  local boxes = ("\\boxed"):rep(400) .. " x"
  assert_eq(math_text.inline(boxes), boxes)
  assert_deep_eq(math_text.display(boxes), { boxes })
  assert_true((vim.uv.hrtime() - start) / 1e6 < 1000, "took over a second")
end)

test("infix fractions and old font switches", function()
  assert_inline({
    { [[{a \over b}]], "a/b" },
    { [[x = {n+1 \over 2}]], "x = (n+1)/2" },
    { [[{1 \over 2}]], "½" },
    { [[{a \over b}^2]], "(a/b)²" },
    { [[{n \choose k} p^k]], "C(n, k) pᵏ" },
    { [[\int f\,{\rm d}x]], "∫ f dx" },
    { [[{\bf v} + {\it ab}c]], "𝐯 + abc" },
    { [[{\cal L}]], "ℒ" },
  })
  assert_display({ { [[x = {n+1 \over 2}]], { "    n+1", "x = ───", "     2" } } })
end)

test("readable forms: binomials, braces, annotations, arrows, frames", function()
  assert_inline({
    { [[\binom{n}{k}]], "C(n, k)" },
    { [[\underbrace{a + b}_{n}]], "a + b⏟ₙ" },
    { [[\overbrace{a + b}^{n}]], "a + b⏞ⁿ" },
    { [[a \stackrel{\text{def}}{=} b]], "a =ᵈᵉᶠ b" },
    { [[\overset{!}{=}]], "=^!" },
    { [[\underset{x}{\max} f]], "maxₓ f" },
    { [[A \xrightarrow{k_1} B]], "A ─k₁→ B" },
    { [[A \xleftarrow{k} B]], "A ←k─ B" },
    { [[\sum_{\substack{i<j \\ j \ne k}} a]], "∑_(i<j, j ≠ k) a" },
    { [[\boxed{E = mc^2}]], "E = mc²" },
    { [[\textcolor{red}{x^2} + y]], "x² + y" },
    {
      [[\cancel{ab} + \cancel{x}]],
      "a"
        .. COMBINING_LONG_SOLIDUS
        .. "b"
        .. COMBINING_LONG_SOLIDUS
        .. " + x"
        .. COMBINING_LONG_SOLIDUS,
    },
    { [[\bm{v} \cdot \bm{\sigma}]], "𝐯 · 𝛔" },
    { [[\mathscr{L}]], "ℒ" },
  })
  assert_display({
    { [[\binom{n}{k} p^k]], { "⎛n⎞", "⎜ ⎟ pᵏ", "⎝k⎠" } },
    {
      [[\underbrace{a + b}_{\text{sum}} + \overbrace{c}^{n}]],
      { "         n", "        ╭┴╮", "a + b +  c", "╰─┬─╯", " sum" },
    },
    { [[a \stackrel{\text{def}}{=} b]], { " def", "a = b" } },
    { [[A \xrightarrow[T]{k_1} B]], { "   k₁", "A ───→ B", "   T" } },
    { [[\sum_{\substack{i<j \\ j \ne k}} a_{ij}]], { "    ∑     aᵢⱼ", "i<j, j ≠ k" } },
  })
  assert_deep_eq(math_text.display([[\boxed{x = \frac{a}{b}}]]), {
    "┌───────┐",
    "│     a │",
    "│ x = ─ │",
    "│     b │",
    "└───────┘",
  })
end)

test("Unicode typed in the TeX passes through unchanged", function()
  for _, tex in ipairs({
    "α + β ≤ γ",
    "3 × 10⁵",
    "90°",
    "∂f/∂x",
    "ℏ ∑ ∫ √2",
    "5 µm²",
  }) do
    assert_eq(math_text.inline(tex), tex, tex)
    assert_deep_eq(math_text.display(tex), { tex }, tex)
  end
  assert_inline({ { [[\text{Schrödinger, 5 Å}]], "Schrödinger, 5 Å" } })
end)

test("readable forms: separators and labels that are easy to lose", function()
  assert_inline({
    { [[\sum_{\substack{i & j}} a]], "∑_(i, j) a" },
    { [[A \xrightarrow[T]{k} B]], "A ─k→_T B" },
    -- `{c}` gives the columns of a subarray; it is not content.
    { [[\sum_{\begin{subarray}{c} i<j \\ k \end{subarray}} a]], "∑_(i<j; k) a" },
  })
end)

-- ============================================================================
-- 6. Never raises, never a newline or a tab
-- ============================================================================

local MALFORMED = {
  "",
  "\\",
  "x \\",
  "\\frac{",
  "\\frac{a}{",
  "\\frac",
  "x_{",
  "x_",
  "x^",
  "^",
  "_{}^{}",
  "{",
  "}",
  "}}}{{{",
  "\\left(",
  "\\right)",
  "\\left( x \\right",
  "\\begin{pmatrix}",
  "\\begin{pmatrix} a & b \\\\",
  "\\end{cases}",
  "\\begin{",
  "\\begin{array}{",
  "\\sqrt[",
  "\\sqrt[3",
  "\\text{",
  "\\text{a {b",
  "\\mathbf",
  "\\hat{}",
  "\\not",
  "\\operatorname*",
  "&&\\\\",
  "\\\\[",
  "$",
  "a\tb\nc\r\n",
  "\128\255\192",
  "é \\alpha é",
  string.rep("{", 2000),
  string.rep("x^", 1000),
  string.rep("\\frac{", 500),
  string.rep("\\left(", 500),
  string.rep("\\over ", 500),
  string.rep("{\\bf ", 500),
  "\\over",
  "{a \\over",
  "\\tag{",
  "\\tag",
  "\\intertext{a",
  "\\begin{alignat}{",
  "\\underbrace{",
  "\\overset{a}",
  "\\xrightarrow[",
  "\\xrightarrow[a",
  "\\substack{a \\\\",
  "\\substack{a \\end{b}",
  "\\boxed{",
  '\\text{\\"',
  '\\text{\\"{',
  "\\textcolor{",
}

---@param tex any
local function assert_never_raises(tex)
  local is_inline_ok, inline = pcall(math_text.inline, tex)
  assert_true(is_inline_ok, "inline raised on " .. vim.inspect(tex) .. ": " .. tostring(inline))
  assert_eq(type(inline), "string", "inline type for " .. vim.inspect(tex))
  assert_true(not inline:find("[\n\t]"), "newline or tab in inline of " .. vim.inspect(tex))
  local is_display_ok, rows = pcall(math_text.display, tex)
  assert_true(is_display_ok, "display raised on " .. vim.inspect(tex) .. ": " .. tostring(rows))
  assert_true(type(rows) == "table" and #rows >= 1, "display rows for " .. vim.inspect(tex))
  for _, row in ipairs(rows) do
    assert_eq(type(row), "string")
    assert_true(not row:find("[\n\t]"), "newline or tab in display of " .. vim.inspect(tex))
  end
end

test("never raises on malformed TeX", function()
  for _, tex in ipairs(MALFORMED) do
    assert_never_raises(tex)
  end
  assert_never_raises(nil)
  assert_never_raises(42)
end)

test("never raises on any prefix of five long equations (half-typed)", function()
  for _, tex in ipairs(LONG_EQUATIONS) do
    for length = 0, #tex do
      assert_never_raises(tex:sub(1, length))
    end
  end
end)

test("half-typed TeX is drawn as far as it goes", function()
  assert_inline({
    { [[\frac{a]], "a/" },
    { "x_{", "x" },
    { [[T = \frac{2}{3k_B N} \sum \frac{1]], "T = 2/(3k_B N) ∑ 1/" },
    { [[\left( x]], "( x" },
    { "\\", "\\" },
  })
end)

test("nesting too deep for the parser comes back as the TeX itself", function()
  local tex = string.rep("{", 300) .. "x"
  assert_eq(math_text.inline(tex), tex)
  assert_deep_eq(math_text.display(tex), { tex })
end)

test("whitespace and control characters in the TeX become spaces", function()
  assert_eq(math_text.inline("a\n+\tb\r\n= c"), "a + b = c")
  assert_eq(math_text.inline("\\text{a\tb}"), "a b")
end)

_H.finish()
