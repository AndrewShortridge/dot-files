local M = {}
M.name = "Presentation Note"

local body_template = [==[
# ${title}

**Event:** ${event}
**Date:** ${date}
**Project:** [[${project}/Dashboard]]
**File:** `${file_location}`
**Status:** `${status}`

---

## Audience & Goal

> [!abstract] Who is this for and what should they walk away understanding?
>

## Slide Outline

| # | Slide Title | Content / Key Point | Data Source |
| - | ----------- | ------------------- | ----------- |
| 1 | Title slide |  |  |
| 2 |  |  | [[]] |
| 3 |  |  | [[]] |

## Key Figures Used

- [[]]

## Talking Points

> [!note] Things to say that aren't on the slides

-

## Anticipated Questions

| Question | Prepared Answer |
| -------- | --------------- |
|          |                 |

## Changes from Previous Version

> If this is an updated version of a prior presentation

- Previous: [[]]
- Changes:

## Post-Presentation Notes

> [!people] Feedback received, questions asked, follow-ups needed

-

## Notes
]==]

function M.run(e, p)
  local title = e.input({ prompt = "Presentation title (e.g., Group Meeting 2025-02-13)" })
  if not title then return end

  local event = e.input({ prompt = "Event / audience (e.g., Group Meeting, APS Conference)" })
  if not event then return end

  local file_location = e.input({ prompt = "Path to .pptx file", default = "" })

  local status = e.select(
    { "Drafting", "Ready", "Presented", "Archived" },
    { prompt = "Presentation status" }
  )
  if not status then return end

  local project = p.project(e)
  if not project then return end

  local date = e.today()
  local vars = { title = title, event = event, file_location = file_location or "", status = status, project = project, date = date }

  local fm = "---\n"
    .. "type: presentation\n"
    .. "title: " .. title .. "\n"
    .. "event: " .. event .. "\n"
    .. "file_location: " .. (file_location or "") .. "\n"
    .. "status: " .. status .. "\n"
    .. "project: '[[" .. project .. "/Dashboard]]'\n"
    .. "date: " .. date .. "\n"
    .. "tags:\n"
    .. "  - presentation\n"
    .. "---\n"

  e.write_note("Projects/" .. project .. "/Presentations/" .. title, fm .. "\n" .. e.render(body_template, vars))
end

return M
