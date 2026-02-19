local M = {}
M.name = "Domain MOC"

local body_template = [==[
# ${title}

> [!abstract] What is this domain?
>

---

## Core Concepts

> [!info] Foundational ideas and principles — these are your durable concept notes

- [[]]

## Sub-Domains

> Narrower areas within this domain, each potentially its own MOC

- [[]]

## Active Projects

```dataview
LIST
FROM "Projects"
WHERE type = "project-dashboard" AND status != "Archived" AND contains(file.outlinks, this.file.link)
```

> Manual links:
> - [[]]

## Completed Projects

```dataview
LIST
FROM "Projects"
WHERE type = "project-dashboard" AND status = "Archived" AND contains(file.outlinks, this.file.link)
```

## Key Methods

```dataview
LIST
FROM "Methods"
WHERE contains(file.outlinks, this.file.link)
SORT file.name ASC
```

> Manual links:
> - [[]]

## Key Literature

```dataview
LIST
FROM "Library"
WHERE contains(file.tags, this.file.tags)
SORT year DESC
```

> Manual links:
> - [[]]

## Key People

- [[]]

## Open Questions

> [!question] Big-picture questions that span individual projects

1.

## Emerging Ideas

> [!tip] Ideas that haven't crystallized into concept notes yet

-

## Resources

> External links, textbooks, course materials, reference documents

-

## Timeline / Milestones

> [!calendar] Significant events in your engagement with this domain

| Date | Event |
| ---- | ----- |
|      |       |

## Notes
]==]

function M.run(e, p)
  local title = e.input({ prompt = "Domain name (e.g., Shock Physics)" })
  if not title then return end

  local date = e.today()
  local vars = { title = title, date = date }

  local fm = "---\n"
    .. "type: domain\n"
    .. "domain: " .. title .. "\n"
    .. "created: " .. date .. "\n"
    .. "tags:\n"
    .. "  - domain\n"
    .. "  - MOC\n"
    .. "---\n"

  e.write_note("Domains/" .. title .. "/" .. title, fm .. "\n" .. e.render(body_template, vars))
end

return M
