# ksession Rust Port — Implementation Plan

Reference doc for porting `~/.config/kitty/scripts/ksession.sh` (Bash, ~840 LOC) to a
Rust binary `ksession-rs`. Synthesizes findings from four parallel research passes
(crate selection, module architecture, nvim adapter design, migration & testing).

The Bash version works today. This port exists to:

- Replace string-templating into `nvim --remote-expr` with real msgpack-RPC.
- Parallelize per-window capture (~5–10× speedup expected for complex sessions).
- Get static types on the data model so regressions like the IFS-tab-collapse and the
  fg-pid-vs-w-pid mix-up can't recur.
- Lay groundwork for a richer restore (load-into-current-OS-window with live RPC).

The Bash version **stays installed** through the entire transition; nothing about
this port is destructive.

---

## 1. Scope & non-goals

**In scope (parity with current Bash):**

- `save`, `restore`, `list`, `show`, `rm` subcommands.
- Capture: kitty layout (OS window × tab × window), nvim (mksession + modified buffer
  dumps), less/man (fdinfo `pos:`), shell context (venv/conda/oldpwd), tmux (session
  structure + per-pane program), scrollback ANSI.
- Restore via kitty's native `--session` mechanism — generate a `.conf` that the
  existing `session-picker.sh` / `project-loader.sh` can consume.
- Same on-disk sidecar layout (see §6 for the exact paths).

**Explicitly out of scope:**

- macOS / Windows. Linux-only via `/proc`.
- A custom restore launcher. We keep using `kitty --session`.
- Replacing `session-picker.sh` / `project-loader.sh`. Those are happy as-is.
- Migrating data forward — preserve existing `.state/` directories byte-for-byte.

---

## 1.5. User-facing environment variables

Canonical list of env vars consumed by `ksession-rs` and its generated scripts. New variables added during implementation should be added here.

| Variable | Consumed by | Default | Effect |
|---|---|---|---|
| `KSESSION_FORCE` | Generated `tmux/<sess>/restore.sh` (§5.4 collision policy) | unset | When set to any non-empty value, the restore script `kill-session`s a colliding live tmux session before rebuilding, rather than attaching to it. |
| `KSESSION_SCROLLBACK` | `session::save::capture_window` (kitty-window leg, §5.7) and `adapter::tmux::capture` (tmux-pane leg, §5.4); both legs read the same env var, resolved once by `cli/save` (Step 9) into `SharedCtx.scrollback_enabled`. | `1` (on) | Setting `=0` skips per-pane `capture-pane` calls. Used by users with very large/sensitive scrollbacks who want to opt out. |
| `KSESSION_IMPL` | `ksession-save-prompt.sh` (§7 migration) | unset → `$(dirname "$0")/ksession.sh` | Path to the ksession implementation binary that the save-prompt invokes. Default during Phases 1–2 is the sibling `ksession.sh`; the wrapper's hardcoded default is flipped to `$HOME/.local/bin/ksession-rs` in Phase 3 (see §7). Setting this env var overrides the default at runtime — e.g. `export KSESSION_IMPL=$HOME/.local/bin/ksession-rs` during Phase 2 opt-in, or `export KSESSION_IMPL=$(dirname …)/ksession-legacy.sh` to revert after Phase 3. The wrapper validates that the target is executable before invoking it; bare names matching known shells (`bash`, `sh`, `zsh`) are rejected. There is no runtime "shadow / both" mode — differential testing lives in `tests/diff_runner.rs` (§8) as a test-time harness, not a save-time wrapper. |
| `KSESSION_FROM_LS` | `cli/save` (resolves into `SaveOpts.from_ls` before `session::save` is called; §8 shadow testing) | unset | When set, `cli/save` resolves the env var to a path and writes it into `SaveOpts.from_ls`; `session::save` then reads the pre-recorded `kitty @ ls` JSON from that path instead of spawning kitty. `session::save` never reads `KSESSION_FROM_LS` directly — it operates on the pre-resolved `SaveOpts.from_ls`. Used by integration tests for deterministic fixtures. |
| `KITTY_PROJECT_SESSIONS_DIR` | Sessions-dir resolver (`session::sessions_dir`); inherited from Bash `ksession.sh:26` | `~/.config/kitty/sessions` | Overrides where `.conf` and `.state/` files are written/read. Setting this lets multiple ksession installations (e.g. parity-test sandbox vs prod) coexist without trampling each other. |
| `KITTY_WINDOW_ID` | `cli/save` (Step 9), resolving `--window-id`/env to `SaveOpts.window_id`; never read directly by `session::save`. | injected by kitty into each window | Used to identify which OS window the running save originated from when the user does not pass `--window-id`. Read-only — set by kitty itself, not the user. Documented here for completeness; consumers should never set it by hand. Resolution is owned by Step 9; `session::save` operates on a fully-resolved `Option<u32>`. |
| `KSESSION_RESTORE_SIZE` | §B.3.2 control-mode fallback for tmux `< 3.2` with no other clients attached | `200x60` | Sentinel `WxH` written to `tmux refresh-client -C` before the control-mode client detaches, so the session does not persist at the control client's default 80×24. Format is `<width>x<height>` (e.g. `300x80`). Only consumed on the pre-3.2 fallback path; ignored on tmux ≥ 3.2 where `attach-session -r` (`ignore-size`) avoids the resize entirely. |

Setting any of these via `~/.config/kitty/kitty.conf`'s `env` directive applies them to ksession invocations launched from kitty windows.

---

## 2. Architecture

Single crate, `cargo new --bin ksession-rs`, exposing `src/lib.rs` + `src/bin/ksession.rs`.
The lib/bin split lets integration tests in `tests/` call `ksession::session::save()`
directly with fixtures, and lets a future GUI/TUI consume the same library.

```
ksession-rs/
├── Cargo.toml
├── Makefile                       # build / install / test (no install.sh, no packaging)
├── templates/
│   └── tmux_restore_header.sh    # static preamble: #!/bin/bash + set -euo pipefail + collision check (§5.4)
├── tests/
│   ├── fixtures/
│   │   ├── kitty-ls/*.json        # captured `kitty @ ls` snapshots
│   │   ├── proc/<scenario>/       # mock /proc trees
│   │   └── golden/conf/*.conf     # hand-curated expected outputs
│   ├── regression/*.rs            # one test per shipped Bash bug
│   ├── integration/
│   │   ├── nvim.rs                # spawns headless nvim
│   │   └── tmux.rs                # spawns isolated tmux server
│   └── manual/kitty_e2e.sh        # interactive, run locally only
└── src/
    ├── lib.rs                     # public re-exports
    ├── bin/ksession.rs            # thin CLI dispatcher → lib::session
    ├── error.rs                   # KError, AdapterError (thiserror)
    ├── log.rs                     # tracing setup → ~/.cache/ksession.log
    ├── cli/                       # clap-derive subcommand structs
    ├── model/                     # pure serde types (SessionFile, OsWindow, …)
    ├── proc/                      # /proc helpers (exe_base, env, descendants)
    ├── fsx/                       # atomic writes (NamedTempFile + persist)
    ├── kitty/                     # `kitty @` wrapper, ls JSON deserialization
    ├── nvim_rpc/                  # msgpack-RPC client (used by nvim AND tmux adapters)
    ├── tmux_rpc/                  # tmux query helpers + restore.sh codegen
    │   ├── mod.rs
    │   └── control.rs             # ~150 LOC: `tmux -C attach` pipe + %begin/%end demuxer (§B.3.2)
    ├── adapter/
    │   ├── mod.rs                 # Adapter trait + Registry
    │   ├── nvim.rs
    │   ├── less.rs
    │   ├── shell.rs
    │   ├── tmux.rs
    │   └── raw.rs                 # always-matches fallback
    ├── conf/                      # render SessionFile → kitty .conf text (kq quoting)
    └── session/                   # save / restore / list / show / rm orchestration
```

Two non-obvious calls in this layout:

- **`nvim_rpc` is separated from `adapter::nvim`.** The tmux adapter recurses into the
  same per-program adapters for each pane (a tmux pane running nvim is just an nvim
  capture with a different state-dir root). Both need the RPC client; only the kitty-
  level adapter generates the kitty launch argv. Keep the transport agnostic.
- **`model/` has zero behavior.** It's pure data so `conf::render`, `session::save`,
  and tests can all consume it without pulling in adapter dependencies.

---

## 3. Dependencies

```toml
[dependencies]
clap            = { version = "4", features = ["derive", "wrap_help"] }
serde           = { version = "1", features = ["derive"] }
serde_json      = "1"
thiserror       = "1"
anyhow          = "1"                              # bin/ only, never in lib/
async-trait     = "0.1"                            # required for adapter::Adapter trait (§5.5)
chrono          = { version = "0.4", features = ["serde"] }
uuid            = { version = "1", features = ["v4"] }   # §C.3 window tagging (--var ksession_id=<uuid>)
nvim-rs         = "0.9"                            # msgpack-RPC over Unix socket
tokio           = { version = "1", features = ["net", "io-util", "rt", "macros", "time", "process", "sync"] }
nix             = { version = "0.29", features = ["fs", "user"] }   # readlink, getuid
shell-escape    = "0.1"                            # for tmux restore.sh, NOT for kq
tempfile        = "3"                              # atomic writes via NamedTempFile::persist
tracing         = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
tracing-appender   = "0.2"                         # rolling log → ~/.cache/ksession.log

[dev-dependencies]
pretty_assertions = "1"
tempfile          = "3"
```

**Rejected:**

- `procfs` — pulls 6+ transitive deps for ~30 lines of `/proc` parsing we can hand-roll.
- `argh` — lighter than clap but no subcommand `--help` polish and no completion gen.
- `rmp-serde` / raw `rmpv` for nvim — nvim-rs already handles framing, request ID
  correlation, and the generated API surface. Rolling our own is ~400 LOC for no gain.
- `askama` / `tera` — only two templates, each has one variable list. Use `include_str!`
  + a small write loop.

**Cross-cutting decision:** `nvim-rs` is Tokio-only, so the whole binary uses Tokio.
Use the `current_thread` flavor — no need for work-stealing, and avoiding `Send` bounds
keeps the code simpler. Single shared `Runtime` for the whole process.

---

## 4. Data model

```rust
// model/session.rs
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct SessionFile {
    pub name: String,
    pub created_at: DateTime<Utc>,
    pub schema: u32,                       // bump on layout changes; mismatched schema at restore/list/show rejects with KError::SchemaMismatch{name,found,expected} — user re-runs save to overwrite. No silent upgrade.
    pub os_windows: Vec<OsWindow>,
}

impl SessionFile {
    /// Schema version this binary writes and expects to read. Bump on any
    /// breaking change to the `model/` types. Older sidecars fail with
    /// `KError::SchemaMismatch`; re-run `save` to overwrite.
    pub const CURRENT_SCHEMA: u32 = 1;
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct OsWindow { pub tabs: Vec<Tab> }

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Tab {
    pub title: Option<String>,             // None when blanked by sanitizer
    pub layout: String,                    // "splits" | "stack" | ...
    /// Index INTO the post-Phase-0.75-filter `windows` Vec (i.e., after the
    /// filter that drops `is_self` and `overlay_parent` entries). Sourced from
    /// the corresponding kitty `@ ls` JSON `is_active` flag during Phase 1
    /// assembly: the assembler walks the filtered window list and records the
    /// position of the entry whose `is_active == true`. Consumed by the §C.1
    /// Phase 4 patcher to emit `focus_matching_window var:ksession_id=<uuid>`
    /// for the active window's UUID. Reference Bash `ksession.sh:733–737`.
    pub active_window_idx: usize,
    pub windows: Vec<Window>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Window {
    pub kitty_id: u64,
    /// Stable identity for this window, assigned client-side during Phase 0.5
    /// (§5.7). Not optional — every `model::Window` has a `ksession_id`. For
    /// live windows, the same value is pushed to kitty via
    /// `set-user-vars ksession_id=<uuid>` so the conf patcher (§C.1) can
    /// correlate skeleton `launch` lines back to this in-memory `Window`. For
    /// synthetic empty-tab windows (Phase 2, §5.7), the `ksession_id` exists
    /// here but no kitty window holds it; §C.1's patcher MUST inject those
    /// windows into the skeleton at render time — see §5.6. Serialized as the
    /// 36-char hyphenated `Uuid` form; the in-memory representation is a
    /// `String` so pre-§C.3 manifests deserialize via `#[serde(default)]` to
    /// an empty string.
    pub ksession_id: String,
    pub cwd: Option<PathBuf>,
    pub program: Program,
    pub scrollback: Option<PathBuf>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Program {
    Nvim {
        session_vim: PathBuf,
        manifest: Option<PathBuf>,         // dump manifest JSON
        truncated_buffers: u32,            // count, for `show`
    },
    Less { file: PathBuf, byte_offset: u64, file_size: u64 },
    Shell {
        shell: ShellKind,                  // Bash | Zsh | Fish | Sh | Dash | Ash
        venv: Option<PathBuf>,
        conda: Option<String>,
        oldpwd: Option<PathBuf>,
    },
    Tmux {
        session_name: String,
        /// Numeric tmux session id (from `$TMUX` field 2). Used at SAVE time to
        /// address the session via `-t '$<sid>'` in all control-mode queries —
        /// sidesteps name-quoting entirely (apostrophes, etc., per §5.4
        /// "Apostrophe in session name"). Not used at restore time (server
        /// restart invalidates the id); the restore.sh addresses by name.
        session_id: u32,
        restore_sh: PathBuf,
        /// Index of the active tmux window at capture time. Drives the final
        /// `tmux select-window -t "=$SESS:<idx>"` emitted by §5.4 codegen.
        /// `None` if no window was marked active during capture (headless session).
        /// Derived from the `TmuxWindow.active == true` entry, but cached here so
        /// the emitter doesn't need to scan `windows` at codegen time.
        ///
        /// INVARIANT: at serialization time, `active_window_idx == windows.iter()
        /// .find(|w| w.active).map(|w| w.idx)`. A `Deserialize` validator MUST
        /// recompute from `windows` and reject the manifest if the cached value
        /// disagrees (covers hand-edited or version-downgraded manifests).
        active_window_idx: Option<u32>,
        windows: Vec<TmuxWindow>,          // captured for `show`, not used at restore
    },
    Raw { argv: Vec<String> },
    BareShell,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct TmuxWindow {
    pub idx: u32,
    pub name: String,
    pub layout: String,                    // opaque tmux layout string
    pub active: bool,
    pub active_pane_idx: Option<u32>,      // pane index of the marked-active pane within this
                                           // tmux window during capture; `None` if no pane was
                                           // marked active (capture race). Referenced by §5.4.
    pub layout_leaf_count: u32,            // Leaf-count parsed from `layout` at capture time;
                                           // used to gate `select-layout` emission against
                                           // post-dead-pane-filter live count (§5.4).
    pub panes: Vec<TmuxPane>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct TmuxPane {
    /// window-relative `pane_index`; used as the `-t <sess>:<win>.<index>` target.
    pub index: u32,
    pub pane_pid: u32,                     // used for recursive adapter dispatch (§5.5)
    /// tmux `pane_id` with leading `%` stripped (the `%37` → `37`); used as the
    /// sidecar path component `pane-<digits>` and as the per-capture uid key
    /// (§5.4, §6, §5.5). `u64` because tmux's `pane_id` counter is server-
    /// lifetime monotonic and can overflow `u32` on long-lived servers.
    /// At query construction time the `%` prefix is re-added: emit `-t '%<N>'`
    /// where `<N>` is this field's value rendered as decimal digits — never
    /// emit `-t '<sess>:<idx>.%<N>'` (invalid tmux syntax, see §5.4 "Per-pane
    /// query batch").
    pub pane_id_digits: u64,
    pub cwd: Option<PathBuf>,
    /// `pane_current_command` captured from tmux at save time (e.g., `bash`,
    /// `nvim`, `less`). Used by `session::save::resolve_pane_program` as the
    /// exe-base fallback when `/proc/<pane_pid>/exe` is unreadable (mirrors
    /// `ksession.sh:246`'s `exe_base=$(proc_exe_base ... || echo "$cmd")` and
    /// the unknown-program fallthrough at `ksession.sh:302`). Persisted on the
    /// model so re-`show`ing the session without `/proc` access still labels
    /// panes correctly.
    pub current_command: Option<String>,
    pub program: Box<Program>,             // recursive — pane's resolved program
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct BufferDump {
    pub buf_id: i64,
    pub name: String,                      // "" for unnamed
    pub modified: bool,
    pub filetype: String,
    pub content_path: PathBuf,
    pub truncated: bool,
    pub byte_count: u64,
}
```

**`Program` is `#[serde(tag = "kind")]`** so the JSON manifest (`<name>.state/manifest.json`,
written additively alongside the existing `.conf`) is human-readable and diffable for tests.

Note: `SplitHint` was removed when §C.1's skeleton-patch path replaced from-scratch rendering — split geometry rides on `set_layout_state` (see §C.1).

---

## 5. Module designs

### 5.1 `kitty/` — calling `kitty @ ls`

> **Superseded:** §B.3.1 introduces a direct DCS socket transport (`kitty/rpc.rs`) as
> the primary path and demotes the subprocess described below to a `kitty/cli.rs`
> fallback behind a `KittyTransport` enum. Read §B.3.1 first; the content below
> describes the fallback only.

Hybrid deserialization: typed structs for the spine, `serde_json::Value` for known-flaky
fields. Kitty has shipped releases that add or omit fields between minor versions.

```rust
#[derive(Deserialize, Debug)]
pub struct OsWindow {
    pub id: u32,
    pub is_focused: bool,
    pub wm_class: Option<String>,
    pub wm_name: Option<String>,
    #[serde(default)]
    pub tabs: Vec<Tab>,
}

#[derive(Deserialize, Debug)]
pub struct Window {
    pub id: u64,
    pub pid: u32,
    pub cwd: Option<String>,               // Raw JSON form. Converted to PathBuf when building model::Window during session::save (see §4).
    pub title: Option<String>,
    pub is_focused: bool,
    pub is_active: bool,
    #[serde(default)]
    pub is_self: bool,
    pub overlay_parent: Option<u64>,
    #[serde(default)]
    pub foreground_processes: Vec<serde_json::Value>,
    /// Per-window user variables, populated from `kitty @ ls --all-env-vars`.
    /// Kitty stores values set via `set-user-vars` (and OSC 1337 `SetUserVar`)
    /// in this field on each window. `#[serde(default)]` so missing-on-older-
    /// kitty deserializes to an empty map rather than failing. Consumers:
    /// §5.5 (`adapter::shell` reads venv/conda hints set by shell hooks),
    /// §C.1 (the conf patcher reads `ksession_id` to correlate skeleton
    /// `launch` lines back to `model::Window`s), §C.2 (the OSC 1337 hook that
    /// writes these values), §C.3 (UUID tagging at Phase 0.5).
    #[serde(default)]
    pub user_vars: HashMap<String, String>,
}
```

Never `#[serde(deny_unknown_fields)]` on the top-level — kitty adds fields and we don't
want to break on a new minor release.

Subprocess: `tokio::process::Command::new("kitty").args(["@", "ls", "--all-env-vars"]).output().await`.
Wrap in `tokio::time::timeout(Duration::from_secs(5), …)` and return `KError::KittyRemote`
with the stderr on non-zero exit.

```rust
pub async fn ls_from_file(path: &Path) -> Result<LsJson, KError>;
```

Parses a pre-recorded `kitty @ ls --all-env-vars` JSON from disk. Used by
`KSESSION_FROM_LS` (§1.5) for deterministic differential testing — bypasses the
subprocess so test fixtures captured from real kitty sessions can be replayed
against the Rust port. Returns the same `LsJson` shape as the live subprocess
path; behavior is identical apart from the source of bytes.

```rust
/// Load a pre-recorded `@ ls --output-format=session` skeleton from disk.
/// Used by `KSESSION_FROM_LS` differential-testing mode (§5.7 Phase 0).
/// Convention: skeleton lives at `<from_ls_path>.skeleton` next to the JSON.
pub async fn skeleton_from_file(path: &Path) -> Result<String, KError>;
```

Consumed by `session::save` Phase 0 (§5.7) when `SaveOpts.from_ls` is set.

### 5.2 `proc/` — /proc helpers

All take a `proc_root: &Path` arg (default `/proc`) so tests can stub the filesystem:

```rust
pub fn exe_base(root: &Path, pid: u32) -> Option<String>;
pub fn cmdline(root: &Path, pid: u32) -> Option<Vec<String>>;
pub fn env_var(root: &Path, pid: u32, key: &str) -> Option<String>;
pub fn descendants(root: &Path, pid: u32) -> Vec<u32>;     // iterative DFS, root included
pub fn fdinfo_pos(root: &Path, pid: u32, fd: u32) -> Option<u64>;
```

`descendants` reads `/proc/<pid>/task/*/children` (space-separated PIDs) iteratively
to avoid stack blowup on deep trees. Same shape as the Bash `proc_descendants`.

### 5.3 `nvim_rpc/` — the centerpiece

This is the highest-value module — the place where the Rust port pays for itself.
Replaces the Bash `nvim --server … --remote-expr` shell-out (slow, racy, escape-hell)
with one persistent RPC connection per nvim.

**Socket discovery** mirrors the Bash 4-tier lookup but is more robust:

```rust
pub fn socket_for_pid(rt: &Path, pid: u32, tree: &[u32]) -> Option<PathBuf> {
    // 1. NVIM_LISTEN_ADDRESS env on the pid
    // 2. ${rt}/nvim.<pid>.0 and ${rt}/nvim.<pid>.*
    // 3. ${rt}/nvim.${USER}/*/nvim.<pid>.* (older convention)
    // 4. Last resort: scan rt for nvim.<X>.0; accept if X ∈ tree
    //                 (handles foreground_processes under-reporting)
    // Returns None on any I/O error rather than propagating — caller degrades.
}
```

**Connection lifecycle**: one `NvimConn` per nvim, held for the whole per-window
capture (mksession + list_bufs + N × {get_option ×3, get_lines}). Drop = teardown.
nvim-rs requires spawning the IO handler future; if you drop the JoinHandle the
connection silently dies — keep it.

```rust
pub struct NvimConn {
    nvim: Neovim<WriteHalf<UnixStream>>,
    _io_handle: JoinHandle<Result<(), Box<LoopError>>>,
}

impl NvimConn {
    pub async fn connect(sock: &Path) -> Result<Self, NvimError> { ... }

    /// Synchronous mksession via nvim_command (no polling!).
    /// nvim_command returns when the Ex command finishes — including `mksession!`.
    pub async fn mksession(&self, out: &Path) -> Result<(), NvimError> {
        let cmd = format!("silent! mksession! {}", escape_vim_string(out));
        self.nvim.command(&cmd).await?;
        if !out.exists() {
            return Err(NvimError::MksessionDidNothing);
        }
        Ok(())
    }

    /// Enumerate + dump modified non-special buffers. Bounded by 8 MiB per buffer.
    pub async fn dump_modified_buffers(
        &self,
        dumps_dir: &Path,
    ) -> Result<Vec<BufferDump>, NvimError> { ... }
}
```

Key win: `nvim_command` blocks until `:mksession!` finishes. The Bash polling loop
(15 × 200ms = up to 3s) collapses to zero overhead in the happy path.

**Restore format** — switch from the Bash approach (appended `s:KsessionRestoreBuffer`
vim function) to a **JSON sidecar + tiny Lua loader**. JSON is the data, Lua is the
loader, no quoting hell:

```
<name>.state/nvim/win-<id>.vim       # mksession output (unchanged)
<name>.state/nvim/win-<id>.json      # NEW: BufferDump manifest
<name>.state/nvim/win-<id>.dumps/
    buf-<n>.txt                      # one file per modified buffer (unchanged)
```

Append one line to the session.vim (instead of the full restore function body):

```vim
" ---- ksession buffer restore ----
lua require('ksession_restore').load(vim.fn.expand('<sfile>:p:h') .. '/win-XYZ.json')
```

Ship `ksession_restore.lua` to `~/.local/share/nvim/site/lua/` from `make install`:

```lua
local M = {}
function M.load(json_path)
  local f = io.open(json_path, 'r'); if not f then return end
  local data = vim.json.decode(f:read('*a')); f:close()
  for _, b in ipairs(data.buffers) do
    local bnr
    if b.name ~= '' then
      bnr = vim.fn.bufnr(b.name)
      if bnr <= 0 then bnr = vim.fn.bufadd(b.name) end
      vim.fn.bufload(bnr)
    else
      bnr = vim.api.nvim_create_buf(true, false)
    end
    local lines = vim.fn.readfile(b.dump_path)
    vim.api.nvim_buf_set_lines(bnr, 0, -1, false, lines)
    if b.modified then vim.bo[bnr].modified = true end
    if b.filetype ~= '' then vim.bo[bnr].filetype = b.filetype end
    if b.truncated then
      vim.notify(
        ('ksession: buffer %s was truncated at capture'):format(b.name),
        vim.log.levels.WARN)
    end
  end
end
return M
```

**Size cap: 8 MiB per buffer.** Real-world edited files are <1 MiB. The cap covers
pathological-but-legitimate log review cases. Above the cap, truncate, set
`truncated: true`, log a warning. The lua loader surfaces it to the user via
`vim.notify`. Skipping entirely is worse than partial restore.

**Error degradation**: socket missing, connect refused, RPC error during mksession —
all fold to `vec!["nvim".into()]` (bare launch) with a warning log. Save never aborts
on one window's failure.

### 5.4 `tmux_rpc/` — tmux interrogation and restore.sh codegen

**Adapter trait impl (top-level entry point).** The control-flow skeleton below is the
canonical shape of `adapter::tmux`; subsequent subsections fill in the body of
`capture()`:

```rust
pub struct TmuxAdapter;

#[async_trait::async_trait]
impl Adapter for TmuxAdapter {
    fn name(&self) -> &'static str { "tmux" }

    /// Pre-resolved by `session::save::resolve_target_program` (Step 8,
    /// ksession.sh:537–554) before this adapter is consulted: the orchestrator
    /// sets a per-ctx flag when the foreground program (or one of its
    /// descendants) is a tmux client. `detect()` reads that flag — it does NOT
    /// re-walk descendants here. Returns `false` immediately when
    /// `ctx.depth >= MAX_ADAPTER_DEPTH` to short-circuit nested-tmux recursion.
    fn detect(&self, ctx: &WindowCtx) -> bool {
        ctx.depth < MAX_ADAPTER_DEPTH && ctx.target_program_hint == Some(TargetHint::Tmux)
    }

    async fn capture(&self, ctx: &WindowCtx) -> Result<Program, AdapterError> {
        // 1. probe tmux -V (entry step 1)
        // 2. parse $TMUX from /proc/<ctx.fg_pid>/environ → (socket, server_pid, sid)
        // 3. open/reuse TmuxControl from ctx.tmux_servers keyed on (socket, server_pid)
        // 4. list-clients, match ctx.fg_pid → session_name
        // 5. for each window: list-panes, per-pane field queries (incl. pane_active)
        // 6. for each pane: synthesize child WindowCtx { depth: ctx.depth + 1,
        //    uid: pane_id_digits.to_string(), state_dir: scoped, .. }, dispatch
        //    via ctx.registry
        // 7. generate restore.sh + write to disk
        // 8. return Program::Tmux { session_name, session_id, restore_sh, ... }
        //
        // Any documented degrade path (tmux missing, $TMUX empty, list-clients
        // no-match, empty list-windows/list-panes, illegal session name)
        // returns Ok(Program::Raw{["tmux".into()]}) or Ok(Program::BareShell)
        // — NEVER Err. Per §5.5 Registry semantics any Err already folds to
        // BareShell at the orchestration layer, but the tmux adapter prefers
        // explicit degrades so the orchestrator can preserve "this was a tmux
        // window" semantics across re-saves.
        todo!()
    }
}
```

**WindowCtx fields consumed by this adapter:** `fg_pid`, `kitty_window` (for cwd /
user_vars), `state_dir`, `uid` (the outer kitty_id), `proc_root`, `registry`,
`tmux_servers`, `depth`, `target_program_hint`. The orchestrator initializes
`depth = 0` at the top-level dispatch; recursive pane dispatches increment.

Mirror the field-per-call pattern the Bash version finally landed on after the
delimiter-escape pain (kitty escapes `\x01`, tmux escapes `\x01`, neither passes
control bytes through their format strings reliably):

```rust
async fn list_windows(sess: &str) -> Result<Vec<TmuxWindowMeta>> {
    let raw = tmux(&["list-windows", "-t", sess, "-F", "#{window_index}"]).await?;
    let mut out = Vec::new();
    for win_idx in raw.lines() {
        out.push(TmuxWindowMeta {
            idx: win_idx.parse()?,
            name:    display_message(sess, win_idx, "window_name").await?,
            layout:  display_message(sess, win_idx, "window_layout").await?,
            active:  display_message(sess, win_idx, "window_active").await? == "1",
        });
    }
    Ok(out)
}
```

N+1 calls, but correct, and N is small (≤20 panes per session in practice).
Parallelism here buys nothing because tmux's server is single-threaded. Same N+1
shape applies to `list-panes` per window — but per-call cost is ~1 ms over
control mode (§B.3.2), so N+1 is acceptable at typical session sizes.

**Transport note.** The `tmux(…)` and `display_message(…)` calls in the snippets
above are wrappers over the long-lived `tmux -C attach` control-mode pipe owned
by the adapter (see §B.3.2). Concretely:

- `tmux(&["list-windows", "-t", sess, "-F", "#{window_index}"]).await?` desugars
  to `control.request("list-windows -t '<sess>' -F '#{window_index}'").await?`
  on the per-server `TmuxControl` handle in `WindowCtx`.
- `display_message(sess, win_idx, field).await?` desugars to
  `control.request(format!("display-message -p -t '<sess>:<idx>' '#{{<field>}}'"))
  .await?` with the format-string brace escaping.

The pipe is **not** a subprocess fork per call. One persistent pipe per
`(socket_path, server_pid)` is reused for every query and for `capture-pane`.
Spawning a subprocess per call would erase the ~5× speedup measured in §B.3.2.

The shorthand is editorial only — actual call sites use
`control.request(&str) -> Result<Vec<String>>` directly, where the response is
the lines between `%begin` and `%end` (a single line for `display-message -p`,
multiple lines for `list-windows`/`list-panes`).

#### Entry: client pid → session name

Bootstrap ordering (this is the order the adapter does things, not what gets
emitted to restore.sh):

1. Probe `tmux` availability first: spawn `tokio::process::Command::new("tmux").arg("-V")` with a 1 s timeout. If `which`/exec fails (ENOENT) or returns non-zero, emit `Program::Raw { argv: vec!["tmux".into()] }` (bare `tmux` launch — user lands in whatever default config their tmux has when they next run it) and `warn!`-log `tmux adapter: tmux not in PATH; bare launch`. Mirrors `ksession.sh:314–318`. Skip all subsequent steps for this window. On success, **parse stdout into a `(major, minor)` tuple** (`tmux 3.4` → `(3, 4)`; strip any trailing suffix like `tmux 3.4a` before parsing the minor — split on the first non-digit after the dot). Stash on the adapter's per-process state. §B.3.2's `<3.2` layout-corruption fallback consumes this; it MUST be available before the control-mode pipe is opened, so the probe is the canonical version source.

2. Read `$TMUX` from `/proc/<fg_pid>/environ`. Expected format:
   `<socket_path>,<server_pid>,<session_id>`. Field 0 is the tmux server socket;
   field 1 is the server pid; field 2 is the **numeric session id** (not name)
   that the foreground tmux client is attached to. If `$TMUX` is empty, the
   foreground tmux is not connected to a server — emit `Program::BareShell` and
   warn-log. Note: `$TMUX` parsing is net-new in the Rust port. Bash (ksession.sh:322) skips it and goes directly to `tmux list-clients` over a one-shot subprocess. The Rust port needs `$TMUX` because the persistent control-mode pipe must be opened against the specific server the foreground tmux client is attached to — see §B.3.2's `Command::env` requirement (risk-table row at line 1843).

3. Look up (or open) a persistent control-mode pipe in `WindowCtx.tmux_servers`
   keyed by `(socket_path, server_pid)`. The first lookup for a server spawns
   `tmux -C attach -r -t '$<session_id>'` (the `$<id>` syntax targets by
   numeric session id — see §B.3.2 — and `-r` aliases to
   `read-only,ignore-size` on tmux ≥ 3.2 for layout-corruption mitigation).

4. Over that pipe, run `list-clients -F '#{client_pid} #{session_name}'` and
   match column 1 against the foreground process pid to learn the session name
   (which is what subsequent commands address):

```sh
tmux list-clients -F '#{client_pid} #{session_name}'
# match column 1 against fg_pid; column 2 is the session
```

If no row matches the pid (client died mid-save, attached to a different server's
socket, or the pid is some non-client tmux helper), do **not** synthesize a stub.
Emit `Program::BareShell` and `warn!`-log `tmux pid=<pid>: no attached session`.
Same degrade path as "tmux not in PATH" (ksession.sh ~314–318).
Symmetrically, if `control.request("list-clients …")` itself returns `Err` (server died between `$TMUX` parse and pipe open; control-mode pipe spawn failed; pipe was closed by tmux's `%exit` mid-request), degrade the same way: `Program::BareShell` + `warn!`-log `tmux pid=<pid>: list-clients failed: <err>`. By §5.5 Registry semantics any adapter `Err` already folds to `Program::BareShell` at the orchestration layer; this inline note exists only so reviewers don't read steps 3–4 as assuming the pipe is always reachable.

Subsequent queries (`list-windows`, `list-panes`, `display-message`,
`capture-pane`) all run over the same pipe and address the just-resolved session
name via `-t <sess>`. Other sessions on the same tmux server are also reachable
via `-t <other_sess>:…` over the same pipe (control-mode clients can address
any session on their server, not just the one attached).

#### Cross-reference: tab-title sanitization

When this adapter fires on a window, the parent tab's title (from
`kitty @ ls`) is almost certainly polluted — it'll be the stale shell command
that ran `exec tmux …` before tmux took over. The sanitization that blanks such
titles lives at the **orchestration layer** in `session::save::blank_polluted_titles`
(Bash `ksession.sh:691–712`), not in this adapter. Step 8 implements it; Step 7's
contract with the orchestrator is just that `Program::Tmux` is recognizable so
the sanitizer can target tabs containing it. See §11 "Polluted tab-title
sanitization location" and the `polluted_title_blanked.rs` regression test.

#### Per-pane query batch

For each window, fetch pane metadata via the field-per-call pattern:

```sh
tmux list-panes -t '<sess>:<win_idx>' -F '#{pane_id}'
# then for each pane_id, one display-message -p per field, addressing the pane
# by its globally-unique `%`-prefixed id (NOT '<sess>:<idx>.<pane_id>' — tmux
# parses the `.` separator and expects an integer pane index, not `%N`):
tmux display-message -p -t '%<digits>' '#{pane_index}'
tmux display-message -p -t '%<digits>' '#{pane_pid}'
tmux display-message -p -t '%<digits>' '#{pane_current_path}'
tmux display-message -p -t '%<digits>' '#{pane_current_command}'
tmux display-message -p -t '%<digits>' '#{pane_dead}'
tmux display-message -p -t '%<digits>' '#{pane_active}'
```

The exhaustive per-pane field list is **6 calls** (`pane_index`, `pane_pid`,
`pane_current_path`, `pane_current_command`, `pane_dead`, `pane_active`); the
~1 ms control-mode RTT (§B.3.2) puts each window's pane-query cost at
`~6 ms × pane_count`, not the under-counted "1 ms each" the earlier draft
implied.

Same delimiter-escape rationale as `list-windows` above — tmux's `-F` does not reliably escape non-printable bytes; ksession.sh:360–361 inherits the same decision. N+1 round-trips here are tolerable because control-mode RTT is ~1 ms (§B.3.2).

Parse into `Vec<PaneMeta>`. Skip panes where `pane_dead=1` — restoring as a live
split would respawn the shell unexpectedly. **NET-NEW BEHAVIOR (not Bash
parity).** ksession.sh contains zero references to `pane_dead`; its loop at
lines 374–425 iterates every pane unconditionally and emits a `split-window` for
each, including dead ones. The Rust port introduces this filter as a deliberate
improvement, paired with the `select-layout` leaf-count guard below — reviewers
should not assume "this matches Bash" for the dead-pane handling. `pane_pid` is required for the
recursive registry dispatch in §5.5 (the adapter for an nvim pane needs the pid
to find its socket); `pane_current_path` is `TmuxPane.cwd`. `pane_index` is the
tmux-internal window-relative index used as the target for restore-time
`select-pane` and `split-window`/`new-window` window-position arithmetic.
`pane_active=1` marks the active pane within the window; recorded per-window for
the focus trailer (§5.4 "Layout + focus trailer"). `pane_current_command` is
captured as the exe-base fallback when `/proc/<pane_pid>/exe` is unreadable
(mirrors Bash ksession.sh:246 — `exe_base=$(proc_exe_base ... || echo "$cmd")` —
and the unknown-program fallthrough at ksession.sh:302).

**Dead-pane filter and layout consistency.** When any `pane_dead=1` panes are
filtered out, the captured `window_layout` string still encodes the full pane
count. Emitting `select-layout <captured>` against a window whose pane count
differs from the captured layout's leaf count is unsafe in both directions. Per
tmux source (`layout-custom.c::layout_parse`):

- If live panes **exceed** layout cells, tmux errors with a message of the form
  `have N panes but need M` and `select-layout` returns non-zero — the window is
  left in whatever state it was already in.
- If live panes are **fewer** than layout cells, tmux destructively prunes cells
  from the layout tree to fit, applying the resulting shrunken layout. The user
  sees a layout that is neither what was captured nor a sane default.

Neither outcome is desirable when the dead-pane filter removed panes between
capture and emit.

Mitigation: only emit `tmux select-layout` for a window when **both** of the
following hold:

1. The captured `window_layout` string is non-empty (matches Bash
   `ksession.sh:428`'s `[[ -n "$win_layout" ]]` guard — preserved verbatim);
   AND
2. The live pane count emitted to `restore.sh` equals the pane count encoded in
   the captured layout string (NET-NEW guard; avoiding both the
   error-and-skip and the destructive-prune branches above).

When either condition fails, OMIT the `select-layout` line for that window. On
condition (2)'s failure, warn-log `tmux window=<sess>:<win_idx>: <N> live panes
but layout encodes <M>; geometry will use default splits`. Condition (1)'s
failure is silent (Bash parity — an empty layout string is normal for
single-pane windows). The pane count in a layout string is the count
of leaf entries — parse this from the layout string at capture time. Tmux leaf format is `<W>x<H>,<X>,<Y>,<pane_id>` — three comma-separated integers after the `WxH` cell-size token, with `pane_id` being a bare integer (no `%` prefix in layout strings). Count leaves by scanning for that 4-token tail pattern; nested groups are delimited by `[]` (vertical splits) and `{}` (horizontal splits) per `layout-custom.c`. Store alongside the layout string in `TmuxWindow`, OR re-count at emit time.

#### Restore-time collision policy (`KSESSION_FORCE`)

The collision branch is decided **at restore time, by the generated `restore.sh`**,
*not* at save time by Rust. Rust emits both branches into the script unconditionally
(ksession.sh ~342–354); the runtime env var picks which fires:

- **Default** (`KSESSION_FORCE` unset/empty): if `tmux has-session -t "$SESS"` succeeds,
  print a warning to stderr and `exec tmux attach-session -t "$SESS"` — attach to
  the live session, do not rebuild. The captured layout is assumed stale.
- **Forced** (`KSESSION_FORCE=1`): `tmux kill-session -t "$SESS"`, fall through, rebuild
  from the captured commands.

The template's `$SESS` is a bash variable; Rust emits **two** session-assignment
lines as the first body lines after the template (mirroring Bash
`ksession.sh:339–340`, which does `printf 'ORIG_SESS=%q\n' "$sess"` then
`echo 'SESS="$ORIG_SESS"'` — the `ORIG_SESS` indirection survives later
re-assignments to `SESS` inside the body, e.g. when the user wants to override
just the displayed name without losing the original target). The template
includes everything from `#!/bin/bash` through the second `fi`.

```sh
ORIG_SESS=<shell-escaped session name>
SESS="$ORIG_SESS"
```

The emitted preamble is verbatim:

```sh
#!/bin/bash
set -euo pipefail
if [[ -z "${KSESSION_FORCE:-}" ]] && tmux has-session -t "=$SESS" 2>/dev/null; then
  echo "ksession: tmux session $SESS already exists — attaching to live session (set KSESSION_FORCE=1 to rebuild)." >&2
  exec tmux attach-session -t "=$SESS"
fi
if tmux has-session -t "=$SESS" 2>/dev/null; then
  tmux kill-session -t "=$SESS"
fi
```

This belongs in `templates/tmux_restore_header.sh` (`include_str!`).

Three non-obvious specifics in the preamble:

- **`#!/bin/bash`, not `#!/usr/bin/env bash`.** Bash (ksession.sh:336) emits `#!/usr/bin/env bash`; the Rust port fixes this. The absolute path survives `PATH`
  weirdness and noexec mounts on the state dir, and avoids relying on `/usr/bin/env`
  resolving to a working bash at restore time. Same rationale as the kitty `.conf` invocation `launch /bin/bash <restore_sh>`
  in §5.4 "restore.sh execution bit". The script is also invoked
  explicitly via `/bin/bash <path>` from the kitty `.conf`, so the shebang is
  defensive belt-and-braces.

- **`-t "=$SESS"` (literal `=` prefix), not `-t "$SESS"`.** Tmux's target-session
  resolution falls back to start-of-name prefix matching: `has-session -t prod` returns
  success against a live session named `production`. Without the `=` prefix, a captured
  session named `prod` would (a) spuriously detect collision against `production` and
  attach to the wrong session by default, or (b) under `KSESSION_FORCE=1`,
  `kill-session -t prod` would **destroy `production`**. The `=` forces exact-name
  match. Applies to all three target uses in the preamble (`has-session`,
  `attach-session`, `kill-session`). The `new-session -s "$SESS"` further down in the
  body does NOT need `=` (it's creation, not resolution). Bash (ksession.sh:342–354)
  has this bug; the Rust port fixes it. Covered by a new regression test —
  see §8: `tmux_collision_exact_match.rs`. Note that tmux's `cmd-find.c` applies `=` exact-match resolution to the **session and window** components of any target; the pane component (`.N`) has no `=` parsing of its own. The four `=$SESS`/`=$SESS:<idx>`/`=$SESS:<idx>.<pane>` uses in Step 7 emit (`has-session`, `attach-session`, `kill-session`, `select-pane`, `select-window`) all benefit because the session token is exact-matched in every case.

- **`set -euo pipefail` (fix vs Bash).** Bash `ksession.sh:338` emits `set -e` only; the
  Rust port upgrades to `set -euo pipefail`. Three concrete wins from the upgrade:
  (`-u`) catches typos in body variable expansions like `"$ORIGI_SESS"` at
  generation-evolution time rather than producing an empty-string target that
  silently destroys the wrong session under `KSESSION_FORCE=1`; (`-o pipefail`)
  catches future emission patterns that add pipelines; (`-e` retained) aborts on the
  first failed `new-window` rather than letting the trailing `exec tmux
  attach-session` succeed against a half-built session and present a corrupted
  layout (compounded by `--hold` per §C.4, which would otherwise surface the
  stderr). Covered by `tmux_restore_sh_strict_mode.rs` (§8).

- **KSESSION_FORCE race window.** Between the preamble's
  `tmux kill-session -t "=$SESS"` and the body's `tmux new-session -d -s "$SESS"`,
  a concurrent reconnecting client can re-create a session at the same name on a
  multi-user/multi-client tmux server (unusual on a single-user desktop but legal).
  In that case `new-session -d` fails with `duplicate session: <SESS>` and `set -e`
  aborts the script. We do NOT retry: retrying would race indefinitely against a
  pathologically-respawning client, and a single failed restore surfaced via
  `--hold` is better than a silent retry loop. The error is user-visible and the
  user can re-run with `KSESSION_FORCE=1`. Documented here so reviewers reading
  the preamble don't assume retry behavior was forgotten.

#### Three-way pane-emission state machine

For each pane, the emitted command depends on `(first_win, first_pane)` flags
(ksession.sh ~399–424). Same enumeration discipline as "always argv, never
send-keys":

- **first window, first pane** → bootstrap the session:
  ```sh
  tmux new-session -d -s "$SESS" -n <win_name> -c <pane_cwd> <prog_argv>
  ```
- **first pane of any subsequent window** → new window in the existing session:
  ```sh
  tmux new-window -t "$SESS:<win_idx>" -n <win_name> -c <pane_cwd> <prog_argv>
  ```
- **any later pane in a window** → split the existing window:
  ```sh
  tmux split-window -t "$SESS:<win_idx>" -c <pane_cwd> <prog_argv>
  ```

**Known bug: pane↔position scrambling under `select-layout` (v1 parity with Bash).**

`select-layout <layout-string>` reassigns pane dimensions in pane-index order — it
does NOT swap pane *contents* to match position assignments in the captured layout
tree. If the captured layout was constructed by manual user rearranging
(`swap-pane`, `move-pane`, etc.) so that pane indices do not run monotonically
across the geometric tree, the restored window shows correct geometry but the
programs land in scrambled positions (e.g., the editor that was on the right ends
up bottom-left).

Bash (`ksession.sh:399–430`) has the same bug. The v1 Rust port preserves Bash
behavior for parity. **TODO(v2):** either (a) drive split direction (`-h`/`-v`)
and `-l <size>` from the layout-tree walk so panes are created in the layout's
intended geometric order (avoiding select-layout entirely), or (b) after
splits + select-layout, emit `swap-pane -s <src> -t <dst>` calls to permute panes
into the captured slot mapping. Option (a) is structurally cleaner; option (b) is
mechanical and easier to validate against the captured pane→position map. Pick
during v2 design.

**Edge cases — omit, do not pass empties:**

- If `pane_current_path` is empty, omit the `-c <pane_cwd>` flag entirely.
  Tmux 3.4 does NOT error on `-c ''` (verified empirically — it falls back to
  the server process's cwd), but emitting an empty flag yields a non-deterministic
  result that depends on whatever the server was started in. Omitting the flag
  is cleaner and lets tmux's own fallback (`-c <session-default-path>`) take
  over, matching the user's intent.
- If `win_name` is empty (relevant only for the first pane of a window), omit
  the `-n <win_name>` flag.
- **Session-name validation.** Tmux's `clean_name()` (tmux source: `tmux.c`, called from `cmd-rename-session.c`) **silently replaces** any `:` or `.` byte with `_` rather than erroring. (The plan previously claimed `#` was in the forbid set, citing a `"#:."` literal in older tmux sources — empirically verified on tmux 3.4 to be wrong: `#` is allowed in session names verbatim. The Rust port should treat only `:` and `.` as substitution triggers.) A captured session named `my.proj` is recreated as `my_proj`, so the round-trip `has-session -t "=my.proj"` collision check on re-restore would then miss the live session. Empty names cause tmux to error outright; non-UTF-8 names are also rejected. Degrade path:
  - If `sess` is empty, or contains any of `:`, `.`, or is not valid UTF-8 →
    warn-log `tmux session=<sess>: name needs cleaning by tmux, degrading to bare
    launch` and degrade the entire tmux window's capture to
    `Program::Raw { argv: vec!["tmux".into()] }`. Same degrade path as the
    empty-panes race below.
  - Do NOT silently substitute `_` ourselves and proceed — that would diverge from
    Bash and produce a different name on restore than was captured, breaking
    user-visible identity.
- **Apostrophe (`'`) in session name.** Tmux's `clean_name()` filter passes apostrophes through verbatim, but the field-per-call query pattern at §5.4 lines 415–447 desugars to `control.request(format!("list-windows -t '<sess>' -F …"))` with single-quote wrapping. Tmux's control-mode command parser (`cmd_string_split`) interprets single quotes, so a session named e.g. `dev's-laptop` would break the wrapper. **v1 picks option (b): address every save-time query by session id (`-t '$<sid>'`), where `<sid>` is the numeric session id captured from `$TMUX` field 2 at entry step 2.** This sidesteps name-quoting entirely. The cost is threading `sid: u32` through `WindowCtx` alongside `session_name`; this is paid by the `session_id: u32` field on `Program::Tmux` (§4) and the `session_id` plumbing in the Step 7↔Step 8 contract (line ~2591). Restore time still addresses by name because `$<sid>` does not survive across tmux server restarts; the apostrophe risk at restore time is mitigated by the `=$SESS` exact-match prefix plus `shell-escape::unix::escape` applied to the `SESS=` assignment (which correctly emits `'dev'\''s-laptop'`).

If `prog_argv` is empty, drop the trailing arg — tmux falls back to `default-shell`.
Never `send-keys`. Never interpolate program text into a command string; pass it as
the final positional argv of the spawn command (the Bash version uses `%q` for
exactly this reason — see below).

**Base-index drift at restore time.**

Tmux's `base-index` option (default `0`, commonly set to `1`) controls the index
of the first window in a session. If the restore environment's `base-index`
differs from what the captured session used (e.g., capture under `base-index 0`
on a server with default config, restore under `base-index 1` on the user's
configured server), the bootstrap `new-session -d -s "$SESS"` lands the first
window at the restore-env's base-index, and the subsequent
`tmux new-window -t "$SESS:<captured_idx>"` either creates a hole (if
`captured_idx > base-index`) or errors with a message of the form
`index in use: <N>` (if `captured_idx ≤ base-index`). Code emitting this branch
must not pattern-match on the exact error text — trap the non-zero exit instead.

**Mitigation: relocate the bootstrap window with `move-window`.** After
`new-session -d -s "$SESS"` creates the first window at the restore-env's
`base-index`, conditionally move it into the captured first-window index. Emit:

```sh
# Reconcile base-index drift. Determine the restore-time base-index first so
# we can refuse a destination below it (tmux rejects `index out of range`).
TMUX_BASE_INDEX=$(tmux show-options -v -t "=$SESS" base-index 2>/dev/null \
                  || tmux show-options -gv base-index 2>/dev/null \
                  || echo 0)
TMUX_BASE_INDEX=${TMUX_BASE_INDEX:-0}  # `show-options -v` can return exit=0 with empty stdout
CAPTURED_FIRST_IDX=<captured_first_window_index>
if [[ "$CAPTURED_FIRST_IDX" -ge "$TMUX_BASE_INDEX" && "$CAPTURED_FIRST_IDX" -ne "$TMUX_BASE_INDEX" ]]; then
  tmux move-window -s "=$SESS:" -t "=$SESS:$CAPTURED_FIRST_IDX" 2>/dev/null || true
fi
```

The arithmetic guard handles three cases:

- `CAPTURED_FIRST_IDX == TMUX_BASE_INDEX` (the common case when both servers use
  the same `base-index` setting): skip `move-window` entirely. Avoids tmux's
  `"same index: <N>"` non-fatal error.
- `CAPTURED_FIRST_IDX > TMUX_BASE_INDEX`: move to the captured index. Trailing
  `|| true` defensively swallows any unexpected error so the rest of the body
  proceeds.
- `CAPTURED_FIRST_IDX < TMUX_BASE_INDEX` (e.g., captured under `base-index 0`,
  restored under `base-index 1` with `captured_first_idx == 0`): the destination
  is below the restore-time `base-index` and tmux would reject with `"index out
  of range"`. **Skip the move and accept the drift** — subsequent
  `new-window -t :<captured_next_idx>` calls also need their indices clamped to
  `>= TMUX_BASE_INDEX`. Emit each `new-window` with `:<max(captured_idx,
  TMUX_BASE_INDEX)>` in this branch; record the displacement so per-window
  `select-window`/`select-pane` references at the end of the body use the
  emitted indices, not the captured ones. The trailing `|| true` is NOT
  sufficient by itself for this branch — without the guard, `move-window`'s
  error would `set -e`-abort the entire restore.

This avoids needing the previous "always emit and swallow" approach (which
silently broke under the third case) and avoids capturing `base_index` on
`Program::Tmux` (the field is not on the §4 struct).

Bash (`ksession.sh:399–430`) does not address this — sessions saved on a
default-config server and restored on a `base-index 1` server fail today. Fix
in v1.

Note on the earlier-draft `show-options -v` fallback: `show-options -v -t "=$SESS"`
returns exit=0 with empty stdout when no per-session override exists, so the
`||` fallback to the global option does not fire on exit code alone. The
`${TMUX_BASE_INDEX:-0}` parameter expansion at the end of the show-options chain
above is the load-bearing fix — it turns the empty-stdout case into `0`, which
matches tmux's documented default for `base-index`.

#### Layout + focus trailer

After all panes for a window are emitted, before moving to the next window
(ksession.sh ~428–430):

```sh
tmux select-layout -t "$SESS:<win_idx>" <window_layout>
tmux select-pane   -t "=$SESS:<win_idx>.<active_pane_idx>"   # if window had a marked-active pane
```

The per-window `select-pane` immediately follows that window's `select-layout`,
restoring the **per-window active pane**. Track this during capture by extending
the per-window state (e.g., `TmuxWindow.active_pane_idx: Option<u32>`) — during
the `list-panes` parse, whenever `pane_active=1` is seen for a pane in window
`<win_idx>`, record that pane's index on that window's metadata. Omit the
`select-pane` line for any window that has no marked-active pane (e.g., capture
race where the pane was killed between `list-panes` and the active-flag read).

After every window is emitted (ksession.sh ~433–437), append in this exact order:

```sh
tmux select-window -t "=$SESS:<active_win_idx>"
exec tmux attach-session -t "=$SESS"
```

The final `select-window` restores the active **window** (the per-window
`select-pane` calls above already restored each window's active pane, so no
global `select-pane` is needed). The `exec attach-session` is always the last
line. All three (per-window `select-pane`, final `select-window`, and final
`attach-session`) use the `=` exact-match prefix for consistency with the
preamble's bug-3 fix. The `select-window` line is omitted if no window was marked
active during capture (e.g., headless session).

**(fix vs Bash: ksession.sh:381–382 + ~433–437.)** Bash assigns
`active_pane="$win_idx.$pane_idx"` for every pane where `#{pane_active}=1` inside
its windows×panes loop, so the **last window's** active pane overwrites all
earlier per-window assignments. The single global `select-pane` Bash then emits
targets the wrong coordinate whenever the active window isn't the last window
processed. Even with that overwrite fixed, a single global `select-pane` would
only restore the active pane within the active window — all other windows
would be left with their last-split pane as active rather than the captured
active pane. The Rust port fixes both bugs by tracking active pane per window
during capture and emitting one `select-pane` per window immediately after its
`select-layout`, plus a final `select-window` to restore the active window.

#### Empty list-windows / list-panes race

If `list-windows -t <sess>` or `list-panes -t <sess>:<idx>` returns zero rows
(session torn down between `list-clients` and the iteration), the Bash version
writes a stub `restore.sh` consisting of just the preamble + `exec attach-session`,
which fails noisily at restore. The Rust port must **not** emit any restore file
in that case. Degrade the whole tmux window to `Program::Raw { argv: vec!["tmux".into()] }`
(a bare `tmux` launch — user lands in whatever session their config defaults to) and
`warn!`-log `tmux session=<sess>: empty windows/panes at capture, degrading to bare
launch`. Picking `Raw{["tmux"]}` over `BareShell` preserves the "this window was a
tmux client" semantic so a subsequent re-save sees it again.

#### Scrollback capture

Per pane, gated by `KSESSION_SCROLLBACK` (default on; `=0` opts out — ksession.sh
~392–394):

```sh
# -C: application-layer escape (octal + \\) so raw bytes are unambiguous inside
#     the %begin/%end frame (mandated by §B.3.2 "Capture-pane content needs -C").
# -e: preserve ANSI escapes for scrollback consumers.
# Decode the \NNN / \\ escapes in the Rust capture-pane response handler
# before writing the decoded bytes to <pane_dir>/scrollback.ansi.
tmux capture-pane -p -C -e -S - -t '<sess>:<win_idx>.<pane_idx>' \
  | <decode \NNN and \\ to raw bytes> \
  > <pane_dir>/scrollback.ansi
```

If the resulting file is zero bytes, **delete it**. Empty scrollback files are
worse than absent ones — they trip downstream tools that detect "has scrollback"
by file existence rather than size. ANSI escapes (`-e`) round-trip cleanly through
control mode per §B.3.2 once the `-C` decoder has run. If `capture-pane` exits non-zero (pane died mid-capture, pipe error, etc.), any partial output already written to the sidecar file is left in place — only zero-byte files from *successful* captures are deleted. Mirrors `ksession.sh:392–395`, which uses `tmux capture-pane … && [[ ! -s … ]] && rm -f …` — the `&&` short-circuits on capture failure so partial output stays. Covered by `tmux_scrollback_empty_deleted.rs` (§8).

#### Quoting — `%q` ↔ `shell-escape::unix::escape`

Bash uses `printf %q` on `sess` (ksession.sh:339, the `ORIG_SESS=` preamble
assignment), `win_name`, `pane_cwd`, `window_layout`, and `prog_cmd`
(ksession.sh ~401–429). Rust uses `shell-escape::unix::escape`. They are not
byte-identical (`%q` may emit `$'…'` ANSI-C quoting for control bytes;
`shell-escape` emits `'…'` with `'\''` for embedded quotes), but the requirement
is round-trip equivalence, not byte equality:

> Every emitted token must, when re-parsed by `bash -c`, yield the exact original
> byte string.

Enforce this in the regression suite (`tests/regression/tmux_quote_roundtrip.rs`):
fuzz over pane names, cwds, and layouts containing spaces, single quotes, double
quotes, backslashes, newlines, UTF-8, and bytes `\x01`–`\x1f`; for each, render
with `shell-escape`, prepend `printf '%s' `, eval via `bash -c`, assert stdout
matches input bytes.

**NUL byte caveat.** `shell-escape::unix::escape` will single-quote any byte
including `\x00`, but `bash -c <script>` parses argv as C strings and truncates
at the first NUL byte. The "round-trip equivalence" property therefore holds for
bytes 0x01–0xff but NOT for NUL.

Tmux metadata (pane cwd, window names, layout strings, session names) cannot
legitimately contain NUL — tmux's own field parsers reject it earlier. So in
practice the NUL case is unreachable for tmux-sourced strings. But the shell-pane
adapter reads env vars (`VIRTUAL_ENV`, `OLDPWD`, etc.) from `/proc/<pid>/environ`
where bytes are NUL-separated by definition — a malformed environ block could
theoretically yield a value containing an embedded NUL.

Defensive contract: before passing any string to `shell-escape`, the caller
MUST verify it contains no NUL byte. Implement as a `assert!` debug-build and a
`warn!`-log + degrade to bare shell in release-build. Covered by regression
test `tmux_quote_nul_rejected.rs` in §8.

#### `pane_id` → path key

Tmux pane IDs are `%<digits>` (e.g. `%37`). Strip the leading `%` before using
as a path component — §6 keys sidecars under `tmux/<sess>/win-<idx>/pane-<digits>`
(ksession.sh ~384: `local uid=${pane_id#%}`). The full `%37` form is only used
as a `-t` target when querying tmux.

#### `restore.sh` execution bit

The Bash version sets the exec bit (`ksession.sh:440`) and the adapter returns
`/bin/bash <restore_sh>` as the argv tokens that the orchestrator splices into
the kitty session-file `launch` line (`ksession.sh:442`'s
`printf '%s\n' /bin/bash "$restore_sh"` emits the adapter's return value to its
caller; it is NOT an in-script invocation). Belt and braces — keep both:

```rust
fs::set_permissions(&restore_sh, Permissions::from_mode(0o755))?;
// emitted .conf line (the patcher in Step 6.75 / §C.1 composes this from
// Program::Tmux.restore_sh, the enclosing Window.cwd, and the UUID it tagged
// pre-`save_as_session` via set-user-vars):
//
//   launch --hold --cwd <window_cwd> --var ksession_id=<uuid> \
//          /bin/bash <state_dir>/tmux/<sess>/restore.sh
```

The `--hold` flag (per §C.4) keeps the kitty window open if `restore.sh` fails,
surfacing the tmux error to the user. The `--cwd` is the enclosing kitty
`Window.cwd` from the model — it is NOT a field on `Program::Tmux`; the
conf-patcher (Step 6.75, §C.1) sources it from the `SessionFile::Window` it
correlates by UUID. The `--var ksession_id=<uuid>` tag is what the patcher uses
to correlate this launch line back to the captured `Window` on the next save
round-trip (§C.3) — preserve it verbatim; do NOT drop it when patching.

Rationale: `chmod +x` lets users run the script directly for debugging;
`/bin/bash <path>` in the kitty `.conf` survives noexec mounts (state on tmpfs
with noexec is not unheard of) and avoids relying on a shebang interpreter
existing in the restore environment.

#### Restore.sh codegen — plumbing

Build the body via `format!` and `shell-escape::unix::escape`. Use
`include_str!("templates/tmux_restore_header.sh")` for the static preamble (the
collision warning + `KSESSION_FORCE` check + `tmux kill-session` clause).

For per-pane program restore, **always pass as argv to `new-session` / `new-window`
/ `split-window`**, never `send-keys` — eliminates the race where rc-file timing
eats the input. Wrap shell-context restores in `bash -c '…; exec bash'` so the
pane survives after the activation runs (per the Bash version's lesson).

#### Per-pane program restoration

The tmux adapter recurses each pane through the same `Registry` (§5.5), so
per-program emission inside a pane mirrors kitty-level emission, with three
caveats:

**nvim panes (ksession.sh:269–280):** run the same
`NvimConn::{mksession, dump_modified_buffers}` flow as the kitty-level nvim
adapter, but write sidecars under the pane's scoped state dir:

```
<state_dir>/tmux/<sess>/win-<X>/pane-<Y>/nvim/win-<uid>.vim
<state_dir>/tmux/<sess>/win-<X>/pane-<Y>/nvim/win-<uid>.json
<state_dir>/tmux/<sess>/win-<X>/pane-<Y>/nvim/win-<uid>.dumps/
```

Where:
- `<X>` is the tmux `#{window_index}`.
- `<Y>` is the tmux `#{pane_id}` with the leading `%` stripped (§5.4 "pane_id → path key").
- `<uid>` is the pane-id digits — the same value as `<Y>` (i.e., `${pane_id#%}`,
  matching Bash `ksession.sh:384`). Bash uses the pane-id digits for BOTH the
  directory key and the sidecar filename, so the on-disk layout for an nvim pane
  is e.g. `pane-37/nvim/win-37.vim` — same digit on both sides of the slash.
  At the kitty-window level `WindowCtx.uid` is `kitty_id`; for tmux panes there
  is no kitty window id, so the pane-id digits (stable for the lifetime of the
  capture) serve as the per-capture unique key. The pane's PID is still captured
  separately on `TmuxPane.pane_pid` because it's needed to find the nvim socket
  (§5.4 "Per-pane query batch"), but it does NOT appear in any sidecar path.

Emit `nvim -S <vim-path>` as the pane's argv passed to `new-window`/`split-window`.

**less / man / more / most / pg panes (ksession.sh:281–297):** emit
`<exe> +<pct>% -- <file>`. The Bash version writes `+<pct>%%` because
`ksession.sh:293` uses the printf format string `'%s +%d%%%% -- %s'` — four
literal `%`s in the format reduce to two `%`s in printf's output. That output
is then handed to `tmux new-window`/`split-window` as a single argv string and
ultimately invoked through `/bin/sh -c`, which does NOT re-evaluate printf
format characters — so the literal `+<N>%%` reaches `less`, which mis-parses it
(`less` expects `+<N>%`, single percent). **This is a Bash bug.** The Rust port
emits via `shell-escape` (not `printf`), so a single `%` is correct and the
Rust port silently fixes the bug. Regression risk: copy-pasting the Bash format
string verbatim into Rust would emit a literal `%%`. Covered by
`tmux_less_pane_single_percent.rs` in §8.

**shell panes (ksession.sh:248–267):** read `VIRTUAL_ENV`, `CONDA_DEFAULT_ENV`,
`OLDPWD` from `/proc/<pane_pid>/environ` and wrap the shell launch as:

```sh
bash -c 'source <venv>/bin/activate; conda activate <env>; export OLDPWD=<oldpwd>; exec bash'
```

Match Bash (`ksession.sh:248–267`) exactly: emit `export OLDPWD=<oldpwd>`, **not**
`cd <oldpwd>`. The pane already starts in `pane_current_path` via tmux's `-c`; setting
`OLDPWD` lets `cd -` return to the previous directory. Using `cd <oldpwd>` would override
the `-c` and land the user in the wrong directory. The `conda activate <env>` clause
fires only when `CONDA_DEFAULT_ENV` is set and not `"base"` (Bash lines 260–262); omit
otherwise. Activation clauses are joined left-to-right and any individual clause may be
absent — emit only the ones whose source variable is set.

Bash also reads `DIRENV_DIR` but **never uses it** in the emitted string —
captured-but-unused (likely a Bash bug). For v1 parity, replicate the omission
with a `TODO(v2): wire DIRENV_DIR into pane shell activation` comment. Do not
silently fix.

**Unknown-program panes (ksession.sh:298–304):** fall back to
`/proc/<pane_pid>/cmdline` (NUL-split argv, trailing-space trim) and emit
verbatim as `Program::Raw { argv }`. Catch-all when `exe_base` is not in any
known set. **Divergence vs Bash (silently fixed).** ksession.sh:300 flattens the cmdline via `tr '\0' ' '` to a single space-joined argv string. The Rust port preserves the original argv vector via NUL-split, which restores correctly through tmux `split-window`/`new-window` (each token is a distinct argv element). Argv with embedded spaces inside a single token now restore correctly where Bash would mis-tokenize.

### 5.5 `adapter/` — the trait

```rust
pub const MAX_ADAPTER_DEPTH: u8 = 2; // max nested tmux-in-tmux recursion before degrade
```

```rust
pub struct WindowCtx<'a> {
    pub kitty_window: &'a kitty::Window,
    pub fg_pid: u32,
    pub fg_exe: Option<String>,
    pub window_root_pid: u32,
    pub state_dir: &'a Path,
    pub uid: String,                   // unique key for sidecar filenames
    pub proc_root: &'a Path,           // stub-able for tests
    pub registry: &'a Registry,        // for tmux pane recursion
    /// Memoized per-server control-mode pipes, keyed by `(socket_path,
    /// server_pid)` from `$TMUX` field 0–1. The tmux adapter looks up (or
    /// opens) `TmuxControl` here; recursive pane→registry dispatch reuses the
    /// same pipe. See §5.4 entry step 3 and §B.3.2 line ~1863.
    pub tmux_servers: &'a tokio::sync::Mutex<HashMap<(PathBuf, u32), Arc<TmuxControl>>>,
    /// Adapter error accumulator. Borrowed from `SharedCtx.errors` when
    /// `capture_window` constructs the `WindowCtx` for each kitty window.
    /// Adapters push directly into this on `AdapterError` — see
    /// `Registry::capture` below. The borrow lifetime `'a` ties this
    /// reference to the parent `session::save` invocation that owns the
    /// `SharedCtx`; the `WindowCtx` cannot outlive the save. `std::sync::Mutex`
    /// (not `tokio::sync::Mutex`) because the only operation is a brief
    /// `lock().push(e)` that never crosses a `.await` point — contrast with
    /// `tmux_servers` above, where the lock IS held across the
    /// control-socket spawn `.await` and therefore must be the async flavor.
    pub errors: &'a std::sync::Mutex<Vec<AdapterError>>,
    /// Adapter-recursion depth. Top-level kitty-window capture is `0`; each
    /// time the tmux adapter synthesizes a child `WindowCtx` for a pane,
    /// increment by one. Adapters whose `detect()` would cause infinite
    /// recursion (currently `adapter::tmux`) MUST refuse to fire when
    /// `depth >= MAX_ADAPTER_DEPTH` (default `2`), degrading the pane to
    /// `Program::Raw { argv }` with a `warn!`-log. Guards against nested
    /// tmux (common over SSH-through-tmux). See §11 "Nested tmux inside tmux".
    pub depth: u8,
    /// Set by `session::save::resolve_target_program` (Step 8 orchestration,
    /// `ksession.sh:537–554`) BEFORE the registry is dispatched, so adapter
    /// `detect()` impls do not re-walk descendants. The orchestrator walks
    /// `proc_descendants(window_root_pid)` and picks the first descendant
    /// whose exe basename is in `{tmux, nvim, less, man, more, most, pg}`;
    /// the matched program becomes `TargetHint::Tmux | Nvim | Less | …`.
    /// Adapter `detect()` impls match on this hint instead of probing /proc
    /// themselves. `None` means no descendant matched a known program — the
    /// `adapter::shell` and `adapter::raw` fallbacks fire on hint match
    /// against their own variants. Centralizing the walk here is what allows
    /// the §11-row-1516 statement "detection lives at the orchestration
    /// layer, not in the adapter" to be true.
    pub target_program_hint: Option<TargetHint>,
    /// Memoized /proc reads for the current save (§B.4). Borrowed from
    /// `SharedCtx.proc` by `capture_window` so adapters can read env vars
    /// and cmdlines without re-syscalling — populated lazily on first
    /// touch.
    pub proc: &'a crate::proc::ProcCache,
    /// Parent tab's layout string ("splits" | "stack" | …), threaded in so
    /// adapters that emit split-position hints (Bash 558–562) can vary on
    /// it. Pure read; adapters never mutate.
    pub tab_layout: &'a str,
    /// Gated by `KSESSION_SCROLLBACK` (§1.5), resolved once by `cli/save`
    /// and threaded through `SharedCtx`. Adapters consult this to decide
    /// whether to spend RPC budget on `capture-pane` calls.
    pub scrollback_enabled: bool,
}
```

**Mutex flavors (pinned).** `WindowCtx` references two mutexes with different
sync flavors, on purpose:

- `errors: &'a std::sync::Mutex<Vec<AdapterError>>` — sync mutex. The push
  inside `Registry::capture` is brief and never crosses an `.await`. A sync
  mutex is cheaper and won't accidentally yield to the runtime mid-push.
- `tmux_servers: &'a tokio::sync::Mutex<HashMap<…, Arc<TmuxControl>>>` —
  async mutex. The lock IS held across the `.await` that spawns the
  control-mode socket when a `(socket_path, server_pid)` entry is vacant.
  A `std::sync::Mutex` here would either deadlock the runtime or force a
  drop-before-await dance that races concurrent adapter calls. Pin this
  in code as `tokio::sync::Mutex` — do not "simplify" it.

```rust
/// Pre-resolved target program for an adapter dispatch. See `WindowCtx
/// .target_program_hint`. The variants correspond 1:1 with `Adapter` impls.
/// Pinned to exactly 6 variants. Descendant exe basenames `more`, `most`, `pg`
/// MAP to `TargetHint::Less` — they share the less adapter (pager family with
/// identical capture surface: file path + byte offset).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TargetHint { Tmux, Nvim, Less, Man, Shell, Raw }


#[async_trait::async_trait]
pub trait Adapter: Send + Sync {
    fn name(&self) -> &'static str;
    fn detect(&self, ctx: &WindowCtx) -> bool;
    async fn capture(&self, ctx: &WindowCtx) -> Result<Program, AdapterError>;
}

pub struct Registry { adapters: Vec<Box<dyn Adapter>> }

impl Registry {
    /// Returns `Program` (not `Result<Program, AdapterError>`): degrades
    /// internally on `AdapterError`, pushing the error into a
    /// `ctx.errors: Mutex<Vec<AdapterError>>` accumulator owned by Step 8's
    /// `SharedCtx`. Per-adapter failures never abort the save; the worst case
    /// is a `Program::BareShell` fallback for the offending window. See §5.7
    /// for the observability hook that drains the accumulator into the
    /// per-session warnings log at the end of `session::save`.
    pub async fn capture(&self, ctx: &WindowCtx) -> Program {
        for a in &self.adapters {
            if a.detect(ctx) {
                match a.capture(ctx).await {
                    Ok(p) => return p,
                    Err(e) => {
                        tracing::warn!(adapter = a.name(), ?e, "capture failed");
                        ctx.errors.lock().push(e);
                    }
                }
            }
        }
        Program::BareShell
    }
}
```

**Tmux recursion**: the tmux adapter holds `&Registry` (passed via `ctx.registry`)
and for each pane builds a synthetic `WindowCtx` (state_dir scoped to
`tmux/<sess>/win-<X>/pane-<Y>`, fg_pid from `pane_pid`, `uid` set to the pane-id
digits — `pane_id.trim_start_matches('%').to_string()`, the same value used as
`<Y>` in the path; see §5.4 "nvim panes") and dispatches against the same
registry. One adapter set works at OS-window level and inside tmux panes.

`WindowCtx.uid` is the unique key adapters embed in sidecar filenames
(`nvim/win-<uid>.vim`, etc.). At the kitty-window level it's `kitty_id`; for tmux
panes there is no kitty window id, so the pane-id digits (`${pane_id#%}`, per
Bash `ksession.sh:384`) serve as the stable per-capture key — the same value
used for the `pane-<Y>` directory component. See §5.4 "nvim panes" for the
resulting sidecar layout (`tmux/<sess>/win-<X>/pane-<Y>/nvim/win-<Y>.vim`, i.e.,
same digit on both sides of the slash).

**Restore rendering** is a separate trait, kept apart from capture:

```rust
pub trait Restorable {
    /// argv for a fresh kitty launch line. Used by the fallback from-scratch
    /// renderer; under §C.1 conf-patch this is invoked only when the kitty-emitted
    /// `ls --output-format=session` skeleton lacks a launch line for the window
    /// (rare — race with new windows opening mid-save).
    fn kitty_argv(&self) -> Vec<String>;
    /// argv passed as the final positional arguments to `tmux new-session` /
    /// `new-window` / `split-window`. None = let tmux launch `default-shell`.
    fn tmux_argv(&self) -> Option<Vec<String>>;
}
impl Restorable for Program { /* dispatch per variant */ }
```

Rationale: returning a single `String` invites the "is this already shell-quoted?"
ambiguity. Returning argv pushes shell-escape into the codegen layer, where it belongs.

This split lets `conf::render` (fallback path) and `tmux_rpc::generate_restore_sh`
be pure functions over the captured `Program`, easily unit-testable.

**Note on `Program::Tmux::kitty_argv`:** under the §C.1 conf-patch pipeline (the
primary code path), the kitty-level launch line for a tmux window is rewritten by
the patcher to `/bin/bash <restore_sh>`, not emitted by this trait. The trait
method exists for the from-scratch fallback only; for `Program::Tmux` it returns
`vec!["/bin/bash".into(), restore_sh.to_string_lossy().into()]` — same form as
the patcher emits, so the two paths converge.

**Caveat on the fallback path:** `kitty_argv` returns only `["/bin/bash", restore_sh]`
— it does NOT add `--hold` or `--cwd <window_cwd>`. If the conf-patcher fails to
locate the launch line (e.g., the kitty `ls --output-format=session` skeleton was
empty due to a save-time race) and the fallback fires, the resulting kitty window
will close immediately if `restore.sh` errors, hiding the failure from the user (the
inverse of §C.4's intent). This is a known shortcoming of the dead-code fallback and
is acceptable because the primary path always patches `--hold` in; document loudly
in code comments so a future refactor that demotes the conf-patcher doesn't silently
regress error-surface behavior.

Note: `adapter::shell` consumes `kitty_window.user_vars` populated by the OSC 1337
hook described in §C.2, with `/proc/<pid>/environ` as fallback. The hook
(`ksession-shell-hook.sh`) ships separately and is a prerequisite for venv/conda/oldpwd
capture from non-cooperating shells.

**`adapter::raw` — argv source.** The Raw adapter (catch-all when no
known-program hint matches) MUST read argv from
`ctx.kitty_window.foreground_processes[-1].cmdline` (the snapshot kitty
captured at exec time, surfaced via `kitty @ ls`), NOT from
`/proc/<pid>/cmdline`. Rationale: argv-rewriting daemons —
`prctl(PR_SET_NAME)` callers, supervisors like `s6`, `runit`, language
runtimes that rebrand their process title (Postgres, gunicorn) — can mutate
`/proc/<pid>/cmdline` after exec, but kitty's recorded value is the
original argv at fork/exec time. Restoring the post-mutation title would
produce a launch line that no longer runs the intended program. Matches
Bash `ksession.sh:581`. The tmux-pane Raw fallback (§5.4 "Unknown-program
panes," `ksession.sh:298–304`) does still read `/proc/<pane_pid>/cmdline`
because there is no equivalent kitty-side snapshot for tmux panes —
divergence between the two Raw paths is intentional and documented here.

### 5.6 `conf/` — kitty session-file emitter

> **Superseded:** §C.1 replaces from-scratch rendering with a skeleton-patcher
> pipeline. The actual `conf::render` signature is `render(skeleton: &str, session: &SessionFile, gen_us: u64) -> String` — it patches launch lines emitted by `kitty @ ls --output-format=session`, embedding absolute paths into `<sessions>/<name>.gen-<gen_us>.state/` for every sidecar reference (nvim session, tmux restore.sh, scrollback). `gen_us` is the generation timestamp resolved in §5.7 Phase 0; the patcher uses it to construct absolute paths because `SessionFile` itself does not carry the gen suffix. The from-scratch text below describes the
> obsolete v0 design; §C.1 is canonical.

Port the Bash `kq()` function literally — **not** with `shell-escape`. Kitty's session
syntax does `${VAR}` expansion BEFORE shlex parsing, so its quoting rules are different
from POSIX shell. `shell-escape` would silently break `$VAR` because it backslash-
escapes `$` in double-quoted output. Two different contexts; don't conflate them.

```rust
/// Quote one arg for a kitty session-file `launch` line.
fn kq(s: &str) -> Cow<'_, str> {
    static SAFE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^[A-Za-z0-9_./@:=+,-]+$").unwrap());
    if SAFE.is_match(s) {
        Cow::Borrowed(s)
    } else {
        Cow::Owned(format!("'{}'", s.replace('\'', r"'\''")))
    }
}
```

15 lines. Done.

#### Render contract — required header and emitted lines

`conf::render(skeleton, session)` MUST produce output that conforms to the
following contract. The patcher in §C.1 is the implementation; this section
specifies the externally-observable shape.

**Header (F#20 — `# Description:` line).** The renderer prepends three header
lines to the output before the skeleton body:

```
# Description: ksession save '<name>' at <RFC3339 timestamp>
# Generated by ksession-rs <crate_version>
# To restore: kitty --detach --class "kitty-project-<name>" --session <this-file>
```

The first line is parsed by `cli/list` and `ksession-save-prompt.sh` to
populate the description column in the fzf save-prompt preview. Matches
Bash `ksession.sh:654–658`. Without this header, the save-prompt preview
loses the description column — this is a hard requirement, not a nice-to-have.
`<name>` is the save name; `<RFC3339 timestamp>` is `chrono::Utc::now().to_rfc3339()`.
`<crate_version>` is `env!("CARGO_PKG_VERSION")`. The third line preserves
the Bash restore hint (Bash `ksession.sh:656` emits a single longer line with
the same hint) for human readers grepping a saved `.conf`; `cli/list` only
parses the first line, so the third line is documentation-only.

**Per-tab `focus_matching_window` emission (F#21).** After each tab's
`launch` lines, the renderer emits

```
focus_matching_window var:ksession_id=<active_uuid>
```

when the active window in that tab is not the first window in the tab.
`<active_uuid>` is `model::Window.ksession_id` for whichever window in the tab has
`is_active == true` per the original kitty JSON. If the active window is
the first one (the default focus target), the line is omitted — kitty's
default already focuses the first window of a tab. The §C.1 patcher
implements this emission directly in the per-tab block walk.

> **Divergence from Bash.** This diverges from Bash `ksession.sh:736`,
> which uses `var:ksession_idx=<int>` (a tab-relative integer index). The
> Rust port substitutes a UUID per window because UUID correlation is the
> spec'd mechanism for skeleton-launch-line → captured-`model::Window`
> lookup (§C.1 patcher). The conf body therefore is NOT byte-equivalent
> to Bash output; §6 "preserve every existing path" applies to filesystem
> layout, not conf-line contents.

**`new_os_window` separator between OS windows (F#23).** When `SessionFile`
contains more than one `OsWindow`, the patcher emits a literal
`new_os_window` line between consecutive OS-window blocks of the rendered
conf. Note that kitty's `@ ls --output-format=session` emits only one OS
window per invocation; for multi-OS-window saves the orchestrator MUST
issue one `--output-format=session` call per OS-window and concatenate the
resulting skeletons with `new_os_window` separators (option (a) — chosen
over (b) "patcher hand-crafts subsequent OS-window blocks from the model"
because option (a) keeps the patcher's "the skeleton is canonical for
layout" invariant intact and avoids duplicating kitty's layout-emission
logic in Rust).

> **TODO (cross-section, §5.7 Phase 0):** §5.7 Phase 0 (skeleton fetch)
> must therefore iterate OS-windows and issue one
> `kitten @ action save_as_session --save-only --match
> id:<os_window_id> --use-foreground-process <tmp_per_osw>` call per
> OS-window, concatenating the outputs with `new_os_window` between them
> before handing the joined skeleton to `conf::render`. A single
> `save_as_session` call covers exactly one OS-window's skeleton; this
> contract must be honored by Phase 0.

**Synthetic empty-tab window injection (F#4).** The orchestrator emits
synthetic `model::Window { kitty_id: 0, ksession_id: <fresh>, program: BareShell, … }`
entries for tabs that exist but contain no real kitty windows (empty-tab
edge case). Kitty's `save_as_session` skeleton does NOT contain a `launch`
line for these synthetic windows — they don't exist in the live kitty
state. The patcher MUST detect synthetic windows and inject a corresponding
`launch /bin/bash -l` line into the appropriate tab (matches Bash
`ksession.sh:722–725`, which spawns a login shell). Detection rule and
injection rule are pinned in §C.1 below.

### 5.7 `session/` — save/restore orchestration

#### Public surface

```rust
pub struct SaveOpts {
    pub name: String,
    pub window_id: Option<u32>,
    pub all_windows: bool,
    pub from_ls: Option<PathBuf>,
}

pub async fn save(opts: SaveOpts) -> Result<SessionFile, KError>;
```

`KITTY_WINDOW_ID` resolution lives in `cli/` (Step 9). By the time `session::save`
is called, `SaveOpts.window_id` is already fully resolved — `session::save` never
reads env vars.

**Save-name validation.** `SaveOpts.name` is validated by `cli/save` (Step 9)
against the regex `^[A-Za-z0-9._-]+$` (Bash `ksession.sh:38–40`).
`session::save` may also re-validate defensively and return
`Err(KError::InvalidName(name))` if a caller bypasses `cli/`. The library entry
point treats name validation as a hard precondition.

#### Restore

```rust
pub async fn restore(name: &str, sessions_dir: &Path) -> Result<(), KError>;
```

`restore` is a thin wrapper:
1. Validate `name` via the same regex as `save` (§Save-name validation above);
   return `KError::InvalidName` on miss.
2. Resolve `<sessions_dir>/<name>.conf`; if absent return `KError::NotFound(name)`.
3. Sweep orphaned gen-stamped state dirs (same routine as save's pre-Phase 0
   sweep — see §B.4 "Orphan sweep"). This is the only opportunity to
   garbage-collect orphans when the user only ever restores.
4. `exec`/spawn `kitty --detach --class "kitty-project-<name>" --session <conf_path>`
   and return. The `--class` flag matches Bash `ksession.sh` restore and lets
   window managers pin per-project workspaces.

No phase model, no state-dir creation, no UUID dance — restore is read-only
from the perspective of `<sessions_dir>`.

#### Canonical 8-phase pipeline

Phases: 0, 0.5, 0.75, 1, 2, 3, 4, 5. Half-integer labels preserve historical
numbering when new phases were inserted (Phase 0.75 was the most recent
addition — F#22). §10's step-8 named-phase list is kept in sync with the
runtime order below (probe → filter → UUID-tag → capture → …).

- **Phase 0 — Probe.**

  **Sessions dir bootstrap.** Before any RC traffic, ensure `sessions_dir`
  exists with `std::fs::create_dir_all(sessions_dir)`. Errors propagate as
  `KError::Io`. This matches Bash `ksession.sh:28`'s `mkdir -p` at script
  load. The Rust port does it lazily (per-save) rather than at process
  start so library consumers don't pay the cost when only running
  `list`/`show`.

  Issue `@ ls --all-env-vars` and `@ ls --output-format=session`
  (the skeleton) in parallel via the §B.3.1 pipelined RC channel. If
  `SaveOpts.from_ls` is set (or `KSESSION_FROM_LS` was honored by `cli/`), read
  both from the pre-recorded fixture path via `kitty::ls_from_file` and
  `kitty::skeleton_from_file` respectively (§5.1).

  **OS-window resolution (F#24).** With `ls_json` in hand, resolve which
  OS-windows are save targets:
  - If `SaveOpts.window_id == Some(w)`, locate the OS-window containing window
    id `w` by walking `ls_json` tabs/windows:
    `os_windows.into_iter().find(|osw| osw.tabs.iter().any(|t| t.windows.iter().any(|win| win.id == w)))`.
    That single OS-window is the save target.
  - Else if `SaveOpts.all_windows == false`, fall back to the focused
    OS-window: `os_windows.into_iter().find(|osw| osw.is_focused)`.
  - Else (`all_windows == true`), all OS-windows are targets.

  Bash analog: `ksession.sh:640–652`. The lookup runs here, before fan-out,
  so downstream phases iterate only over the resolved target set.

  **Tab-position side table.** A stack-local map carries each surviving
  kitty window id back to its tab/OS-window position so Phase 2 can fold the
  flat `(kitty_id, Program)` futures back into the tab-structured
  `SessionFile`:
  ```rust
  // stack-local in save():
  // Maps each surviving (post-Phase-0.75) kitty window id to its position
  // (os_window_idx, tab_idx, window_idx_in_filtered_tab) so Phase 2 can
  // fold the flat (kitty_id, Program) futures back into the tab-structured
  // SessionFile. Populated during Phase 0.75 filtering — the same pass that
  // drops is_self/overlay_parent windows records each survivor's position.
  let positions: HashMap<u64, (usize, usize, usize)>;
  ```
  Populated in Phase 0.75 (filter); consumed in Phase 2 (collect).

  **Skeleton fanout (multi-OS-window).** `kitty @ ls --output-format=session`
  only emits one OS-window per invocation. After OS-window resolution above
  produces the list of target OS-window ids, Phase 0 issues one
  `save_as_session --match id:<os_window_id>` call per resolved OS-window via
  the pipelined RC channel (§B.3.1), then concatenates the resulting skeletons
  with a literal `new_os_window` line between consecutive blocks. The
  `@ ls --all-env-vars` call still fires once. See §C.1:3064–3077 for the
  patcher's expectation of pre-concatenated input.

  **Skeleton-fetch error path.** If `save_as_session` returns a non-`ok`
  envelope or the body fails to parse for ANY target OS-window,
  `session::save` returns
  `Err(KError::KittyRemote { stage: "save_as_session", os_window: Some(<id>), source })`
  (see §5.8). The save aborts before Phase 0.75 — no sidecars are written,
  and the gen-stamped state-dir mkdir (described below) is deferred until
  after the skeleton fanout completes successfully, so no orphan dir is left
  on disk. There is no from-scratch fallback renderer; the conf-patch
  pipeline is the only render path.

  **Generation stamp + state-dir mkdir.** After skeleton fanout (above) completes
  successfully, compute `gen_us: u64 = SystemTime::now().duration_since(UNIX_EPOCH)?.as_micros() as u64`
  and mkdir `<sessions>/<name>.gen-<gen_us>.state/` at its FINAL name (not a
  `.tmp` name) via `std::fs::create_dir` (which surfaces `EEXIST` as
  `ErrorKind::AlreadyExists`). On `AlreadyExists`, retry with the path
  `<name>.gen-<gen_us>_<pid>.state/`; on a second `AlreadyExists` (same µs AND
  same pid — only reachable from intra-process reentrant `session::save`),
  increment `gen_us` by 1 and retry up to 8 total attempts before returning
  `KError::GenCollision`. The state dir, wrapped in a `StateTmpdir` newtype
  (see Phase 5), is threaded into Phase 4 (so the conf body embeds absolute
  paths into the gen-stamped dir) and into the StateTmpdir handed to
  `commit_session` in Phase 5. Sidecars written in Phase 1 land directly in
  the final-named dir. The sweep step (§B.4) recognises both
  `gen-<digits>.state` and `gen-<digits>_<digits>.state` patterns when
  extracting gen suffixes.

- **Phase 0.75 — Filter (F#22).** (Despite the half-integer label ordering
  (0.5 < 0.75), Phase 0.75 runs BEFORE Phase 0.5 at runtime. The labels
  preserve historical numbering — Phase 0.75 was the most recent insertion,
  F#22; the prose order in this section reflects execution order. Filtering
  before tagging avoids minting and dispatching UUIDs for windows that are
  about to be filtered.) Drop windows where `is_self == true` OR
  `overlay_parent.is_some()`. Applied per-tab BEFORE Phase 1 fan-out. The
  filtered window list is the canonical input for:
  (a) Phase 1 capture iteration,
  (b) `active_idx` computation per tab (§5.6 / §C.1),
  (c) the split-position heuristic (Bash 558–562).
  The same pass populates the `positions: HashMap<u64, (usize, usize, usize)>`
  side table declared in Phase 0 — each survivor's
  `(os_window_idx, tab_idx, window_idx_in_filtered_tab)` is recorded as the
  filter walks. Phase 2 reads this map to fold flat `(kitty_id, Program)`
  futures back into the tab-structured `SessionFile`.
  Bash analog: `ksession.sh:683–686`.

- **Phase 0.5 — UUID tag (F#2).** Generate one fresh `Uuid` per SURVIVING
  target window (post-Phase 0.75 filter), CLIENT-SIDE. Store the mapping in
  a stack-local `HashMap<u64, Uuid>` keyed by `kitty_id`. Issue a single
  batched `kitten @ set-user-vars` call applying every tag in one round-trip.
  **`no_response: true` is FORBIDDEN here** — use a response-acknowledged
  call so we know which windows actually received their tag. Windows that
  fail to tag (died between probe and tag) are dropped from the in-memory
  target window list before Phase 1 — they cannot participate because the
  patcher has no way to correlate them. The `HashMap<u64, Uuid>` is the
  canonical `ksession_id` store for the remainder of the save; the value is
  paired into `model::Window.ksession_id` at SessionFile-assembly time using
  this table — it is NOT stored on the in-memory `kitty::Window`. Concretely the tag burst
  is N pipelined `set_user_vars` calls over the §B.3.1 socket — one per
  surviving window. Kitty's `set_user_vars` RC verb takes a single
  `window_match` per invocation and has no batch envelope; 'batched' here
  means pipelined over one socket, not a single multi-window RPC.

- **Phase 1 — Capture.** Spawn per-window `capture_window` futures and drive
  concurrently via `buffer_unordered(12)` (see §B.2). Each future returns
  `(kitty_id, Program)`; the orchestrator pairs that with the `ksession_id`
  from the Phase 0.5 `HashMap<u64, Uuid>` when assembling each `model::Window`
  for the `SessionFile`.

  **Per-window timeout (F#16).** Each `capture_window` future is wrapped by
  the orchestrator in
  `tokio::time::timeout(PER_WINDOW_BUDGET, capture_window(...))` where
  `PER_WINDOW_BUDGET = Duration::from_secs(15)`. On elapse, the window
  degrades to `Program::BareShell` and the orchestrator pushes
  `AdapterError::Timeout { kitty_id, elapsed }` into `ctx.errors`.
  Justification: a hung nvim socket (TCP-via-SSH, stuck `mksession`) must
  not block the entire save indefinitely. The inner `nvim_rpc` 5s timeout
  (§5.3) covers individual RPC calls; the orchestration-layer 15s budget
  covers the whole adapter dispatch for one window.

- **Phase 2 — Collect.** Fold futures into `SessionFile`. The orchestrator
  consumes the `positions: HashMap<u64, (usize, usize, usize)>` side table
  populated in Phase 0.75 to place each flat `(kitty_id, Program)` future
  into its correct `OsWindow → Tab → Window` slot.

  **`active_window_idx` computation.** When folding the flat
  `(kitty_id, Program)` futures back into `model::Tab`, the orchestrator
  computes `active_window_idx` per tab by walking the post-Phase-0.75-filter
  window list and recording the position of the entry whose original kitty
  `@ ls` JSON had `is_active == true`. If no surviving window was marked
  active (the previously-active window was filtered or torn down between
  probe and capture), `active_window_idx = 0` (default to the first
  surviving window).

  **Empty-tab fallback:**
  if a tab ends with zero windows after Phase 0.75 filtering, emit a
  synthetic
  `Window { kitty_id: 0, ksession_id: Uuid::new_v4().to_string(), program: Program::BareShell, cwd: tab_cwd_fallback, scrollback: None }`
  so the tab survives restore (Bash `ksession.sh:722–725` parity). A fresh
  `ksession_id` is minted per synthetic window — no kitty window holds it;
  the §C.1 patcher injects matching `launch` lines tagged with this value.
  The synthetic window's `ksession_id` is ALSO inserted into the Phase 0.5
  `HashMap<u64, Uuid>` (keyed by `kitty_id = 0` per synthetic-window slot —
  or, if multiple synthetic windows can coexist in one save, keyed by a
  reserved synthetic-id range; see §C.1) so the patcher's lookup table
  covers synthetic windows uniformly.
- **Phase 3 — Sanitize.** `blank_polluted_titles(&mut SessionFile)` mutates tab
  titles in place per the regex below, plus blanks tabs in which ANY window —
  not just the active or foreground one — resolved to `TargetHint::Tmux`
  during Phase 1 (the descendant-was-tmux trigger from Bash
  `ksession.sh:691–712`, which iterates every filtered pid in the tab).
- **Phase 4 — Render.** `let conf = conf::render(skeleton, &session_file, gen_us);`
  — per the canonical signature in §5.6:1378
  `render(skeleton: &str, session: &SessionFile, gen_us: u64) -> String`,
  `gen_us` (the timestamp computed in Phase 0) is passed through so the
  patcher can embed absolute paths into the gen-stamped state dir. The
  §C.1 patcher rewrites each tagged `launch` line from the skeleton using
  the UUID→Program correlation. Untagged windows are emitted from the
  skeleton verbatim. The rendered conf body's absolute paths target the
  generation-stamped state dir chosen for this save (see Phase 5).
- **Phase 5 — Commit (F#1).** Generation-stamped commit. The state dir was
  already created at its final gen-stamped name in Phase 0 and populated
  in Phase 1; Phase 5 only fsyncs and renames the conf:
  ```rust
  fsx::commit_session(
      state_tmpdir,         // StateTmpdir wrapping <sessions>/<name>.gen-<gen_us>.state/
      &conf_body,           // &str — the .conf bytes from Phase 4
      sessions_dir,
      &session_file.name,
  )?;
  ```
  `commit_session` (signature in §B.4) does NOT rename the state dir — it
  was final-named from mkdir. The function fsyncs the state dir, writes
  `<name>.conf.tmp.<pid>` + fsync, renames `conf.tmp -> conf` (the SOLE
  commit point), and fsyncs the parent. The Phase 4 conf body embeds
  absolute paths into the gen-stamped dir — every
  `launch nvim -S /…/sessions/<name>.gen-<gen_us>.state/nvim/win-N.vim`
  and every `tmux/<sess>/restore.sh` path is built against `gen_us` from
  Phase 0.

  **Conf-rename is the SOLE commit point.** State and conf are decoupled
  because each conf references its own gen-stamped state dir — there is
  no cross-conf shared state. Re-save semantics: every save writes a
  fresh state-dir AND a fresh conf; the old gen pair
  (`<name>.gen-<prev_us>.state/` plus the now-overwritten `<name>.conf`)
  remains readable on disk until the sweep step collects it.

  **Sweep deferred.** Old gen state-dirs (those referenced by prior
  `<name>.conf` versions overwritten by this save) are NOT deleted
  inline. They are collected by the sweep step at the START of the next
  save (see §B.4). Inline deletion would race with concurrent restores
  reading the previous generation.

  **StateTmpdir Drop guard (F#17).** The state tempdir is wrapped in a
  `StateTmpdir` newtype whose `Drop` impl `rm -rf`s the directory if the
  save future is dropped before `commit_session` succeeds.
  **Cancellation safety:** `commit_session` consumes the `StateTmpdir` by
  value. The internal `std::mem::forget` anchor fires immediately AFTER
  the `conf.tmp → conf` rename succeeds (step 4 of §B.4's outline) — that
  rename is the sole commit point. If the subsequent parent-fsync (step
  6) fails, the save is already committed: `commit_session` returns
  `Err(KError::Io)` but the gen-stamped state dir is NOT deleted, because
  the live `<name>.conf` already references it. Errors BEFORE the conf
  rename (state-dir fsync, conf.tmp write, conf.tmp fsync) propagate as
  Err and the Drop runs, cleaning up the orphaned gen-stamped state dir.
  The Drop impl uses `std::fs::remove_dir_all`; this is safe under the
  `current_thread` runtime flavor (§3) where no blocking-pool deadlock is
  possible. Do not change the runtime flavor without revisiting this
  Drop.

#### Save-local state (ownership map)

Stack-locals owned by `session::save` for the duration of one save invocation:

- `gen_us: u64` — computed in Phase 0, embedded into conf paths by Phase 4,
  never mutated after Phase 0.
- `state_tmpdir: StateTmpdir` — owned across Phases 1–4; consumed by value by
  `commit_session` in Phase 5. Its Drop guard fires on any early return.
- `ksession_id_map: HashMap<u64, Uuid>` — populated in Phase 0.5, consumed
  in Phase 1 (paired with `(kitty_id, Program)` results) and Phase 2
  (synthetic-window `ksession_id` minting also pushes here).
- `positions: HashMap<u64, (usize, usize, usize)>` — populated in Phase 0.75
  (filter), consumed in Phase 2 (collect/reassemble).

These are deliberately NOT in `SharedCtx` because they are per-save state
with no concurrent-task readers — adapter futures only see what's threaded
through `WindowCtx`.

#### Per-window orchestration

`capture_window` is the per-window unit driven by `buffer_unordered(12)`.
Its signature (F#9):

```rust
async fn capture_window(
    window: &kitty::Window,
    tab_layout: &str,              // "splits" | "stack" | ... — split-position heuristic, Bash 558–562
    state_dir: &Path,              // <sessions_dir>/<name>.gen-<gen_us>.state/ — created at final name in Phase 0, never renamed
    shared: &SharedCtx,
) -> (u64, Program)                // (kitty_id, Program); ksession_id paired in by caller (Phase 1)
```

Body of `capture_window`:

a. **Resolve target program.** Call
   `resolve_target_program(window, &shared.proc)` to obtain
   `(fg_pid: u32, fg_exe: Option<String>, hint: Option<TargetHint>)`. Note
   the signature is `(fg_pid, fg_exe, hint)` — `fg_exe` is the third tuple
   element, an `Option<String>` carrying the basename of
   `/proc/<fg_pid>/exe` (or `None` if unreadable), and is ALWAYS read from
   `/proc/<fg_pid>/exe` regardless of how `fg_pid` was obtained (see
   Target-program resolution below).

b. **Compute window root pid.** `let window_root_pid: u32 = window.pid;`
   This is the kitty-window root pid (the shell launched by kitty), used
   for `WindowCtx.window_root_pid` so adapters can walk descendants from
   the right root rather than from `fg_pid`.

c. **Construct `WindowCtx`.** Pull every adapter-input field from the
   resolved values above plus `shared`:
   ```rust
   let window_ctx = WindowCtx {
       kitty_window: window,
       fg_pid,
       fg_exe,                // Option<String>, owned by this stack frame
       window_root_pid,
       state_dir,
       uid: window.id.to_string(),  // per-window sidecar key (per §5.5:1188) — NOT the libc uid
       proc_root: &shared.proc_root,
       registry: shared.registry,
       tmux_servers: &shared.tmux_servers,
       errors: &shared.errors,
       depth: 0,
       target_program_hint: hint,
       proc: &shared.proc,
       tab_layout,
       scrollback_enabled: shared.scrollback_enabled,
   };
   ```
   Field set tracks §5.5 `WindowCtx` exactly; any new adapter input goes
   through that struct, never as a side-channel.

   `WindowCtx.uid` is the kitty window id stringified (the per-window sidecar
   key per §5.5:1188), distinct from `SharedCtx.uid` (the libc uid). The two
   share a name historically; the libc-uid value is not consumed here.
   `SharedCtx.uid` is reserved for tmux-socket fallback discovery (§5.4 step 2
   `/tmp/tmux-<uid>/default`, used only when `$TMUX` is absent) and should be
   removed in a follow-up unless that fallback path is added — `capture_window`
   itself does not read it.

d. **Dispatch via registry, in parallel with kitty-window scrollback.**
   ```rust
   let program_fut    = shared.registry.capture(&window_ctx);
   let scrollback_fut = capture_kitty_window_scrollback(window, state_dir, shared);
   let (program, _sb) = tokio::join!(program_fut, scrollback_fut);
   ```

Per-window legs run concurrently via `tokio::join!`: the registry-dispatch
leg (which may itself spawn nvim mksession or tmux capture under the §5.5
adapter trait) overlaps with the kitty-window scrollback leg (which uses
the kitty RC socket per §B.3.1). The kitty RC socket leg serialises across
all 12 windows on a shared `Mutex<UnixStream>` (§B.3.1 Serialization note),
but inside a single window the two legs do not serialise against each
other. `_sb` is discarded because `capture_kitty_window_scrollback` already
pushes any `AdapterError::KittyWindowGetText` into `*shared.errors`.

Return `(window.id, program)`, where `program` is the result of the
registry dispatch captured by the `join!` destructuring above. The caller
(Phase 1) looks the `ksession_id` up from the `HashMap<u64, Uuid>` produced
in Phase 0.5 and constructs the final `model::Window` from the triple
`(kitty_id, ksession_id, program)`.

```rust
pub struct SharedCtx {
    /// Adapter registry. `&'static` lifetime is intentional —
    /// registry composition is global, backed by
    /// `once_cell::sync::Lazy<Registry>` declared in `default_registry()`
    /// (see Registry construction below). F#7.
    pub registry: &'static Registry,

    /// Memoized /proc reads (§B.4). `ProcCache` owns its internal
    /// `std::sync::RwLock<HashMap<u32, …>>` per field — synchronization
    /// is hidden inside the cache type rather than wrapping the cache
    /// in an outer lock. Read-heavy under `buffer_unordered(12)` fan-out;
    /// writes are first-touch only, so `RwLock` allows concurrent readers
    /// to amortize contention to near-zero. F#15. (Full detail in §B.4 —
    /// this comment is the §5.7 summary.)
    pub proc: ProcCache,

    /// /proc filesystem root (overridable for tests).
    pub proc_root: PathBuf,

    /// Cached libc UID of the current process, populated once at SharedCtx
    /// construction time via `unsafe { libc::getuid() } as u32`. RESERVED for
    /// tmux-socket fallback discovery (§5.4 step 2: `/tmp/tmux-<uid>/default`,
    /// used only when `$TMUX` is absent). NOT currently consumed by
    /// `capture_window` — distinct from `WindowCtx.uid`, which is the
    /// per-window sidecar key (kitty window id stringified, §5.5:1188).
    /// Remove in a follow-up if the tmux-socket fallback path is never wired
    /// in. F#9.
    pub uid: u32,

    /// Per-server tmux control sockets, keyed by (socket_path, server_pid).
    /// `Arc<TmuxControl>` so multiple `capture_window` futures can hold
    /// the control handle concurrently without cloning the underlying
    /// socket. `tokio::sync::Mutex` because the lock is held across a
    /// socket-spawn `.await` when a new server entry is being constructed.
    /// F#6, F#8.
    /// Lock contention is bounded: the mutex is acquired only when
    /// CONSTRUCTING a new `(socket_path, server_pid)` entry; once
    /// `Arc<TmuxControl>` is in the map, subsequent dispatches clone the
    /// Arc and run queries against the per-server pipe without re-locking.
    /// See §B.3.2 lines 2650–2659 — query atomicity (FIFO correlation
    /// between writes and `%begin`/`%end` echoes) is held inside
    /// `TmuxControl` itself via its own internal mutex on `ChildStdin`.
    pub tmux_servers: tokio::sync::Mutex<HashMap<(PathBuf, u32), Arc<TmuxControl>>>,

    /// Accumulates per-window adapter degradations. `std::sync::Mutex`
    /// (sync flavor) — the lock is NEVER held across an `.await`; pushes
    /// are short critical sections (`errors.lock().unwrap().push(e)`).
    /// Borrowed as `&'a std::sync::Mutex<Vec<AdapterError>>` into each
    /// `WindowCtx` (§5.5). F#8.
    pub errors: std::sync::Mutex<Vec<AdapterError>>,

    /// Gated by `KSESSION_SCROLLBACK` (resolved by `cli/save`, §1.5).
    pub scrollback_enabled: bool,
}
```

#### Registry construction

`default_registry()` order: `[adapter::Nvim, adapter::Tmux, adapter::Less, adapter::Shell, adapter::Raw]`
(Raw last). `Registry::capture(ctx) -> Program` keeps degrading on
`AdapterError` internally and pushes each error into `ctx.errors`.

Signature (F#11):

```rust
pub fn default_registry() -> &'static Registry {
    static REGISTRY: once_cell::sync::Lazy<Registry> = once_cell::sync::Lazy::new(|| {
        Registry::new([Adapter::Nvim, Adapter::Tmux, Adapter::Less, Adapter::Shell, Adapter::Raw])
    });
    &REGISTRY
}
```

The `&'static` return is the same lifetime stored in `SharedCtx.registry`
(F#7) — composition is global, so the lifetime is honest rather than a
workaround.

#### Target-program resolution

```rust
fn resolve_target_program(
    window: &kitty::Window,
    proc: &ProcCache,
) -> (u32 /* fg_pid */, Option<String> /* fg_exe basename or None */, Option<TargetHint>)
```

Returns the triple `(fg_pid, fg_exe, hint)` (F#9, F#27):

- `fg_pid` is taken from `window.foreground_processes.last().map(|p| p.pid)`
  — the LAST entry of `foreground_processes`, matching Bash 523's
  `foreground_processes[-1]`; falls back to the window's root pid when
  `foreground_processes` is empty (Bash 527–529).
- `fg_exe` is an `Option<String>` carrying the basename of
  `/proc/<fg_pid>/exe` (or `None` if `/proc/<fg_pid>/exe` is unreadable —
  e.g. the process exited between Phase 0 ls and Phase 1 capture, or
  permissions deny readlink). Read via `proc.exe(fg_pid)` and **always**
  sourced from `/proc/<fg_pid>/exe` regardless of how `fg_pid` was
  obtained. **Bash parity:** `ksession.sh:530–533` always reads
  `proc_exe_base $fg_pid` even when `fg_pid` came from kitty's reported
  `foreground_processes` — kitty's reported `cmdline[0]` can disagree
  with `/proc/<fg_pid>/exe` under wrapper exec (e.g., `python` symlinked
  to `python3.12`, or a shell `exec`-ing its real implementation).
  Reading `/proc/<pid>/exe` unconditionally avoids that class of
  mismatch. The basename string (not a `PathBuf`) is what adapters
  pattern-match against.
- `hint` is determined by walking descendants of `fg_pid` and matching
  basename in `{tmux, nvim, less, man, more, most, pg}`; `more|most|pg`
  map to `TargetHint::Less` (share the less adapter). Returns a
  `TargetHint` only — never a `Program`. `TargetHint` is defined in §5.5;
  `MAX_ADAPTER_DEPTH = 2` is declared in §5.5.

  **Descendant-walk gating (Bash 537–538).** The descendant walk runs ONLY
  when `fg_exe`'s basename is in `{bash, zsh, fish, dash, sh, ash}` — i.e.,
  the foreground process is a shell that may have spawned a long-running
  child. If `fg_exe` is itself a known program (e.g., `nvim`, `tmux`,
  `less`, `man`, `more`, `most`, `pg`), no descendant walk runs — the hint
  is determined directly from `fg_exe`. If `fg_exe` is `None` (unreadable
  `/proc/<fg_pid>/exe`) or some other non-shell program (e.g., `python`),
  no walk and `hint = None`.

#### Polluted-title sanitization

Rust regex matching Bash 707–712 semantics:
`^(tmux|exec|nvim|less|man|vim|sudo|ssh|cd|ls) `.
The trailing literal space is load-bearing: Bash 708 uses `tmux\ *` (command
followed by a space then any args), so a bare-word title like `"ls"` —
with no trailing space — must NOT be blanked. The Rust port preserves this
exactly: only stale command-WITH-arguments titles are blanked. Note:
`more|most|pg` are **not** in the regex — they are descendant-walk only.

Tabs in which ANY window — not just the active/foreground one — resolved to
`TargetHint::Tmux` are blanked, independent of the regex. This is the
descendant-was-tmux trigger; the Rust port preserves Bash `ksession.sh:691–712`'s
iteration over every filtered pid in the tab. A tab with two non-active tmux
windows and one active non-tmux window IS blanked.

Both triggers run at the orchestration layer — not inside any adapter — so
adapters stay simple and the cross-cutting heuristics are auditable in one place.
See §11 risk rows on "Polluted tab-title sanitization location" for the rationale.

#### Kitty-window scrollback

`capture_window` owns kitty-window scrollback. After adapter dispatch, if
`ctx.scrollback_enabled` is true, write `<state>/scrollback/win-<kitty_id>.ansi`
from `kitten @ get-text` (or the recorded equivalent in `KSESSION_FROM_LS` mode).
The gate matches `KSESSION_SCROLLBACK` (§1.5).

Signature:

```rust
async fn capture_kitty_window_scrollback(
    window: &kitty::Window,
    state_dir: &Path,
    shared: &SharedCtx,
) -> ();   // errors pushed directly into shared.errors; no return value
```

#### Error observability

`Registry::capture` swallows `AdapterError` and pushes each occurrence into
`ctx.errors`. Step 8 surfaces these to the CLI for `tracing::warn!` output so
degraded adapters are visible without aborting the save.

**Partial-capture threshold (F#31).** After `Registry::capture` completes
for every window, the orchestrator inspects `ctx.errors.lock().unwrap()`
and computes a degraded count. If degraded count **exceeds** the
threshold `max(1, total / 4)` — i.e., any nvim/tmux adapter failure, OR
≥25% of windows degraded — `session::save` returns
`Err(KError::PartialCapture { degraded, total })`. Below threshold, the
orchestrator returns `Ok(SessionFile)` and lets `cli/save` emit
individual `tracing::warn!` lines for each accumulated `AdapterError`.
The threshold is intentionally low: a small session (4 windows) with one
broken nvim is still salvageable as a warning; a large session with 25%
mass adapter failure indicates a systemic problem (e.g., nvim crash,
tmux server gone) where silently returning `Ok` would mask data loss.

**State-dir cleanup on PartialCapture.** When the threshold is exceeded,
`session::save` returns `Err(KError::PartialCapture { degraded, total })`
BEFORE Phase 5 runs. `commit_session` is never called, so the
`StateTmpdir`'s Drop guard fires on the way out and `rm -rf`s the
populated gen-stamped state dir. No orphan is left on disk. Below-threshold
degradations proceed through Phase 5 normally; per-window warnings are
emitted by `cli/save` from the drained `ctx.errors` Vec.

**Timeouts count toward the threshold.** `AdapterError::Timeout` entries
pushed by the per-window 15s budget (Phase 1) are NOT filtered when
computing `degraded`. This is intentional: a session where 25%+ of
windows hang to timeout indicates a systemic problem (stuck SSH-tunneled
nvim sockets, deadlocked tmux server, /proc denial) where silently
saving a hollow `SessionFile` would mask the underlying issue.
Below-threshold timeouts degrade individually (each affected window
becomes `Program::BareShell` with a `tracing::warn!` line);
above-threshold the save aborts cleanly via `KError::PartialCapture`
and the state dir is rm-rf'd. Users hitting this should diagnose the
hang root cause rather than retry — `cli/save` exits non-zero with a
stderr summary listing the timing-out windows.

### 5.8 Errors

```rust
// error.rs (lib only — bin uses anyhow for context at the boundary)
#[derive(thiserror::Error, Debug)]
pub enum KError {
    /// `kitty @` RC channel failed at a named stage: Phase 0 `ls`,
    /// Phase 0 `save_as_session` (per OS-window — `os_window` carries the
    /// id of the offending OS-window), or Phase 0.5 `set-user-vars` for
    /// the whole batch. Per-window kitty RC failures during Phase 1 (e.g.,
    /// transient `get-text` on a dying window) do NOT use this variant —
    /// they push `AdapterError::KittyWindowGetText` and degrade the
    /// window. F#32.
    #[error("kitty RC failed at stage {stage}{} : {source}", os_window.map(|w| format!(" (os_window={w})")).unwrap_or_default())]
    KittyRemote { stage: &'static str, os_window: Option<u32>, #[source] source: KittyRpcError },
    #[error("invalid session name '{0}'")]      InvalidName(String),
    #[error("session '{0}' not found")]         NotFound(String),
    #[error("no OS windows matched")]           NoTargets,
    /// Sidecar manifest's `schema: u32` field does not match the running
    /// binary's expected schema. Returned by `restore`, `list`, and `show`
    /// when reading a `<name>.state/manifest.json` whose schema field does
    /// not match `model::SessionFile::CURRENT_SCHEMA`. The user re-runs
    /// `save` to overwrite. No silent upgrade — schema bumps are explicit
    /// breaking changes.
    #[error("session '{name}' was saved with schema {found}, expected {expected} — re-run `ksession save {name}` to upgrade")]
    SchemaMismatch { name: String, found: u32, expected: u32 },
    /// Returned by `session::save` when the count of accumulated
    /// `AdapterError`s exceeds `max(1, total / 4)` after Phase 1 capture.
    /// `cli/save` exits non-zero with a stderr summary. F#31.
    #[error("partial capture: {degraded}/{total} windows degraded — re-run save or check logs")]
    PartialCapture { degraded: usize, total: usize },
    /// `commit_session` attempted to rename `<name>.conf.tmp.<pid>` to
    /// `<name>.conf` (or the state dir) across a filesystem boundary;
    /// `renameat2` (or `rename(2)`) returned `EXDEV`. Recovery is
    /// caller-driven (move `<sessions>` onto the same filesystem as the
    /// state-dir target).
    #[error("cross-filesystem rename: cannot rename {src:?} to {dst:?}")]
    CrossFilesystem { src: PathBuf, dst: PathBuf },
    /// Phase 0 could not allocate a fresh gen-stamped state directory
    /// after the §5.7 retry loop exhausted its attempts (same µs +
    /// same pid + several `gen_us + N` retries all collided — only
    /// reachable from pathological intra-process reentrant save bursts).
    #[error("could not allocate a fresh gen-stamped state directory after {attempts} attempts")]
    GenCollision { attempts: u32 },
    #[error(transparent)] Io(#[from] std::io::Error),
    #[error(transparent)] Json(#[from] serde_json::Error),
}

#[derive(thiserror::Error, Debug)]
pub enum AdapterError {
    #[error("nvim socket unreachable: {0}")]       NvimSocket(String),
    #[error("nvim mksession produced no output")]  NvimMksessionDidNothing,
    #[error("nvim RPC error: {0}")]                NvimRpc(String),
    #[error("tmux not on PATH")]                   TmuxMissing,
    #[error("tmux session not attached")]          TmuxNoClient,
    /// Transient per-window `kitten @ get-text` failure during Phase 1.
    /// Degrades the window's scrollback to absent (no
    /// `<state>/scrollback/win-N.ansi` file written); does NOT abort the
    /// save. Distinct from `KError::KittyRemote`, which is for whole-RC
    /// channel failures during probe/tag phases. F#32.
    #[error("kitty get_text failed for window {kitty_id}: {source}")]
    KittyWindowGetText { kitty_id: u64, source: String },
    /// Per-window capture exceeded `PER_WINDOW_BUDGET` (15s, §5.7 F#16).
    /// Pushed by the orchestrator (NOT by an adapter); window degrades
    /// to `Program::BareShell`.
    #[error("window {kitty_id} capture timed out after {elapsed:?}")]
    Timeout { kitty_id: u64, elapsed: std::time::Duration },
    #[error(transparent)] Io(#[from] std::io::Error),
}
```

**Fatal vs degraded:**

- Fatal: `KError::*` — abort the save. `KError::PartialCapture` is a
  fatal outcome aggregated from many non-fatal degradations: when too
  many adapters degrade, the orchestrator escalates rather than silently
  returning a hollow `SessionFile`.
- Degraded: any `AdapterError` — log at WARN, fall through to
  `Program::BareShell` (or, for `KittyWindowGetText`, just skip the
  scrollback file).

This is the same contract as the Bash version's `|| true` patterns, just explicit.

---

## 6. On-disk compatibility — preserve every existing path

The Bash version writes:

```
~/.config/kitty/sessions/<name>.conf
~/.config/kitty/sessions/<name>.state/
    nvim/win-<id>.vim
    nvim/win-<id>.dumps/buf-<n>.txt
    scrollback/win-<id>.ansi
    tmux/<sess>/restore.sh
    tmux/<sess>/win-<X>/pane-<Y>/scrollback.ansi
    tmux/<sess>/win-<X>/pane-<Y>/nvim/win-<uid>.vim            # if pane runs nvim
    tmux/<sess>/win-<X>/pane-<Y>/nvim/win-<uid>.dumps/         # if pane runs nvim
```

For nvim under a tmux pane, `<uid>` is the pane-id digits (same value as `<Y>`),
not the pane pid — so the path is e.g. `tmux/main/win-1/pane-37/nvim/win-37.vim`.
See §5.4 "nvim panes" for the contract.

**Path divergence under §B.4 atomic publish.** The state dir is renamed
`<name>.gen-<gen_us>.state/` (gen-stamped, see §B.4). The conf body uses
absolute paths into the gen-stamped dir, so the on-disk shape of the directory
tree is identical to the Bash layout — only the top-level directory's basename
changes (`<name>.state` → `<name>.gen-<gen_us>.state`). External tools that
hard-coded the Bash `<name>.state/` literal path will need to glob
`<name>.gen-*.state/` instead. Bash-era saves remain readable at their original
paths; the next Rust-era save writes a fresh gen-stamped dir without touching
the Bash one (sweep collects orphans — see §B.4 "Orphan sweep").

Per-pane program sidecars (nvim, etc.) are nested under the pane dir — the tmux
adapter recurses into the same per-program adapters and scopes their state-dir
root to the pane. §5.4 covers the recursion.

`pane-<Y>` uses digits only: tmux emits pane ids as `%NN`, and the directory key
strips the leading `%` (Bash `uid=${pane_id#%}` at `ksession.sh:384`). Rust port
matches via `pane_id.trim_start_matches('%')`.

Every one of these paths is referenced by **absolute** path from the generated
`.conf` (e.g. `launch nvim -S /home/andrew/.config/kitty/sessions/foo.state/nvim/win-12.vim`)
or shelled into directly (`restore.sh`). The user has working sessions today; we
preserve every path under the state dir bit-for-bit; the state dir's TOP-LEVEL
basename changes to `<name>.gen-<gen_us>.state/` per §B.4.

**Additive only:**

```
~/.config/kitty/sessions/<name>.state/manifest.json     # NEW
~/.local/share/nvim/site/lua/ksession_restore.lua       # NEW (installed by `make install`)
```

The new `manifest.json` is what `ksession-rs show` and the round-trip tests consume.
The legacy `ksession.sh show` already does `find … -type f` to list sidecars, so it
keeps working — it'll just list `manifest.json` too.

**Format changes:**

- The appended `s:KsessionRestoreBuffer` vim function in `nvim/win-N.vim` is replaced
  by one `lua require('ksession_restore').load(...)` line. **Bash-era saved sessions
  must still restore** — they have the old vim function inline, which works fine.
  Rust-era saves use the new lua loader. Both produce equivalent buffer-restore
  behavior at restore time.

---

## 7. Migration plan & rollout

**The Bash version stays installed throughout.** Only the launcher script changes,
and it changes in a way that's instantly revertable via env var.

`KSESSION_IMPL` is a **path to an executable** (see §1.5), not a mode enum. The wrapper
expands it directly into a command position. There is no runtime shadow / `both` mode —
differential testing lives in `tests/diff_runner.rs` (§8) as a fixture-driven test
harness, not a save-time wrapper.

Step 1 — patch `~/.config/kitty/scripts/ksession-save-prompt.sh`:

```bash
KSESSION="${KSESSION_IMPL:-$(dirname "$0")/ksession.sh}"
case "$(basename -- "$KSESSION")" in
  bash|sh|zsh|dash|fish)
    echo "ksession: KSESSION_IMPL=$KSESSION resolves to a shell, refusing" >&2
    exit 1 ;;
esac
[[ -x "$KSESSION" ]] || {
  echo "ksession: $KSESSION is not executable (check KSESSION_IMPL)" >&2
  exit 1
}
# ... later:
if "$KSESSION" save "$name"; then ...
```

The two guards exist because §1.5's older draft documented `KSESSION_IMPL` as an enum
(`bash|rust|both`) — if a user carried that habit forward and ran
`export KSESSION_IMPL=bash`, the wrapper would otherwise silently exec an interactive
shell as `bash save <name>`. Reject bare-shell names explicitly; the executable check
catches typos and stale paths to a not-yet-built binary.

Step 2 — phases:

| Phase | Duration | What's enabled |
|---|---|---|
| 1. Parity | until golden-tests pass | `tests/diff_runner.rs` (§8) runs both impls against captured `kitty @ ls` fixtures with stubbed `/proc`; diffs reviewed offline. No runtime shadow — interactive saves still go through Bash. `KSESSION_IMPL` unset → wrapper default `ksession.sh`. |
| 2. Opt-in | ≥ 4 weeks daily use | `export KSESSION_IMPL=$HOME/.local/bin/ksession-rs` in `~/.config/kitty/kitty.conf` via the `env` directive (see §1.5 — the save prompt is launched as a kitty overlay and does NOT source interactive-shell rc files). Zero rollbacks required to advance. |
| 3. Default | ≥ 1 month | **Second edit to the wrapper:** flip line 1 of Step 1's snippet from `${KSESSION_IMPL:-$(dirname "$0")/ksession.sh}` to `${KSESSION_IMPL:-$HOME/.local/bin/ksession-rs}`. Rename `ksession.sh` → `ksession-legacy.sh`; users wanting to revert set `KSESSION_IMPL=$(dirname …)/ksession-legacy.sh`. |
| 4. Retire | after a clean quarter | Delete `ksession-legacy.sh` (still in git history). |

`session-picker.sh`, `project-loader.sh`, `project-launcher.sh` never need touching —
they read `.conf` files and shell into `kitty --session`. Whoever wrote the `.conf` is
opaque to them.

---

## 8. Testing strategy

### Unit tests (pure, fast, no I/O)

Port each Bash helper to a Rust function and test it in isolation:

- `conf::kq` — equivalence: regex-matching ASCII passes through; bytes outside the
  safe set get single-quoted. Property-test against a curated alphabet.
- `conf::render` — golden files: hand-curated `SessionFile` fixtures → expected
  `.conf` string, checked in under `tests/golden/conf/`.
- `proc::descendants` — fixture `/proc` trees under `tests/fixtures/proc/`.
- `proc::env_var`, `proc::cmdline` — same fixture trees.
- `nvim_rpc::socket_for_pid` — `tempfile::tempdir` as `XDG_RUNTIME_DIR`, drop fake
  socket files, assert all 4 discovery tiers fire correctly.
- `tab_title::should_blank` — table-driven: `("tmux attach -t 0", false) → true`,
  `("my project", false) → false`.
- `kitty::rpc::deserialize` — golden JSON fixtures (single-OS-window, multi-OS-window, missing optional fields, unknown future fields tolerated via `#[serde(default)]`).
- `kitty::rpc::set_user_vars_request` — the on-wire request bytes for a `set-user-vars` call against N windows are well-formed and parse back via the inverse path; verifies §C.3 burst shape.
- `fsx::atomic_rename` — `tempfile::tempdir` as the target dir; assert rename semantics, fsync ordering, and `EXDEV` error surface (without actually crossing filesystems — inject an `io::Error::from_raw_os_error(EXDEV)` via a trait-mockable rename impl).
- `fsx::gen_stamp` — round-trip a `gen_us` value through the `<name>.gen-<digits>_<digits>.state/` formatter and the reverse parser; assert the protected bare-name pattern (`<name>.state/`) is rejected by the parser so Bash-era directories never match the sweep.
- `fsx::sweep_predicate` — pure-function variant of `atomic_publish_sweep_predicates.rs`: given a synthesized list of (path, mtime, conf-references), assert which entries the predicate returns for removal.
- `model::session::schema_compat` — serialize a `SessionFile` with `CURRENT_SCHEMA`, mutate the JSON to set `schema: 0` and `schema: 999`, assert deserialize rejects both with `KError::SchemaMismatch`.
- `model::program::tagged_enum_roundtrip` — every `Program` variant round-trips through `serde_json::to_string` / `from_str` byte-identical; verifies the `#[serde(tag = "kind", rename_all = "snake_case")]` contract underpinning the manifest format.
- `error::exit_code_mapping` — each `KError` variant maps to its documented `cli/save` exit code (e.g., `PartialCapture` → 2, `GenCollision` → 3); table-driven.
- `log::redact` — if any redaction logic exists for paths or env values in log lines, unit-test the redactor against secrets-like inputs; otherwise this bullet is a placeholder pinning that no PII reaches `~/.cache/ksession.log`.
- `cli/parse_help` — golden snapshots of each subcommand's `--help` output (`save`, `restore`, `list`, `show`, `rm`); catches accidental flag/arg renames during refactors.
- `session::save::blank_polluted_titles` — pure-data unit variant of the regression rows: feed a `SessionFile` plus a vector of per-window `TargetHint`s into `blank_polluted_titles` and assert the resulting per-tab `title` field set. Distinct from `tab_title::should_blank` (which only tests the regex) and from the regression rows (which exercise the full save path).

### Integration tests (real external processes, marked `#[tokio::test]`)

- **nvim** — spawn `nvim --headless --listen <tmpsock> --clean -u NORC`, drive via
  `nvim-rs`. Load buffer, modify, dump, assert sidecar contents.
- **tmux** — `tmux -L ksession-test -S <tmpsock>`, build a known structure, generate
  `restore.sh`, then run it against a *second* isolated socket and assert
  `list-windows` / `list-panes` match.
- **kitty** — **skip on CI**: no headless mode that works without a display. Provide
  `tests/manual/kitty_e2e.sh` for local verification, marked `#[ignore]` in the test
  runner so `cargo test -- --ignored` runs it locally.

### Regression suite

Every regression test below corresponds to one of three categories: (1) a real bug observed in the Bash version, (2) a deliberate deviation the Rust port introduces, or (3) a load-bearing invariant whose silent regression would be hard to notice (concurrency topology, protocol parsing, atomic-publish ordering, etc.). Rule: every new user-reported bug must ship a regression test in the same commit as the fix.

One file per shipped Bash bug under `tests/regression/`. Each one names the bug, the
symptom, and the commit that fixed it. Minimum set:

| File | What it asserts |
|---|---|
| `overlay_window_excluded.rs` | Save prompt overlay (`is_self=true`) is filtered before indexing. |
| `nvim_socket_via_descendants.rs` | All 4 discovery tiers cover their assigned cases. |
| `dump_meta_separator.rs` | Unnamed buffers (empty `name`) parse without field shift. |
| `tmux_pane_as_argv.rs` | Generated `restore.sh` uses `new-window <cmd>` not `send-keys`. |
| `tmux_detected_via_descendant_walk.rs` | Bash detection (orchestration `emit_launch_for_window`, ksession.sh lines 537–554, NOT inside the tmux adapter): if fg_exe is a shell, walk `proc_descendants $w_pid` and pick the first descendant whose exe basename is in {tmux, nvim, less, man, more, most, pg}. Empty `foreground_processes` falls back to `w_pid` earlier (lines 527–529). Lives in session/, not adapter/tmux.rs. |
| `polluted_title_blanked.rs` | `"tmux attach -t 0"` blanks; `"my project"` survives. Logic lives in `session::save::blank_polluted_titles` (Bash `ksession.sh:691–712`), not in the tmux adapter. Lives in session/, not adapter/tmux.rs. |
| `unnamed_buffer_round_trip.rs` | Modified `[No Name]` buffer dump → restore preserves content + modified flag. |
| `kitty_ls_failure_msg.rs` | Stub failing kitty; assert error mentions `allow_remote_control`. |
| `tmux_collision_attaches_live.rs` | Default behavior on session-name collision: generated `restore.sh` attaches to the live session and warns; does not rebuild. |
| `tmux_collision_force_rebuilds.rs` | `KSESSION_FORCE=1` in the restore env causes `tmux kill-session -t <sess>` then rebuild. |
| `tmux_quote_roundtrip.rs` | Strings with newlines, single quotes, and `$` in pane cwds / commands survive `shell-escape` → bash eval inside the generated `restore.sh`. |
| `tmux_empty_panes_degrades_to_raw.rs` | When `list-windows` or `list-panes` returns zero rows for a session visible at detection time, the entire OS-window's capture degrades to `Program::Raw { argv: vec!["tmux".into()] }`; no `restore.sh` is emitted. Empty `list-panes` / `list-windows` output does not produce a broken `restore.sh`. |
| `tmux_control_mode_protocol.rs` | Parser fuzz: interleaved `%session-changed` / `%output` / `%layout-change` notifications between command blocks; cmd-num correlation across notifications interleaved between command blocks (responses arrive in command-number order per §B.3.2; the demuxer separates notifications from responses, it does not reorder responses); literal `%end` bytes inside decoded `capture-pane` content. |
| `tmux_capture_pane_octal_decode.rs` | Round-trip bytes 0x00–0xff through `capture-pane -e` in control mode; decoded output equals input. Must explicitly cover the two-char `\\` form for literal backslash (tmux 3.4 emits `\\`, NOT `\134`) in addition to the `\NNN` 3-digit octal form for bytes < 0x20. |
| `tmux_layout_preserved_on_save.rs` | Spawn isolated tmux server with one attached client at 200×60. Run `ksession-rs save`. Assert post-save window dimensions are unchanged — validates `attach-session -r` mitigation on tmux ≥ 3.2 (§B.3.2). |
| `tmux_conf_patch_restore_launch.rs` | Run the §C.1 conf-patch pipeline against an `ls --output-format=session` output containing a tmux-client window. Assert the resulting `.conf` `launch` line contains, in order, **all four** of: `--hold`, `--cwd <window_cwd>` (cwd from the enclosing `SessionFile::Window`), `--var ksession_id=<uuid>` (UUID preserved from the §C.3 set-user-vars tagging round), and `/bin/bash <state_dir>/tmux/<sess>/restore.sh` (NOT bare `bash`, NOT relying on the shebang). Regression covers: patcher dropping the UUID (round-trip identity broken on re-save), patcher dropping `--hold` (§C.4 error surface broken), patcher dropping `--cwd` (window opens in server-cwd which is non-deterministic), or patcher invoking via shebang (breaks on noexec mounts). |
| `tmux_pane_pid_recursion.rs` | tmux pane running nvim → adapter recurses via `pane_pid` → nvim sidecars land under `tmux/<sess>/win-X/pane-Y/nvim/`, not at the kitty-level nvim path. |
| `tmux_nested_tmux_depth_capped.rs` | Nested-tmux child pane is captured as `Program::Raw { argv: ["tmux"] }` (not recursed into) when `WindowCtx.depth >= MAX_ADAPTER_DEPTH`. Prevents infinite recursion on SSH-through-tmux setups. |
| `tmux_pane_shell_context.rs` | VIRTUAL_ENV-only pane (no CONDA_DEFAULT_ENV, no OLDPWD) → emitted argv is `bash -c 'source <venv>/bin/activate; exec bash'`. Confirms the VENV-alone emission shape from ksession.sh:248–267. See `tmux_pane_shell_oldpwd_exported.rs` for the combined VENV+CONDA+OLDPWD case. |
| `tmux_dead_pane_skipped.rs` | `pane_dead=1` panes are filtered before emitting `split-window` / `new-window`; restore does not respawn dead panes as live splits. |
| `tmux_scrollback_empty_deleted.rs` | After `capture-pane` succeeds with zero output, the scrollback sidecar file is deleted (not left as a zero-byte stub). If capture fails (nonzero exit), any partial output is left in place. Mirrors ksession.sh:392–395. |
| `tmux_illegal_session_name_degrades.rs` | Session names containing `:` or `.`, or empty / non-UTF-8 names. `#` is allowed verbatim (verified on tmux 3.4) and must NOT trigger degrade. Degrade the OS-window's capture to `Program::Raw { argv: vec!["tmux".into()] }` (NOT silently rewritten with `_`). Covers `clean_name()` (`tmux.c`) silent-substitution case that would break round-trip identity. |
| `tmux_empty_win_name_omits_dash_n.rs` | When a window's `#{window_name}` is empty, the generated `new-session` / `new-window` line omits the `-n <name>` flag entirely (does not emit `-n ''`). |
| `tmux_empty_pane_cwd_omits_dash_c.rs` | When `pane_current_path` is empty, the generated `new-session` / `new-window` / `split-window` line omits the `-c <cwd>` flag entirely. Tmux 3.4 does not error on `-c ''` but the result is server-cwd which is non-deterministic; omission is preferred. |
| `tmux_restore_sh_perms_and_invocation.rs` | The emitted `restore.sh` has mode 0o755 set, and the kitty `.conf` `launch` line invokes it as `/bin/bash <restore_sh>` (NOT bare `bash`, NOT relying on the shebang). |
| `tmux_restore_sh_strict_mode.rs` | The emitted `restore.sh` begins with `#!/bin/bash\nset -euo pipefail\n` — a failed `new-window` between `new-session` and `attach-session` causes the script to exit nonzero rather than silently attaching to a half-built session. |
| `tmux_collision_exact_match.rs` | The collision-check preamble uses `tmux has-session -t "=$SESS"`, `attach-session -t "=$SESS"`, `kill-session -t "=$SESS"` — the literal `=` forces exact-name match. Regression: `has-session -t prod` against a live session `production` must NOT spuriously detect collision; `kill-session -t prod` under `KSESSION_FORCE=1` must NOT destroy `production`. |
| `tmux_pane_shell_oldpwd_exported.rs` | Combined activation chain: A pane with `OLDPWD` set in its shell env emits `bash -c 'source <venv>/bin/activate; conda activate <env>; export OLDPWD=<oldpwd>; exec bash'` — uses `export OLDPWD=…`, **not** `cd <oldpwd>` (which would override `-c <cwd>` and land in the wrong directory). Mirrors ksession.sh:263. This is the row that pins the `export OLDPWD=…` vs `cd <oldpwd>` choice; `tmux_pane_shell_context.rs` is the narrower VENV-only emission shape. |
| `tmux_pane_shell_direnv_unused.rs` | DIRENV_DIR is captured from the pane's environ but is NOT used in the emitted activation string — parity with Bash's captured-but-unused behavior at ksession.sh:248–267. A future v2 fix would wire this in; v1 must replicate the omission. |
| `tmux_less_pane_single_percent.rs` | Less / man / more / most / pg pane restore commands emit `<exe> +<pct>% -- <file>` with a single `%` (not `%%`). Regression against the Bash `printf '%s +%d%%%% -- %s'` format-string bug at ksession.sh:293, which the Rust port silently fixes. |
| `tmux_per_window_active_pane.rs` | The emitted `restore.sh` emits a `tmux select-pane -t "$SESS:<win_idx>.<active_pane>"` AFTER each window's `select-layout`, restoring the active pane in EVERY window (not just the active window). Then a global `tmux select-window -t "$SESS:<active_win>"` selects the active window. Regression against the Bash overwrite bug at ksession.sh:381–382 where only the last window's active pane survived assignment. |
| `tmux_empty_prog_argv_default_shell.rs` | When a shell pane has no activation context (no `VIRTUAL_ENV`, no `CONDA_DEFAULT_ENV`, no `OLDPWD`), the emitted `tmux new-window`/`split-window` line drops the trailing program-argv argument entirely, letting tmux launch its configured `default-shell`. |
| `tmux_pane_id_strips_percent.rs` | Sidecar paths under `<state_dir>/tmux/<sess>/win-<X>/pane-<Y>/…` use the leading-`%`-stripped pane id (e.g., `%37` → `pane-37`), not the raw `#{pane_id}`. The `-t %37` form is still used when querying tmux. Mirrors `local uid=${pane_id#%}` at ksession.sh:384. |
| `tmux_quote_nul_rejected.rs` | A string containing `\x00` passed to the shell-escape wrapper is rejected at the boundary (debug: panic; release: warn-log + degrade to bare shell). NUL cannot round-trip through `bash -c <argv>` because bash truncates argv at NUL (C string semantics). |
| `tmux_layout_leaf_count_mismatch_skips_select_layout.rs` | When `pane_dead=1` filtering removes panes such that the surviving pane count differs from the leaf count parsed from the captured `window_layout` string, the emitted `restore.sh` OMITS the `select-layout` line for that window and warn-logs. Asserts the leaf parser correctly counts the `<W>x<H>,<X>,<Y>,<id>` tail pattern. Avoids the silent-no-op bug verified on tmux 3.4 where `select-layout` exits 0 with no output when pane counts mismatch. |
| `tmux_base_index_drift.rs` | A session captured under `base-index 0` and restored under `base-index 1` (or vice versa) survives — the emitted `restore.sh` handles base-index drift via `move-window` (or arithmetic; see §5.4 base-index subsection) rather than emitting `new-window -t :<captured_idx>` which would error with `index in use`. |
| `tmux_no_server_bareshell.rs` | `$TMUX` unset/empty in the foreground process's environ (the foreground tmux client is not connected to a server) degrades that OS-window's capture to `Program::BareShell` with a warn-log. No `Program::Tmux` is emitted; no `restore.sh` is written. Mirrors §5.4 "Entry: client pid → session name" step 2 ($TMUX-empty rule). |
| `tmux_unknown_client_pid_bareshell.rs` | `tmux list-clients -F '#{client_pid} #{session_name}'` returns no row matching the foreground process's pid (client died mid-save, attached to a different server's socket, or pid is a non-client tmux helper). Adapter degrades to `Program::BareShell` with warn-log `tmux pid=<pid>: no attached session`. Mirrors §5.4 "Entry: client pid → session name" step 4 (no-row-matches degrade). |
| `tmux_control_pipe_reused.rs` | Two tmux windows on the same `(socket_path, server_pid)` reuse a single `tmux -C attach` pipe across all queries — does not spawn a new control-mode subprocess per query. Asserts pipe reuse via process-counting against `pgrep tmux` before/after. Regression against silently falling back to subprocess transport. Mirrors §5.4 "Entry: client pid → session name" step 3 (per-server pipe reuse) and §B.3.2 "Control-mode pipe ownership". |
| `tmux_octal_decode_scoped_to_capture.rs` | A `display-message`/`list-windows` response containing a literal `\NNN`-shaped byte sequence (e.g., a response payload containing literal backslash or octal-shaped bytes that arrived OUTSIDE a `capture-pane -e` block (e.g., a tmux `window_layout` string containing literal `,` `[` `]` `{` `}` separators, or a session name containing a literal backslash)) passes through the general command-block parser verbatim; only `capture-pane -p -C -e` responses go through the octal decoder. Negative-side complement of `tmux_capture_pane_octal_decode.rs`. Mirrors §B.3.2 lines 1705–1709. |
| `tmux_scrollback_opt_out.rs` | With `KSESSION_SCROLLBACK=0` in the save environment, no `capture-pane` calls are issued and no `scrollback.ansi` sidecars are created under `<state_dir>/tmux/<sess>/win-<X>/pane-<Y>/`. Mirrors §5.4 scrollback-gating subsection and §1.5 `KSESSION_SCROLLBACK`. |
| `tmux_headless_no_select_window.rs` | When no window was marked active during capture (e.g., headless tmux session), the emitted `restore.sh` omits the trailing `tmux select-window` line. Independently, when a window has no marked-active pane (capture race killed the pane between `list-panes` and the `pane_active` read), that window's `select-pane` line is omitted. Mirrors §5.4 "Layout + focus trailer" omissions for headless sessions and missing-active-pane races. |
| `tmux_v1_pane_position_scrambling_parity.rs` | [PARITY-CONTRACT, NOT REGRESSION] Pins v1 parity: a tmux window manually rearranged with `swap-pane`/`move-pane` so pane indices do not run monotonically across the layout's geometric tree restores with correct geometry but pane CONTENTS in scrambled positions — matching Bash (`ksession.sh:399–430`). A v2 fix changing this must remove or update this test. Documents the v1 parity contract in §5.4 "Three-way pane-emission state machine". |
| `tmux_pre_32_refresh_client_fallback.rs` | With the tmux version probe reporting `< 3.2`, the control-mode connection emits the documented fallback (`refresh-client -C <w>x<h>` against the largest existing client, or sentinel size when no other clients are attached) — does not silently rely on `-r` which doesn't alias to `ignore-size` on `< 3.2`. Mirrors §B.3.2 "Fallback for tmux < 3.2". |
| `tmux_tmux_env_parse.rs` | `$TMUX` env var format `<socket_path>,<server_pid>,<session_id>` is parsed correctly from `/proc/<fg_pid>/environ`. Malformed `$TMUX` (missing fields, non-numeric pid/sid, non-UTF-8 bytes) degrades to `Program::BareShell` with a warn-log; valid `$TMUX` yields a (socket_path, server_pid, session_id) tuple where session_id is the numeric form addressable as `$<sid>` in tmux `-t` targets. Mirrors §5.4 "Entry: client pid → session name" step 2 ($TMUX parse). |
| `tmux_list_clients_matching.rs` | `tmux list-clients -F '#{client_pid} #{session_name}'` over the control-mode pipe is parsed line-by-line, splitting on the first space; the row whose column 1 equals the foreground pid is selected and column 2 becomes the session name passed to subsequent `-t <sess>` queries. No match yields `Program::BareShell` (covered by `tmux_unknown_client_pid_bareshell.rs`). Mirrors §5.4 "Entry: client pid → session name" step 4 (list-clients pid match). |
| `tmux_version_detection.rs` | The startup one-shot `tmux -V` subprocess probe parses tmux version strings (`tmux 3.4`, `tmux 3.3a`, `tmux next-3.5`, `tmux 3.0-rc4`) into a comparable `(major, minor)` tuple and gates the `-r` attach flag vs. the `refresh-client -C` fallback. The probe MUST be a one-shot subprocess, not `display-message -p '#{version}'` over the control pipe — the attach flag is chosen before the pipe is opened (§B.3.2 "Fallback for tmux < 3.2"). Stubbed `< 3.2` responses select the fallback path; stubbed `≥ 3.2` responses select the `-r` path. Missing/unparseable version output conservatively assumes `< 3.2` (i.e., picks the fallback). |
| `tmux_control_pipe_cancellation.rs` | A dropped `request()` future (e.g., the caller times out, or the recursive registry dispatch is canceled mid-fan-out) drops its `oneshot::Receiver`. The demuxer's later `send()` on the corresponding `oneshot::Sender` returns `Err(SendError)`; the demuxer discards the response and removes the entry from the per-pipe `HashMap<u32, Sender<…>>` rather than leaking. Mirrors §B.3.2 lines 1799–1800. |
| `tmux_not_in_path_bareshell.rs` | When `tokio::process::Command::new("tmux").arg("-V")` fails with ENOENT or non-zero exit, the tmux adapter degrades to `Program::Raw { argv: vec!["tmux".into()] }` with a warn-log. Mirrors §5.4 "Bootstrap ordering" step 1 (ksession.sh:314–318). |
| `tmux_move_window_skipped_when_idx_matches_base.rs` | When the captured first-window index equals the restore-time `base-index`, the emitted `restore.sh` skips `tmux move-window` (gated by `[[ <captured_first_idx> -ne $TMUX_BASE_INDEX ]]`). Regression against `server_link_window`'s `"same index: <N>"` error when source and destination are the same. |
| `tmux_restore_sh_sess_var_set.rs` | The emitted `restore.sh` assigns `SESS=<shell-escaped session name>` as the first body line after the static template preamble (`#!/bin/bash` + `set -euo pipefail`), so all `"=$SESS"` references in the preamble's collision-check block are defined. Asserts the script runs without `set -u` aborting. |
| `atomic_publish_gen_isolation.rs` | Kill `session::save` mid-write — between sidecar writes into the gen-stamped `<name>.gen-<gen_us>.state/` and the final `<name>.conf.tmp → <name>.conf` rename. Assert the prior `<name>.conf` (which references a different `<name>.gen-<prev_us>.state/`) survives intact and remains the live entrypoint. The orphaned gen-stamped dir from the killed save is collected by sweep on the next run (no `*.tmp.<pid>` ever exists for the state dir under the F#1 design — only the conf has a `.tmp.<pid>` suffix). Validates the §B.4 atomic-publish protocol: gen-stamped state dir created at final name → fsync → write conf.tmp → fsync → rename conf; sweep collects orphan gen-dirs. |
| `capture_window_one_failure_does_not_abort.rs` | Stub one adapter (e.g., `adapter::nvim`) to return `Err(AdapterError::…)` for one window. Assert: the whole save completes; that window's emitted `Program` is `BareShell`; `SharedCtx.errors` contains the failure; remaining windows are captured normally. Validates the §5.7 per-window degrade rule (one adapter failure must not abort the join). |
| `parallel_overlap.rs` | Insert a known 200ms sleep inside `adapter::less::capture` for one window. With N ≥ 3 live windows, assert total wall-clock save time < N × 200ms — i.e., adapters run concurrently via the §B.2 `buffer_unordered(12)` topology, not serially. Without this regression test the entire concurrency design is unverified. |
| `uuid_tagging_covers_every_live_window.rs` | With N live kitty windows, assert that N pipelined `set_user_vars` calls (one per surviving window) are issued over a single §B.3.1 socket before `@ ls --output-format=session`; the calls cover all N window ids paired with distinct UUIDs; and each call is response-acknowledged (NOT `no_response: true` — superseded by §5.7 Phase 0.5 / F#2: per-window acks are required so failed tags can be dropped before Phase 1). Ack here means per-window status from N envelopes, not one envelope. Validates §C.3 (pipelined per-window, distinct UUIDs, all live ids) and the F#2 ack-required policy. |
| `uuid_tag_window_died_mid_save.rs` | Tag N windows via the §C.3 burst, kill window K between the tag burst and the `@ ls`, then run `save_as_session`. Assert: no crash; the surviving N-1 windows appear in the rendered `.conf`; window K is omitted entirely (NOT emitted as an untagged passthrough). Validates §C.1:2486–2488 (dead-window race handling). |
| `resolve_target_program_nvim_fg.rs` | Foreground process IS nvim directly (not a shell containing nvim as a descendant). Assert `resolve_target_program` returns `Some(TargetHint::Nvim)` without performing a descendant walk. |
| `resolve_target_program_less_fg.rs` | Foreground process IS less directly. Assert `resolve_target_program` returns `Some(TargetHint::Less)` without descendant walk. |
| `resolve_target_program_no_matching_descendant.rs` | Foreground is a shell whose descendants contain NO entry in {tmux, nvim, less, man, more, most, pg}. Assert `resolve_target_program` returns `None`, and `Registry::capture` falls through to `adapter::shell` (NOT to `Program::Raw`). |
| `resolve_target_program_empty_fg_falls_back_to_wpid.rs` | `foreground_processes` is empty (Bash 527–529 fallback path). Assert fg_pid equals the window's root pid and the descendant walk proceeds from that pid (not aborted). |
| `resolve_target_program_more_most_pg_map_to_less.rs` | Table-driven: each of `more`, `most`, `pg` appears as the descendant-walk match. Assert `resolve_target_program` returns `Some(TargetHint::Less)` for all three (the Bash adapter alias-set collapses to the less adapter). |
| `patcher_unmatched_uuid_passthrough.rs` | A window appears in the §C.1 skeleton with no UUID tag (race: created between the §C.3 tag burst and `save_as_session`). Assert the skeleton's `launch` line for that window is emitted verbatim in the rendered `.conf` (no panic, no drop). Validates §C.1:2486–2488. |
| `blank_polluted_titles_both_triggers.rs` | Table-driven with two subcases: (a) stale-command regex — title `"tmux attach -t 0"` matches `^(tmux\|exec\|nvim\|less\|man\|vim\|sudo\|ssh\|cd\|ls)\b`; (b) descendant-walk hint — ANY window in the tab (not just the foreground/active one) resolved to `TargetHint::Tmux` during Phase 1, even though the title (`"work"`) does not match the regex. The (b) subcase MUST include a tab with two non-active tmux windows + one active non-tmux window, asserting the tab is still blanked. Both subcases result in blanked titles. Mirrors Bash `ksession.sh:691–712` iteration over ALL filtered pids. NOTE: This is a deliberate tightening over Bash, which checked `proc_exe_base "$tp" == "tmux"` directly (ksession.sh:694–701). The Rust port routes through `TargetHint::Tmux` so the trigger fires only when descendant resolution actually picked tmux as the program — not when an unrelated process named `tmux` happens to appear in `/proc/<pid>/exe`. Captured under §11 as an intentional behavior change. |
| `blank_polluted_titles_multi_tab.rs` | Multi-tab session: tab 1 has a polluted title that matches the stale-command regex, tab 2 has a clean title `"my project"`. Assert tab 1 is blanked in the rendered `.conf` and tab 2 is preserved verbatim — blanking is per-tab, not global. |
| `schema_mismatch_rejected.rs` | Hand-craft a `manifest.json` with `schema: 0` (and a second subcase `schema: 999`). Assert `ksession list` / `ksession show` / `ksession restore` reject the session with `KError::SchemaMismatch { name, found, expected }`. Assert the existing `.conf` is NOT deleted on rejection (user must re-run `save` to overwrite). |
| `empty_tab_emits_bare_shell.rs` | A tab where every window is either `is_self=true` or an overlay (i.e., filtered out before emission). Assert the rendered `.conf` contains a synthetic `launch /bin/bash -l` line for that tab — parity with Bash 722–725 (never emit an empty tab). |
| `new_os_window_separator_preserved.rs` | Save a session with 2 OS windows. Assert the rendered `.conf` contains a `new_os_window` token between them, preserved from the §C.1 skeleton (the patcher must not strip OS-window separators while substituting `launch` lines). |
| `kitty_window_scrollback_gate.rs` | With `KSESSION_SCROLLBACK=0` in the save environment, assert no `<state>/scrollback/win-<id>.ansi` files are written for kitty-window scrollback. With `KSESSION_SCROLLBACK=1` (or unset), assert the scrollback sidecars ARE written. Gates kitty-window scrollback capture symmetrically with the tmux pane gate (`tmux_scrollback_opt_out.rs`). |

#### Env vars (§1.5)

| File | What it asserts |
|---|---|
| `sessions_dir_env_override.rs` | `KITTY_PROJECT_SESSIONS_DIR=<path>` in the save environment redirects `.conf` and `.gen-*.state/` writes/reads to that path; restore/list/show resolve sessions from there. Bash parity (`ksession.sh:26`). Verifies the override path is honored by `session::sessions_dir` end-to-end. |
| `kitty_window_id_resolved_from_env.rs` | `KITTY_WINDOW_ID=<n>` in the save environment (with no `--window-id` flag) resolves to `SaveOpts.window_id == Some(n)` via `cli/save`. `session::save` operates on the pre-resolved option and never reads the env var directly. Mirrors §1.5 row for `KITTY_WINDOW_ID`. |
| `restore_size_env_override.rs` | `KSESSION_RESTORE_SIZE=300x80` on a tmux `< 3.2` fallback path emits `refresh-client -C 300x80` (not the default `200x60`). Subcase: malformed values (`KSESSION_RESTORE_SIZE=foo`, empty string, missing `x`, non-numeric) fall back to `200x60` with a warn-log. Mirrors §1.5 / §B.3.2 fallback rule. |
| `ksession_impl_wrapper_guards.rs` | The `ksession-save-prompt.sh` wrapper rejects `KSESSION_IMPL` values that name a bare shell (`bash`, `sh`, `zsh`) and rejects non-executable paths before exec. Shell-level test (under `tests/integration/`) drives the wrapper with each rejection case + a happy-path executable. Mirrors §7 wrapper guards and §1.5 row for `KSESSION_IMPL`. |
| `ksession_scrollback_malformed_value.rs` | `KSESSION_SCROLLBACK=foo` (and other non-`0`/non-`1` values) parses defensively in `cli/save` and resolves to `SharedCtx.scrollback_enabled=true` (default-on) with a warn-log. Bash uses `(( ${KSESSION_SCROLLBACK:-1} ))` which would error on `foo`; the Rust port replaces this with explicit `bool` parsing. Mirrors §1.5 row for `KSESSION_SCROLLBACK`. |
| `ksession_force_edge_cases.rs` | The generated `restore.sh` reads `KSESSION_FORCE` with bash `[[ -z "${KSESSION_FORCE:-}" ]]` semantics: `unset` → attach; `=` (empty) → attach; `=0` → rebuild (non-empty); `=1` → rebuild. Three subcases beyond the existing `KSESSION_FORCE=1` regression. Mirrors §1.5 row for `KSESSION_FORCE`. |

#### nvim (§5.3)

| File | What it asserts |
|---|---|
| `nvim_buffer_truncation_at_cap.rs` | A modified buffer larger than 8 MiB is truncated at the cap during dump; the emitted `BufferDump` has `truncated: true`, `byte_count == 8 << 20`, and a warning is logged. The Lua loader surfaces the truncation via `vim.notify` at restore time. Verifies §5.3's "8 MiB per buffer" cap. |
| `escape_vim_string.rs` | Unit test for the `escape_vim_string` helper used by `NvimConn::mksession` to quote paths inside `silent! mksession! …`. Round-trips paths containing single quotes, backslashes, embedded newlines, and non-ASCII bytes through the helper and asserts the resulting vim expression evaluates back to the original path. Distinct from `conf::kq`. |
| `nvim_conn_drop_does_not_kill_io.rs` | Construct an `NvimConn`, hold it for the lifetime of a capture, then drop it; assert the inner `_io_handle: JoinHandle` survives until `Drop` runs (regression against accidentally dropping the handle inline, which would silently kill the connection). Pairs with the §11 risk "nvim-rs IO handler future drops silently". |
| `nvim_degrade_per_failure_mode.rs` | Three subcases — (a) socket file missing, (b) socket exists but connect refused, (c) RPC error mid-mksession — each fold the per-window result to `Program::Raw { argv: vec!["nvim".into()] }` with a warn-log naming the specific failure mode. Verifies §5.3 "Error degradation" enumeration end-to-end (not just the generic adapter-error path covered by `capture_window_one_failure_does_not_abort.rs`). |

#### Adapter / Registry (§5.5)

| File | What it asserts |
|---|---|
| `max_adapter_depth_value_pinned.rs` | Compile-time / behavioral assertion that `MAX_ADAPTER_DEPTH == 2`. Guards against silent bumps that would change the nested-tmux degrade boundary. Pairs with `tmux_nested_tmux_depth_capped.rs` which exercises the behavior but not the constant. |
| `registry_all_decline_falls_to_bare_shell.rs` | A `WindowCtx` whose foreground program is unrecognized by every registered adapter (`Adapter::detect` returns `false` for all) results in `Registry::capture` returning `Program::BareShell` — NOT `Program::Raw`. Verifies §5.5 fallthrough order: nvim → less → shell → tmux → raw → bare-shell. |
| `adapter_raw_argv_source.rs` | The `adapter::raw` path sources argv from `kitty_window.foreground_processes[-1].cmdline` (the last entry in kitty's reported foreground process list), NOT from `/proc/<pid>/cmdline`. Regression against argv-rewriting daemons (Postgres, gunicorn) where `/proc` shows the rebranded name. Verifies §5.5 raw adapter argv source. |
| `restorable_kitty_argv_converges.rs` | The (documented dead-code) `Restorable::kitty_argv` fallback for `Program::Tmux` emits `vec!["/bin/bash", restore_sh.into_os_string()]` — no `--hold`, no `--cwd`. Pins the documented shortcoming so a future refactor doesn't silently change the fallback shape. The primary code path is §C.1's conf-patcher; this row pins the fallback. |

#### Conf rendering (§5.6)

| File | What it asserts |
|---|---|
| `conf_description_header_format.rs` | The rendered `.conf` begins with exactly three header lines (in order): `# ksession-rs session <name>`, `# Description: ksession save '<name>' at <RFC3339-UTC>`, `# Schema: <CURRENT_SCHEMA>`. `cli/list` parses the Description line; the format is load-bearing. F#20 in §5.6. Asserts presence, ordering, and timestamp format (RFC 3339 with `Z` suffix). |
| `focus_matching_window_emission_gate.rs` | Per-tab F#21 emission rule: when `active_window_idx == 0` (active window is the first launch in the tab), the `focus_matching_window var:ksession_id=<uuid>` line is OMITTED (kitty already focuses the first window). When `active_window_idx > 0`, the line is emitted AFTER the tab's last `launch` and references the `ksession_id` of `windows[active_window_idx]`. Diverges from Bash which used `ksession_idx`; the Rust port uses UUIDs. |

#### Orchestration (§5.7)

| File | What it asserts |
|---|---|
| `capture_window_timeout_degrades.rs` | A stubbed adapter that never returns within `PER_WINDOW_BUDGET = 15s` is wrapped by `tokio::time::timeout` at the `buffer_unordered(12)` layer; the per-window result degrades to `Program::BareShell` and `AdapterError::Timeout` is pushed onto `SharedCtx.errors`. Pins the 15s constant (F#16). Already named in §11 risks. |
| `partial_capture_threshold.rs` | When degraded captures exceed the threshold (ANY nvim or tmux failure, OR ≥25% of windows degrade), `session::save` returns `Err(KError::PartialCapture { degraded, total })`. `cli/save` surfaces this with a non-zero exit code and a stderr summary. Already named in §11 risks. |
| `state_tmpdir_drop_cleanup.rs` | A `StateTmpdir` newtype dropped via panic / cancellation (Ctrl-C, future cancel) runs its `Drop` guard and `rm -rf`s the orphan `<name>.gen-<gen_us>.state/` directory. `commit_session` consumes the `StateTmpdir` by value to suppress the Drop on a successful save. Already named in §11 risks (§5.7 + §B.4). |
| `gen_collision_after_8_retries.rs` | When `<name>.gen-<gen_us>.state/` creation fails with `AlreadyExists`, the orchestrator retries: first by appending `_<pid>` suffix to disambiguate, then by incrementing `gen_us` and retrying. After 8 total attempts without success, `session::save` returns `Err(KError::GenCollision { attempts: 8 })`. Pins the retry policy from §B.4. |
| `save_opts_name_revalidated.rs` | When `session::save` is called directly (bypassing `cli/save`) with a `SaveOpts.name` containing forbidden characters (`/`, leading `.`, `..`, control bytes, NUL) it returns `Err(KError::InvalidName)`. The check is defensive — `cli/save` already validates, but `session::save` re-validates because the lib is public and used by integration tests + future GUI consumers. |
| `restore_orphan_sweep_runs_pre_phase_0.rs` | A `restore` invocation (not `save`) on a sessions dir containing orphan `<name>.gen-<gen_us>.state/` directories runs the sweep at Phase −0.1 before restore proceeds. Orphans older than `SWEEP_MIN_AGE = 60s` and not referenced by any live `.conf` are removed; younger orphans and referenced orphans survive. Mirrors §B.4 sweep specification. |

#### Atomic publish (§B.4)

| File | What it asserts |
|---|---|
| `atomic_publish_sweep_predicates.rs` | The sweep predicate matches paths of the form `<name>.gen-<digits>_<digits>.state/` (or `<name>.gen-<digits>.state/` without pid suffix); rejects paths matching the protected bare-name pattern `<name>.state/` (Bash-era directories must NOT be swept); applies `SWEEP_MIN_AGE = 60s` age guard before removal; and skips any path referenced (by absolute path) from a live `.conf` body. Three subcases for each predicate dimension. |
| `atomic_publish_cross_filesystem_rename.rs` | When the state dir and conf live on different filesystems (rename returns `EXDEV`), `session::save` returns `Err(KError::CrossFilesystem)` rather than attempting a copy-fallback. The error surface is clean; no partial state is committed. |
| `atomic_publish_fsync_ordering.rs` | Verifies the §B.4 fsync sequence on a successful save: (1) all sidecars in `<name>.gen-<gen_us>.state/` written and fsynced; (2) the gen-stamped state dir's directory entry fsynced; (3) `<name>.conf.tmp.<pid>` written and fsynced; (4) `<name>.conf.tmp.<pid>` renamed to `<name>.conf`; (5) parent dir fsynced. Uses LD_PRELOAD-injected fsync counter or strace-based verification to assert ordering. |

#### Skeleton patcher (§C.1)

| File | What it asserts |
|---|---|
| `patcher_no_kitty_unserialize_data_token.rs` | The §C.1 conf-patch pipeline (parse skeleton → patch → render) MUST eliminate every `kitty-unserialize-data` token from the output. Captures a skeleton with `kitty-unserialize-data` blobs, patches, asserts the rendered `.conf` contains zero matches. Explicitly demanded by §C.1. |
| `synthetic_empty_tab_injection_detected.rs` | The patcher distinguishes (a) synthetic empty-tab windows (detected by `Window.kitty_id == 0`) — which require injection of a `launch /bin/bash -l` line into the skeleton — from (b) race-window passthrough (a window present in the skeleton but with no matching `model::Window`, e.g., created between the §C.3 UUID tag and `save_as_session`) — which is emitted verbatim. The two cases use different detection rules and different code paths; this row pins both. |
| `patcher_multi_os_window_concatenation.rs` | A session with 2 OS windows results in two distinct `kitten @ action save_as_session --save-only --use-foreground-process <tmp>` calls (one per OS window, matched by `--match id:<os_window_id>`), and the patcher concatenates the two skeletons with the `new_os_window` separator preserved between them in the final `.conf`. Distinct from `new_os_window_separator_preserved.rs` which only verifies the separator survives. |
| `patcher_set_layout_state_opaque.rs` | The patcher treats `set_layout_state` blobs as opaque base64 — never inspects, decodes, or transforms them. A skeleton with a known-good `set_layout_state` blob round-trips byte-identical to the output. Guards against accidentally introducing layout-state parsing that could break split geometry restore. |
| `patcher_emits_ksession_win_var.rs` | Every patched `launch` line carries `--var ksession_win=<kitty_window_id>` in addition to `--var ksession_id=<uuid>`. For synthetic empty-tab windows (where `kitty_id == 0`), the emitted value is `ksession_win=0`. Pairs with `tmux_conf_patch_restore_launch.rs` which only asserted the `ksession_id` half. |

#### OSC 1337 push (§C.2)

| File | What it asserts |
|---|---|
| `adapter_shell_consumes_user_vars.rs` | `adapter::shell` reads `ksession_venv`, `ksession_conda`, `ksession_oldpwd`, `ksession_direnv` from `kitty::Window.user_vars` BEFORE falling back to `/proc/<pid>/environ`. Four subcases — one per user_var — assert the user_vars value wins over the /proc value when both are set with different values. Mirrors §C.2 fast-path contract. |
| `nvim_socket_via_user_var.rs` | `nvim_rpc::socket_for_pid` reads `ksession_nvim_sock` from `kitty::Window.user_vars` BEFORE the §5.3 four-tier `/proc`-walking discovery. When `ksession_nvim_sock` is present and points to a live socket, no `/proc` reads are issued. When absent (Bash-era window, or shell hook didn't fire), the four-tier discovery runs as before. Mirrors §C.2 OSC 1337 fast-path for nvim. |

#### --hold matrix (§C.4)

| File | What it asserts |
|---|---|
| `hold_flag_on_nvim_launch.rs` | The rendered `.conf` `launch` line for a `Program::Nvim` window includes `--hold` before the program argv. Asserts that nvim's failure surface (e.g., session.vim missing, crash on startup) leaves the kitty window visible with the error rather than instantly closing it. |
| `hold_flag_on_less_launch.rs` | The rendered `.conf` `launch` line for a `Program::Less` window includes `--hold` before the program argv. Symmetric with the nvim case. |
| `hold_flag_omitted_for_bare_shell.rs` | The rendered `.conf` `launch` line for `Program::BareShell` and `Program::Shell` (interactive shells) OMITS `--hold` — a user `exit`ing their shell should close the kitty window naturally, not pin it open. Negative-case complement of the nvim/less rows. |

#### RC pipelining (§C.6)

| File | What it asserts |
|---|---|
| `single_kitty_socket_per_save.rs` | Over the lifetime of one `session::save` call, exactly ONE `UnixStream` is opened to kitty's RC socket; all RC calls (`@ ls`, `set-user-vars` burst, `save_as_session`) are pipelined over that single connection. Asserts via lsof-style file-descriptor counting against the kitty process before/after save, or by inspecting the in-process `Mutex<UnixStream>` lifetime. Mirrors §C.6 single-connection guarantee. |

#### tmux specifics (§5.4 + §B.3.2)

| File | What it asserts |
|---|---|
| `tmux_session_name_apostrophe_via_sid.rs` | A tmux session whose name contains a single quote (`'`) is queried at save time via `-t '$<sid>'` (numeric session id from `$TMUX` field 2), NOT via `-t '<session_name>'` — sidesteps single-quote breakage in command-mode string quoting. The session id is the `session_id` field on `Program::Tmux`. Mirrors §5.4 "Entry: client pid → session name". |
| `tmux_unknown_pane_argv_preserves_tokens.rs` | A pane running an unknown program (not in {tmux, nvim, less, man, more, most, pg}) has its argv captured as a `Vec<String>` split on NUL from `/proc/<pid>/cmdline`. Tokens containing embedded spaces (e.g., `python -c 'print("hello world")'`) survive verbatim through the emitted `new-window` line. Diverges from Bash which used `tr '\0' ' '` and flattened to a single string. |
| `tmux_base_index_clamp_branch.rs` | A session captured under tmux config `base-index 2` and restored under `base-index 0`: the captured first-window index (2) is greater than the restore-time base (0), so the emitted `restore.sh` uses `tmux move-window` to relocate from base-index 0 to index 2. The reverse case (captured base 0, restored base 2): captured first-window index (0) is LESS than restore-time base (2), so subsequent `new-window -t :<idx>` references must be rewritten to `max(captured, base)` and per-window `select-window`/`select-pane` reference targets clamped accordingly. Distinct emission path from `tmux_base_index_drift.rs`. |
| `tmux_list_clients_err_vs_no_match.rs` | Distinguishes two degradation paths: (a) `control.request("list-clients ...")` returns `Ok(rows)` with no row matching the foreground pid → warn-log `tmux pid=<pid>: no attached session` (already covered by `tmux_unknown_client_pid_bareshell.rs`); (b) `control.request` returns `Err(...)` (pipe spawn failed, `%exit` mid-request, server died) → warn-log `tmux pid=<pid>: list-clients failed: <err>` with the underlying error chained. Both degrade to `Program::BareShell` but with distinct log lines. |
| `tmux_control_mode_unknown_notification_dropped.rs` | The control-mode parser receives a `%foo-event` line (unknown notification type) outside any `%begin/%end` block. Asserts: the line is DEBUG-logged and dropped (forward-compat); the parser does NOT error or drop the pipe. Pairs with §B.3.2 forward-compat rule. |
| `tmux_control_mode_percent_error_terminator.rs` | A control-mode command response that begins with `%begin <ts> <num> <flags>` but ends with `%error <ts> <num>` (instead of `%end <ts> <num>`) is surfaced as a per-command `TmuxError::CommandFailed { stderr }` to the `oneshot::Receiver`. The pipe stays open; subsequent commands succeed. Pairs with §B.3.2's `%end` vs `%error` discrimination. |
| `tmux_control_pipe_write_mutex_atomicity.rs` | Two concurrent `request()` callers MUST NOT interleave their (enqueue-sender + write_all-bytes) under the write mutex. A property test fires N concurrent requesters against a single pipe; asserts every response is delivered to the correct `oneshot::Sender` and that FIFO head-pop binding is preserved. Verifies the write-mutex atomicity invariant load-bearing for cmd-num correlation (§B.3.2). |
| `tmux_pre_29_dash_c_separator.rs` | With the tmux version probe reporting `< 2.9`, the control-mode `-C` argument uses the `Cw,Ch` separator (comma) not `CwxCh` (x). Mirrors §B.3.2 version-gated argument format split. Stubbed `< 2.9` version selects comma; `>= 2.9` selects `x`. |

#### Disk layout / Migration (§6 / §11)

| File | What it asserts |
|---|---|
| `disk_layout_matches_bash.rs` | An end-to-end save against a fixture session asserts the full directory tree under the resolved sessions dir matches the layout enumerated in §6 (after stripping the gen-stamp basename suffix on `<name>.gen-<gen_us>.state/`). Compares against a golden snapshot of every path: `<name>.conf`, `<name>.state/nvim/win-<id>.vim`, `<name>.state/nvim/win-<id>.json`, `<name>.state/nvim/win-<id>.dumps/buf-<n>.txt`, `<name>.state/scrollback/win-<id>.ansi`, `<name>.state/tmux/<sess>/restore.sh`, `<name>.state/tmux/<sess>/win-<X>/pane-<Y>/...`, `<name>.state/manifest.json`. Catches accidental path-shape regressions that no single-feature test would notice. |
| `bash_era_session_restores.rs` | A `.state/` directory produced by the Bash version of ksession (containing the old appended `s:KsessionRestoreBuffer` vim function inside the session.vim, the older sidecar layout, and no `manifest.json`) restores cleanly via the Rust binary. Subcases: (a) a Bash-era session.vim with the appended function still loads at restore, the buffers come back; (b) `ksession-rs list` and `ksession-rs show` operate on the Bash-era session without crashing on the missing `manifest.json` — fall back to a synthetic header; (c) re-running `ksession-rs save <name>` over a Bash-era directory upgrades the sidecars in place (atomically via §B.4) without destroying the old `.state/` until the new gen commits. Highest-priority migration test per §11:2494 / §6:2199–2203. |

The orchestration-layer rows in this section (from atomic_publish_gen_isolation.rs onward through the new groups below) cover the Step 8 orchestration end-to-end: atomic publish (§B.4), per-window degrade (§5.7), parallel fan-out topology (§B.2), UUID tagging and patcher passthrough (§C.1 / §C.3 / §C.6), resolve_target_program dispatch, title-blanking, manifest schema gating, scrollback gating, OSC 1337 user-var consumption (§C.2), --hold matrix (§C.4), and disk-layout / Bash-era migration parity (§6 / §11).

**Bucket note.** A subset of the rows above functionally belong to the integration bucket — they spawn live tmux/nvim servers, count subprocess handles, or measure wall-clock concurrency. Those rows live in the regression table for thematic grouping but are marked with `#[ignore]` in source so that `cargo test` runs the pure / fixture-driven subset by default and `cargo test -- --ignored` exercises the live-process subset. Affected rows (non-exhaustive): `tmux_quote_roundtrip.rs`, `tmux_layout_preserved_on_save.rs`, `tmux_control_pipe_reused.rs`, `parallel_overlap.rs`, `bash_era_session_restores.rs`, `single_kitty_socket_per_save.rs`.

Rule: every new user-reported bug **must** ship a regression test in the same commit
as the fix.

### Differential (shadow-mode) testing

For phase 1, run bash and Rust against the same `kitty @ ls` JSON and diff outputs.
Both implementations honor the `KSESSION_FROM_LS=<path>` env var (§1.5) so capture is reproducible:

1. Capture live JSON daily from the user's kitty into `tests/fixtures/kitty-ls/`.
2. `tests/diff_runner.rs` runs both impls with `KSESSION_FROM_LS=<fixture>` against
   a stubbed `/proc` (also fixtured).
3. Parse both `.conf` outputs to a canonical `SessionConf` AST, drop nondeterministic
   fields (`description.timestamp`, fresh socket paths inside the captured nvim
   sessions, tmux temporary names), assert AST equality.

Functional equivalence, not byte-identical. Byte-identity makes tests flaky on benign
changes (timestamp drift, pid reuse).

**Canonical AST (`SessionConf`).** The diff runner parses both implementations' `.conf` outputs into a `SessionConf` AST defined in `tests/diff_runner_ast.rs` with the shape:

- `header: { description: Option<String>, schema: Option<u32> }` — the `# Description: …` and `# Schema: …` lines, parsed into structured form. `header.description.timestamp` is normalized to a fixed sentinel before comparison.
- `os_windows: Vec<OsWindowAst>` — ordered list, separator-preserving.
- `OsWindowAst { tabs: Vec<TabAst> }`.
- `TabAst { title: Option<String>, layout: String, launches: Vec<LaunchAst>, focus_match: Option<FocusMatchAst> }`.
- `LaunchAst { cwd: Option<PathBuf>, hold: bool, vars: BTreeMap<String, String>, argv: Vec<String> }` — `vars` is a sorted map so `--var` ordering differences don't trigger diffs.
- `FocusMatchAst { var_key: String, var_value: String }` — only present when a `focus_matching_window var:…` line was emitted.

Normalization rules applied before AST comparison:
1. Strip `header.description.timestamp` (replace with the literal `<NORMALIZED>`).
2. Strip fresh socket paths embedded inside captured nvim session.vim references (replace with `<NVIM_SOCKET>`).
3. Strip tmux temporary names of the form `ksession-tmp-<digits>` (replace with `<TMUX_TMP>`).
4. Rebase absolute state-dir paths from `<name>.gen-<gen_us>.state/` to `<name>.state/` so the gen-stamp doesn't fail the diff.
5. Sort `--var` arguments inside each `launch` lexicographically.

**Fixture corpus.** Live `kitty @ ls --all-env-vars` JSON snapshots and matching `@ ls --output-format=session` skeletons are captured into `tests/fixtures/kitty-ls/<scenario>.{json,skeleton}` by an opt-in developer ritual: run `make capture-fixture SCENARIO=<name>` from a live kitty session of interest. The script scrubs absolute paths under `$HOME` (replaced with `$HOME/`), strips any tokens matching common secret regexes (AWS keys, GitHub tokens), and writes both files. CI does not auto-capture; the developer reviews the diff before committing. Retention: keep all committed fixtures indefinitely (they're small and load-bearing for regressions).

**Bash invocation.** `tests/diff_runner.rs` invokes the Bash implementation by absolute path `$REPO_ROOT/scripts/ksession.sh`, passing `KSESSION_FROM_LS=<fixture>.json` in the env. The Rust binary is invoked from the test's `cargo` target dir (resolved via `env!("CARGO_BIN_EXE_ksession-rs")`) with the same env. Both implementations write into separate temp-dir sessions dirs via `KITTY_PROJECT_SESSIONS_DIR` overrides.

**Phase-1 sunset.** The differential bucket runs in every PR until the last shipped-Bash bug regression test has been ported (i.e., every row in the §8 regression table corresponds to a passing Rust-only test for at least 14 days). At that point the bucket is gated behind a `--features diff-runner` flag and only run on-demand or against new fixtures. The dated sunset criterion is checked in CI by counting failing regression-tests across `git log --since='14 days ago'`.

---

## 9. Performance target

> **Superseded:** §B.1 (post-Appendix B) and §C.9 (post-Appendix C) revise the
> targets below. Current canonical numbers: **~125 ms p50, ~350 ms p95** (§C.9).
> The section below records the original v1 target for historical context.

Bash baseline: 0.5–2.0s per save, dominated by:

- `mksession` poll loop (up to 3s ceiling; ~200ms typical per nvim).
- `tmux capture-pane` per pane (~50ms × N).
- `kitty @ get-text` per window (~100ms × N).
- `jq` subprocess fanout (~5ms × dozens).

Rust target: **250ms p50, 750ms p95** for a typical 3-tab × 4-window OS window.
Where the wins come from:

| Bash cost | Rust improvement |
|---|---|
| Per-tab `jq` re-parses of the whole ls JSON | Single in-process `serde_json` parse, threaded through. |
| `mksession` poll | `nvim_command` blocks until done — zero polling. |
| Sequential per-window capture | `tokio::join_all` per tab — mksession latencies overlap. |
| Hundreds of subprocess invocations | One process; subprocess fanout only for `kitty @ ls` + `tmux display-message`. |

Enforce a budget with `tests/perf/save_budget.rs` (12-window fixture, ≤1.5s wall
clock, `#[ignore]` on CI, runs locally pre-release).

---

## 10. Implementation phases

Module-by-module order (each step ends in a compile-and-test green checkpoint):

1. **Skeleton + model.** `cargo new`, stub modules, define every `model/` type.
   Implement `Serialize`/`Deserialize`. Zero behavior. (~0.5 day)
2. **`/proc` helpers + tests.** Pure functions over fixture filesystems. (~0.5 day)
3. **`kitty` + deserialize the ls JSON.** Spawn `kitty @ ls`, parse into typed
   structs. Check against fixtures captured from the user's real sessions. (~0.5 day)
4. **`conf::render` + `kq`.** Parse + patch the skeleton emitted by `kitty @ ls
   --output-format=session` (see §C.1). Golden-file tests against hand-curated
   skeletons under `tests/fixtures/kitty-session/`. At this point we can render
   `.conf` outputs from hand-built `SessionFile`s — even before any adapter
   exists. (~1 day)
5. **`adapter::{shell, less, raw}`.** Each adapter is ~80 LOC of `/proc` reads.
   `adapter::shell` additionally reads `kitty_window.user_vars` (populated by the
   §C.2 OSC 1337 hook) before falling back to `/proc/<pid>/environ`. (~1 day)
6. **`nvim_rpc` + `adapter::nvim`.** The big one. Includes:
   - `socket_for_pid` with 4-tier lookup
   - `NvimConn::connect`, `mksession`, `dump_modified_buffers`
   - JSON manifest emit + the `lua require(...)` append to session.vim
   - `ksession_restore.lua` shipped as `include_str!` template, installed by Makefile
   Integration test against headless nvim. (~2 days)
7. **`tmux_rpc` + `adapter::tmux`.** Control mode from day one. See §5.4 for the full
   in-scope checklist (≥25 behaviors). Integration test against an isolated tmux server.
   (~3.5 days. See §B.7 step 7 and §5.4.)
8. **`session::save` orchestration.** Phase 0–5 wiring (probe, filter, UUID-tag, capture, collect, sanitize, render, commit), `buffer_unordered(12)` fan-out (§B.2), generation-stamped state-dir atomic publish per §B.4 (3 fsyncs total). Includes `default_registry() -> &'static Registry` (signature in §5.7) backed by `once_cell::sync::Lazy`. (~1 day)
9. **`cli/` + clap subcommands.** `save`, `restore`, `list`, `show`, `rm`.

   - `save` / `restore`: thin wrappers over `session::{save, restore}`.
     `restore`: validate `name` (same regex as `save`); look up `<name>.conf` (`KError::NotFound` if absent); sweep orphan gen-stamped state dirs (best-effort); exec `kitty --detach --class "kitty-project-<name>" --session <conf_path>`. The `--class` flag matches Bash restore (`ksession.sh`) and lets window managers pin per-project workspaces.
     On success, `cli/save` emits to stdout (NOT just tracing): `ksession: saved '<name>' -> <conf_path>` followed by `ksession:   sidecar state in <state_path>`. These two lines preserve Bash parity (ksession.sh:749–750) and are parsed by `ksession-save-prompt.sh:80–83` to detect save completion before closing the prompt overlay. Removing them silently breaks the prompt UX.
     Flag parity with Bash (ksession.sh:612–621): `save` accepts `--no-scrollback` and `--scrollback` (mutually exclusive). Resolution order: explicit flag > `KSESSION_SCROLLBACK` env var > default (on). The resolved value is written to `SharedCtx.scrollback_enabled` by `cli/save` before invoking `session::save` (§5.7 never reads the env var directly — see §1.5).
     When `session::save` returns `KError::KittyRemote(_)`, `cli/save` prints to stderr: `ksession: kitty @ ls failed — is allow_remote_control on? (try: kitty @ ls)`. Preserves the Bash 637 hint.
   - `list`: enumerate `<sessions_dir>/*.conf`, print one row per session with
     created_at + window count parsed from the adjacent `manifest.json`.
   - `show <name>`: render `<sessions_dir>/<name>.state/manifest.json` as a
     tree:
     ```
     <name>  (created 2026-05-23T14:32:01Z, schema=1)
     ├── OS window 1
     │   ├── Tab 1: "project A"  layout=splits
     │   │   ├── Window 12  cwd=/home/u/proj  [nvim]  buffers=4 truncated=0
     │   │   └── Window 13  cwd=/home/u/proj  [shell] venv=…/proj/.venv
     │   └── Tab 2: "logs"  layout=stack
     │       └── Window 14  cwd=/var/log  [less] file=syslog offset=1.2MiB (32%)
     └── OS window 2
         └── Tab 1: ""  layout=splits
             └── Window 15  [tmux] session=mysess
                 ├── tmux window 0: "main"  layout=…
                 │   ├── pane 0  cwd=/home/u  [shell]
                 │   └── pane 1  cwd=/home/u/src  [nvim] buffers=2
                 └── tmux window 1: "build"  layout=…
                     └── pane 0  [shell]
     ```
     Render `Program::Tmux.windows: Vec<TmuxWindow>` recursively; each
     `TmuxPane.program: Box<Program>` dispatches the same per-variant pretty-
     printer used at the kitty-window level. This is the consumer for those
     two fields — without `show` they'd be captured-but-unused.
   - `rm <name>`: delete `<name>.conf` and `<name>.state/` atomically (rename
     to `<name>.{conf,state}.deleted.<pid>`, then unlink).

   (~0.5 day)
10. **Diff runner + regression suite.** Port every known Bash bug as a regression
    test. (~1 day)
11. **Patch `ksession-save-prompt.sh`** with the `KSESSION_IMPL` env var. Shadow-
    mode trial. (~0.5 day)

Total: ~10 dev days for full parity. Critical path is steps 6 (nvim_rpc) and 7
(tmux_rpc) — everything else is straightforward.

---

## 11. Risks & open questions

| Risk | Mitigation |
|---|---|
| `nvim-rs` lags nvim master / API renames | Pin nvim-rs and nvim version in `Cargo.toml` + `rust-toolchain.toml`. Constrain to the stable subset: `command`, `list_bufs`, `buf_get_lines`, `buf_get_var`, `buf_set_lines`, `create_buf`. All stable since nvim 0.9. |
| `kitty @ ls` JSON schema change | Never `deny_unknown_fields` on top-level types. Use `#[serde(default)]` on every optional field. Integration test against the user's real kitty version. |
| tmux format-string control-byte escaping | Use the field-per-call pattern via `display-message`; never embed delimiters in `-F`. |
| Concurrent capture surfaces races (nvim exits mid-save) | Per-adapter `Result` always degrades to bare launch + log; whole-save never aborts on one adapter. |
| User on Linux only | Stated non-goal. `/proc` access is direct; macOS would need `libproc`, deferred until needed. |
| nvim-rs IO handler future drops silently | Hold the `JoinHandle` for the lifetime of `NvimConn`. Document this with a comment at the field. |
| Bash-era saves must keep restoring after upgrade | The old appended vim function still works; we only stop *emitting* it for new saves. Tested in regression suite. |
| `KSESSION_FORCE` semantics on collision | **Specified, not deferred.** At restore time, if a tmux session of the same name already exists on the server: default behavior is to attach to the live session and emit a warning via `echo` in the generated `restore.sh` (do not destroy state). Setting `KSESSION_FORCE=1` in the env when restore launches causes `restore.sh` to `tmux kill-session -t <sess>` first, then rebuild from the captured windows/panes. Covered by `tmux_collision_attaches_live.rs` and `tmux_collision_force_rebuilds.rs` (§8). |
| Empty tab after filtering (every window is `is_self`/overlay) | Phase 2 of §5.7 emits a synthetic `Window { kitty_id: 0, program: BareShell, ... }` so the tab survives restore. Bash 722–725 parity. Tested by `empty_tab_emits_bare_shell.rs`. |
| `KSESSION_SCROLLBACK` gating inconsistent across kitty-window and tmux-pane legs | Both legs gate on the same env var (default on; `=0` disables). Kitty-window leg owned by `session::save::capture_window` (§5.7); tmux-pane leg owned by `adapter::tmux::capture` (§5.4). Tested by `kitty_window_scrollback_gate.rs`. |
| Schema mismatch on older sidecar files | `restore`/`list`/`show` reject with `KError::SchemaMismatch{name,found,expected}`; user re-runs `save` to overwrite. No silent upgrade. Tested by `schema_mismatch_rejected.rs`. |
| Adapter failures invisible to caller (Registry swallows AdapterError) | `SharedCtx.errors: Mutex<Vec<AdapterError>>` accumulates all degraded captures; `cli/save` surfaces them as `tracing::warn!` lines after `session::save` returns. Tested by `capture_window_one_failure_does_not_abort.rs`. |
| Nested kitty inside tmux | **Out of scope for v1.** If a kitty binary appears in a tmux pane's descendant tree, the tmux adapter does not recurse into nested kitty windows — the pane is captured as `Program::Raw { argv }` (matching Bash's fall-through that dumps the raw cmdline at `capture_pane_program_cmd`, `ksession.sh:266–326`) with a `tracing::debug!` note. No attempt is made to reach into the nested kitty's RC socket. |
| Nested tmux inside tmux (e.g., SSH-through-tmux into a remote tmux) | `WindowCtx.depth: u8` is incremented each time the tmux adapter synthesizes a child `WindowCtx` for a pane (§5.5). The tmux adapter's `detect()` refuses to fire when `depth >= MAX_ADAPTER_DEPTH` (default `2`), degrading the pane to `Program::Raw { argv }` with a `warn!`-log. Guards against infinite recursion when a tmux pane contains another tmux invocation. Tested by `tmux_nested_tmux_depth_capped.rs`. |
| Tmux session torn down mid-save | If `list-windows` or `list-panes` returns zero rows for a session that was visible at detection time, degrade that OS-window's capture to a bare `tmux` launch — do **not** emit a `restore.sh` that references a missing session. Warn-log via `tracing::warn!`. Covered by `tmux_empty_panes_degrades_to_raw.rs` (§8). |
| Polluted tab-title sanitization location | The title-blanking pass (`"tmux attach -t 0"` etc. → empty) runs in `session::save::blank_polluted_titles` at the **orchestration layer** (Bash `ksession.sh:691–712`), not inside the tmux adapter. Reviewers chasing the regression test `polluted_title_blanked.rs` should look in `session/` rather than `adapter/tmux.rs` or §5.4. Symmetrically, the **tmux detection** logic also lives at the orchestration layer (`session::save::resolve_target_program`, Bash `ksession.sh:537–554`), not inside `adapter/tmux.rs`. Reviewers chasing `tmux_detected_via_descendant_walk.rs` should look in `session/`, not the adapter. NB: trigger source diverges from Bash — see `blank_polluted_titles_both_triggers.rs` description in §8. |
| tmux pane has empty `pane_current_path` | Omit `-c` flag from emitted `new-session` / `new-window` / `split-window` (§5.4 edge cases). Tmux falls back to the session's `default-path`. Passing `-c ''` errors. |
| tmux session name contains `:` or `.` | Illegal in tmux. Degrade the entire tmux window's capture to `Program::Raw { argv: vec!["tmux".into()] }` with warn-log. Covered by the §5.4 edge-case subsection. |
| tmux pane is dead (`pane_dead=1`) | Skip in `list_panes` consumer at capture time. Restoring a dead pane as a live split would respawn the shell. Covered by `tmux_dead_pane_skipped.rs`. |
| Restore.sh missing strict mode | Preamble emits `#!/bin/bash` + `set -euo pipefail` — a failed `new-window` between `new-session` and `attach-session` aborts noisily rather than silently attaching to a half-built session. Tested by `tmux_restore_sh_strict_mode.rs`. |
| Tmux prefix-match collision via `has-session -t prod` matching live `production` | Use `-t "=$SESS"` (literal `=` exact-match) in `has-session`, `attach-session`, `kill-session` inside the restore.sh preamble. Tested by `tmux_collision_exact_match.rs`. |
| Tmux silent name substitution (`:`, `.` → `_`) breaks round-trip | Detect at capture time and degrade to bare `tmux` launch rather than silently substituting. The captured name would not round-trip through `clean_name()` (tmux source). Empirically verified on tmux 3.4 that `#` is NOT in the forbid set (allowed verbatim in session names); only `:` and `.` trigger substitution. Tested by `tmux_illegal_session_name_degrades.rs`. |
| Pane-position scrambling under select-layout (v1 parity with Bash bug) | Knowingly preserved for v1; TODO(v2) drive split direction from the layout tree OR emit post-hoc `swap-pane` corrections. Documented inline in §5.4 "Three-way pane-emission state machine." Tested by `tmux_v1_pane_position_scrambling_parity.rs`. |
| Bash bug: single global `select-pane` only restores the active pane in the last-processed window | Track active pane per window during capture; emit `tmux select-pane -t "=$SESS:<win_idx>.<active_pane_idx>"` immediately after each window's `select-layout` line, then a single final `tmux select-window -t "=$SESS:<active_win_idx>"` to restore the active window. Fix vs ksession.sh:381–382 + ~433–437. Tested by `tmux_per_window_active_pane.rs`. |
| Tmux base-index drift between capture and restore | Use `move-window` to relocate the bootstrap window into the captured first-window index, then subsequent `new-window -t :<idx>` references the captured indices directly. Tested by `tmux_base_index_drift.rs`. |
| Dead-pane filter silently corrupts captured `window_layout` | Gate `select-layout` emission on live-pane-count == layout-encoded-pane-count; on mismatch, omit `select-layout` and warn-log. Tested by `tmux_layout_leaf_count_mismatch_skips_select_layout.rs`. |
| NUL byte through `shell-escape` → `bash -c` truncates argv at first NUL | Reject NUL at the shell-escape boundary (debug-panic; release warn-log + degrade). Tmux metadata cannot contain NUL legitimately. Tested by `tmux_quote_nul_rejected.rs`. |
| Tmux ≥ 3.2 layout-corruption (issue #2594) | Use `attach-session -r` (alias for `read-only,ignore-size`) as the primary mitigation; race-free vs. post-attach `refresh-client -f`. Fallback for tmux < 3.2 documented in §B.3.2. Tested by `tmux_layout_preserved_on_save.rs`. |
| Control-mode 5-minute output-age timeout (`CONTROL_MAXIMUM_AGE = 300000ms`) | Read loop never blocks; demuxer uses unbounded channels (or a high-watermark bounded channel with `%output` drop policy). Save flow doesn't subscribe to `%output` by default. |
| Capture-pane raw output theoretically ambiguous inside `%begin/%end` | Use `capture-pane -p -C -e` so tmux escapes non-printable bytes at the application layer; decode `\NNN` / `\134` in the client. Tested by `tmux_capture_pane_octal_decode.rs`. |
| `Restorable::kitty_argv` for `Program::Tmux` is dead code under §C.1 | Documented in §5.5 as "fallback path only"; primary code path is the conf-patcher in §C.1, which patches launch lines via `--var=ksession_id=<uuid>` correlation. Both paths emit the same `/bin/bash <restore_sh>` form. |
| `Conf-rename and state-rename race could mismatch generations` | RESOLVED in §B.4 redesign: state dirs are gen-stamped (`<name>.gen-<ts_us>.state/`) and conf bodies reference absolute paths into their own generation. Conf-rename is the sole commit point. Old gen state-dirs become orphans collected by sweep. Tested by `atomic_publish_gen_isolation.rs`. |
| `Hung adapter (e.g., nvim socket on a stuck SSH tunnel) stalls entire save` | Per-window `tokio::time::timeout(15s, capture_window(...))` wraps each future at the `buffer_unordered(12)` layer. Timeout degrades to `BareShell` and pushes `AdapterError::Timeout`. Tested by `capture_window_timeout_degrades.rs`. See §5.7. |
| `Mass adapter failures silently produce a hollow session` | `KError::PartialCapture { degraded, total }` returned by `session::save` when degraded > threshold (any nvim/tmux failure OR ≥25% windows). `cli/save` surfaces with non-zero exit + stderr summary. Tested by `partial_capture_threshold.rs`. See §5.8. |
| `Ctrl-C mid-save leaves orphan .gen-*.state/ dirs` | `StateTmpdir` newtype with Drop guard rm -rf's on cancellation. `commit_session` consumes by value to suppress Drop on success. Sweep at next save's Phase −0.1 collects any survivors. Tested by `state_tmpdir_drop_cleanup.rs`. See §5.7 + §B.4. |

Open question: should `ksession-rs doctor` be in v1 or v2? It's a small subcommand
that checks `allow_remote_control`, nvim socket dir perms, tmux availability, and
`/proc` readability of kitty children. The Bash version has no equivalent and it'd
have caught the user's "tmux didn't open" investigation in 10 seconds. **Recommend
shipping in v1** — it's ~100 LOC and high diagnostic value.

---

## 12. Release

No packaging, no Cargo registry. A `Makefile`:

```make
build:
	cargo build --release

install: build
	install -m 0755 target/release/ksession-rs $(HOME)/.local/bin/
	install -m 0644 lua/ksession_restore.lua $(HOME)/.local/share/nvim/site/lua/

test:
	cargo test
	cargo test -- --ignored   # nvim + tmux integration

clean:
	cargo clean
```

`~/.local/bin` is already on PATH. README documents `make install` and the
`KSESSION_IMPL` env var. Done.

---

## Appendix A — File-level reference into the Bash version

Use the Bash script as the canonical behavior specification. Specific functions to
port byte-by-byte:

| Bash function | File:line | Rust target |
|---|---|---|
| `kq` | `ksession.sh:44–51` | `conf::kq` |
| `emit_launch` | `ksession.sh:53–60` | `conf::patch_launch` (via the §C.1 skeleton-patch path, not from-scratch render) |
| `proc_exe_base`, `proc_env`, `proc_descendants` | `ksession.sh:65–97` | `proc::*` |
| `nvim_socket_for_pid` | `ksession.sh:100–135` | `nvim_rpc::socket_for_pid` |
| `nvim_capture_to_file` | `ksession.sh:138–150` | `NvimConn::mksession` |
| `nvim_dump_modified_buffers` | `ksession.sh:172–236` | `NvimConn::dump_modified_buffers` |
| `less_state` | `ksession.sh:153–169` | `adapter::less::capture` |
| `capture_nvim_window` | `ksession.sh:447–465` | `adapter::nvim::capture` |
| `capture_pane_program_cmd` | `ksession.sh:243–306` | `Restorable::tmux_argv` per variant |
| `capture_tmux_window` | `ksession.sh:311–443` | `adapter::tmux::capture` + `tmux_rpc::generate_restore_sh` |
| `tmux list-clients` lookup | `ksession.sh:322` | `tmux_rpc::session_for_client_pid` |
| `tmux list-panes per window` | `ksession.sh:374–426` | `tmux_rpc::list_panes` |
| `tmux control-mode pipe lifecycle` | N/A (Rust-only, see §B.3.2) | `tmux_rpc::control::{spawn, request, shutdown}` |
| tmux detection (fg shell → walk descendants) | `ksession.sh:537–554` | `session::save::resolve_target_program` |
| `emit_launch_for_window` | `ksession.sh:500–567` | `session::save::capture_window` |
| `save_session` | `ksession.sh:608–751` | `session::save` |
| polluted-title sanitizer in `save_session` | `ksession.sh:691–712` | `session::save::blank_polluted_titles` |
| save-prompt fzf overlay | `ksession-save-prompt.sh:1–95` | Unchanged. Only one line patched (`KSESSION_IMPL` env). |

The Bash file is the ground truth. When in doubt during the port, the Bash semantics
win — they've been hardened against real-world use.

---

# Appendix B — Performance Addendum

Synthesizes four targeted investigations (concurrency topology, direct RPC sockets,
filesystem syscall optimization, build/startup tuning). This addendum **supersedes**
§5.4, §5.7, §9, and the Cargo.toml in §3 where it conflicts; original sections are
preserved for context but the choices below win.

## B.1 Revised performance target

Original §9 target: **250 ms p50, 750 ms p95** for a 3-tab × 4-window OS window.

Revised target after layering the wins in this addendum:

| Workload | Original §9 estimate | Revised estimate |
|---|---|---|
| Typical (12 windows, 2 nvim, 1 tmux) | 250 ms p50 | **~150 ms p50** |
| Heavy (30 windows, 6 nvim, 2 tmux × 4 panes) | 750 ms p95 | **~400 ms p95** |

The single biggest delta is **eliminating subprocess fork/exec** for kitty and tmux,
worth ~450 ms on the heavy workload alone (measured empirically — see B.3).

## B.2 Concurrency topology (revises §5.7)

**Drop the per-tab `for` loop. Flat-fan-out across every window in every tab in every
OS window, gated by `buffer_unordered(12)`.** Per-window captures are fully independent;
the only contention is kitty's remote-control server, which serializes internally at
memory speed.

**Within a window, kick off two legs concurrently** (the registry-dispatched adapter capture and the kitty-window scrollback over the kitty RC socket):

```rust
// Inside capture_window (§5.7), after WindowCtx construction:
let program_fut    = shared.registry.capture(&window_ctx);
let scrollback_fut = capture_kitty_window_scrollback(window, state_dir, shared);
let (program, _)   = tokio::join!(program_fut, scrollback_fut);
```

The three-legged 'nvim + scrollback + tmux' parallelism the v0 plan hinted at is realised one level down: the tmux adapter (§5.4) fans out pane captures via `buffer_unordered(4)`; the nvim adapter (§5.3) pipelines `mksession` against `list_bufs`/`buf_get_lines` on a single msgpack connection. The orchestration layer never directly issues `tokio::join!(nvim, scrollback, tmux)` because the registry dispatches exactly one adapter per window — adapter-internal parallelism is the adapter's contract, not the orchestrator's.

**Concurrency cap: `buffer_unordered(12)`.**
- 12 concurrent nvim mksessions: fine on any modern machine, each runs in its own nvim process. Note: kitty RC calls from the 12 concurrent windows serialize on the single RC socket (§B.3.1). Effective parallelism is per-leg, not across kitty RC. mksession and tmux control mode each have their own per-connection parallelism.
- fd budget: 12 × ~6 fds = 72, well under default ulimit 1024
- Diminishing returns past N=12 because mksession (~200 ms) dominates, so 30 windows = 3 waves ≈ 600 ms

**Inner cap for tmux pane recursion.** Per tmux session, panes recurse with their own
`buffer_unordered(4)`. Worst case: 12 OS-window slots × 4 panes per tmux session = 48
in-flight units. fd budget remains comfortable; the recursive nvim mksessions inside
tmux panes serialize naturally at the per-pane RPC connection.

**DAG (replaces the implicit per-tab tree in §5.7):**

```
   kitty.ls()  ─►  serde_json parse  ─►  resolve_targets
        │
        ▼
   FLAT FAN-OUT (buffer_unordered=12) over every window
        │
   ┌────┴─────────────────────────────────────────────┐
   │ per window (capture_window):                      │
   │   tokio::join!(                                   │
   │     registry.capture(ctx),                        │
   │     capture_kitty_window_scrollback(window),      │
   │   );                                              │
   │   adapter-internal fanout:                        │
   │     - nvim adapter: pipelined RPC on one conn     │
   │     - tmux adapter: buffer_unordered(4) per pane  │
   │   NOTE: scrollback leg's kitty RC calls           │
   │   serialize across all 12 windows on the single   │
   │   Mutex<UnixStream> (§B.3.1).                     │
   └────┬─────────────────────────────────────────────┘
        │
   conf::render ∥ serde_json::to_vec_pretty(manifest)
        │
   fsx::commit_session   (single conf rename — see B.4)
```

**Wasted serializations the original §5.7 had:** tab-at-a-time outer loop, within-window
sequencing of mksession → scrollback → tmux, per-window subprocess fork for
`kitty @ get-text`. All three eliminated.

## B.3 Direct RPC sockets (revises §5.1, §5.4)

The single highest-ROI change in the whole port. The Bash version shells out to
`kitty` and `tmux` for every operation. Each fork/exec is ~5 ms, plus the cold-start
of the kitty binary itself (~30-50 ms measured). For a heavy session this is
~600+ ms of pure process startup.

### B.3.1 Kitty RC protocol — direct socket

**Empirically verified (agent probed `/tmp/kitty-68204` live):**

- Transport: Unix socket, single connection, persistent.
- Frame: `\x1bP@kitty-cmd<json-payload>\x1b\\` (DCS sequence; same on send and receive).
- Request body: `{"cmd": "<name>", "version": [0,42,0], "payload": {...}}`.
- Response body: `{"ok": true, "data": "..."}`.
- **Auth**: with `allow_remote_control socket-only` (the user's config), socket
  permissions on `/tmp/kitty-<pid>` (mode 0700) ARE the auth. Confirmed empirically:
  no `KITTY_RC_PASSWORD`, no `KITTY_PUBLIC_KEY`, no AES-GCM envelope — bare JSON
  works. The encryption machinery only kicks in for TTY-escape transport from
  untrusted children.
- Quirk: `data` for tree results (`ls`) is a **JSON string containing JSON** —
  double-decode. `data` for `get_text` is raw text.
- CLI-flag → JSON-field naming: snake_case. `--all-env-vars` → `"all_env_vars": true`.

**Measured per-call costs** (one save's worth of operations):

| Operation | Subprocess (`kitty @ ...`) | Direct socket |
|---|---|---|
| `ls --all-env-vars` | 50 ms | 15 ms |
| `get-text --match id:X` | 50 ms | 15 ms |

For 6 windows of scrollback capture: **300 ms → 90 ms (savings: 210 ms)**.

**Implementation: ~80 LOC `kitty/rpc.rs`.** Approximate sketch:

> **Serialization note.** The `Mutex<UnixStream>` is held across both the write of the request frame and the read of the response frame because kitty RC has no client-side correlation ID for response demuxing. This means concurrent calls from multiple tasks fully serialize at the socket level. Wall-clock cost: 12 windows × 15 ms per `get_text` ≈ 180 ms (serial). This is still a 3× improvement over the Bash subprocess version (12 × 50 ms ≈ 600 ms) — the savings come from eliminating fork/exec overhead, not from socket-level parallelism. If/when kitty adds a correlation-id mechanism, the demuxer pattern from §B.3.2 (`TmuxControl`) can be ported here for true parallelism.

```rust
pub struct KittyRpc { stream: Mutex<UnixStream> }

impl KittyRpc {
    pub async fn discover() -> Result<Self> {
        // Honor $KITTY_LISTEN_ON, else scan /tmp/kitty-*
    }

    async fn call(&self, cmd: &str, payload: Value) -> Result<Value> {
        let body = json!({ "cmd": cmd, "version": [0,42,0], "payload": payload });
        let mut s = self.stream.lock().await;
        s.write_all(b"\x1bP@kitty-cmd").await?;
        s.write_all(&serde_json::to_vec(&body)?).await?;
        s.write_all(b"\x1b\\").await?;
        // Read until \x1b\\ terminator, strip DCS frame, parse JSON envelope
        let resp: Value = read_dcs_envelope(&mut *s).await?;
        if !resp["ok"].as_bool().unwrap_or(false) {
            return Err(...);
        }
        Ok(resp["data"].clone())
    }

    pub async fn ls(&self, all_env_vars: bool) -> Result<Vec<OsWindow>> {
        let raw = self.call("ls", json!({"all_env_vars": all_env_vars})).await?;
        // Double-decode for tree results:
        Ok(serde_json::from_str(raw.as_str().unwrap())?)
    }

    pub async fn get_text(&self, match_: &str, extent: &str, ansi: bool)
        -> Result<String>
    {
        let raw = self.call("get_text", json!({
            "match": match_, "extent": extent, "ansi": ansi
        })).await?;
        Ok(raw.as_str().unwrap().to_string())
    }

    pub async fn set_user_vars(
        &self,
        window_match: &str,         // e.g. "id:42"
        vars: &[(&str, &str)],      // key=value pairs
    ) -> Result<(), KError> {
        let payload_vars: Vec<String> = vars.iter().map(|(k, v)| format!("{}={}", k, v)).collect();
        self.call("set_user_vars", json!({
            "match": window_match,
            "all": false,
            "payload": payload_vars,
        })).await?;
        Ok(())
    }
}
```

Note that Phase 0.5 (§5.7) calls `set_user_vars` PER-WINDOW because each window gets a distinct UUID. The `Mutex<UnixStream>` serializes the calls — this is documented serialization, not a bug (see the Serialization note above).

**Fallback:** if `discover()` fails or the response has an unknown `version` mismatch
error, degrade to the subprocess path (which §5.1 already plans). Keep
`kitty/cli.rs` as a fallback module behind a `KittyTransport` enum.

**Do NOT pursue:** the AES-GCM encrypted envelope path. Irrelevant for unix-socket
transport with `socket-only`.

### B.3.2 Tmux control mode (`tmux -C`)

Spawn one `tmux -C attach -t <sess>` **per tmux server**, keyed on
`(socket_path, server_pid)` extracted from `/proc/<fg_pid>/environ` — `$TMUX` has the
form `<socket_path>,<server_pid>,<session_id>`. All sessions on the same server share
the one pipe; the `-t <sess>` arg picks the attach target but every subsequent command
can address any session on that server via `-t <other_sess>:…`. Drive all queries
through its stdin/stdout. Protocol (verified live):

```
%begin <ts> <cmd-num> <flags>
<command output>
%end   <ts> <cmd-num> <flags>     (or %error)
```

Each command produces one block; `<cmd-num>` correlates request to response.

Async notifications interleave between command blocks but never inside one
(verified per the Control-Mode wiki). The full set emitted by current tmux is
larger than the three the original draft listed. From `control.c` and
`control-notify.c` in tmux master:

| Notification | Source |
|---|---|
| `%output %<pane> <escaped-bytes>` | live pane output |
| `%extended-output %<pane> <ms-behind> : <escaped-bytes>` | output with timing |
| `%pause %<pane>` / `%continue %<pane>` | flow control |
| `%subscription-changed <name> $<sid> @<wid> <idx> %<pid> : <value>` | format subscriptions |
| `%window-add @<window>` / `%window-close @<window>` | window lifecycle |
| `%unlinked-window-add @<window>` / `%unlinked-window-close @<window>` | unlinked variant |
| `%window-pane-changed @<window> %<pane>` | active pane changed |
| `%window-renamed @<window> <new-name>` / `%unlinked-window-renamed @<window> <new-name>` | rename events |
| `%session-changed $<session> <name>` / `%session-renamed $<session> <name>` | session events |
| `%client-session-changed <client> $<session> <name>` | per-client session reassign |
| `%client-detached <client>` | client detached |
| `%sessions-changed` | session list dirty |
| `%session-window-changed $<session> @<window>` | session's active window |
| `%paste-buffer-changed <name>` / `%paste-buffer-deleted <name>` | paste buffer events |
| `%pane-mode-changed %<pane>` | copy-mode / view-mode toggle |
| `%layout-change` | window layout dirty |
| `%config-error <message>` | bad ~/.tmux.conf line, may arrive immediately on attach |
| `%exit [<reason>]` | client.c, connection-terminating framing token (printed once just before stdin closes — handle as clean-shutdown signal, not a generic notification) |

Note: `%exit` is special — it is the only `%`-prefixed line that signals
connection termination rather than a transient async notification. The
demuxer should match it explicitly and drive the read loop to a clean shutdown
(drain pending `oneshot::Sender`s with `NvimError::ConnectionClosed`-equivalent
errors, then close the channel) rather than DEBUG-logging-and-continuing.

The parser must use a **forward-compatible rule**: any line starting with `%`
that is not one of the framing markers (`%begin`, `%end`, `%error`) is an
async notification — log unknown ones at DEBUG and continue; do NOT error.
Tmux 3.4+ may add new notifications without bumping the protocol version.

Build the parser as a stream tokenizer keyed on the `<cmd-num>` field of
`%begin`/`%end`, not "read N lines after `%begin`". Lines between matching
`%begin <ts> <num> <flags>` and `%end <ts> <num> <flags>` (or `%error`) are
that command's response; everything else outside those bracketed regions is
either a notification (starts with `%`) or, if the line doesn't start with `%`,
the connection is corrupted and the parser should reconnect.

The plan's `tmux_control_mode_protocol.rs` regression test (§8) must fuzz this
parser with all the notifications above interleaved between command blocks.

**Layout-corruption mitigation (required).** A `-C attach` client is a real attached
client. Tmux resizes every window in the session to match the smallest attached
client — default tty size is 80×24. Per
[tmux#2594](https://github.com/tmux/tmux/issues/2594), the reflow **persists after
the control-mode client detaches**. Without mitigation, every save permanently shrinks
the user's session.

**Primary mitigation: attach with `-r`.** On tmux ≥ 3.2, `attach-session -r` is
documented as an alias for `-f read-only,ignore-size`. Set the flag at attach
time — this is race-free, because there is no window between attach and a
follow-up `refresh-client` during which tmux may have already recomputed window
sizes against our 80×24 default. The read-only semantic is also correct: a
query-only control client should not be participating in input dispatch,
clipboard, or any other write path.

Spawn line:

```
tmux -C attach -r -t '$<sid>'           # tmux ≥ 3.2 (preferred)
```

Where `<sid>` is the numeric session id from `$TMUX` field 2, addressed as
`$<sid>` (tmux's by-id target syntax) so name escaping doesn't matter.

**Fallback for tmux < 3.2 (no `-r` ↔ ignore-size alias).** Probe the tmux version once at startup via a one-shot `tmux -V` subprocess (the same subprocess used for the availability probe at §5.4 line ~450 — reuse its output). Parse the major.minor from the `tmux X.Y[suffix]` line. The attach flag is chosen from this version before the control-mode pipe is opened, so the probe MUST NOT use `display-message` (which would require an already-attached control client). If `< 3.2`, the
mitigation depends on whether other clients are attached:

- **Other clients attached** — attach in control mode, then immediately
  force a refresh against the largest existing client so tmux doesn't shrink
  the session to our 80×24:

  ```
  tmux -C attach -t '$<sid>'
  # over the pipe, before any session-mutating query:
  tmux list-clients -F '#{client_width} #{client_height}'  # pick max
  tmux refresh-client -C <max_w>x<max_h>     # tmux >= 2.9
  tmux refresh-client -C <max_w>,<max_h>     # tmux  < 2.9 (comma separator)
  ```

  The `-C` flag's argument format **changed** in tmux 2.9 (`Cw,Ch` → `CwxCh`).
  The version probe at §5.4 step 1 produces a `(major, minor)` tuple already; gate
  the format selection on `(major, minor) < (2, 9)`. Tmux versions in the 2.x
  range fall into the `< 3.2` mitigation branch, so this branch must handle them
  correctly — emitting `WxH` to a 2.6 server produces `bad command syntax: -C`
  and the resize never fires.

- **No other clients attached** — there is no "largest other client" to
  match against. The control-mode client's own 80×24 will become the
  session's persistent size after detach (the bug at issue #2594). Emit
  `tmux refresh-client -C <KSESSION_RESTORE_SIZE>` (see §1.5; default
  `200x60`, format-translated per the version-gating rule above to
  `200,60` on tmux `< 2.9`) before detach to leave the session at a
  reasonable size. This is best-effort: the right size to restore is
  unknowable from inside the save process. Users with 4K terminals or
  unusual layouts can override via `export KSESSION_RESTORE_SIZE=380x100`
  in their kitty `env` directive.

Tmux < 3.2 was released 2020-10; most distros in 2026 ship ≥ 3.3a. This
fallback exists for completeness; the `-r` path covers the user's current
setup.

Cover with regression test `tmux_layout_preserved_on_save.rs` (see §8).

**Measured impact** for a 2-session × 4-pane tmux capture (5 field queries per pane):

| Operation | Subprocess (`tmux <cmd>` per call) | Control mode |
|---|---|---|
| 40 × `display-message -p '#{field}'` | 200 ms | 40 ms |
| 4 × `list-windows`/`list-panes` | 20 ms | 4 ms |
| 8 × `capture-pane` | 40 ms | 8 ms |

**Total: 260 ms → 52 ms (savings: 208 ms)** for that workload.

**Capture-pane content needs `-C` for safe in-band transport.** Verified against tmux
master source:

- Output between `%begin/%end` command-result blocks goes through `control_write()`
  (control.c) and is sent **raw** — no escaping. The plan's previous claim that all
  command output is octal-encoded was wrong.
- Only `%output` / `%extended-output` async notifications go through
  `control_write_output()`, which is where the `\NNN` (bytes <0x20) / `\134` (literal
  backslash) escaping lives. Tmux uses strict 3-digit octal (`xsnprintf` with `"\\%03hho"` in `cmd-capture-pane.c`) for bytes `< 0x20`. **Backslash itself, however, is emitted as the two-character sequence `\\` (two literal backslashes), NOT as `\134`** — verified empirically on tmux 3.4 by round-tripping a pane containing a literal `\` byte. The decoder MUST handle two escape forms:

  - `\NNN` where `NNN` is exactly three octal digits → byte `NNN` (octal)
  - `\\` (two literal backslashes) → single byte `\`

  Treat any other `\<x>` sequence (where `<x>` is neither three octal digits nor a second `\`) as a parser error: `warn!`-log the offending byte sequence and degrade to passing the raw bytes through verbatim. Do not silently consume a single `\` as literal. (An earlier draft of this plan stated tmux uses `\134` for literal backslash — that was wrong on tmux 3.4 and likely on all current versions; the source-code claim about `cmd-capture-pane.c` was over-extrapolated. The `tmux_capture_pane_octal_decode.rs` regression test (§8) must cover the `\\` case explicitly.)

This means a raw `capture-pane -p` of arbitrary scrollback bytes is **theoretically
ambiguous** inside a `%begin/%end` block: if the scrollback contains a literal LF
followed by the exact text `%end <ts> <num> 1`, the parser would mis-frame. In
practice this is vanishingly unlikely but the framing is not collision-proof.

**Solution:** request application-layer escaping with `capture-pane -p -C -e`. The
`-C` flag tells tmux to escape non-printable bytes (`\NNN` octal) and literal
backslash (`\134`) in the captured string itself, before any control-mode framing.
After this, the data inside `%begin/%end` is strictly 7-bit printable with no
embedded LFs or framing-ambiguous sequences. Decode the `\NNN` + `\134` escapes in
Rust to recover the raw bytes. The `-e` flag preserves the ANSI escape sequences
(SGR colors etc.) that scrollback consumers want.

Round-trip bytes 0x00–0xff through `tmux capture-pane -p -C -e` in
`tmux_capture_pane_octal_decode.rs` (see §8). The test is now: write known bytes
into a pane, capture with `-C`, decode in the parser, assert byte-for-byte equality.

**Do NOT** unconditionally octal-decode all command-output blocks — that would
corrupt the output of `display-message`, `list-windows`, etc., which legitimately
contain literal `\` bytes (e.g., escaped layout strings) that are NOT octal-escape
prefixes. Decoding is scoped to the result of `capture-pane -C`; the decoder lives
in the capture-pane response handler, not the general command-block parser.

**Concurrent pipe access.** `TmuxControl` owns a single background read-loop
task that demultiplexes `%begin/%end/%error` blocks by `<cmd-num>` into
per-request `tokio::sync::oneshot::Sender`s held in a
`HashMap<u32, Sender<…>>` (cmd-num is a `u_int` in tmux source —
`cmdq_item.number` — and wraps at `u32::MAX`). Concurrent `request()` callers
serialize on a `Mutex<ChildStdin>` for the write side only — the lock is
held microseconds (one `write_all` of the newline-terminated command) and
released before the response arrives. This makes the pipe safe for the
recursive pane → registry dispatch in §5.5 under §B.2's `buffer_unordered`
fan-out.

**Runtime flavor.** The whole binary uses `tokio::runtime::Builder::new_current_thread()`
(`#[tokio::main(flavor = "current_thread")]` on `bin/ksession.rs`). The
write-mutex / FIFO atomicity invariant below is load-bearing for FIFO
correlation, and it requires that no two tasks ever interleave their
"enqueue + write_all" critical sections. `current_thread` guarantees this by
cooperative scheduling: a task holds the mutex across an `.await` only if it
yields, and `write_all` of a 200-byte command does not yield in practice
(stdin is a pipe, not a socket; `try_write` succeeds without yielding for
sub-PIPE_BUF writes). On a `multi_thread` runtime two tasks could observe the
mutex as available simultaneously on different OS threads, race on the FIFO
push vs. the write_all flush ordering, and scramble responses. Do not change
the runtime flavor without revisiting this section.

**Request atomicity invariant (load-bearing for FIFO correlation).** Tmux assigns command numbers **server-side**, not client-side: `cmd-queue.c::cmdq_next` increments a function-static `u_int number` shared across all clients on the server, and stamps each command's `cmdq_item.number` at parse time. The client never sees the number until tmux echoes it back in `%begin <ts> <num> <flags>`. Therefore the demuxer key is **not** an atomic the client allocates — it's the number parsed off the wire when `%begin` arrives. Correlating "which `request()` future does this `%begin` belong to" requires that the order of `%begin`s arriving back matches the order of writes leaving the client. Tmux's per-client `cmdq` processes commands FIFO (see `control.c::control_read_callback` + `cmd-queue.c`), so as long as the client serializes writes, the `%begin` echoes arrive in write order.

Concretely: hold the stdin mutex across (push pending-sender onto a FIFO queue + `write_all` of the command). The demuxer pops the FIFO head when each `%begin` arrives and binds it to the parsed cmd-num for the duration of that block.

```rust
// pending: Mutex<VecDeque<oneshot::Sender<Result<Vec<String>>>>>
// in_flight: Mutex<HashMap<u32, oneshot::Sender<…>>>  // keyed by server-assigned cmd-num
async fn request(&self, cmd: &str) -> Result<Vec<String>> {
    let (tx, rx) = oneshot::channel();
    {
        let mut stdin = self.stdin.lock().await;       // hold across enqueue+write
        self.pending.lock().await.push_back(tx);
        stdin.write_all(format!("{}\n", cmd).as_bytes()).await?;
    }                                                   // release before awaiting reply
    rx.await?
}

// in the read-loop, on receiving `%begin <ts> <num> <flags>`:
//   let tx = self.pending.lock().await.pop_front().unwrap();
//   self.in_flight.lock().await.insert(num, tx);
// and on `%end <ts> <num> <flags>` (or `%error`):
//   let tx = self.in_flight.lock().await.remove(&num).unwrap();
//   let _ = tx.send(collected_lines);
```

If write order and FIFO pop order diverge (e.g., write happens outside the mutex or two callers race the enqueue), the FIFO-head pop binds the wrong `oneshot::Sender` to the cmd-num and responses get scrambled. The mutex-around-(enqueue + write) is the load-bearing invariant; the in_flight map exists only to bridge the `%begin`-arrival and `%end`-arrival edges within a single command.

**Note on response ordering.** Tmux processes per-client commands FIFO (see
`control.c::control_read_callback` + tmux's per-client cmdq in
`cmd-queue.c` (the cmd-num counter is a process-wide static, but each client's commands process in FIFO order against that counter)), so responses to pipelined commands arrive **in command-number
order**, not out of order. The `HashMap` demuxer is still required — not for
out-of-order responses, but because async notifications (`%window-add`,
`%output`, etc.) interleave between command blocks, and the demuxer cleanly
separates "this is response N to my request" from "this is an unsolicited
notification."

Cancellation: a dropped request future drops its `Receiver`; the demuxer
detects this when it later tries to `send` and discards the response.

**Backpressure caveat (5-minute kill).** Tmux's `CONTROL_MAXIMUM_AGE = 300000ms`
(control.c) — if the read loop stalls for ≥ 5 minutes while tmux has buffered
output for our client, tmux kills the connection. The read loop must therefore
never block. Per-command responses use `oneshot` (no buffering question — the
sender writes once and the receiver awaits). Async notifications (`%output`,
`%window-add`, etc.) are **discarded** in the save flow: the read loop matches
`%begin`/`%end`/`%error` for command correlation and silently drops every other
`%`-prefixed line (DEBUG-log unknown ones). No notification channel is allocated.
If a future feature subscribes to `%output`, route it through a bounded
`tokio::sync::mpsc::channel(64)` with a drop-oldest policy on overflow — never
unbounded, to keep the read loop's memory footprint deterministic under a
slow consumer.

**Do NOT pursue:** connecting directly to tmux's unix socket (`/tmp/tmux-1000/default`).
Tmux's internal `msg_t` protocol is unstable across versions, undocumented, and
control mode IS the stable public interface to that socket.

**Implementation: ~150 LOC `tmux_rpc/control.rs`.** Holds a `&TmuxControl` in `WindowCtx`
so recursive pane→registry dispatch reuses the same pipe.

### B.3.3 Risks (additions to §11)

| Risk | Mitigation |
|---|---|
| kitty RC protocol version mismatch | Send `"version": [0,42,0]`; kitty returns clean error on mismatch; fall back to subprocess. |
| `data` double-encoded JSON gotcha | Encapsulate in `KittyRpc::call()`; never let callers see the raw envelope. |
| tmux `-C` async notifications mid-stream | Parser must be tokenizer keyed on cmd-num, NEVER line-count. |
| Capture-pane content containing literal `%end` line | Request application-layer escaping with `capture-pane -p -C -e`; the resulting `\NNN` (3-digit octal for bytes < 0x20) and `\\` (two-char escape for literal backslash — verified on tmux 3.4) sequences are decoded **only** in the capture-pane response handler, not in the general command-block parser (per §B.3.2). Literal `%end` bytes inside captured content become `\045end` after escape, so the framing parser never sees ambiguous markers. Other command output (`display-message`, `list-windows`) is passed through verbatim — applying octal-decode globally would corrupt layout strings containing literal backslashes. |
| `-C attach` mutates session layout via smallest-client resize | Use `attach-session -r` (alias for `read-only,ignore-size`) as the primary mitigation on tmux ≥ 3.2; fallback to `refresh-client -C <w>x<h>` matching largest existing client on tmux < 3.2. See §B.3.2 "Layout-corruption mitigation". |
| Long-lived `tmux -C` child needs the right server's env | Read `$TMUX` (and `$TMUX_TMPDIR` if set) from `/proc/<fg_pid>/environ` and pass via `Command::env`; never inherit `ksession-rs`'s own tmux env, which may point at a different server or no server at all. |

## B.4 Filesystem & I/O (revises §5.7)

Single biggest non-RPC win is the **atomic-write strategy**.

### Replace per-sidecar `NamedTempFile::persist` with tempdir-then-rename

Current §5.7 writes ~30 sidecar files using `NamedTempFile::persist` per file:
- 30 × (create + write + fsync ~5 ms + rename) ≈ **~150 ms of fsync alone** on ext4.

Revised (generation-stamped state dirs — conf rename is the sole commit point):

```
1. ts_us = current unix microseconds (or atomic counter if reentrant)
2. mkdir <sessions>/<name>.gen-<ts_us>.state/         (tempdir-named-final from the start)
3. Write all sidecars + manifest.json into it          (no per-file fsync)
4. fsync the state dir                                 (single fsync, all data)
5. Render conf body with absolute paths referencing <name>.gen-<ts_us>.state/
6. Write <name>.conf.tmp.<pid> + fsync                 (entrypoint, must be durable)
7. rename(<name>.conf.tmp.<pid> → <name>.conf)        (commit point — single rename)
8. fsync parent sessions/ directory                    (commits the rename)
```

### Generation stamp collision policy

`gen_us = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_micros() as u64`. The Phase 0 state-dir mkdir uses `std::fs::create_dir` (which maps to `mkdir(2)` with `EEXIST` surfaced as `ErrorKind::AlreadyExists`). On `AlreadyExists`:

1. Retry with path `<sessions>/<name>.gen-<gen_us>_<pid>.state/` — disambiguates concurrent saves from different PIDs that land in the same microsecond.
2. On a second `AlreadyExists` (same µs AND same PID — only possible from intra-process reentrant `session::save` calls), increment `gen_us` by 1 µs and retry steps (1)–(2) up to 8 total attempts.
3. After 8 failed attempts, return `KError::GenCollision { attempts: 8 }`. Effectively unreachable under normal use.

Sweep (below) recognises both `gen-<digits>.state` and `gen-<digits>_<digits>.state` patterns. The gen-extraction regex is `gen-(?P<ts>\d+)(?:_(?P<pid>\d+))?\.state` — capture both groups; treat them as opaque identifiers when matching state-dir → conf references.

Total fsyncs: **3** (state dir, conf, parent). Crash anywhere before step 7 leaves the new gen-stamped state dir orphaned (collected by sweep on next save). Crash after step 7 means the save committed. The previous re-save problem (conf↔state two-rename coupling) is GONE: each conf references its own gen-stamped state dir, so the old `<name>.conf` (if any) still references the old gen-stamped state dir, which remains on disk and readable until sweep collects it. **Saves ~125 ms** vs per-file fsync.

**Re-save case:** writing a new save over an existing `<name>` simply produces a new `.gen-<new_ts_us>.state/` dir alongside the old one, then atomically replaces `<name>.conf`. The old state dir is detectable as orphan (no conf references it) and collected by sweep. NO inline `rm -rf` of the old state — that was the Bash bug (`ksession.sh:630`).

### `fsx::commit_session` signature

```rust
/// Atomic-publish a save.
/// `state_tmpdir` is the populated final-named gen-stamped dir (already moved into place at step 2).
/// `conf_body` is the rendered .conf contents from §5.6 (referencing absolute paths into state_tmpdir).
/// Returns Ok(()) on commit; on error, the caller's StateTmpdir Drop guard cleans up the orphaned dir.
pub fn commit_session(
    state_tmpdir: StateTmpdir,
    conf_body: &str,
    sessions_dir: &Path,
    name: &str,
) -> Result<(), KError>;
```

Implementation outline: (1) fsync `state_tmpdir.path()`; (2) write `<sessions_dir>/<name>.conf.tmp.<pid>` and fsync it; (3) rename `conf.tmp.<pid>` → `<sessions_dir>/<name>.conf` — this is the SOLE commit point; (4) `state_tmpdir.commit()` — internally `std::mem::forget`s the inner `StateTmpdir` so its Drop guard does NOT remove the gen-stamped state dir; (5) fsync `sessions_dir`. The `commit()` call MUST fire AFTER the rename (step 3) and BEFORE the parent fsync (step 5): if step 3 fails the dir should be cleaned up (Drop runs); if step 5 fails the dir must NOT be cleaned up because the on-disk conf already references it. The function consumes `state_tmpdir: StateTmpdir` by value so its Drop is in scope for steps 1–3 and disarmed from step 4 onward.

### Orphan sweep

At the START of every save (before Phase 0), the orchestrator scans `<sessions>/`
for `*.gen-*.state` directories not referenced by any `*.conf`:

1. Enumerate all `*.conf` files in `<sessions_dir>/`. For each conf, scan every line for absolute paths matching `gen-<digits>(?:_<digits>)?\.state/` and collect the matched gen identifiers into a referenced-set. The scan is line-oriented and tolerant: if a conf has no recognisable gen-stamped path (e.g., user hand-edited it to point at a relocated state dir, or it was authored by an external tool), the conf's `<name>` is added to a 'protected-bare-name' set — every `<name>.gen-*.state/` is treated as referenced for sweep purposes, on the basis that we cannot prove they are unreferenced.
2. Enumerate all `*.gen-*.state/` directories.
3. Any state dir not in the referenced set, AND older than `SWEEP_MIN_AGE` (default 60s — guards against in-flight concurrent saves), is `rm -rf`'d.
4. Failures (EACCES, ENOENT) are logged at `debug!` and skipped — sweep is best-effort.

Bounds: sweep walks O(N) conf files + O(M) state dirs where M ≤ 2N in steady state (one orphan per re-save at most until next sweep). Negligible cost (~5 ms for typical N=20).

**Hand-edited conf safety.** Sweep never deletes a state dir referenced by even one conf containing a path that resolves to it on disk. The protected-bare-name fallback above is the second line of defence: if a conf body has been edited so heavily that no `gen-*.state/` pattern remains anywhere, sweep declines to touch any state dir whose basename starts with the conf's `<name>`. The user can manually clean up state dirs if they intentionally reorganised storage.

### Same-filesystem invariant

All atomic-publish renames (state-dir name, `conf.tmp` → `conf`) MUST happen within
a single filesystem. The plan asserts that `<sessions_dir>` and all tempdirs/
`.tmp` files live in the same directory (`<sessions_dir>/` itself). Cross-fs
renames return `EXDEV` and would silently break atomicity.

`commit_session` returns `Err(KError::CrossFilesystem { src, dst })` on `EXDEV` from any rename in the publish sequence, where `src` and `dst` are the offending paths. The error message reads: '`<sessions_dir>` and the temporary state directory must live on the same filesystem; check that `$KSESSION_DIR` is not on a tmpfs while `<sessions_dir>` is on ext4 (or vice versa).' `cli/save` surfaces this as a non-zero exit with the message on stderr. Treating EXDEV as a recoverable error (rather than a panic) keeps the binary friendly to environments where the sessions dir is bind-mounted across filesystems — the user gets a clean diagnostic and can re-point `KITTY_PROJECT_SESSIONS_DIR` rather than seeing a stack trace. The `KError::CrossFilesystem { src: PathBuf, dst: PathBuf }` variant is defined in §5.8.

Future: if cross-fs operation is ever needed, replace `rename(2)` with a
copy-then-fsync-then-unlink dance — but this is out of scope for v1.

### Memoize `/proc` reads within one save

Each adapter calls `proc_env(pid, KEY)` independently. For 4 shell windows × 4 env
vars each (`VIRTUAL_ENV`, `CONDA_DEFAULT_ENV`, `OLDPWD`, `DIRENV_DIR`) = 16 reads of
`/proc/PID/environ`. Cache it:

```rust
pub struct ProcCache {
    environ: HashMap<u32, HashMap<String, String>>,  // parse once
    cmdline: HashMap<u32, Vec<String>>,              // immutable after exec
    exe:     HashMap<u32, Option<String>>,           // readlink /proc/<pid>/exe, basename only; None = unreadable
    // task/*/children NOT cached — can change during save
}
```

`exe(pid: u32) -> Option<String>` returns the basename of the symlink target at `/proc/<pid>/exe`, memoised per save. `None` means the readlink failed (process exited, permission denied) — callers treat this the same as "unknown program" and fall back to `kitty_window.foreground_processes[i].cmdline[0]` or degrade to `Program::BareShell`. Reading `/proc/<pid>/exe` unconditionally (rather than trusting kitty's reported cmdline) matches Bash `ksession.sh:530–533` and avoids the wrapper-exec mismatch class of bug (e.g., `python` → `python3.12`).

**Saves ~5-10 ms** (now ~20 `/proc` reads coalesced — 4 shells × 5 reads each — across the save) and cleans up the code (no `proc_root: &Path` plumbing through every adapter).

### Use `std::fs`, not `tokio::fs`

`tokio::fs::write` dispatches to a `spawn_blocking` thread pool — ~70 µs overhead
per write for ops that take ~10 µs. **Drop the `"fs"` feature from tokio in §3.**
All I/O in the save phase is `std::fs::write`. Saves ~2 ms across 30 writes;
removes the blocking-pool dependency for trivial work.

### Skip these (verdict: don't bother)

| Item | Why not |
|---|---|
| `io_uring` (tokio-uring / rio) | ~150 µs saving against a 250 ms budget. Splits I/O strategy across two runtimes. |
| Skip-write-if-identical hashing | Requires reading existing file → cancels write savings. mksession output and scrollback always differ. |
| Buffer streaming under 8 MiB | Real-world buffers <1 MiB; chunking just spreads same total bytes across more msgpack frames. |
| Scrollback gzip | Total scrollback ~240 KB/save; 10 ms saved at save = 10 ms paid at restore. Net zero. |
| tmpfs detection | User's sessions dir is ext4 noatime. 50 LOC for 15 ms on unusual setups. |

## B.5 Build & startup (revises §3 deps)

Append these to `[profile.release]` in `Cargo.toml`:

```toml
[profile.release]
lto = "fat"               # 10-20% size + 5-15% steady-state speed
codegen-units = 1         # +1-5% on top of LTO
panic = "abort"           # 5-10% size, no unwind tables in hot paths
strip = "debuginfo"       # keeps symbols for backtraces, drops debug info
debug = 1                 # line tables only — `RUST_BACKTRACE=1` still works
```

**Dependencies — revisions to §3:**

```toml
# REMOVE the "fs" feature (B.4); ADD "sync" for tmux control-mode demuxer (§B.3.2):
tokio = { version = "1", features = ["net", "io-util", "rt", "macros", "time", "process", "sync"] }

# REPLACE `regex` with `regex-lite`:
regex-lite = "0.1"        # ASCII-only kq regex, no need for full PCRE
                          # ~150 KB binary size + 10× compile time saved
```

**Pre-spawn `kitty @ ls`** in `main()` before parsing args / tracing init:

```rust
fn main() -> Result<()> {
    // Issue this FIRST so its ~15ms socket round-trip overlaps with our setup
    let kitty_ls_fut = KittyRpc::discover_and_ls();

    let args = Cli::parse();              // ~2 ms
    log::init(&args.log_level)?;          // ~1 ms
    let runtime = build_runtime()?;       // ~500 µs

    runtime.block_on(async move {
        let ls = kitty_ls_fut.await?;
        ...
    })
}
```

This is the single biggest realistic startup win — **~10 ms saved**.

### Skip these (verdict: don't bother)

| Item | Why not |
|---|---|
| PGO | Realistic gain on 10 ms cold start: 2-5%. Maintenance cost >> payoff. |
| musl target | Personal tool; portability non-goal. musl's malloc is 10-40% slower for malloc-heavy work. |
| jemalloc | Init cost may exceed runtime savings on short-lived process. |
| mimalloc | Maybe — only if `samply` shows malloc in top 3 hotspots. Default: skip. |
| simd-json | ~200 µs saved on a 250 ms budget. Complicates the hybrid deserialization. |
| Lazy Tokio runtime init | ~500 µs saved; every entry point becomes conditional. Not worth complexity. |
| `bytes::Bytes` for /proc | Built for refcounted sharing across tasks; we have neither. Use `Vec<u8>` reused. |

## B.6 Measurement methodology

Layered benchmarking, smallest tool that surfaces each kind of issue:

| Tool | Use case |
|---|---|
| `hyperfine --warmup 3 --runs 50 'ksession-rs save bench'` | End-to-end wall time. THE number that matters. |
| `samply record ./target/release/ksession-rs save bench` | Flamegraph in Firefox profiler. Tells you whether mimalloc / simd-json are worth investigating. |
| `cargo bench` with `criterion` | Pure-CPU unit benches only: kq, JSON parse, /proc parse. Never bench anything touching real subprocesses. |
| `strace -c -f ksession-rs save bench` | Once, to sanity-check syscall counts. If 500 `openat()`s show up, you have a problem no profiler will name as clearly. |

**Methodology**: establish Bash baseline with `hyperfine`. Port to Rust with default
settings. Measure. Apply the "worth the line" items (B.4 std::fs, B.5 LTO+strip+panic+
regex-lite+pre-spawn). Re-measure. Only chase items in the "skip" lists if `samply`
shows them in the top 3 hotspots.

## B.7 Revised implementation order

Insert two phases into §10:

```
6.   nvim_rpc + adapter::nvim                                  (~2 days)
6.5* kitty/rpc.rs — direct DCS socket client                   (~1 day) [B.3.1]
7.   tmux_rpc + adapter::tmux (control mode from day one)      (~3.5 days) [§5.4, B.3.2]
     — all behaviors per §5.4 (control-pipe queries, restore.sh codegen, recursive
       pane→registry dispatch, layout-corruption mitigation, base-index drift handling,
       etc.). §5.4 is the canonical scope.
8.   session::save orchestration with flat fan-out             (~1 day)  [B.2]
9.   cli + clap subcommands                                    (~0.5 day)
10.  Diff runner + regression suite                            (~1 day)
11.  Patch ksession-save-prompt.sh                             (~0.5 day)
```

Total: **~13 dev days** (was ~10). The extra days buy ~450 ms of per-save latency
and the §B.3.2 layout-corruption mitigation — pays back the first day of "ksession
felt slow" pre-flip-to-Rust user feedback, and unambiguously beats Bash on day one
of Phase 2 opt-in.

**Phase ordering rationale:** ship the kitty RC client (6.5) before phase 3 of the
migration in §7 — it makes the Rust port unambiguously faster than Bash and removes
"subprocess overhead" as a confounding variable in shadow-mode diff testing. Step 7
ships control-mode tmux directly (no subprocess-baseline stepping stone) because
the layout-corruption mitigation in §B.3.2 is mandatory for any control-mode usage
and there's no sensible halfway state.

## B.8 TL;DR table

| Change | Wall-clock saving | LOC cost | Verdict |
|---|---|---|---|
| Direct kitty RC socket (B.3.1) | **~210 ms** (typical) | ~80 | **DO** |
| Flat fan-out + within-window pipelining (B.2) | **~150 ms** | refactor §5.7 | **DO** |
| Tempdir-then-rename atomic writes (B.4) | **~125 ms** | refactor `fsx/` | **DO** |
| tmux `-C` control mode (B.3.2) | **~210 ms** when tmux present | ~150 | **DO** |
| LTO + codegen-units=1 + panic=abort + strip (B.5) | ~5-10 ms cold start | 4 lines | **DO** |
| Pre-spawn `kitty @ ls` in `main()` (B.5) | ~10 ms | ~5 lines | **DO** |
| `regex-lite` instead of `regex` (B.5) | startup + 150 KB binary | 1 line | **DO** |
| `std::fs` not `tokio::fs` (B.4) | ~2 ms | drop feature flag | **DO** |
| `ProcCache` memoization (B.4) | ~5-10 ms | ~30 LOC | **DO** |
| Batched mkdir upfront (B.4) | ~1 ms | trivial | **DO** (clarity) |
| mimalloc | ~0.5-1.5 ms | 2 lines | **MAYBE** (only if samply shows) |
| io_uring | 0 (negative) | ~200 | **SKIP** |
| simd-json | ~200 µs | ~20 | **SKIP** |
| PGO | ~200-500 µs | harness setup | **SKIP** |
| musl static binary | negative (slower) | target config | **SKIP** |
| jemalloc | likely negative | 2 lines | **SKIP** |
| Buffer streaming <8 MiB | 0 | ~50 LOC | **SKIP** |
| Skip-write-if-identical hash | 0 | ~30 LOC | **SKIP** |
| Scrollback gzip | 0 net | ~20 LOC + restore-side | **SKIP** |
| tmpfs detection | 0 (user on ext4) | ~50 LOC | **SKIP** |
| Lazy Tokio init | ~500 µs | invasive | **SKIP** |
| `bytes::Bytes` for /proc | ~0 | dep + ~20 LOC | **SKIP** |

**Net wall-clock improvement combining all DO items: ~510-580 ms saved per save
on a heavy workload, against the original §9 estimate.**

---

# Appendix C — kitty docs deep-dive findings

Three parallel research passes against https://sw.kovidgoyal.net/kitty/ surfaced
findings that are either NEW (not in Appendix B) or REINFORCE earlier choices with
empirical evidence from the user's live kitty. This appendix is additive to
Appendix B; nothing here invalidates B's choices.

## C.1 The save_as_session / ls --output-format=session finding

**Two independent agents (RC surface scan + shell-integration scan) converged on
this. Highest-leverage finding in this round.**

`kitty @ ls --output-format=session` (or equivalently `kitten @ action save_as_session
--save-only <path>`) produces a complete kitty session file as output. Sample output
verified against the user's live `/tmp/kitty-4726`:

```
new_tab
layout splits
enabled_layouts splits,stack
set_layout_state {"pairs": {"horizontal": false, "one": 1}, "opts": {...},
                  "class": "Splits", "all_windows": {"active_group_idx": 0,
                  "active_group_history": [5,8,1],
                  "window_groups": [{"id": 1, "window_ids": [1]}]}}
cd /home/andrew/.config/kitty
launch 'kitty-unserialize-data={"id": 1}' --var=ksession_probe=hello
focus
```

Key observations:

- `set_layout_state` is documented as "for internal use only" but is a JSON blob
  encoding the **exact splits tree geometry** — pair axes, group history, window
  → group mapping. It round-trips cleanly through `kitty --session`.
- The current plan (and Bash version) reconstruct splits via `--location=vsplit`/`hsplit`
  hints, which lose exact ratios. `set_layout_state` preserves them pixel-correctly.
- `launch` lines use a `kitty-unserialize-data={"id": N}` token that's an
  intra-process reattach mechanism — does NOT survive across kitty restarts. We
  still need to rewrite those lines with real argv from our adapters.
- Options: `--use-foreground-process` (captures the actual running program rather
  than the shell), `--relocatable` (relative paths), `--match`, `--base-dir`.

### Implementation plan

**Replace the from-scratch conf renderer (§5.6) with a "skeleton + patch" pipeline:**

```rust
pub fn render(skeleton: &str, session: &SessionFile, gen_us: u64) -> String;
```

`gen_us` is the Phase-0-computed timestamp used to build absolute sidecar
paths into `<sessions>/<name>.gen-<gen_us>.state/`; the patcher does not
invent it.

1. Run `kitten @ action save_as_session --save-only --use-foreground-process <tmp>`
   at the start of save. Cost: one RC call (~15 ms over the direct socket from B.3.1).
2. Parse the resulting conf line-by-line. It's stable, line-oriented syntax.
3. For each `launch` line whose argv references nvim / less / tmux / a shell, patch
   the argv to invoke our restored sidecars. The patched line MUST carry, in order:
   (a) `--hold` for every non-shell program (nvim, less, tmux, raw — see §C.4 for rationale; bare shells omit `--hold` so a user-initiated `exit` closes the window);
   (b) `--cwd <window_cwd>` where `<window_cwd>` is the captured `model::Window.cwd` (omitted when cwd is `None`);
   (c) `--var ksession_id=<uuid>` preserving the UUID assigned in §5.7 Phase 0.5 / §C.3;
   (d) `--var ksession_win=<kitty_window_id>` (log-grep aid; `0` for synthetic empty-tab windows per the injection rules below);
   (e) the program argv itself — one of: `nvim -S <vim>`, `less +<pct>% -- <file>`, `/bin/bash <restore_sh>`, or `bash -c 'source <venv>/bin/activate; export OLDPWD=<oldpwd>; exec bash'`.
   The `/bin/bash <restore_sh>` form for tmux windows DOES receive `--hold` (the wrapper bash is a one-shot exec'ing into `tmux attach-session`, so its exit indicates tmux failure — §C.4 last paragraph).
4. Preserve `new_os_window`, `new_tab`, `layout`, `enabled_layouts`, `set_layout_state`, `focus`,
   `focus_tab`, `cd`, and `--var` lines verbatim. Multi-OS-window sessions rely on `new_os_window` being preserved verbatim; the patcher only rewrites tagged `launch` lines and the `os_window_title`/`tab_title` lines, never the structural tokens.

**Patcher→Program correlation.** The patcher needs to map a kitty-emitted `launch`
line back to the `SessionFile::Window` it captured (to fetch `restore_sh`,
`session_vim`, etc.). Mechanism: before invoking `save_as_session`, the save
orchestrator tags each live kitty window with a fresh UUID via
`set-user-vars ksession_id=<uuid>` (per §C.3). Kitty's emitted `launch` line
preserves the `--var=ksession_id=<uuid>` token. The patcher reads the UUID off the
launch line, looks up the `Window` in the in-memory `SessionFile` by UUID, and
substitutes argv based on `Window.program`. On every patched launch line the patcher emits BOTH `--var ksession_id=<uuid>` AND `--var ksession_win=<kitty_window_id>`: `ksession_id` is the correlation key used for focus restoration and patcher lookup, while `ksession_win` is a debug aid that preserves the original kitty window id across the save→restore round-trip (useful when grepping logs or correlating crash reports). If a `launch` line in the skeleton lacks a `ksession_id` user-var (the window was created between the tag-burst and `save_as_session`, or `set-user-vars` failed for it), the patcher emits the line verbatim from the skeleton. No silent crash, no degrade to bare launch.

**Per-tab `focus_matching_window` emission (F#21).** After walking each
tab's `launch` lines, the patcher emits

```
focus_matching_window var:ksession_id=<active_uuid>
```

when the tab's active window is NOT its first window. The active window is
identified from the in-memory `SessionFile`: consult `model::Tab.active_window_idx`
(sourced from the corresponding kitty `@ ls` JSON `is_active` flag during Phase 1
assembly, then re-indexed into the post-Phase-0.75-filter `tab.windows` Vec). Use
`tab.windows[tab.active_window_idx].ksession_id` as `<active_uuid>` — the same UUID
embedded in that window's patched `launch` line's `--var ksession_id=<uuid>` token,
so kitty's `focus_matching_window` selector finds exactly one match. If the active
window IS the first one in the tab, the line is omitted (kitty already
focuses the first launch by default). Bash analog: `ksession.sh:733–737`.
This emission lives in the patcher's per-tab block walk; the renderer
contract in §5.6 makes the same guarantee visible to callers.

**`new_os_window` separator (F#23).** §5.7 Phase 0 "Skeleton fanout (multi-OS-window)" owns the fanout logic; this subsection specifies what the patcher expects to receive. When the `SessionFile` contains more
than one `OsWindow`, the patcher emits a literal `new_os_window` line
between consecutive OS-window blocks of the rendered conf. Important
constraint: `kitten @ action save_as_session --save-only` emits a skeleton
for ONE OS-window at a time per invocation. To handle multi-OS-window
saves we adopt option (a): the orchestrator (§5.7 Phase 0) issues one
`save_as_session --match id:<os_window_id>` call per OS-window and
concatenates the skeletons with `new_os_window` between them. Option (b)
— "patcher hand-crafts subsequent OS-window blocks from the model" — was
rejected because it duplicates kitty's layout-emission code in Rust and
loses fidelity for `set_layout_state` and friends. The patcher therefore
expects its input skeleton to already contain `new_os_window` separators
where appropriate; its only job is to preserve them verbatim alongside
the other structural tokens listed in step 4.

**Synthetic empty-tab `Window` injection (F#4).** The orchestrator emits
synthetic `model::Window { kitty_id: 0, ksession_id: <fresh>, program: BareShell, … }`
entries for tabs that exist but have no real kitty windows. The skeleton
from `save_as_session` does NOT contain `launch` lines for these synthetic
windows — they correspond to no live kitty state. The patcher MUST inject
a fresh `launch /bin/bash` line for each one into the appropriate tab.

Detection and injection rules (pinned):

- **Detect synthetic windows by `model::Window.kitty_id == 0`.** This is
  the authoritative signal — the orchestrator sets `kitty_id = 0` when
  constructing synthetic windows for empty tabs (real windows always have
  non-zero kitty ids). The alternative rule "any `model::Window` whose
  `ksession_id` does not match any skeleton `launch` line's `ksession_id`
  user-var" is equivalent in well-formed inputs but brittle: a
  race-window creation between the §C.3 tag-burst and the skeleton fetch
  also produces a no-match, but those windows are real and should fall
  through to the verbatim-emit path described in the "Patcher→Program
  correlation" paragraph above. Use `kitty_id == 0`.
- **Inject at the end of the tab's launch-line block.** Walking the
  skeleton tab-by-tab, after emitting all real `launch` lines for the
  tab and before the tab's `focus_matching_window` line (if any), emit:
  `launch --var ksession_id=<synthetic_uuid> --var ksession_win=0 /bin/bash`.
  `ksession_win=0` reflects the synthetic origin (load-bearing only for
  log-grepping); `ksession_id=<synthetic_uuid>` is what the per-tab
  `focus_matching_window` line targets if the synthetic window happens
  to be the tab's active one.

**`/bin/bash`, not `bash`.** Match §5.4's tmux restore.sh invocation. The
explicit `/bin/bash` path survives `PATH` weirdness and noexec mounts on the
state directory.

**Code impact:**

- `conf::render` (§5.6) goes from "construct the whole .conf from a `SessionFile`
  AST" to "parse + patch launch lines." Estimated **~150 LOC deleted, ~80 added**.
- `SplitHint` enum (model/) becomes dead code — split geometry rides entirely on
  `set_layout_state`. Delete.
- `kq()` (the bash-style quoter) stays — needed for patching launch arg argv.

**Correctness wins** (not just performance):

- Exact split ratios restored, not approximate alternating vsplit/hsplit.
- Active-window-history (`active_group_history`) preserved → focus restoration is
  exact even for >2-window splits.
- `enabled_layouts` per-tab preserved (current plan doesn't capture this).

**Risks:**

- `set_layout_state` schema is documented as unstable. Mitigation: treat the blob
  as opaque string, never inspect or transform it. If kitty changes the schema
  between releases, our pass-through still works.
- The intra-process `kitty-unserialize-data` token in `launch` lines must be
  rewritten — failure to rewrite means restore tries to reattach to dead window
  IDs. Add a regression test: parse → patch → assert no `kitty-unserialize-data`
  remains.

**Verdict: ADOPT.** Highest-leverage change in Appendix C. Net perf-neutral
(~15 ms RC vs. ~5 ms in-process render) but a meaningful correctness win for
splits-heavy users and a ~50% complexity reduction in `conf/`.

## C.2 OSC 1337 push from shell + nvim — eliminate /proc reads

Kitty consumes `OSC 1337 ; SetUserVar = <key> = <base64(value)> ST` to populate
`window.user_vars`, which is then visible in `kitty @ ls` output. This means the
shell or nvim can **proactively advertise** state that our adapters currently
scrape from `/proc/PID/environ`.

(Plan correction: the Bash version's earlier research referenced "OSC 99" for user
vars — that's wrong. OSC 99 is desktop notifications. User vars are OSC 1337.)

### Shell hook (~30 lines in user dotfiles)

Ship `~/.config/kitty/scripts/ksession-shell-hook.sh` for the user to source:

```bash
_ksession_push() {
  local _ks() { printf '\e]1337;SetUserVar=%s=%s\a' "$1" \
                "$(printf %s "$2" | base64 -w0 2>/dev/null)"; }
  _ks ksession_venv   "${VIRTUAL_ENV-}"
  _ks ksession_conda  "${CONDA_DEFAULT_ENV-}"
  _ks ksession_oldpwd "${OLDPWD-}"
  _ks ksession_direnv "${DIRENV_DIR-}"
}
PROMPT_COMMAND="_ksession_push${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
```

Equivalent zsh: use `precmd_functions+=(_ksession_push)`.

### Nvim socket via VimEnter

For nvim, the 4-tier socket discovery dance becomes a one-liner. Add to user's
`init.lua`:

```lua
vim.api.nvim_create_autocmd('VimEnter', { callback = function()
  local s = vim.v.servername
  if s == '' then return end
  io.write(('\27]1337;SetUserVar=ksession_nvim_sock=%s\a'):format(
    vim.fn.system({'base64','-w0'}, s)))
end })
```

After this fires, `ls`'s window has `user_vars.ksession_nvim_sock = "/run/user/.../nvim.PID.0"`.
**Skips tiers 2-4 of `socket_for_pid`** (the descendants scan, the wildcard glob,
the last-resort pid-tree match).

### Rust-side change

`adapter::shell::capture` and `nvim_rpc::socket_for_pid` get an opt-in fast path:

```rust
// adapter/shell.rs
fn capture(&self, ctx: &WindowCtx) -> Result<Program> {
    let vars = &ctx.kitty_window.user_vars;
    let venv = vars.get("ksession_venv").and_then(decode_base64);
    let conda = vars.get("ksession_conda").and_then(decode_base64);
    // Fall back to /proc if user hasn't sourced the hook:
    let venv = venv.or_else(|| proc::env_var(ctx.proc_root, ctx.fg_pid, "VIRTUAL_ENV"));
    // ...
}
```

Strictly additive — when the user hasn't sourced the hook, behavior is unchanged.

### Tradeoffs

- **Wall-clock saved per save:** ~5-15 ms per shell window (no `/proc/PID/environ`
  open + parse) + ~20-50 ms per nvim window (no `XDG_RUNTIME_DIR` scan).
- **Code complexity:** ~20 lines added to `adapter::shell`, ~10 to
  `nvim_rpc::socket_for_pid`. `ProcCache` (B.4) can shrink because env-var
  lookups are the most common /proc read.
- **User-facing footprint:** ~30 lines in `.bashrc`/`init.lua`. Opt-in via
  documentation; doesn't break anything when absent.
- **Coverage:** new windows opened AFTER sourcing the hook get user_vars. Existing
  windows have none — fall back to /proc handles this transparently.

**Verdict: ADOPT (additive).** Highest user-facing-effort-to-perf-gain ratio in
this round. Ship the hook scripts under `~/.config/kitty/scripts/` with the Rust
binary; document in README.

## C.3 Window tagging via set-user-vars on restore

Currently the plan emits `--var ksession_idx=$idx` on every launch and uses
`focus_matching_window var:ksession_idx=$active_idx` to restore focus. This works
but the `idx` value is fragile (it's a position counter; if the user reorders
windows manually before saving, the index assignment is brittle).

**Cleaner alternative:** tag each captured window with a UUID via `set-user-vars`,
emit the UUID into the launch line, and match on UUID at restore time.

Tagging is N pipelined `set_user_vars` calls over the §B.3.1 socket — one per surviving window. "Batched" here means pipelined over one socket, not a single multi-window RPC. The burst sets `--var ksession_id=<uuid>` on every target kitty window. **`no_response: true` MUST NOT be used here** — superseded by §5.7 Phase 0.5 (F#2): the orchestrator needs the per-window acknowledgement so it can drop tags that failed (e.g., window died between probe and tag) from the in-memory target set before Phase 1 capture. The §C.6 `no_response` optimization applies to *other* RPC bursts, not this one. UUIDs are `Uuid::new_v4().hyphenated()` (36-char canonical form). Per-window iteration in any example code is illustrative only — the actual implementation issues one batched RPC.

The UUID type is `uuid::Uuid` end-to-end; serialized as the 36-char hyphenated form when stored in the on-disk `manifest.json` and in the `--var ksession_id=…` token.

```rust
// On save, for each window:
let uid = Uuid::new_v4().to_string();
kitty.set_user_vars(window.id, &[("ksession_id", &uid)]).await?;
// emit: launch ... --var ksession_id=<uid> ...
// emit: focus_matching_window var:ksession_id=<active_uid>
```

**Wall-clock saved:** zero. Pure correctness/robustness.
**Code impact:** ~10 LOC.
**Verdict: ADOPT** as part of B.2 implementation.

## C.4 `--hold` flag for failed-program restore

When a captured program's restore command fails (nvim sidecar file moved, tmux
session can't be reattached, less can't read the original file), the kitty window
closes immediately and the user sees a missing window with no diagnostic. Adding
`--hold` to launch lines for nvim/less/tmux/raw makes the window stay open
showing the program's stderr after it exits.

```
launch --hold --cwd /path nvim -S /path/win-12.vim
```

**Wall-clock impact:** zero.
**UX impact:** when restore partially fails, the user can see WHY in the kept-open
window instead of staring at a missing pane.
**Code impact:** one line in each launch-line emitter.
**Verdict: ADOPT.** Trivial, strict UX improvement. Apply to all non-shell launches
(don't `--hold` for bare shells — shell exit is intentional via `exit`).
The `launch /bin/bash <restore.sh>` form used for tmux windows (§5.4) DOES get `--hold` — the wrapper bash is a one-shot exec'ing into `tmux attach-session`, so its exit indicates tmux failure, exactly the diagnostic case `--hold` surfaces. The `--hold` assertion for the tmux case lives in `tmux_conf_patch_restore_launch.rs` (§8), which validates all four required tokens on the patched launch line including `--hold`.

## C.5 Watcher / custom-kitten daemon — verdict: SKIP

A separate agent investigated whether a global Python watcher in kitty.conf could
maintain a live state cache, eliminating most of the save-time RC traffic.

### Findings

Watchers are real, in-process Python callbacks invoked on per-window events
(`on_load`, `on_focus_change`, `on_close`, `on_set_user_var`, `on_cmd_startstop`,
`on_title_change`, etc.). They CAN open sockets and write to disk. Custom kittens
are one-shot only — no daemon lifecycle.

### Why we're not adopting

The save floor is `nvim mksession` (~200 ms typical) which is **structurally
uncacheable** — it must run live at save time to capture cursor positions, buffer
contents, and modified state at THAT moment. A watcher could replace the ~15 ms
`kitty @ ls` call and ~10 ms of `/proc` reads (combined ~25 ms savings on a typical
session), but cannot touch the mksession floor.

**Math:** with Appendix B applied, p50 is ~150 ms. Watcher caching brings it to
~125 ms. That's a 17% improvement requiring ~300 LOC of Python in kitty's process
+ IPC to Rust + cold-start handling + race-condition mitigation across 6 documented
event-ordering hazards.

### Documented hazards (FYI, not action items)

- Watcher cold-start: only fires for windows created AFTER kitty loaded the watcher.
  Existing windows are invisible until you prime via `boss.call_remote_control(['ls'])`.
- No `on_cwd_change` event. `cd` doesn't fire anything unless shell integration
  pushes a user_var (which DOES fire `on_set_user_var`, but you need that wired).
- `on_cmd_startstop` only fires at shell prompt boundaries with shell integration
  enabled. Mid-shell nvim launch is not a watchable event.
- Memory leaks: storing `window` refs in dicts prevents GC. Store `window.id` only.
- Focus_change → close races: always re-resolve via `boss.window_id_map.get(wid)`.
- Watchers run in the kitty render loop — any blocking I/O stalls the UI.

**Verdict: SKIP for v1, REVISIT IF post-B.3.1 telemetry shows `kitty @ ls` in the
top-3 hotspots (it won't be — mksession dominates).**

**However**, watchers DO have value for out-of-band features unrelated to perf —
e.g., "auto-save session on focus-loss after 30 s idle" or "live cwd breadcrumb in
tab title." These are different use cases; defer to a separate ADOPT-LATER track.

## C.6 RC pipelining and `no_response`

Investigated; mostly not load-bearing.

Empirically measured against the user's `/tmp/kitty-4726`:

| Pattern | 20 ops |
|---|---|
| 20× separate subprocess `kitty @ ls` | 207 ms |
| 20× pipelined over one socket (B.3.1) | 168 ms |
| 20× `set-user-vars` with `no_response: true` | 0.4 ms |

Findings:

- **Pipelining over one socket works** — kitty processes requests in send order,
  responses come back framed by DCS terminators in order. The savings vs. B.3.1's
  one-request-per-connection-per-call is only ~20% because the per-call work is
  already short (~15 ms each over the socket).
- **`no_response: true` is true fire-and-forget** for the writes. 20 `set-user-vars`
  calls drop from 1.2 ms to 0.4 ms. **NOTE:** the C.3 UUID tagging step
  originally adopted this — superseded by §5.7 Phase 0.5 (F#2). The orchestrator
  now requires per-window acks so it can drop failed tags from the target set
  before Phase 1 capture. The ~5 ms `no_response` win is forfeited there;
  `no_response: true` remains available for *other* fire-and-forget bursts
  where the caller has no need to know which messages landed.
- **No batch envelope.** Pipelining individual messages IS the documented async
  path.

**Verdict:** when implementing B.3.1, **keep one persistent connection for the
duration of save** and pipeline naturally. The UUID-tagging burst is
response-acknowledged (F#2 supersedes earlier `no_response` adoption). Don't
add a "pipelining mode" abstraction — let it fall out of the connection-per-save
lifetime.

## C.7 Things investigated and rejected

For completeness, these were probed and don't help:

| Item | Why not |
|---|---|
| `get-text --match "id:A or id:B"` for batched scrollback | **Empirically returns one window's text, not concatenated.** Verified: `id:1 or id:8` returns 77 bytes (active prompt only) vs 3429 for `id:1`. Cannot batch. |
| `ls --match` for filtered saves | Tree is structurally pruned, not flattened. Be aware in `KSESSION_FROM_LS` fixtures but no general use. |
| `get-colors` per window | Captures per-window color overrides. User doesn't customize per-window colors; skip. |
| `at_prompt` + `last_reported_cmd_cwd` from `ls` for /proc reduction | Saves ~1 ms; needs shell integration. Not worth the conditional logic. |
| `last_cmd_output` / `last_visited_cmd_output` extents as queryable rows | Not exposed via RC — only extractable via `get-text --extent <name>`. Already in use. No win. |
| OSC 133 prompt marks via RC | The underlying ranges are not exposed. Skip. |
| Custom-kitten as RPC server | One-shot lifecycle. Watcher is strictly better if you want this at all. |

## C.8 Updated TL;DR — Appendix B + Appendix C combined

| Change | Source | Wall-clock | LOC delta | Verdict |
|---|---|---|---|---|
| Direct kitty RC socket | B.3.1 | ~210 ms | +80 | **DO** |
| tmux `-C` control mode | B.3.2 | ~210 ms | +150 | **DO** |
| Flat fan-out + within-window pipelining | B.2 | ~150 ms | refactor | **DO** |
| Tempdir-then-rename atomic writes | B.4 | ~125 ms | refactor | **DO** |
| **Use `ls --output-format=session` for skeleton** | **C.1** | **~0 ms (correctness)** | **−70 net** | **DO** |
| **OSC 1337 shell hook + nvim VimEnter** | **C.2** | **~25-65 ms** | **+30 in Rust, +30 in dotfiles** | **DO** |
| **UUID tagging via set-user-vars** | **C.3** | **0 ms (robustness)** | **+10** | **DO** |
| **`--hold` for failed-program restore** | **C.4** | **0 ms (UX)** | **trivial** | **DO** |
| ~~`no_response: true` for UUID tagging burst~~ (superseded by F#2) | C.6 | ~5 ms forfeited | n/a | **DROPPED** — see §5.7 Phase 0.5 |
| Build profile (LTO, codegen-units=1, panic=abort, strip) | B.5 | ~5-10 ms | 4 lines | **DO** |
| Pre-spawn `kitty @ ls` in `main()` | B.5 | ~10 ms | 5 lines | **DO** |
| `regex-lite` instead of `regex` | B.5 | startup | 1 line | **DO** |
| `std::fs` not `tokio::fs` | B.4 | ~2 ms | feature drop | **DO** |
| `ProcCache` memoization | B.4 | ~5-10 ms | ~30 | **DO** (smaller after C.2) |
| Batched mkdir upfront | B.4 | ~1 ms | trivial | **DO** (clarity) |
| RC connection pipelining | C.6 | ~40 ms | natural | **DO** (free with B.3.1) |
| Watcher/kitten daemon | C.5 | ~25 ms | +300 Python | **SKIP** |
| mimalloc | B.5 | ~0.5-1.5 ms | 2 lines | **MAYBE** |
| io_uring | B.4 | 0 net | +200 | **SKIP** |
| simd-json | B.5 | ~200 µs | +20 | **SKIP** |
| PGO | B.5 | ~200-500 µs | harness | **SKIP** |
| musl static | B.5 | negative | config | **SKIP** |
| jemalloc | B.5 | likely negative | 2 lines | **SKIP** |
| Buffer streaming <8 MiB | B.4 | 0 | +50 | **SKIP** |
| Skip-write-if-identical | B.4 | 0 | +30 | **SKIP** |
| Scrollback gzip | B.4 | 0 net | +20 | **SKIP** |
| tmpfs detection | B.4 | 0 (user on ext4) | +50 | **SKIP** |
| `get-text` batched match | C.7 | — | — | **NOT POSSIBLE** |
| `get-colors` per window | C.7 | — | — | **SKIP** (niche) |
| OSC 133 cmd extents via RC | C.7 | — | — | **NOT EXPOSED** |

## C.9 Revised performance estimate

Cumulative impact of all Appendix B + C "DO" items, layered:

| Workload | Original §9 | After B | After B + C |
|---|---|---|---|
| Typical (12 windows, 2 nvim, 1 tmux) | 250 ms p50 | ~150 ms p50 | **~125 ms p50** |
| Heavy (30 windows, 6 nvim, 2 tmux × 4 panes) | 750 ms p95 | ~400 ms p95 | **~350 ms p95** |

**Floor remains nvim mksession (~200 ms).** Total save can't drop below ~125 ms
on the typical case without either (a) running mksession before the save (live
cache via watcher — see C.5), or (b) accepting stale nvim state. Both are out
of scope for v1.

## C.10 Revised implementation order

Insert two items into §10 / B.7:

```
5.   adapter::{shell, less, raw}                            (~1 day)
5.5* shell hooks: ksession-shell-hook.sh + nvim VimEnter    (~0.5 day) [C.2]
     — write the bash/zsh hook + the lua snippet
     — adapter::shell reads window.user_vars with /proc fallback
6.   nvim_rpc + adapter::nvim                               (~2 days)
6.5* kitty/rpc.rs — direct DCS socket client                (~1 day)   [B.3.1]
6.75 conf rewrite: parse `ls --output-format=session`       (~1 day)   [C.1]
     — replaces ~150 LOC of from-scratch render
     — embeds set_layout_state verbatim
     — adds UUID tagging via set-user-vars [C.3]
7.   tmux_rpc + adapter::tmux (control mode from day one)   (~3.5 days) [§5.4, B.3.2]
     — all behaviors per §5.4 (control-pipe queries, restore.sh codegen, recursive
       pane→registry dispatch, layout-corruption mitigation, base-index drift handling,
       etc.). §5.4 is the canonical scope.
8.   session::save orchestration with flat fan-out          (~1 day)   [B.2]
9.   cli + clap subcommands                                 (~0.5 day)
10.  Diff runner + regression suite                         (~1 day)
11.  Patch ksession-save-prompt.sh                          (~0.5 day)
```

Total: **~13.5 dev days** (was ~13, was originally ~10). The +0.5 day for C.2
shell hooks + the −1 day from C.1's conf simplification net out to flat against
§B.7; the consolidated step 7 (no separate 7.5) replaces a 2 + 1.5 = 3.5 day
split with a single 3.5-day step — no change in critical path. C.1 also reduces
ongoing maintenance burden in `conf/` and removes the SplitHint model type
entirely.

**Critical path unchanged:** steps 6 (nvim_rpc) and 7 (tmux_rpc). C.1's conf
rewrite (6.75) is gated on B.3.1 (kitty RC client) since it depends on the
direct-socket `ls --output-format=session` call.

Step 6.75 (C.1 conf-patch) emits a kitty `launch /bin/bash <state>/tmux/<sess>/restore.sh`
line for tmux-client windows; covered by `tmux_conf_patch_restore_launch.rs` in §8.

**Step 7 ↔ Step 8 input contract.** Step 8's `session::save::resolve_target_program` (ksession.sh:537–554) has already determined that a kitty window's foreground program resolves to a tmux client and identified the relevant pid. Step 7's `adapter::tmux::capture` receives a `WindowCtx` containing **exactly** these fields (no "at minimum" hedge — every field is load-bearing for some Step 7 code path):

- `kitty_window: &kitty::Window` — for `cwd` (used as outer `--cwd` in the conf-patch launch line) and `user_vars` (the `ksession_id` UUID tag from §C.3 set-user-vars).
- `fg_pid: u32` — the tmux client pid, used to (a) read `$TMUX` from `/proc/<fg_pid>/environ` and (b) match against `list-clients -F '#{client_pid} #{session_name}'` to resolve the session name.
- `fg_exe: Option<String>` — informational only; the orchestrator has already classified this as a tmux client via `target_program_hint`. Step 7 does NOT re-validate.
- `window_root_pid: u32` — passed through but unused by the tmux adapter directly; it's already been used by the orchestrator's descendant walk.
- `state_dir: &Path` — sidecar root; the adapter writes `<state_dir>/tmux/<sess>/restore.sh` and `<state_dir>/tmux/<sess>/win-<X>/pane-<Y>/…`.
- `uid: String` — the outer kitty window's id (e.g., `kitty_id.to_string()`); not used for sidecar paths inside the tmux subtree (those use pane-id digits per §5.4 "nvim panes") but threaded through for symmetry with non-tmux adapters.
- `proc_root: &Path` — stub-able for tests, per §5.2.
- `registry: &Registry` — used to recursively dispatch per-pane programs (§5.5).
- `tmux_servers: &Mutex<HashMap<(PathBuf, u32), Arc<TmuxControl>>>` — the per-`(socket_path, server_pid)` control-mode pipe cache (§B.3.2). The first lookup for a server spawns `tmux -C attach -r -t '$<sid>'`; subsequent lookups return the cached `Arc<TmuxControl>` so pipes are reused across windows on the same server.
- `depth: u8` — initialized to `0` by Step 8 at the top-level dispatch. The tmux adapter increments by one when synthesizing the child `WindowCtx` for each pane recursion (§5.5). The adapter's own `detect()` short-circuits when `depth >= MAX_ADAPTER_DEPTH` (default `2`) to prevent nested-tmux infinite recursion.
- `target_program_hint: Option<TargetHint>` — set by Step 8's `resolve_target_program`. The tmux adapter's `detect()` fires only on `Some(TargetHint::Tmux)`; detection itself is fully owned by the orchestrator.

Additionally, the adapter persists the **numeric session id** (parsed from `$TMUX` field 2) onto `Program::Tmux.session_id: u32` so save-time queries can address by `-t '$<sid>'` (sidesteps apostrophe-in-session-name quoting per §5.4 "Apostrophe in session name"). The `session_id` is NOT useful at restore time (server-lifetime monotonic; restart invalidates), so the restore.sh still addresses by name with the `=$SESS` exact-match prefix.

Step 7's preconditions: the `fg_pid` is a real tmux client pid (Step 8 guarantees this via descendant walk + exe-base matching); `target_program_hint == Some(TargetHint::Tmux)`; /proc is readable; tmux availability is NOT pre-checked (Step 7 probes itself per §5.4 step 1). Step 7's postcondition: returns either `Program::Tmux { … }` with a written `restore.sh` on disk, or `Program::Raw { argv: vec!["tmux".into()] }` / `Program::BareShell` on any documented degrade path (no exceptions thrown to the orchestrator).

**Step 7 ↔ Step 6.75 contract.** Step 7's `restore.sh` is a self-contained Bash script invoking `tmux` commands; it does NOT emit kitty `--var ksession_id=…` tokens. UUID tagging (§C.3) is OWNED by Step 8's `session::save` Phase 0.5 — the orchestrator generates client-side UUIDs, issues the batched `kitten @ set-user-vars` call, and tracks the `(kitty_id → Uuid)` mapping in memory. Step 6.75's conf-patcher only READS the resulting `ksession_id` user-vars from the skeleton `launch` lines to correlate them back to the captured `model::Window` entries. The patcher then rewrites the emitted `launch` line for tmux-client windows to `launch --hold --cwd <cwd> --var ksession_id=<uuid> /bin/bash <state>/tmux/<sess>/restore.sh`. Step 7 writes (a) `restore.sh` at `Program::Tmux.restore_sh`, (b) per-pane scrollback files at `<state>/tmux/<sess>/win-<X>/pane-<Y>/scrollback.ansi`, (c) per-pane nvim sidecars (`.vim`, `.json`, buffer dumps) when a tmux pane runs nvim — see §5.4 lines 1080-1099 for the full filesystem layout. Step 6.75 reads only `restore.sh` off `Program::Tmux.restore_sh`; the other files are referenced from inside `restore.sh` itself, not from the kitty conf. Step 7 has no compile- or runtime-dependency on Step 6.75 — they meet only on the `Program::Tmux.restore_sh: PathBuf` field of the in-memory `SessionFile`. **Boundary fields enumerated.** Step 6.75's patcher reads three things from the in-memory `SessionFile` to construct the kitty `launch` line for a tmux window: (1) `Program::Tmux.restore_sh` (the script path), (2) the enclosing kitty `Window.cwd` from the `SessionFile::OsWindow → Tab → Window` tree (for the `--cwd` argument — this is NOT a field on `Program::Tmux`), and (3) the UUID it tagged via `set-user-vars` before invoking `save_as_session` (for correlation). The emitted line is `launch --hold --cwd <window_cwd> --var ksession_id=<uuid> /bin/bash <restore_sh>`. Step 7 owns only (1); (2) is owned by the kitty-layer capture in Step 8; (3) is owned by Step 6.75 itself.
