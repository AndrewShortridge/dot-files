# pdfproto — read a PDF as a page, select text on it, highlight it

Two views over the same page, sharing one word map and one sidecar:

- **image view** (`pdfview.lua`) — the page rendered by poppler, exactly as it
  is: figures, equations, rules, layout. A cell grid sits invisibly behind it,
  so the cursor walks the page **word by word**. Confirmed highlights are
  composited into the page image, so you see the marker on the real page.
- **text view** (`pdfproto.lua`) — the extracted text as an ordinary buffer,
  where every native vim motion works because it *is* an ordinary buffer.

`<Tab>` switches between them **and lands on the same word**, because both are
driven by the same reading-order index from `pdftotext -bbox-layout`.

Highlights are stored as *geometry* (page-point rects), never buffer offsets,
so they survive re-extraction, rescaling and zoom.

## Try it

```sh
cd ~/.config/nvim
nvim -u tmp/prototype/init.lua ~/Desktop/Shock-Profile-Induced-By-Short-Laser-Pulses.pdf 2
```

The trailing number is the page (default 1); `PDF_PAGE=2` works too. Opens in
the image view. Or explicitly:

```
:PdfProtoView /path/to/file.pdf 3     " image
:PdfProtoOpen /path/to/file.pdf 3     " text
```

## Image view keys

| Key | |
|---|---|
| `w` `b` / `l` `h` / arrows | next / previous word |
| `j` `k` | nearest word on the next / previous text line |
| `0` `$` | first / last word of the line |
| `gg` `G` | first / last word of the page |
| `v` | start (or drop) a selection at the current word |
| `1` `2` `3` `4` | confirm: yellow / blue / red / purple |
| `<CR>` | confirm yellow |
| `<Esc>` | cancel the selection |
| `x` | delete the highlight under the cursor |
| `]p` `[p` / `PgDn` `PgUp` | next / previous page |
| `gp` | go to page (`4gp`, or prompts) |
| `+` `-` `0z` | zoom in / out / reset |
| `r` | refit to the window and re-render |
| `?` | debug: why the page is not rendering |
| `<Tab>` | switch to the text view, same word |
| `q` | close |

The footer is always on and is where selection feedback lives:

```
  p2/6   word 12/839   "Futuroscope"     2 highlight(s)  [v]select []p[p]page …
  SELECT 3 word(s): "Shock profile induced"   [1]yel [2]blu [3]red [4]pur  [Esc]cancel
```

It has to, and this is worth knowing: snacks draws the image with unicode
placeholder extmarks, which cover the buffer text underneath, so nvim's own
Visual highlight **cannot be seen** over the page. Selection feedback is
therefore textual while you select, and pixel-accurate once you confirm.

## Text view keys

`<leader>hy` `hb` `hr` `hp` in visual mode to highlight, `<leader>hd` to
delete, `<leader>hl` to list, `]h` `[h` to jump, `]p` `[p` to change page,
`<leader>h?` to dump the word
under the cursor with its PDF point and pixel coordinates, `<Tab>` to go back
to the page.

## The resolution limit, and zoom

The word grid is derived from the cell box snacks actually draws the image
into (`placement:state().loc`), not from a pixel calculation of my own, so the
words line up with the picture even when snacks rescales it.

A terminal cell (~8×17px) is often taller than a line of PDF text, so at
fit-to-window scale several text lines can land on one cell row. Each word is
anchored to the single cell row containing its vertical centre, and the open
message reports the cost honestly:

```
pdfview: paper.pdf p1 -- 827x1170px @100dpi (zoom 1.0x), 109 words on a
         104x69 cell grid; 2 crowded row(s)
```

`2 crowded rows` = 2 cell rows carrying more than one PDF text line. Press `+`
to zoom; the grid gets finer and crowding drops (asserted in the tests). All
motions are word-graph based rather than cell based, so even crowded rows
navigate correctly — `j`/`k` follow real text lines, not screen rows.

## Highlight burn-in with no imagemagick

`magick` is not installed here, so `image_ops.lua` does it in pure Lua:
`pdftoppm` emits an uncompressed **PPM**, the highlight rects are
multiply-blended into it (white paper takes the colour, glyphs stay dark and
readable), and the result is written as a **PNG using zlib *stored* blocks** —
valid PNG, no compression library, only crc32 and adler32.

Verified by decoding the output with Python's `zlib`: every chunk CRC
validates, the stream decompresses, and the tinted band lands exactly on the
title line —

```
changed region bbox: x 168..501  y 123..141   (requested 167..502 x 121..142)
white paper inside band -> (255, 232, 66)
dark glyph pixels in band: 983, e.g. (29,27,27) -> (29,24,6)
```

Cost: ~275ms for two full-page renders at 100dpi, ~8ms of that being the PNG
encode. If you install imagemagick it would be faster, but nothing here needs it.

## Where things land

Everything goes to `tmp/prototype/data/`; the source PDF is never touched.

- `<name>.hl.json` — sidecar, Logseq's EDN schema in JSON, saved on every
  add/delete, shared by both views. Highlights on other pages are preserved.
- `hls__<name>.md` — via `:PdfProtoExport`, the Logseq page shape
  (`ls-type:: annotation`, `hl-page::`, `hl-color::`, `id::`).
- `<name>-p<N>-r<dpi>.ppm` — cached base render.
- `<name>-p<N>-r<dpi>-g<n>.png` — composited page, one per repaint.

## If the page does not look like a page

Press `?` in the view, or run `:PdfViewDebug`. It reports terminal detection,
whether snacks thinks placeholders are available, the cell size, the drawn
grid, and the placement state:

```
  TERM                   xterm-256color
  env.name               kitty
  env.placeholders       true
  supports_terminal()    true
  cell px                8x17
  png                    …/paper-p1-r100-g2.png
  window cells           212x54
  grid cells             96x54
  drawn loc              row 1 col 0  96x54 cells
  snacks extmarks        54
```

Three things make the page fail to draw, and all three were bugs in the first
cut of this prototype:

1. **Placing before kitty detection finishes.** Snacks learns it is in kitty
   from an async DA3 reply; place an image before it lands and
   `env().placeholders` is unset, so nothing appears. Every entry point now
   goes through `Snacks.image.terminal.detect()` first.
2. **`conceal = false`.** With conceal off, snacks skips its overlay branch
   entirely and emits the whole page as *virtual lines below line 1* — the
   page floats under an empty row and the cursor can never reach it.
3. **A single-line `range`.** Snacks only overlays as many rows as the range
   covers, so `range` must span the full grid, not just line 1.

If `env.placeholders` is false you are not in kitty/ghostty (or detection
failed) and no in-terminal renderer will work; `supports_terminal()` false
means the same. The composited PNG path is printed either way, so you can open
it externally to confirm the rest of the pipeline is fine.

## Headless checks

No plugins, no UI, no network. All green.

```sh
nvim --headless -u NONE -l tmp/prototype/check.lua           # 13  parse + geometry round-trip
nvim --headless -u NONE -l tmp/prototype/smoke.lua           # 25  text view end to end
nvim --headless -u NONE -l tmp/prototype/png_check.lua       #  9  ppm -> blend -> png
nvim --headless -u NONE -l tmp/prototype/view_check.lua      # 23  image view, cell grid, zoom, commit
nvim --headless -u NONE -l tmp/prototype/placement_check.lua # 32  placement contract + page nav
```

The first four take an optional `<pdf> <page>`; all pass against page 1 and
page 2 of the sample paper.

`view_check.lua` includes the assertion that matters most for `<Tab>`: word
ordinal *N* is the same word in both views. `placement_check.lua` stubs snacks
and pins the three render bugs above — each was re-introduced individually and
confirmed to fail the relevant assertion.

## Known limitations

- **One page on screen at a time.** `]p`/`[p`/`gp` move between pages and each
  page re-renders from scratch; there is no continuous scroll across a page
  boundary.
- **No live tint while selecting** — see the footer note above. Confirming is
  what shows you colour on the page.
- **Zoomed-in pages scroll but do not pan smoothly**; the cursor drags the
  viewport as you move between words.
- **No real PDF annotations written.** Sidecar only. Poppler *does* render
  embedded annotations (`pdftoppm -hide-annotations` exists to suppress them),
  so exporting to genuine PDF annots would make Zathura and Okular show these
  highlights — it needs `pymupdf`/`pypdf`, neither of which is installed.
- **Two-column papers read in poppler's block order**, so `w`/`b` walk one
  column at a time rather than visually left to right across the page.
- `<leader>` is space in this harness only.

## Files

| | |
|---|---|
| `pdfproto.lua` | extraction, word map, text view, storage |
| `pdfview.lua` | image view, cell grid, zoom, burn-in |
| `image_ops.lua` | PPM reader, highlighter blend, pure-Lua PNG writer |
| `init.lua` | standalone harness |
| `check.lua` `smoke.lua` `png_check.lua` `view_check.lua` `placement_check.lua` | headless tests |
