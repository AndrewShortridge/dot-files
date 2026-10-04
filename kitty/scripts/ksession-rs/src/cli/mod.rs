//! Clap-derive subcommand structs for the `ksession` binary.
//!
//! Kitty-driven `save/restore/list/show/rm`, the `trace` observability
//! group, and the `tmux` group (tmux-native session manager). Each nested
//! group lives in its own module.

use clap::{Parser, Subcommand, ValueEnum};

pub mod tmux;
pub mod trace;

/// Trace output mode for `--trace` on save/restore (Slice 12).
#[derive(Copy, Clone, Debug, Default, PartialEq, Eq, ValueEnum)]
pub enum TraceMode {
    /// No tracing (default). Behaviour unchanged.
    #[default]
    Off,
    /// Write merged chrome-trace JSON to `<trace_dir>/chrome.json` and
    /// print the path to stderr.
    Chrome,
    /// Render an indented span tree to stderr after the operation.
    Tree,
}

#[derive(Parser, Debug)]
#[command(
    name = "ksession",
    version,
    about = "Save and restore kitty terminal sessions"
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Subcommand, Debug)]
pub enum Command {
    /// Capture the current kitty session to `<sessions_dir>/<name>.{conf,state}`.
    Save {
        /// Session name (used as the `<name>.conf` / `<name>.state` filename stem).
        name: String,
        /// Capture every OS window. Without `--all`, save restricts to the
        /// OS window containing `$KITTY_WINDOW_ID` (else the focused one).
        #[arg(long)]
        all: bool,
        /// Suppress per-window scrollback capture. Equivalent to
        /// `KSESSION_SCROLLBACK=0`. Default: scrollback is captured.
        #[arg(long)]
        no_scrollback: bool,
        /// Trace output mode. `off` (default) produces no trace. `chrome`
        /// writes a perfetto.dev JSON file. `tree` prints an indented span
        /// tree to stderr.
        #[arg(long, value_enum, default_value_t = TraceMode::Off)]
        trace: TraceMode,
    },
    /// Launch a previously saved session via `kitty --session <name>.conf`.
    Restore {
        /// Session name to restore.
        name: String,
        /// Trace output mode. `off` (default) produces no trace. `chrome`
        /// writes a perfetto.dev JSON file. `tree` prints an indented span
        /// tree to stderr.
        #[arg(long, value_enum, default_value_t = TraceMode::Off)]
        trace: TraceMode,
        /// Restore session into the current kitty instance instead of
        /// launching a new kitty window. Requires running within a kitty
        /// instance (checks KITTY_WINDOW_ID).
        #[arg(long)]
        into_current: bool,
    },
    /// List saved sessions in `<sessions_dir>`.
    List,
    /// Render a saved session's `manifest.json` as a tree.
    Show {
        /// Session name to inspect.
        name: String,
    },
    /// Remove a saved session (deletes `<name>.conf` and `<name>.state/`).
    Rm {
        /// Session name to remove.
        name: String,
    },
    /// Inspect perf observability traces under `~/.cache/ksession/traces/`.
    ///
    /// Only `show --format=chrome` is implemented in slice 1; the other
    /// subcommands print a "not yet implemented" line and exit non-zero
    /// per PRD-0's slice plan (stats=2, tree=3, gc/ls=4).
    Trace {
        #[command(subcommand)]
        command: trace::TraceCommand,
    },
    /// Tmux-native session manager: save/restore tmux sessions from inside
    /// any tmux client, no kitty required.
    Tmux {
        #[command(subcommand)]
        command: tmux::TmuxCommand,
    },
}
