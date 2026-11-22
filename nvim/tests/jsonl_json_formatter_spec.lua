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
--     items are and holding only `… N more items` (`… 1 more item` for
--     one, point 35); then the closing bracket where it always is, with
--     its comma when a sibling follows.
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
--     `… N more characters` (`… 1 more character` for one, point 35), N
--     being the characters left out, so the characters shown and N add up
--     to the string's characters as the record writes them. A cut string
--     stays on one line. A string with fewer characters than the limit
--     (nine, one or none), whether it is the whole record, a member's
--     value, an item of an array or a key, comes out as it does without
--     limits.
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
--     items after it are still counted. The commas between the members of
--     a hidden object, like those between the items of a hidden array, at
--     any depth, are not items of the cut array, and a closing brace inside
--     a string does not close the object holding it. Whitespace between
--     hidden items changes nothing. The items shown plus the count in the
--     marker equal the array's items as the built-in decoder counts them.
--     After the marker line come the cut array's own closing bracket, with
--     its comma when a sibling follows, and the siblings, laid out as
--     usual.
-- 31. The items a cut array leaves out are only passed over, to count them
--     and find the array's end: no lines, pieces or copies of them are
--     made. With the same small limits, a record whose array hides 100,000
--     items, each an object of three members holding a nested array and a
--     long string, allocates at most 64 KB more than the same record hiding
--     one item, while formatting it whole allocates more than a thousand
--     times that bound. The two give the same lines apart from the count in
--     the marker, `… 1 more item` against `… 100,000 more items`, and
--     report as many trimmed places: a long hidden string is neither cut
--     nor copied. The heap growth is measured with the garbage collector
--     stopped and the JIT off, and the collector is restarted even when
--     what is measured raises. Only allocation is checked; no time is
--     measured.
-- 32. With the same small limits, a string's characters are those of the
--     JSON text as written: an escape counts as the characters it is
--     written with (`\n` and `\"` two, `\u00e9` six). A cut is never made
--     inside an escape: when the limit falls inside one the whole escape
--     is shown, so the shown part can exceed the limit by the rest of that
--     escape, and an escape ending exactly at the limit is shown with the
--     cut after it. The marker counts the escapes left out as written. A
--     string whose last escape, kept whole, uses up the rest of it is
--     shown whole, with no marker and no trimmed place. The shown part
--     never ends in a backslash that would escape its closing quote. Each
--     string is checked as the whole record and as a member's value, and
--     its length in bytes is counted by hand.
-- 33. With the same small limits, a character written directly in the
--     record counts as one character, however many bytes it has: two,
--     three or four. The limit and the count in the marker are both in
--     characters: a cut string shows exactly ten characters whatever their
--     bytes, a character of more bytes is shown or left out whole, and a
--     string of ten two-byte characters is shown whole, with no marker. A
--     cut never falls between the bytes of one character, so the shown
--     part is valid UTF-8. Each string is checked as the whole record and
--     as a member's value, and its length in bytes is counted by hand.
-- 34. With the same small limits, the count in a marker, of items left out
--     or of characters, is written in digits grouped in threes from the
--     right with commas: `… 999 more items`, `… 1,000 more items`,
--     `… 1,001 more items`, `… 1,000,000 more items`,
--     `… 12,345,678 more items` and `… 37,907 more characters`. A count
--     below a thousand has no comma, and one whose digits are a multiple
--     of three (`100`, `100,000`) starts with none, in either kind of
--     marker. The large arrays are built of single-digit items, and a
--     failure names the count, not the record.
-- 35. With the same small limits, a marker reads as a sentence: a count
--     of exactly one takes the singular, `… 1 more item` for one item left
--     out and `… 1 more character` for one character, in every place an
--     array or a string is cut. Every other count takes the plural:
--     `… 2 more items`, `… 2 more characters`, and `… 1,001 more items`
--     and `… 1,001 more characters`, whose last digit is a one.
-- 36. Besides its lines, which stay the first thing it returns, the
--     formatter returns the trimmed places of the whole record as a plain
--     whole number: one for each cut array and one for each cut string,
--     keys included, so with the same small limits `[1,2,3,4,5]` reports
--     1, and `[[1,2,3,4,5],[1,2],3,4]` and
--     `["a","b","0123456789abcdef","d","e"]` report 2. A long string or
--     a long array among the hidden items was never cut and is not
--     counted: `[1,2,3,"0123456789abcdef",[1,2,3,4,5]]` reports 1. The
--     count always equals the markers in the lines, three and four places
--     included, each marker counted by its `…`, in records whose strings
--     hold none. A record with nothing long reports 0 with the small
--     limits, any record reports 0 without limits, and a blank record
--     reports 0 and no lines with either.
-- 37. With the same small limits, a surrogate pair written as two `\u`
--     escapes in a row, a high surrogate (`\ud800` to `\udbff`) directly
--     followed by a low one (`\udc00` to `\udfff`), is one escape of
--     twelve characters, its hexadecimal digits in upper or lower case: a
--     cut never falls between its two escapes, whether the limit falls
--     inside either half or exactly between them, and a pair that reaches
--     the end of the string leaves nothing out, so the string is shown
--     whole, with no marker and no trimmed place. A high surrogate not
--     directly followed by a low one is an ordinary escape of six, even
--     with a pair later in the string, and so is each of two escapes in a
--     row that are not a pair. The shown part is never more than eleven
--     characters longer than the limit, and the shown part and the
--     marker's count add up to the whole string. Each string is checked as
--     the whole record and as a member's value, and its length in bytes is
--     counted by hand.
-- 38. A marker cannot be taken for data: every marker begins with `…` and
--     one space, and in the lines the formatter returns `…` stands outside
--     a string only as the start of a marker; a `…` the record holds is
--     inside a string and stays data. Strings are told apart in a line as
--     point 14 says, and the case that tells them apart is checked first
--     on lines written here. With the same small limits, for point 18's
--     records, the records of point 36 cut in several places, and records
--     whose strings hold `…` (shown, in a key, in a cut string before and
--     after the cut, among the hidden items, reading like a marker, next to
--     an escaped quote or backslash), the `…` outside strings are as many
--     as the trimmed places, each followed by one space and a digit; a `…`
--     a string holds is kept inside a string when shown and is in no line
--     when cut off or hidden; an array's marker line begins, after its
--     indentation, with `…`, and every line that begins with `…` is one;
--     and a trimmed record's lines, joined with line feeds, are rejected
--     by the built-in decoder: where something was cut, the lines are no
--     longer JSON. Without limits, no line of the same records has `…`
--     outside a string. `["a…b","…",3,4]` is compared with its exact
--     lines.
-- 39. There is one rule and no size at which trimming switches on, so a
--     record with nothing long is never altered. With the same small
--     limits, a record whose every array and string, keys included, is
--     within the limits gives exactly the lines it gives without limits
--     and reports no trimmed places: records of every shape (deep nesting,
--     empty objects and arrays, objects with more members than the items
--     limit, escapes, multi-byte characters, every kind of number, true,
--     false and null, records that are not objects), and records with an
--     array of exactly the items limit or a string of exactly the
--     characters limit. With limits far larger than any of its records,
--     which each record's length in bytes shows, point 18's varied set
--     formats to its lines without limits and reports no trimmed places.
--     A blank record gives no lines either way (point 36).
-- 40. Without limits nothing is cut, however long: limits apply only
--     when the caller passes them, and the formatter never falls back to
--     the default limits. Without limits, an array of 10,000 items that
--     is the whole record gives its 10,002 lines, one per item and its two
--     brackets, none of them a marker, and reports no trimmed places; a
--     string of 50,000 characters that is the whole record gives one line
--     holding all of it, and no trimmed places; and a record with an array
--     of one item more than the default items limit and a string of one
--     character more than the default characters limit gives lines that,
--     joined with line feeds, the built-in decoder accepts and decodes to
--     the same value as the record. Passing no limits and passing nil give
--     the same lines and the same trimmed places, for those records and
--     for short ones. The array of 10,000 items and the string of 50,000
--     characters are named in a failure, never printed: every line is
--     compared, and a failure shows only how many lines each side has,
--     which line is the first that differs, and about 60 bytes of each
--     version of it, around the first byte that differs.
-- 41. The formatter owns one default set of limits, exposed by name: 20
--     items per array and 2,000 characters per string. One case holds
--     those numbers: it checks the value as a constant, then passes it as
--     it is on the PRD's own figures, an array of 9,999 items that shows
--     its first 20 and a marker line for 9,979 left out, and a string of
--     39,907 characters that shows its first 2,000 and a marker for
--     37,907 left out, one trimmed place each. Passed as it is, the value
--     leaves an array of exactly its items and a string of exactly its
--     characters as they are without limits, with no trimmed places, and
--     formatting leaves it holding the numbers it held when the spec
--     loaded it, through every case that passes it. Every other case
--     passes its own limits or none, so changing a default means updating
--     that one case: the cases of this point that do not hold the numbers,
--     and point 40's record longer than the default limits, are built
--     from the value and follow it. Their long records are named in a
--     failure and compared as point 40's are, never printed.
-- 42. Point 17's guarantee holds with limits too, on the paths trimming
--     adds: passing over hidden items and choosing where to cut a string.
--     With the small limits, every text of point 17 returns a list of
--     strings and a count of trimmed places that is a number, without
--     raising and without looping, and none of the strings holds a line
--     feed or a carriage return. So do texts that break inside those
--     paths: an array longer than the limit that never closes, ends in a
--     comma, has a comma before its bracket or a closer of the wrong kind
--     among its hidden items; a string longer than the limit that never
--     closes, whose cut meets a backslash or a `\u` escape cut off by the
--     end of the text, with a `\u` escape of too few digits before its
--     closing quote, or with bytes that are not UTF-8 at the cut; and a
--     raw line break inside a hidden item, between hidden items, and in
--     the shown or the hidden part of a cut string. Point 17's own cases
--     check the count's type as well, and give the formatter the text
--     alone, with no second argument.
-- 43. Trimming works by path inside a worker thread, the one call the
--     record preview makes. Loaded by path in a worker thread, where
--     `require` can load no module of this config, the formatter formats
--     point 40's record longer than the default limits with the default
--     limits read from the formatter loaded there, and hands back plain
--     data, a list of strings and a number of trimmed places, equal to
--     what the same call gives on the main thread. Loaded by path where
--     the editor's global `vim` is absent, it trims the same record to the
--     same lines and trimmed places. A worker thread that raises or never
--     finishes is a failure of the case within point 19's time limit,
--     never a hang.
--
-- The formatter is given JSON text and its lines are checked as text; no
-- config is loaded. Only points 18, 30, 38, 39 and 40 decode a record,
-- with `vim.json.decode`: point 18 to catch what no expected lines thought
-- of, point 30 to count a cut array's items, point 38 to check that its own
-- records are JSON and that a trimmed record's lines are not, point 39 to
-- check that its own records are JSON, point 40 to check that a record
-- longer than the default limits comes out whole; decoding cannot see key
-- order or how a number is written, which point 15 checks on the text, nor
-- how a string is written, which point 16 checks. For text that is not
-- valid JSON the lines are not compared with any expected lines: only the
-- checks of points 17 and 42 are made. With limits, the lines are
-- compared with expected lines or with the lines the same text gives
-- without limits, or with the lines of the same record hiding fewer items
-- (point 31), or searched for `…` outside strings (point 38). The count of
-- trimmed places is checked against an expected number and against the
-- markers in the lines (points 25, 32, 36, 37, 38, 39, 40 and 41) and
-- against the same call on the main thread (point 43); besides, one case
-- checks that hidden items add nothing to it.
--
-- Run with: nvim --headless -u NONE -l tests/jsonl_json_formatter_spec.lua

---@type SpecHelper
local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_deep_eq, assert_nil, assert_match = _H.test, _H.assert_eq, _H.assert_deep_eq, _H.assert_nil, _H.assert_match

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local json_formatter = require("andrew.jsonl.json_formatter")

--- The default limits as the module holds them when the spec loads it,
--- before any case has formatted with them (point 41).
local default_limits_as_loaded = vim.deepcopy(json_formatter.DEFAULT_LIMITS)

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

--- Asserts that `value` is `bytes` long as written in this file. The length
--- is counted by hand, so a Lua escape or an editor that changed the text is
--- caught before the formatter is asked anything.
---@param value string a string as written in JSON text
---@param bytes integer the length of `value` in bytes, counted by hand
local function assert_bytes_as_written(value, bytes)
  assert_eq(#value, bytes, vim.inspect(value) .. ", bytes as written:")
end

--- Asserts that the string `value` is `byte_length` bytes long as written in
--- the record and in the lines, and that it comes out with exactly its bytes
--- as the whole record, as a member's value, as an item of an array and as a
--- key; a failure names the text it was given.
---@param value string a string as written in JSON text
---@param byte_length integer the bytes of `value`, counted by hand
local function assert_string_kept_byte_for_byte(value, byte_length)
  assert_bytes_as_written(value, byte_length)
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

--- Asserts that formatting `text` with `limits` returns, without raising and
--- without looping, a list of strings none of which holds a line feed or a
--- carriage return, and a count of trimmed places that is a number. A
--- failure names the text and whether the small limits were given.
---@param text string text that is not valid JSON
---@param limits JsonTrimLimits? `SMALL_LIMITS`, or nil to give the text alone
local function assert_formats_to_lines_without_line_breaks(text, limits)
  local label = vim.inspect(text) .. (limits and " with small limits" or "")
  -- A count hook is not called inside compiled code, so the JIT is off while
  -- the hook turns a loop into an error, and the code earlier cases compiled
  -- is flushed: turning the JIT off does not stop that code from running.
  jit.off()
  jit.flush()
  debug.sethook(function()
    error(("still running after %d instructions"):format(INSTRUCTIONS_BEFORE_LOOPING))
  end, "", INSTRUCTIONS_BEFORE_LOOPING)
  -- Without limits the formatter is given the text alone, as point 17 has
  -- it: passing nil is a call of its own (point 40).
  ---@type boolean, any, any
  local ok, lines, trimmed_places
  if limits then
    ok, lines, trimmed_places = pcall(json_formatter.format, text, limits)
  else
    ok, lines, trimmed_places = pcall(json_formatter.format, text)
  end
  debug.sethook()
  jit.on()
  assert_eq(ok, true, label .. " raised: " .. tostring(lines))
  assert_list_of_strings(lines, "the result for " .. label)
  for position, line in ipairs(lines) do
    assert_nil(line:find("[\r\n]"), ("%s line %d holds a line break:"):format(label, position))
  end
  assert_eq(type(trimmed_places), "number", label .. ", the type of the trimmed places:")
end

--- Text that is not valid JSON: closers with nothing open, a record cut off
--- after a colon or inside a string, plain words, a lone backslash at the end
--- of a string, a comma or a colon alone.
---@type string[]
local texts_that_are_not_json = {
  "}}}",
  '{"a":',
  '{"a":"never closes',
  "only plain words and not JSON",
  '{"a":"ends in a lone backslash \\',
  ",",
  ":",
}

test("text that is not valid JSON returns a list of lines without raising or looping", function()
  for _, text in ipairs(texts_that_are_not_json) do
    assert_formats_to_lines_without_line_breaks(text)
  end
end)

--- Texts with a raw line feed, carriage return or both inside a string.
---@type string[]
local texts_with_a_raw_line_break_inside_a_string = {
  '{"a":"one\ntwo"}',
  '{"a":"one\ntwo\nthree"}',
  '{"a":"one\r\ntwo"}',
  '{"a":"one\rtwo"}',
  '"one\ntwo"',
  '{"o\nne":1}',
  '{"a":"never\ncloses',
}

test("a raw line break inside a string gives lines none of which holds a line break", function()
  for _, text in ipairs(texts_with_a_raw_line_break_inside_a_string) do
    assert_formats_to_lines_without_line_breaks(text)
  end
end)

--- Texts with a raw line break between words that are not JSON.
---@type string[]
local texts_with_a_raw_line_break_between_words = { "plain\nwords", "plain\r\nwords", '{"a":tr\nue}' }

test("a raw line break between words that are not JSON gives no line holding a line break", function()
  for _, text in ipairs(texts_with_a_raw_line_break_between_words) do
    assert_formats_to_lines_without_line_breaks(text)
  end
end)

--- Texts closing braces and brackets with nothing open.
---@type string[]
local texts_closing_what_is_not_open = { "]]]", "}]", '}]{"a":[1]}' }

test("closing braces and brackets with nothing open do not raise", function()
  for _, text in ipairs(texts_closing_what_is_not_open) do
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

--- Asserts that the built-in decoder accepts `text`, one of this spec's
--- records, and returns the value it decodes to. Checked before what is
--- asserted of the formatter, so a record this spec wrote wrongly is not
--- taken for one the formatter broke.
---@param text string the JSON text of one record
---@return any value
local function assert_record_decodes(text)
  local record_decodes, record_value = pcall(vim.json.decode, text)
  assert_eq(record_decodes, true, vim.inspect(text) .. " is not JSON the decoder accepts: " .. tostring(record_value))
  return record_value
end

--- Asserts that `text`, one of this spec's records, formatted without
--- limits gives lines that, joined with line feeds, the built-in decoder
--- accepts and decodes to the same value as the record; a failure names
--- the record `record_name`.
---@param text string the JSON text of one record
---@param record_name string names the record in a failure
local function assert_lines_decode_to_the_record(text, record_name)
  local record_value = assert_record_decodes(text)
  -- No limits: it is the untrimmed lines that must decode.
  local lines = json_formatter.format(text)
  local lines_decode, lines_value = pcall(vim.json.decode, table.concat(lines, "\n"))
  assert_eq(lines_decode, true, record_name .. " formats to lines that do not decode: " .. tostring(lines_value))
  assert_deep_eq(lines_value, record_value, record_name .. " formats to lines that decode to another value:")
end

test("the lines of every record in a varied set, joined with line feeds, decode to the same value as the record", function()
  for _, text in ipairs(varied_records) do
    assert_lines_decode_to_the_record(text, vim.inspect(text))
  end
end)

--- The formatter's own file, as the record preview's worker thread loads it.
local json_formatter_path = vim.fn.stdpath("config") .. "/lua/andrew/jsonl/json_formatter.lua"
--- How long a case waits for a worker thread's result before it fails.
local WORKER_RESULT_LIMIT_MS = 5000

--- Runs in a worker thread (`vim.uv.new_work`), in a Lua state of its own
--- that sees none of this file's locals, so all it needs comes as arguments.
--- Loads the formatter by path, with nothing `require` could load, and
--- formats `text`: with the text alone, or, when `with_default_limits` is
--- true, with the default limits read from the formatter loaded there.
--- Returns true, the lines packed with `vim.mpack` (a worker thread hands
--- back strings, numbers and booleans, not tables) and the trimmed places,
--- or false and the error. A loop becomes an error as in point 17: a worker
--- thread that never ends would keep the process from exiting.
---@param module_path string
---@param text string
---@param instruction_limit integer
---@param with_default_limits boolean?
---@return boolean is_formatted
---@return string packed_lines_or_error
---@return integer? trimmed_places
local function format_in_worker_thread(module_path, text, instruction_limit, with_default_limits)
  -- The worker thread's runtime path loader would find this config's modules.
  package.loaders = {}
  jit.off()
  jit.flush()
  debug.sethook(function()
    error(("still running after %d instructions"):format(instruction_limit))
  end, "", instruction_limit)
  local is_formatted, packed_lines_or_error, trimmed_places = pcall(function()
    ---@module "andrew.jsonl.json_formatter"
    local formatter = dofile(module_path)
    if not with_default_limits then
      return vim.mpack.encode((formatter.format(text)))
    end
    local lines, places = formatter.format(text, formatter.DEFAULT_LIMITS)
    return vim.mpack.encode(lines), places
  end)
  debug.sethook()
  return is_formatted, tostring(packed_lines_or_error), trimmed_places
end

--- Formats `text` in a worker thread with `format_in_worker_thread` and
--- waits for its result, at most `WORKER_RESULT_LIMIT_MS`. Asserts that the
--- result came in time and that the worker thread did not fail, and returns
--- the lines unpacked, checked to be a list of strings, and the trimmed
--- places as they came back.
---@param text string
---@param with_default_limits boolean? true to format with the default limits, else with the text alone
---@return string[] lines
---@return any trimmed_places
local function result_from_worker_thread(text, with_default_limits)
  ---@type { is_formatted: boolean?, packed_lines_or_error: string?, trimmed_places: any }?
  local worker_result = nil
  vim.uv
    .new_work(
      format_in_worker_thread,
      ---@param is_formatted boolean?
      ---@param packed_lines_or_error string?
      ---@param trimmed_places any
      function(is_formatted, packed_lines_or_error, trimmed_places)
        worker_result = { is_formatted = is_formatted, packed_lines_or_error = packed_lines_or_error, trimmed_places = trimmed_places }
      end
    )
    :queue(json_formatter_path, text, INSTRUCTIONS_BEFORE_LOOPING, with_default_limits)
  local has_answered = vim.wait(WORKER_RESULT_LIMIT_MS, function()
    return worker_result ~= nil
  end, 10)
  assert_eq(has_answered, true, ("no result from the worker thread within %d ms:"):format(WORKER_RESULT_LIMIT_MS))
  ---@cast worker_result -nil
  assert_eq(worker_result.is_formatted, true, "the worker thread failed: " .. tostring(worker_result.packed_lines_or_error))
  local lines = vim.mpack.decode(worker_result.packed_lines_or_error --[[@as string]])
  assert_list_of_strings(lines, "the worker thread's result")
  ---@cast lines string[]
  return lines, worker_result.trimmed_places
end

test("the formatter loaded by path in a worker thread hands back, as a list of strings, the lines it gives a nested record on the main thread", function()
  local lines = result_from_worker_thread(compact_record)
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
--- `expected`; a failure names the text it was given, or `record_name` for
--- a record too long to print.
---@param text string the JSON text of one record
---@param expected string[] the lines the formatter must return
---@param record_name? string names the record in a failure instead of its text
local function assert_formats_with_small_limits(text, expected, record_name)
  assert_deep_eq(json_formatter.format(text, SMALL_LIMITS), expected, (record_name or vim.inspect(text)) .. " with small limits:")
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

--- The JSON texts of `records`, in order.
---@param records { text: string }[]
---@return string[] texts
local function texts_of(records)
  ---@type string[]
  local texts = {}
  for _, record in ipairs(records) do
    texts[#texts + 1] = record.text
  end
  return texts
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

--- Asserts that `text` formatted with `limits` reports `expected` trimmed
--- places, as a plain whole number, and that its lines hold exactly as many
--- markers, each counted by its `…`; a failure names the text and whether
--- the small limits were given. Only for records whose strings hold no `…`.
---@param text string the JSON text of one record
---@param limits JsonTrimLimits? `SMALL_LIMITS`, or nil to show everything
---@param expected integer the trimmed places the record must report
local function assert_reports_trimmed_places(text, limits, expected)
  local label = vim.inspect(text) .. (limits and " with small limits" or " without limits")
  local lines, trimmed_places = json_formatter.format(text, limits)
  assert_eq(type(trimmed_places), "number", label .. ", the type of the trimmed places:")
  assert_eq(trimmed_places, expected, label .. ", trimmed places:")
  local markers = 0
  for _, line in ipairs(lines) do
    local _, markers_on_line = line:gsub("…", "")
    markers = markers + markers_on_line
  end
  assert_eq(markers, trimmed_places, label .. ", markers in the lines against the trimmed places:")
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

--- The shown part, without its quotes, and the count in the marker on
--- `cut.line`, the line of a cut string; asserts that the line is a shown
--- part and a marker.
---@param cut { label: string, line: string }
---@return string shown
---@return string left_out the count as written
local function shown_part_and_left_out(cut)
  ---@type string?, string?
  local shown, left_out = cut.line:match('^"(.*)"  … (%d+) more characters$')
  assert_eq(type(shown), "string", cut.label .. ", a shown part and a marker in " .. vim.inspect(cut.line) .. ":")
  ---@cast shown -nil
  ---@cast left_out -nil
  return shown, left_out
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
      local shown, left_out = shown_part_and_left_out(cut)
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
  assert_formats_with_small_limits('[1,2,3,"0123456789abcdef"]', { "[", "  1,", "  2,", "  3,", "  … 1 more item", "]" })
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
  assert_reports_trimmed_places('{"0123456789abcdef":"0123456789XYZ","b":2}', SMALL_LIMITS, 2)
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
--- as the whole record, as a member's value and as an item of another array,
--- each with the lines it formats to: the limit's items, then a marker line
--- for the one left out, indented as those items are.
---@type { text: string, expected: string[] }[]
local records_with_one_item_more_than_the_limit = {
  { text = "[1,2,3,4]", expected = { "[", "  1,", "  2,", "  3,", "  … 1 more item", "]" } },
  {
    text = '{"h":[1,2,3,4],"z":1}',
    expected = { "{", '  "h": [', "    1,", "    2,", "    3,", "    … 1 more item", "  ],", '  "z": 1', "}" },
  },
  { text = "[[1,2,3,4],1]", expected = { "[", "  [", "    1,", "    2,", "    3,", "    … 1 more item", "  ],", "  1", "]" } },
}

test("an array with one item more than the limit shows the limit's items and a marker line for the one left out", function()
  for _, record in ipairs(records_with_one_item_more_than_the_limit) do
    assert_formats_with_small_limits(record.text, record.expected)
  end
end)

test("no marker states that zero items were left out", function()
  ---@type string[]
  local texts = { "[1,2,3]" }
  vim.list_extend(texts, texts_of(records_with_arrays_of_exactly_the_limit))
  vim.list_extend(texts, texts_of(records_with_one_item_more_than_the_limit))
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
--- and as a key, each with the lines it formats to: the cut string's line
--- ends in two spaces and a marker for the one character left out.
---@type { text: string, expected: string[] }[]
local records_with_one_character_more_than_the_limit = {
  { text = '"0123456789a"', expected = { '"0123456789"  … 1 more character' } },
  { text = '{"t":"0123456789a"}', expected = { "{", '  "t": "0123456789"  … 1 more character', "}" } },
  { text = '{"t":"0123456789a","z":1}', expected = { "{", '  "t": "0123456789",  … 1 more character', '  "z": 1', "}" } },
  { text = '["0123456789a"]', expected = { "[", '  "0123456789"  … 1 more character', "]" } },
  { text = '["0123456789a",2]', expected = { "[", '  "0123456789",  … 1 more character', "  2", "]" } },
  { text = '{"0123456789a":1}', expected = { "{", '  "0123456789": 1  … 1 more character', "}" } },
  { text = '{"0123456789a":1,"b":2}', expected = { "{", '  "0123456789": 1,  … 1 more character', '  "b": 2', "}" } },
  {
    text = '{"a":{"t":"0123456789a","z":1},"y":2}',
    expected = { "{", '  "a": {', '    "t": "0123456789",  … 1 more character', '    "z": 1', "  },", '  "y": 2', "}" },
  },
  {
    text = '[["0123456789a",2],3]',
    expected = { "[", "  [", '    "0123456789",  … 1 more character', "    2", "  ],", "  3", "]" },
  },
}

test("a string with one character more than the limit, as the whole record, a member's value, an item of an array or a key, shows the limit's characters, closed with a quote, and a marker for the one left out", function()
  for _, record in ipairs(records_with_one_character_more_than_the_limit) do
    assert_formats_with_small_limits(record.text, record.expected)
  end
end)

test("no marker states that zero characters were left out", function()
  ---@type string[]
  local texts = { '"0123456789"' }
  vim.list_extend(texts, texts_of(records_with_strings_of_exactly_the_limit))
  vim.list_extend(texts, texts_of(records_with_one_character_more_than_the_limit))
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

--- Records holding one cut array whose hidden items hold nesting, objects of
--- several members, brackets, braces or commas inside strings, escapes or
--- whitespace, each with the lines it formats to with the small limits and,
--- when the cut array is a member's value, that member's key.
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
  {
    text = '[1,2,3,{"a":1,"b":2},5]',
    expected = { "[", "  1,", "  2,", "  3,", "  … 2 more items", "]" },
  },
  {
    text = '[1,2,3,[{"a":"}","b":2}],5]',
    expected = { "[", "  1,", "  2,", "  3,", "  … 2 more items", "]" },
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

--- Runs `action` with the garbage collector stopped and returns how much the
--- heap grew meanwhile; the collector is restarted before returning, whether
--- or not `action` raised. It asserts nothing itself, since an assert raises
--- and would leave the collector stopped. Compiled code can drop a string it
--- never uses, so the JIT is off while measuring, and the code earlier cases
--- compiled is flushed.
---@param action fun()
---@return boolean has_returned
---@return string error_text `tostring` of what `action` raised ("nil" when it returned)
---@return number heap_growth_kilobytes
local function heap_growth_while(action)
  jit.off()
  jit.flush()
  collectgarbage("collect")
  collectgarbage("stop")
  local heap_before = collectgarbage("count")
  local has_returned, error_value = pcall(action)
  local heap_after = collectgarbage("count")
  collectgarbage("restart") -- finally: always restart
  jit.on()
  return has_returned, tostring(error_value), heap_after - heap_before
end

--- Whether the garbage collector is running. lua_ls's LuaJIT runtime lacks
--- "isrunning", which LuaJIT 2.1 has.
---@return boolean
local function is_collector_running()
  ---@diagnostic disable-next-line: param-type-mismatch
  return collectgarbage("isrunning") --[[@as boolean]]
end

test("the measure of heap growth stops the collector while it measures, sees what is allocated and restarts the collector when what it measures raises", function()
  ---@type boolean?
  local was_collector_running = nil
  local has_returned, _, heap_growth_kilobytes = heap_growth_while(function()
    was_collector_running = is_collector_running()
    local _ = ("x"):rep(512 * 1024)
    error("raised on purpose")
  end)
  assert_eq(has_returned, false, "the measured function raised:")
  assert_eq(was_collector_running, false, "the collector was running while measuring:")
  assert_eq(heap_growth_kilobytes >= 512, true, "the heap grew by at least the 512 KB allocated: " .. heap_growth_kilobytes .. " KB;")
  assert_eq(is_collector_running(), true, "the collector is running again:")
end)

--- Formats `text` while the heap growth is measured, asserts that the
--- formatter returned, and returns the growth; what the formatter allocates
--- counts whether or not its lines are kept.
---@param text string the JSON text of one record
---@param limits JsonTrimLimits? nil shows everything
---@param label string names the record and its limits in a failure
---@return number heap_growth_kilobytes
local function heap_growth_formatting(text, limits, label)
  local has_returned, error_text, heap_growth_kilobytes = heap_growth_while(function()
    json_formatter.format(text, limits)
  end)
  assert_eq(has_returned, true, label .. " raised: " .. error_text)
  return heap_growth_kilobytes
end

--- How many items the large record of point 31 hides, and the most its
--- formatting with limits may allocate beyond the record hiding one item.
--- Measured: 0.2 to 0.3 KB more for 100,000 hidden items, against about
--- 127,000 KB to format that record whole.
local MANY_HIDDEN_ITEMS = 100000
local HEAP_GROWTH_BOUND_KILOBYTES = 64

--- An array of objects that, with the small limits, shows its first items
--- and hides `hidden_items` more. Each item has a realistic shape: an object
--- of three members, one a nested array and one a long string holding
--- brackets and braces. The string starts with the item's position, so its
--- first characters differ from item to item and a cut or a copy of it is a
--- new string, not one already interned.
---@param hidden_items integer
---@return string record the record as JSON text
local function record_hiding(hidden_items)
  ---@type string[]
  local items = {}
  for position = 1, SMALL_LIMITS.array_items + hidden_items do
    items[position] = '{"id":' .. position .. ',"tags":["a","b"],"text":"' .. position .. ' is a long [string], {x}"}'
  end
  return "[" .. table.concat(items, ",") .. "]"
end

local record_hiding_one_item = record_hiding(1)
local record_hiding_many_items = record_hiding(MANY_HIDDEN_ITEMS)

test("formatting with limits a record whose array hides 100,000 items allocates at most 64 KB more than the same record hiding one item, far less than formatting it whole", function()
  local one_growth = heap_growth_formatting(record_hiding_one_item, SMALL_LIMITS, "the record hiding one item with small limits")
  local many_growth = heap_growth_formatting(record_hiding_many_items, SMALL_LIMITS, "the record hiding 100,000 items with small limits")
  local whole_growth = heap_growth_formatting(record_hiding_many_items, nil, "the record hiding 100,000 items without limits")
  assert_eq(
    many_growth - one_growth <= HEAP_GROWTH_BOUND_KILOBYTES,
    true,
    "heap growth with small limits, 100,000 hidden items against one: " .. many_growth .. " KB against " .. one_growth .. " KB;"
  )
  assert_eq(
    whole_growth >= 1000 * HEAP_GROWTH_BOUND_KILOBYTES,
    true,
    "heap growth formatting the record hiding 100,000 items whole is far above the bound: " .. whole_growth .. " KB;"
  )
end)

test("a record whose array hides 100,000 objects gives with limits the same lines as the same record hiding one, apart from the count in the marker", function()
  local one_lines = json_formatter.format(record_hiding_one_item, SMALL_LIMITS)
  assert_eq(one_lines[#one_lines - 1], "  … 1 more item", "the record hiding one item with small limits, the marker line:")
  local expected = vim.deepcopy(one_lines)
  expected[#expected - 1] = "  … 100,000 more items"
  assert_formats_with_small_limits(record_hiding_many_items, expected, "the record hiding " .. MANY_HIDDEN_ITEMS .. " items")
end)

test("long strings among the hidden items add nothing to the trimmed places", function()
  local _, one_trimmed_places = json_formatter.format(record_hiding_one_item, SMALL_LIMITS)
  local _, many_trimmed_places = json_formatter.format(record_hiding_many_items, SMALL_LIMITS)
  assert_eq(many_trimmed_places, one_trimmed_places, "trimmed places with small limits, 100,000 hidden items against one:")
end)

--- Asserts that the string `value`, `bytes` long as written, formats with
--- the small limits to the one line `expected` as the whole record, and to
--- `expected` after its key as a member's value.
---@param value string a string as written in JSON text
---@param bytes integer the length of `value` in bytes, counted by hand
---@param expected string the line `value` gives as the whole record
local function assert_string_formats_with_small_limits(value, bytes, expected)
  assert_bytes_as_written(value, bytes)
  assert_formats_with_small_limits(value, { expected })
  assert_formats_with_small_limits('{"t":' .. value .. "}", { "{", '  "t": ' .. expected, "}" })
end

--- Asserts that the string `value`, `bytes` long as written, is shown whole
--- with the small limits, with no marker and no trimmed place, as the whole
--- record and as a member's value.
---@param value string a string as written in JSON text
---@param bytes integer the length of `value` in bytes, counted by hand
local function assert_string_shown_whole_with_small_limits(value, bytes)
  assert_string_formats_with_small_limits(value, bytes, value)
  assert_reports_trimmed_places(value, SMALL_LIMITS, 0)
  assert_reports_trimmed_places('{"t":' .. value .. "}", SMALL_LIMITS, 0)
end

test("a cut that falls inside an escape shows the whole escape, a \\n, a \\u escape or an escaped quote, then the closing quote and the marker", function()
  assert_string_formats_with_small_limits('"012345678\\nabc"', 16, '"012345678\\n"  … 3 more characters')
  assert_string_formats_with_small_limits('"012345678\\u00e9abc"', 20, '"012345678\\u00e9"  … 3 more characters')
  assert_string_formats_with_small_limits('"012345678\\"abc"', 16, '"012345678\\""  … 3 more characters')
end)

test("an escape that ends exactly at the characters limit is shown whole and the cut follows it", function()
  assert_string_formats_with_small_limits('"01234567\\nabc"', 15, '"01234567\\n"  … 3 more characters')
end)

test("escapes left out are counted in the marker as the characters they are written with", function()
  assert_string_formats_with_small_limits('"0123456789\\n\\u00e9x"', 21, '"0123456789"  … 9 more characters')
end)

test("a string whose last escape, kept whole, uses up the rest of it is shown whole, with no marker and no trimmed place", function()
  assert_string_shown_whole_with_small_limits('"012345678\\\\"', 13)
  assert_string_shown_whole_with_small_limits('"012345678\\u00e9"', 17)
end)

test("the shown part of a cut string never ends in a backslash that would escape its closing quote", function()
  ---@type { text: string, bytes: integer }[]
  local strings_cut_near_an_escaped_backslash = {
    { text = '"012345678\\\\abc"', bytes = 16 },
    { text = '"01234567\\\\\\\\abc"', bytes = 17 },
    { text = '"' .. ("\\\\"):rep(6) .. '"', bytes = 14 },
    { text = '"0' .. ("\\\\"):rep(6) .. '"', bytes = 15 },
    { text = '"012345678\\\\\\"abc"', bytes = 18 },
  }
  for _, value in ipairs(strings_cut_near_an_escaped_backslash) do
    assert_bytes_as_written(value.text, value.bytes)
    for _, cut in ipairs(lines_of_cut_string(value.text)) do
      local shown = shown_part_and_left_out(cut)
      assert_eq(#shown:match("\\*$") % 2, 0, cut.label .. ", backslashes ending the shown part:")
    end
  end
end)

test("a cut that falls on a multi-byte character shows the whole character, then the closing quote and the marker", function()
  assert_string_formats_with_small_limits('"012345678éabc"', 16, '"012345678é"  … 3 more characters')
  assert_string_formats_with_small_limits('"012345678✓abc"', 17, '"012345678✓"  … 3 more characters')
  assert_string_formats_with_small_limits('"012345678😀abc😀"', 22, '"012345678😀"  … 4 more characters')
end)

test("multi-byte characters before the cut count one character each, so ten characters are shown in thirteen bytes", function()
  assert_string_formats_with_small_limits('"0123éé789éabc"', 18, '"0123éé789é"  … 3 more characters')
end)

test("multi-byte characters left out are counted in the marker one character each, not one per byte", function()
  assert_string_formats_with_small_limits('"0123456789ééé"', 18, '"0123456789"  … 3 more characters')
end)

test("a string of ten two-byte characters, exactly the characters limit, is shown whole, with no marker", function()
  assert_string_formats_with_small_limits('"éééééééééé"', 22, '"éééééééééé"')
end)

--- Whether `text` is valid UTF-8: every character is a lead byte followed
--- by as many continuation bytes as it announces, and nothing else.
---@param text string
---@return boolean
local function is_valid_utf8(text)
  local position = 1
  while position <= #text do
    local lead = text:byte(position)
    local width = lead < 0x80 and 1 or lead < 0xC2 and 0 or lead < 0xE0 and 2 or lead < 0xF0 and 3 or lead < 0xF5 and 4 or 0
    if width == 0 then
      return false
    end
    for continuation_at = position + 1, position + width - 1 do
      local byte = text:byte(continuation_at)
      if not byte or byte < 0x80 or byte > 0xBF then
        return false
      end
    end
    position = position + width
  end
  return true
end

test("the shown part of a cut string holding multi-byte characters is valid UTF-8 and exactly the limit's characters", function()
  ---@type { text: string, bytes: integer }[]
  local strings_with_multi_byte_characters = {
    { text = '"012345678漢abc"', bytes = 17 },
    { text = '"' .. ("é"):rep(12) .. '"', bytes = 26 },
    { text = '"' .. ("漢"):rep(12) .. '"', bytes = 38 },
    { text = '"' .. ("😀"):rep(12) .. '"', bytes = 50 },
  }
  for _, value in ipairs(strings_with_multi_byte_characters) do
    assert_bytes_as_written(value.text, value.bytes)
    for _, cut in ipairs(lines_of_cut_string(value.text)) do
      local shown = shown_part_and_left_out(cut)
      assert_eq(is_valid_utf8(shown), true, cut.label .. ", the shown part " .. vim.inspect(shown) .. " is valid UTF-8:")
      local _, characters = shown:gsub("[^\128-\191]", "")
      assert_eq(characters, SMALL_LIMITS.string_characters, cut.label .. ", characters in the shown part:")
    end
  end
end)

--- An array of single-digit items that is the whole record and, with the
--- small limits, shows its first items and hides `hidden_items` more, as
--- JSON text. Two bytes an item, so millions of items stay cheap to build.
---@param hidden_items integer
---@return string record
local function record_of_digits_hiding(hidden_items)
  return "[" .. ("0,"):rep(SMALL_LIMITS.array_items + hidden_items - 1) .. "0]"
end

--- Asserts that the array of digits hiding `hidden_items` formats with the
--- small limits to its shown items, the line `marker_line` and its closing
--- bracket; a failure names the count, since the record is too long to
--- print.
---@param hidden_items integer
---@param marker_line string the marker line, indentation included
local function assert_marker_line_of_array_hiding(hidden_items, marker_line)
  assert_formats_with_small_limits(
    record_of_digits_hiding(hidden_items),
    { "[", "  0,", "  0,", "  0,", marker_line, "]" },
    "an array of digits hiding " .. hidden_items .. " items"
  )
end

--- Asserts that a string that is the whole record and leaves out
--- `left_out` characters after `0123456789` formats with the small limits
--- to the one line `line`; a failure names the count.
---@param left_out integer
---@param line string the line the string gives, its marker included
local function assert_line_of_string_leaving_out(left_out, line)
  assert_formats_with_small_limits('"0123456789' .. ("x"):rep(left_out) .. '"', { line }, "a string leaving out " .. left_out .. " characters")
end

test("the count in a cut array's marker has no comma below a thousand and one from a thousand: 999, 1,000 and 1,001 items left out", function()
  assert_marker_line_of_array_hiding(999, "  … 999 more items")
  assert_marker_line_of_array_hiding(1000, "  … 1,000 more items")
  assert_marker_line_of_array_hiding(1001, "  … 1,001 more items")
end)

test("the count in a cut array's marker has a comma between every group of three digits: 1,000,000 and 12,345,678 items left out", function()
  assert_marker_line_of_array_hiding(1000000, "  … 1,000,000 more items")
  assert_marker_line_of_array_hiding(12345678, "  … 12,345,678 more items")
end)

test("the count in a cut string's marker is grouped in threes with commas: 37,907 characters left out", function()
  assert_line_of_string_leaving_out(37907, '"0123456789"  … 37,907 more characters')
end)

test("a count of three or six digits, 100 or 100,000, starts with no comma, in a cut array's marker and in a cut string's", function()
  assert_marker_line_of_array_hiding(100, "  … 100 more items")
  assert_marker_line_of_array_hiding(100000, "  … 100,000 more items")
  assert_line_of_string_leaving_out(100, '"0123456789"  … 100 more characters')
  assert_line_of_string_leaving_out(100000, '"0123456789"  … 100,000 more characters')
end)

test("an array with exactly one item left out has the marker line `… 1 more item`, in the singular", function()
  assert_formats_with_small_limits("[1,2,3,4]", { "[", "  1,", "  2,", "  3,", "  … 1 more item", "]" })
end)

test("a string with exactly one character left out reads `… 1 more character`, in the singular", function()
  assert_formats_with_small_limits('"0123456789a"', { '"0123456789"  … 1 more character' })
end)

test("a count of two takes the plural: `… 2 more items` and `… 2 more characters`", function()
  assert_formats_with_small_limits("[1,2,3,4,5]", { "[", "  1,", "  2,", "  3,", "  … 2 more items", "]" })
  assert_formats_with_small_limits('"0123456789ab"', { '"0123456789"  … 2 more characters' })
end)

test("only a count of exactly one is singular: 1,001 items or characters left out read `… 1,001 more items` and `… 1,001 more characters`", function()
  assert_marker_line_of_array_hiding(1001, "  … 1,001 more items")
  assert_line_of_string_leaving_out(1001, '"0123456789"  … 1,001 more characters')
end)

--- Records cut in more than one place with the small limits, each with the
--- trimmed places it reports: a cut key before a cut array, arrays cut at
--- three depths, and a cut key, a cut array and two cut strings.
---@type { text: string, trimmed_places: integer }[]
local records_cut_in_several_places = {
  { text = '{"0123456789abcdef":[1,2,3,4,5]}', trimmed_places = 2 },
  { text = "[[[1,2,3,4,5],2,3,4,5],2,3,4,5]", trimmed_places = 3 },
  { text = '{"0123456789a":[1,2,3,4],"z":["0123456789a","b","c","0123456789ab"]}', trimmed_places = 4 },
}

test("a cut array that is the whole record is one trimmed place", function()
  assert_reports_trimmed_places("[1,2,3,4,5]", SMALL_LIMITS, 1)
end)

test("each cut array and each cut string is one trimmed place, an array cut inside a shown item included", function()
  assert_reports_trimmed_places("[[1,2,3,4,5],[1,2],3,4]", SMALL_LIMITS, 2)
  assert_reports_trimmed_places('["a","b","0123456789abcdef","d","e"]', SMALL_LIMITS, 2)
end)

test("a long string and a long array among the hidden items are not trimmed places", function()
  assert_reports_trimmed_places('[1,2,3,"0123456789abcdef",[1,2,3,4,5]]', SMALL_LIMITS, 1)
end)

test("the trimmed places equal the markers in the lines, three and four places included", function()
  for _, record in ipairs(records_cut_in_several_places) do
    assert_reports_trimmed_places(record.text, SMALL_LIMITS, record.trimmed_places)
  end
end)

test("a record with nothing long reports no trimmed places with the small limits", function()
  for _, text in ipairs(records_with_short_arrays) do
    assert_reports_trimmed_places(text, SMALL_LIMITS, 0)
  end
  for _, text in ipairs(records_with_short_strings) do
    assert_reports_trimmed_places(text, SMALL_LIMITS, 0)
  end
end)

test("any record reports no trimmed places without limits, however long its arrays and strings", function()
  for _, record in ipairs(records_with_a_cut_array) do
    assert_reports_trimmed_places(record.text, nil, 0)
  end
  for _, text in ipairs(long_strings) do
    assert_reports_trimmed_places(text, nil, 0)
  end
  for _, record in ipairs(records_cut_in_several_places) do
    assert_reports_trimmed_places(record.text, nil, 0)
  end
end)

test("a blank record reports no trimmed places and no lines, with the small limits and without limits", function()
  for _, text in ipairs(blank_records) do
    assert_reports_trimmed_places(text, SMALL_LIMITS, 0)
    assert_formats_with_small_limits(text, {})
    assert_reports_trimmed_places(text, nil, 0)
    assert_formats(text, {})
  end
end)

test("a surrogate pair is never split: when the limit falls inside its first escape, both escapes are shown, then the closing quote and the marker", function()
  assert_string_formats_with_small_limits('"012345678\\ud83d\\ude00abc"', 26, '"012345678\\ud83d\\ude00"  … 3 more characters')
end)

test("a surrogate pair is never split: when the limit falls exactly between its two escapes, both are shown and the cut follows them", function()
  assert_string_formats_with_small_limits('"0123\\ud83d\\ude00abc"', 21, '"0123\\ud83d\\ude00"  … 3 more characters')
end)

test("a surrogate pair written with upper-case hexadecimal digits is kept together as well", function()
  assert_string_formats_with_small_limits('"012345678\\uD83D\\uDE00abc"', 26, '"012345678\\uD83D\\uDE00"  … 3 more characters')
  assert_string_formats_with_small_limits('"0123\\uD83D\\uDE00abc"', 21, '"0123\\uD83D\\uDE00"  … 3 more characters')
end)

test("a high surrogate not directly followed by a low one is an ordinary escape, and the cut follows it", function()
  assert_string_formats_with_small_limits('"0123\\ud83dabcdefghi"', 21, '"0123\\ud83d"  … 9 more characters')
  assert_string_formats_with_small_limits('"0123\\ud83d\\u00e9abc"', 21, '"0123\\ud83d"  … 9 more characters')
  assert_string_formats_with_small_limits('"0123\\ud83dabc\\ud83d\\ude00"', 27, '"0123\\ud83d"  … 15 more characters')
end)

test("two \\u escapes in a row that are not a surrogate pair are cut between them", function()
  assert_string_formats_with_small_limits('"0123\\u00e9\\u00e9abc"', 21, '"0123\\u00e9"  … 9 more characters')
end)

test("a string whose surrogate pair reaches its end leaves nothing out: it is shown whole, with no marker and no trimmed place", function()
  assert_string_shown_whole_with_small_limits('"012345678\\ud83d\\ude00"', 23)
  assert_string_shown_whole_with_small_limits('"0123\\ud83d\\ude00"', 18)
end)

test("wherever the limit falls on a surrogate pair, the shown part is at most eleven characters over the limit, keeps the pair whole, and adds up with the marker's count to the whole string", function()
  for zeros = 0, 12 do
    local value = '"' .. ("0"):rep(zeros) .. '\\ud83d\\ude00abc"'
    assert_bytes_as_written(value, zeros + 17)
    for _, cut in ipairs(lines_of_cut_string(value)) do
      local shown, left_out = shown_part_and_left_out(cut)
      assert_eq(#shown <= SMALL_LIMITS.string_characters + 11, true, cut.label .. ", the shown part " .. vim.inspect(shown) .. " is at most eleven characters over the limit:")
      local _, high_surrogates = shown:gsub("\\ud83d", "")
      local _, low_surrogates = shown:gsub("\\ude00", "")
      assert_eq(high_surrogates, low_surrogates, cut.label .. ", low surrogates against high ones in the shown part " .. vim.inspect(shown) .. ":")
      assert_eq(#shown + tonumber(left_out), #value - 2, cut.label .. ", characters shown and left out:")
    end
  end
end)

--- The byte positions of the `…` that stand outside strings in `line`, a
--- line the formatter returned. A string ends at the first quote that is not
--- part of an escape: the byte after a backslash belongs to the escape
--- (point 14). A string that never closes runs to the end of the line.
---@param line string
---@return integer[] positions
local function ellipses_outside_strings(line)
  ---@type integer[]
  local positions = {}
  local position = 1
  while true do
    local ellipsis_at = line:find("…", position, true)
    if not ellipsis_at then
      return positions
    end
    local quote_at = line:find('"', position, true)
    if not quote_at or ellipsis_at < quote_at then
      positions[#positions + 1] = ellipsis_at
      position = ellipsis_at + #"…"
    else
      -- Pass over the string the quote opens, up to its closing quote.
      position = quote_at + 1
      while true do
        local at = line:find('["\\]', position)
        if not at then
          return positions
        end
        position = at + 1
        if line:sub(at, at) == '"' then
          break
        end
        position = position + 1
      end
    end
  end
end

test("the `…` outside strings in a line are found by point 14's rule, so a `…` inside a string is not among them, after an escaped quote or before an escaped backslash and the closing quote alike", function()
  ---@type { line: string, positions: integer[] }[]
  local lines = {
    { line = '  "a…b",', positions = {} },
    { line = "  … 2 more items", positions = { 3 } },
    { line = '"\\"…\\""', positions = {} },
    { line = '"01234567\\\\"  … 6 more characters', positions = { 15 } },
    { line = '  "0123…45678": "x…01234567"  … 4 more characters  … 3 more characters', positions = { 35, 58 } },
    { line = '"ab…', positions = {} },
  }
  for _, case in ipairs(lines) do
    assert_deep_eq(ellipses_outside_strings(case.line), case.positions, vim.inspect(case.line) .. ", positions of `…` outside strings:")
  end
end)

--- Records whose strings hold `…`, each with the trimmed places it reports
--- with the small limits and the `…` its lines keep inside strings: `…` in
--- shown strings, in a key, in cut strings before and after the cut, among
--- the hidden items, in strings that read like a marker, and next to an
--- escaped quote and an escaped backslash.
---@type { text: string, trimmed_places: integer, ellipses_in_strings: integer }[]
local records_with_ellipses_in_strings = {
  { text = '["a…b","…",3,4]', trimmed_places = 1, ellipses_in_strings = 2 },
  { text = '{"t":"…","z":[1,2,3,4,5]}', trimmed_places = 1, ellipses_in_strings = 1 },
  { text = '"012345678…abc"', trimmed_places = 1, ellipses_in_strings = 1 },
  { text = '"0123456789ab…"', trimmed_places = 1, ellipses_in_strings = 0 },
  { text = '{"0123…456789abc":"x…0123456789…"}', trimmed_places = 2, ellipses_in_strings = 2 },
  { text = '[1,2,3,"…","… 2 more items",["…"]]', trimmed_places = 1, ellipses_in_strings = 0 },
  { text = '["… 2 more items","… 1 more character",3,4]', trimmed_places = 3, ellipses_in_strings = 2 },
  { text = '{"… 1 more item":"… 6 more characters"}', trimmed_places = 2, ellipses_in_strings = 2 },
  { text = '["\\"…\\"","01234567\\\\…abc",3,4]', trimmed_places = 2, ellipses_in_strings = 1 },
}

--- Point 18's varied records, the records cut in several places and the
--- records whose strings hold `…`.
---@type string[]
local varied_records_with_ellipses = vim.list_extend({}, varied_records)
vim.list_extend(varied_records_with_ellipses, texts_of(records_cut_in_several_places))
vim.list_extend(varied_records_with_ellipses, texts_of(records_with_ellipses_in_strings))

test('with the small limits, ["a…b","…",3,4] keeps both `…` inside their strings and its marker line reads `… 1 more item`', function()
  assert_formats_with_small_limits('["a…b","…",3,4]', { "[", '  "a…b",', '  "…",', "  3,", "  … 1 more item", "]" })
end)

test("a `…` a record's string holds stays inside a string when it is shown, and is not in the lines when it is cut off or among the hidden items", function()
  for _, record in ipairs(records_with_ellipses_in_strings) do
    local label = vim.inspect(record.text) .. " with small limits"
    assert_record_decodes(record.text)
    local lines, trimmed_places = json_formatter.format(record.text, SMALL_LIMITS)
    assert_eq(trimmed_places, record.trimmed_places, label .. ", trimmed places:")
    local ellipses_in_strings = 0
    for _, line in ipairs(lines) do
      local _, ellipses = line:gsub("…", "")
      ellipses_in_strings = ellipses_in_strings + ellipses - #ellipses_outside_strings(line)
    end
    assert_eq(ellipses_in_strings, record.ellipses_in_strings, label .. ", `…` inside strings:")
  end
end)

test("with the small limits, the `…` outside strings in a varied set's lines are as many as the trimmed places, and each begins a marker: `…`, one space and a digit", function()
  local all_trimmed_places = 0
  for _, text in ipairs(varied_records_with_ellipses) do
    local label = vim.inspect(text) .. " with small limits"
    local lines, trimmed_places = json_formatter.format(text, SMALL_LIMITS)
    local ellipses = 0
    for position, line in ipairs(lines) do
      for _, at in ipairs(ellipses_outside_strings(line)) do
        ellipses = ellipses + 1
        assert_match(line:sub(at), "^… %d", ("%s, line %d, a `…` outside a string:"):format(label, position))
      end
    end
    assert_eq(ellipses, trimmed_places, label .. ", `…` outside strings against the trimmed places:")
    all_trimmed_places = all_trimmed_places + trimmed_places
  end
  assert_eq(all_trimmed_places > 0, true, "the varied set has trimmed places with small limits:")
end)

test("without limits, no line of the varied set has a `…` outside a string", function()
  for _, text in ipairs(varied_records_with_ellipses) do
    for position, line in ipairs((json_formatter.format(text))) do
      assert_deep_eq(ellipses_outside_strings(line), {}, ("%s without limits, line %d, positions of `…` outside strings:"):format(vim.inspect(text), position))
    end
  end
end)

test("an array's marker line begins, after its indentation, with `…`, and a line that begins with `…` is an array's marker line", function()
  local array_marker_lines = 0
  for _, text in ipairs(varied_records_with_ellipses) do
    for position, line in ipairs((json_formatter.format(text, SMALL_LIMITS))) do
      local label = ("%s with small limits, line %d"):format(vim.inspect(text), position)
      for _, at in ipairs(ellipses_outside_strings(line)) do
        if line:find("^… [%d,]+ more items?$", at) then
          array_marker_lines = array_marker_lines + 1
          assert_match(line:sub(1, at - 1), "^ *$", label .. ", what comes before an array's marker:")
        end
      end
      if line:find("^ *…") then
        assert_match(line, "^ *… [%d,]+ more items?$", label .. ", a line beginning with `…`:")
      end
    end
  end
  assert_eq(array_marker_lines > 0, true, "the varied set has array marker lines with small limits:")
end)

test("the lines of a trimmed record, joined with line feeds, are rejected by the built-in JSON decoder", function()
  local trimmed_records = 0
  for _, text in ipairs(varied_records_with_ellipses) do
    local lines, trimmed_places = json_formatter.format(text, SMALL_LIMITS)
    if trimmed_places > 0 then
      trimmed_records = trimmed_records + 1
      local lines_decode = pcall(vim.json.decode, table.concat(lines, "\n"))
      assert_eq(lines_decode, false, vim.inspect(text) .. " with small limits, its lines decode:")
    end
  end
  assert_eq(trimmed_records >= #records_with_ellipses_in_strings, true, "the varied set has trimmed records with small limits:")
end)

--- The records with nothing long of point 39, of every shape it lists.
---@type string[]
local records_with_nothing_long = {
  '{"a":[{"b":{"c":[[{"d":{"e":[1,{"f":"deep"}]}}]]}}]}',
  '{"a":{},"b":[],"c":[{},[],{"d":{}}],"e":{"f":{"g":[[]]}}}',
  '{"a":1,"b":2,"c":3,"d":4,"e":5}',
  '{"o":{"a":1,"b":2,"c":3,"d":4},"z":[{"c":3,"d":4}]}',
  '[{"a":1,"b":2,"c":3,"d":4},2,3]',
  '["say \\"hi\\"","a\\\\b","\\u00e9\\n\\t"]',
  '{"\\"k\\"":"\\b\\f\\r\\/"}',
  '{"é ü ñ":"✓ 漢字 😀","emoji":["😀","é"]}',
  '{"integers":[0,-7,12345678901234567890],"decimals":[18.40,-0.5,3.14],"exponents":[1.2e-3,1E+2,-6.02E23],"minus zero":-0}',
  '{"yes":true,"no":false,"nothing":null,"words":[true,false,null]}',
  '[1,"two",[]]',
  '"1.0"',
  "-1.5e10",
  "true",
  "false",
  "null",
  "[]",
  "{}",
  compact_record,
  unevenly_spaced_record,
}

test("a record with nothing long, of every shape, gives with the small limits exactly the lines it gives without limits, and no trimmed places", function()
  for _, text in ipairs(records_with_nothing_long) do
    assert_record_decodes(text)
    assert_small_limits_change_nothing(text)
    assert_reports_trimmed_places(text, SMALL_LIMITS, 0)
  end
end)

test("a record with an array of exactly the items limit or a string of exactly the characters limit gives with the small limits exactly the lines it gives without limits, and no trimmed places", function()
  ---@type string[]
  local texts = { "[1,2,3]", '"0123456789"', '{"a":[1,2,3],"s":"0123456789"}' }
  vim.list_extend(texts, texts_of(records_with_arrays_of_exactly_the_limit))
  vim.list_extend(texts, texts_of(records_with_strings_of_exactly_the_limit))
  for _, text in ipairs(texts) do
    assert_small_limits_change_nothing(text)
    assert_reports_trimmed_places(text, SMALL_LIMITS, 0)
  end
end)

--- Limits far larger than anything in point 18's varied set: no record of
--- it has as many bytes, so none has an array of as many items or a string
--- of as many characters.
---@type JsonTrimLimits
local LIMITS_FAR_LARGER_THAN_THE_VARIED_SET = { array_items = 1000000, string_characters = 1000000 }

test("with limits far larger than anything in it, every record of point 18's varied set formats to the same lines as without limits", function()
  for _, text in ipairs(varied_records) do
    local label = vim.inspect(text) .. " with limits far larger than it"
    assert_eq(#text < LIMITS_FAR_LARGER_THAN_THE_VARIED_SET.array_items, true, label .. ", fewer bytes than the items limit:")
    assert_eq(#text < LIMITS_FAR_LARGER_THAN_THE_VARIED_SET.string_characters, true, label .. ", fewer bytes than the characters limit:")
    local lines, trimmed_places = json_formatter.format(text, LIMITS_FAR_LARGER_THAN_THE_VARIED_SET)
    assert_deep_eq(lines, (json_formatter.format(text)), label .. ", lines against those without limits:")
    assert_eq(trimmed_places, 0, label .. ", trimmed places:")
  end
end)

--- How many items the long array of point 40 has, and how many characters
--- its long string has: far more than either limit, small or default.
local ITEMS_OF_THE_LONG_ARRAY = 10000
local CHARACTERS_OF_THE_LONG_STRING = 50000

--- An array that is the whole record, of the numbers 1 to `count` as
--- written.
---@param count integer how many items the array has
---@return string
local function array_of_items(count)
  ---@type string[]
  local items = {}
  for item = 1, count do
    items[item] = tostring(item)
  end
  return "[" .. table.concat(items, ",") .. "]"
end

--- The long array of point 40, the whole record.
local long_array_record = array_of_items(ITEMS_OF_THE_LONG_ARRAY)

--- The long string of point 40, the whole record: 50,000 single-byte
--- characters.
local long_string_record = '"' .. ("x"):rep(CHARACTERS_OF_THE_LONG_STRING) .. '"'

--- A record whose members' values are an array of one item more than the
--- default items limit and a string of one character more than the default
--- characters limit.
local record_longer_than_the_default_limits = '{"items":'
  .. array_of_items(json_formatter.DEFAULT_LIMITS.array_items + 1)
  .. ',"text":"'
  .. ("y"):rep(json_formatter.DEFAULT_LIMITS.string_characters + 1)
  .. '"}'

--- How many bytes of the first line that differs a failure of
--- `assert_same_lines` shows of each version at most (a few more to end on
--- a whole character), and how many of them come before the first byte
--- that differs.
local BYTES_SHOWN_OF_A_DIFFERING_LINE = 60
local BYTES_SHOWN_BEFORE_THE_DIFFERENCE = 20

--- `line`'s bytes `from` to `to`, carried on past `to` to the end of the
--- UTF-8 character there, so a failure never shows half of a `…`.
---@param line string? a line, or nil past the end of its list
---@param from integer the first byte shown, the start of a character
---@param to integer the last byte shown, before carrying on
---@return string?
local function piece_of_line(line, from, to)
  if line == nil then
    return nil
  end
  while line:find("^[\128-\191]", to + 1) do
    to = to + 1
  end
  return line:sub(from, to)
end

--- Asserts that `lines` are exactly the lines `expected`, every line
--- compared, for a record too long to print: a failure names `record_name`
--- and shows only how many lines each list has, the position of the first
--- line that differs, and a piece of at most about 60 bytes of each version
--- of it, around the first byte that differs.
---@param lines string[] the lines the formatter returned
---@param expected string[] the lines it must return
---@param record_name string names the record, and how it was formatted, in a failure
local function assert_same_lines(lines, expected, record_name)
  local position = 1
  while lines[position] ~= nil and lines[position] == expected[position] do
    position = position + 1
  end
  local line, expected_line = lines[position], expected[position]
  local first_byte = 1
  if line ~= nil and expected_line ~= nil then
    while line:byte(first_byte) == expected_line:byte(first_byte) do
      first_byte = first_byte + 1
    end
  end
  local from = math.max(1, first_byte - BYTES_SHOWN_BEFORE_THE_DIFFERENCE)
  -- Start on a whole character. The bytes before the first that differs
  -- are the same in both versions, and moving back only shows more.
  local either_line = line or expected_line or ""
  while from > 1 and either_line:find("^[\128-\191]", from) do
    from = from - 1
  end
  local to = from + BYTES_SHOWN_OF_A_DIFFERING_LINE - 1
  assert_eq(
    piece_of_line(line, from, to),
    piece_of_line(expected_line, from, to),
    ("%s: lines returned %d, expected %d; the first line that differs is line %d, shown from byte %d:"):format(record_name, #lines, #expected, position, from)
  )
end

test("an array of 10,000 items formatted without limits gives 10,002 lines, none of them a marker, and no trimmed places", function()
  local label = "the array of 10,000 items without limits"
  local lines, trimmed_places = json_formatter.format(long_array_record)
  assert_deep_eq(positions_of_lines_holding(lines, "…"), {}, label .. ", lines holding a marker:")
  ---@type string[]
  local expected = { "[" }
  for item = 1, ITEMS_OF_THE_LONG_ARRAY do
    expected[#expected + 1] = "  " .. item .. (item < ITEMS_OF_THE_LONG_ARRAY and "," or "")
  end
  expected[#expected + 1] = "]"
  assert_same_lines(lines, expected, label)
  assert_eq(trimmed_places, 0, label .. ", trimmed places:")
end)

test("a string of 50,000 characters formatted without limits gives one line holding all of it, and no trimmed places", function()
  local label = "the string of 50,000 characters without limits"
  local lines, trimmed_places = json_formatter.format(long_string_record)
  assert_same_lines(lines, { long_string_record }, label)
  assert_eq(trimmed_places, 0, label .. ", trimmed places:")
end)

test("a record with an array longer than the default items limit and a string longer than the default characters limit, formatted without limits, decodes to the same value as the record", function()
  assert_lines_decode_to_the_record(record_longer_than_the_default_limits, "the record longer than the default limits, without limits,")
end)

test("passing no limits and passing nil give the same lines and the same trimmed places", function()
  ---@type { name?: string, text: string }[]
  local records = {
    { name = "the array of 10,000 items", text = long_array_record },
    { name = "the string of 50,000 characters", text = long_string_record },
    { name = "the record longer than the default limits", text = record_longer_than_the_default_limits },
    { text = "[1,2,3,4,5]" },
    { text = '"0123456789abcdef"' },
    { text = '{"0123456789abcdef":[1,2,3,4,5]}' },
    { name = 'the blank record ""', text = "" },
  }
  for _, record in ipairs(records) do
    local label = (record.name or vim.inspect(record.text)) .. " with no limits and with nil"
    local lines, trimmed_places = json_formatter.format(record.text)
    local nil_lines, nil_trimmed_places = json_formatter.format(record.text, nil)
    assert_same_lines(nil_lines, lines, label)
    assert_eq(nil_trimmed_places, trimmed_places, label .. ", trimmed places:")
  end
end)

--- The PRD's own figures for the default limits, each the whole record:
--- an array of the numbers 1 to 9,999, and a string of 39,907 single-byte
--- characters.
local array_of_9999_items = array_of_items(9999)
local string_of_39907_characters = '"' .. ("x"):rep(39907) .. '"'

test("the default limits are one value of 20 items per array and 2,000 characters per string, which passed as it is cuts an array of 9,999 items after 20 with 9,979 left out and a string of 39,907 characters after 2,000 with 37,907 left out", function()
  assert_deep_eq(json_formatter.DEFAULT_LIMITS, { array_items = 20, string_characters = 2000 }, "the default limits:")

  local array_label = "the array of 9,999 items with the default limits"
  local array_lines, array_trimmed_places = json_formatter.format(array_of_9999_items, json_formatter.DEFAULT_LIMITS)
  ---@type string[]
  local expected = { "[" }
  for item = 1, 20 do
    expected[#expected + 1] = "  " .. item .. ","
  end
  expected[#expected + 1] = "  … 9,979 more items"
  expected[#expected + 1] = "]"
  assert_same_lines(array_lines, expected, array_label)
  assert_eq(array_trimmed_places, 1, array_label .. ", trimmed places:")

  local string_label = "the string of 39,907 characters with the default limits"
  local string_lines, string_trimmed_places = json_formatter.format(string_of_39907_characters, json_formatter.DEFAULT_LIMITS)
  assert_same_lines(string_lines, { '"' .. ("x"):rep(2000) .. '"  … 37,907 more characters' }, string_label)
  assert_eq(string_trimmed_places, 1, string_label .. ", trimmed places:")
end)

test("with the default limits, an array of exactly the default items and a string of exactly the default characters come out as they do without limits, and no trimmed places", function()
  local limits = json_formatter.DEFAULT_LIMITS
  ---@type { name: string, text: string }[]
  local records = {
    { name = "the array of exactly the default items", text = array_of_items(limits.array_items) },
    { name = "the string of exactly the default characters", text = '"' .. ("x"):rep(limits.string_characters) .. '"' },
  }
  for _, record in ipairs(records) do
    local label = record.name .. " with the default limits"
    local lines, trimmed_places = json_formatter.format(record.text, limits)
    assert_same_lines(lines, (json_formatter.format(record.text)), label)
    assert_eq(trimmed_places, 0, label .. ", trimmed places:")
  end
end)

test("formatting with the default limits leaves them holding the same two numbers", function()
  assert_deep_eq(json_formatter.DEFAULT_LIMITS, default_limits_as_loaded, "the default limits after the cases before this one formatted with them:")
  ---@type { name: string, text: string }[]
  local records = {
    { name = "the array of 9,999 items", text = array_of_9999_items },
    { name = "the string of 39,907 characters", text = string_of_39907_characters },
    { name = "a record with nothing long", text = compact_record },
    { name = 'the blank record ""', text = "" },
  }
  for _, record in ipairs(records) do
    json_formatter.format(record.text, json_formatter.DEFAULT_LIMITS)
    assert_deep_eq(json_formatter.DEFAULT_LIMITS, default_limits_as_loaded, "the default limits after formatting " .. record.name .. " with them:")
  end
end)

--- Every text of point 17, none of which is valid JSON.
---@type string[]
local texts_of_point_17 = vim.list_extend({}, texts_that_are_not_json)
vim.list_extend(texts_of_point_17, texts_with_a_raw_line_break_inside_a_string)
vim.list_extend(texts_of_point_17, texts_with_a_raw_line_break_between_words)
vim.list_extend(texts_of_point_17, texts_closing_what_is_not_open)

test("every text of point 17 that is not valid JSON, formatted with the small limits, returns a list of lines and a number of trimmed places without raising or looping", function()
  for _, text in ipairs(texts_of_point_17) do
    assert_formats_to_lines_without_line_breaks(text, SMALL_LIMITS)
  end
end)

test("an array longer than the limit that never closes, ends in a comma, has a comma before its bracket or a closer of the wrong kind among its hidden items does not raise with the small limits", function()
  for _, text in ipairs({ "[1,2,3,4,5", "[1,2,3,", "[1,2,3,]", '[1,2,3,{"a":1],5]' }) do
    assert_formats_to_lines_without_line_breaks(text, SMALL_LIMITS)
  end
end)

test("a string longer than the limit that never closes, whose cut meets a backslash or a \\u escape cut off by the end of the text, with a \\u escape of too few digits or with bytes that are not UTF-8 at the cut does not raise with the small limits", function()
  -- Bytes that are not UTF-8 are written as Lua's decimal escapes, each
  -- followed by something that is not a digit.
  ---@type { text: string, bytes: integer }[]
  local texts = {
    { text = '"0123456789abcdef', bytes = 17 },
    { text = '"012345678\\', bytes = 11 },
    { text = '"0123456789\\', bytes = 12 },
    { text = '"012345678\\u00', bytes = 14 },
    { text = '"012345678\\u0"', bytes = 14 },
    { text = '{"t":"012345678\\u0","z":1}', bytes = 26 },
    { text = '"012345678\255abc"', bytes = 15 },
    { text = '"012345678\195"', bytes = 12 },
    { text = '"012345678\240\159abc"', bytes = 16 },
    { text = '"012345678\128abc"', bytes = 15 },
    { text = '"0123456789\128\128\128"', bytes = 15 },
  }
  for _, written in ipairs(texts) do
    assert_bytes_as_written(written.text, written.bytes)
    assert_formats_to_lines_without_line_breaks(written.text, SMALL_LIMITS)
  end
end)

test("a raw line break inside a hidden item, between hidden items, or in the shown or the hidden part of a cut string gives with the small limits no line holding a line break", function()
  for _, text in ipairs({
    '[1,2,3,"a\nb",5]',
    '[1,2,3,"a\r\nb",5]',
    "[1,2,3,4,\n5]",
    "[1,2,3,4\r\n,5]",
    '"01234\n56789abcdef"',
    '"01234\r\n56789abcdef"',
    '"01234\r56789abcdef"',
    '"0123456789ab\ncdef"',
    '"0123456789ab\r\ncdef"',
  }) do
    assert_formats_to_lines_without_line_breaks(text, SMALL_LIMITS)
  end
end)

test("the formatter loaded by path in a worker thread trims a record longer than the default limits it holds there to the lines and trimmed places the same call gives on the main thread, handed back as a list of strings and a number", function()
  local label = "the record longer than the default limits, formatted with them in a worker thread"
  local expected_lines, expected_trimmed_places = json_formatter.format(record_longer_than_the_default_limits, json_formatter.DEFAULT_LIMITS)
  assert_eq(expected_trimmed_places, 2, "on the main thread, the trimmed places of the record longer than the default limits:")
  local lines, trimmed_places = result_from_worker_thread(record_longer_than_the_default_limits, true)
  assert_eq(type(trimmed_places), "number", label .. ", the type of the trimmed places:")
  assert_same_lines(lines, expected_lines, label)
  assert_eq(trimmed_places, expected_trimmed_places, label .. ", trimmed places:")
end)

test("the formatter loaded by path where the editor's global is absent trims a record longer than the default limits it holds to the lines and trimmed places it gives with the editor's global", function()
  local label = "the record longer than the default limits, formatted with them without the editor's global"
  local environment = copy_of_globals()
  environment.vim = nil
  ---@module "andrew.jsonl.json_formatter"
  local formatter = setfenv(assert(loadfile(json_formatter_path)), environment)()
  local lines, trimmed_places = formatter.format(record_longer_than_the_default_limits, formatter.DEFAULT_LIMITS)
  local expected_lines, expected_trimmed_places = json_formatter.format(record_longer_than_the_default_limits, json_formatter.DEFAULT_LIMITS)
  assert_same_lines(lines, expected_lines, label)
  assert_eq(trimmed_places, expected_trimmed_places, label .. ", trimmed places:")
end)

_H.finish()
