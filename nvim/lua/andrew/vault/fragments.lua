local engine = require("andrew.vault.engine")

local M = {}

-- =============================================================================
-- Template Fragments
-- =============================================================================
-- Insert template fragments into existing notes at the cursor position.
-- Unlike full templates (which create new files), fragments are snippets of
-- structured content injected into the current buffer.

--- Available fragments. Each has: name, desc, build(engine) -> string[]
local fragments = {
  {
    name = "Meeting Section",
    desc = "Attendees, agenda, discussion, action items",
    build = function(e)
      local date = e.today()
      return {
        "",
        "## Meeting — " .. date,
        "",
        "**Attendees:** ",
        "",
        "### Agenda",
        "",
        "1. ",
        "",
        "### Discussion Notes",
        "",
        "- ",
        "",
        "### Action Items",
        "",
        "- [ ] ",
        "",
        "### Decisions",
        "",
        "- ",
        "",
      }
    end,
  },
  {
    name = "Task Section",
    desc = "Task list with due dates and priorities",
    build = function(e)
      return {
        "",
        "## Tasks",
        "",
        "- [ ] [due:: ] [priority:: ] ",
        "- [ ] [due:: ] [priority:: ] ",
        "- [ ] [due:: ] [priority:: ] ",
        "",
      }
    end,
  },
  {
    name = "Dataview Table",
    desc = "Dataview TABLE query block",
    build = function()
      return {
        "",
        "```dataview",
        "TABLE status, priority, due",
        'FROM "Projects"',
        'WHERE status != "Complete"',
        "SORT priority ASC",
        "```",
        "",
      }
    end,
  },
  {
    name = "Dataview Task Query",
    desc = "Dataview TASK query block",
    build = function()
      return {
        "",
        "```dataview",
        'TASK FROM "Projects"',
        "WHERE !completed",
        "SORT due ASC",
        "```",
        "",
      }
    end,
  },
  {
    name = "DataviewJS Block",
    desc = "DataviewJS code block with scaffold",
    build = function()
      return {
        "",
        "```dataviewjs",
        'const pages = dv.pages(\'"Projects"\')',
        "  .where(p => p.status === \"Active\")",
        '  .sort(p => p.file.name, "asc");',
        "",
        'dv.table(["Name", "Status"], pages.map(p => [p.file.link, p.status]));',
        "```",
        "",
      }
    end,
  },
  {
    name = "Progress Table",
    desc = "Project progress tracking table",
    build = function()
      return {
        "",
        "## Progress",
        "",
        "| Milestone | Status | Target Date | Notes |",
        "| --------- | ------ | ----------- | ----- |",
        "|           |        |             |       |",
        "",
      }
    end,
  },
  {
    name = "Literature Summary",
    desc = "Key findings, methods, relevance sections",
    build = function()
      return {
        "",
        "## Key Findings",
        "",
        "- ",
        "",
        "## Methodology",
        "",
        "- ",
        "",
        "## Relevance to My Work",
        "",
        "> [!tip] How does this connect to current projects?",
        "",
        "- ",
        "",
      }
    end,
  },
  {
    name = "Decision Log",
    desc = "Decision record with context and rationale",
    build = function(e)
      local date = e.today()
      return {
        "",
        "## Decision — " .. date,
        "",
        "**Context:** ",
        "",
        "**Options Considered:**",
        "",
        "1. ",
        "2. ",
        "3. ",
        "",
        "**Decision:** ",
        "",
        "**Rationale:** ",
        "",
        "> [!warning] Risks / Trade-offs",
        "> ",
        "",
      }
    end,
  },
  {
    name = "Daily Work Block",
    desc = "Time-stamped work log entry",
    build = function()
      local time = os.date("%H:%M")
      return {
        "",
        "- **" .. time .. " - __:__** | ",
        "",
      }
    end,
  },
  {
    name = "Simulation Parameters",
    desc = "Parameter table for a simulation run",
    build = function()
      return {
        "",
        "## Simulation Parameters",
        "",
        "| Parameter | Value | Units | Notes |",
        "| --------- | ----- | ----- | ----- |",
        "|           |       |       |       |",
        "",
        "### Initial Conditions",
        "",
        "- ",
        "",
        "### Boundary Conditions",
        "",
        "- ",
        "",
      }
    end,
  },
  {
    name = "Areas Check-In",
    desc = "Quick health check on life areas",
    build = function()
      return {
        "",
        "## Areas Check-In",
        "",
        "> [!check] Quick health check on each life area",
        "",
        "| Area | Status | Action Needed? |",
        "| ---- | ------ | -------------- |",
        "| [[Finance]] | \xF0\x9F\x9F\xA2 / \xF0\x9F\x9F\xA1 / \xF0\x9F\x94\xB4 |  |",
        "| [[Health & Fitness]] | \xF0\x9F\x9F\xA2 / \xF0\x9F\x9F\xA1 / \xF0\x9F\x94\xB4 |  |",
        "| [[Vehicles]] | \xF0\x9F\x9F\xA2 / \xF0\x9F\x9F\xA1 / \xF0\x9F\x94\xB4 |  |",
        "| [[Home]] | \xF0\x9F\x9F\xA2 / \xF0\x9F\x9F\xA1 / \xF0\x9F\x94\xB4 |  |",
        "| [[Career]] | \xF0\x9F\x9F\xA2 / \xF0\x9F\x9F\xA1 / \xF0\x9F\x94\xB4 |  |",
        "",
      }
    end,
  },
  {
    name = "Callout Block",
    desc = "Admonition / callout with type selection",
    build = function(e)
      local types = { "NOTE", "TIP", "WARNING", "IMPORTANT", "CAUTION", "INFO", "TODO", "EXAMPLE", "QUESTION", "ABSTRACT", "BUG", "SUCCESS", "FAILURE", "DANGER", "QUOTE" }
      local choice = e.select(types, { prompt = "Callout type" })
      if not choice then
        return nil
      end
      return {
        "",
        "> [!" .. choice .. "] ",
        "> ",
        "",
      }
    end,
  },
}

--- Show a picker of available fragments and insert the selected one at cursor.
function M.insert_fragment()
  engine.run(function()
    local names = {}
    local desc_map = {}
    for _, f in ipairs(fragments) do
      names[#names + 1] = f.name
      desc_map[f.name] = f.desc
    end

    local choice = engine.select(names, {
      prompt = "Insert fragment",
      format_item = function(item)
        return item .. "  —  " .. (desc_map[item] or "")
      end,
    })
    if not choice then
      return
    end

    for _, f in ipairs(fragments) do
      if f.name == choice then
        local lines = f.build(engine)
        if not lines then
          return
        end
        -- Insert at cursor position
        local row = vim.api.nvim_win_get_cursor(0)[1]
        vim.api.nvim_buf_set_lines(0, row, row, false, lines)
        -- Move cursor to first non-empty inserted line
        for idx, line in ipairs(lines) do
          if line ~= "" then
            vim.api.nvim_win_set_cursor(0, { row + idx, #line })
            break
          end
        end
        vim.notify("Inserted: " .. f.name, vim.log.levels.INFO)
        return
      end
    end
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("VaultInsertFragment", function()
    M.insert_fragment()
  end, { desc = "Insert a template fragment at cursor" })

  local group = vim.api.nvim_create_augroup("VaultFragments", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "<leader>vI", function()
        M.insert_fragment()
      end, { buffer = ev.buf, desc = "Vault: insert fragment", silent = true })
    end,
  })
end

return M
