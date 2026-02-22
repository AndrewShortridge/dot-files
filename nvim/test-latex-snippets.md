# LaTeX Snippet Test File

## Instructions

Open this file in Neovim and test each section in insert mode.
Delete the test lines and retype them to verify snippet expansion.

---

## 1. Math Mode Entry

Type `mk` in normal text to get inline math: $cursor here$
Type `dm` in normal text to get display math:

$$
cursor here
$$

---

## 2. Fractions (must be inside $...$ or $$...$$)

Enter inline math first with `mk`, then type:
- `ff` → $\frac{num}{den}$
- `//` → $\frac{num}{den}$

---

## 3. Sub/Superscripts (inside math)

- `td` → $x^{power}$
- `sb` → $x_{index}$
- `sr` → $x^2$
- `cb` → $x^3$
- `inv` → $A^{-1}$

---

## 4. Greek Letters (inside math, prefix `;`)

- `;a` → $\alpha$
- `;b` → $\beta$
- `;g` → $\gamma$
- `;G` → $\Gamma$
- `;d` → $\delta$
- `;D` → $\Delta$
- `;e` → $\epsilon$
- `;ve` → $\varepsilon$
- `;t` → $\theta$
- `;l` → $\lambda$
- `;m` → $\mu$
- `;s` → $\sigma$
- `;o` → $\omega$
- `;O` → $\Omega$
- `;f` → $\phi$
- `;vf` → $\varphi$

---

## 5. Operators & Relations (inside math)

- `<=` → $\leq$
- `>=` → $\geq$
- `!=` → $\neq$
- `~~` → $\approx$
- `~=` → $\cong$
- `>>` → $\gg$
- `<<` → $\ll$
- `xx` → $\times$
- `**` → $\cdot$
- `->` → $\to$
- `=>` → $\implies$
- `iff` → $\iff$
- `inn` → $\in$
- `notin` → $\notin$
- `EE` → $\exists$
- `AA` → $\forall$
- `uu` → $\cup$
- `nn` → $\cap$

---

## 6. Big Operators (inside math)

- `sum` → $\sum_{i=1}^{n}$
- `prod` → $\prod_{i=1}^{n}$
- `lim` → $\lim_{n \to \infty}$
- `dint` → $\int_{a}^{b} f(x) \,dx$

---

## 7. Symbols (inside math)

- `ooo` → $\infty$
- `par` → $\partial$
- `nab` → $\nabla$
- `...` → $\ldots$
- `ddd` → $\,d$ (differential d)

---

## 8. Decorators (inside math)

- `hat` → $\hat{x}$
- `bar` → $\bar{x}$
- `vec` → $\vec{v}$
- `dot` → $\dot{x}$
- `ddot` → $\ddot{x}$
- `tld` → $\tilde{x}$

---

## 9. Delimiters (inside math)

- `lr(` → $\left( x \right)$
- `lr[` → $\left[ x \right]$
- `lr{` → $\left\{ x \right\}$
- `lr|` → $\left| x \right|$
- `lra` → $\left\langle x \right\rangle$

---

## 10. Math Environments (inside math)

- `pmat` → $\begin{pmatrix} a & b \end{pmatrix}$
- `bmat` → $\begin{bmatrix} a & b \end{bmatrix}$
- `case` → $\begin{cases} x & y \end{cases}$

---

## 11. Text & Font Commands (inside math)

- `textt` → $\text{hello}$
- `RR` → $\mathbb{R}$
- `ZZ` → $\mathbb{Z}$
- `NN` → $\mathbb{N}$
- `QQ` → $\mathbb{Q}$
- `CC` → $\mathbb{C}$

---

## 12. Combined Examples

The gradient is $\nabla f = \frac{\partial f}{\partial x} \hat{x} + \frac{\partial f}{\partial y} \hat{y}$

$$
\int_{-\infty}^{\infty} e^{-x^2} \,dx = \sqrt{\pi}
$$

For all $\epsilon > 0$, there exists $\delta > 0$ such that $|f(x) - L| < \epsilon$

$$
\sum_{i=1}^{n} i = \frac{n(n+1)}{2}
$$

---

## 13. Negative Tests (should NOT expand)

These should NOT trigger snippets because they are outside math:

- The word "diff" contains ff but should not become a fraction
- The inequality a <= b in prose should stay as <=
- Typing mk at a word boundary creates math, but "bookmark" should not
