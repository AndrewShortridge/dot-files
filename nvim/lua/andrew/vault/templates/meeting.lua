local M = {}
M.name = "Meeting Note"

function M.run(e, p)
  local title = e.input({ prompt = "Meeting title (e.g., Weekly Advisor Check-in)" })
  if not title then return end

  local attendee = e.input({ prompt = "Primary attendee (e.g., Dr. Smith)" })
  if not attendee then return end

  local project = p.project_or_none(e)
  if project == nil then return end

  local is_general = (project == false)
  local date = e.today()
  local date_long = e.today_long()

  -- Frontmatter
  local fm = "---\n"
    .. "type: meeting\n"
    .. "date: " .. date .. "\n"
    .. "attendees:\n"
    .. "  - '[[" .. attendee .. "]]'\n"
  if is_general then
    fm = fm .. "parent-project:\n"
  else
    fm = fm .. "parent-project: '[[Projects/" .. project .. "/Dashboard|" .. project .. "]]'\n"
  end
  fm = fm
    .. "tags:\n"
    .. "  - meeting\n"
    .. "---\n"

  -- Body
  local body = "\n# Meeting — " .. date_long .. "\n\n"
    .. "**Attendees:** [[" .. attendee .. "]]\n"
  if is_general then
    body = body .. "**Project:** —\n"
  else
    body = body .. "**Project:** [[Projects/" .. project .. "/Dashboard|" .. project .. "]]\n"
  end
  body = body .. [[

---

## Agenda

1.

## Discussion Notes



## Feedback / Guidance

> [!important] Specific feedback on drafts, methods, direction

-

## Action Items

- [ ]
- [ ]

## Decisions Made

| Decision | Rationale |
| -------- | --------- |
|          |           |

## Follow-Up

- **Next meeting:**
- **Items to prepare:**

## Notes
]]

  -- Destination: project meetings folder or vault root
  local dest
  if is_general then
    dest = title
  else
    dest = "Projects/" .. project .. "/Meetings/" .. title
  end

  e.write_note(dest, fm .. body)
end

return M
