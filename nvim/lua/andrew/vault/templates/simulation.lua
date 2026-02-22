local M = {}

M.name = "Simulation Note"

function M.run(e, p)
  local title = e.input({ prompt = "Simulation note title (e.g., voronoi_cu_50nm_001)" })
  if not title then return end

  local software = e.select({ "LAMMPS", "GEMMS" }, { prompt = "Select simulation software" })
  if not software then return end

  local loading_condition = ""
  local uses_laser = false
  if software == "GEMMS" then
    loading_condition = e.select(
      { "Piston Shock", "Laser Shock (QCGD-TTM)", "Laser Deposition (Continuous)", "Other" },
      { prompt = "Select loading condition" }
    )
    if not loading_condition then return end
    uses_laser = loading_condition:find("Laser") ~= nil
  end

  local run_id = e.input({ prompt = "Run ID (e.g., voronoi_cu_50nm_001)" })
  if not run_id then return end

  local campaign = e.input({ prompt = "Campaign name (e.g., Density Method Comparison)" })

  local status = e.select(
    { "Queued", "Running", "Complete", "Failed", "Needs Rerun" },
    { prompt = "Simulation status" }
  )

  local project = p.project(e)
  if not project then return end

  local hpc_path = e.input({ prompt = "HPC path (e.g., /scratch/andrew/runs/...)" })

  local script_name = nil
  if software == "LAMMPS" then
    script_name = e.input({ prompt = "LAMMPS input script filename", default = "in.lammps" })
  end

  local date = e.today()

  -- Build frontmatter
  local fm = "---\n"
    .. "type: simulation\n"
    .. "software: " .. software .. "\n"
    .. "run_id: " .. (run_id or "") .. "\n"
    .. "campaign: " .. (campaign or "") .. "\n"
    .. "status: " .. (status or "") .. "\n"
    .. "parent-project: '[[Projects/" .. project .. "/Dashboard|" .. project .. "]]'\n"
    .. "date_started: " .. date .. "\n"
    .. "date_completed:\n"
    .. "hpc_path: " .. (hpc_path or "") .. "\n"
  if software == "GEMMS" then
    fm = fm .. "loading_condition: " .. loading_condition .. "\n"
  end
  fm = fm
    .. "tags:\n"
    .. "  - simulation\n"
    .. "---\n"

  -- Build body
  local body = "\n# " .. (run_id or title) .. "\n\n"
    .. "**Software:** " .. software .. "\n"
  if software == "GEMMS" then
    body = body .. "**Loading Condition:** " .. loading_condition .. "\n"
  end
  body = body
    .. "**Campaign:** [[" .. (campaign or "") .. "]]\n"
    .. "**Status:** " .. (status or "") .. "\n"
    .. "**Project:** [[Projects/" .. project .. "/Dashboard|" .. project .. "]]\n"
    .. "**Started:** " .. date .. "\n"
    .. "**HPC Path:** " .. (hpc_path or "") .. "\n\n"
    .. "---\n\n"
    .. "## Purpose\n\n"
    .. "> [!abstract] What question is this run trying to answer?\n>\n\n"
    .. "## Parameters\n\n"

  if software == "LAMMPS" then
    body = body
      .. "| Parameter | Value |\n"
      .. "| --------- | ----- |\n"
      .. "| Software | LAMMPS |\n"
      .. "| Potential |  |\n"
      .. "| Material |  |\n"
      .. "| Piston velocity |  |\n"
      .. "| Sample geometry |  |\n"
      .. "| Domain size |  |\n"
      .. "| Timesteps |  |\n"
      .. "| Timestep size |  |\n"
      .. "| Thermostat |  |\n"
      .. "| Boundary conditions |  |\n"
      .. "| Ensemble |  |\n"
  else
    body = body
      .. "| Parameter | Value |\n"
      .. "| --------- | ----- |\n"
      .. "| Software | GEMMS |\n"
      .. "| QCGD level |  |\n"
      .. "| Potential |  |\n"
      .. "| Material |  |\n"
      .. "| Loading condition | " .. loading_condition .. " |\n"
      .. "| Sample geometry |  |\n"
      .. "| Domain size |  |\n"
      .. "| Timestep |  |\n"
      .. "| Thermostat |  |\n"
      .. "| Barostat |  |\n"
      .. "| Boundary conditions |  |\n"
  end

  body = body .. "\n"

  if loading_condition == "Piston Shock" then
    body = body
      .. "### Piston Parameters\n\n"
      .. "| Parameter | Value |\n"
      .. "| --------- | ----- |\n"
      .. "| Piston velocity |  |\n"
      .. "| Piston thickness |  |\n"
      .. "| Pulse duration |  |\n\n"
  end

  if uses_laser then
    body = body
      .. "### Laser Parameters\n\n"
      .. "| Parameter | Value |\n"
      .. "| --------- | ----- |\n"
      .. "| Beam profile |  |\n"
      .. "| Pulse duration |  |\n"
      .. "| Laser energy |  |\n"
      .. "| Spot size / diameter |  |\n"
      .. "| Wavelength |  |\n"
      .. "| Absorption depth |  |\n\n"
  end

  if loading_condition == "Laser Shock (QCGD-TTM)" then
    body = body
      .. "### TTM Parameters\n\n"
      .. "| Parameter | Value |\n"
      .. "| --------- | ----- |\n"
      .. "| Electron-phonon coupling (G) |  |\n"
      .. "| Electron thermal conductivity |  |\n"
      .. "| Electron heat capacity |  |\n"
      .. "| Lattice heat capacity |  |\n"
      .. "| TTM grid resolution |  |\n\n"
  end

  body = body .. "## Input Files\n\n"
  if software == "LAMMPS" then
    body = body
      .. "- **Script:** " .. (script_name or "in.lammps") .. "\n"
      .. "- **Data file:**\n"
      .. "- **Potential file:**\n"
  else
    body = body
      .. "- **Input deck:**\n"
      .. "- **Data file:**\n"
      .. "- **Potential file:**\n"
  end

  body = body .. "\n## Methods Used\n\n"
  if software == "GEMMS" then
    body = body .. "- [[Quasi-Coarse Grained Dynamics (QCGD)]]\n"
    if loading_condition == "Laser Shock (QCGD-TTM)" then
      body = body .. "- [[Two-Temperature Model (TTM)]]\n"
    end
  else
    body = body .. "- [[]]\n"
  end

  body = body .. [==[

## Results

> [!success] Key findings

### Summary



### Key Metrics

| Metric | Value | Notes |
| ------ | ----- | ----- |
|        |       |       |

### Figures

> Embed key output plots here

## Comparison to Previous Runs

| Run | Key Difference | Result Difference |
| --- | -------------- | ----------------- |
| [[]] |               |                   |

## Issues / Troubleshooting

> [!bug] Problems encountered during this run

-

## Feeds Into

> [!info] Where do these results go?

- **Draft:** [[]]
- **Figure(s):**
- **Analysis:** [[]]

## Post-Processing

- [ ] Data extracted
- [ ] Plots generated
- [ ] Results documented
- [ ] Compared against previous runs

## Notes
]==]

  e.write_note("Projects/" .. project .. "/Simulations/" .. title, fm .. body)
end

return M
