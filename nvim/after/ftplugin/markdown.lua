-- =============================================================================
-- Guard nvim's markdown gO / ]] / [[ against running in a non-markdown buffer
-- =============================================================================
-- $VIMRUNTIME/ftplugin/markdown.lua binds three buffer-local keys to
-- vim.treesitter._headings: gO (show_toc), ]] and [[ (jump). Those functions
-- are unsafe outside markdown/vimdoc:
--
--   _headings.get_headings() resolves `lang` from the buffer's filetype and
--   returns early only when that is nil. For any filetype that HAS a treesitter
--   language but no entry in its hardcoded `heading_queries` table -- fortran,
--   lua, python, everything except markdown and vimdoc -- it sails past the
--   guard and calls ts.query.parse(lang, nil). The nil query reaches
--   vim.func._memoize's hash, which table.concat's it, and the user sees:
--
--     E5108: ... _memoize.lua:79: invalid value (nil) at index 2 in table for 'concat'
--
-- That is a genuine upstream bug (runtime/lua/vim/treesitter/_headings.lua:52-57
-- checks `lang` but not `heading_queries[lang]`), and it was hit here: gO in a
-- .f90 buffer produced exactly that traceback, through markdown.lua:4.
--
-- How a markdown buffer-local mapping came to be live in a Fortran buffer was
-- NOT reproducible -- nvim 0.12 drops ftplugin buffer-local maps on every
-- filetype-change path tried (:setfiletype, vim.bo.filetype, and :edit reusing
-- an unnamed buffer). So this is deliberately a DEFENSIVE fix: rather than
-- chase the path, make the mapping harmless wherever it ends up. It re-binds
-- the same three keys, buffer-locally, to wrappers that check the buffer's
-- CURRENT language before touching _headings and otherwise do the sensible
-- default. after/ftplugin runs last, so these replace the runtime versions.
--
-- If upstream adds the missing guard, this file can go.

-- The only two languages _headings has queries for.
local HEADING_LANGS = { markdown = true, vimdoc = true }

--- Does the CURRENT buffer's language actually have heading support?
--- Checked at keypress time, not at ftplugin time -- that is the whole point.
local function has_headings()
  local ok, lang = pcall(vim.treesitter.language.get_lang, vim.bo.filetype)
  return ok and lang ~= nil and HEADING_LANGS[lang] == true
end

vim.keymap.set("n", "gO", function()
  if has_headings() then
    require("vim.treesitter._headings").show_toc()
  else
    -- What nvim's own global gO does (runtime/lua/vim/_core/defaults.lua).
    vim.lsp.buf.document_symbol()
  end
end, { buffer = 0, silent = true, desc = "Show an Outline of the current buffer" })

for lhs, count in pairs({ ["]]"] = 1, ["[["] = -1 }) do
  vim.keymap.set("n", lhs, function()
    if has_headings() then
      require("vim.treesitter._headings").jump({ count = count })
    else
      -- Fall back to the built-in section motion. `normal!` does not remap, so
      -- this cannot recurse into this mapping.
      vim.cmd("normal! " .. vim.v.count1 .. lhs)
    end
  end, {
    buffer = 0,
    silent = false,
    desc = count > 0 and "Jump to next section" or "Jump to previous section",
  })
end

-- No teardown is added here on purpose. $VIMRUNTIME/ftplugin/markdown.lua runs
-- BEFORE this file and already appends
--   | silent! nunmap <buffer> gO | silent! nunmap <buffer> ]] | ... [[
-- to 'undo_ftplugin' for the very same three keys. Our mappings replace its
-- mappings on the same lhs, so that teardown removes ours too. Appending a
-- second copy only guaranteed a FAILING :nunmap (the first one already removed
-- the mapping), which set v:errmsg = "E31: No such mapping" on every markdown
-- buffer -- twice, since vault/init.lua re-fires FileType once.

-- =============================================================================
-- Re-assert options the runtime markdown ftplugin clobbers
-- =============================================================================
-- Load order is: config ftplugin/markdown.lua -> $VIMRUNTIME/ftplugin/markdown.vim
-- -> this file. The runtime script resets 'formatlistpat' to its numbered-list-
-- only default (dropping the `- * +` bullets and the `[ ]`/`[x]` checkbox part
-- that align wrapped list text under its own first character) and sets
-- sw/ts/sts to 4, while the config global is 2 -- and list-continuation's
-- outdent-on-empty-bullet reads 'shiftwidth'. after/ftplugin runs last, so put
-- the config values back here.
vim.bo.formatlistpat =
  [[^\s*[-*+]\s\+\%(\[[ x~>!?/-]\]\s\+\)\?\|^\s*\d\+[.)]\s\+\%(\[[ x~>!?/-]\]\s\+\)\?]]
vim.bo.shiftwidth = 2
vim.bo.tabstop = 2
vim.bo.softtabstop = 2
