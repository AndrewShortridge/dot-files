local M = {}
M.name = "Changelog"

local body_template = [==[
# Changelog: ${from_version} → ${to_version}

**Project:** [[${project}/Dashboard]]
**Date:** ${date_long}
**Author:** ${author}

---

## Summary

> [!abstract] One-line summary of what this version accomplishes
>

## Major Changes

### Section-Level Modifications

| Section | Change Type | Description |
| ------- | ----------- | ----------- |
|         | Added / Revised / Removed / Rewritten |             |
|         |             |             |
|         |             |             |

### Figure Changes

| Figure | Action | Description |
| ------ | ------ | ----------- |
|        | Added / Updated / Removed |             |
|        |        |             |

## Minor Changes

-

## Motivation

> [!question] Why were these changes made?
> Sources: advisor feedback, reviewer comments, new data, etc.

-

## Data Dependencies

> [!info] Which simulation runs or analyses motivated or enabled these changes?

- [[]]

## Open Issues Remaining

- [ ]

## Links

- **Previous version:** [[${from_version}]]
- **New version:** [[${to_version}]]
- **Related analysis:** [[]]
]==]

function M.run(e, p)
  local title = e.input({ prompt = "Changelog title (e.g., Draft v1 to Draft v2)" })
  if not title then return end

  local from_version = e.input({ prompt = "Previous version (e.g., Draft v1)" })
  if not from_version then return end

  local to_version = e.input({ prompt = "New version (e.g., Draft v2)" })
  if not to_version then return end

  local author = e.input({ prompt = "Author name" })
  if not author then return end

  local project = p.project(e)
  if not project then return end

  local date = e.today()
  local vars = {
    title = title, from_version = from_version, to_version = to_version,
    author = author, project = project, date = date, date_long = e.today_long(),
  }

  local fm = "---\n"
    .. "type: changelog\n"
    .. "from_version: " .. from_version .. "\n"
    .. "to_version: " .. to_version .. "\n"
    .. "author: " .. author .. "\n"
    .. "project: '[[" .. project .. "/Dashboard]]'\n"
    .. "date: " .. date .. "\n"
    .. "tags:\n"
    .. "  - changelog\n"
    .. "---\n"

  e.write_note("Projects/" .. project .. "/Changelogs/" .. title, fm .. "\n" .. e.render(body_template, vars))
end

return M
