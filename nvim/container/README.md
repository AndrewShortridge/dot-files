# Neovim in Apptainer, for HPC

A single `nvim.sif` containing Neovim 0.12.5, this config, all 49 plugins, the
treesitter parsers, the mason language servers, and every external CLI the
config shells out to. **Nothing is fetched at run time**, which is the whole
point on compute nodes that cannot reach the network.

Fortran is the reason it exists: MPI, OpenMP and Fortran-keyword hover,
signature help, completion and diagnostics all work offline, from data baked
into the config tree. See [Fortran: MPI and OpenMP intelligence](#fortran-mpi-and-openmp-intelligence).

- [What's in the image](#whats-in-the-image)
- [Fortran: MPI and OpenMP intelligence](#fortran-mpi-and-openmp-intelligence)
- [Why a container and not a tarball](#why-a-container-and-not-a-tarball)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Building](#building)
- [Getting it onto the cluster](#getting-it-onto-the-cluster)
- [Running it](#running-it)
- [How config and state are separated](#how-config-and-state-are-separated)
- [Binding project directories](#binding-project-directories)
- [Installing things at run time](#installing-things-at-run-time)
- [Verifying an image](#verifying-an-image)
- [Troubleshooting](#troubleshooting)
- [HPC caveats](#hpc-caveats)
- [Updating](#updating)
- [The XDG_RUNTIME_DIR trap](#the-xdg_runtime_dir-trap)
- [Debian vs conda binary names](#debian-vs-conda-binary-names)
- [What lives in the image vs. the wrapper](#what-lives-in-the-image-vs-the-wrapper)
- [Fonts and icons](#fonts-and-icons)
- [Deliberate omissions](#deliberate-omissions)
- [Known limitations](#known-limitations)

---

## What's in the image

| Layer | Contents | Approx size |
|---|---|---|
| Neovim | conda-forge `nvim=0.12.5` — pinned, the config targets 0.12 APIs | 30 MB |
| Plugins | 49 lazy.nvim plugins, pre-synced from `lazy-lock.json` | 180 MB |
| Language servers | mason: `rust-analyzer`, `ruff`, `ty`, `codelldb`, `eslint_d`, `prettier`, `ctags-lsp`, `python-lsp-server`, `emmet-ls`, `prisma-language-server`, `eslint-lsp`; conda: `lua-language-server`, `fortls` | 650 MB |
| Fortran registry | `fortran-extras`, an in-process Lua server (no binary) plus its generated MPI/OpenMP/keyword registry `lua/andrew/fortran/data/`, the Fortran snippet set and `doc/fortran-extras.md` | 4 MB |
| Toolchains | `rust` (cargo/rustc), `gfortran`, `openmpi` (for `mpi.mod`/`mpif.h`, see below), `nodejs`, `python`, `cmake`, `gh` | 550 MB |
| Fonts | Nerd Fonts 3.5.1 (Symbols + JetBrainsMono), 98 faces | 30 MB |
| Parsers | treesitter grammars, built with `tree-sitter=0.25.9` | 5 MB |
| CLI tools | `rg` `fd` `fzf` `git` `gdb` `gfortran` `fortls` `ruff` `stylua` `ctags` `ftnchek` `node` `python` `yazi` `lazygit` `delta` `imagemagick` `bat` | 700 MB |

Measured (2026-09-19 build, apptainer 1.5.3): the image is **1.6 GB**,
verified by `%test` to contain 49 plugins, 22 treesitter parsers, 11 mason
packages and 98 Nerd Font faces, with `mpi.mod` readable by the image's
gfortran 16.2 and every Fortran spec and the smoke test passing in-image.
23 parsers are requested; `latex` has never baked in any build of this image
and fails without a log line, so 22 is the expected count.

## Fortran: MPI and OpenMP intelligence

Two language servers attach to every Fortran buffer:

| Server | What it is | What it answers |
|---|---|---|
| `fortls` | conda-forge binary, launched with `--disable_autoupdate` first so it never tries to reach PyPI (`lua/andrew/plugins/lsp/lspconfig.lua`) | project symbols, go-to-definition, references, rename, intrinsics |
| `fortran-extras` | in-process Lua server started with `vim.lsp.start` and a function `cmd` (`lua/andrew/fortran/lsp.lua`); no process, no binary, no `PATH` | hover, signature help, completion, inlay hints, code actions, call hierarchy and two diagnostics for MPI routines and constants, `!$OMP` directives and clauses, and Fortran keywords |

`fortran-extras` reads a generated registry, `lua/andrew/fortran/data/{mpi,openmp,keywords}.lua`,
built on the workstation by `snippets/gen-mpi.lua` (from conda's `mpi.mod`) and
`snippets/gen-omp.lua` (from gfortran's `omp_lib.f90`) merged with the
hand-written prose in `snippets/overrides/`. The registry ships inside the
config tree, so the MPI/OpenMP documentation needs **no MPI installation and
no network** at run time. The generators and their inputs are not needed in
the image; only the three data files are.

The one design rule: `fortran-extras` returns `null` wherever `fortls` would
answer, so a hover never shows two banners and project symbols stay with
`fortls`. Completion in Fortran buffers ranks exact matches first, then the
LSP group (both servers), then snippets (`lua/andrew/fortran/completion_sort.lua`).

Its two diagnostics, `ompDirectiveWithoutFlag` and `mpiArgumentCount`, each
carry a link into `doc/fortran-extras.md`, which is why `doc/` is in `%files`.
`<leader>cH` opens the link; inside the image there is no `xdg-open`, so the
useful form on the cluster is to read the file directly:
`apptainer exec nvim.sif less /opt/nvim/config/nvim/doc/fortran-extras.md`.

### Why `openmpi` is installed

Not to run MPI programs. The gfortran linter and `fortls` need `mpi.mod`,
`mpi_f08.mod` and `mpif.h` to resolve `use mpi` / `include 'mpif.h'`, and
without them gfortran stops at one fatal error:

```
Fatal Error: Cannot open module file 'mpi.mod' for reading at (1)
```

That single line masked every other diagnostic in every MPI source file, and
nothing in the config suppresses it. `lua/andrew/fortran/mpi.lua` discovers
`mpif.h` by probing, in order, `I_MPI_ROOT` / `MPI_HOME` / `MPI_ROOT` /
`MPICH_DIR` / `OPAL_PREFIX`, then `$CONDA_PREFIX/include`, then the usual
system paths. The image sets `CONDA_PREFIX=/opt/conda`, so conda-forge's
`openmpi` lands its module files exactly where the probe looks, and both the
linter's `-I` and `fortls --include_dirs` follow without further wiring.

A site MPI module still wins when you bind it in and export one of the
variables above, because they are probed first. conda-forge's `mpif90`
wrapper does run (verified with a clean environment); the earlier note about
broken conda MPI wrappers applied to Intel MPI, which is still left out.

`:FortranMpiStatus` reports what was found; `vim.g.fortran_mpi_include_dirs`
overrides discovery entirely.

`tree-sitter` is pinned to 0.25.9 because the latex grammar needs that CLI's
`--no-bindings` behaviour to build. `nvim` is pinned exactly because a 0.11
image would break LSP attach — this config uses `vim.lsp.enable` and the 0.12
`gr*` defaults.

## Why a container and not a tarball

Copying `~/.config/nvim` alone does not work.

1. **The workstation's Neovim isn't portable.** It's conda's, and `ldd` shows it
   linking eight shared libraries out of `~/miniconda3/lib` — `libluv`,
   `liblpeg`, `libtree-sitter.so.0.25`, `libluajit`, `libutf8proc`,
   `libunibilium`, `libuv`, `libiconv`. Move the binary alone and it won't start.
2. **The config shells out constantly.** About twenty external binaries, `rg`
   alone from 16 call sites.
3. **Compiled artifacts are arch- and libc-specific.** The parsers and
   everything under `mason/` are x86-64 Linux binaries built against a
   particular glibc.

Apptainer bundles all three, runs unprivileged, and is already the container
runtime on most clusters.

## Prerequisites

**To build** (workstation): Apptainer with `--fakeroot`, network access, ~5 GB
free disk.

```bash
sudo add-apt-repository -y ppa:apptainer/ppa
sudo apt install -y apptainer
```

**To run** (cluster): Apptainer or Singularity, usually via `module load`.
No root, no network.

```bash
module load apptainer     # or: module load singularity
```

## Quick start

```bash
cd ~/.config/nvim
./container/build.sh                        # 20-40 min -> container/nvim.sif
scp container/nvim.sif user@hpc:~/bin/

# on the cluster
module load apptainer
apptainer run ~/bin/nvim.sif solver.f90
```

## Building

```bash
./container/build.sh                  # -> container/nvim.sif
./container/build.sh /tmp/other.sif   # -> a different path
```

The script verifies apptainer is present, builds with `--fakeroot --force`,
runs the image's `%test` section, and prints the size and an `scp` line.

Equivalent by hand — note the build context must be the **repo root**, because
`%files` copies paths relative to the current directory:

```bash
cd ~/.config/nvim
apptainer build --fakeroot container/nvim.sif container/nvim.def
```

**Build on a workstation, not the cluster.** Most sites forbid building on
login nodes, and the build needs network to pull plugins and servers.

Expect roughly 20–40 minutes, dominated by downloads rather than compilation:
mason fetching `rust-analyzer` and `codelldb`, conda fetching the Rust
toolchain, and the Nerd Font archives. A warm conda/apt cache shortens it
considerably; a cold one on a slow link will exceed it. `build.sh` picks a rootless strategy automatically: `--fakeroot`
where `newuidmap` exists (the cluster case), otherwise an `unshare` fallback
for a workstation that lacks the `uidmap` package.

### If a build step fails

The seeding steps are deliberately non-fatal — a failure degrades one feature
rather than sinking a 40-minute build. Watch for these in the log:

```
WARN: lazy sync incomplete              -> plugins missing; check network/proxy
WARN: treesitter parser build incomplete -> syntax highlighting degraded
WARN: mason servers incomplete           -> LSP missing; PATH servers still work
WARN: ftnchek unavailable                -> :FortranCheck inert, everything else fine
```

None of these abort the build. If you need them fixed, resolve the cause and
rebuild rather than shipping a half-seeded image.

## Getting it onto the cluster

Land it under a temporary name and swap it in only once the checksum matches.
A half-transferred `.sif` is still a file the wrapper will happily try to run,
and you will not enjoy diagnosing that at 2am.

```bash
rsync -avP container/nvim.sif user@hpc:~/bin/nvim.sif.new
# then, on the cluster:
md5sum ~/bin/nvim.sif.new          # compare against the source
mv ~/bin/nvim.sif.new ~/bin/nvim.sif
```

Do not overwrite the image while an nvim is running against it.

The `.sif` is a single immutable file — nothing else needs to travel with it,
and the wrapper is a separate ~30-line text file you rarely need to update. If
the image and the wrapper are ever both stale, copy the image first: a new
wrapper against an old image loses the fixes, whereas an old wrapper against a
new image works fine (its redundant blocks are harmless).

## Running it

```bash
apptainer run  ~/bin/nvim.sif                 # open nvim
apptainer run  ~/bin/nvim.sif solver.f90      # open a file
apptainer exec ~/bin/nvim.sif nvim --version  # run a specific command
apptainer exec ~/bin/nvim.sif rg pattern      # use a bundled tool directly
apptainer shell ~/bin/nvim.sif                # poke around inside
apptainer test ~/bin/nvim.sif                 # verify the toolchain
apptainer run-help ~/bin/nvim.sif             # the %help text
```

### Replacing the cluster's /usr/bin/vi

`container/hpc-vi-wrapper.sh` shadows the system editor. Install it as
`~/bin/nvim` and symlink the classic names at it:

```bash
mkdir -p ~/bin
cp container/hpc-vi-wrapper.sh ~/bin/nvim && chmod +x ~/bin/nvim
ln -sf nvim ~/bin/vi
ln -sf nvim ~/bin/vim
ln -sf nvim ~/bin/view
```

Then **prepend** (not append) to `~/.bashrc`:

```bash
export PATH="$HOME/bin:$PATH"
export EDITOR=nvim
export VISUAL=nvim
```

Check it took: `command -v vi` must print `~/bin/vi`, not `/usr/bin/vi`
(`hash -r` clears bash's cached lookups).

The wrapper `module load`s apptainer if needed, binds whichever of `/scratch`,
`/work`, `/project`, `/gpfs`, `/shared` exist, opens read-only when invoked as
`view`, honours `NVIM_SIF` for a non-default image path, and falls back to
`/usr/bin/vi` if apptainer or the image is missing. That is all it does — see
[What lives in the image vs. the wrapper](#what-lives-in-the-image-vs-the-wrapper).

Two limits: anything calling the absolute path `/usr/bin/vi` bypasses this, and
if your cluster `~/.bashrc` early-returns for non-interactive shells, the
`PATH` line must sit *above* that guard or batch jobs will not see it.

### If $HOME is mounted noexec

Some clusters (UConn Storrs among them: `/home` is WekaFS mounted
`rw,noexec`) refuse to execute *any* file in your home directory, whatever the
permission bits say. The symptom is confusing, because the wrapper looks
perfectly fine:

```
$ ls -l ~/bin/nvim
-rwxr-xr-x. 1 you users 1834 nvim          <- executable
$ ~/bin/nvim --version
-bash: /home/you/bin/nvim: Permission denied
$ hash -r; type -a vi
vi is /usr/bin/vi                          <- PATH silently skipped it
```

`PATH` lookup skips entries it cannot execute, so `vi` falls through to the
system one and no error is ever printed. Confirm with:

```bash
findmnt -no SOURCE,TARGET,OPTIONS -T $HOME     # look for `noexec`
bash ~/bin/nvim --version                      # works: reading != executing
```

The image itself is unaffected — apptainer only *reads* the `.sif`, so
`apptainer exec ~/bin/nvim.sif nvim --version` works from a noexec home.

Use shell functions instead of a `PATH` entry; `bash script` needs only read
permission:

```bash
# ~/.bashrc  (drop the $HOME/bin PATH line, it does nothing here)
export NVIM_SIF="$HOME/bin/nvim.sif"
nvim() { bash "$HOME/bin/nvim" "$@"; }
vi()   { bash "$HOME/bin/nvim" "$@"; }
vim()  { bash "$HOME/bin/nvim" "$@"; }
view() { bash "$HOME/bin/nvim" -R "$@"; }
export -f nvim vi vim view
export EDITOR="bash $HOME/bin/nvim"
export VISUAL="$EDITOR"
```

`export -f` carries the functions into bash subshells, and the `EDITOR` string
works for git, `crontab -e`, and anything else that runs the editor through
`sh -c`. The limitation is that functions do not reach non-bash contexts — a
`csh` job script, or a program calling `execvp("vi")` directly. If you need
that, ask the site where users are expected to keep executables; most clusters
leave scratch exec-capable.

### Make it feel native

Add to `~/.bashrc` on the cluster:

```bash
module load apptainer
alias nvim='apptainer run --bind /scratch,/work $HOME/bin/nvim.sif'
```

Or, if you'd rather have a real executable on `PATH` — `~/bin/nvim`:

```bash
#!/usr/bin/env bash
module load apptainer 2>/dev/null || true
exec apptainer run --bind /scratch,/work "$HOME/bin/nvim.sif" "$@"
```

```bash
chmod +x ~/bin/nvim
```

The wrapper is usually better than the alias: aliases don't apply in scripts,
in `$EDITOR`, or in git's editor hook.

## How config and state are separated

This is the part worth understanding, because a `.sif` is immutable but Neovim
must be able to write.

| Variable | Points at | Writable | Holds |
|---|---|---|---|
| `XDG_CONFIG_HOME` | `/opt/nvim/config` (image) | no | the config |
| `XDG_DATA_HOME` | `/opt/nvim/data` (image) | no | plugins, parsers, mason servers |
| `XDG_STATE_HOME` | `$HOME/.local/state` (host) | **yes** | shada, undo, swap, logs |
| `XDG_CACHE_HOME` | `$HOME/.cache` (host) | **yes** | Lua module cache |

Apptainer bind-mounts `$HOME` and the current directory by default, so your
marks, undo history and jump list land in your real home. They survive between
runs *and* between image versions — rebuild and upgrade freely, state carries.

The image also exports `NVIM_CONTAINER=1`, which `lua/andrew/lazy.lua` reads to
switch off lazy.nvim's update checker and file-change detection. Without it, an
air-gapped node spends startup on 49 `git fetch` calls that cannot resolve and
would have nowhere to write if they could.

## Binding project directories

Anything outside `$HOME` and `$PWD` must be bound explicitly:

```bash
apptainer run --bind /scratch/$USER,/work/$USER,/project/lab ~/bin/nvim.sif
```

Set it once for the session:

```bash
export APPTAINER_BIND=/scratch,/work,/project
```

A file that isn't bound gives "permission denied" or an empty buffer. That is a
missing bind, not a broken image.

## Installing things at run time

The image is read-only, so `:Lazy install` and `:MasonInstall` cannot write.

**Throwaway** — changes vanish on exit, useful for trying one plugin:

```bash
apptainer run --writable-tmpfs ~/bin/nvim.sif
```

**Persistent** — a writable layer stored beside the image:

```bash
apptainer overlay create --size 2048 ~/bin/nvim-overlay.img
apptainer run --overlay ~/bin/nvim-overlay.img ~/bin/nvim.sif
```

For anything you want to keep, prefer editing the config and rebuilding. That
keeps the image reproducible, which is the reason to containerise at all.

## Verifying an image

```bash
apptainer test ~/bin/nvim.sif
```

Checks that `nvim --version` runs, that all 25 core tools are on `PATH`
(reporting every missing one at once, not just the first), that the plugin tree
was seeded, and that Nerd Fonts registered with fontconfig.

Then the Fortran stack: the registry data files, `doc/fortran-extras.md`, the
Fortran snippet set and the `fortran` treesitter parser are present; `mpif.h`
and `mpi.mod` exist under `/opt/conda/include` and `mpi.include_dirs()` finds
them; eleven of the repo's Fortran specs run against the baked tree
(`tests/fortran_*_spec.lua`, shipped for the purpose); and
`/opt/nvim/fortran-smoke.lua` boots the real config, attaches `fortran-extras`
to a buffer and asks it for MPI hover, OpenMP hover and MPI completion.

It also runs the regression test for the bug that broke fzf-lua on the cluster:
nvim is launched with a simulated host `XDG_RUNTIME_DIR=/run/user/999999` and
must move `stdpath("run")` off it, open a socket successfully, and report
`CONDA_PREFIX=/opt/conda`. A passing run looks like:

```
OK: XDG_RUNTIME_DIR -> /tmp/nvim.andrew-cmmg/HgIefj, CONDA_PREFIX -> /opt/conda
OK: 49 plugins, 22 parsers, 11 mason packages, 98 nerd faces
OK: MPI include discovery -> /opt/conda/include
  fortran_registry_spec:   23 passed, 0 failed
  ...
OK: fortran-extras hover(MPI)=3119 chars hover(OMP)=2163 chars completion(MPI_Al)=18 items
OK: fortran-extras MPI/OpenMP registry, hover, signature, completion and diagnostics verified in-image
```

Deeper spot check:

```bash
apptainer exec ~/bin/nvim.sif nvim --headless "+Lazy! health" +qa
apptainer exec ~/bin/nvim.sif nvim --headless "+checkhealth" +qa
# the Fortran smoke test and any single spec, on the cluster:
apptainer exec ~/bin/nvim.sif nvim --headless -l /opt/nvim/fortran-smoke.lua
apptainer exec ~/bin/nvim.sif nvim --headless -u NONE -l /opt/nvim/config/nvim/tests/fortran_lsp_hover_spec.lua
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `E5108: serverstart(): ... XDG_RUNTIME_DIR (/run/user/NNNNN) is writeable` | image predates the entrypoint shim | rebuild. As a stopgap on an old image: `export APPTAINERENV_XDG_RUNTIME_DIR=/tmp/nvim-run-$(id -u)` after `mkdir -p`ing it |
| File picker (`<leader>ff`) opens empty, no error | image predates the `fd`/`fdfind` fix, so `files.cmd` ran a binary that isn't there — fzf-lua reports nothing when its command fails | rebuild |
| Icons show as boxes / wrong glyphs | your **local** terminal's font, not the image | set `font_family` in the terminal you SSH *from* — see [Fonts and icons](#fonts-and-icons) |
| Fortran files never format on save | image predates the `CONDA_PREFIX` fix, so conform resolved `/bin/fprettify` | rebuild; verify with `apptainer exec nvim.sif fprettify --version` |
| `permission denied` opening a file | path not bound | `--bind /scratch,/work` |
| Empty buffer for a file you know exists | same | as above |
| `FATAL: container creation failed` | no user namespaces / setuid mode | ask the site admin which mode is enabled |
| Build fails writing temp files | tiny `TMPDIR` from the scheduler | `export APPTAINER_TMPDIR=/scratch/$USER/tmp` |
| LSP never attaches | server missing from the image | check the build log for `WARN: mason servers incomplete` |
| No MPI/OpenMP hover or completion in Fortran | `fortran-extras` has no binary, so it cannot be "missing"; either `lua/andrew/fortran/data/` did not ship or the ft-gated lspconfig spec never ran | `apptainer exec nvim.sif nvim --headless -l /opt/nvim/fortran-smoke.lua` and read the `FAIL:` line; `:LspInfo` should list both `fortls` and `fortran-extras` |
| Every MPI source shows one `Cannot open module file 'mpi.mod'` error and nothing else | image predates the `openmpi` install, so the linter has no `-I` | rebuild; check with `:FortranMpiStatus`, or bind a site MPI and export `MPI_HOME` |
| Images don't render inline | terminal isn't Kitty | expected over plain SSH; everything else works |
| `:Lazy` shows plugins as needing update | read-only image | cosmetic; rebuild to update |
| Cluster `~/.config/nvim` seems ignored | by design | `XDG_CONFIG_HOME` overrides it; host and image can't fight |
| Slow first start | `$HOME` on a network filesystem | `export XDG_CACHE_HOME=/tmp/$USER/nvim-cache` |
| `exec` hangs on anything large | unprivileged squashfuse mount (seen on a workstation; clusters use setuid-mode kernel squashfs) | `apptainer build --sandbox dir image.sif` and run the sandbox |

## HPC caveats

- **No network is fine.** Everything is baked in.
- **`TMPDIR`** is often a small tmpfs under a scheduler. Point
  `APPTAINER_TMPDIR` at scratch if anything fails oddly.
- **Inline images** need Kitty's graphics protocol; they won't render over a
  plain SSH session. Nothing else degrades.
- **Fortran LSP** — `fortls` and `fortran-extras` both attach; both scope
  themselves to a project root marked by `.fortls`, `.git`, or a `code/`
  directory (`lua/andrew/plugins/linting.lua`, `lua/andrew/fortran/scan.lua`).
  Open files from inside the project, or the root falls back to the file's
  own directory.
- **MPI** — documentation, completion and the argument-count diagnostic are
  baked in and need no MPI at all. The image carries `gfortran` plus
  conda-forge `openmpi` so `use mpi` lints cleanly, but that is *not* your
  cluster's MPI: bind the site module in and export `MPI_HOME` (or
  `I_MPI_ROOT`, `MPICH_DIR`, `OPAL_PREFIX`) to lint against its `mpif.h`
  instead. For real `mpif90` builds use the cluster's wrappers outside the
  container, or build a variant with `From:` your cluster's MPI base image.
- **Home collision** — a cluster `~/.config/nvim` is ignored, because
  `XDG_CONFIG_HOME` inside the container points at the image.

## Updating

The image is disposable:

```bash
cd ~/.config/nvim
git pull                       # or edit the config
./container/build.sh
scp container/nvim.sif user@hpc:~/bin/
```

Your state in `$HOME/.local/state` is untouched by the swap.

## The XDG_RUNTIME_DIR trap

Apptainer bind-mounts `/tmp`, `$HOME`, `/dev`, `/proc` and `/sys` by default —
but **not `/run/user`**. Your login shell exports `XDG_RUNTIME_DIR=/run/user/$UID`,
that value is inherited into the container, and the directory it names is simply
not there. Neovim resolves `stdpath("run")` from it, so every unix socket fails:

```
E5108: Lua: .../fzf-lua/lua/fzf-lua/init.lua:44: serverstart():
Vim:Failed to start server: no such file or directory.
Please make sure 'XDG_RUNTIME_DIR' (/run/user/578032) is writeable
```

fzf-lua is only the messenger — it opens an RPC socket at `require` time, so it
is the first thing to ask. `:terminal`, `--listen`, and anything else touching
`stdpath("run")` break the same way.

Measured against nvim 0.12.5:

| `XDG_RUNTIME_DIR` | `stdpath("run")` | `serverstart()` |
|---|---|---|
| unset | `/tmp/nvim.$USER/<random>` | works |
| set to a path that doesn't exist | that path | fails as above |
| set to a writable dir | that dir | works |

**Fixed in the image**, by an entrypoint shim — and the reason it is a shim
rather than `%environment` is worth knowing.

Apptainer re-applies the host environment *after* sourcing `%environment`. Any
variable the host also defines therefore gets its host value back, and an
`unset` there is silently undone. Verified directly: sourcing
`/.singularity.d/env/90-environment.sh` by hand inside the container *does*
clear the variable, yet it is still set at process start. `PATH` is special-cased
and survives; `XDG_RUNTIME_DIR` and `CONDA_PREFIX` do not.

So `%post` renames the real binary to `nvim.bin` and installs a shim at
`/opt/conda/bin/nvim` that runs after all environment handling. It clears an
unwritable `XDG_RUNTIME_DIR` (Neovim then makes its own private
`/tmp/nvim.$USER/<random>` and removes it on exit), pins `CONDA_PREFIX`, and
guarantees mason's bin dir is on `PATH`. Being on `PATH` rather than in
`%runscript` means it covers `apptainer run`, `apptainer exec nvim` *and* a bare
`nvim` from `apptainer shell`.

`%test` asserts all of this against a simulated host value, so it cannot
regress silently:

```
OK: XDG_RUNTIME_DIR -> /tmp/nvim.andrew-cmmg/HgIefj, CONDA_PREFIX -> /opt/conda
```

The wrapper does nothing here, and needs to know nothing about it.

## Debian vs conda binary names

The workstation installs `fd` from **apt**, which names the binary `fdfind` (the
name `fd` clashes with fdclone on Debian). The image installs it from
**conda-forge**, which names it `fd`. Verified inside the built image:

```
$ apptainer exec nvim.sif sh -c 'command -v fd fdfind'
/opt/conda/bin/fd                 # and no fdfind at all
```

`fzf-lua.lua` used to hardcode `fdfind`, so in the container the file picker ran
a command that does not exist. fzf-lua reports nothing when its `cmd` fails — the
picker just comes up empty, which reads like "search is broken" rather than
"binary missing". It now resolves the name at config time and falls back to
fzf-lua's own detection if neither is present.

Fixed in two places, so neither has to be trusted alone:

- **`fzf-lua.lua`** resolves the name at config time, falling back to fzf-lua's
  own detection if neither binary is present.
- **`%post`** creates `ln -sf fd /opt/conda/bin/fdfind`, so anything else that
  assumes the Debian name also works.

`bat` needs no equivalent — fzf-lua detects `bat` and `batcat` itself.

## What lives in the image vs. the wrapper

The wrapper is a launcher, not a patch kit. Anything that *can* be baked in, is:

| Concern | Where | Why there |
|---|---|---|
| `XDG_RUNTIME_DIR` sanity | image (`%environment`) | nothing host-specific about it |
| `fdfind` name | image (`%post` symlink + config resolution) | a property of the image's own toolchain |
| `CONDA_PREFIX=/opt/conda` | image (`%environment`) | formatter paths resolve from it |
| mason's bin dir on `PATH` | image (`%environment`) | mason is filetype-gated, so it may never load |
| Find apptainer (`module load`) | **wrapper** | must happen before a container can exist |
| Locate the `.sif` | **wrapper** | host path, `NVIM_SIF`-overridable |
| Bind list | **wrapper** | binds are decided by the launcher, not the image |
| `view` → `-R` | **wrapper** | the container cannot see which name was typed |
| Fallback to `/usr/bin/vi` | **wrapper** | the image may be missing entirely |

That leaves about 30 lines of actual code in `hpc-vi-wrapper.sh`. If you change
the wrapper you do not need to rebuild; if you change anything in the left-hand
column you do.

### Formatters and `CONDA_PREFIX`

`conform.lua` used to hardcode `$CONDA_PREFIX/bin/fprettify`. Nothing sets
`CONDA_PREFIX` inside the image, so that expanded to `/bin/fprettify`, and
Fortran files silently never formatted — conform reports nothing when its
`command` does not exist. It now prefers the conda-env copy and falls back to a
bare name resolved on `PATH`. The image sets `CONDA_PREFIX=/opt/conda` and ships
`fprettify`, so both paths work.

## Fonts and icons

The image ships Nerd Fonts 3.5.1, but **be clear about what that can and cannot
do.**

Glyphs in fzf-lua, which-key, lualine and nvim-web-devicons are drawn by *the
terminal emulator on your local machine*, using *its* configured font. A remote
process only ever writes codepoints down the wire — Neovim never rasterises
anything. So fonts inside a container on the cluster cannot change what your
terminal draws, and **installing them does not fix tofu boxes over SSH.** That
is fixed in the local terminal's config:

```conf
# ~/.config/kitty/kitty.conf on the machine you SSH *from*
font_family JetBrainsMono Nerd Font
```

Without an explicit `font_family`, kitty resolves `monospace` through
fontconfig, which can hand a large share of the private-use range to an
unrelated fallback face — CJK fonts are a common culprit — and you get boxes for
roughly half your icons with no error anywhere.

What the bundled fonts *are* for: imagemagick and ghostscript rasterise text
**inside** the container when snacks.nvim converts an SVG or PDF for inline
image rendering. Without a font covering the private-use range, any icon inside
a converted document comes out blank.

They install to `/opt/conda/fonts`, which is not a matter of taste: there is no
`/etc/fonts` in this image, conda's fontconfig is the only one present, and it
scans exactly two directories — `/opt/conda/fonts` and `$HOME/.fonts`. Fonts in
the conventional `/usr/local/share/fonts` are silently invisible.

Check what the image registered:

```bash
apptainer exec nvim.sif fc-list : family | grep -i nerd | sort -u
```

## Deliberate omissions

Two things are left out on purpose. Adding either would make things worse:

**`xclip` / `xsel` / `wl-clipboard`.** Neovim picks a clipboard provider by
probing for these *first*, and falls back to OSC 52 only when none is found.
There is no X display in the container, so installing them would make Neovim
select a provider that cannot work and break copy/paste that currently works
fine over SSH. This is a regression, not a feature.

**Intel MPI (`impi`, `mpiifx`).** conda's Intel-MPI wrappers ship with an
unsubstituted install prefix and do not run. Real vendor MPI comes from
environment modules, which are outside the container by definition.
conda-forge's `openmpi` *is* installed, for its module files rather than its
runtime; see [Why `openmpi` is installed](#why-openmpi-is-installed).

## Known limitations

- **x86-64 Linux only.** The parsers and mason servers are compiled for this
  arch and glibc. An ARM cluster needs a rebuild on ARM.
- **Built and confirmed working on the cluster** with the 2026-09-12 image.
  Verified inside it: nvim 0.12.5 starts, 50 plugins load, 22 parsers present,
  all 25 external tools resolve on `PATH`, fzf-lua loads and `serverstart()`
  succeeds under a hostile host `XDG_RUNTIME_DIR`, and `fprettify`/`prettier`
  both resolve. Then run for real on UConn Storrs against Fortran sources.
- **The 2026-09-19 image** (built with apptainer 1.5.3 from conda-forge, in
  the `apptainer` conda env, via `bash ./container/build.sh`) carries the
  Fortran docs port: `fortran-extras` registry, `doc/`, `tests/`, the smoke
  test and `openmpi`. **Confirmed on UConn Storrs 2026-09-19**: `apptainer
  test` passed in full on a login node (49 plugins, 22 parsers, 11 mason
  packages, MPI include discovery, all 11 Fortran specs) and the smoke test
  attached `fortran-extras` alongside `fortls` and answered MPI/OpenMP hover
  and MPI completion. The previous image is kept as `nvim.sif.old` for
  rollback; delete it once you are happy.
- **The `latex` treesitter parser does not bake** (22 of 23 requested), in
  this and every earlier image, with no error in the build log. LaTeX files
  fall back to Vim syntax highlighting; nothing Fortran-related is affected.
- **Cluster MPI is not bundled**; conda-forge `openmpi` stands in for its
  headers only, see above.
- **`<leader>cH` has nothing to open with** inside the image (no `xdg-open`);
  read `doc/fortran-extras.md` directly.
- **Mason cannot self-update** inside a read-only image; rebuild instead.
