-- Unit tests for lua/andrew/vault/embed_images.lua (pure helpers only)
-- Run with: nvim --headless -u NONE -l tests/embed_helpers_spec.lua
--
-- NOTE on scope: `is_image_embed` and `get_image_name` were audited as the
-- REAL pure embed classification helpers; they live in embed_images.lua, not
-- embed.lua (embed.lua delegates via `images.is_image_embed`). The "slug
-- heading match" used by the embed system is just link_utils.heading_to_slug,
-- which is covered by link_utils_spec.lua, so it is intentionally not retested
-- here.

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_false

-- ============================================================================
-- Load module under test
-- ============================================================================
package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local embed_images = require("andrew.vault.embed_images")

-- ============================================================================
-- Tests
-- ============================================================================

print("\n=== embed_images Pure Helper Tests ===\n")

-- ---------------------------------------------------------------------------
-- 1. is_image_embed — positive cases
-- ---------------------------------------------------------------------------
test("is_image_embed true for .png", function()
  assert_true(embed_images.is_image_embed("x.png"))
end)

test("is_image_embed true for .jpg / .jpeg / .gif / .webp / .svg", function()
  assert_true(embed_images.is_image_embed("a.jpg"))
  assert_true(embed_images.is_image_embed("a.jpeg"))
  assert_true(embed_images.is_image_embed("a.gif"))
  assert_true(embed_images.is_image_embed("a.webp"))
  assert_true(embed_images.is_image_embed("a.svg"))
end)

test("is_image_embed extension match is case-insensitive", function()
  assert_true(embed_images.is_image_embed("photo.PNG"))
  assert_true(embed_images.is_image_embed("photo.JpG"))
end)

test("is_image_embed strips pipe alias before extension check", function()
  assert_true(embed_images.is_image_embed("photo.PNG|400"))
end)

-- ---------------------------------------------------------------------------
-- 2. is_image_embed — negative cases
-- ---------------------------------------------------------------------------
test("is_image_embed false for plain note name", function()
  assert_false(embed_images.is_image_embed("Note"))
end)

test("is_image_embed false for note#heading", function()
  assert_false(embed_images.is_image_embed("Note#Heading"))
end)

test("is_image_embed false for block ref ^blk", function()
  assert_false(embed_images.is_image_embed("^blk"))
end)

test("is_image_embed false for self-heading #Heading", function()
  assert_false(embed_images.is_image_embed("#Heading"))
end)

test("is_image_embed false for non-image extension", function()
  assert_false(embed_images.is_image_embed("doc.md"))
  assert_false(embed_images.is_image_embed("data.txt"))
end)

test("is_image_embed false for name with no extension", function()
  assert_false(embed_images.is_image_embed("My Note Without Extension"))
end)

-- ---------------------------------------------------------------------------
-- 3. get_image_name — strips pipe alias
-- ---------------------------------------------------------------------------
test("get_image_name strips pipe alias", function()
  assert_eq(embed_images.get_image_name("photo.png|400"), "photo.png")
end)

test("get_image_name returns name unchanged when no alias", function()
  assert_eq(embed_images.get_image_name("photo.png"), "photo.png")
end)

test("get_image_name keeps only segment before first pipe", function()
  assert_eq(embed_images.get_image_name("a.png|x|y"), "a.png")
end)

-- ---------------------------------------------------------------------------
-- invalidate_image_cache — selective, NUL-separated keys
-- ---------------------------------------------------------------------------
-- Regression: keys are "<image_name>\0<buf_dir>" and were split with the Lua
-- pattern "^([^\0]+)". Under LuaJIT, classend() scans for the closing "]" and
-- halts at the embedded NUL, so that pattern ALWAYS raises "malformed pattern
-- (missing ']')" -- selective invalidation threw from the fs-watcher callback
-- whenever the image cache was non-empty.
local engine = require("andrew.vault.engine")

local function image_cache_entries()
  local stats = engine.cache_stats()
  return stats.image_paths and stats.image_paths.entries or 0
end

test("invalidate_image_cache does not throw when the cache is populated", function()
  -- resolve_image caches negative results too, so no real image is needed.
  embed_images.resolve_image("regress-photo.png", "/tmp/embed-spec/note.md")
  assert_true(image_cache_entries() > 0, "cache populated")

  local ok, err = pcall(embed_images.invalidate_image_cache, "/tmp/other/regress-photo.png")
  assert_true(ok, "selective invalidation must not error: " .. tostring(err))
end)

test("invalidate_image_cache evicts only the matching image name", function()
  embed_images.resolve_image("keep-me.png", "/tmp/embed-spec/note.md")
  embed_images.resolve_image("drop-me.png", "/tmp/embed-spec/note.md")
  local before = image_cache_entries()
  assert_true(before >= 2, "both entries cached")

  embed_images.invalidate_image_cache("/somewhere/else/drop-me.png")
  assert_eq(image_cache_entries(), before - 1, "exactly the matching key is removed")

  -- A name present in no key leaves the cache untouched.
  local held = image_cache_entries()
  embed_images.invalidate_image_cache("/somewhere/else/absent.png")
  assert_eq(image_cache_entries(), held, "non-matching name evicts nothing")
end)

-- ============================================================================
-- Summary
-- ============================================================================
_H.finish({ style = "results", exit = "os" })
