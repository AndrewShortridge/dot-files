-- Run with: nvim --headless -u NONE -l tests/run_all.lua
--
-- Aggregate test runner. Discovers every tests/*_spec.lua plus
-- tests/test_vault_fixes.lua and runs each one in its OWN
-- `nvim --headless -u NONE -l <spec>` subprocess (each spec calls
-- os.exit/cquit itself, so they must not share a process). Captures
-- each spec's "N passed, M failed" summary, prints a per-spec line and
-- an aggregate total, then exits non-zero if any spec failed or errored.

local function script_dir()
  local src = debug.getinfo(1, "S").source
  local path = src:sub(1, 1) == "@" and src:sub(2) or src
  return path:match("^(.*)[/\\][^/\\]*$") or "."
end

local tests_dir = script_dir()

-- Discover spec files.
local files = {}
local seen = {}
local function add(path)
  if path and path ~= "" and not seen[path] then
    seen[path] = true
    files[#files + 1] = path
  end
end

for _, path in ipairs(vim.fn.glob(tests_dir .. "/*_spec.lua", true, true)) do
  add(path)
end
local fixes = tests_dir .. "/test_vault_fixes.lua"
if vim.fn.filereadable(fixes) == 1 then
  add(fixes)
end
table.sort(files)

if #files == 0 then
  print("No spec files found in " .. tests_dir)
  os.exit(1)
end

local nvim = vim.v.progpath or "nvim"

local total_passed = 0
local total_failed = 0
local errored_specs = 0
local any_failure = false

print(string.format("Running %d spec(s)\n", #files))

for _, file in ipairs(files) do
  local name = vim.fn.fnamemodify(file, ":t")
  local cmd = { nvim, "--headless", "-u", "NONE", "-l", file }
  local out = vim.fn.system(cmd)
  local code = vim.v.shell_error

  -- Parse the last "N passed, M failed" summary the spec printed.
  local passed, failed
  for p, f in tostring(out):gmatch("(%d+)%s+passed,%s+(%d+)%s+failed") do
    passed, failed = tonumber(p), tonumber(f)
  end

  if passed then
    total_passed = total_passed + passed
    total_failed = total_failed + failed
    local ok = failed == 0 and code == 0
    if not ok then
      any_failure = true
    end
    print(
      string.format("%-32s %s  %d passed, %d failed", name, ok and "PASS" or "FAIL", passed, failed)
    )
  else
    -- No summary parsed: the spec errored before reporting (or crashed).
    errored_specs = errored_specs + 1
    any_failure = true
    print(string.format("%-32s ERROR (exit %s, no summary)", name, tostring(code)))
    local trimmed = tostring(out):gsub("%s+$", "")
    if trimmed ~= "" then
      for line in (trimmed .. "\n"):gmatch("(.-)\n") do
        print("    " .. line)
      end
    end
  end
end

print(
  string.format(
    "\nTotal: %d passed, %d failed across %d spec(s)%s",
    total_passed,
    total_failed,
    #files,
    errored_specs > 0 and string.format(" (%d errored)", errored_specs) or ""
  )
)

os.exit(any_failure and 1 or 0)
