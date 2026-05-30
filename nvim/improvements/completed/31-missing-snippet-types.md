# 31 — Missing Snippet Types

## Problem

The markdown snippet file (`luasnippets/markdown.lua`) has comprehensive coverage of callouts, frontmatter, wikilinks, embeds, footnotes, tasks, tables, code blocks, and template sections (~200+ snippets). However, several standard markdown and HTML constructs have no snippet support at all:

| Syntax | Example | Current Snippet? | Workaround |
|--------|---------|------------------|------------|
| Image link | `![alt](url "title")` | None | Type manually (easy to misplace `!`, `[]`, `()` delimiters) |
| Image from clipboard | `![alt](clipboard)` | None | Paste URL manually, wrap in image syntax |
| HTML comment | `<!-- hidden -->` | None | Type all 7 delimiter characters manually |
| HTML comment block | `<!--\n...\n-->` | None | Same, plus managing newlines |
| Reference-style link | `[text][id]` + `[id]: url` | None | Type both the reference and definition manually, keep them in sync |
| Reference-style image | `![alt][id]` + `[id]: url` | None | Same as above with `!` prefix |
| Highlight | `==text==` | None | Type `==` pairs manually (easy to forget closing `==`) |
| Abbreviation | `*[ABBR]: Full Text` | None | Obscure syntax, hard to remember the `*[...]` prefix |
| Definition list | `term\n: definition` | None | The `: ` prefix at start of line is easy to forget |
| Keyboard key | `<kbd>key</kbd>` | None | 11 characters of HTML tag boilerplate |
| Details/summary | `<details><summary>...</summary>...</details>` | None | 4 HTML tags, must be in correct nesting order |

### Why the Current File Can't Cover These

The existing snippet file focuses on vault-centric constructs (callouts, wikilinks, embeds, frontmatter, template sections). Standard markdown syntax like image links and reference-style links were never added because the vault primarily uses `![[wikilink]]` for images and `[[wikilink]]` for links. However, these standard markdown constructs are needed when:

1. Writing notes that will be exported or shared outside Obsidian/vault context.
2. Embedding external web images (not local vault attachments).
3. Adding HTML comments for draft notes, TODOs, or hidden metadata.
4. Using highlights for emphasis that differs from bold/italic.
5. Creating collapsible content sections with `<details>`.

---

## Goal

1. Add 12 new LuaSnip snippets to `luasnippets/markdown.lua` covering image links, HTML comments, reference-style links, highlights, abbreviations, definition lists, keyboard keys, and details/summary blocks.
2. Use the existing LuaSnip node conventions (`s`, `t`, `i`, `c`, `f`, `rep`) already imported in the file.
3. Use `vim.fn.getreg("+")` in a `function_node` for the clipboard-based image snippet.
4. Use a `function_node` with buffer-appending logic for the reference-style link/image snippets to auto-place the definition at the bottom of the buffer.
5. All snippets must be added inside the `local snippets = { ... }` table (before the closing `}` on line 1554) to remain consistent with the file structure.
6. No new files, modules, or dependencies required.

---

## Approach

### Architecture

All 12 snippets are added to a single new section block inside the existing `snippets` table in `luasnippets/markdown.lua`. They follow the existing pattern:

- Short triggers for common patterns (`img`, `hl`, `kbd`, `def`, `abbr`)
- Descriptive `desc` fields for completion menu display
- `t()` for static text, `i()` for tab stops with sensible defaults
- `f()` for dynamic content (clipboard access, buffer manipulation)
- `c()` for choice alternatives where multiple variants exist
- `rep()` for repeating a previous insert node's content

### Snippet Implementations

#### 1. Image Link (`img`)

Standard markdown image with three tab stops: alt text, URL, optional title.

```lua
s({ trig = "img", desc = "Image ![alt](url)" }, {
  t("!["), i(1, "alt text"), t("]("), i(2, "url"),
  t(' "'), i(3, "title"), t('")'),
}),
```

Output: `![alt text](url "title")`

Tab order: alt text -> URL -> title -> exit.

#### 2. Image Link from Clipboard (`imgc`)

Uses `f()` to read the system clipboard (`+` register) and auto-fill the URL. This avoids the manual paste step when copying an image URL from a browser.

```lua
s({ trig = "imgc", desc = "Image from clipboard ![alt](clipboard)" }, {
  t("!["), i(1, "alt text"), t("]("),
  f(function()
    local clip = vim.fn.getreg("+")
    -- Trim whitespace and newlines from clipboard content
    return vim.trim(clip)
  end),
  t(")"),
}),
```

Output: `![alt text](https://whatever-was-in-clipboard)`

The `vim.trim()` strips trailing newlines that are common when copying from terminals.

#### 3. HTML Comment (`comment`)

Single-line HTML comment with a single tab stop for content.

```lua
s({ trig = "comment", desc = "HTML comment <!-- -->" }, {
  t("<!-- "), i(1, "comment"), t(" -->"),
}),
```

Output: `<!-- comment -->`

#### 4. HTML Comment Block (`commentblock`)

Multi-line HTML comment for hiding larger sections of content.

```lua
s({ trig = "commentblock", desc = "HTML comment block (multi-line)" }, {
  t({ "<!--", "" }), i(1, "comment"), t({ "", "-->" }),
}),
```

Output:
```
<!--
comment
-->
```

#### 5. Reference-Style Link (`reflink`)

This is the most complex snippet. It needs to:
1. Insert `[text][ref-id]` at the cursor position.
2. Append `[ref-id]: url` at the bottom of the buffer.

The approach uses a `function_node` with a post-expand callback pattern. However, LuaSnip's `function_node` evaluates during expansion and cannot easily defer buffer modifications. Instead, we use a simpler two-part approach: the snippet inserts both the reference and the definition separated by blank lines, and the user can move the definition to the bottom of the file if desired.

A cleaner approach: use LuaSnip's `post_expand` callback on the snippet to schedule the buffer append after the snippet is fully expanded.

```lua
s({
  trig = "reflink",
  desc = "Reference-style link [text][id] + definition",
}, {
  t("["), i(1, "link text"), t("]["), i(2, "ref-id"), t("]"),
}, {
  callbacks = {
    [-1] = {
      [ls.events.leave] = function(node, event_args)
        local snip = event_args.snippet or node
        -- Get the ref-id and schedule appending the definition
        local ref_id = snip:get_text(2) or "ref-id"
        if ref_id == "" then ref_id = "ref-id" end
        local line_count = vim.api.nvim_buf_line_count(0)
        local last_line = vim.api.nvim_buf_get_lines(0, line_count - 1, line_count, false)[1] or ""
        local lines_to_add = {}
        if last_line ~= "" then
          table.insert(lines_to_add, "")
        end
        table.insert(lines_to_add, "[" .. ref_id .. "]: ")
        vim.api.nvim_buf_set_lines(0, line_count, line_count, false, lines_to_add)
      end,
    },
  },
}),
```

**Note:** The callback approach is fragile and depends on LuaSnip event timing. A simpler, more reliable alternative places both parts inline:

```lua
s({ trig = "reflink", desc = "Reference-style link [text][id] + definition" }, {
  t("["), i(1, "link text"), t("]["), i(2, "ref-id"), t("]"),
  t({ "", "", "[" }), rep(2), t("]: "), i(3, "url"),
}),
```

Output:
```
[link text][ref-id]

[ref-id]: url
```

The `rep(2)` node mirrors the ref-id from tab stop 2 into the definition line. This is the recommended approach because it uses only standard LuaSnip nodes, is fully predictable, and lets the user see both parts together. The user can cut the definition line and move it to the bottom of the file after expansion.

#### 6. Reference-Style Image (`refimg`)

Same pattern as `reflink` but with `!` prefix.

```lua
s({ trig = "refimg", desc = "Reference-style image ![alt][id] + definition" }, {
  t("!["), i(1, "alt text"), t("]["), i(2, "ref-id"), t("]"),
  t({ "", "", "[" }), rep(2), t("]: "), i(3, "url"), t(' "'), i(4, "title"), t('"'),
}),
```

Output:
```
![alt text][ref-id]

[ref-id]: url "title"
```

#### 7. Highlight (`hl`)

Wraps text in `==` markers for highlight syntax (supported by Obsidian, some markdown renderers via mark extension).

```lua
s({ trig = "hl", desc = "Highlight ==text==" }, {
  t("=="), i(1, "highlighted text"), t("=="),
}),
```

Output: `==highlighted text==`

An alias trigger `mark` expands identically:

```lua
s({ trig = "mark", desc = "Highlight ==text== (alias)" }, {
  t("=="), i(1, "highlighted text"), t("=="),
}),
```

#### 8. Highlight with Prefix (`hl!`, `hl?`)

Prefixed highlights for semantic emphasis. These use a convention where the first character inside the highlight indicates its intent: `!` for important, `?` for questions.

```lua
s({ trig = "hl!", desc = "Important highlight ==!text==" }, {
  t("==!"), i(1, "important"), t("=="),
}),

s({ trig = "hl?", desc = "Question highlight ==?text==" }, {
  t("==?"), i(1, "question"), t("=="),
}),
```

Output: `==!important==` / `==?question==`

**Note:** These triggers contain non-alphanumeric characters (`!`, `?`). They will work because the blink.cmp keyword patch sets `iskeyword` to include `@,48-57,_,-,;,192-255`. The `!` and `?` characters are **not** in this set, so these triggers will only match if the user types the full trigger. If completion does not trigger for `hl!`, the user can invoke completion manually or use the `hl` snippet and type the prefix character inside the tab stop.

#### 9. Abbreviation (`abbr`)

Markdown abbreviation syntax (supported by PHP Markdown Extra, some renderers).

```lua
s({ trig = "abbr", desc = "Abbreviation *[ABBR]: Full Text" }, {
  t("*["), i(1, "ABBR"), t("]: "), i(2, "Full Text"),
}),
```

Output: `*[ABBR]: Full Text`

#### 10. Definition List (`def`)

Definition list syntax with term and definition. Supported by PHP Markdown Extra, Pandoc, and some renderers.

```lua
s({ trig = "def", desc = "Definition list (term + definition)" }, {
  i(1, "Term"), t({ "", ": " }), i(2, "Definition"),
}),
```

Output:
```
Term
: Definition
```

#### 11. Keyboard Key (`kbd`)

HTML `<kbd>` element for keyboard key references. Common in documentation and READMEs.

```lua
s({ trig = "kbd", desc = "Keyboard key <kbd>...</kbd>" }, {
  t("<kbd>"), i(1, "key"), t("</kbd>"),
}),
```

Output: `<kbd>key</kbd>`

A variant for key combinations (e.g., `Ctrl+C`):

```lua
s({ trig = "kbdc", desc = "Keyboard combo <kbd>mod</kbd>+<kbd>key</kbd>" }, {
  t("<kbd>"), i(1, "Ctrl"), t("</kbd>+<kbd>"), i(2, "key"), t("</kbd>"),
}),
```

Output: `<kbd>Ctrl</kbd>+<kbd>key</kbd>`

#### 12. Details/Summary (`details`)

HTML5 `<details>` element for collapsible content. Renders as a disclosure widget in browsers and GitHub markdown.

```lua
s({ trig = "details", desc = "Collapsible <details><summary>...</summary>...</details>" }, {
  t({ "<details>", "<summary>" }), i(1, "Click to expand"), t({ "</summary>", "", "" }),
  i(2, "Hidden content here"),
  t({ "", "", "</details>" }),
}),
```

Output:
```html
<details>
<summary>Click to expand</summary>

Hidden content here

</details>
```

The blank lines around the content are important: many markdown renderers require them to process markdown syntax inside HTML blocks.

---

## Implementation Steps

### Step 1: Add the new snippet section to `luasnippets/markdown.lua`

**File:** `/home/andrew-cmmg/.config/nvim/luasnippets/markdown.lua`

Insert the following block **after** the generic reusable section snippets (after the `;section-log` snippet at line ~1553) and **before** the closing `}` of the `local snippets` table (line 1554).

```lua
  -- =========================================================================
  -- Image, HTML, reference link, and misc markdown snippets
  -- =========================================================================

  -- Image link: ![alt](url "title")
  s({ trig = "img", desc = "Image ![alt](url)" }, {
    t("!["), i(1, "alt text"), t("]("), i(2, "url"),
    t(' "'), i(3, "title"), t('")'),
  }),

  -- Image link from clipboard: auto-fills URL from system clipboard
  s({ trig = "imgc", desc = "Image from clipboard ![alt](clipboard)" }, {
    t("!["), i(1, "alt text"), t("]("),
    f(function()
      local clip = vim.fn.getreg("+")
      return vim.trim(clip)
    end),
    t(")"),
  }),

  -- HTML comment (single-line)
  s({ trig = "comment", desc = "HTML comment <!-- -->" }, {
    t("<!-- "), i(1, "comment"), t(" -->"),
  }),

  -- HTML comment block (multi-line)
  s({ trig = "commentblock", desc = "HTML comment block (multi-line)" }, {
    t({ "<!--", "" }), i(1, "comment"), t({ "", "-->" }),
  }),

  -- Reference-style link: [text][id] with definition below
  s({ trig = "reflink", desc = "Reference-style link [text][id] + definition" }, {
    t("["), i(1, "link text"), t("]["), i(2, "ref-id"), t("]"),
    t({ "", "", "[" }), rep(2), t("]: "), i(3, "url"),
  }),

  -- Reference-style image: ![alt][id] with definition below
  s({ trig = "refimg", desc = "Reference-style image ![alt][id] + definition" }, {
    t("!["), i(1, "alt text"), t("]["), i(2, "ref-id"), t("]"),
    t({ "", "", "[" }), rep(2), t("]: "), i(3, "url"), t(' "'), i(4, "title"), t('"'),
  }),

  -- Highlight ==text==
  s({ trig = "hl", desc = "Highlight ==text==" }, {
    t("=="), i(1, "highlighted text"), t("=="),
  }),

  -- Highlight ==text== (alias)
  s({ trig = "mark", desc = "Highlight ==text== (alias)" }, {
    t("=="), i(1, "highlighted text"), t("=="),
  }),

  -- Important highlight ==!text==
  s({ trig = "hl!", desc = "Important highlight ==!text==" }, {
    t("==!"), i(1, "important"), t("=="),
  }),

  -- Question highlight ==?text==
  s({ trig = "hl?", desc = "Question highlight ==?text==" }, {
    t("==?"), i(1, "question"), t("=="),
  }),

  -- Abbreviation *[ABBR]: Full Text
  s({ trig = "abbr", desc = "Abbreviation *[ABBR]: Full Text" }, {
    t("*["), i(1, "ABBR"), t("]: "), i(2, "Full Text"),
  }),

  -- Definition list: term + : definition
  s({ trig = "def", desc = "Definition list (term + definition)" }, {
    i(1, "Term"), t({ "", ": " }), i(2, "Definition"),
  }),

  -- Keyboard key <kbd>key</kbd>
  s({ trig = "kbd", desc = "Keyboard key <kbd>...</kbd>" }, {
    t("<kbd>"), i(1, "key"), t("</kbd>"),
  }),

  -- Keyboard combo <kbd>mod</kbd>+<kbd>key</kbd>
  s({ trig = "kbdc", desc = "Keyboard combo <kbd>mod</kbd>+<kbd>key</kbd>" }, {
    t("<kbd>"), i(1, "Ctrl"), t("</kbd>+<kbd>"), i(2, "key"), t("</kbd>"),
  }),

  -- Collapsible details/summary block
  s({ trig = "details", desc = "Collapsible <details><summary>...</summary>...</details>" }, {
    t({ "<details>", "<summary>" }), i(1, "Click to expand"), t({ "</summary>", "", "" }),
    i(2, "Hidden content here"),
    t({ "", "", "</details>" }),
  }),
```

### Step 2: Verify no trigger collisions

Check that none of the new triggers conflict with existing snippets in the file:

| New Trigger | Collision? | Resolution |
|-------------|-----------|------------|
| `img` | No existing `img` trigger | Safe |
| `imgc` | No existing `imgc` trigger | Safe |
| `comment` | No existing `comment` trigger | Safe |
| `commentblock` | No existing `commentblock` trigger | Safe |
| `reflink` | No existing `reflink` trigger | Safe |
| `refimg` | No existing `refimg` trigger | Safe |
| `hl` | No existing `hl` trigger | Safe |
| `mark` | No existing `mark` trigger | Safe |
| `hl!` | No existing `hl!` trigger | Safe |
| `hl?` | No existing `hl?` trigger | Safe |
| `abbr` | No existing `abbr` trigger | Safe |
| `def` | No existing `def` trigger | Safe |
| `kbd` | No existing `kbd` trigger | Safe |
| `kbdc` | No existing `kbdc` trigger | Safe |
| `details` | No existing `details` trigger | Safe |

Also check against `friendly-snippets` (loaded via `from_vscode`). The `friendly-snippets` markdown file may include a `detail` trigger for `<details>`, but LuaSnip allows multiple snippets with the same trigger (shown as separate completion items). The `desc` field differentiates them in the completion menu.

### Step 3: Reload and verify

After editing the file:

1. Restart Neovim (or run `:luafile ~/.config/nvim/luasnippets/markdown.lua` -- though full restart is more reliable).
2. Open a `.md` file.
3. Type each trigger and verify expansion via completion.

---

## Testing

### Manual Verification Checklist

For each snippet, open a new markdown buffer and verify:

1. **`img`** -- Type `img`, select from completion, press Tab through: `alt text` -> `url` -> `title`. Confirm output: `![alt text](url "title")`.

2. **`imgc`** -- Copy a URL to clipboard (`echo "https://example.com/image.png" | xclip -sel clipboard`), type `imgc`, expand. Confirm URL is auto-filled. Verify only `alt text` is a tab stop.

3. **`comment`** -- Type `comment`, expand. Confirm output: `<!-- comment -->`. Cursor starts on `comment`.

4. **`commentblock`** -- Type `commentblock`, expand. Confirm three-line output with `<!--`, cursor on content line, `-->`.

5. **`reflink`** -- Type `reflink`, expand. Tab through: `link text` -> `ref-id` -> `url`. Confirm `ref-id` is mirrored in the definition line via `rep(2)`. Change the ref-id in the first position and verify the definition line updates.

6. **`refimg`** -- Same as `reflink` but with `!` prefix and additional `title` tab stop.

7. **`hl`** -- Type `hl`, expand. Confirm `==highlighted text==`. Tab stop on content.

8. **`mark`** -- Same output as `hl` (alias).

9. **`hl!`** -- Type `hl!` and trigger manually if needed. Confirm `==!important==`.

10. **`hl?`** -- Type `hl?` and trigger manually if needed. Confirm `==?question==`.

11. **`abbr`** -- Type `abbr`, expand. Confirm `*[ABBR]: Full Text`. Two tab stops.

12. **`def`** -- Type `def`, expand. Confirm two-line output: `Term` then `: Definition`. Cursor starts on `Term`.

13. **`kbd`** -- Type `kbd`, expand. Confirm `<kbd>key</kbd>`. Single tab stop.

14. **`kbdc`** -- Type `kbdc`, expand. Confirm `<kbd>Ctrl</kbd>+<kbd>key</kbd>`. Two tab stops.

15. **`details`** -- Type `details`, expand. Confirm multi-line HTML with `<details>`, `<summary>`, content area, `</details>`. Two tab stops: summary text and content.

### Edge Cases to Verify

- **`imgc` with empty clipboard**: Should produce `![alt text]()` (empty string from `vim.trim("")`).
- **`imgc` with multi-line clipboard**: `vim.trim()` strips leading/trailing whitespace; multi-line content will be collapsed to a single line by `f()` (LuaSnip function nodes return strings, not tables).
- **`reflink` rep node**: Change the ref-id text and verify the `rep(2)` node updates in real-time as you type.
- **`hl!` / `hl?` completion trigger**: If blink.cmp does not offer these in the completion menu due to `!`/`?` not being in `iskeyword`, verify they can be triggered by typing the full trigger and pressing the expand key.

---

## Risks & Mitigations

### 1. `hl!` and `hl?` trigger characters not in `iskeyword`

**Risk:** The `!` and `?` characters are not included in the blink.cmp keyword patch (`@,48-57,_,-,;,192-255`). blink.cmp may split the trigger at `hl` and never match `hl!` or `hl?` as a single completion candidate.

**Mitigation:** Two options:
- **Option A (recommended):** Keep the snippets. Users type `hl` and see all three highlight variants (`hl`, `hl!`, `hl?`) in the completion menu. blink.cmp's fuzzy matching may match `hl!` when the user types `hl!` even if `!` is not in `iskeyword`, since the prefix `hl` matches.
- **Option B (fallback):** If Option A fails, change `hl!` to `hli` (highlight important) and `hl?` to `hlq` (highlight question). This uses only alphanumeric characters.

### 2. `imgc` clipboard access in SSH / headless environments

**Risk:** `vim.fn.getreg("+")` reads the system clipboard. In SSH sessions without X11 forwarding or clipboard tools (`xclip`, `xsel`, `wl-copy`), the `+` register may be empty or unavailable.

**Mitigation:** The snippet degrades gracefully: if the clipboard is empty, the URL field is simply empty and the user types the URL manually. No error is thrown. The `vim.trim()` call handles `nil` gracefully (Neovim's `getreg` always returns a string, never nil).

### 3. `reflink` / `refimg` definition placement

**Risk:** The `rep(2)` approach places the reference definition immediately below the reference, not at the bottom of the file. This differs from the convention of collecting all reference definitions at the end of a document.

**Mitigation:** This is an intentional design choice. Placing both parts together lets the user see the full context during expansion. After expanding, the user can cut the definition line and move it to the file bottom. A future improvement could add a command (`:VaultRefDefs`) to collect all scattered reference definitions and move them to the end of the buffer.

### 4. `comment` trigger collision with friendly-snippets

**Risk:** The `friendly-snippets` package may include a `comment` trigger for markdown. If so, the user would see two `comment` entries in the completion menu.

**Mitigation:** LuaSnip handles duplicate triggers by showing both entries with their `desc` fields. The user can differentiate them in the completion menu. If this is a problem, the trigger can be changed to `htmlcomment` or `cmt`.

### 5. `def` trigger collision with future snippets

**Risk:** `def` is a short, generic trigger that could conflict with a definition-related snippet added later (e.g., a footnote definition or a glossary definition).

**Mitigation:** The `desc` field ("Definition list (term + definition)") clearly identifies this snippet in the completion menu. If a collision arises, the trigger can be renamed to `deflist`.

### 6. `details` blank line requirements

**Risk:** Some markdown renderers require blank lines between HTML tags and markdown content inside `<details>`. Others do not. The snippet includes blank lines, which is the more compatible approach but may produce extra whitespace in renderers that don't need them.

**Mitigation:** The blank lines are harmless in all tested renderers (GitHub, Obsidian, Pandoc). They ensure markdown inside the `<details>` block is parsed correctly. No action needed.

### 7. Backwards compatibility

**Risk:** None of the new snippets modify existing triggers or behavior. All additions are purely additive.

**Mitigation:** No existing snippets are changed. The file structure (imports, `snippets` table, `autosnippets` table, return statement) remains identical. The new block is inserted before the closing `}` of the `snippets` table.
