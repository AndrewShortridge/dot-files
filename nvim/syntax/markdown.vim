" Shadow markdown syntax file — suppress the dead legacy Vim-regex cascade.
"
" Treesitter provides 100% of markdown highlighting in this config (markdown +
" markdown_inline parsers, fenced code via markdown_inline injections), so the
" runtime $VIMRUNTIME/syntax/markdown.vim produces nothing visible — yet it does
" an unconditional `runtime! syntax/html.vim`, which transitively sources
" css.vim / javascript.vim / yaml.vim (~30-50ms per .md open). nvim-treesitter
" reattaches on every lazy.nvim FileType replay (one per ft-gated markdown
" plugin) and on the vault bootstrap re-fire; each reattach's
" TSHighlighter:destroy() runs `set syntax=markdown`, dragging in that cascade.
"
" `set syntax=markdown` loads syntax files via `runtime! syntax/markdown.{vim,lua}`
" (ALL matches, config rtp first). This file is sourced FIRST and sets
" b:current_syntax, so the runtime markdown.vim then early-returns at its
" `if exists("b:current_syntax") | finish` guard — the html/css/js/yaml cascade
" never runs. Treesitter highlighting is independent of this file, so rendering
" is byte-identical; only the dead legacy work is skipped.

if exists("b:current_syntax")
  finish
endif

let b:current_syntax = "markdown"
