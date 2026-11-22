# The transcript view has its own filetype, not markdown

The transcript view is a buffer this config builds line by line, and it colours those lines itself from what the builder knows about each one; no parser runs on it. It is not `filetype=markdown`, even though the assistant's text is markdown and is therefore shown as written.

Setting `filetype=markdown` on the view was measured: it attached 36 buffer-local editing keymaps and 19 autocmds (the markdown ftplugin, both renderers, the vault's hooks) to a read-only buffer, and the largest views were still left uncoloured by the treesitter size guard (1.5 MB / 20,000 lines). Attaching only the markdown parser to an own filetype cost about 0.7 s of parsing on a 1.5 MB view and required the whole layout to remain valid markdown, with every tool output fenced correctly.

## Consequences

- Markdown in a response is not rendered in the view. Rendering one response on request is a separate feature, not a reason to change the filetype.
- The view's cost does not grow with a grammar: highlighting is decided when a line is built.
