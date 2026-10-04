//! `ksession tmux …` subcommand: the tmux-native session manager.
//!
//! Usable from inside any tmux client without kitty. The target server and
//! session come from `--session` or the process's own `$TMUX`; everything
//! else (adapters, restore.sh codegen, atomic writes) is shared with the
//! kitty-driven commands. Dispatch lives in `crate::tmux_session::run`.

use clap::Subcommand;

/// `ksession tmux <subcmd>` dispatch.
#[derive(Subcommand, Debug)]
pub enum TmuxCommand {
    /// Save a live tmux session to `<root>/<name>.json` + a state dir.
    Save {
        /// Saved-session name (`A-Z a-z 0-9 . _ -`). Required unless
        /// `--auto` derives it from the tmux session name.
        #[arg(required_unless_present = "auto", conflicts_with = "auto")]
        name: Option<String>,
        /// Name the save `auto-<tmux session name>` instead of asking for a
        /// name. Never prompts; empty sessions are skipped silently.
        #[arg(long)]
        auto: bool,
        /// With `--auto`: save every session on the server.
        #[arg(long, requires = "auto")]
        all: bool,
        /// Tmux session to save. Default: the session this process runs in
        /// (resolved from `$TMUX`).
        #[arg(long, value_name = "TMUX_SESSION")]
        session: Option<String>,
        /// Suppress per-pane scrollback capture. Equivalent to
        /// `KSESSION_SCROLLBACK=0`. Default: scrollback is captured.
        #[arg(long)]
        no_scrollback: bool,
    },
    /// Rebuild a saved tmux session and switch/attach to it.
    Restore {
        /// Saved-session name.
        name: String,
        /// Rebuild even when a live tmux session of that name exists
        /// (kills it first). Without `--force` the live session wins.
        #[arg(long)]
        force: bool,
    },
    /// List saved tmux sessions.
    List {
        /// Machine-readable rows:
        /// `name\tsession_name\twindows\tpanes\tcreated_at_rfc3339`, no
        /// header, no colour. Consumed by the tmux picker.
        #[arg(long)]
        porcelain: bool,
    },
    /// Render a saved tmux session's window/pane tree.
    Show {
        /// Saved-session name.
        name: String,
    },
    /// Remove a saved tmux session (manifest and every state dir).
    Rm {
        /// Saved-session name.
        name: String,
    },
    /// Throttled `save --auto --all`, meant for `status-right` and hooks.
    /// Silent on stdout; exits 0 without saving when the last sweep is
    /// younger than `--every`.
    Autosave {
        /// Minimum interval between sweeps: `<N>s`, `<N>m`, `<N>h`, or bare
        /// seconds.
        #[arg(long, default_value = "15m", value_name = "DURATION")]
        every: String,
        /// Sweep now regardless of the stamp age.
        #[arg(long)]
        force: bool,
    },
}
