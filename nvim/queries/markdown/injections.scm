; Code-fence language injection — WHITELISTED to ensure_installed languages.
;
; This file deliberately has NO `; extends` / `; inherits` modeline: it is a
; REPLACING query that fully supersedes nvim-treesitter's default
; markdown/injections.scm. The default resolves ANY fence info-string via
; `set-lang-from-info-string!`, so every fence could spawn a child parser —
; fence-heavy notes multiply parse cost unboundedly. We bound injection to
; exactly the parsers in `ensure_installed` (lua/andrew/plugins/treesitter.lua).
;
; The `#any-of?` guard matches the RAW info-string text, so it enumerates common
; aliases (py, js, ts, rs, sh, yml, …) alongside canonical names — otherwise
; alias fences silently lose highlighting. We KEEP the `set-lang-from-info-string!`
; directive after the guard so those aliases still resolve to the right parser
; (e.g. `js` -> javascript, `sh` -> bash, `tsx` -> tsx); the guard bounds WHICH
; fences run it. That directive is safe here: ts_directive_compat.apply() patches
; its 0.12 node-list crash. Only aliases that the directive actually resolves to
; an installed parser are listed (verified empirically); aliases that resolve to a
; non-installed parser name — e.g. `docker`(->docker, parser is `dockerfile`),
; `viml`(->viml, parser is `vim`), `tex`(->plaintex), `shell`/`zsh` — are omitted
; because they would not highlight anyway and listing them implies false coverage.
;
; The four non-fence rules below (html_block, minus/plus metadata,
; inline/pipe_table_cell) are copied verbatim from the default: replacing rather
; than extending drops them otherwise, breaking frontmatter YAML/TOML injection,
; HTML-in-markdown, and all markdown_inline highlighting. snacks.nvim still
; appends its `; extends` math->latex injection, so it is intentionally absent.

(fenced_code_block
  (info_string
    (language) @_lang)
  (#any-of? @_lang
    "json"
    "yaml" "yml"
    "javascript" "js" "jsx"
    "typescript" "ts"
    "tsx"
    "html"
    "css"
    "vue"
    "bash" "sh"
    "dockerfile"
    "gitignore"
    "lua"
    "vim"
    "rust" "rs"
    "c"
    "fortran" "f90" "f95"
    "python" "py"
    "latex"
    "query"
    "vimdoc" "help")
  (code_fence_content) @injection.content
  (#set-lang-from-info-string! @_lang))

((html_block) @injection.content
  (#set! injection.language "html")
  (#set! injection.combined)
  (#set! injection.include-children))

((minus_metadata) @injection.content
  (#set! injection.language "yaml")
  (#offset! @injection.content 1 0 -1 0)
  (#set! injection.include-children))

((plus_metadata) @injection.content
  (#set! injection.language "toml")
  (#offset! @injection.content 1 0 -1 0)
  (#set! injection.include-children))

([
  (inline)
  (pipe_table_cell)
] @injection.content
  (#set! injection.language "markdown_inline"))
