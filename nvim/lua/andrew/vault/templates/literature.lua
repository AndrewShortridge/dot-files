local M = {}
M.name = "Literature Note"

local body_template = [==[
# ${authors} (${year}) — ${title}

> [!cite] Citation
> ${authors}, "${title}," *${journal}*, ${year}.
> DOI: ${doi}

---

## Core Claim / Thesis

> [!summary]
>

## Key Results

1.

## Methodology

- **Simulation / Experimental approach:**
- **Potential / Material:**
- **Key parameters:**
- **Boundary conditions:**

## Relevance to My Work

> [!important] Why does this paper matter for my research?
>

### Points of Agreement

-

### Points of Difference

-

### Gaps / Opportunities

> [!tip] What didn't they do that I can?
>

## Figures Worth Referencing

| Their Figure | What It Shows | Comparison to My Work |
| ------------ | ------------- | --------------------- |
|              |               |                       |

## Methods Worth Noting

> [!warning] Methodological choices to be aware of (thermostat, boundary conditions, filtering, etc.)
>

## Questions This Raises

- [ ]

## Quotes / Key Passages

>

## Related Papers

- [[]]

## Notes
]==]

function M.run(e, p)
  local title = e.input({ prompt = "Paper title" })
  if not title then return end

  local authors = e.input({ prompt = "Authors (e.g., Durand & Soulard)" })
  if not authors then return end

  local year = e.input({ prompt = "Publication year" })
  if not year then return end

  local journal = e.input({ prompt = "Journal name" })
  if not journal then return end

  local doi = e.input({ prompt = "DOI (leave blank if unknown)", default = "" })

  local date = e.today()
  local vars = { title = title, authors = authors, year = year, journal = journal, doi = doi or "", date = date }

  local fm = "---\n"
    .. "type: literature\n"
    .. 'title: "' .. title .. '"\n'
    .. 'authors: "' .. authors .. '"\n'
    .. "year: " .. year .. "\n"
    .. 'journal: "' .. journal .. '"\n'
    .. "doi: " .. (doi or "") .. "\n"
    .. "date_read: " .. date .. "\n"
    .. "rating: /5\n"
    .. "tags:\n"
    .. "  - lit\n"
    .. "---\n"

  -- Sanitize title for filename
  local safe_title = title:gsub(":", " -"):gsub("/", "-"):gsub("[%*%?|]", "")

  e.write_note("Library/" .. safe_title, fm .. "\n" .. e.render(body_template, vars))
end

return M
