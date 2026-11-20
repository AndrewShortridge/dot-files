-- copy-mode.lua - the Neovim half of kitty's copy mode. Sourced by copy-mode.sh,
-- which kitty launches in an overlay over the window being copied from.
--
-- kitty hands over a snapshot of that window: its scrollback and screen, one
-- screen row at a time, with the escape sequences for the colours it was
-- drawn in. Every row becomes one line of a read-only buffer, its escape
-- sequences removed. A row's colours are worked out from those sequences only
-- when the row is drawn, so opening costs one pass over the snapshot that
-- does no more than cut it into lines. The overlay opens on the rows the
-- window was showing, cursor where the terminal's cursor was, with hybrid
-- line numbers in the gutter. Nothing is ever sent back to the window.
--
-- Images the window showed are shown too. The snapshot has none of them:
-- their pixels are fetched from kitty (kittens/copy_mode_images.py) when
-- their rows are first drawn.
--
-- The user's whole Neovim config is loaded, so motions, search, text objects
-- and plugins are the usual ones. Differences from an ordinary buffer:
--   * `q` or `<Esc>` in Normal mode leaves copy mode.
--   * A yank that reaches the system clipboard leaves copy mode (tmux's
--     copy-selection-and-cancel). `"ay` and friends stay.
--   * A yank across rows kitty soft-wrapped yields the unwrapped text, as it
--     would in tmux. The rows themselves stay split: `$`, `w` and `/` see
--     screen rows, not logical lines.
--   * `[[` and `]]` jump between shell prompts (the OSC 133 marks kitty keeps
--     in the snapshot).
--
-- Inputs, both set up by copy-mode.sh / kitty's `launch`:
--   fd 3              the snapshot, as kitty writes it for
--                     --stdin-add-formatting --stdin-add-line-wrap-markers.
--                     Every row ends in "\r"; a "\n" follows unless the row
--                     soft-wraps into the next. Each row starts with SGR
--                     reset, so its colours depend on nothing before it; a
--                     hyperlink (OSC 8) left open runs on into the next row.
--   $KITTY_PIPE_DATA  "{scrolled_by}:{cursor_x},{cursor_y}:{lines},{columns}",
--                     cursor 1-based, of the window at the time of the snapshot.
--   $KITTY_WINDOW_ID  this overlay, for asking kitty about the images of the
--                     window under it. That goes through `kitten @`: without
--                     remote control there are no images.

local SNAPSHOT_FD = 3

local api = vim.api
local lpeg = vim.lpeg
local P, R, Cg, Cp, Cs, Ct = lpeg.P, lpeg.R, lpeg.Cg, lpeg.Cp, lpeg.Cs, lpeg.Ct

local ESC = P("\27")
local ST = P("\7") + ESC * "\\"
local TEXT = (1 - ESC) ^ 1

--- An escape sequence in a row: CSI (SGR) or OSC (hyperlink, prompt mark).
---@param capture fun(pattern: vim.lpeg.Pattern, name: string): vim.lpeg.Pattern what to keep of its parts
---@return vim.lpeg.Pattern
local function sequence(capture)
  local csi = ESC * "[" * capture(R("0?") ^ 0, "params") * R(" /") ^ 0 * capture(R("@~"), "final")
  local osc = ESC * "]" * capture((1 - ST) ^ 0, "osc") * ST
  return csi + osc
end

-- A row without its escape sequences: the text of its buffer line.
local strip = Cs((TEXT + sequence(function(pattern)
  return pattern
end) / "" + 1) ^ 0)

-- A row's escape sequences as { start, stop, params, final } (CSI) or
-- { start, stop, osc }, where [start, stop) are the bytes of the row it takes.
local sequences = Ct((TEXT + Ct(Cg(Cp(), "start") * sequence(Cg) * Cg(Cp(), "stop")) + 1) ^ 0)

---@class copy_mode.Snapshot
---@field rows string[] the rows, oldest first, escape sequences included
---@field wrapped table<integer, true> rows that soft-wrap into the next
---@field open_link table<integer, string> rows that start inside a hyperlink, and its target

---@return copy_mode.Snapshot
local function read_snapshot()
  local file = assert(io.open("/dev/fd/" .. SNAPSHOT_FD, "rb"), "copy-mode: no snapshot on fd 3; run via copy-mode.sh")
  local data = file:read("*a")
  file:close()

  local rows, wrapped, open_link = {}, {}, {}
  local count, from, link = 0, 1, nil
  while from <= #data do
    local cr = data:find("\r", from, true)
    local row = data:sub(from, (cr or #data + 1) - 1)
    count = count + 1
    rows[count] = row
    open_link[count] = link
    if row:find("\27]8;", 1, true) then
      -- The last OSC 8 of the row: its target, empty when it closes a link.
      local target = row:match(".*\27%]8;[^;]*;([^\27\7]*)")
      link = target ~= "" and target or nil
    end

    if not cr then
      break
    elseif data:byte(cr + 1) == 10 then
      from = cr + 2
    else
      -- kitty ends the last row with the bare "\r" too; nothing follows it.
      wrapped[count] = cr < #data or nil
      from = cr + 1
    end
  end
  return { rows = rows, wrapped = wrapped, open_link = open_link }
end

--- Put the snapshot's text in the current buffer: one line per row.
---@param rows string[]
---@return integer buf
local function show(rows)
  local win = api.nvim_get_current_win()
  local buf = api.nvim_get_current_buf()

  local text = {}
  for index = 1, #rows do
    text[index] = strip:match(rows[index])
  end

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  api.nvim_buf_set_lines(buf, 0, -1, false, text)
  vim.bo[buf].modifiable = false
  api.nvim_buf_set_name(buf, "[Copy mode]")
  -- kitty keeps a tab as a tab; it stood for the cells up to the next multiple of 8.
  vim.bo[buf].tabstop = 8

  -- The gutter is line numbers and nothing else: its columns come out of the row's.
  vim.wo[win].number = true
  vim.wo[win].relativenumber = true
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].wrap = false
  vim.wo[win].list = false
  return buf
end

-- xterm's colours 0-15, for those the colorscheme leaves out of g:terminal_color_N.
local ANSI_COLOURS = {
  0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5,
  0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00, 0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff,
}

--- A colour of the 256-colour palette. 0-15 are Neovim's terminal colours, not
--- kitty's theme; the rest are the values kitty uses unless configured otherwise.
---@param index integer 0-255
---@return integer|string colour as nvim_set_hl() takes it
local function palette(index)
  if index < 16 then
    return vim.g["terminal_color_" .. index] or ANSI_COLOURS[index + 1]
  elseif index < 232 then
    local function level(step)
      return step == 0 and 0 or 55 + 40 * step
    end
    index = index - 16
    return level(math.floor(index / 36)) * 0x10000 + level(math.floor(index / 6) % 6) * 0x100 + level(index % 6)
  end
  return (8 + 10 * (index - 232)) * 0x010101
end

--- The colour of an SGR 38, 48 or 58, in kitty's spelling: ":5:n" or ":2:r:g:b".
---@param spec string the parameter after its code
---@return integer|string|nil
local function extended_colour(spec)
  local index = spec:match("^:5:(%d+)$")
  if index then
    return palette(tonumber(index))
  end
  local red, green, blue = spec:match("^:2:(%d+):(%d+):(%d+)$")
  if red then
    return tonumber(red) * 0x10000 + tonumber(green) * 0x100 + tonumber(blue)
  end
end

-- SGR 4:1 to 4:5, as nvim_set_hl() names them.
local UNDERLINES = { "underline", "underdouble", "undercurl", "underdotted", "underdashed" }

--- Apply an SGR sequence to the attributes in force.
---@param attrs vim.api.keyset.highlight changed in place
---@param params string the sequence's parameters, e.g. "22;1;38:2:255:128:0"
local function apply_sgr(attrs, params)
  for code, sub in (params == "" and "0" or params):gmatch("(%d+)([%d:]*)") do
    code = tonumber(code)
    if code == 0 then
      for field in pairs(attrs) do
        attrs[field] = nil
      end
    elseif code == 1 then
      attrs.bold = true
    elseif code == 2 then
      attrs.dim = true
    elseif code == 22 then
      attrs.bold, attrs.dim = nil, nil
    elseif code == 3 or code == 23 then
      attrs.italic = code == 3 or nil
    elseif code == 4 or code == 24 then
      for _, style in ipairs(UNDERLINES) do
        attrs[style] = nil
      end
      -- A bare 4 is a straight underline; 4:0 is none.
      local style = code == 4 and UNDERLINES[tonumber(sub:sub(2)) or 1]
      if style then
        attrs[style] = true
      end
    elseif code == 7 or code == 27 then
      attrs.reverse = code == 7 or nil
    elseif code == 9 or code == 29 then
      attrs.strikethrough = code == 9 or nil
    elseif code >= 30 and code <= 37 then
      attrs.fg = palette(code - 30)
    elseif code == 38 then
      attrs.fg = extended_colour(sub)
    elseif code == 39 then
      attrs.fg = nil
    elseif code >= 40 and code <= 47 then
      attrs.bg = palette(code - 40)
    elseif code == 48 then
      attrs.bg = extended_colour(sub)
    elseif code == 49 then
      attrs.bg = nil
    elseif code == 58 then
      attrs.sp = extended_colour(sub)
    elseif code == 59 then
      attrs.sp = nil
    elseif code >= 90 and code <= 97 then
      attrs.fg = palette(code - 90 + 8)
    elseif code >= 100 and code <= 107 then
      attrs.bg = palette(code - 100 + 8)
    end
  end
end

local ATTRIBUTES = vim.list_extend({ "fg", "bg", "sp", "bold", "dim", "italic", "reverse", "strikethrough" }, UNDERLINES)

--- Colour the buffer's lines as their rows were, each when it is drawn.
---@param buf integer
---@param snapshot copy_mode.Snapshot
local function colour(buf, snapshot)
  -- Highlight groups live in their own namespace, where `:colorscheme` does
  -- not clear them.
  local namespace = api.nvim_create_namespace("kitty.copy-mode")
  api.nvim_set_hl_ns(namespace)

  local groups = {} ---@type table<string, string> attributes -> highlight group
  local group_count = 0

  ---@param attrs vim.api.keyset.highlight
  ---@return string? group none for text in the default colours
  local function group_for(attrs)
    if next(attrs) == nil then
      return nil
    end
    local key = {}
    for index, attribute in ipairs(ATTRIBUTES) do
      key[index] = tostring(attrs[attribute] or "")
    end
    local id = table.concat(key, ",")
    if not groups[id] then
      group_count = group_count + 1
      groups[id] = "KittyCopyMode" .. group_count
      api.nvim_set_hl(namespace, groups[id], attrs)
    end
    return groups[id]
  end

  ---@alias copy_mode.Span { [1]: integer, [2]: integer, [3]: string?, [4]: string? } byte columns [from, to), highlight group, hyperlink
  local spans = {} ---@type table<integer, copy_mode.Span[]> by row, once drawn

  ---@param row integer
  ---@return copy_mode.Span[]
  local function spans_of(row)
    if spans[row] then
      return spans[row]
    end
    local raw = snapshot.rows[row]
    local found = {} ---@type copy_mode.Span[]
    local attrs = {} ---@type vim.api.keyset.highlight
    local group, link = nil, snapshot.open_link[row]
    local from, removed = 0, 0 -- start of the run of text being read; bytes of escape sequences before it

    local function close(to)
      if (group or link) and to > from then
        found[#found + 1] = { from, to, group, link }
      end
      from = to
    end

    for _, seq in ipairs(sequences:match(raw)) do
      close(seq.start - 1 - removed)
      removed = removed + seq.stop - seq.start
      if seq.osc then
        local target = seq.osc:match("^8;[^;]*;(.*)$")
        if target then
          link = target ~= "" and target or nil
        end
      elseif seq.final == "m" then
        apply_sgr(attrs, seq.params)
        group = group_for(attrs)
      end
    end
    close(#raw - removed)

    spans[row] = found
    return found
  end

  api.nvim_set_decoration_provider(namespace, {
    on_win = function(_, _, drawn)
      return drawn == buf
    end,
    on_line = function(_, _, _, line)
      for _, span in ipairs(spans_of(line + 1)) do
        api.nvim_buf_set_extmark(buf, namespace, line, span[1], {
          end_col = span[2],
          hl_group = span[3],
          url = span[4],
          ephemeral = true,
        })
      end
    end,
  })
end

-- The character a program prints in every cell an image covers when it draws
-- the image with Unicode placeholders (U+10EEEE). Combining characters after
-- it number the cell's row and column in the image and carry the top byte of
-- the image's id; the foreground colour is the rest of the id.
local PLACEHOLDER = "\244\142\187\174"
local UTF8_CHARACTER = "^[%z\1-\127\194-\244][\128-\191]*"

-- Those combining characters as code points, in the order of the numbers
-- they stand for, from 0 (kitty: gen/rowcolumn-diacritics.txt).
local DIACRITICS = [[
0305 030D 030E 0310 0312 033D 033E 033F 0346 034A 034B 034C 0350 0351 0352 0357 035B 0363 0364
0365 0366 0367 0368 0369 036A 036B 036C 036D 036E 036F 0483 0484 0485 0486 0487 0592 0593 0594
0595 0597 0598 0599 059C 059D 059E 059F 05A0 05A1 05A8 05A9 05AB 05AC 05AF 05C4 0610 0611 0612
0613 0614 0615 0616 0617 0657 0658 0659 065A 065B 065D 065E 06D6 06D7 06D8 06D9 06DA 06DB 06DC
06DF 06E0 06E1 06E2 06E4 06E7 06E8 06EB 06EC 0730 0732 0733 0735 0736 073A 073D 073F 0740 0741
0743 0745 0747 0749 074A 07EB 07EC 07ED 07EE 07EF 07F0 07F1 07F3 0816 0817 0818 0819 081B 081C
081D 081E 081F 0820 0821 0822 0823 0825 0826 0827 0829 082A 082B 082C 082D 0951 0953 0954 0F82
0F83 0F86 0F87 135D 135E 135F 17DD 193A 1A17 1A75 1A76 1A77 1A78 1A79 1A7A 1A7B 1A7C 1B6B 1B6D
1B6E 1B6F 1B70 1B71 1B72 1B73 1CD0 1CD1 1CD2 1CDA 1CDB 1CE0 1DC0 1DC1 1DC3 1DC4 1DC5 1DC6 1DC7
1DC8 1DC9 1DCB 1DCC 1DD1 1DD2 1DD3 1DD4 1DD5 1DD6 1DD7 1DD8 1DD9 1DDA 1DDB 1DDC 1DDD 1DDE 1DDF
1DE0 1DE1 1DE2 1DE3 1DE4 1DE5 1DE6 1DFE 20D0 20D1 20D4 20D5 20D6 20D7 20DB 20DC 20E1 20E7 20E9
20F0 2CEF 2CF0 2CF1 2DE0 2DE1 2DE2 2DE3 2DE4 2DE5 2DE6 2DE7 2DE8 2DE9 2DEA 2DEB 2DEC 2DED 2DEE
2DEF 2DF0 2DF1 2DF2 2DF3 2DF4 2DF5 2DF6 2DF7 2DF8 2DF9 2DFA 2DFB 2DFC 2DFD 2DFE 2DFF A66F A67C
A67D A6F0 A6F1 A8E0 A8E1 A8E2 A8E3 A8E4 A8E5 A8E6 A8E7 A8E8 A8E9 A8EA A8EB A8EC A8ED A8EE A8EF
A8F0 A8F1 AAB0 AAB2 AAB3 AAB7 AAB8 AABE AABF AAC1 FE20 FE21 FE22 FE23 FE24 FE25 FE26 10A0F 10A38
1D185 1D186 1D187 1D188 1D189 1D1AA 1D1AB 1D1AC 1D1AD 1D242 1D243 1D244
]]

local KITTEN = vim.fs.normalize(
  vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/../kittens/copy_mode_images.py"
)

--- The low 24 bits of an image id, as an SGR sequence sets them.
---@param params string the sequence's parameters
---@param current integer? the bits before the sequence
---@return integer?
local function id_bits(params, current)
  for code, sub in (params == "" and "0" or params):gmatch("(%d+)([%d:]*)") do
    code = tonumber(code)
    if code == 0 or code == 39 then
      current = nil
    elseif code >= 30 and code <= 37 then
      current = code - 30
    elseif code >= 90 and code <= 97 then
      current = code - 90 + 8
    elseif code == 38 then
      local index = sub:match("^:5:(%d+)$")
      local red, green, blue = sub:match("^:2:(%d+):(%d+):(%d+)$")
      current = index and tonumber(index) or red and tonumber(red) * 0x10000 + tonumber(green) * 0x100 + tonumber(blue)
    end
  end
  return current
end

--- Show the images the kitty window had.
---
--- The snapshot is text. It has nothing of an image a program placed on the
--- screen (the rows under it are blank), and of an image drawn with Unicode
--- placeholders only the placeholder cells. The pixels of both are in the
--- kitty window underneath, where the copy_mode_images kitten reads them.
---
--- An image is sent to this window the first time one of its rows is drawn,
--- and shown by placeholder cells. Those of a placed image are virtual text
--- over its rows, so the buffer is as it would be without images.
---@param buf integer
---@param snapshot copy_mode.Snapshot
local function images(buf, snapshot)
  local window = vim.env.KITTY_WINDOW_ID
  if not window then
    return
  end
  local highlights = api.nvim_create_namespace("kitty.copy-mode")
  local marks = api.nvim_create_namespace("kitty.copy-mode.images")

  local diacritics = {} ---@type string[] by the number they stand for, 0 at index 1
  local diacritic_numbers = {} ---@type table<string, integer>
  for codepoint in DIACRITICS:gmatch("%x+") do
    local character = vim.fn.nr2char(tonumber(codepoint, 16))
    diacritic_numbers[character] = #diacritics
    diacritics[#diacritics + 1] = character
  end

  --- Run the kitten over this window; it answers about the one underneath.
  ---@param arguments any[]
  ---@param on_answer fun(answer: table?) nil when it could not answer
  local function ask(arguments, on_answer)
    local command = { "kitten", "@", "kitten", "--match", "id:" .. window, KITTEN }
    for _, argument in ipairs(arguments) do
      command[#command + 1] = tostring(argument)
    end
    vim.system(
      command,
      { text = true },
      vim.schedule_wrap(function(result)
        local ok, answer = pcall(vim.json.decode, result.stdout or "")
        on_answer(result.code == 0 and ok and type(answer) == "table" and not answer.error and answer or nil)
      end)
    )
  end

  local file_count = 0
  --- A name for a file of pixels. kitty deletes the file once it has read
  --- it, but only one whose name says it is for the graphics protocol.
  local function pixel_file()
    file_count = file_count + 1
    return ("/dev/shm/tty-graphics-protocol-copy-mode-%d-%d.raw"):format(vim.fn.getpid(), file_count)
  end

  --- Send an image to this window, to be shown by placeholder cells.
  ---@param id integer the id the cells will carry
  ---@param pixels { path: string, width: integer, height: integer, depth: integer } as the kitten wrote them
  ---@param columns integer cells the image spans
  ---@param rows integer
  local function transmit(id, pixels, columns, rows)
    local keys = ("a=T,U=1,q=2,i=%d,f=%d,s=%d,v=%d,c=%d,r=%d,t=t"):format(
      id,
      pixels.depth * 8,
      pixels.width,
      pixels.height,
      columns,
      rows
    )
    api.nvim_ui_send(("\27_G%s;%s\27\\"):format(keys, vim.base64.encode(pixels.path)))
  end

  ---@class copy_mode.Placement an image a program placed on the screen, as the kitten lists it
  ---@field image integer kitty's id for the image
  ---@field rows_before_end integer rows from its first row to the last row of the screen
  ---@field column integer first cell, 1-based
  ---@field rows integer
  ---@field columns integer
  ---@field src number[] the part of the image it shows
  ---@field px number[] its size on screen
  ---@field id integer the id it has in this window
  ---@field group string highlight group whose foreground is that id
  ---@field state "loading"|"ready"|"failed"|nil

  local placed = {} ---@type table<integer, { placement: copy_mode.Placement, image_row: integer }[]> by buffer row

  ---@param placement copy_mode.Placement
  local function load_placement(placement)
    local arguments = { "plain", placement.image, placement.px[1], placement.px[2] }
    vim.list_extend(arguments, placement.src)
    arguments[#arguments + 1] = pixel_file()
    ask(arguments, function(pixels)
      if not pixels then
        placement.state = "failed"
        return
      end
      transmit(placement.id, pixels, placement.columns, placement.rows)
      placement.state = "ready"
      api.nvim__redraw({ buf = buf, valid = false })
    end)
  end

  ---@class copy_mode.PlaceholderImage an image the snapshot has placeholder cells of
  ---@field source integer its id in the window underneath
  ---@field id integer the id its cells carry when Neovim draws them
  ---@field rows integer cells the image spans, going by the cells in the snapshot
  ---@field columns integer
  ---@field state "loading"|"ready"|"failed"|nil

  local placeholder_images ---@type table<integer, copy_mode.PlaceholderImage>? by source id, once scanned
  local placeholder_rows = {} ---@type table<integer, integer[]> source ids, by buffer row

  --- Find every placeholder image in the snapshot.
  local function scan_placeholders()
    placeholder_images = {}
    for row, raw in ipairs(snapshot.rows) do
      if raw:find(PLACEHOLDER, 1, true) then
        local attrs, bits = {}, nil
        local from = 1
        local function read(to)
          local text = raw:sub(from, to - 1)
          local found = bits and text:find(PLACEHOLDER, 1, true)
          while found do
            local at, numbers = found + #PLACEHOLDER, {}
            for index = 1, 3 do
              local character = text:match(UTF8_CHARACTER, at)
              numbers[index] = character and diacritic_numbers[character]
              if not numbers[index] then
                break
              end
              at = at + #character
            end
            if numbers[1] and numbers[2] then
              -- Neovim draws the cell in the colour its highlight group has,
              -- which for a palette colour is not the number kitty was given.
              local shown = type(attrs.fg) == "string" and tonumber(attrs.fg:sub(2), 16) or attrs.fg
              local top = (numbers[3] or 0) * 0x1000000
              local source = top + bits
              local image = placeholder_images[source] or { source = source, id = top + shown, rows = 0, columns = 0 }
              image.rows = math.max(image.rows, numbers[1] + 1)
              image.columns = math.max(image.columns, numbers[2] + 1)
              placeholder_images[source] = image
              placeholder_rows[row] = placeholder_rows[row] or {}
              if not vim.tbl_contains(placeholder_rows[row], source) then
                table.insert(placeholder_rows[row], source)
              end
            end
            found = text:find(PLACEHOLDER, at, true)
          end
        end
        for _, seq in ipairs(sequences:match(raw)) do
          read(seq.start)
          from = seq.stop
          if seq.final == "m" then
            apply_sgr(attrs, seq.params)
            bits = id_bits(seq.params, bits)
          end
        end
        read(#raw + 1)
      end
    end
  end

  ---@param row integer a row with placeholder cells
  local function load_placeholders(row)
    if not placeholder_images then
      scan_placeholders()
    end
    for _, source in ipairs(placeholder_rows[row] or {}) do
      local image = placeholder_images[source]
      if not image.state then
        image.state = "loading"
        ask({ "placeholder", source, pixel_file() }, function(pixels)
          if not pixels then
            image.state = "failed"
            return
          end
          transmit(image.id, pixels, image.columns, image.rows)
          image.state = "ready"
          -- The cells are on screen already, and kitty looks for their image
          -- only when their line is drawn again: have Neovim send it all anew.
          vim.cmd("mode")
        end)
      end
    end
  end

  ask({ "list" }, function(listing)
    if not listing then
      return
    end
    -- Rows the window has gained since the snapshot was taken.
    local drift = math.max(listing.history + listing.lines - #snapshot.rows, 0)
    local count = 0
    for _, placement in ipairs(listing.placements) do
      local first = #snapshot.rows - (placement.rows_before_end - drift) + 1
      local last = math.min(first + placement.rows - 1, #snapshot.rows)
      local probe = snapshot.rows[math.max(first, 1)]
      -- kitty also lists the placeholder cells it has drawn; those are text here.
      if last >= 1 and probe and not probe:find(PLACEHOLDER, 1, true) and placement.rows <= #diacritics then
        count = count + 1
        placement.id = count
        placement.group = "KittyCopyModeImage" .. count
        api.nvim_set_hl(highlights, placement.group, { fg = placement.id })
        for row = math.max(first, 1), last do
          placed[row] = placed[row] or {}
          table.insert(placed[row], { placement = placement, image_row = row - first })
        end
      end
    end
    api.nvim__redraw({ buf = buf, valid = false })
  end)

  local leftcol = 0
  local seen = {} ---@type table<integer, true> rows whose placeholder images were asked for
  api.nvim_set_decoration_provider(marks, {
    on_win = function(_, win, drawn)
      if drawn ~= buf then
        return false
      end
      leftcol = vim.fn.getwininfo(win)[1].leftcol
    end,
    on_line = function(_, _, _, line)
      local row = line + 1
      for _, cell in ipairs(placed[row] or {}) do
        local placement = cell.placement
        -- Cells scrolled off the left edge are left out; the rest keep their numbers.
        local hidden = math.max(leftcol - (placement.column - 1), 0)
        if placement.state == "ready" and hidden < placement.columns then
          local cells = {}
          for column = hidden, math.min(placement.columns, #diacritics) - 1 do
            cells[#cells + 1] = PLACEHOLDER .. diacritics[cell.image_row + 1] .. diacritics[column + 1]
          end
          api.nvim_buf_set_extmark(buf, marks, line, 0, {
            virt_text = { { table.concat(cells), placement.group } },
            virt_text_pos = "overlay",
            virt_text_win_col = placement.column - 1 + hidden - leftcol,
            hl_mode = "combine",
            ephemeral = true,
          })
        elseif not placement.state then
          placement.state = "loading"
          vim.schedule(function()
            load_placement(placement)
          end)
        end
      end
      if not seen[row] and snapshot.rows[row]:find(PLACEHOLDER, 1, true) then
        seen[row] = true
        vim.schedule(function()
          load_placeholders(row)
        end)
      end
    end,
  })
end

--- Show the rows the kitty window was showing, cursor on the terminal's cursor.
---@param row_count integer
local function restore_view(row_count)
  -- The tabline and the statusline (for the mode) stay, as in any Neovim.
  vim.o.cmdheight = 0

  local scrolled_by, cursor_x, cursor_y, lines = (vim.env.KITTY_PIPE_DATA or ""):match("^(%d+):(%d+),(%d+):(%d+),%d+$")
  if not scrolled_by then
    vim.cmd("normal! G")
    return
  end
  scrolled_by, cursor_x, cursor_y, lines = tonumber(scrolled_by), tonumber(cursor_x), tonumber(cursor_y), tonumber(lines)

  -- The screen is the last `lines` rows of the snapshot; kitty was scrolled
  -- `scrolled_by` rows up from there.
  local screen_top = math.max(row_count - lines + 1, 1)
  local kitty_top = math.max(screen_top - scrolled_by, 1)

  -- The bars cover screen rows rather than push them: the view starts as far
  -- down as the window does (below the tabline), so every row that still
  -- shows is on the screen line kitty had it on.
  local top = kitty_top + vim.fn.win_screenpos(0)[1] - 1
  local height = api.nvim_win_get_height(0)
  local cursor_row = screen_top + cursor_y - 1
  if cursor_row > kitty_top + lines - 1 then
    -- Scrolled back far enough that the cursor is off kitty's screen.
    cursor_row, cursor_x = math.min(top + height - 1, row_count), 1
  elseif cursor_row > top + height - 1 then
    -- On a row the statusline covers: move the view down to it.
    top = cursor_row - height + 1
  elseif cursor_row < top then
    -- On a row the tabline covers: move the view up to it.
    top = cursor_row
  end

  -- 'scrolloff' would scroll the view to keep context around the cursor.
  vim.wo.scrolloff = 0
  vim.wo.sidescrolloff = 0
  api.nvim_win_set_cursor(0, { cursor_row, 0 })
  vim.cmd("normal! " .. cursor_x .. "|")
  vim.fn.winrestview({ topline = top, leftcol = 0 })
end

--- Buffer-local behaviour of copy mode.
---@param buf integer
---@param snapshot copy_mode.Snapshot
local function attach(buf, snapshot)
  local function leave()
    vim.cmd("qall!")
  end

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, leave, { buffer = buf, nowait = true, desc = "Leave copy mode" })
  end

  local prompts ---@type integer[]? rows a shell prompt starts on, once asked for

  --- Move to the [count]th prompt above or below the cursor, or as far that
  --- way as there are prompts.
  ---@param step -1|1
  local function jump_to_prompt(step)
    if not prompts then
      prompts = {}
      for row, raw in ipairs(snapshot.rows) do
        if raw:find("\27]133;A", 1, true) then
          prompts[#prompts + 1] = row
        end
      end
    end

    local here = api.nvim_win_get_cursor(0)[1]
    local left, target = vim.v.count1, nil
    for index = step > 0 and 1 or #prompts, step > 0 and #prompts or 1, step do
      if left > 0 and (prompts[index] - here) * step > 0 then
        target = prompts[index]
        left = left - 1
      end
    end
    if target then
      api.nvim_win_set_cursor(0, { target, 0 })
    end
  end

  vim.keymap.set({ "n", "x", "o" }, "[[", function()
    jump_to_prompt(-1)
  end, { buffer = buf, desc = "Jump [count] shell prompts backward" })
  vim.keymap.set({ "n", "x", "o" }, "]]", function()
    jump_to_prompt(1)
  end, { buffer = buf, desc = "Jump [count] shell prompts forward" })

  -- The view was restored with 'scrolloff' off. Hand it back to the user's
  -- setting as soon as they move.
  local start = api.nvim_win_get_cursor(0)
  local scrolloff_autocmd
  scrolloff_autocmd = api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      local cursor = api.nvim_win_get_cursor(0)
      if cursor[1] == start[1] and cursor[2] == start[2] then
        return
      end
      vim.wo.scrolloff = -1
      vim.wo.sidescrolloff = -1
      api.nvim_del_autocmd(scrolloff_autocmd)
    end,
  })

  api.nvim_create_autocmd("TextYankPost", {
    buffer = buf,
    callback = function()
      local event = vim.v.event
      if event.operator ~= "y" then
        return
      end

      -- Where a yank without a register name goes ('clipboard').
      local register = event.regname
      if register == "" then
        local clipboard = vim.opt.clipboard:get()
        register = vim.tbl_contains(clipboard, "unnamedplus") and "+"
          or vim.tbl_contains(clipboard, "unnamed") and "*"
          or '"'
      end

      -- Undo kitty's soft wraps. Every yanked row but the last runs to the
      -- end of its buffer line; where that row wraps into the next, drop the
      -- line break.
      if event.regtype == "v" or event.regtype == "V" then
        local first_row = vim.fn.line("'[")
        local unwrapped, pending = {}, nil
        for index, text in ipairs(event.regcontents) do
          text = (pending or "") .. text
          if snapshot.wrapped[first_row + index - 1] and index < #event.regcontents then
            pending = text
          else
            unwrapped[#unwrapped + 1] = text
            pending = nil
          end
        end
        if #unwrapped < #event.regcontents then
          vim.fn.setreg(register, unwrapped, event.regtype)
        end
      end

      if register == "+" or register == "*" then
        vim.schedule(leave)
      end
    end,
  })
end

local snapshot = read_snapshot()
local buf = show(snapshot.rows)
colour(buf, snapshot)
restore_view(#snapshot.rows)
attach(buf, snapshot)
images(buf, snapshot)
