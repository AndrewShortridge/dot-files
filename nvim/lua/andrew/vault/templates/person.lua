local M = {}
M.name = "Person Note"

local body_template = [==[
# ${name}

**Role:** ${role}
**Institution:** ${institution}
**Email:** ${email}

---

## Context

> [!info] How do I know this person? What's the working relationship?
>

## Shared Projects

```dataview
LIST
FROM "Projects"
WHERE contains(file.outlinks, this.file.link) AND type = "project-dashboard"
```

> Manual links:
> - [[]]

## Meeting Notes

```dataview
LIST
FROM "Log"
WHERE contains(file.outlinks, this.file.link)
SORT file.name DESC
LIMIT 10
```

## Their Papers / Work

> Literature notes authored by this person

- [[]]

## Feedback Patterns

> [!tip] Recurring themes in their feedback — knowing these saves revision cycles

-

## Preferences & Communication Style

> How do they prefer to work? What do they care about most in a presentation / draft?

-

## Key Conversations & Decisions

| Date | Topic | Outcome |
| ---- | ----- | ------- |
|      |       |         |

## Notes
]==]

function M.run(e, p)
  local name = e.input({ prompt = "Full name" })
  if not name then return end

  local role = e.input({ prompt = "Role / relationship (e.g., PhD Advisor, Collaborator, Committee Member)" })
  if not role then return end

  local institution = e.input({ prompt = "Institution / organization", default = "" })

  local email = e.input({ prompt = "Email (leave blank if unknown)", default = "" })

  local date = e.today()
  local vars = { name = name, role = role, institution = institution or "", email = email or "", date = date }

  local fm = "---\n"
    .. "type: person\n"
    .. "name: " .. name .. "\n"
    .. "role: " .. role .. "\n"
    .. "institution: " .. (institution or "") .. "\n"
    .. "email: " .. (email or "") .. "\n"
    .. "created: " .. date .. "\n"
    .. "tags:\n"
    .. "  - person\n"
    .. "---\n"

  e.write_note("People/" .. name, fm .. "\n" .. e.render(body_template, vars))
end

return M
