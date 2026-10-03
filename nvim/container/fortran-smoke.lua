-- container/fortran-smoke.lua -- headless smoke test for the Fortran stack.
--
-- Runs the REAL config (init.lua, lazy.nvim, the ft-gated lspconfig spec) and
-- asks the in-process `fortran-extras` server (lua/andrew/fortran/lsp.lua)
-- for hover on an MPI routine, hover on an OpenMP directive, and completion
-- of an MPI prefix. No network; fortls is neither required nor consulted.
--
-- The %test section of nvim.def runs it against the baked image, and it is
-- shipped at /opt/nvim/fortran-smoke.lua so the same check can be repeated on
-- the cluster:
--
--   apptainer exec nvim.sif nvim --headless -l /opt/nvim/fortran-smoke.lua
--
-- On a workstation:  nvim --headless -l container/fortran-smoke.lua
--
-- Do NOT pass -u: `nvim -l` forces 'loadplugins' off and lazy.setup() then
-- registers nothing; the script undoes that itself before sourcing init.lua.
--
-- Prints  OK: fortran-extras hover(MPI)=<n chars> hover(OMP)=<n chars> completion(MPI_Al)=<count> items
-- and exits 0, or  FAIL: <reason>  and exits non-zero (:cq).

local CLIENT = "fortran-extras"

local function fail(reason)
  io.stdout:write("FAIL: " .. tostring(reason) .. "\n")
  io.stdout:flush()
  vim.cmd("cq")
end

-- ---------------------------------------------------------------------------
-- 1. Bootstrap the real config.
--
-- `nvim -l` sources no init.lua and forces 'loadplugins' off; lazy.nvim's
-- setup() returns before registering a single plugin when that option is off,
-- so both must be undone here before init.lua is sourced. stdpath("config")
-- honours $XDG_CONFIG_HOME, which is how the container points at
-- /opt/nvim/config.
-- ---------------------------------------------------------------------------
local config_dir = vim.fn.stdpath("config")
local init = config_dir .. "/init.lua"
if vim.g.lazy_did_setup then
  if not vim.o.loadplugins then
    fail("config already sourced with 'loadplugins' off (was -u given?); run as: nvim --headless -l " .. arg[0])
  end
else
  if vim.fn.filereadable(init) ~= 1 then
    fail("no init.lua at " .. init .. " (XDG_CONFIG_HOME=" .. tostring(vim.env.XDG_CONFIG_HOME) .. ")")
  end
  vim.o.loadplugins = true
  local ok, err = pcall(dofile, init)
  if not ok then
    fail("init.lua raised: " .. tostring(err))
  end
end
-- VeryLazy never fires under --headless; ~14 plugins hang off it.
pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "VeryLazy" })

-- ---------------------------------------------------------------------------
-- 2. A Fortran buffer. Named under a fresh temp dir so root detection has a
--    directory to work from; nothing in it is ever written to the repo.
-- ---------------------------------------------------------------------------
local src = {
  "program probe",
  "  use mpi",
  "  implicit none",
  "  integer :: i, ierr, buf(4)",
  "  real :: x(100)",
  "  call MPI_Init(ierr)",
  "  call MPI_Send(buf, 4, MPI_INTEGER, 1, 0, MPI_COMM_WORLD, ierr)",
  "  !$omp parallel do private(i)",
  "  do i = 1, 100",
  "    x(i) = real(i)",
  "  end do",
  "  !$omp end parallel do",
  "  call MPI_Finalize(ierr)",
  "end program probe",
}
local SEND_LINE, OMP_LINE = 7, 8 -- 1-based

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local path = dir .. "/probe.f90"
vim.fn.writefile(src, path)

local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(buf, path)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, src)
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].modified = false
-- Setting the filetype fires FileType: lazy loads the lspconfig spec, whose
-- config() calls require("andrew.fortran").setup() -> fortran.lsp.setup(),
-- which attaches fortran-extras to every open Fortran buffer.
vim.bo[buf].filetype = "fortran"

-- ---------------------------------------------------------------------------
-- 3. Wait for fortran-extras to attach and initialise.
-- ---------------------------------------------------------------------------
local function extras_client()
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    if c.name == CLIENT then
      return c
    end
  end
  return nil
end

local attached = vim.wait(15000, function()
  local c = extras_client()
  return c ~= nil and c.initialized == true
end, 50)
if not attached then
  local names = {}
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    names[#names + 1] = c.name
  end
  fail(("no client named %q attached to the buffer within 15s (attached: %s; andrew.fortran loaded: %s)")
    :format(CLIENT, #names > 0 and table.concat(names, ",") or "none", tostring(package.loaded["andrew.fortran"] ~= nil)))
end
local client = extras_client()
if client.offset_encoding ~= "utf-8" then
  fail("expected utf-8 offset encoding, got " .. tostring(client.offset_encoding))
end

-- ---------------------------------------------------------------------------
-- Request helpers.
--
-- The request goes to the fortran-extras client ALONE (Client:request_sync,
-- nvim 0.11+). vim.lsp.buf_request_sync would fan out to every attached
-- client and block until the slowest replies -- and when fortls happens to be
-- on PATH it attaches too, and a cold fortls can take longer than any sane
-- timeout on its first hover, turning a healthy fortran-extras into a false
-- FAIL. This probe is about fortran-extras; fortls is neither required nor
-- consulted.
-- ---------------------------------------------------------------------------

--- Position params for the cursor placed at (lnum, col) -- 1-based line,
--- 1-based byte column -- using the client's own encoding.
local function params_at(lnum, col)
  vim.api.nvim_win_set_cursor(0, { lnum, col - 1 })
  return vim.lsp.util.make_position_params(0, client.offset_encoding)
end

--- Send `method` to fortran-extras and return its result (or nil, reason).
local function ask(method, params, label)
  local reply, err = client:request_sync(method, params, 10000, buf)
  if reply == nil then
    return nil, ("%s: %s request failed: %s"):format(label, method, tostring(err))
  end
  if reply.err then
    return nil, ("%s: %s returned an error: %s"):format(label, method, vim.inspect(reply.err))
  end
  return reply.result
end

--- Flatten hover contents to one string.
local function hover_text(result)
  if type(result) ~= "table" or result.contents == nil then
    return ""
  end
  local c = result.contents
  if type(c) == "string" then
    return c
  end
  if type(c) == "table" and c.value then
    return tostring(c.value)
  end
  if type(c) == "table" then
    local parts = {}
    for _, item in ipairs(c) do
      parts[#parts + 1] = type(item) == "table" and tostring(item.value or "") or tostring(item)
    end
    return table.concat(parts, "\n")
  end
  return ""
end

-- ---------------------------------------------------------------------------
-- 4. Hover on MPI_Send.
-- ---------------------------------------------------------------------------
local send_col = src[SEND_LINE]:find("MPI_Send", 1, true)
local res, why = ask("textDocument/hover", params_at(SEND_LINE, send_col), "hover(MPI)")
if res == nil then
  fail(why or "hover(MPI): nil result for MPI_Send")
end
local mpi_text = hover_text(res)
if #mpi_text == 0 then
  fail("hover(MPI): empty contents for MPI_Send: " .. vim.inspect(res))
end
if not mpi_text:find("MPI_Send", 1, true) then
  fail("hover(MPI): contents do not mention MPI_Send: " .. mpi_text:sub(1, 200))
end
if type(res.contents) == "table" and res.contents.kind and res.contents.kind ~= "markdown" then
  fail("hover(MPI): expected markdown, got " .. tostring(res.contents.kind))
end

-- ---------------------------------------------------------------------------
-- 5. Hover on `parallel` on the !$omp line.
-- ---------------------------------------------------------------------------
local par_col = src[OMP_LINE]:find("parallel", 1, true)
res, why = ask("textDocument/hover", params_at(OMP_LINE, par_col), "hover(OMP)")
if res == nil then
  fail(why or "hover(OMP): nil result for `parallel` on the !$omp line")
end
local omp_text = hover_text(res)
if #omp_text == 0 then
  fail("hover(OMP): empty contents for `parallel`: " .. vim.inspect(res))
end
if not omp_text:lower():find("parallel", 1, true) then
  fail("hover(OMP): contents do not mention parallel: " .. omp_text:sub(1, 200))
end

-- ---------------------------------------------------------------------------
-- 6. Completion after typing `MPI_Al` on a new line.
-- ---------------------------------------------------------------------------
local typed = "  call MPI_Al"
vim.api.nvim_buf_set_lines(buf, SEND_LINE, SEND_LINE, false, { typed })
local NEW_LINE = SEND_LINE + 1
local cparams = params_at(NEW_LINE, #typed + 1) -- cursor just past the `l`
cparams.context = { triggerKind = 1 } -- Invoked
res, why = ask("textDocument/completion", cparams, "completion(MPI_Al)")
if res == nil then
  fail(why or "completion(MPI_Al): nil result")
end
local items = res.items or res
if type(items) ~= "table" then
  fail("completion(MPI_Al): unexpected result shape: " .. vim.inspect(res):sub(1, 200))
end
local found = false
for _, it in ipairs(items) do
  local hay = table.concat({
    tostring(it.label or ""),
    tostring(it.filterText or ""),
    tostring(it.insertText or ""),
    type(it.textEdit) == "table" and tostring(it.textEdit.newText or "") or "",
  }, " "):lower()
  if hay:find("mpi_allreduce", 1, true) then
    found = true
    break
  end
end
if #items == 0 then
  fail("completion(MPI_Al): zero items")
end
if not found then
  local labels = {}
  for i, it in ipairs(items) do
    labels[#labels + 1] = tostring(it.label)
    if i >= 15 then
      break
    end
  end
  fail("completion(MPI_Al): MPI_Allreduce not among " .. #items .. " items (first: " .. table.concat(labels, ", ") .. ")")
end

-- ---------------------------------------------------------------------------
-- 7. Report, tidy, exit 0.
-- ---------------------------------------------------------------------------
-- io.write rather than print: under `nvim -l`, print() goes through the
-- message system and the last line arrives without its newline, so the
-- shell prompt lands on the same line as the OK.
io.stdout:write(("\nOK: %s hover(MPI)=%d chars hover(OMP)=%d chars completion(MPI_Al)=%d items\n")
  :format(CLIENT, #mpi_text, #omp_text, #items))
io.stdout:flush()

vim.bo[buf].modified = false
for _, c in ipairs(vim.lsp.get_clients()) do
  pcall(function()
    c:stop(true)
  end)
end
vim.wait(500, function()
  return #vim.lsp.get_clients() == 0
end, 50)
pcall(vim.api.nvim_buf_delete, buf, { force = true })
vim.fn.delete(dir, "rf")
os.exit(0)
