-- Spec for andrew.jsonl.json_formatter: the JSON text of one record as
-- indented lines, for the record preview.
--
-- WHAT THIS IS GUARDING
--
-- 1. A flat object is laid out one member per line: the opening brace on a
--    line of its own, each member indented two spaces and written as the key,
--    a colon, one space and the value, and the closing brace on a line of its
--    own with no indentation.
-- 2. Every member line ends in a comma except the last, so an object with one
--    member has no comma at all.
-- 3. The lines come back as a list of strings, in order, ready to be buffer
--    lines.
-- 4. Every level of nesting adds two spaces of indentation, and an array puts
--    each item on its own line, one level deeper than the line holding its
--    opening bracket, as an object does each member.
-- 5. An object or array that is a member's value opens on the member's line,
--    after the colon and space.
-- 6. A closing brace or bracket is on a line of its own, at the indentation
--    of the line that opened it, and ends in a comma when a sibling follows
--    it; the last one has none.
-- 7. An empty object or array is written `{}` or `[]` on the line where it
--    occurs (the whole record, a member's value or an item of an array),
--    whatever whitespace the input has between its brackets.
-- 8. An empty object or array adds no level of indentation: the lines after
--    it are as deep as they would be without it.
-- 9. A record may be any JSON value. An array that is the whole record is
--    laid out like any other array, its brackets at no indentation; a string,
--    a number, true, false or null that is the whole record is one line
--    holding exactly that value.
-- 10. The input's whitespace does not shape the lines: spaces, tabs, line
--     feeds and carriage-return line feeds between the tokens of a record,
--     or before and after the whole record, whatever value it holds, give
--     the same lines as the record written with none. So the formatter's own
--     lines, joined with line breaks, format to the same lines again.
-- 11. Whitespace inside a string is part of the string and is kept exactly,
--     leading, trailing and repeated spaces alike; no line ends in
--     whitespace.
-- 12. A blank record (empty text, or only spaces, tabs, line feeds and
--     carriage returns) formats to no lines: an empty list, not a list
--     holding one empty line, and formatting it does not raise.
-- 13. Braces, brackets, commas and colons inside a string are part of the
--     string, whether it is a member's value, an item of an array or a
--     key: it stays one string on one line and adds no line break, no
--     indentation and no space, and the lines after it are as deep as
--     after plain text.
-- 14. A string ends at the first quote that is not part of an escape: the
--     byte after a backslash belongs to the escape, so an escaped quote
--     does not end it and an escaped backslash before a quote does not stop
--     that quote from ending it. This holds for a member's value and a key
--     alike, and the lines after such a string are as deep as after plain
--     text.
-- 15. Members keep the order the record has them, at every level of
--     nesting, and every number, true, false and null is copied exactly as
--     written: an exponent and its case, trailing zeros, every digit of a
--     long integer and the sign of -0 are kept, and a string that looks
--     like a number, true, false or null keeps its quotes.
-- 16. What is between a string's quotes is copied byte for byte, whether
--     it is the whole record, a member's value, an item of an array or a
--     key: an escape (`\n`, `\t`, `\/`, `\b`, `\f`, `\r`, a `\u` escape and
--     the two `\u` escapes of a surrogate pair) stays the escape the record
--     wrote, multi-byte characters written directly keep their bytes, and
--     the empty string stays `""`. Nothing is unescaped, re-escaped or
--     normalised, so a string has as many bytes in the lines as in the
--     record.
-- 17. Text that is not valid JSON (closing brackets with nothing open, a
--     record cut off after a colon or inside a string, plain words, a lone
--     backslash at the end of a string, a comma or colon alone, a raw line
--     break inside a string or between words) returns a list of strings
--     without raising and without looping, and none of those strings holds
--     a line feed or a carriage return, so they can be buffer lines.
-- 18. For a varied set of valid records (deep nesting, a long array, empty
--     objects and arrays at several depths, strings full of structural
--     characters and escapes, multi-byte text, every kind of number, true,
--     false and null, records that are not objects, and one record written
--     both compactly and with irregular whitespace), the lines the
--     formatter returns with no limits, joined with line feeds, are JSON the
--     built-in decoder accepts and decode to the same value as the record.
-- 19. The formatter is one file that needs only the Lua standard library, as
--     the record preview's worker thread requires. Loaded by path in a
--     worker thread, where `require` can load no module of this config, it
--     formats a nested record to the same lines as on the main thread and
--     hands them back as plain data, a list of strings. Loaded by path where
--     the editor's global `vim` is absent, or where `require` can load no
--     module at all, it formats a record to the expected lines. A worker
--     thread that raises or never finishes is reported as a failure of the
--     case, within a time limit, never as a hang.
-- 20. The formatter never turns the text into a value: loading it by path
--     and formatting a small record, or a record of more than a megabyte
--     built here, makes no call to the built-in JSON decoder or encoder
--     (`vim.json.decode`, `vim.json.encode`). Counting replacements with the
--     real signatures stand in for the two only while the formatter loads
--     and runs, and the real ones are put back even when it raises. Only
--     calls are counted; no time is measured.
-- 21. Limits are one value holding two numbers, items per array and
--     characters per string, always given together: the module's type for
--     it, `JsonTrimLimits`, has both fields required. No case reads that
--     type; it is judged by reading the module and by lua_ls. With limits,
--     an array with more items than the items limit shows its first items,
--     in order, each laid out as it is without limits (an item that is an
--     object or array still spans its usual lines), the last of them
--     keeping its comma; then a marker line of its own, indented as the
--     items are and holding only `… N more items`; then the closing
--     bracket where it always is, with its comma when a sibling follows.
--     An array with fewer items than the limit (two, one or none), whether
--     it is the whole record, a member's value or an item of another
--     array, comes out as it does without limits. The cases use small
--     limits, 3 items and 10 characters, so the expected lines stay
--     readable.
-- 22. With the same small limits, a string with more characters than the
--     characters limit, whether it is the whole record or the last
--     member's value, shows its first characters between quotes, the
--     closing one written although the record's closing quote is not
--     reached; then, on the same line, exactly two spaces and the marker
--     `… N more characters`, N being the characters left out, so the
--     characters shown and N add up to the string's characters as the
--     record writes them. A cut string stays on one line. A string with
--     fewer characters than the limit (nine, one or none), whether it is
--     the whole record, a member's value, an item of an array or a key,
--     comes out as it does without limits.
-- 23. With the same small limits, a cut string followed by a sibling, as a
--     member's value or as an item of an array, keeps its comma where it
--     always is, directly after the closing quote with nothing between
--     them; then exactly two spaces and the marker, which is the last thing
--     on the line.
-- 24. With the same small limits, a cut string that is the last item a
--     cut array shows keeps its own marker at the end of its line, after
--     its comma, and the array's marker line follows on the next line:
--     two markers on two consecutive lines, one on each, neither replacing
--     the other. A cut string shown before other items of a cut array is
--     cut the same way, and the items after it are laid out as usual. A
--     long string among the items an array leaves out is not shown, so it
--     has no marker.
-- 25. With the same small limits, a key with more characters than the
--     characters limit is cut as a string is: its first characters
--     between quotes, then the colon, the space and the value as after
--     any key, and the key's marker at the end of the key's line, after
--     the line's comma if it has one. When the value is an object or
--     array, the key's line is the line that opens it, and the marker
--     follows the opening bracket; an empty one is shown whole on the
--     key's line, so the marker ends that line, after its comma if it
--     has one. Every cut string has its own marker:
--     on every line the markers are as many as the strings cut on it, so
--     a line whose key and string value are both cut carries two, the
--     key's first, each after two spaces, and the record reports two
--     trimmed places.
-- 26. With the same small limits, an array is cut only when it has more
--     items than the items limit. One with exactly as many, whether it is
--     the whole record, a member's value or an item of another array, is
--     shown whole, with no marker, as it is without limits; one item more
--     is enough to cut it after the limit's items, with a marker line for
--     the one left out. No marker states that zero items were left out.
-- 27. With the same small limits, a string is cut only when it has more
--     characters than the characters limit. One with exactly as many,
--     whether it is the whole record, a member's value, an item of an
--     array or a key, is shown whole, with no marker, as it is without
--     limits; one character more is enough to cut it after the limit's
--     characters, closed with a quote, with a marker for the one left
--     out. No marker states that zero characters were left out.
-- 28. With the same small limits, an array nested inside a shown item,
--     directly or under any number of objects and arrays, three levels of
--     nesting included, is cut by the same rule: it shows its own first
--     items and gets its own marker line, indented as its own items are.
--     Each array is counted by itself: the items of an inner array, shown
--     or left out, do not use up the outer array's items, and after an
--     inner array closes the outer one goes on counting where it was, so
--     a long inner array does not shorten it. The two records the issue
--     names are compared with their exact lines, `… 1 more item` included.
-- 29. With the same small limits, an object is never cut, however many
--     members it has: whether it is the whole record, a member's value or
--     an item of an array, shown in a cut array or not, it shows every
--     member, as it does without limits, and no object gets a marker line.
--     An object's members are not items of the array holding it: an array
--     of three items whose first is an object of four members is not cut.
-- 30. With the same small limits, the marker of a cut array counts each
--     item it leaves out once, whatever the item holds: a number, a
--     string, or an object or array with any nesting inside it, an empty
--     one included. Brackets, braces and commas inside a hidden string are
--     part of the string; an escaped quote does not end it, and an escaped
--     backslash before its closing quote does not keep it open, so the
--     items after it are still counted. Whitespace between hidden items
--     changes nothing. The items shown plus the count in the marker equal
--     the array's items as the built-in decoder counts them. After the
--     marker line come the cut array's own closing bracket, with its comma
--     when a sibling follows, and the siblings, laid out as usual.
--
-- The formatter is given JSON text and its lines are checked as text; no
-- config is loaded. Only points 18 and 30 decode a record, with
-- `vim.json.decode`: point 18 to catch what no expected lines thought of,
-- point 30 to count a cut array's items; decoding cannot see key order
-- or how a number is written, which point 15 checks on the text, nor how a
-- string is written, which point 16 checks. For text that is not valid JSON
-- the lines are not compared with any expected lines: only the checks of
-- point 17 are made. With limits, the lines are compared with expected
-- lines or with the lines the same text gives without limits; one case
-- also checks the count of trimmed places.
--
-- Run with: nvim --headless -u NONE -l tests/jsonl_json_formatter_spec.lua

---@type SpecHelper
local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_deep_eq, assert_nil, assert_match = _H.test, _H.assert_eq, _H.assert_deep_eq, _H.assert_nil, _H.assert_match

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local json_formatter = require("andrew.jsonl.json_formatter")

--- Asserts that `text` formats to exactly the lines `expected`; a failure
--- names the text it was given.
---@param text string the JSON text of one record
---@param expected string[] the lines the formatter must return
local function assert_formats(text, expected)
  assert_deep_eq(json_formatter.format(text), expected, vim.inspect(text) .. ":")
end

--- Asserts that `lines` is a list holding only strings, as buffer lines and
--- a worker thread's result must be; a failure starts with `label`.
---@param lines any what the formatter returned
---@param label string names that result in a failure, e.g. "the result"
local function assert_list_of_strings(lines, label)
  assert_eq(vim.islist(lines), true, label .. " is a list: " .. vim.inspect(lines))
  ---@cast lines unknown[]
  for position, line in ipairs(lines) do
    assert_eq(type(line), "string", ("%s, line %d:"):format(label, position))
  end
end

test("a flat object is formatted one member per line", function()
  assert_formats('{"a":1,"b":"x","c":true}', {
    "{",
    '  "a": 1,',
    '  "b": "x",',
    '  "c": true',
    "}",
  })
end)

test("an object with one member has no comma on its member line", function()
  assert_formats('{"a":1}', { "{", '  "a": 1', "}" })
end)

test("the lines come back as a list of strings, in order", function()
  local lines = json_formatter.format('{"a":1,"b":"x","c":true}')
  assert_list_of_strings(lines, "the result")
  assert_eq(#lines, 5, "line count:")
  assert_eq(lines[1], "{", "first line:")
  assert_eq(lines[#lines], "}", "last line:")
end)

test("nested objects and arrays are indented two spaces per level", function()
  assert_formats('{"a":{"b":[1,{"c":null}]},"d":[]}', {
    "{",
    '  "a": {',
    '    "b": [',
    "      1,",
    "      {",
    '        "c": null',
    "      }",
    "    ]",
    "  },",
    '  "d": []',
    "}",
  })
end)

test("an object that is a member's value opens on the member's line and closes at its indentation", function()
  assert_formats('{"a":{"b":1},"c":2}', {
    "{",
    '  "a": {',
    '    "b": 1',
    "  },",
    '  "c": 2',
    "}",
  })
end)

test("an array that is a member's value puts each item on its own line, one level deeper", function()
  assert_formats('{"a":[1,2],"b":3}', {
    "{",
    '  "a": [',
    "    1,",
    "    2",
    "  ],",
    '  "b": 3',
    "}",
  })
end)

test("objects that are items of an array each open and close on lines of their own", function()
  assert_formats('{"a":[{"b":1},{"c":2}]}', {
    "{",
    '  "a": [',
    "    {",
    '      "b": 1',
    "    },",
    "    {",
    '      "c": 2',
    "    }",
    "  ]",
    "}",
  })
end)

test("a closing brace or bracket followed by a sibling ends in a comma and the last one does not", function()
  assert_formats('{"a":{"b":1},"c":[2],"d":{"e":[3]}}', {
    "{",
    '  "a": {',
    '    "b": 1',
    "  },",
    '  "c": [',
    "    2",
    "  ],",
    '  "d": {',
    '    "e": [',
    "      3",
    "    ]",
    "  }",
    "}",
  })
end)

test("an empty object or array is the whole record on one line", function()
  assert_formats("{}", { "{}" })
  assert_formats("[]", { "[]" })
end)

test("whitespace between the brackets of an empty object or array is not kept", function()
  assert_formats("{ }", { "{}" })
  assert_formats("[  ]", { "[]" })
end)

test("an empty object or array that is a member's value stays on the member's line", function()
  assert_formats('{"a":{},"b":[]}', {
    "{",
    '  "a": {},',
    '  "b": []',
    "}",
  })
end)

test("an empty array or object that is an item of an array stays on the item's line", function()
  assert_formats("[[],{}]", {
    "[",
    "  [],",
    "  {}",
    "]",
  })
end)

test("the lines after an empty object or array keep their indentation", function()
  assert_formats('{"a":{"b":{},"c":[],"d":1},"e":2}', {
    "{",
    '  "a": {',
    '    "b": {},',
    '    "c": [],',
    '    "d": 1',
    "  },",
    '  "e": 2',
    "}",
  })
end)

test("an array that is the whole record puts each item on its own line", function()
  assert_formats('[1,"two",false]', {
    "[",
    "  1,",
    '  "two",',
    "  false",
    "]",
  })
end)

test("a number that is the whole record is one line holding the number", function()
  assert_formats("42", { "42" })
end)

test("a string that is the whole record is one line holding the string", function()
  assert_formats('"just text"', { '"just text"' })
end)

test("true, false and null that are the whole record are each one line holding the word", function()
  assert_formats("true", { "true" })
  assert_formats("false", { "false" })
  assert_formats("null", { "null" })
end)

test("spaces before or after a string, number, true, false or null that is the whole record are not kept", function()
  assert_formats("  42", { "42" })
  assert_formats('"just text"  ', { '"just text"' })
  assert_formats(" true ", { "true" })
  assert_formats("null  ", { "null" })
end)

--- The tokens of one record holding a number, a string, a nested array and
--- object, and an empty object, in order.
---@type string[]
local record_tokens = { "{", '"a"', ":", "1", ",", '"b"', ":", "[", "2", ",", "{", '"c"', ":", '"x"', "}", "]", ",", '"d"', ":", "{", "}", "}" }
local compact_record = table.concat(record_tokens)
---@type string[]
local compact_record_lines = {
  "{",
  '  "a": 1,',
  '  "b": [',
  "    2,",
  "    {",
  '      "c": "x"',
  "    }",
  "  ],",
  '  "d": {}',
  "}",
}
--- The record with each kind of whitespace (space, tab, line feed,
--- carriage-return line feed, a mixed run) between every two of its tokens.
---@type string[]
local records_with_whitespace_between_tokens = {}
for _, separator in ipairs({ " ", "\t", "\n", "\r\n", " \t\r\n " }) do
  records_with_whitespace_between_tokens[#records_with_whitespace_between_tokens + 1] =
    table.concat(record_tokens, separator)
end
--- The same record with whitespace of every kind, unevenly placed.
local unevenly_spaced_record = '{ \t"a" :\t1,\r\n  "b":\n[ 2 ,\t{"c" : "x"}\r\n] ,"d" :  {\n}  }'
--- A record whose strings start, end or are filled with spaces.
local spaces_in_strings_record =
  '{ "a" : "  leading" , "b" : "trailing  " , "c" : "repeated   spaces" , " d " : " " }'
--- An object record with whitespace of every kind before and after it.
local record_inside_whitespace = ' \t\r\n{"a":1}\r\n\t '

test("spaces, tabs, line feeds and carriage-return line feeds between the tokens of a record do not change its lines", function()
  assert_formats(compact_record, compact_record_lines)
  for _, text in ipairs(records_with_whitespace_between_tokens) do
    assert_formats(text, compact_record_lines)
  end
  assert_formats(unevenly_spaced_record, compact_record_lines)
end)

test("whitespace before or after an object or array that is the whole record adds no lines or characters", function()
  assert_formats(record_inside_whitespace, { "{", '  "a": 1', "}" })
  assert_formats("\n[1,2]\t", { "[", "  1,", "  2", "]" })
  assert_formats("\r\n[1,2]\r\n", { "[", "  1,", "  2", "]" })
  assert_formats("\t{}\r\n", { "{}" })
end)

test("the formatter's own lines joined with line breaks format to the same lines again", function()
  assert_formats(table.concat(compact_record_lines, "\n"), compact_record_lines)
end)

test("spaces inside a string are kept exactly: leading, trailing and repeated", function()
  assert_formats(spaces_in_strings_record, {
    "{",
    '  "a": "  leading",',
    '  "b": "trailing  ",',
    '  "c": "repeated   spaces",',
    '  " d ": " "',
    "}",
  })
end)

test("no line ends in whitespace", function()
  ---@type string[]
  local texts = vim.list_extend({
    unevenly_spaced_record,
    spaces_in_strings_record,
    record_inside_whitespace,
    table.concat(compact_record_lines, "\r\n"),
  }, records_with_whitespace_between_tokens)
  for _, text in ipairs(texts) do
    for position, line in ipairs(json_formatter.format(text)) do
      assert_nil(line:match("%s$"), ("%s line %d:"):format(vim.inspect(text), position))
    end
  end
end)

--- Records holding only whitespace: a space, a tab, a line feed, a carriage
--- return and a carriage-return line feed alone, repeated, and a mixed run.
---@type string[]
local whitespace_only_records = { " ", "   ", "\t", "\t\t", "\n", "\n\n", "\r", "\r\n", " \t\r\n " }
--- Every blank record: empty text and the records holding only whitespace.
---@type string[]
local blank_records = vim.list_extend({ "" }, whitespace_only_records)

test("empty text formats to an empty list of lines", function()
  assert_formats("", {})
end)

test("text made only of spaces, tabs, line feeds or carriage returns formats to an empty list of lines", function()
  for _, text in ipairs(whitespace_only_records) do
    assert_formats(text, {})
  end
end)

test("a blank record gives an empty list, not a list holding one empty line", function()
  for _, text in ipairs(blank_records) do
    local lines = json_formatter.format(text)
    assert_eq(vim.islist(lines), true, vim.inspect(text) .. " gives a list:")
    assert_eq(#lines, 0, vim.inspect(text) .. " line count:")
  end
end)

test("formatting a blank record does not raise", function()
  for _, text in ipairs(blank_records) do
    local ok, err = pcall(json_formatter.format, text)
    assert_eq(ok, true, vim.inspect(text) .. " raised: " .. tostring(err))
  end
end)

test("a string value holding braces, brackets, a comma and a colon stays one string", function()
  assert_formats('{"s":"a{b}[c],d:e"}', { "{", '  "s": "a{b}[c],d:e"', "}" })
end)

test("a string value holding a quote, a colon and a space is not split and invents no key", function()
  assert_formats('{"a":"name\\": \\"value","b":1}', {
    "{",
    '  "a": "name\\": \\"value",',
    '  "b": 1',
    "}",
  })
  -- Without the space the formatter's own ": " would show if it took the
  -- colon for the end of a key.
  assert_formats('{"a":"name\\":\\"value","b":1}', {
    "{",
    '  "a": "name\\":\\"value",',
    '  "b": 1',
    "}",
  })
end)

test("a key holding a brace, a comma or a colon is kept whole and followed by a colon and a space", function()
  assert_formats('{"{a}":1,"b,c":2,"d:e":3}', {
    "{",
    '  "{a}": 1,',
    '  "b,c": 2,',
    '  "d:e": 3',
    "}",
  })
end)

test("a string item of an array holding ],[ stays one item on one line", function()
  assert_formats('{"a":["x],[y","z"],"b":1}', {
    "{",
    '  "a": [',
    '    "x],[y",',
    '    "z"',
    "  ],",
    '  "b": 1',
    "}",
  })
end)

--- Asserts that the string `value`, as a member's value in an object nested
--- in the record, stays on its member's line and leaves the lines after it
--- as deep as after plain text; a failure names the text it was given.
---@param value string a string as written in JSON text
local function assert_lines_after_string_keep_depth(value)
  assert_formats('{"a":{"b":' .. value .. ',"c":[1]},"d":2}', {
    "{",
    '  "a": {',
    '    "b": ' .. value .. ",",
    '    "c": [',
    "      1",
    "    ]",
    "  },",
    '  "d": 2',
    "}",
  })
end

test("the lines after a string holding structural characters are indented as after plain text", function()
  for _, value in ipairs({ '"plain text"', '"x}],[{y: z"', '"{"', '"]"', '","', '":"' }) do
    assert_lines_after_string_keep_depth(value)
  end
end)

test("a string value holding escaped quotes and a comma stays one string and the next member is on the following line", function()
  assert_formats('{"a":"say \\"hi\\", ok","b":1}', { "{", '  "a": "say \\"hi\\", ok",', '  "b": 1', "}" })
  -- With the comma between the two escaped quotes, a formatter that took an
  -- escaped quote for the end of the string would break the line there.
  assert_formats('{"a":"say \\"hi, ok\\"","b":1}', { "{", '  "a": "say \\"hi, ok\\"",', '  "b": 1', "}" })
end)

test("a string value ending in an escaped backslash ends at its own closing quote", function()
  assert_formats('{"a":"path\\\\","b":1}', { "{", '  "a": "path\\\\",', '  "b": 1', "}" })
end)

test("a string value holding an escaped backslash and then an escaped quote is one string", function()
  assert_formats('{"a":"\\\\\\"","b":1}', { "{", '  "a": "\\\\\\"",', '  "b": 1', "}" })
end)

test("a string value holding only an escaped backslash is one string", function()
  assert_formats('{"a":"\\\\","b":1}', { "{", '  "a": "\\\\",', '  "b": 1', "}" })
end)

test("the lines after a string holding an escaped quote and then a comma or closing brace are indented as after plain text", function()
  for _, value in ipairs({ '"\\","', '"\\"}"' }) do
    assert_lines_after_string_keep_depth(value)
  end
end)

--- Strings holding escaped quotes and backslashes, as written in JSON text.
---@type string[]
local strings_with_escapes =
  { '"say \\"hi\\", ok"', '"say \\"hi, ok\\""', '"path\\\\"', '"\\\\\\""', '"\\\\"', '"\\","', '"\\"}"' }

--- Asserts that the string `key`, as the first key of an object record, is
--- kept whole and followed by a colon and a space, with the next member on
--- the following line; a failure names the text it was given.
---@param key string a string as written in JSON text
local function assert_key_kept_as_written(key)
  assert_formats("{" .. key .. ':1,"b":2}', { "{", "  " .. key .. ": 1,", '  "b": 2', "}" })
end

test("a key holding escaped quotes or backslashes is kept whole and the next member is on the following line", function()
  for _, key in ipairs(strings_with_escapes) do
    assert_key_kept_as_written(key)
  end
end)

test("members keep the order the record has them, at every level of nesting", function()
  assert_formats('{"zeta":{"zeta":1,"alpha":2,"mid":3},"alpha":[{"zeta":1,"alpha":2,"mid":3}],"mid":3}', {
    "{",
    '  "zeta": {',
    '    "zeta": 1,',
    '    "alpha": 2,',
    '    "mid": 3',
    "  },",
    '  "alpha": [',
    "    {",
    '      "zeta": 1,',
    '      "alpha": 2,',
    '      "mid": 3',
    "    }",
    "  ],",
    '  "mid": 3',
    "}",
  })
  -- A decoder's key order changes from one Neovim process to the next;
  -- decoding and encoding again almost never gave back both this record and
  -- the one above in the same process (11 of 8,300 spec runs measured). The
  -- check that does not depend on chance is point 20's count of calls to the
  -- decoder and encoder.
  assert_formats('{"mid":{"mid":1,"zeta":2,"alpha":3},"zeta":[{"mid":1,"zeta":2,"alpha":3}],"alpha":3}', {
    "{",
    '  "mid": {',
    '    "mid": 1,',
    '    "zeta": 2,',
    '    "alpha": 3',
    "  },",
    '  "zeta": [',
    "    {",
    '      "mid": 1,',
    '      "zeta": 2,',
    '      "alpha": 3',
    "    }",
    "  ],",
    '  "alpha": 3',
    "}",
  })
end)

--- Asserts that `value`, as a member's value and as an item of an array,
--- comes out exactly as it is written; a failure names the text it was given.
---@param value string a value as written in JSON text
local function assert_value_kept_as_written(value)
  assert_formats('{"a":' .. value .. ',"b":[' .. value .. ",1]}", {
    "{",
    '  "a": ' .. value .. ",",
    '  "b": [',
    "    " .. value .. ",",
    "    1",
    "  ]",
    "}",
  })
end

--- Asserts that the number `value`, as the whole record, as a member's value
--- and as an item of an array, comes out exactly as it is written; a failure
--- names the text it was given.
---@param value string a number as written in JSON text
local function assert_number_kept_as_written(value)
  assert_formats(value, { value })
  assert_value_kept_as_written(value)
end

test("a number with an exponent is kept as written: 1.2e-3 and 1E+2", function()
  for _, value in ipairs({ "1.2e-3", "1E+2" }) do
    assert_number_kept_as_written(value)
  end
end)

test("a number keeps its trailing zeros: 18.40 and 1.0", function()
  for _, value in ipairs({ "18.40", "1.0" }) do
    assert_number_kept_as_written(value)
  end
end)

test("an integer of twenty digits keeps every digit", function()
  assert_number_kept_as_written("12345678901234567890")
end)

test("-0.5, -0 and 0 are kept as written", function()
  -- 0 is the only record in this spec that is one character long and not
  -- blank.
  for _, value in ipairs({ "-0.5", "-0", "0" }) do
    assert_number_kept_as_written(value)
  end
end)

test("true, false and null stay lowercase words as a member's value and as an item of an array", function()
  for _, value in ipairs({ "true", "false", "null" }) do
    assert_value_kept_as_written(value)
  end
end)

test("a string that looks like a number, true, false or null keeps its quotes", function()
  for _, value in ipairs({ '"1"', '"1.0"', '"true"', '"false"', '"null"' }) do
    assert_value_kept_as_written(value)
  end
end)

--- Asserts that the string `value` is `byte_length` bytes long as written in
--- the record and in the lines, and that it comes out with exactly its bytes
--- as the whole record, as a member's value, as an item of an array and as a
--- key; a failure names the text it was given.
---@param value string a string as written in JSON text
---@param byte_length integer the bytes of `value`, counted by hand
local function assert_string_kept_byte_for_byte(value, byte_length)
  -- Counted by hand, so a Lua escape or an editor that changed the value in
  -- this file is caught before the formatter is asked anything.
  assert_eq(#value, byte_length, vim.inspect(value) .. " bytes as written:")
  local record_line = json_formatter.format(value)[1] or ""
  assert_eq(#record_line, byte_length, vim.inspect(value) .. " bytes in the line of the whole record:")
  local member_line = json_formatter.format('{"a":' .. value .. "}")[2] or ""
  assert_eq(#member_line - #'  "a": ', byte_length, vim.inspect(value) .. " bytes in the member's line:")
  assert_formats(value, { value })
  assert_value_kept_as_written(value)
  assert_key_kept_as_written(value)
end

test("a string holding the escapes \\n, \\t and \\u00e9 keeps them as written, on one line", function()
  assert_string_kept_byte_for_byte('"line1\\nline2\\t\\u00e9"', 22)
end)

test("a string of multi-byte characters written directly keeps their bytes: accented letters, a check mark, CJK characters and a four-byte emoji", function()
  -- é, ü and ñ are two bytes each, the check mark and each CJK character
  -- three, the emoji four.
  assert_string_kept_byte_for_byte('"é ü ñ ✓ 漢字 😀"', 26)
end)

test('the empty string stays ""', function()
  assert_string_kept_byte_for_byte('""', 2)
end)

test("a string holding the escapes \\/, \\b, \\f and \\r keeps each as written", function()
  assert_string_kept_byte_for_byte('"\\/\\b\\f\\r"', 10)
end)

test("a \\u escape for a surrogate pair is kept as its two escapes", function()
  assert_string_kept_byte_for_byte('"\\ud83d\\ude00"', 14)
end)

--- Instructions the formatter may run on one short text before it counts as
--- looping; every text in this spec needs a few hundred at most.
local INSTRUCTIONS_BEFORE_LOOPING = 1000000

--- Asserts that formatting `text` returns, without raising and without
--- looping, a list of strings none of which holds a line feed or a carriage
--- return. A failure names the text.
---@param text string text that is not valid JSON
local function assert_formats_to_lines_without_line_breaks(text)
  -- A count hook is not called inside compiled code, so the JIT is off while
  -- the hook turns a loop into an error, and the code earlier cases compiled
  -- is flushed: turning the JIT off does not stop that code from running.
  jit.off()
  jit.flush()
  debug.sethook(function()
    error(("still running after %d instructions"):format(INSTRUCTIONS_BEFORE_LOOPING))
  end, "", INSTRUCTIONS_BEFORE_LOOPING)
  local ok, lines = pcall(json_formatter.format, text)
  debug.sethook()
  jit.on()
  assert_eq(ok, true, vim.inspect(text) .. " raised: " .. tostring(lines))
  assert_list_of_strings(lines, "the result for " .. vim.inspect(text))
  for position, line in ipairs(lines) do
    assert_nil(line:find("[\r\n]"), ("%s line %d holds a line break:"):format(vim.inspect(text), position))
  end
end

test("text that is not valid JSON returns a list of lines without raising or looping", function()
  for _, text in ipairs({
    "}}}",
    '{"a":',
    '{"a":"never closes',
    "only plain words and not JSON",
    '{"a":"ends in a lone backslash \\',
    ",",
    ":",
  }) do
    assert_formats_to_lines_without_line_breaks(text)
  end
end)

test("a raw line break inside a string gives lines none of which holds a line break", function()
  for _, text in ipairs({
    '{"a":"one\ntwo"}',
    '{"a":"one\ntwo\nthree"}',
    '{"a":"one\r\ntwo"}',
    '{"a":"one\rtwo"}',
    '"one\ntwo"',
    '{"o\nne":1}',
    '{"a":"never\ncloses',
  }) do
    assert_formats_to_lines_without_line_breaks(text)
  end
end)

test("a raw line break between words that are not JSON gives no line holding a line break", function()
  for _, text in ipairs({ "plain\nwords", "plain\r\nwords", '{"a":tr\nue}' }) do
    assert_formats_to_lines_without_line_breaks(text)
  end
end)

test("closing braces and brackets with nothing open do not raise", function()
  for _, text in ipairs({ "]]]", "}]", '}]{"a":[1]}' }) do
    assert_formats_to_lines_without_line_breaks(text)
  end
end)

--- The 300 items of a long array, in turn a number, a string holding a comma
--- and brackets, and an object.
---@type string[]
local long_array_items = {}
for item = 1, 300 do
  long_array_items[item] = ({ tostring(item), '"item ' .. item .. ', [x]"', '{"n":' .. item .. "}" })[item % 3 + 1]
end

--- Valid records of every shape the formatter must lay out, as written in
--- JSON text.
---@type string[]
local varied_records = {
  -- Ten levels of nesting.
  '{"a":[{"b":{"c":[[{"d":{"e":[1,{"f":"ten levels deep"}]}}]]}}]}',
  "[" .. table.concat(long_array_items, ",") .. "]",
  -- Empty objects and arrays as members' values and as items of arrays.
  '{"a":{},"b":[],"c":[{},[],{"d":{}},[[]]],"e":{"f":{"g":[]}}}',
  '{"s":"a{b}[c],d:e","t":["x],[y","}{",":"],"{k:v}":"\\"q\\", and \\\\"}',
  "[" .. table.concat(strings_with_escapes, ",") .. "]",
  '{"é ü ñ":"✓ 漢字 😀","emoji":["😀","\\ud83d\\ude00"],"escaped":"\\u00e9\\n\\t\\/\\b\\f\\r"}',
  '{"integers":[0,42,-7,12345678901234567890],"decimals":[18.40,-0.5,3.14],"exponents":[1.2e-3,1E+2,-6.02E23],"minus zero":-0}',
  '{"yes":true,"no":false,"nothing":null,"words":[true,false,null]}',
  '[1,"two",false,null,[],{}]',
  '"a bare string, {with} [structure]: \\"quoted\\""',
  -- A string that is the whole record and looks like a number.
  '"1.0"',
  "-1.5e10",
  compact_record,
  unevenly_spaced_record,
}

test("the lines of every record in a varied set, joined with line feeds, decode to the same value as the record", function()
  for _, text in ipairs(varied_records) do
    -- Checked first, so a record this spec wrote wrongly is not taken for one
    -- the formatter broke.
    local record_decodes, record_value = pcall(vim.json.decode, text)
    assert_eq(record_decodes, true, vim.inspect(text) .. " is not JSON the decoder accepts: " .. tostring(record_value))
    -- No limits: it is the untrimmed lines that must decode.
    local lines = json_formatter.format(text)
    local lines_decode, lines_value = pcall(vim.json.decode, table.concat(lines, "\n"))
    assert_eq(lines_decode, true, vim.inspect(text) .. " formats to lines that do not decode: " .. tostring(lines_value))
    assert_deep_eq(lines_value, record_value, vim.inspect(text) .. " formats to lines that decode to another value:")
  end
end)

--- The formatter's own file, as the record preview's worker thread loads it.
local json_formatter_path = vim.fn.stdpath("config") .. "/lua/andrew/jsonl/json_formatter.lua"
--- How long a case waits for a worker thread's result before it fails.
local WORKER_RESULT_LIMIT_MS = 5000

--- Runs in a worker thread (`vim.uv.new_work`), in a Lua state of its own
--- that sees none of this file's locals, so all it needs comes as arguments.
--- Loads the formatter by path, with nothing `require` could load, and
--- formats `text`. Returns true and the lines packed with `vim.mpack` (a
--- worker thread hands back strings, not tables), or false and the error. A
--- loop becomes an error as in point 17: a worker thread that never ends
--- would keep the process from exiting.
---@param module_path string
---@param text string
---@param instruction_limit integer
---@return boolean is_formatted
---@return string packed_lines_or_error
local function format_in_worker_thread(module_path, text, instruction_limit)
  -- The worker thread's runtime path loader would find this config's modules.
  package.loaders = {}
  jit.off()
  jit.flush()
  debug.sethook(function()
    error(("still running after %d instructions"):format(instruction_limit))
  end, "", instruction_limit)
  local is_formatted, packed_lines_or_error = pcall(function()
    return vim.mpack.encode((dofile(module_path).format(text)))
  end)
  debug.sethook()
  return is_formatted, tostring(packed_lines_or_error)
end

test("the formatter loaded by path in a worker thread hands back, as a list of strings, the lines it gives a nested record on the main thread", function()
  ---@type { is_formatted: boolean?, packed_lines_or_error: string? }?
  local worker_result = nil
  vim.uv
    .new_work(
      format_in_worker_thread,
      ---@param is_formatted boolean?
      ---@param packed_lines_or_error string?
      function(is_formatted, packed_lines_or_error)
        worker_result = { is_formatted = is_formatted, packed_lines_or_error = packed_lines_or_error }
      end
    )
    :queue(json_formatter_path, compact_record, INSTRUCTIONS_BEFORE_LOOPING)
  local has_answered = vim.wait(WORKER_RESULT_LIMIT_MS, function()
    return worker_result ~= nil
  end, 10)
  assert_eq(has_answered, true, ("no result from the worker thread within %d ms:"):format(WORKER_RESULT_LIMIT_MS))
  ---@cast worker_result -nil
  assert_eq(worker_result.is_formatted, true, "the worker thread failed: " .. tostring(worker_result.packed_lines_or_error))
  local lines = vim.mpack.decode(worker_result.packed_lines_or_error --[[@as string]])
  assert_list_of_strings(lines, "the worker thread's result")
  assert_deep_eq(lines, json_formatter.format(compact_record), "lines from the worker thread:")
end)

--- Every global of this Lua state, `_G` included, in a table of their own,
--- for the formatter's file to be loaded in.
---@return table<string, any>
local function copy_of_globals()
  ---@type table<string, any>
  local environment = {}
  for name, value in pairs(_G --[[@as table<string, any>]]) do
    environment[name] = value
  end
  environment._G = environment
  return environment
end

test("the formatter loaded by path where the editor's global is absent formats a record", function()
  local environment = copy_of_globals()
  environment.vim = nil
  ---@module "andrew.jsonl.json_formatter"
  local formatter = setfenv(assert(loadfile(json_formatter_path)), environment)()
  assert_deep_eq(formatter.format(compact_record), compact_record_lines, "without the editor's global:")
end)

test("the formatter loaded by path where require can load no module formats a record", function()
  local environment = copy_of_globals()
  ---@param module_name string
  environment.require = function(module_name)
    error("the formatter requires " .. module_name)
  end
  ---@module "andrew.jsonl.json_formatter"
  local formatter = setfenv(assert(loadfile(json_formatter_path)), environment)()
  assert_deep_eq(formatter.format(compact_record), compact_record_lines, "without a module loader:")
end)

--- Runs `action` with the built-in JSON decoder and encoder replaced by
--- counting ones, and puts the real ones back before returning, whether or
--- not `action` raised. It asserts nothing itself, since an assert raises and
--- would leave the counting ones in place.
---@param action fun()
---@return boolean has_returned
---@return string error_text `tostring` of what `action` raised ("nil" when it returned)
---@return integer decoder_calls
---@return integer encoder_calls
local function count_json_calls(action)
  local real_decode, real_encode = vim.json.decode, vim.json.encode
  local decoder_calls, encoder_calls = 0, 0
  -- `vim.json.decode` and `vim.json.encode` reject an `opts` that is nil, so
  -- it is passed on only when it is given.
  ---@param str string
  ---@param opts? vim.json.decode.Opts
  ---@return any
  local function counting_decode(str, opts)
    decoder_calls = decoder_calls + 1
    if opts == nil then
      return real_decode(str)
    end
    return real_decode(str, opts)
  end
  ---@param obj any
  ---@param opts? vim.json.encode.Opts
  ---@return string
  local function counting_encode(obj, opts)
    encoder_calls = encoder_calls + 1
    if opts == nil then
      return real_encode(obj)
    end
    return real_encode(obj, opts)
  end
  vim.json.decode, vim.json.encode = counting_decode, counting_encode
  local has_returned, error_value = pcall(action)
  vim.json.decode, vim.json.encode = real_decode, real_encode -- finally: always restore
  return has_returned, tostring(error_value), decoder_calls, encoder_calls
end

--- Loads the formatter by path and formats `text` while calls to the JSON
--- decoder and encoder are counted, and asserts that it returned and made
--- none. It is loaded inside the count, not taken from the `require` at the
--- top of this file, so a decoder the formatter keeps from when it loaded is
--- the counting one too.
---@param text string
---@param label string
local function assert_formats_without_json_calls(text, label)
  local has_returned, error_text, decoder_calls, encoder_calls = count_json_calls(function()
    dofile(json_formatter_path).format(text)
  end)
  assert_eq(has_returned, true, label .. " raised: " .. error_text)
  assert_eq(decoder_calls, 0, label .. ", calls to the decoder:")
  assert_eq(encoder_calls, 0, label .. ", calls to the encoder:")
end

test("the count of calls to the JSON decoder and encoder sees every call and puts the real ones back when what it counts raises", function()
  local real_decode, real_encode = vim.json.decode, vim.json.encode
  local has_returned, _, decoder_calls, encoder_calls = count_json_calls(function()
    vim.json.encode(vim.json.decode("[1]"))
    error("raised on purpose")
  end)
  assert_eq(has_returned, false, "the counted function raised:")
  assert_eq(decoder_calls, 1, "calls to the decoder:")
  assert_eq(encoder_calls, 1, "calls to the encoder:")
  assert_eq(vim.json.decode == real_decode, true, "the real decoder is back:")
  assert_eq(vim.json.encode == real_encode, true, "the real encoder is back:")
end)

test("formatting a small record calls the built-in JSON decoder and encoder zero times", function()
  assert_formats_without_json_calls(compact_record, "the small record")
end)

--- The varied set of point 18, many times over, as the items of one array.
---@type string[]
local large_record_items = {}
for copy = 1, 300 do
  large_record_items[copy] = table.concat(varied_records, ",")
end
local large_record = "[" .. table.concat(large_record_items, ",") .. "]"

test("formatting a record of more than a megabyte calls the built-in JSON decoder and encoder zero times", function()
  assert_eq(#large_record >= 1024 * 1024, true, "the large record is at least a megabyte: " .. #large_record .. " bytes;")
  assert_formats_without_json_calls(large_record, "the large record")
end)

--- The small limits point 21 describes.
---@type JsonTrimLimits
local SMALL_LIMITS = { array_items = 3, string_characters = 10 }

--- Asserts that `text` formats with the small limits to exactly the lines
--- `expected`; a failure names the text it was given.
---@param text string the JSON text of one record
---@param expected string[] the lines the formatter must return
local function assert_formats_with_small_limits(text, expected)
  assert_deep_eq(json_formatter.format(text, SMALL_LIMITS), expected, vim.inspect(text) .. " with small limits:")
end

--- Asserts that `text` formats with the small limits to exactly the lines it
--- gives without limits; a failure names the text it was given.
---@param text string the JSON text of one record
local function assert_small_limits_change_nothing(text)
  assert_formats_with_small_limits(text, (json_formatter.format(text)))
end

--- The positions in `lines` of the lines holding `piece`, found as plain text.
---@param lines string[] lines the formatter returned
---@param piece string the text to look for
---@return integer[] positions
local function positions_of_lines_holding(lines, piece)
  ---@type integer[]
  local positions = {}
  for position, line in ipairs(lines) do
    if line:find(piece, 1, true) then
      positions[#positions + 1] = position
    end
  end
  return positions
end

--- Asserts that `text` formats with the small limits to exactly the lines
--- `lines_before`, then one line that is `line_start` followed by a marker
--- for one `unit` left out, then exactly `lines_after`; a failure names the
--- text it was given. How the marker words exactly one item or character is
--- not pinned here.
---@param text string the JSON text of one record
---@param lines_before string[] the lines before the line ending in the marker
---@param line_start string that line up to the `…` of its marker, a string's two-space gap included
---@param unit "item"|"character" what the marker counts
---@param lines_after string[] the lines after the line ending in the marker
local function assert_formats_with_small_limits_leaving_one_out(text, lines_before, line_start, unit, lines_after)
  local lines = json_formatter.format(text, SMALL_LIMITS)
  local label = vim.inspect(text) .. " with small limits"
  local marker_line_position = #lines_before + 1
  assert_eq(#lines, marker_line_position + #lines_after, label .. ", number of lines:")
  assert_deep_eq(vim.list_slice(lines, 1, marker_line_position - 1), lines_before, label .. ", the lines before the marker's line:")
  assert_match(lines[marker_line_position], "^" .. vim.pesc(line_start) .. "… 1 more " .. unit .. "s?$", label .. ", the marker's line:")
  assert_deep_eq(vim.list_slice(lines, marker_line_position + 1), lines_after, label .. ", the lines after the marker's line:")
end

--- Asserts that no line `texts` format to with the small limits holds a
--- marker stating that zero items or characters were left out; a failure
--- names the text and the line's position.
---@param texts string[] the JSON texts of one record each
local function assert_no_marker_states_zero_left_out(texts)
  for _, text in ipairs(texts) do
    for position, line in ipairs((json_formatter.format(text, SMALL_LIMITS))) do
      assert_nil(line:find("… 0 ", 1, true), vim.inspect(text) .. " with small limits, line " .. position .. ":")
    end
  end
end

test("an array that is the whole record with more items than the limit shows its first items and then a marker line", function()
  assert_formats_with_small_limits("[1,2,3,4,5]", { "[", "  1,", "  2,", "  3,", "  … 2 more items", "]" })
end)

test("an array that is a member's value with more items than the limit is cut the same way and its closing bracket keeps its comma", function()
  assert_formats_with_small_limits('{"h":[1,2,3,4,5],"z":1}', {
    "{",
    '  "h": [',
    "    1,",
    "    2,",
    "    3,",
    "    … 2 more items",
    "  ],",
    '  "z": 1',
    "}",
  })
end)

--- Records holding one cut array at different depths, each with the
--- indentation of that array's items.
---@type { text: string, item_indentation: string }[]
local records_with_a_cut_array = {
  { text = "[1,2,3,4,5]", item_indentation = "  " },
  { text = '{"h":[1,2,3,4,5],"z":1}', item_indentation = "    " },
  { text = '{"a":{"b":[1,2,3,4,5]},"z":[]}', item_indentation = "      " },
}

test("the marker line is indented as the array's items are and holds nothing but the marker", function()
  for _, record in ipairs(records_with_a_cut_array) do
    local lines = json_formatter.format(record.text, SMALL_LIMITS)
    local marker_positions = positions_of_lines_holding(lines, "…")
    local label = vim.inspect(record.text) .. " with small limits"
    assert_eq(#marker_positions, 1, label .. ", lines holding a marker:")
    local marker_position = marker_positions[1]
    assert_eq(lines[marker_position], record.item_indentation .. "… 2 more items", label .. ", the marker line:")
    assert_eq(lines[marker_position - 1], record.item_indentation .. "3,", label .. ", the line before the marker:")
  end
end)

test("the last shown item's line ends in a comma, whether the item is a number, a string, an object or an array", function()
  assert_formats_with_small_limits("[1,2,3,4,5]", { "[", "  1,", "  2,", "  3,", "  … 2 more items", "]" })
  assert_formats_with_small_limits('["a","b","c","d","e"]', { "[", '  "a",', '  "b",', '  "c",', "  … 2 more items", "]" })
  assert_formats_with_small_limits('[1,2,{"c":3},4,5]', {
    "[",
    "  1,",
    "  2,",
    "  {",
    '    "c": 3',
    "  },",
    "  … 2 more items",
    "]",
  })
  assert_formats_with_small_limits("[1,2,[3],4,5]", { "[", "  1,", "  2,", "  [", "    3", "  ],", "  … 2 more items", "]" })
end)

test("the shown items are the array's first ones, in order, each laid out as without limits, an object or array item on its usual lines", function()
  local text = '[{"a":1,"b":[2,3]},[4,5],{"c":6},7,8]'
  assert_formats_with_small_limits(text, {
    "[",
    "  {",
    '    "a": 1,',
    '    "b": [',
    "      2,",
    "      3",
    "    ]",
    "  },",
    "  [",
    "    4,",
    "    5",
    "  ],",
    "  {",
    '    "c": 6',
    "  },",
    "  … 2 more items",
    "]",
  })
  local lines_with_limits = json_formatter.format(text, SMALL_LIMITS)
  local lines_without_limits = json_formatter.format(text)
  assert_deep_eq(
    vim.list_slice(lines_with_limits, 1, 15),
    vim.list_slice(lines_without_limits, 1, 15),
    vim.inspect(text) .. ", the shown items' lines with small limits and without limits:"
  )
end)

--- Records whose every array has fewer items than the small limits allow.
---@type string[]
local records_with_short_arrays = {
  "[]",
  "[1]",
  "[1,2]",
  '{"h":[],"z":1}',
  '{"h":[1],"z":1}',
  '{"h":[1,2],"z":1}',
  '[{"a":[1,2]},[3]]',
  "[[1,2],[1]]",
  "[[],1]",
}

test("an array with fewer items than the limit comes out as it does without limits", function()
  for _, text in ipairs(records_with_short_arrays) do
    assert_small_limits_change_nothing(text)
  end
end)

test("a string that is the whole record with more characters than the limit shows its first characters, closed with a quote, then a marker", function()
  assert_formats_with_small_limits('"0123456789abcdef"', { '"0123456789"  … 6 more characters' })
end)

test("a string that is the last member's value with more characters than the limit is cut the same way on the member's line", function()
  assert_formats_with_small_limits('{"t":"0123456789abcdef"}', { "{", '  "t": "0123456789"  … 6 more characters', "}" })
end)

--- The shown part of the long string `value`, as written in JSON text, with
--- the small limits: its first characters between quotes.
---@param value string a string of single-byte characters as written in JSON text
---@return string
local function shown_part_of(value)
  return '"' .. value:sub(2, 1 + SMALL_LIMITS.string_characters) .. '"'
end

--- Strings of plain single-byte characters with more characters than the
--- small limits allow, as written in JSON text; each cut leaves out 2, 6, 16
--- or 90 characters.
---@type string[]
local long_strings = { '"0123456789ab"', '"0123456789abcdef"', '"abcdefghijklmnopqrstuvwxyz"', '"' .. ("x"):rep(100) .. '"' }

--- The line a long string gives with the small limits as the whole record
--- and as the last member's value, without the member's indentation and key,
--- and the label a failure names it by.
---@param value string a string as written in JSON text
---@return { label: string, line: string }[]
local function lines_of_cut_string(value)
  local member_line = json_formatter.format('{"t":' .. value .. "}", SMALL_LIMITS)[2] or ""
  return {
    {
      label = vim.inspect(value) .. " as the whole record with small limits",
      line = json_formatter.format(value, SMALL_LIMITS)[1] or "",
    },
    {
      label = vim.inspect(value) .. " as the last member's value with small limits",
      line = (member_line:gsub('^  "t": ', "", 1)),
    },
  }
end

test("the shown part of a cut string is its first characters between quotes, though the record's closing quote is not reached", function()
  for _, value in ipairs(long_strings) do
    for _, cut in ipairs(lines_of_cut_string(value)) do
      assert_eq(cut.line:sub(1, 12), shown_part_of(value), cut.label .. ", the shown part:")
    end
  end
end)

test("exactly two spaces separate a cut string's closing quote from its marker", function()
  for _, value in ipairs(long_strings) do
    for _, cut in ipairs(lines_of_cut_string(value)) do
      assert_eq(cut.line:sub(12, 14 + #"…"), '"  …', cut.label .. ", from the closing quote to the marker:")
    end
  end
end)

test("the characters shown plus the count in the marker equal the characters of the string as the record writes it", function()
  for _, value in ipairs(long_strings) do
    for _, cut in ipairs(lines_of_cut_string(value)) do
      ---@type string?, string?
      local shown, left_out = cut.line:match('^"(.*)"  … (%d+) more characters$')
      assert_eq(type(shown), "string", cut.label .. ", a shown part and a marker in " .. vim.inspect(cut.line) .. ":")
      ---@cast shown -nil
      ---@cast left_out -nil
      assert_eq(#shown + tonumber(left_out), #value - 2, cut.label .. ", characters shown plus characters left out:")
    end
  end
end)

test("a cut string stays on one line, the line its marker is on", function()
  for _, value in ipairs(long_strings) do
    for _, text in ipairs({ value, '{"t":' .. value .. "}", '{"a":{"t":' .. value .. "}}" }) do
      local label = vim.inspect(text) .. " with small limits"
      local lines_with_limits = json_formatter.format(text, SMALL_LIMITS)
      assert_eq(#lines_with_limits, #json_formatter.format(text), label .. ", lines as many as without limits:")
      local shown_part_and_marker = shown_part_of(value) .. "  …"
      local positions = positions_of_lines_holding(lines_with_limits, shown_part_and_marker)
      assert_eq(#positions, 1, label .. ", lines holding the shown part and the marker:")
    end
  end
end)

--- Records whose every string has fewer characters than the small limits
--- allow.
---@type string[]
local records_with_short_strings = {
  '""',
  '"a"',
  '"012345678"',
  '{"t":"012345678"}',
  '{"a":"x","t":"012345678"}',
  '{"t":"","z":1}',
  '["abc","012345678"]',
  '["",""]',
  '{"012345678":1,"b":2}',
  '{"":1}',
}

test("a string with fewer characters than the limit comes out as it does without limits", function()
  for _, text in ipairs(records_with_short_strings) do
    assert_small_limits_change_nothing(text)
  end
end)

test("a string that is a member's value with more characters than the limit keeps its comma before the marker when another member follows", function()
  assert_formats_with_small_limits('{"t":"0123456789abcdef","z":1}', { "{", '  "t": "0123456789",  … 6 more characters', '  "z": 1', "}" })
end)

test("a string that is an item of an array with more characters than the limit keeps its comma before the marker when another item follows", function()
  assert_formats_with_small_limits('["0123456789abcdef",2]', { "[", '  "0123456789",  … 6 more characters', "  2", "]" })
end)

--- What follows the shown part of the cut string `value` on its line, in
--- records where a sibling follows it, as a member's value and as an item of
--- an array, one and two levels deep, and the label a failure names it by.
---@param value string a string as written in JSON text
---@return { label: string, after_shown_part: string }[]
local function lines_after_cut_string_before_a_sibling(value)
  ---@type { label: string, after_shown_part: string }[]
  local results = {}
  local shown_part = shown_part_of(value)
  for _, text in ipairs({
    '{"t":' .. value .. ',"z":1}',
    "[" .. value .. ",2]",
    '{"a":{"t":' .. value .. ',"z":1},"y":2}',
    "[[" .. value .. ",2],3]",
  }) do
    local label = vim.inspect(text) .. " with small limits"
    local lines = json_formatter.format(text, SMALL_LIMITS)
    local positions = positions_of_lines_holding(lines, shown_part)
    assert_eq(#positions, 1, label .. ", lines holding the shown part:")
    local line = lines[positions[1]]
    local _, quote_at = line:find(shown_part, 1, true)
    ---@cast quote_at -nil
    results[#results + 1] = { label = label, after_shown_part = line:sub(quote_at + 1) }
  end
  return results
end

test("a cut string's comma follows its closing quote with nothing between them", function()
  for _, value in ipairs(long_strings) do
    for _, cut in ipairs(lines_after_cut_string_before_a_sibling(value)) do
      assert_eq(cut.after_shown_part:sub(1, 1), ",", cut.label .. ", the byte after the closing quote:")
    end
  end
end)

test("exactly two spaces separate a cut string's comma from its marker", function()
  for _, value in ipairs(long_strings) do
    for _, cut in ipairs(lines_after_cut_string_before_a_sibling(value)) do
      assert_eq(cut.after_shown_part:sub(1, 3 + #"…"), ",  …", cut.label .. ", from the comma to the marker:")
    end
  end
end)

test("a cut string's marker is the last thing on its line, after the comma", function()
  for _, value in ipairs(long_strings) do
    for _, cut in ipairs(lines_after_cut_string_before_a_sibling(value)) do
      assert_match(cut.after_shown_part, "^,  … %d+ more characters$", cut.label .. ", after the closing quote:")
    end
  end
end)

test("a cut string that is the last item a cut array shows keeps its marker after its comma, and the array's marker line follows", function()
  assert_formats_with_small_limits('["a","b","0123456789abcdef","d","e"]', {
    "[",
    '  "a",',
    '  "b",',
    '  "0123456789",  … 6 more characters',
    "  … 2 more items",
    "]",
  })
end)

--- Records holding one cut array, one and two levels deep, whose last shown
--- item is the long string `value`, each with the indentation of that
--- array's items.
---@param value string a string of single-byte characters as written in JSON text
---@return { text: string, item_indentation: string }[]
local function records_with_a_cut_string_as_last_shown_item(value)
  return {
    { text = '["a","b",' .. value .. ',"d","e"]', item_indentation = "  " },
    { text = '{"h":["a","b",' .. value .. ',"d","e"],"z":1}', item_indentation = "    " },
    { text = '[["a","b",' .. value .. ',"d","e"],1]', item_indentation = "    " },
  }
end

test("a cut string's marker and the array's marker are on consecutive lines, one marker on each", function()
  for _, value in ipairs(long_strings) do
    for _, record in ipairs(records_with_a_cut_string_as_last_shown_item(value)) do
      local label = vim.inspect(record.text) .. " with small limits"
      local lines = json_formatter.format(record.text, SMALL_LIMITS)
      local positions = positions_of_lines_holding(lines, "…")
      assert_eq(#positions, 2, label .. ", lines holding a marker:")
      assert_eq(positions[2], positions[1] + 1, label .. ", the position of the array's marker line:")
      local characters_left_out = #value - 2 - SMALL_LIMITS.string_characters
      assert_eq(
        lines[positions[1]],
        record.item_indentation .. shown_part_of(value) .. ",  … " .. characters_left_out .. " more characters",
        label .. ", the cut string's line:"
      )
      assert_eq(lines[positions[2]], record.item_indentation .. "… 2 more items", label .. ", the array's marker line:")
    end
  end
end)

test("a cut string shown before other items of a cut array has its marker on its own line and the items after it are laid out as usual", function()
  assert_formats_with_small_limits('["0123456789abcdef","b","c","d","e"]', {
    "[",
    '  "0123456789",  … 6 more characters',
    '  "b",',
    '  "c",',
    "  … 2 more items",
    "]",
  })
  assert_formats_with_small_limits('["a","0123456789abcdef","c","d","e"]', {
    "[",
    '  "a",',
    '  "0123456789",  … 6 more characters',
    '  "c",',
    "  … 2 more items",
    "]",
  })
end)

test("a long string among the items an array leaves out is not shown and has no marker", function()
  assert_formats_with_small_limits_leaving_one_out('[1,2,3,"0123456789abcdef"]', { "[", "  1,", "  2,", "  3," }, "  ", "item", { "]" })
  assert_formats_with_small_limits('[1,2,3,"0123456789abcdef",5]', { "[", "  1,", "  2,", "  3,", "  … 2 more items", "]" })
end)

test("a key with more characters than the limit is cut as a string is, and its marker follows the line's comma", function()
  assert_formats_with_small_limits('{"0123456789abcdef":1,"b":2}', {
    "{",
    '  "0123456789": 1,  … 6 more characters',
    '  "b": 2',
    "}",
  })
end)

test("a cut key of the last member has its marker at the end of the member's line, which has no comma", function()
  assert_formats_with_small_limits('{"0123456789abcdef":1}', { "{", '  "0123456789": 1  … 6 more characters', "}" })
end)

test("a cut key whose value is an object or array has its marker after the opening bracket", function()
  assert_formats_with_small_limits('{"0123456789abcdef":[1],"b":2}', {
    "{",
    '  "0123456789": [  … 6 more characters',
    "    1",
    "  ],",
    '  "b": 2',
    "}",
  })
  assert_formats_with_small_limits('{"0123456789abcdef":{"c":1},"b":2}', {
    "{",
    '  "0123456789": {  … 6 more characters',
    '    "c": 1',
    "  },",
    '  "b": 2',
    "}",
  })
  assert_formats_with_small_limits('{"0123456789abcdef":[],"b":2}', { "{", '  "0123456789": [],  … 6 more characters', '  "b": 2', "}" })
  assert_formats_with_small_limits('{"0123456789abcdef":{}}', { "{", '  "0123456789": {}  … 6 more characters', "}" })
end)

test("a cut key and its cut string value each keep a marker on their line, the key's first", function()
  assert_formats_with_small_limits('{"0123456789abcdef":"0123456789XYZ","b":2}', {
    "{",
    '  "0123456789": "0123456789",  … 6 more characters  … 3 more characters',
    '  "b": 2',
    "}",
  })
  assert_formats_with_small_limits('{"0123456789abcdef":"0123456789XYZ"}', {
    "{",
    '  "0123456789": "0123456789"  … 6 more characters  … 3 more characters',
    "}",
  })
end)

test("on every line, the markers are as many as the strings cut on it", function()
  ---@type { text: string, markers_per_line: integer[] }[]
  local records = {
    { text = '{"0123456789abcdef":"x","b":"0123456789XYZ"}', markers_per_line = { 0, 1, 1, 0 } },
    { text = '{"a":{"0123456789abcdef":"0123456789XYZ","z":1},"y":2}', markers_per_line = { 0, 0, 2, 0, 0, 0, 0 } },
    { text = '[{"0123456789abcdef":"0123456789XYZ"},2]', markers_per_line = { 0, 0, 2, 0, 0, 0 } },
  }
  for _, record in ipairs(records) do
    ---@type integer[]
    local markers_per_line = {}
    for _, line in ipairs((json_formatter.format(record.text, SMALL_LIMITS))) do
      local _, markers = line:gsub("…", "")
      markers_per_line[#markers_per_line + 1] = markers
    end
    assert_deep_eq(markers_per_line, record.markers_per_line, vim.inspect(record.text) .. " with small limits, markers per line:")
  end
end)

test("a record whose key and string value are both cut reports two trimmed places", function()
  local text = '{"0123456789abcdef":"0123456789XYZ","b":2}'
  local _, trimmed_places = json_formatter.format(text, SMALL_LIMITS)
  assert_eq(trimmed_places, 2, vim.inspect(text) .. " with small limits, trimmed places:")
end)

--- Records holding an array of exactly as many items as the small limits
--- allow as a member's value or as an item of another array, each with the
--- lines it formats to, as without limits.
---@type { text: string, expected: string[] }[]
local records_with_arrays_of_exactly_the_limit = {
  { text = '{"h":[1,2,3],"z":1}', expected = { "{", '  "h": [', "    1,", "    2,", "    3", "  ],", '  "z": 1', "}" } },
  {
    text = '{"a":{"b":[1,2,3]},"z":[]}',
    expected = { "{", '  "a": {', '    "b": [', "      1,", "      2,", "      3", "    ]", "  },", '  "z": []', "}" },
  },
  { text = "[[1,2,3],1]", expected = { "[", "  [", "    1,", "    2,", "    3", "  ],", "  1", "]" } },
  { text = "[1,[1,2,3]]", expected = { "[", "  1,", "  [", "    1,", "    2,", "    3", "  ]", "]" } },
}

test("an array that is the whole record with exactly as many items as the limit is shown whole, with no marker", function()
  assert_formats_with_small_limits("[1,2,3]", { "[", "  1,", "  2,", "  3", "]" })
end)

test("an array that is a member's value or an item of another array with exactly as many items as the limit is shown whole, with no marker", function()
  for _, record in ipairs(records_with_arrays_of_exactly_the_limit) do
    assert_formats_with_small_limits(record.text, record.expected)
  end
end)

--- Records holding one array with one item more than the small limits allow,
--- as the whole record, as a member's value and as an item of another array:
--- the lines before its marker line, the lines after it, and the indentation
--- of that array's items.
---@type { text: string, lines_before_marker: string[], lines_after_marker: string[], item_indentation: string }[]
local records_with_one_item_more_than_the_limit = {
  { text = "[1,2,3,4]", lines_before_marker = { "[", "  1,", "  2,", "  3," }, lines_after_marker = { "]" }, item_indentation = "  " },
  {
    text = '{"h":[1,2,3,4],"z":1}',
    lines_before_marker = { "{", '  "h": [', "    1,", "    2,", "    3," },
    lines_after_marker = { "  ],", '  "z": 1', "}" },
    item_indentation = "    ",
  },
  {
    text = "[[1,2,3,4],1]",
    lines_before_marker = { "[", "  [", "    1,", "    2,", "    3," },
    lines_after_marker = { "  ],", "  1", "]" },
    item_indentation = "    ",
  },
}

test("an array with one item more than the limit shows the limit's items and a marker line for the one left out", function()
  for _, record in ipairs(records_with_one_item_more_than_the_limit) do
    assert_formats_with_small_limits_leaving_one_out(record.text, record.lines_before_marker, record.item_indentation, "item", record.lines_after_marker)
  end
end)

test("no marker states that zero items were left out", function()
  ---@type string[]
  local texts = { "[1,2,3]" }
  for _, record in ipairs(records_with_arrays_of_exactly_the_limit) do
    texts[#texts + 1] = record.text
  end
  for _, record in ipairs(records_with_one_item_more_than_the_limit) do
    texts[#texts + 1] = record.text
  end
  vim.list_extend(texts, records_with_short_arrays)
  assert_no_marker_states_zero_left_out(texts)
end)

--- Records holding a string of exactly as many characters as the small
--- limits allow as a member's value, as an item of an array and as a key,
--- each with the lines it formats to, as without limits.
---@type { text: string, expected: string[] }[]
local records_with_strings_of_exactly_the_limit = {
  { text = '{"t":"0123456789"}', expected = { "{", '  "t": "0123456789"', "}" } },
  { text = '{"t":"0123456789","z":1}', expected = { "{", '  "t": "0123456789",', '  "z": 1', "}" } },
  { text = '["0123456789"]', expected = { "[", '  "0123456789"', "]" } },
  { text = '["0123456789",2]', expected = { "[", '  "0123456789",', "  2", "]" } },
  { text = '{"0123456789":1}', expected = { "{", '  "0123456789": 1', "}" } },
  { text = '{"0123456789":1,"b":2}', expected = { "{", '  "0123456789": 1,', '  "b": 2', "}" } },
  { text = '{"0123456789":[]}', expected = { "{", '  "0123456789": []', "}" } },
  { text = '{"0123456789":"0123456789"}', expected = { "{", '  "0123456789": "0123456789"', "}" } },
  {
    text = '{"a":{"t":"0123456789","z":1},"y":2}',
    expected = { "{", '  "a": {', '    "t": "0123456789",', '    "z": 1', "  },", '  "y": 2', "}" },
  },
  { text = '[["0123456789",2],3]', expected = { "[", "  [", '    "0123456789",', "    2", "  ],", "  3", "]" } },
  { text = '{"a":{"0123456789":1}}', expected = { "{", '  "a": {', '    "0123456789": 1', "  }", "}" } },
}

test("a string that is the whole record with exactly as many characters as the limit is shown whole, with no marker", function()
  assert_formats_with_small_limits('"0123456789"', { '"0123456789"' })
end)

test("a string that is a member's value, an item of an array or a key with exactly as many characters as the limit is shown whole, with no marker", function()
  for _, record in ipairs(records_with_strings_of_exactly_the_limit) do
    assert_formats_with_small_limits(record.text, record.expected)
  end
end)

--- Records holding one string with one character more than the small limits
--- allow, as the whole record, as a member's value, as an item of an array
--- and as a key: the lines before the cut string's line, that line up to
--- the two spaces before its marker, and the lines after it.
---@type { text: string, lines_before_cut_line: string[], cut_line_start: string, lines_after_cut_line: string[] }[]
local records_with_one_character_more_than_the_limit = {
  { text = '"0123456789a"', lines_before_cut_line = {}, cut_line_start = '"0123456789"', lines_after_cut_line = {} },
  { text = '{"t":"0123456789a"}', lines_before_cut_line = { "{" }, cut_line_start = '  "t": "0123456789"', lines_after_cut_line = { "}" } },
  { text = '{"t":"0123456789a","z":1}', lines_before_cut_line = { "{" }, cut_line_start = '  "t": "0123456789",', lines_after_cut_line = { '  "z": 1', "}" } },
  { text = '["0123456789a"]', lines_before_cut_line = { "[" }, cut_line_start = '  "0123456789"', lines_after_cut_line = { "]" } },
  { text = '["0123456789a",2]', lines_before_cut_line = { "[" }, cut_line_start = '  "0123456789",', lines_after_cut_line = { "  2", "]" } },
  { text = '{"0123456789a":1}', lines_before_cut_line = { "{" }, cut_line_start = '  "0123456789": 1', lines_after_cut_line = { "}" } },
  { text = '{"0123456789a":1,"b":2}', lines_before_cut_line = { "{" }, cut_line_start = '  "0123456789": 1,', lines_after_cut_line = { '  "b": 2', "}" } },
  {
    text = '{"a":{"t":"0123456789a","z":1},"y":2}',
    lines_before_cut_line = { "{", '  "a": {' },
    cut_line_start = '    "t": "0123456789",',
    lines_after_cut_line = { '    "z": 1', "  },", '  "y": 2', "}" },
  },
  {
    text = '[["0123456789a",2],3]',
    lines_before_cut_line = { "[", "  [" },
    cut_line_start = '    "0123456789",',
    lines_after_cut_line = { "    2", "  ],", "  3", "]" },
  },
}

test("a string with one character more than the limit, as the whole record, a member's value, an item of an array or a key, shows the limit's characters, closed with a quote, and a marker for the one left out", function()
  for _, record in ipairs(records_with_one_character_more_than_the_limit) do
    assert_formats_with_small_limits_leaving_one_out(record.text, record.lines_before_cut_line, record.cut_line_start .. "  ", "character", record.lines_after_cut_line)
  end
end)

test("no marker states that zero characters were left out", function()
  ---@type string[]
  local texts = { '"0123456789"' }
  for _, record in ipairs(records_with_strings_of_exactly_the_limit) do
    texts[#texts + 1] = record.text
  end
  for _, record in ipairs(records_with_one_character_more_than_the_limit) do
    texts[#texts + 1] = record.text
  end
  vim.list_extend(texts, records_with_short_strings)
  assert_no_marker_states_zero_left_out(texts)
end)

test("an array that is an item of a cut array is cut by its own count, its marker line indented as its own items are, and the array holding it goes on counting where it was", function()
  assert_formats_with_small_limits("[[1,2,3,4,5],[1,2],3,4]", {
    "[",
    "  [",
    "    1,",
    "    2,",
    "    3,",
    "    … 2 more items",
    "  ],",
    "  [",
    "    1,",
    "    2",
    "  ],",
    "  3,",
    "  … 1 more item",
    "]",
  })
end)

test("an array that is a member's value inside an item of an array is cut by the same rule, its marker line indented as its own items are", function()
  assert_formats_with_small_limits('[{"a":[1,2,3,4]}]', {
    "[",
    "  {",
    '    "a": [',
    "      1,",
    "      2,",
    "      3,",
    "      … 1 more item",
    "    ]",
    "  }",
    "]",
  })
end)

test("a long array that is an item, first, second or third, does not shorten the array holding it, which still shows its first three items", function()
  assert_formats_with_small_limits("[[1,2,3,4,5],2,3,4,5]", {
    "[",
    "  [",
    "    1,",
    "    2,",
    "    3,",
    "    … 2 more items",
    "  ],",
    "  2,",
    "  3,",
    "  … 2 more items",
    "]",
  })
  assert_formats_with_small_limits("[1,[1,2,3,4,5],3,4,5]", {
    "[",
    "  1,",
    "  [",
    "    1,",
    "    2,",
    "    3,",
    "    … 2 more items",
    "  ],",
    "  3,",
    "  … 2 more items",
    "]",
  })
  assert_formats_with_small_limits("[1,2,[1,2,3,4,5],4,5]", {
    "[",
    "  1,",
    "  2,",
    "  [",
    "    1,",
    "    2,",
    "    3,",
    "    … 2 more items",
    "  ],",
    "  … 2 more items",
    "]",
  })
end)

test("an array at three levels of nesting is cut by the same rule, and each array holding it is cut by its own count", function()
  assert_formats_with_small_limits("[[[1,2,3,4,5],2,3,4,5],2,3,4,5]", {
    "[",
    "  [",
    "    [",
    "      1,",
    "      2,",
    "      3,",
    "      … 2 more items",
    "    ],",
    "    2,",
    "    3,",
    "    … 2 more items",
    "  ],",
    "  2,",
    "  3,",
    "  … 2 more items",
    "]",
  })
end)

test("an object that is the whole record, with more members than the items limit, shows every member, with no marker", function()
  assert_formats_with_small_limits('{"a":1,"b":2,"c":3,"d":4,"e":5}', {
    "{",
    '  "a": 1,',
    '  "b": 2,',
    '  "c": 3,',
    '  "d": 4,',
    '  "e": 5',
    "}",
  })
end)

test("an object that is a member's value, with more members than the items limit, shows every member, with no marker", function()
  assert_formats_with_small_limits('{"o":{"a":1,"b":2,"c":3,"d":4,"e":5},"z":1}', {
    "{",
    '  "o": {',
    '    "a": 1,',
    '    "b": 2,',
    '    "c": 3,',
    '    "d": 4,',
    '    "e": 5',
    "  },",
    '  "z": 1',
    "}",
  })
end)

test("an object's members are not items of the array holding it, so an array of three items whose first is an object of four members is not cut", function()
  assert_formats_with_small_limits('[{"a":1,"b":2,"c":3,"d":4},2,3]', {
    "[",
    "  {",
    '    "a": 1,',
    '    "b": 2,',
    '    "c": 3,',
    '    "d": 4',
    "  },",
    "  2,",
    "  3",
    "]",
  })
end)

test("an object that is a shown item of a cut array, first, second or third, shows every member", function()
  assert_formats_with_small_limits('[{"a":1,"b":2,"c":3,"d":4},2,3,4,5]', {
    "[",
    "  {",
    '    "a": 1,',
    '    "b": 2,',
    '    "c": 3,',
    '    "d": 4',
    "  },",
    "  2,",
    "  3,",
    "  … 2 more items",
    "]",
  })
  assert_formats_with_small_limits('[1,{"a":1,"b":2,"c":3,"d":4},3,4,5]', {
    "[",
    "  1,",
    "  {",
    '    "a": 1,',
    '    "b": 2,',
    '    "c": 3,',
    '    "d": 4',
    "  },",
    "  3,",
    "  … 2 more items",
    "]",
  })
  assert_formats_with_small_limits('[1,2,{"a":1,"b":2,"c":3,"d":4},4,5]', {
    "[",
    "  1,",
    "  2,",
    "  {",
    '    "a": 1,',
    '    "b": 2,',
    '    "c": 3,',
    '    "d": 4',
    "  },",
    "  … 2 more items",
    "]",
  })
end)

test("no object gets a marker line, however many members it has and wherever it is", function()
  for _, text in ipairs({
    '{"a":{"o":{"a":1,"b":2,"c":3,"d":4,"e":5}}}',
    '[[{"a":1,"b":2,"c":3,"d":4}]]',
  }) do
    assert_deep_eq(positions_of_lines_holding((json_formatter.format(text, SMALL_LIMITS)), "…"), {}, vim.inspect(text) .. " with small limits, lines holding a marker:")
  end
end)

--- Records holding one cut array whose hidden items hold nesting, brackets,
--- braces or commas inside strings, escapes or whitespace, each with the
--- lines it formats to with the small limits and, when the cut array is a
--- member's value, that member's key.
---@type { text: string, member: string?, expected: string[] }[]
local records_with_hidden_items_of_every_kind = {
  {
    text = '[1,2,3,{"a":[1,2,{"b":"],[,}{"}]},"x,y]",[[],[{}]],"\\"],"]',
    expected = { "[", "  1,", "  2,", "  3,", "  … 4 more items", "]" },
  },
  {
    text = "[1, 2, 3 , 4 , [5, 6] ]",
    expected = { "[", "  1,", "  2,", "  3,", "  … 2 more items", "]" },
  },
  {
    text = "[[1],[2],[3],[4],[5],[6]]",
    expected = {
      "[",
      "  [",
      "    1",
      "  ],",
      "  [",
      "    2",
      "  ],",
      "  [",
      "    3",
      "  ],",
      "  … 3 more items",
      "]",
    },
  },
  {
    text = "[[],{},[],{},[]]",
    expected = { "[", "  [],", "  {},", "  [],", "  … 2 more items", "]" },
  },
  {
    text = '[1,2,3,"path\\\\",5,6]',
    expected = { "[", "  1,", "  2,", "  3,", "  … 3 more items", "]" },
  },
  {
    text = '{"h":[1,2,3,"]",{"x":[4]}],"z":1}',
    member = "h",
    expected = {
      "{",
      '  "h": [',
      "    1,",
      "    2,",
      "    3,",
      "    … 2 more items",
      "  ],",
      '  "z": 1',
      "}",
    },
  },
}

test("hidden items count once each in the marker, whatever they hold, and the cut array's own closing bracket and its siblings follow", function()
  for _, record in ipairs(records_with_hidden_items_of_every_kind) do
    assert_formats_with_small_limits(record.text, record.expected)
  end
end)

test("the items a cut array shows plus the count in its marker equal its items as the built-in decoder counts them", function()
  for _, record in ipairs(records_with_hidden_items_of_every_kind) do
    local label = vim.inspect(record.text) .. " with small limits"
    local lines = json_formatter.format(record.text, SMALL_LIMITS)
    local marker_positions = positions_of_lines_holding(lines, "…")
    assert_eq(#marker_positions, 1, label .. ", lines holding a marker:")
    local left_out = lines[marker_positions[1]]:match("^%s*… (%d+) more items?$")
    assert_eq(type(left_out), "string", label .. ", a count in " .. vim.inspect(lines[marker_positions[1]]) .. ":")
    ---@cast left_out -nil
    local value = vim.json.decode(record.text)
    ---@type unknown[]
    local items = record.member and value[record.member] or value
    assert_eq(SMALL_LIMITS.array_items + tonumber(left_out), #items, label .. ", items shown plus items left out:")
  end
end)

_H.finish()
