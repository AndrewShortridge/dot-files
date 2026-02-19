local M = {}
M.name = "Project Dashboard"

function M.run(e, p)
  local title = e.input({ prompt = "Project name" })
  if not title then return end

  local category = e.select(
    { "Research", "Personal", "Business", "Professional" },
    { prompt = "Category" }
  )
  if not category then return end
  -- Map display to value
  local cat_map = { Research = "research", Personal = "personal", Business = "business", Professional = "professional" }
  local cat_val = cat_map[category] or category:lower()

  local area = e.input({ prompt = "Related area (e.g., Domains/Shock Physics/Shock Physics, Finance — leave blank if none)", default = "" })

  local status = e.select(
    { "Planning", "Active", "In Progress", "On Hold", "Waiting", "Archived" },
    { prompt = "Status" }
  )
  if not status then return end

  local deadline = e.input({ prompt = "Deadline (YYYY-MM-DD or leave blank)", default = "" })

  local target = e.input({ prompt = "Target / deliverable (e.g., journal publication, thesis chapter, tool)" })
  if not target then return end

  local date = e.today()

  local fm = table.concat({
    "---",
    "type: project-dashboard",
    "project: " .. title,
    "category: " .. cat_val,
    "area: '[[" .. (area or "") .. "]]'",
    "status: " .. status,
    "created: " .. date,
    "deadline: " .. (deadline or ""),
    "target: " .. target,
    "collaborators:",
    "tags:",
    "  - project",
    "---",
  }, "\n") .. "\n"

  -- Build body using table.concat to avoid too-many-syntax-levels error
  local b = {}

  b[#b+1] = ""
  b[#b+1] = "# " .. title
  b[#b+1] = ""
  b[#b+1] = "**Category:** `" .. cat_val .. "`"
  b[#b+1] = "**Area:** " .. (area or "")
  b[#b+1] = "**Status:** `" .. status .. "`"
  b[#b+1] = "**Created:** " .. date
  b[#b+1] = "**Deadline:** " .. (deadline or "")
  b[#b+1] = "**Target:** " .. target
  b[#b+1] = ""
  b[#b+1] = "---"
  b[#b+1] = ""
  b[#b+1] = "## Objective"
  b[#b+1] = ""
  b[#b+1] = '> [!abstract] What is the concrete deliverable and definition of "done"?'
  b[#b+1] = ">"
  b[#b+1] = ""
  b[#b+1] = "## Current Focus"
  b[#b+1] = ""
  b[#b+1] = "> [!target] What am I working on right now?"
  b[#b+1] = ">"
  b[#b+1] = ""
  b[#b+1] = "---"
  b[#b+1] = ""
  b[#b+1] = "## Pipeline Status"
  b[#b+1] = ""
  b[#b+1] = "| Stage | Status | Next Action | Blocked By |"
  b[#b+1] = "| ----- | ------ | ----------- | ---------- |"
  b[#b+1] = "|       | \xF0\x9F\x94\xB4 Not Started |  |  |"
  b[#b+1] = "|       | \xF0\x9F\x94\xB4 Not Started |  |  |"
  b[#b+1] = "|       | \xF0\x9F\x94\xB4 Not Started |  |  |"
  b[#b+1] = ""
  b[#b+1] = "> [!tip]- Pipeline stage examples"
  b[#b+1] = "> **Research:** Literature Review \xE2\x86\x92 Simulations \xE2\x86\x92 Analysis \xE2\x86\x92 Cross-comparison \xE2\x86\x92 Writing \xE2\x86\x92 Submission"
  b[#b+1] = "> **Personal:** Planning \xE2\x86\x92 Building \xE2\x86\x92 Testing \xE2\x86\x92 Launch"
  b[#b+1] = "> **Coursework:** Lectures \xE2\x86\x92 Assignments \xE2\x86\x92 Study \xE2\x86\x92 Exam"
  b[#b+1] = ""
  b[#b+1] = "## Key Resources"
  b[#b+1] = ""
  b[#b+1] = "> [!info] Links to subfolders, key documents, external tools, repos"
  b[#b+1] = ""
  b[#b+1] = "- **Subfolder notes:**"
  b[#b+1] = "  - [[" .. title .. "/Simulations/|Simulations]]"
  b[#b+1] = "  - [[" .. title .. "/Analysis/|Analysis]]"
  b[#b+1] = "  - [[" .. title .. "/Meetings/|Meetings]]"
  b[#b+1] = "  - [[" .. title .. "/Findings/|Findings]]"
  b[#b+1] = "  - [[" .. title .. "/Journal/|Journal]]"
  b[#b+1] = "- **HPC path:** ``"
  b[#b+1] = "- **Code repo:** ``"
  b[#b+1] = ""
  b[#b+1] = "---"
  b[#b+1] = ""
  b[#b+1] = "## Task Progress"
  b[#b+1] = ""
  b[#b+1] = '**Progress:** `$=const t=dv.current().file.tasks;const d=t.where(x=>x.completed).length;const total=t.length;dv.span(total>0?d+"/"+total+" ("+Math.round(d/total*100)+"%)":"No tasks yet")`'
  b[#b+1] = ""
  b[#b+1] = "## Task Tracker"
  b[#b+1] = ""
  b[#b+1] = "> [!info] Task format: `**[due:: YYYY-MM-DD]** : [priority:: N] : Task description`"
  b[#b+1] = "> Priority: 1 = today, 2 = 2-4 days, 3 = 7 days, 4 = 30 days, 5 = no deadline"
  b[#b+1] = ""
  b[#b+1] = "### Active"
  b[#b+1] = "- [ ] **[due:: ]** : [priority:: ] :"
  b[#b+1] = ""
  b[#b+1] = "### Backlog"
  b[#b+1] = "- [ ] **[due:: ]** : [priority:: ] :"
  b[#b+1] = ""
  b[#b+1] = "- [x] **[due:: " .. date .. "]** : [priority:: 1] : Project created [completion:: " .. date .. "]"
  b[#b+1] = ""
  b[#b+1] = "### Recently Completed"
  b[#b+1] = ""
  b[#b+1] = "```dataviewjs"
  b[#b+1] = 'const weekAgo = dv.date("today").minus({days: 7});'
  b[#b+1] = 'const projFolder = "Projects/' .. title .. '";'
  b[#b+1] = "const rows = [];"
  b[#b+1] = "const clean = t => t"
  b[#b+1] = '  .replace(/\\*{0,2}\\[\\w+::[^\\]]*\\]\\*{0,2}/g, "")'
  b[#b+1] = '  .replace(/\\[\\[(?:[^\\]|]*\\|)?([^\\]]*)\\]\\]/g, "$1")'
  b[#b+1] = '  .replace(/^\\s*(?::\\s*)+/, "").replace(/(?:\\s*:)+\\s*$/, "").trim();'
  b[#b+1] = ""
  b[#b+1] = [[for (const p of dv.pages('"' + projFolder + '"'))]]
  b[#b+1] = "  for (const t of p.file.tasks.where(t => t.completed && t.completion && t.completion >= weekAgo))"
  b[#b+1] = "    rows.push([dv.fileLink(p.file.path, false, clean(t.text) || t.text), t.completion]);"
  b[#b+1] = ""
  b[#b+1] = [[for (const n of dv.pages('"' + projFolder + '/Tasks"').where(p => p.type === "task" && p.status === "Complete" && p.date_completed && dv.date(p.date_completed) >= weekAgo))]]
  b[#b+1] = "  rows.push([dv.fileLink(n.file.path, false, n.file.name), n.date_completed]);"
  b[#b+1] = ""
  b[#b+1] = "rows.sort((a, b) => b[1] < a[1] ? -1 : b[1] > a[1] ? 1 : 0);"
  b[#b+1] = 'if (rows.length > 0) dv.table(["Task", "Completed"], rows);'
  b[#b+1] = 'else dv.paragraph("No recently completed tasks.");'
  b[#b+1] = "```"
  b[#b+1] = ""
  b[#b+1] = "> [!example]- Archived Tasks"
  b[#b+1] = ">"
  b[#b+1] = "> ```dataviewjs"
  b[#b+1] = '> const weekAgo = dv.date("today").minus({days: 7});'
  b[#b+1] = '> const projFolder = "Projects/' .. title .. '";'
  b[#b+1] = "> const rows = [];"
  b[#b+1] = "> const clean = t => t"
  b[#b+1] = '>   .replace(/\\*{0,2}\\[\\w+::[^\\]]*\\]\\*{0,2}/g, "")'
  b[#b+1] = '>   .replace(/\\[\\[(?:[^\\]|]*\\|)?([^\\]]*)\\]\\]/g, "$1")'
  b[#b+1] = '>   .replace(/^\\s*(?::\\s*)+/, "").replace(/(?:\\s*:)+\\s*$/, "").trim();'
  b[#b+1] = ">"
  b[#b+1] = [[> for (const p of dv.pages('"' + projFolder + '"'))]]
  b[#b+1] = ">   for (const t of p.file.tasks.where(t => t.completed && t.completion && t.completion < weekAgo))"
  b[#b+1] = ">     rows.push([dv.fileLink(p.file.path, false, clean(t.text) || t.text), t.completion]);"
  b[#b+1] = ">"
  b[#b+1] = [[> for (const n of dv.pages('"' + projFolder + '/Tasks"').where(p => p.type === "task" && p.status === "Complete" && p.date_completed && dv.date(p.date_completed) < weekAgo))]]
  b[#b+1] = ">   rows.push([dv.fileLink(n.file.path, false, n.file.name), n.date_completed]);"
  b[#b+1] = ">"
  b[#b+1] = "> rows.sort((a, b) => b[1] < a[1] ? -1 : b[1] > a[1] ? 1 : 0);"
  b[#b+1] = '> if (rows.length > 0) dv.table(["Task", "Completed"], rows);'
  b[#b+1] = '> else dv.paragraph("No archived tasks.");'
  b[#b+1] = "> ```"
  b[#b+1] = ""
  b[#b+1] = "### All Open Tasks"
  b[#b+1] = ""
  b[#b+1] = "```dataviewjs"
  b[#b+1] = 'const projFolder = "Projects/' .. title .. '";'
  b[#b+1] = "const rows = [];"
  b[#b+1] = "const clean = t => t"
  b[#b+1] = '  .replace(/\\*{0,2}\\[\\w+::[^\\]]*\\]\\*{0,2}/g, "")'
  b[#b+1] = '  .replace(/\\[\\[(?:[^\\]|]*\\|)?([^\\]]*)\\]\\]/g, "$1")'
  b[#b+1] = '  .replace(/^\\s*(?::\\s*)+/, "").replace(/(?:\\s*:)+\\s*$/, "").trim();'
  b[#b+1] = ""
  b[#b+1] = [[for (const p of dv.pages('"' + projFolder + '"'))]]
  b[#b+1] = "  if (p.file.name !== dv.current().file.name)"
  b[#b+1] = "    for (const t of p.file.tasks.where(t => !t.completed && t.due && t.priority))"
  b[#b+1] = '      rows.push([dv.fileLink(p.file.path, false, clean(t.text) || t.text), t.due, t.priority, "Open"]);'
  b[#b+1] = ""
  b[#b+1] = [[for (const n of dv.pages('"' + projFolder + '/Tasks"').where(p => p.type === "task" && p.status !== "Complete" && p.status !== "Cancelled" && p.due && p.priority))]]
  b[#b+1] = '  rows.push([dv.fileLink(n.file.path, false, n.file.name), n.due, n.priority, n.status || "\xE2\x80\x94"]);'
  b[#b+1] = ""
  b[#b+1] = "rows.sort((a, b) => {"
  b[#b+1] = '  const pa = typeof a[2] === "number" ? a[2] : 99;'
  b[#b+1] = '  const pb = typeof b[2] === "number" ? b[2] : 99;'
  b[#b+1] = "  if (pa !== pb) return pa - pb;"
  b[#b+1] = '  if (!a[1] || a[1] === "\xE2\x80\x94") return 1;'
  b[#b+1] = '  if (!b[1] || b[1] === "\xE2\x80\x94") return -1;'
  b[#b+1] = "  return a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0;"
  b[#b+1] = "});"
  b[#b+1] = 'if (rows.length > 0) dv.table(["Task", "Due", "Priority", "Status"], rows);'
  b[#b+1] = 'else dv.paragraph("No open tasks.");'
  b[#b+1] = "```"
  b[#b+1] = ""
  b[#b+1] = "> [!example]- Unscheduled Tasks"
  b[#b+1] = ">"
  b[#b+1] = "> ```dataviewjs"
  b[#b+1] = '> const projFolder = "Projects/' .. title .. '";'
  b[#b+1] = "> const rows = [];"
  b[#b+1] = "> const clean = t => t"
  b[#b+1] = '>   .replace(/\\*{0,2}\\[\\w+::[^\\]]*\\]\\*{0,2}/g, "")'
  b[#b+1] = '>   .replace(/\\[\\[(?:[^\\]|]*\\|)?([^\\]]*)\\]\\]/g, "$1")'
  b[#b+1] = '>   .replace(/^\\s*(?::\\s*)+/, "").replace(/(?:\\s*:)+\\s*$/, "").trim();'
  b[#b+1] = ">"
  b[#b+1] = [[> for (const p of dv.pages('"' + projFolder + '"'))]]
  b[#b+1] = ">   if (p.file.name !== dv.current().file.name)"
  b[#b+1] = ">     for (const t of p.file.tasks.where(t => !t.completed && (!t.due || !t.priority)))"
  b[#b+1] = '>       rows.push([dv.fileLink(p.file.path, false, clean(t.text) || t.text), t.due || "\xE2\x80\x94", t.priority || "\xE2\x80\x94"]);'
  b[#b+1] = ">"
  b[#b+1] = [[> for (const n of dv.pages('"' + projFolder + '/Tasks"').where(p => p.type === "task" && p.status !== "Complete" && p.status !== "Cancelled" && (!p.due || !p.priority)))]]
  b[#b+1] = '>   rows.push([dv.fileLink(n.file.path, false, n.file.name), n.due || "\xE2\x80\x94", n.priority || "\xE2\x80\x94"]);'
  b[#b+1] = ">"
  b[#b+1] = '> if (rows.length > 0) dv.table(["Task", "Due", "Priority"], rows);'
  b[#b+1] = '> else dv.paragraph("All tasks have due dates and priorities.");'
  b[#b+1] = "> ```"
  b[#b+1] = ""
  b[#b+1] = "> [!example]- All Task Notes"
  b[#b+1] = ">"
  b[#b+1] = "> ```dataview"
  b[#b+1] = "> TABLE WITHOUT ID"
  b[#b+1] = '>     file.link AS "Task",'
  b[#b+1] = '>     status AS "Status",'
  b[#b+1] = '>     priority AS "Priority",'
  b[#b+1] = '>     due AS "Due",'
  b[#b+1] = '>     date_completed AS "Completed"'
  b[#b+1] = '> FROM "Projects/' .. title .. '/Tasks"'
  b[#b+1] = '> WHERE type = "task"'
  b[#b+1] = "> SORT date_completed DESC, priority ASC"
  b[#b+1] = "> ```"
  b[#b+1] = ""
  b[#b+1] = "---"
  b[#b+1] = ""
  b[#b+1] = "## Collaborators & Contacts"
  b[#b+1] = ""
  b[#b+1] = "- [[]]"
  b[#b+1] = ""
  b[#b+1] = "## Decision Log"
  b[#b+1] = ""
  b[#b+1] = "> [!info] Key decisions and their rationale"
  b[#b+1] = ""
  b[#b+1] = "| Date | Decision | Rationale | Revisit? |"
  b[#b+1] = "| ---- | -------- | --------- | -------- |"
  b[#b+1] = "|      |          |           |          |"
  b[#b+1] = ""
  b[#b+1] = "---"
  b[#b+1] = ""
  b[#b+1] = "## Related Knowledge Base"
  b[#b+1] = ""
  b[#b+1] = "> [!example]+ Tools & Methodology References"
  b[#b+1] = ">"
  b[#b+1] = "> ```dataview"
  b[#b+1] = "> TABLE WITHOUT ID"
  b[#b+1] = '>     file.link AS "Note",'
  b[#b+1] = '>     type AS "Type",'
  b[#b+1] = '>     join(file.tags, ", ") AS "Tags"'
  b[#b+1] = '> FROM "Reference" OR "Areas"'
  b[#b+1] = "> WHERE related-projects AND contains(string(related-projects), this.file.name)"
  b[#b+1] = "> SORT type ASC, file.name ASC"
  b[#b+1] = "> ```"
  b[#b+1] = ""
  b[#b+1] = "> [!abstract]+ Related Literature"
  b[#b+1] = ">"
  b[#b+1] = "> ```dataview"
  b[#b+1] = "> TABLE WITHOUT ID"
  b[#b+1] = '>     file.link AS "Paper",'
  b[#b+1] = '>     dateformat(file.ctime, "yyyy-MM-dd") AS "Added"'
  b[#b+1] = '> FROM "Library"'
  b[#b+1] = "> WHERE related-projects AND contains(string(related-projects), this.file.name)"
  b[#b+1] = "> SORT file.ctime DESC"
  b[#b+1] = "> ```"
  b[#b+1] = ""
  b[#b+1] = "---"
  b[#b+1] = ""
  b[#b+1] = "## Sub-Notes"
  b[#b+1] = ""
  b[#b+1] = "> [!note]+ Simulations"
  b[#b+1] = ">"
  b[#b+1] = "> ```dataview"
  b[#b+1] = "> TABLE WITHOUT ID"
  b[#b+1] = '>     file.link AS "Simulation",'
  b[#b+1] = '>     status AS "Status",'
  b[#b+1] = '>     date_started AS "Started"'
  b[#b+1] = '> FROM "Projects/' .. title .. '/Simulations"'
  b[#b+1] = '> WHERE type = "simulation"'
  b[#b+1] = "> SORT date_started DESC"
  b[#b+1] = "> ```"
  b[#b+1] = ""
  b[#b+1] = "> [!note]+ Analysis"
  b[#b+1] = ">"
  b[#b+1] = "> ```dataview"
  b[#b+1] = "> TABLE WITHOUT ID"
  b[#b+1] = '>     file.link AS "Analysis",'
  b[#b+1] = '>     status AS "Status",'
  b[#b+1] = '>     date_created AS "Created"'
  b[#b+1] = '> FROM "Projects/' .. title .. '/Analysis"'
  b[#b+1] = '> WHERE type = "analysis"'
  b[#b+1] = "> SORT date_created DESC"
  b[#b+1] = "> ```"
  b[#b+1] = ""
  b[#b+1] = "> [!note]+ Meetings"
  b[#b+1] = ">"
  b[#b+1] = "> ```dataview"
  b[#b+1] = "> TABLE WITHOUT ID"
  b[#b+1] = '>     file.link AS "Meeting",'
  b[#b+1] = '>     date AS "Date",'
  b[#b+1] = '>     attendees AS "Attendees"'
  b[#b+1] = '> FROM "Projects/' .. title .. '/Meetings"'
  b[#b+1] = '> WHERE type = "meeting"'
  b[#b+1] = "> SORT date DESC"
  b[#b+1] = "> ```"
  b[#b+1] = ""
  b[#b+1] = "> [!note]+ Findings"
  b[#b+1] = ">"
  b[#b+1] = "> ```dataview"
  b[#b+1] = "> TABLE WITHOUT ID"
  b[#b+1] = '>     file.link AS "Finding",'
  b[#b+1] = '>     status AS "Status",'
  b[#b+1] = '>     date_created AS "Created"'
  b[#b+1] = '> FROM "Projects/' .. title .. '/Findings"'
  b[#b+1] = '> WHERE type = "finding"'
  b[#b+1] = "> SORT date_created DESC"
  b[#b+1] = "> ```"
  b[#b+1] = ""
  b[#b+1] = "> [!note]+ Journal"
  b[#b+1] = ">"
  b[#b+1] = "> ```dataview"
  b[#b+1] = "> TABLE WITHOUT ID"
  b[#b+1] = '>     file.link AS "Entry",'
  b[#b+1] = '>     date_created AS "Date"'
  b[#b+1] = '> FROM "Projects/' .. title .. '/Journal"'
  b[#b+1] = '> WHERE type = "journal-entry"'
  b[#b+1] = "> SORT date_created DESC"
  b[#b+1] = "> ```"
  b[#b+1] = ""
  b[#b+1] = "---"
  b[#b+1] = ""
  b[#b+1] = "## Backlinks"
  b[#b+1] = ""
  b[#b+1] = "```dataview"
  b[#b+1] = "LIST"
  b[#b+1] = "FROM [[]]"
  b[#b+1] = "WHERE file.name != this.file.name"
  b[#b+1] = "SORT file.mtime DESC"
  b[#b+1] = "```"
  b[#b+1] = ""
  b[#b+1] = "---"
  b[#b+1] = ""
  b[#b+1] = "## Log"
  b[#b+1] = ""
  b[#b+1] = "### " .. date
  b[#b+1] = "- Project created"
  b[#b+1] = ""
  b[#b+1] = "## Notes"

  local body = table.concat(b, "\n")

  e.write_note("Projects/" .. title .. "/Dashboard", fm .. body)
end

return M
