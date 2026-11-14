local config = require("andrew.vault.config")
local people = require("andrew.vault.people")
local notify = require("andrew.vault.notify")

local M = {}
M.name = "Literature Note"

-- Picker sentinels. Compared by exact equality, so they are prefixed to keep
-- them distinguishable from a real People note name.
local CHOICE_NEW = "+ New author..."
local CHOICE_DONE = "✓ Done — finish author list"

--- Join author names the way a citation reads: "A", "A and B", "A, B, and C".
--- Uses the Oxford comma for three or more names.
---@param list string[]
---@return string
local function join_authors(list)
  local n = #list
  if n == 0 then return "" end
  if n == 1 then return list[1] end
  if n == 2 then return list[1] .. " and " .. list[2] end
  return table.concat(list, ", ", 1, n - 1) .. ", and " .. list[n]
end

--- Render the frontmatter `authors:` key as a YAML block list of person
--- wikilinks. Indentation is two spaces because the frontmatter parser matches
--- list items with "^%s+%- " (patterns.lua) — a flush-left "- x" parses as nil.
--- Links stay bare ([[Name]], not [[People/Name]]) per the vault convention.
--- Quoting goes through people.yaml_quote so apostrophes stay resolvable.
---@param list string[]
---@return string
local function authors_yaml(list)
  if #list == 0 then return "authors:\n" end
  local lines = { "authors:" }
  for _, name in ipairs(list) do
    lines[#lines + 1] = "  - " .. people.yaml_quote("[[" .. name .. "]]")
  end
  return table.concat(lines, "\n") .. "\n"
end

--- Strip characters that must never reach a person note's name.
--- "<", ">" and "%" would let a pasted name carry Templater delimiters:
--- Obsidian fires vault.on("create") for files written from outside, and
--- Templater parses non-empty new files in place, so "<% ... %>" in a name
--- would execute as code the next time Obsidian sees the stub.
---@param name string
---@return string
local function sanitize_author(name)
  return (vim.trim(name):gsub("[<>%%]", ""))
end

--- Prompt repeatedly for authors, offering existing People notes for reuse so
--- the same person does not accumulate spelling variants.
---@param e table engine
---@return string[]|nil  collected names, or nil if the user aborted the template
local function collect_authors(e)
  local authors = {}
  local seen = {}

  local choices = { CHOICE_NEW, CHOICE_DONE }
  for _, name in ipairs(people.list_names()) do
    choices[#choices + 1] = name
  end

  while true do
    local choice = e.select(choices, { prompt = "Author " .. (#authors + 1) .. " (or Done)" })
    -- Cancelling the picker means "no more authors", not "abandon the note"
    if choice == nil or choice == CHOICE_DONE then break end

    local name
    if choice == CHOICE_NEW then
      name = e.input({ prompt = "New author name (e.g., Rongbo Wang)" })
      if name == nil then return nil end -- Esc at the free-text prompt aborts
      name = sanitize_author(name)
      if name == "" then break end
    else
      name = sanitize_author(choice)
    end

    if name ~= "" and not seen[name] then
      seen[name] = true
      authors[#authors + 1] = name
    end
  end

  return authors
end

--- Ensure every author has a People note. Without one, `links-to:"<name>"`
--- misses the paper and following the link would create a stub in the paper's
--- own folder instead of People/.
---@param list string[]
local function ensure_people_notes(list)
  local created = 0
  for _, name in ipairs(list) do
    if people.create_stub(name) == "created" then created = created + 1 end
  end
  if created > 0 then
    notify.info("created " .. created .. " People note(s)")
  end
end

local body_template = [==[
# {{authors}} ({{year}}) — {{title}}

> [!cite] Citation
> {{authors}}, "{{title}}," *{{journal}}*, {{year}}.
> DOI: {{doi}}

---

> [!summary]
>

> [!Author's Intentions]
>

## Notes

## Related Concepts

- [[]]

## Related Papers

- [[]]

]==]

function M.run(e, p)
  local title = e.input({ prompt = "Paper title" })
  if not title then return end

  local authors = collect_authors(e)
  if not authors then return end

  local year = e.input({ prompt = "Publication year" })
  if not year then return end

  local journal = e.input({ prompt = "Journal name" })
  if not journal then return end

  local doi = e.input({ prompt = "DOI (leave blank if unknown)", default = "" })

  local date = e.today()
  -- Body vars stay plain prose: substitute() tostring()s values, so a table
  -- would render as "table: 0x...".
  local vars = {
    title = title,
    authors = join_authors(authors),
    year = year,
    journal = journal,
    doi = doi or "",
    date = date,
  }

  local fm = "---\n"
    .. "type: literature\n"
    .. 'title: "' .. title .. '"\n'
    .. authors_yaml(authors)
    .. "year: " .. year .. "\n"
    .. 'journal: "' .. journal .. '"\n'
    .. "doi: " .. (doi or "") .. "\n"
    .. "start_date: " .. date .. "\n"
    .. "completed_date: " .. date .. "\n"
    .. "tags:\n"
    .. "  - literature/paper\n"
    .. "---\n"

  -- Sanitize title for filename
  local safe_title = title:gsub(":", " -"):gsub("/", "-"):gsub("[%*%?|]", "")

  -- Each paper gets its own folder, so the PDF can sit beside the note
  local paper_dir = config.dirs.library .. "/" .. safe_title

  -- Before write_note, which opens the new note and should own the final focus
  ensure_people_notes(authors)

  e.write_note(paper_dir .. "/" .. safe_title, fm .. "\n" .. e.render(body_template, vars))
end

return M
