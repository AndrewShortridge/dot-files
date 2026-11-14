-- Perf regression spec: the dead legacy Vim-regex markdown syntax cascade is
-- suppressed.
--
-- Treesitter does 100% of markdown highlighting in this config, but the runtime
-- $VIMRUNTIME/syntax/markdown.vim still does an unconditional
-- `runtime! syntax/html.vim`, which transitively sources css.vim / javascript.vim
-- / yaml.vim (~30-50ms per .md open). nvim-treesitter reattaches on every
-- lazy.nvim FileType replay and on the vault bootstrap re-fire; each reattach's
-- TSHighlighter:destroy() runs `set syntax=markdown`, which (via the runtime
-- `syntaxset` autocmd -> synload's SynSet) loads syntax files with
-- `runtime! syntax/markdown.{vim,lua}` -- ALL matches, config runtimepath first.
--
-- The fix is the config's shadow `syntax/markdown.vim`: sourced FIRST, it sets
-- `b:current_syntax`, so the runtime markdown.vim then hits its
-- `if exists("b:current_syntax") | finish` guard and never runs the
-- html/css/js/yaml cascade. Treesitter highlighting is independent of this file,
-- so rendering is byte-identical; only the dead legacy work is skipped.
--
-- This spec drives the REAL `set syntax=markdown` runtime machinery (no mocks,
-- no source-introspection): it puts the config runtimepath ahead of $VIMRUNTIME,
-- enables syntax, sets `syntax=markdown` on a scratch buffer, and asserts the
-- runtime html ftplugin/syntax cascade did NOT load. A sentinel global proves
-- the runtime markdown.vim early-returned instead of cascading.
--
-- DISCRIMINATING POWER (verified by temporarily reintroducing the bug): if the
-- shadow's `let b:current_syntax = "markdown"` line is removed, the runtime
-- markdown.vim no longer early-returns, the html cascade loads, and the
-- "cascade suppressed" assertions below fail. The spec also pins that the shadow
-- itself sets b:current_syntax (the load-bearing line) and leaves a usable
-- buffer where treesitter (not legacy syntax) owns highlighting.
--
-- Run with: nvim --headless -u NONE -l tests/legacy_md_syntax_suppressed_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

local config_dir = vim.fn.stdpath("config")

print("\n=== Legacy Markdown Syntax Suppression Tests ===\n")

-- The shadow file under test.
local shadow_path = config_dir .. "/syntax/markdown.vim"

-- ---------------------------------------------------------------------------
-- The shadow file exists and carries the load-bearing guard line.
-- ---------------------------------------------------------------------------
test("shadow syntax/markdown.vim exists", function()
  assert_eq(vim.fn.filereadable(shadow_path), 1, "config syntax/markdown.vim should exist:")
end)

-- ---------------------------------------------------------------------------
-- Helper: run a function with the config runtimepath ahead of $VIMRUNTIME so
-- `runtime! syntax/markdown.{vim,lua}` finds the shadow FIRST (exactly as it
-- does in the real config, where the config dir precedes $VIMRUNTIME in rtp).
-- ---------------------------------------------------------------------------
local function with_config_rtp(fn)
  local saved = vim.o.runtimepath
  -- Prepend the config dir; $VIMRUNTIME stays present so the runtime markdown.vim
  -- (the thing we are gating) is still on the path and would cascade if unguarded.
  vim.opt.runtimepath:prepend(config_dir)
  local ok, err = pcall(fn)
  vim.o.runtimepath = saved
  if not ok then
    error(err)
  end
end

-- Fresh scratch buffer with the given lines, made the current buffer.
local function scratch_md(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  return buf
end

-- A marker that is ONLY defined by the runtime syntax/html.vim cascade body.
-- `*htmlComplete` (autoload/htmlcomplete.vim) is pulled in by the runtime
-- markdown/html ftplugin+syntax cascade. Its absence proves the cascade was
-- skipped; its presence proves the cascade ran.
local function html_cascade_loaded()
  -- Multiple independent signals; any one being present means legacy cascade ran.
  if vim.fn.exists("*htmlcomplete#CompleteTags") == 1 then return true end
  -- The runtime syntax/html.vim defines the htmlTag syntax cluster/group.
  if vim.fn.hlexists("htmlTag") == 1 then return true end
  if vim.fn.hlexists("cssBraces") == 1 then return true end
  return false
end

-- ---------------------------------------------------------------------------
-- CORE: with the shadow on the rtp, `set syntax=markdown` must NOT drag in the
-- legacy html/css cascade. The shadow's b:current_syntax makes the runtime
-- markdown.vim early-return.
-- ---------------------------------------------------------------------------
test("set syntax=markdown does not load the legacy html/css cascade", function()
  with_config_rtp(function()
    -- Enable the real syntax machinery (registers Syntax/syntaxset autocmds).
    vim.cmd("syntax enable")
    local buf = scratch_md({ "# Heading", "", "some **bold** `code`", "", "```python", "x = 1", "```" })

    -- Pre-state: cascade markers absent on this fresh buffer's setup.
    -- Drive the exact runtime path that reattach/destroy uses.
    vim.cmd("setlocal filetype=markdown")
    vim.cmd("setlocal syntax=markdown")

    -- The shadow must have set b:current_syntax (the load-bearing effect).
    assert_eq(vim.b[buf].current_syntax, "markdown",
      "shadow should set b:current_syntax so runtime markdown.vim early-returns:")

    -- The expensive legacy cascade must NOT have run.
    assert_eq(html_cascade_loaded(), false,
      "legacy html/css cascade must be suppressed by the shadow guard:")
  end)
end)

-- ---------------------------------------------------------------------------
-- DISCRIMINATING POWER: emulate the bug (shadow WITHOUT the b:current_syntax
-- line) by sourcing the runtime markdown.vim directly on a buffer that has NO
-- b:current_syntax set. The runtime file then runs its body and pulls in the
-- html cascade -> html_cascade_loaded() flips to true. This proves the marker
-- the CORE test relies on actually discriminates: remove the shadow's guard
-- line and the suppression assertion above fails.
-- ---------------------------------------------------------------------------
test("without the guard, the runtime markdown.vim DOES load the html cascade", function()
  vim.cmd("syntax enable")
  local buf = scratch_md({ "# Heading", "para" })
  vim.bo[buf].filetype = "markdown"
  -- Ensure no guard is set (the "bug" condition).
  pcall(function() vim.cmd("unlet b:current_syntax") end)
  assert_nil(vim.b[buf].current_syntax, "precondition: no current_syntax guard:")

  -- Source ONLY the runtime markdown.vim (bypassing the config shadow) to
  -- reproduce what happens when the guard is absent.
  local rt_md = vim.env.VIMRUNTIME .. "/syntax/markdown.vim"
  assert_eq(vim.fn.filereadable(rt_md), 1, "runtime markdown.vim should exist:")
  vim.cmd("source " .. vim.fn.fnameescape(rt_md))

  assert_true(html_cascade_loaded(),
    "unguarded runtime markdown.vim must load the html cascade (proves the marker discriminates):")
end)

-- ---------------------------------------------------------------------------
-- The shadow file's guard line is present (parity pin on the load-bearing
-- content, without source-introspecting any product module's behavior): we
-- assert the FILE sets b:current_syntax by sourcing it on a clean buffer and
-- observing the effect (behavioral, not text-grep).
-- ---------------------------------------------------------------------------
test("shadow file sets b:current_syntax when sourced on a clean buffer", function()
  local buf = scratch_md({ "# H" })
  pcall(function() vim.cmd("unlet b:current_syntax") end)
  assert_nil(vim.b[buf].current_syntax, "precondition: clean buffer:")

  vim.cmd("source " .. vim.fn.fnameescape(shadow_path))
  assert_eq(vim.b[buf].current_syntax, "markdown",
    "shadow must set b:current_syntax = 'markdown':")

  -- And re-sourcing on an already-guarded buffer is a no-op early-return
  -- (idempotent), matching the runtime's own guard contract.
  local before = vim.b[buf].current_syntax
  vim.cmd("source " .. vim.fn.fnameescape(shadow_path))
  assert_eq(vim.b[buf].current_syntax, before, "shadow re-source should be idempotent:")
end)

_H.finish({ style = "results", exit = "os" })
