//! Render a kitty `.conf` session file by patching a `kitty @ ls
//! --output-format=session` skeleton.
//!
//! Plan §C.1 ("skeleton + patch" pipeline): instead of synthesising the whole
//! conf from a [`SessionFile`] AST, we delegate `new_tab` / `layout` /
//! `enabled_layouts` / `set_layout_state` / `cd` / `focus` / `focus_tab` /
//! `os_window_*` lines to kitty itself, then rewrite each `launch` line in
//! two ways:
//!
//! - Strip the `kitty-unserialize-data={"id": N}` token kitty inserts for its
//!   intra-process reattach mechanism — it never survives a kitty restart.
//! - Replace the existing argv (which, depending on capture flags, may be
//!   either a bare shell or whatever the foreground process happens to be)
//!   with the argv our save-time adapters chose (a real `nvim -S …` line,
//!   `less +N% -- file`, the tmux restore.sh, …). The new argv is keyed off
//!   the window's `kitty_id` so a `Window` from [`SessionFile`] supplies it.
//! - Re-tag every patched launch with `--var=ksession_id=<uuid>` (§C.3) for
//!   stable cross-restart identity, and add `--hold` for non-shell programs
//!   so a failed restore stays visible (§C.4).
//!
//! The skeleton's `focus` line (after the active window's launch) and
//! `focus_tab N` (last line) are preserved verbatim — kitty's session parser
//! already handles them correctly, so we don't need `focus_matching_window`.
//!
//! Lines we don't recognise pass through verbatim. That is deliberate: kitty
//! adds session-format keywords across point releases (e.g. `os_window_class`
//! / `os_window_name` showed up in 0.40+), so blacklisting would silently
//! drop them.

use std::borrow::Cow;
use std::collections::HashMap;
use std::fmt::Write as _;

use crate::error::KError;
use crate::model::{Program, SessionFile, ShellKind, Window, SYNTHETIC_ID_FLOOR};

// ---------- kq: kitty session-file arg quoter ----------

/// Quote one arg for a kitty session-file launch line.
///
/// Kitty parses launch args with shlex semantics after `${VAR}` expansion;
/// single-quotes disable both. If the arg consists entirely of "safe"
/// characters (`A-Za-z0-9_./@:=+,-`), it is returned as-is via
/// `Cow::Borrowed`. Otherwise it is wrapped in single quotes and any
/// embedded single quotes are escaped using the shell-classic
/// `'\''` sequence.
#[must_use]
pub fn kq(s: &str) -> Cow<'_, str> {
    if is_kq_safe(s) {
        Cow::Borrowed(s)
    } else {
        Cow::Owned(format!("'{}'", s.replace('\'', r"'\''")))
    }
}

fn is_kq_safe(s: &str) -> bool {
    !s.is_empty()
        && s.bytes().all(|b| {
            matches!(b,
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' |
                b'_' | b'.' | b'/' | b'@' | b':' | b'=' | b'+' | b',' | b'-'
            )
        })
}

// ---------- shlex tokenizer ----------

/// Split a kitty session-file line into shell-style tokens.
///
/// Handles single quotes (no escapes, literal), double quotes (literal too:
/// kitty doesn't honour C-style backslash escapes inside `"..."` in launch
/// args), and bare tokens broken on ASCII whitespace. An unterminated quote
/// is tolerated by emitting the partial token — the round trip back through
/// [`kq`] will re-quote it correctly on re-emission.
fn shlex_split(line: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut have_token = false;
    let mut chars = line.chars();
    while let Some(c) = chars.next() {
        if c == '\'' {
            have_token = true;
            for nc in chars.by_ref() {
                if nc == '\'' {
                    break;
                }
                cur.push(nc);
            }
        } else if c == '"' {
            have_token = true;
            for nc in chars.by_ref() {
                if nc == '"' {
                    break;
                }
                cur.push(nc);
            }
        } else if c.is_ascii_whitespace() {
            if have_token {
                out.push(std::mem::take(&mut cur));
                have_token = false;
            }
        } else {
            cur.push(c);
            have_token = true;
        }
    }
    if have_token {
        out.push(cur);
    }
    out
}

// ---------- unserialize-data parsing ----------

/// If `tok` is `kitty-unserialize-data={"id": N}` (with arbitrary whitespace
/// inside the JSON), return N. Otherwise return None.
fn extract_unserialize_id(tok: &str) -> Option<u64> {
    let json = tok.strip_prefix("kitty-unserialize-data=")?;
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    v.get("id")?.as_u64()
}

// ---------- launch-line patching ----------

/// Drop the user-var keys ksession owns; everything else passes through.
fn is_ksession_owned_var(key: &str) -> bool {
    matches!(key, "ksession_id" | "ksession_idx" | "ksession_win")
}

/// Patch one `launch …` line. `by_id` maps captured `Window.kitty_id` to the
/// `Window` itself; if the line's unserialize-id matches, the argv is
/// rewritten from `window.program`. If it doesn't match (window not captured,
/// orphan launch, unrecognised token shape, …) we still strip the
/// unserialize-data token and ksession-owned vars so the line at least no
/// longer references stale state — but argv is left as the skeleton had it.
///
/// The returned string has no trailing newline; callers append `\n`.
fn patch_launch(line: &str, by_id: &HashMap<u64, &Window>) -> String {
    let tokens = shlex_split(line);
    debug_assert!(!tokens.is_empty() && tokens[0] == "launch");

    let mut unserialize_id: Option<u64> = None;
    let mut preserved_opts: Vec<String> = Vec::new();
    let mut residual_argv: Vec<String> = Vec::new();
    let mut had_hold = false;

    // Skip tokens[0] = "launch".
    let mut iter = tokens.into_iter().skip(1);
    // The skeleton's option block is followed by an argv block; once we see a
    // non-option non-unserialize token we treat everything after as argv.
    let mut in_argv = false;
    while let Some(t) = iter.next() {
        // G1: strip unserialize-data unconditionally (even mid-argv). Real
        // kitty only emits it pre-argv, but a hand-edited skeleton with a
        // late-position token would otherwise leak into argv on the
        // unmatched-window path. Drop on prefix match regardless of JSON
        // validity (malformed token has no meaning post-restart).
        if t.starts_with("kitty-unserialize-data=") {
            if unserialize_id.is_none() {
                if let Some(id) = extract_unserialize_id(&t) {
                    unserialize_id = Some(id);
                }
            }
            continue;
        }
        if !in_argv {
            if t == "--hold" {
                had_hold = true;
                preserved_opts.push(t);
                continue;
            }
            if let Some(rest) = t.strip_prefix("--var=") {
                // `--var=key=value` — drop if ksession-owned.
                let key = rest.split_once('=').map(|(k, _)| k).unwrap_or(rest);
                if is_ksession_owned_var(key) {
                    continue;
                }
                preserved_opts.push(t);
                continue;
            }
            // G3: two-token `--var KEY=VAL` and `--env KEY=VAL` both follow
            // kitty's launch-option grammar; group them so the value isn't
            // misparsed as argv[0]. For `--var` we additionally drop
            // ksession-owned keys; `--env` has no owned keys.
            if t == "--var" || t == "--env" {
                let is_var = t == "--var";
                if let Some(next) = iter.next() {
                    if is_var {
                        let key = next
                            .split_once('=')
                            .map(|(k, _)| k)
                            .unwrap_or(next.as_str());
                        if is_ksession_owned_var(key) {
                            continue;
                        }
                    }
                    preserved_opts.push(t);
                    preserved_opts.push(next);
                    continue;
                }
                preserved_opts.push(t);
                continue;
            }
            if t.starts_with("--") {
                preserved_opts.push(t);
                continue;
            }
            // First non-option, non-unserialize token: argv begins here.
            in_argv = true;
        }
        residual_argv.push(t);
    }

    // Build output. kq-quote everything on re-emission.
    let mut out = String::from("launch");
    for opt in &preserved_opts {
        out.push(' ');
        out.push_str(&kq(opt));
    }

    let matched_window = unserialize_id.and_then(|id| by_id.get(&id).copied());

    // --hold: add for non-shell programs (per §C.4), unless the skeleton
    // already had it.
    if let Some(w) = matched_window {
        if program_wants_hold(&w.program) && !had_hold {
            out.push_str(" --hold");
        }
    }

    // Re-tag with ksession_id (§C.3). Skip if empty — happens when an
    // older manifest (pre-§C.3) is round-tripped via the lenient
    // #[serde(default)] on `Window.ksession_id`. Re-saving refreshes it.
    if let Some(w) = matched_window {
        if !w.ksession_id.is_empty() {
            write!(out, " --var=ksession_id={}", kq(&w.ksession_id)).unwrap();
        }
    }

    // PRD-13 Slice 5: HISTFILE env override for shell programs with history.
    // Emitted as the two-token form `--env HISTFILE=<path>` so kq only
    // quotes the value portion when the path contains special characters.
    if let Some(w) = matched_window {
        if let Program::Shell {
            history: Some(ref path),
            ..
        } = w.program
        {
            out.push_str(" --env");
            let val = format!("HISTFILE={}", path.display());
            out.push(' ');
            out.push_str(&kq(&val));
        }
    }

    // Argv: from the captured Program if we matched, otherwise from the
    // skeleton's residual (which may be empty if kitty only emitted the
    // unserialize-data token).
    //
    // PRD-13 scrollback replay: `Program::Shell` handles scrollback
    // internally (via its own `scrollback` field in the `-c` chain).
    // For other program types, we use `Window.scrollback` to wrap
    // the argv in a `/bin/sh -c` that cats the scrollback before
    // exec-ing the original command.
    //
    // `Program::Raw` is EXCLUDED from the cat wrapper (ADR 0007 addendum):
    // raw TUIs (interactive agent CLIs like pi/omp/claude) must start on a
    // clean PTY — catting the raw-ANSI transcript into the PTY before exec
    // visually replays the entire prior session (it reads as a rerun) and
    // can leave the terminal in a dirty mode. Their argv is emitted
    // directly; scrollback capture stays a write-only artifact for them.
    match matched_window {
        Some(w) => {
            let replay_scrollback =
                !matches!(w.program, Program::Shell { .. } | Program::Raw { .. });
            if replay_scrollback {
                if let Some(ref sb_path) = w.scrollback {
                    let mut argv_buf = String::new();
                    append_program_argv(&mut argv_buf, &w.program);
                    let argv_trimmed = argv_buf.trim_start();
                    let cat_cmd = format!(
                        "cat {} 2>/dev/null; exec {}",
                        kq(&sb_path.to_string_lossy()),
                        argv_trimmed
                    );
                    out.push_str(" /bin/sh -c ");
                    out.push_str(&kq(&cat_cmd));
                } else {
                    append_program_argv(&mut out, &w.program);
                }
            } else {
                append_program_argv(&mut out, &w.program);
            }
        }
        None => {
            for a in &residual_argv {
                out.push(' ');
                out.push_str(&kq(a));
            }
        }
    }

    out
}

fn program_wants_hold(p: &Program) -> bool {
    matches!(
        p,
        Program::Nvim { .. } | Program::Less { .. } | Program::Tmux { .. } | Program::Raw { .. }
    )
}

// ---------- agent session resume (ADR 0008) ----------

/// One row of the agent-resume rule table (ADR 0008): exe basenames a rule
/// covers, the flag appended at restore time so the agent resumes its prior
/// conversation (these CLIs key sessions by cwd, which ksession restores),
/// and the flags whose presence in the saved argv suppresses the append
/// (already resuming / explicit session selection / non-interactive /
/// opted out of session persistence).
struct AgentResumeRule {
    basenames: &'static [&'static str],
    resume_flag: &'static str,
    skip_flags: &'static [&'static str],
}

/// Known interactive agent CLIs and their resume behavior. Extend by adding
/// a row (or a basename to an existing row when the tool shares flags).
const AGENT_RESUME_RULES: &[AgentResumeRule] = &[
    AgentResumeRule {
        basenames: &["claude"],
        resume_flag: "--continue",
        skip_flags: &[
            "-c",
            "--continue",
            "-r",
            "--resume",
            "--fork-session",
            "--from-pr",
            "-p",
            "--print",
        ],
    },
    // opi and omp are the same tool; pi is its sibling with identical
    // session flags.
    AgentResumeRule {
        basenames: &["pi", "opi", "omp"],
        resume_flag: "--continue",
        skip_flags: &[
            "-c",
            "--continue",
            "-r",
            "--resume",
            "--session",
            "--session-id",
            "--fork",
            // Session wasn't saved — resuming would pick up an unrelated one.
            "--no-session",
            "-p",
            "--print",
        ],
    },
];

/// Script runtimes that appear as `argv[0]` when an agent CLI is a shebang
/// script (`#!/usr/bin/env bun` → the kernel execs `bun /path/to/omp`, and
/// that is what `/proc/<pid>/cmdline` reports). The agent's identity is
/// then `argv[1]`, so basename matching must look past the runtime.
const SCRIPT_RUNTIMES: &[&str] = &["bun", "node", "deno", "python", "python3"];

/// If `argv` is a known agent CLI that should resume its prior conversation
/// on restore (ADR 0008), return the flag to append; otherwise `None`.
///
/// Matching is on the BASENAME of the agent executable: `argv[0]`, or
/// `argv[1]` when `argv[0]` is a script runtime (`bun /home/u/.bun/bin/omp`;
/// saved argvs may carry a full path like `/home/u/.local/bin/opi`).
/// Skip-flags are scanned across ALL argv elements — these CLIs accept
/// flags anywhere — in both the `--flag value` (exact token) and
/// `--flag=value` (prefix) forms. No full CLI grammar is modeled; simple
/// token matching is intentional.
fn agent_resume_flag(argv: &[String]) -> Option<&'static str> {
    fn basename(s: &str) -> &str {
        s.rsplit('/').next().unwrap_or(s)
    }
    let first = basename(argv.first()?);
    let exe = if SCRIPT_RUNTIMES.contains(&first) {
        // A runtime followed by a script path: `bun /abs/omp`. Runtime
        // subcommands/flags (`bun run x`, `node -e`) are not agents.
        argv.get(1).filter(|s| s.contains('/'))?
    } else {
        first
    };
    let basename = basename(exe);
    let rule = AGENT_RESUME_RULES
        .iter()
        .find(|r| r.basenames.contains(&basename))?;
    let has_skip = argv.iter().any(|a| {
        rule.skip_flags.iter().any(|f| {
            a.strip_prefix(f)
                .is_some_and(|rest| rest.is_empty() || rest.starts_with('='))
        })
    });
    if has_skip {
        None
    } else {
        Some(rule.resume_flag)
    }
}

/// Push one program's argv directly to `out`, each arg prefixed with a space
/// and kq-quoted. No intermediate `Vec<String>` is allocated.
fn append_program_argv(out: &mut String, p: &Program) {
    fn push(out: &mut String, arg: &str) {
        out.push(' ');
        out.push_str(&kq(arg));
    }
    match p {
        Program::Nvim { session_vim, .. } => {
            push(out, "nvim");
            push(out, "-S");
            push(out, &session_vim.to_string_lossy());
        }
        Program::Less {
            file,
            byte_offset,
            file_size,
        } => {
            // bash clamps at 99 because less rejects `+100%`.
            let pct = if *file_size > 0 {
                (byte_offset.saturating_mul(100) / *file_size).min(99)
            } else {
                0
            };
            push(out, "less");
            let mut plus = String::with_capacity(8);
            write!(&mut plus, "+{pct}%").unwrap();
            push(out, &plus);
            push(out, "--");
            push(out, &file.to_string_lossy());
        }
        Program::Shell {
            shell,
            venv,
            conda,
            direnv: _,
            oldpwd,
            scrollback,
            history: _,
        } => {
            let shell_name = shell_name(*shell);

            // Scrollback replay: `cat <path> 2>/dev/null;` prepended to the
            // -c command chain so the terminal replays saved scrollback before
            // the interactive shell starts.
            let scrollback_pre = if let Some(sb) = scrollback {
                let _span =
                    crate::perf_span!(crate::perf::Level::Debug, "conf.render.scrollback_wrap");
                format!("cat {} 2>/dev/null; ", kq(&sb.to_string_lossy()))
            } else {
                String::new()
            };

            let mut pre = String::new();
            write!(&mut pre, "{scrollback_pre}").unwrap();
            if let Some(v) = venv {
                write!(&mut pre, "source {}/bin/activate; ", v.display()).unwrap();
            } else if let Some(c) = conda {
                write!(&mut pre, "conda activate {c}; ").unwrap();
            }
            if let Some(o) = oldpwd {
                write!(&mut pre, "export OLDPWD={}; ", o.display()).unwrap();
            }
            let mut bin = String::with_capacity(5 + shell_name.len());
            write!(&mut bin, "/bin/{shell_name}").unwrap();
            push(out, &bin);
            push(out, "-l");
            if !pre.is_empty() {
                push(out, "-c");
                // `pre` always ends with "; " from its constituent
                // writeln-style chunks; trim to avoid the cosmetic double
                // space in e.g. "export OLDPWD=/tmp;  exec bash".
                let pre_trimmed = pre.trim_end();
                let mut cmd = String::with_capacity(pre_trimmed.len() + 6 + shell_name.len());
                write!(&mut cmd, "{pre_trimmed} exec {shell_name}").unwrap();
                push(out, &cmd);
            }
        }
        Program::Tmux { restore_sh, .. } => {
            // Plan §6: paths are bit-for-bit preserved with the Bash port.
            // ksession.sh:442 emits `/bin/bash` (absolute) — match exactly.
            push(out, "/bin/bash");
            push(out, &restore_sh.to_string_lossy());
        }
        Program::Raw { argv } => {
            for a in argv {
                push(out, a);
            }
            // ADR 0008: known agent CLIs get a session-resume flag appended
            // at render time so the restored agent picks its cwd-keyed
            // conversation back up instead of starting fresh. This arm is
            // the single choke point for Raw argv in kitty launch lines:
            // both patch_launch paths (scrollback and direct — Raw always
            // takes the direct one per ADR 0007's addendum) funnel here.
            if let Some(flag) = agent_resume_flag(argv) {
                push(out, flag);
            }
        }
        Program::BareShell => {
            push(out, "/bin/bash");
            push(out, "-l");
        }
    }
}

fn shell_name(s: ShellKind) -> &'static str {
    match s {
        ShellKind::Bash => "bash",
        ShellKind::Zsh => "zsh",
        ShellKind::Fish => "fish",
        ShellKind::Sh => "sh",
        ShellKind::Dash => "dash",
        ShellKind::Ash => "ash",
    }
}

// ---------- render: SessionFile + skeleton -> kitty .conf ----------

/// Render a kitty `.conf` session file.
///
/// Inputs:
///   - `skeleton` — output of `kitty @ ls --output-format=session` (or the
///     newer `kitten @ action save_as_session --save-only`). Provides the
///     `new_tab` / `layout` / `enabled_layouts` / `set_layout_state` / `cd` /
///     `focus` / `focus_tab` / `os_window_*` lines verbatim.
///   - `session` — captured [`SessionFile`] from the save adapters. Provides
///     argv for each window via `Program`, looked up by `kitty_id`.
///
/// Returns the patched conf text. Errors only if `skeleton` is materially
/// malformed (not currently — every parser branch tolerates oddities). The
/// `Result` keeps room for future strict-mode opt-ins.
pub fn render(skeleton: &str, session: &SessionFile) -> Result<String, KError> {
    let _span = crate::perf_span!(crate::perf::Level::Info, "conf.render");

    // Pre-0.40 kitty doesn't honour `--output-format=session` and returns
    // JSON regardless. Sniff the first non-blank-non-comment line: if it
    // opens with `[` or `{` (after stripping a possible UTF-8 BOM), we're
    // looking at JSON, not session format. Better to fail loudly here than
    // to feed JSON through `shlex_split` and produce nonsense.
    let sniff_input = skeleton.trim_start_matches('\u{feff}');
    if let Some(first) = sniff_input
        .lines()
        .map(str::trim_start)
        .map(|l| l.trim_start_matches('\u{feff}'))
        .find(|l| !l.is_empty() && !l.starts_with('#'))
    {
        if first.starts_with('[') || first.starts_with('{') {
            return Err(KError::KittyRemote(
                "kitty @ ls --output-format=session returned JSON, not session format \
                 (kitty < 0.40?). Upgrade kitty to 0.40+ or fall back to the legacy \
                 renderer."
                    .to_string(),
            ));
        }
    }

    let by_id: HashMap<u64, &Window> = session
        .os_windows
        .iter()
        .flat_map(|osw| osw.tabs.iter())
        .flat_map(|t| t.windows.iter())
        .map(|w| (w.kitty_id, w))
        .collect();

    let mut out = String::with_capacity(skeleton.len() + 256);

    // Header. chrono's SecondsFormat::Secs with use_z=false emits "+00:00"
    // (matches `date -Is`); use_z=true would emit "Z".
    //
    let ts = session
        .created_at
        .to_rfc3339_opts(chrono::SecondsFormat::Secs, false);
    writeln!(out, "# Description: saved {}", ts).unwrap();
    out.push_str(
        "# Generated by ksession-rs \u{2014} re-save to refresh; restore with: kitty --session this-file\n",
    );
    out.push('\n');

    // Line-by-line pass-through with launch patching. Use `split_inclusive`
    // so we preserve the original newline shape: a skeleton ending without a
    // trailing newline emits a file ending without one too.
    //
    // We also track tab boundaries so that synthetic-window placeholders
    // (`kitty_id >= SYNTHETIC_ID_FLOOR`, see plan §5.7) get a fresh
    // `launch /bin/bash -l` line emitted into the tab they belong to. The
    // skeleton has no launch line for a synthetic window (no kitty window
    // existed at capture time), so the patcher injects one when the tab
    // ends — at the next `new_tab` / `new_os_window` / `focus_tab` boundary
    // (whichever comes first), or at end of input.
    //
    // OSW/tab indexing matches the SessionFile assembly order in
    // `session::save`: the first `new_os_window` in the skeleton corresponds
    // to `os_windows[1]` (the first OSW is implicit, the second is
    // introduced by the separator). `new_tab` resets to tab 0 within the
    // current OSW; subsequent `new_tab`s bump tab_idx.
    let mut osw_idx: usize = 0;
    let mut tab_idx: usize = 0;
    // True once the current OSW has opened its first tab (via the first
    // `new_tab` of that OSW). Reset on `new_os_window` so the first
    // `new_tab` of the *next* OSW doesn't double-bump `tab_idx`.
    let mut seen_first_tab_in_osw = false;
    // True iff we've already flushed synthetic launches for the (osw_idx,
    // tab_idx) currently in scope. Reset whenever the tab coordinate
    // changes; checked on EOF to avoid double-flushing when the skeleton
    // ends with a `focus_tab` (which already triggered a flush).
    let mut tab_flushed = false;
    let mut out_tmp = String::new();
    for raw in skeleton.split_inclusive('\n') {
        let (body, nl) = match raw.strip_suffix('\n') {
            Some(b) => (b, "\n"),
            None => (raw, ""),
        };
        let trimmed = body.trim_start();
        let is_new_tab = trimmed == "new_tab"
            || trimmed.starts_with("new_tab ")
            || trimmed.starts_with("new_tab\t");
        let is_new_osw = trimmed == "new_os_window"
            || trimmed.starts_with("new_os_window ")
            || trimmed.starts_with("new_os_window\t");
        let is_focus_tab = trimmed == "focus_tab"
            || trimmed.starts_with("focus_tab ")
            || trimmed.starts_with("focus_tab\t");

        // Tab transition: flush synthetic launches for the *current* tab
        // before emitting the boundary directive. `focus_tab` is the
        // trailing directive after the last tab's launches, so flushing
        // there closes out the final tab too.
        if (is_new_tab || is_new_osw || is_focus_tab) && seen_first_tab_in_osw && !tab_flushed {
            emit_synthetic_launches(&mut out_tmp, session, osw_idx, tab_idx);
            tab_flushed = true;
        }

        if is_new_osw {
            osw_idx += 1;
            tab_idx = 0;
            seen_first_tab_in_osw = false;
            tab_flushed = false;
        } else if is_new_tab {
            if seen_first_tab_in_osw {
                tab_idx += 1;
            }
            seen_first_tab_in_osw = true;
            tab_flushed = false;
        }

        if is_launch_line(body) {
            // Drop transient overlay windows (e.g. the ctrl+space>shift+s
            // save-prompt that triggered this very save) that kitty's session
            // skeleton lists but `filter_windows` excluded from the model.
            // Emitting nothing stops restore from re-spawning them.
            if !is_filtered_overlay_launch(body, &by_id) {
                out_tmp.push_str(&patch_launch(body, &by_id));
                out_tmp.push_str(nl);
            }
        } else {
            out_tmp.push_str(raw);
        }
    }
    // Flush the final tab if no `focus_tab` / `new_tab` / `new_os_window`
    // boundary closed it.
    if seen_first_tab_in_osw && !tab_flushed {
        emit_synthetic_launches(&mut out_tmp, session, osw_idx, tab_idx);
    }

    out.push_str(&out_tmp);
    Ok(out)
}

/// Emit one `launch /bin/bash -l` line per synthetic window in
/// `session.os_windows[osw_idx].tabs[tab_idx]`, tagged with the window's
/// `ksession_id` so cross-restart identity survives.
///
/// A synthetic window is one whose `kitty_id >= SYNTHETIC_ID_FLOOR`. No-op
/// when the (osw_idx, tab_idx) coordinate is out of range or the tab has no
/// synthetic windows.
fn emit_synthetic_launches(
    out: &mut String,
    session: &SessionFile,
    osw_idx: usize,
    tab_idx: usize,
) {
    let Some(osw) = session.os_windows.get(osw_idx) else {
        return;
    };
    let Some(tab) = osw.tabs.get(tab_idx) else {
        return;
    };
    for w in &tab.windows {
        if w.kitty_id < SYNTHETIC_ID_FLOOR {
            continue;
        }
        out.push_str("launch");
        if !w.ksession_id.is_empty() {
            write!(out, " --var=ksession_id={}", kq(&w.ksession_id)).unwrap();
        }
        out.push_str(" /bin/bash -l\n");
    }
}

/// Whitespace-tolerant check that `body` begins with the bare `launch`
/// directive. Matches `"launch"`, `"launch …"`, `"\tlaunch …"`,
/// `"  launch\tfoo"`, etc. Does NOT match `"launcher"`, `"# launch …"`,
/// or `"launch_attempt …"`.
fn is_launch_line(body: &str) -> bool {
    let body = body.trim_start();
    let rest = match body.strip_prefix("launch") {
        Some(r) => r,
        None => return false,
    };
    rest.is_empty() || rest.starts_with(|c: char| c.is_ascii_whitespace())
}

/// True when a skeleton `launch` line describes an overlay window
/// (`--type=overlay`) that was NOT captured into the model — its
/// `kitty-unserialize-data` id is absent from `by_id`, or it has no id.
///
/// `kitty @ ls --output-format=session` dumps every live window, including
/// transient overlays like the ctrl+space>shift+s save-prompt that triggers the
/// save. `filter_windows` (save.rs) drops those from the captured model, so they
/// never land in `by_id`; without this guard the renderer would pass the
/// overlay's `launch --type=overlay …` line straight through and kitty would
/// re-spawn the save-prompt on every restore.
///
/// `set_layout_state` may still reference the dropped window's id, but kitty
/// maps layout-state ids via the `kitty-unserialize-data` token and silently
/// ignores ids with no live window, so the dangling reference is harmless and
/// the blob stays opaque.
///
/// Only the option region (before argv) is scanned, mirroring `patch_launch`'s
/// tokenisation, so a `--type=overlay` substring inside an argv `-c '…'` string
/// cannot trigger a false drop.
fn is_filtered_overlay_launch(line: &str, by_id: &HashMap<u64, &Window>) -> bool {
    let tokens = shlex_split(line);
    let mut iter = tokens.into_iter().skip(1); // skip "launch"
    let mut in_argv = false;
    let mut is_overlay = false;
    let mut unserialize_id: Option<u64> = None;
    while let Some(t) = iter.next() {
        if t.starts_with("kitty-unserialize-data=") {
            if unserialize_id.is_none() {
                unserialize_id = extract_unserialize_id(&t);
            }
            continue;
        }
        if in_argv {
            continue;
        }
        if let Some(v) = t.strip_prefix("--type=") {
            is_overlay = v == "overlay";
            continue;
        }
        if t == "--type" {
            if let Some(v) = iter.next() {
                is_overlay = v == "overlay";
            }
            continue;
        }
        if t == "--var" || t == "--env" {
            iter.next(); // two-token option: skip value so it isn't read as argv
            continue;
        }
        if t.starts_with("--") {
            continue;
        }
        in_argv = true; // first non-option token: argv begins
    }
    is_overlay && unserialize_id.map_or(true, |id| !by_id.contains_key(&id))
}

// ---------- conf parser ----------

pub mod parser;

pub use parser::ConfParser;

// ---------- tests ----------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{OsWindow, SessionFile, Tab, TmuxWindow, Window};
    use chrono::{TimeZone, Utc};
    use pretty_assertions::assert_eq;
    use std::path::PathBuf;

    // ----- kq -----

    #[test]
    fn kq_safe_passthrough() {
        for s in [
            "a",
            "Z",
            "0",
            "_",
            ".",
            "/",
            "@",
            ":",
            "=",
            "+",
            ",",
            "-",
            "/home/u/proj",
            "--var",
            "ksession_id=0",
            "a.b@c:d=e+f,g-h",
        ] {
            let got = kq(s);
            assert!(
                matches!(got, Cow::Borrowed(_)),
                "expected borrowed for {s:?}"
            );
            assert_eq!(&*got, s);
        }
    }

    #[test]
    fn kq_unsafe_quoted() {
        assert_eq!(&*kq("hello world"), "'hello world'");
        assert_eq!(&*kq("foo;bar"), "'foo;bar'");
        assert_eq!(&*kq("a b"), "'a b'");
    }

    #[test]
    fn kq_empty_quoted() {
        assert_eq!(&*kq(""), "''");
    }

    #[test]
    fn kq_embedded_single_quote() {
        assert_eq!(&*kq("let's go"), r"'let'\''s go'");
    }

    #[test]
    fn kq_multiple_quotes() {
        assert_eq!(&*kq("a'b'c"), r"'a'\''b'\''c'");
    }

    #[test]
    fn kq_curated_alphabet_property() {
        let mut safe: Vec<u8> = Vec::new();
        safe.extend(b'A'..=b'Z');
        safe.extend(b'a'..=b'z');
        safe.extend(b'0'..=b'9');
        safe.extend_from_slice(b"_./@:=+,-");
        for b in safe {
            let s = std::str::from_utf8(std::slice::from_ref(&b))
                .unwrap()
                .to_string();
            assert!(
                matches!(kq(&s), Cow::Borrowed(_)),
                "expected borrowed for {s:?}"
            );
        }
        for ch in [
            ' ', ';', '\'', '"', '$', '*', '?', '(', ')', '[', ']', '{', '}', '\\', '|', '&', '<',
            '>', '!', '#', '\t', '\n',
        ] {
            let s = ch.to_string();
            assert!(matches!(kq(&s), Cow::Owned(_)), "expected quoted for {s:?}");
        }
    }

    // ----- shlex_split -----

    #[test]
    fn shlex_handles_bare_and_single_quoted_tokens() {
        let toks =
            shlex_split(r#"launch 'kitty-unserialize-data={"id": 4}' --var=k=v /bin/bash -l"#);
        assert_eq!(
            toks,
            vec![
                "launch",
                r#"kitty-unserialize-data={"id": 4}"#,
                "--var=k=v",
                "/bin/bash",
                "-l",
            ]
        );
    }

    #[test]
    fn shlex_handles_double_quoted_tokens() {
        let toks = shlex_split(r#"launch --cwd "/home/u/has space" /bin/bash"#);
        assert_eq!(
            toks,
            vec!["launch", "--cwd", "/home/u/has space", "/bin/bash"]
        );
    }

    #[test]
    fn shlex_handles_partial_var_with_space() {
        // Pulled from live capture: `'--var= probe_ws=trailspc'` — a
        // single-quoted token containing a literal `--var=` followed by a
        // space and a key=value.
        let toks = shlex_split(r#"launch '--var= probe_ws=trailspc'"#);
        assert_eq!(toks, vec!["launch", "--var= probe_ws=trailspc"]);
    }

    #[test]
    fn shlex_empty_input() {
        assert!(shlex_split("").is_empty());
    }

    #[test]
    fn shlex_quoted_empty_token() {
        let toks = shlex_split("launch ''");
        assert_eq!(toks, vec!["launch", ""]);
    }

    // ----- extract_unserialize_id -----

    #[test]
    fn unserialize_id_basic() {
        assert_eq!(
            extract_unserialize_id(r#"kitty-unserialize-data={"id": 7}"#),
            Some(7)
        );
    }

    #[test]
    fn unserialize_id_with_extra_keys() {
        assert_eq!(
            extract_unserialize_id(r#"kitty-unserialize-data={"id": 42, "future": true}"#),
            Some(42)
        );
    }

    #[test]
    fn unserialize_id_rejects_non_match() {
        assert_eq!(extract_unserialize_id("--var=k=v"), None);
        assert_eq!(extract_unserialize_id(r#"kitty-unserialize-data={}"#), None);
        assert_eq!(
            extract_unserialize_id(r#"kitty-unserialize-data={"id":"x"}"#),
            None
        );
        assert_eq!(
            extract_unserialize_id("kitty-unserialize-data=garbage"),
            None
        );
    }

    // ----- patch_launch -----

    fn mk_window(id: u64, prog: Program) -> Window {
        Window {
            kitty_id: id,
            ksession_id: format!("uid-{id}"),
            cwd: None,
            program: prog,
            scrollback: None,
        }
    }

    fn by_id_of(ws: &[Window]) -> HashMap<u64, &Window> {
        ws.iter().map(|w| (w.kitty_id, w)).collect()
    }

    #[test]
    fn patch_replaces_argv_for_matched_window() {
        let w = mk_window(7, Program::BareShell);
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 7}' --var=ksession_idx=0 --var=ksession_win=7 /old/argv -here"#;
        let got = patch_launch(line, &by_id);
        assert_eq!(got, "launch --var=ksession_id=uid-7 /bin/bash -l");
    }

    #[test]
    fn patch_strips_unserialize_data_even_with_no_match() {
        let by_id: HashMap<u64, &Window> = HashMap::new();
        let line = r#"launch 'kitty-unserialize-data={"id": 999}' --var=ksession_idx=0 --var=ksession_win=999 /bin/bash -l"#;
        let got = patch_launch(line, &by_id);
        assert_eq!(got, "launch /bin/bash -l");
        assert!(!got.contains("kitty-unserialize-data"));
        assert!(!got.contains("ksession_idx"));
        assert!(!got.contains("ksession_win"));
    }

    #[test]
    fn patch_preserves_user_var_and_cwd() {
        let w = mk_window(2, Program::BareShell);
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 2}' --cwd=/home/u --var=my_custom=42 /bin/bash -l"#;
        let got = patch_launch(line, &by_id);
        assert!(got.contains("--cwd=/home/u"), "cwd preserved: {got}");
        assert!(
            got.contains("--var=my_custom=42"),
            "user --var preserved: {got}"
        );
        assert!(
            got.contains("--var=ksession_id=uid-2"),
            "ksession_id added: {got}"
        );
    }

    #[test]
    fn patch_adds_hold_for_nvim_program() {
        let w = mk_window(
            3,
            Program::Nvim {
                session_vim: PathBuf::from("/tmp/s.vim"),
                manifest: None,
                truncated_buffers: 0,
            },
        );
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 3}'"#;
        let got = patch_launch(line, &by_id);
        assert!(got.contains("--hold"), "nvim must get --hold: {got}");
        assert!(got.ends_with(" nvim -S /tmp/s.vim"), "argv tail: {got}");
    }

    #[test]
    fn patch_skips_duplicate_hold() {
        let w = mk_window(
            4,
            Program::Raw {
                argv: vec!["btop".to_string()],
            },
        );
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch --hold 'kitty-unserialize-data={"id": 4}'"#;
        let got = patch_launch(line, &by_id);
        assert_eq!(
            got.matches("--hold").count(),
            1,
            "--hold deduplicated: {got}"
        );
    }

    #[test]
    fn patch_no_hold_for_shell_program() {
        let w = mk_window(
            5,
            Program::Shell {
                shell: ShellKind::Bash,
                venv: None,
                conda: None,
                direnv: None,
                oldpwd: None,
                scrollback: None,
                history: None,
            },
        );
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 5}'"#;
        let got = patch_launch(line, &by_id);
        assert!(!got.contains("--hold"), "shell must not get --hold: {got}");
    }

    #[test]
    fn patch_handles_two_token_var_form() {
        let w = mk_window(8, Program::BareShell);
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 8}' --var ksession_idx=0 --var keep_me=ok /bin/bash"#;
        let got = patch_launch(line, &by_id);
        assert!(
            !got.contains("ksession_idx"),
            "two-token ksession_idx must be dropped: {got}"
        );
        assert!(
            got.contains("--var keep_me=ok"),
            "two-token user var preserved: {got}"
        );
    }

    #[test]
    fn patch_argv_token_starts_argv_block() {
        // For matched windows, skeleton argv is discarded — even if later
        // tokens look like options, they sit in the argv block once the
        // first non-option non-unserialize token has appeared.
        let w = mk_window(9, Program::BareShell);
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 9}' /old/bin --not-an-option-here"#;
        let got = patch_launch(line, &by_id);
        assert_eq!(got, "launch --var=ksession_id=uid-9 /bin/bash -l");
    }

    #[test]
    fn patch_argv_token_starts_argv_block_unmatched() {
        let by_id: HashMap<u64, &Window> = HashMap::new();
        let line = r#"launch 'kitty-unserialize-data={"id": 9}' /old/bin --not-an-option-here"#;
        let got = patch_launch(line, &by_id);
        assert_eq!(got, "launch /old/bin --not-an-option-here");
    }

    // ----- render: header + pass-through -----

    fn ts() -> chrono::DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 5, 22, 12, 0, 0).unwrap()
    }

    #[test]
    fn render_emits_header() {
        let s = SessionFile {
            name: "demo".to_string(),
            created_at: ts(),
            schema: 1,
            kitty_version: String::new(),
            os_windows: vec![],
        };
        let out = render("", &s).unwrap();
        assert!(out.starts_with(
            "# Description: saved 2026-05-22T12:00:00+00:00\n# Generated by ksession-rs \u{2014} re-save to refresh; restore with: kitty --session this-file\n\n"
        ), "got: {out:?}");
    }

    #[test]
    fn render_passes_through_non_launch_lines() {
        let s = SessionFile {
            name: "x".into(),
            created_at: ts(),
            schema: 1,
            kitty_version: String::new(),
            os_windows: vec![],
        };
        let skel = "new_tab editors\nlayout splits\nenabled_layouts splits,stack\nset_layout_state {\"a\":1}\ncd /home/u\nfocus_tab 0\n";
        let out = render(skel, &s).unwrap();
        for line in skel.lines() {
            assert!(
                out.contains(line),
                "skeleton line missing in output: {line:?}\nout: {out}"
            );
        }
    }

    #[test]
    fn render_strips_kitty_unserialize_data_token() {
        // Plan §C.1 regression: the intra-process reattach token must never
        // appear in the rendered output.
        let w = mk_window(1, Program::BareShell);
        let s = SessionFile {
            name: "test".into(),
            created_at: ts(),
            schema: 1,
            kitty_version: String::new(),
            os_windows: vec![OsWindow {
                tabs: vec![Tab {
                    title: None,
                    layout: "splits".into(),
                    active_window_idx: 0,
                    windows: vec![w],
                }],
            }],
        };
        let skel = "new_tab\nlayout splits\nlaunch 'kitty-unserialize-data={\"id\": 1}' --var=ksession_idx=0 --var=ksession_win=1 /bin/bash -l\nfocus\n";
        let out = render(skel, &s).unwrap();
        assert!(
            !out.contains("kitty-unserialize-data"),
            "must not remain in output: {out}"
        );
        assert!(
            !out.contains("ksession_idx"),
            "must drop legacy ksession_idx: {out}"
        );
        assert!(
            !out.contains("ksession_win"),
            "must drop legacy ksession_win: {out}"
        );
        assert!(
            out.contains("--var=ksession_id=uid-1"),
            "must tag with ksession_id: {out}"
        );
    }

    #[test]
    fn render_drops_filtered_save_prompt_overlay_line() {
        // Regression: the ctrl+space>shift+s save-prompt is an overlay window
        // that kitty's session skeleton lists (id 7 here) but `filter_windows`
        // excludes from the captured model. It must NOT survive into the conf,
        // or restore re-spawns the save-prompt. `set_layout_state` keeps the
        // dangling id 7 — kitty ignores it — so the blob is passed through.
        let w = mk_window(5, Program::BareShell);
        let s = SessionFile {
            name: "nvim".into(),
            created_at: ts(),
            schema: 1,
            kitty_version: String::new(),
            os_windows: vec![OsWindow {
                tabs: vec![Tab {
                    title: None,
                    layout: "splits".into(),
                    active_window_idx: 0,
                    windows: vec![w],
                }],
            }],
        };
        let skel = "new_tab nvim\nlayout splits\nset_layout_state {\"window_groups\": [{\"id\": 4, \"window_ids\": [5, 7]}]}\nlaunch 'kitty-unserialize-data={\"id\": 5}' /bin/bash -l\nlaunch --type=overlay 'kitty-unserialize-data={\"id\": 7}' /home/andrew/.config/kitty/scripts/ksession-save-prompt.sh\nfocus\n";
        let out = render(skel, &s).unwrap();
        assert!(
            !out.contains("ksession-save-prompt.sh"),
            "save-prompt overlay must be dropped: {out}"
        );
        assert!(
            !out.contains("--type=overlay"),
            "no overlay launch line should remain: {out}"
        );
        // The real window survives, and the opaque layout blob is untouched.
        assert!(out.contains("--var=ksession_id=uid-5"), "got: {out}");
        assert!(out.contains("\"window_ids\": [5, 7]"), "got: {out}");
    }

    #[test]
    fn render_keeps_overlay_substring_inside_argv() {
        // A `--type=overlay` substring buried in an argv command string must
        // NOT trigger the overlay drop — only the option region is scanned.
        // Use an unmatched window (empty model) so only the option-region scan
        // — not the by_id gate — decides whether the line survives.
        let s = SessionFile {
            name: "x".into(),
            created_at: ts(),
            schema: 1,
            kitty_version: String::new(),
            os_windows: vec![],
        };
        let skel = "new_tab\nlayout splits\nlaunch 'kitty-unserialize-data={\"id\": 99}' /bin/sh -c 'echo --type=overlay'\nfocus\n";
        let out = render(skel, &s).unwrap();
        assert!(
            out.contains("echo"),
            "argv with an overlay substring must be kept, not dropped: {out}"
        );
    }

    #[test]
    fn render_skeleton_without_trailing_newline_preserved() {
        let s = SessionFile {
            name: "x".into(),
            created_at: ts(),
            schema: 1,
            kitty_version: String::new(),
            os_windows: vec![],
        };
        let skel = "focus_tab 0";
        let out = render(skel, &s).unwrap();
        assert!(
            out.ends_with("focus_tab 0"),
            "out must end with skeleton line: {out:?}"
        );
    }

    #[test]
    fn render_program_less_clamps_at_99_pct() {
        let w = mk_window(
            2,
            Program::Less {
                file: PathBuf::from("/tmp/x"),
                byte_offset: 2_000_000,
                file_size: 1_000_000,
            },
        );
        let s = SessionFile {
            name: "less".into(),
            created_at: ts(),
            schema: 1,
            kitty_version: String::new(),
            os_windows: vec![OsWindow {
                tabs: vec![Tab {
                    title: None,
                    layout: "splits".into(),
                    active_window_idx: 0,
                    windows: vec![w],
                }],
            }],
        };
        let skel = "launch 'kitty-unserialize-data={\"id\": 2}'\n";
        let out = render(skel, &s).unwrap();
        assert!(out.contains("'+99%'"), "less must clamp at +99%: {out}");
        assert!(!out.contains("+100%"), "less must not emit +100%: {out}");
    }

    #[test]
    fn render_program_tmux_emits_restore_sh_only() {
        let w = Window {
            kitty_id: 5,
            ksession_id: "uid-5".into(),
            cwd: None,
            program: Program::Tmux {
                session_name: "work".into(),
                restore_sh: PathBuf::from("/tmp/restore.sh"),
                windows: vec![TmuxWindow {
                    idx: 0,
                    name: "main".into(),
                    layout: "a,80x24,0,0,0".into(),
                    active: true,
                    panes: vec![],
                    active_pane_idx: None,
                    layout_leaf_count: 1,
                }],
                session_id: 0,
                active_window_idx: Some(0),
            },
            scrollback: None,
        };
        let s = SessionFile {
            name: "t".into(),
            created_at: ts(),
            schema: 1,
            kitty_version: String::new(),
            os_windows: vec![OsWindow {
                tabs: vec![Tab {
                    title: None,
                    layout: "splits".into(),
                    active_window_idx: 0,
                    windows: vec![w],
                }],
            }],
        };
        let skel = "launch 'kitty-unserialize-data={\"id\": 5}'\n";
        let out = render(skel, &s).unwrap();
        assert!(
            out.contains("/bin/bash /tmp/restore.sh"),
            "tmux argv: {out}"
        );
        assert!(!out.contains("main"), "tmux window metadata leaked: {out}");
        assert!(!out.contains("80x24"), "tmux layout leaked: {out}");
    }

    #[test]
    fn render_program_shell_with_venv_and_oldpwd() {
        let w = Window {
            kitty_id: 6,
            ksession_id: "uid-6".into(),
            cwd: None,
            program: Program::Shell {
                shell: ShellKind::Bash,
                venv: Some(PathBuf::from("/home/u/.venv")),
                conda: None,
                direnv: None,
                oldpwd: Some(PathBuf::from("/tmp")),
                scrollback: None,
                history: None,
            },
            scrollback: None,
        };
        let s = SessionFile {
            name: "sh".into(),
            created_at: ts(),
            schema: 1,
            kitty_version: String::new(),
            os_windows: vec![OsWindow {
                tabs: vec![Tab {
                    title: None,
                    layout: "splits".into(),
                    active_window_idx: 0,
                    windows: vec![w],
                }],
            }],
        };
        let skel = "launch 'kitty-unserialize-data={\"id\": 6}'\n";
        let out = render(skel, &s).unwrap();
        assert!(
            out.contains(r"/bin/bash -l -c 'source /home/u/.venv/bin/activate; export OLDPWD=/tmp; exec bash'"),
            "shell -c pre-command: {out}"
        );
    }

    #[test]
    fn render_program_raw_with_quoted_args() {
        let w = Window {
            kitty_id: 7,
            ksession_id: "uid-7".into(),
            cwd: None,
            program: Program::Raw {
                argv: vec!["echo".into(), "let's go".into(), "a;b".into()],
            },
            scrollback: None,
        };
        let s = SessionFile {
            name: "r".into(),
            created_at: ts(),
            schema: 1,
            kitty_version: String::new(),
            os_windows: vec![OsWindow {
                tabs: vec![Tab {
                    title: None,
                    layout: "splits".into(),
                    active_window_idx: 0,
                    windows: vec![w],
                }],
            }],
        };
        let skel = "launch 'kitty-unserialize-data={\"id\": 7}'\n";
        let out = render(skel, &s).unwrap();
        assert!(
            out.contains(r"echo 'let'\''s go' 'a;b'"),
            "raw argv must be kq-quoted: {out}"
        );
        assert!(out.contains("--hold"), "raw must get --hold: {out}");
    }

    // Real-world skeleton sourced from a live `/tmp/kitty-*` instance
    // (committed under tests/fixtures/kitty-session/live.skel).
    const LIVE_SKEL: &str = include_str!("../../tests/fixtures/kitty-session/live.skel");

    #[test]
    fn render_live_skeleton_round_trip_no_orphans() {
        // Even with an empty SessionFile, the live skeleton must come
        // through cleanly: every kitty-unserialize-data token and every
        // ksession-owned var stripped, every non-launch line verbatim.
        let s = SessionFile {
            name: "live".into(),
            created_at: ts(),
            schema: 1,
            kitty_version: String::new(),
            os_windows: vec![],
        };
        let out = render(LIVE_SKEL, &s).unwrap();
        assert!(
            !out.contains("kitty-unserialize-data"),
            "no unserialize-data may leak: {out}"
        );
        assert!(
            !out.contains("ksession_idx"),
            "no legacy ksession_idx may leak"
        );
        assert!(
            !out.contains("ksession_win"),
            "no legacy ksession_win may leak"
        );
        assert!(
            out.contains("set_layout_state "),
            "set_layout_state preserved"
        );
        assert!(out.contains("focus_tab"), "focus_tab preserved");
    }

    // ----- round-2 hardening regressions -----

    #[test]
    fn patch_drops_malformed_unserialize_token() {
        // Round-2 finding: a token starting with `kitty-unserialize-data=`
        // but whose JSON fails to parse must still be dropped — never leak
        // into argv on the unmatched-window path.
        let by_id: HashMap<u64, &Window> = HashMap::new();
        for malformed in [
            "kitty-unserialize-data=garbage",
            r#"kitty-unserialize-data={"id":"x"}"#, // non-numeric id
            r#"kitty-unserialize-data={}"#,         // missing id key
        ] {
            let line = format!("launch '{malformed}' /bin/bash -l");
            let got = patch_launch(&line, &by_id);
            assert!(
                !got.contains("kitty-unserialize-data"),
                "malformed unserialize token must still be stripped: input={line:?} got={got:?}"
            );
            assert_eq!(
                got, "launch /bin/bash -l",
                "argv must survive: input={line:?}"
            );
        }
    }

    #[test]
    fn patch_drops_two_token_ksession_id_var() {
        // Test gap: two-token form `--var ksession_id=old` must be dropped
        // so the new `--var=ksession_id=<uuid>` from the renderer doesn't
        // duplicate or shadow a stale value.
        let w = mk_window(11, Program::BareShell);
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line =
            r#"launch 'kitty-unserialize-data={"id": 11}' --var ksession_id=stale-uid /bin/bash"#;
        let got = patch_launch(line, &by_id);
        assert!(
            !got.contains("stale-uid"),
            "two-token ksession_id must be dropped: {got}"
        );
        assert_eq!(
            got.matches("ksession_id").count(),
            1,
            "exactly one ksession_id var: {got}"
        );
        assert!(
            got.contains("--var=ksession_id=uid-11"),
            "new tag emitted: {got}"
        );
    }

    #[test]
    fn unserialize_id_handles_u64_above_u32_max() {
        // Test gap: kitty's window id counter is u64; a long-running
        // instance can exceed u32::MAX. extract_unserialize_id and
        // patch_launch must round-trip a >u32 id.
        let big: u64 = u64::from(u32::MAX) + 1; // 4_294_967_296
        assert_eq!(
            extract_unserialize_id(&format!(r#"kitty-unserialize-data={{"id": {big}}}"#)),
            Some(big)
        );
        let w = mk_window(big, Program::BareShell);
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = format!(r#"launch 'kitty-unserialize-data={{"id": {big}}}'"#);
        let got = patch_launch(&line, &by_id);
        assert!(
            got.contains(&format!("uid-{big}")),
            "big-id window matched: {got}"
        );
    }

    #[test]
    fn patch_preserves_eq_form_cwd_only() {
        // Contract: only `--key=value` (single-token) is supported for
        // option preservation. Kitty's own `ls --output-format=session`
        // always emits `--cwd=PATH` (single-token), so two-token
        // `--cwd PATH` is out of scope. `--var KEY=VALUE` (two-token) is
        // the one exception, recognised so we can drop stale ksession-
        // owned vars regardless of which form a hand-edited skeleton uses.
        let w = mk_window(12, Program::BareShell);
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 12}' --cwd=/home/u /bin/bash"#;
        let got = patch_launch(line, &by_id);
        assert!(
            got.contains("--cwd=/home/u"),
            "single-token --cwd= must be preserved: {got}"
        );
    }

    #[test]
    fn render_detects_tab_separated_launch_line() {
        // Round-2 finding: launch detection must tolerate tabs after
        // "launch". Kitty emits with a single space, but our patcher
        // shouldn't fall over if a hand-edited skeleton has tabs.
        let w = mk_window(13, Program::BareShell);
        let s = SessionFile {
            name: "tab".into(),
            created_at: ts(),
            schema: 1,
            kitty_version: String::new(),
            os_windows: vec![OsWindow {
                tabs: vec![Tab {
                    title: None,
                    layout: "splits".into(),
                    active_window_idx: 0,
                    windows: vec![w],
                }],
            }],
        };
        let skel = "launch\t'kitty-unserialize-data={\"id\": 13}'\t/old/bin\n";
        let out = render(skel, &s).unwrap();
        assert!(
            !out.contains("kitty-unserialize-data"),
            "tab-separated launch line must still be patched: {out}"
        );
        assert!(
            out.contains("--var=ksession_id=uid-13"),
            "tab-separated launch must get its UUID tag: {out}"
        );
    }

    #[test]
    fn is_launch_line_distinguishes_prefix_collisions() {
        // Helper test for the renamed launch detector.
        assert!(is_launch_line("launch"));
        assert!(is_launch_line("launch foo bar"));
        assert!(is_launch_line("launch\tfoo"));
        assert!(is_launch_line("  launch foo"));
        assert!(!is_launch_line("launcher"));
        assert!(!is_launch_line("launch_attempt"));
        assert!(!is_launch_line("# launch …"));
        assert!(!is_launch_line(""));
        assert!(!is_launch_line("new_tab launch"));
    }

    #[test]
    fn render_crlf_line_endings_treated_as_one_line() {
        // Test gap: a Windows-style CRLF skeleton. `split_inclusive('\n')`
        // yields each line WITH its trailing `\n`; the `\r` ends up as the
        // last char of `body`. We don't normalize: `\r` is preserved in
        // pass-through lines (acceptable), and launch detection still
        // matches because the leading whitespace check ignores trailing
        // `\r`. Verify the launch is still patched.
        let w = mk_window(14, Program::BareShell);
        let s = SessionFile {
            name: "crlf".into(),
            created_at: ts(),
            schema: 1,
            kitty_version: String::new(),
            os_windows: vec![OsWindow {
                tabs: vec![Tab {
                    title: None,
                    layout: "splits".into(),
                    active_window_idx: 0,
                    windows: vec![w],
                }],
            }],
        };
        let skel = "new_tab\r\nlaunch 'kitty-unserialize-data={\"id\": 14}'\r\n";
        let out = render(skel, &s).unwrap();
        // Note: the patched launch line does NOT preserve the original `\r`
        // because patch_launch rebuilds the line; only pass-through lines
        // keep CRLF. Document this as the contract.
        assert!(
            !out.contains("kitty-unserialize-data"),
            "CRLF launch line must still be patched: {out}"
        );
        assert!(
            out.contains("--var=ksession_id=uid-14"),
            "CRLF launch must get its UUID tag: {out}"
        );
    }

    #[test]
    fn render_rejects_pre_040_kitty_json_output() {
        // Round-2 finding: pre-0.40 kitty ignores --output-format=session
        // and returns JSON. render() must reject loudly rather than feed
        // JSON to the patcher.
        let s = SessionFile {
            name: "x".into(),
            created_at: ts(),
            schema: 1,
            kitty_version: String::new(),
            os_windows: vec![],
        };
        let json_like = "[{\"id\": 1, \"tabs\": []}]\n";
        let err = render(json_like, &s).expect_err("JSON input must error");
        let msg = err.to_string();
        assert!(
            msg.contains("session format") || msg.contains("0.40"),
            "error must explain the version issue: {msg}"
        );
    }

    #[test]
    fn render_rejects_object_top_level_too() {
        // Some kitties emit a single object instead of an array. Same gate.
        let s = SessionFile {
            name: "x".into(),
            created_at: ts(),
            schema: 1,
            kitty_version: String::new(),
            os_windows: vec![],
        };
        let obj_like = "{\"error\": \"bad request\"}\n";
        assert!(render(obj_like, &s).is_err(), "object-top-level must error");
    }

    // ----- G1: defensive late-position unserialize stripping -----

    #[test]
    fn patch_strips_late_position_unserialize_token() {
        // Unmatched window: a hand-edited skeleton that puts the unserialize
        // token AFTER the first argv token must not leak it through.
        let by_id: HashMap<u64, &Window> = HashMap::new();
        let line = r#"launch /old/argv first 'kitty-unserialize-data={"id": 42}' second"#;
        let got = patch_launch(line, &by_id);
        assert!(
            !got.contains("kitty-unserialize-data"),
            "late-position token must be stripped: {got}"
        );
        assert_eq!(got, "launch /old/argv first second");
    }

    #[test]
    fn patch_strips_late_position_unserialize_token_matched() {
        // Matched window: same shape, but argv is replaced from Program.
        let w = mk_window(42, Program::BareShell);
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch /old/argv first 'kitty-unserialize-data={"id": 42}' second"#;
        let got = patch_launch(line, &by_id);
        assert!(
            !got.contains("kitty-unserialize-data"),
            "late-position token must be stripped on matched path too: {got}"
        );
        assert_eq!(got, "launch --var=ksession_id=uid-42 /bin/bash -l");
    }

    // ----- G2: matched-window + skeleton --cwd= preservation -----

    #[test]
    fn patch_preserves_cwd_when_matched_window_replaces_argv() {
        let w = mk_window(20, Program::BareShell);
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 20}' --cwd=/home/u/proj --var=keep=ok /old/argv"#;
        let got = patch_launch(line, &by_id);
        assert!(got.contains("--cwd=/home/u/proj"), "cwd preserved: {got}");
        assert!(got.contains("--var=keep=ok"), "user var preserved: {got}");
        assert!(
            got.contains("--var=ksession_id=uid-20"),
            "ksession_id tagged: {got}"
        );
        assert!(
            got.ends_with("/bin/bash -l"),
            "argv replaced from Program: {got}"
        );
        assert!(!got.contains("/old/argv"), "skeleton argv discarded: {got}");
        assert!(
            !got.contains("kitty-unserialize-data"),
            "token stripped: {got}"
        );
    }

    // ----- G3: --env and --type pass-through -----

    #[test]
    fn patch_preserves_env_flag() {
        // Both single-token `--env=KEY=VAL` and two-token `--env KEY=VAL`
        // forms must survive — kitty's launch docs accept both, and the
        // two-token form would otherwise be misparsed as starting argv.
        let by_id: HashMap<u64, &Window> = HashMap::new();
        let one = r#"launch --env=FOO=bar /bin/bash -l"#;
        let got_one = patch_launch(one, &by_id);
        assert!(
            got_one.contains("--env=FOO=bar"),
            "single-token --env preserved: {got_one}"
        );
        assert!(got_one.contains("/bin/bash -l"), "argv intact: {got_one}");

        let two = r#"launch --env FOO=bar /bin/bash -l"#;
        let got_two = patch_launch(two, &by_id);
        assert!(
            got_two.contains("--env FOO=bar"),
            "two-token --env preserved: {got_two}"
        );
        assert!(
            got_two.contains("/bin/bash -l"),
            "argv intact after two-token --env: {got_two}"
        );
    }

    #[test]
    fn patch_preserves_type_flag() {
        let by_id: HashMap<u64, &Window> = HashMap::new();
        let window_line = r#"launch --type=window /bin/bash -l"#;
        let got_w = patch_launch(window_line, &by_id);
        assert!(
            got_w.contains("--type=window"),
            "--type=window preserved: {got_w}"
        );

        let tab_line = r#"launch --type=tab /bin/bash -l"#;
        let got_t = patch_launch(tab_line, &by_id);
        assert!(
            got_t.contains("--type=tab"),
            "--type=tab preserved: {got_t}"
        );
    }

    #[test]
    fn render_accepts_skeleton_with_leading_comments() {
        // Comments before the first directive must NOT trip the pre-0.40
        // sniff. Skip blank + `#`-prefixed lines.
        let s = SessionFile {
            name: "x".into(),
            created_at: ts(),
            schema: 1,
            kitty_version: String::new(),
            os_windows: vec![],
        };
        let with_comments = "# a comment\n\n# another\nnew_tab\nfocus_tab 0\n";
        let out = render(with_comments, &s).unwrap();
        assert!(out.contains("new_tab"), "ok skeleton must pass: {out}");
    }

    // ----- scrollback replay wrapping (Slice 3) -----

    #[test]
    fn scrollback_only() {
        // Program::Shell with scrollback but no venv/conda/oldpwd must
        // wrap the shell in -c with `cat <path> 2>/dev/null; exec <shell>`.
        let w = mk_window(
            30,
            Program::Shell {
                shell: ShellKind::Zsh,
                venv: None,
                conda: None,
                direnv: None,
                oldpwd: None,
                scrollback: Some(PathBuf::from("/tmp/scrollback.ansi")),
                history: None,
            },
        );
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 30}'"#;
        let got = patch_launch(line, &by_id);
        assert_eq!(
            got,
            "launch --var=ksession_id=uid-30 /bin/zsh -l -c 'cat /tmp/scrollback.ansi 2>/dev/null; exec zsh'"
        );
    }

    #[test]
    fn scrollback_plus_venv() {
        // scrollback + venv: cat comes BEFORE source .../activate.
        let w = mk_window(
            31,
            Program::Shell {
                shell: ShellKind::Bash,
                venv: Some(PathBuf::from("/home/u/.venv")),
                conda: None,
                direnv: None,
                oldpwd: None,
                scrollback: Some(PathBuf::from("/tmp/sb.ansi")),
                history: None,
            },
        );
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 31}'"#;
        let got = patch_launch(line, &by_id);
        assert_eq!(
            got,
            "launch --var=ksession_id=uid-31 /bin/bash -l -c 'cat /tmp/sb.ansi 2>/dev/null; source /home/u/.venv/bin/activate; exec bash'"
        );
    }

    #[test]
    fn scrollback_plus_oldpwd() {
        // scrollback + oldpwd: cat comes BEFORE export OLDPWD.
        let w = mk_window(
            32,
            Program::Shell {
                shell: ShellKind::Zsh,
                venv: None,
                conda: None,
                direnv: None,
                oldpwd: Some(PathBuf::from("/tmp")),
                scrollback: Some(PathBuf::from("/tmp/sb.ansi")),
                history: None,
            },
        );
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 32}'"#;
        let got = patch_launch(line, &by_id);
        assert_eq!(
            got,
            "launch --var=ksession_id=uid-32 /bin/zsh -l -c 'cat /tmp/sb.ansi 2>/dev/null; export OLDPWD=/tmp; exec zsh'"
        );
    }

    #[test]
    fn scrollback_plus_venv_plus_oldpwd() {
        // All three: scrollback + venv + oldpwd chain correctly.
        let w = mk_window(
            33,
            Program::Shell {
                shell: ShellKind::Bash,
                venv: Some(PathBuf::from("/home/u/.venv")),
                conda: None,
                direnv: None,
                oldpwd: Some(PathBuf::from("/old")),
                scrollback: Some(PathBuf::from("/tmp/sb.ansi")),
                history: None,
            },
        );
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 33}'"#;
        let got = patch_launch(line, &by_id);
        assert_eq!(
            got,
            "launch --var=ksession_id=uid-33 /bin/bash -l -c 'cat /tmp/sb.ansi 2>/dev/null; source /home/u/.venv/bin/activate; export OLDPWD=/old; exec bash'"
        );
    }

    #[test]
    fn scrollback_none() {
        // scrollback: None renders identically to today (regression test).
        let w = mk_window(
            34,
            Program::Shell {
                shell: ShellKind::Zsh,
                venv: None,
                conda: None,
                direnv: None,
                oldpwd: None,
                scrollback: None,
                history: None,
            },
        );
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 34}'"#;
        let got = patch_launch(line, &by_id);
        assert_eq!(got, "launch --var=ksession_id=uid-34 /bin/zsh -l");
    }

    // ----- Slice 7: --no-scrollback gating verification -----

    #[test]
    fn no_scrollback_flag_clears_scrollback_on_resave() {
        // Simulates the "re-save with --no-scrollback" edge case from PRD-0013
        // Slice 7: a session saved WITHOUT --no-scrollback (scrollback captured)
        // is later re-saved WITH --no-scrollback (scrollback NOT captured). The
        // first render must include `cat <path>`, the second must NOT — even
        // though the old scrollback files may still exist on disk.
        //
        // The gating is structural: Program::Shell.scrollback is None when the
        // save omits scrollback, so the renderer never sees the path. This test
        // pins that contract.
        let first_save = mk_window(
            40,
            Program::Shell {
                shell: ShellKind::Bash,
                venv: None,
                conda: None,
                direnv: None,
                oldpwd: None,
                scrollback: Some(PathBuf::from("/tmp/state/scrollback-40.ansi")),
                history: None,
            },
        );
        let second_save = mk_window(
            41,
            Program::Shell {
                shell: ShellKind::Bash,
                venv: None,
                conda: None,
                direnv: None,
                oldpwd: None,
                scrollback: None,
                history: None,
            },
        );

        let by_id_first = by_id_of(std::slice::from_ref(&first_save));
        let line_first = r#"launch 'kitty-unserialize-data={"id": 40}'"#;
        let got_first = patch_launch(line_first, &by_id_first);

        let by_id_second = by_id_of(std::slice::from_ref(&second_save));
        let line_second = r#"launch 'kitty-unserialize-data={"id": 41}'"#;
        let got_second = patch_launch(line_second, &by_id_second);

        // First save: scrollback present → cat command in output.
        assert!(
            got_first.contains("cat /tmp/state/scrollback-40.ansi"),
            "first save must include scrollback cat: {got_first}"
        );
        // Second save (re-save with --no-scrollback): no scrollback → no cat.
        assert!(
            !got_second.contains("cat"),
            "re-save with --no-scrollback must NOT include cat: {got_second}"
        );
        assert!(
            !got_second.contains("scrollback"),
            "re-save with --no-scrollback must NOT reference scrollback: {got_second}"
        );
    }

    #[test]
    fn scrollback_none_with_history_some_are_independent() {
        // PRD-0013 Slice 7 Test 4: --no-scrollback must NOT affect history.
        // When scrollback is None but history is Some, the conf output must
        // contain NO cat/scrollback references. (The history field is not
        // consumed in conf rendering — it rides on the shell adapter's
        // HISTFILE env-var mechanism — but the test pins that history: Some
        // does not accidentally trigger scrollback replay.)
        let w = mk_window(
            42,
            Program::Shell {
                shell: ShellKind::Bash,
                venv: None,
                conda: None,
                direnv: None,
                oldpwd: None,
                scrollback: None,
                history: Some(PathBuf::from("/tmp/state/history-42.txt")),
            },
        );
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 42}'"#;
        let got = patch_launch(line, &by_id);

        // No scrollback replay.
        assert!(
            !got.contains("cat"),
            "scrollback: None must suppress cat even with history: Some: {got}"
        );
        assert!(
            !got.contains("scrollback"),
            "no scrollback reference expected: {got}"
        );
        // Confirm the shell still renders (not an empty line).
        assert!(
            got.contains("/bin/bash -l"),
            "bare shell with no activation context renders as /bin/bash -l: {got}"
        );
    }

    #[test]
    fn scrollback_path_with_spaces() {
        // Path with spaces must be properly kq-quoted inside the -c string.
        // kq(path) produces `'/tmp/my session/scrollback.ansi'`, which is
        // embedded in the -c command, then the whole -c arg is kq-quoted
        // again. The embedded single quotes become `'\''`.
        let w = mk_window(
            35,
            Program::Shell {
                shell: ShellKind::Bash,
                venv: None,
                conda: None,
                direnv: None,
                oldpwd: None,
                scrollback: Some(PathBuf::from("/tmp/my session/scrollback.ansi")),
                history: None,
            },
        );
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 35}'"#;
        let got = patch_launch(line, &by_id);
        // The -c argument, before outer kq quoting, is:
        //   cat '/tmp/my session/scrollback.ansi' 2>/dev/null; exec bash
        // After kq wraps in single quotes (escaping embedded ' as '\''):
        //   'cat '\''/tmp/my session/scrollback.ansi'\'' 2>/dev/null; exec bash'
        assert_eq!(
            got,
            r"launch --var=ksession_id=uid-35 /bin/bash -l -c 'cat '\''/tmp/my session/scrollback.ansi'\'' 2>/dev/null; exec bash'"
        );
    }

    // ----- HISTFILE env override (Slice 5) -----

    #[test]
    fn history_present() {
        // Program::Shell with history: Some(path) must emit --env HISTFILE=<path>
        // as a launch-line option (before argv).
        let w = mk_window(
            40,
            Program::Shell {
                shell: ShellKind::Bash,
                venv: None,
                conda: None,
                direnv: None,
                oldpwd: None,
                scrollback: None,
                history: Some(PathBuf::from("/tmp/state/history-42.txt")),
            },
        );
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 40}'"#;
        let got = patch_launch(line, &by_id);
        assert_eq!(
            got,
            "launch --var=ksession_id=uid-40 --env HISTFILE=/tmp/state/history-42.txt /bin/bash -l"
        );
    }

    #[test]
    fn history_none() {
        // history: None must NOT emit any --env HISTFILE (regression guard).
        let w = mk_window(
            41,
            Program::Shell {
                shell: ShellKind::Zsh,
                venv: None,
                conda: None,
                direnv: None,
                oldpwd: None,
                scrollback: None,
                history: None,
            },
        );
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 41}'"#;
        let got = patch_launch(line, &by_id);
        assert!(
            !got.contains("HISTFILE"),
            "history: None must not emit HISTFILE: {got}"
        );
        assert!(
            !got.contains("--env"),
            "history: None must not emit --env: {got}"
        );
        assert_eq!(got, "launch --var=ksession_id=uid-41 /bin/zsh -l");
    }

    #[test]
    fn history_path_with_spaces() {
        // Path containing spaces must be kq-quoted in the HISTFILE= value.
        let w = mk_window(
            42,
            Program::Shell {
                shell: ShellKind::Bash,
                venv: None,
                conda: None,
                direnv: None,
                oldpwd: None,
                scrollback: None,
                history: Some(PathBuf::from("/tmp/my session/history.txt")),
            },
        );
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 42}'"#;
        let got = patch_launch(line, &by_id);
        // kq wraps the whole "HISTFILE=/tmp/my session/history.txt" in single quotes.
        assert_eq!(
            got,
            "launch --var=ksession_id=uid-42 --env 'HISTFILE=/tmp/my session/history.txt' /bin/bash -l"
        );
    }

    #[test]
    fn scrollback_plus_history_plus_venv() {
        // All three features compose correctly: --env HISTFILE=... as a
        // launch option, scrollback `cat` in the -c arg, venv `source` in
        // the -c arg.
        let w = mk_window(
            43,
            Program::Shell {
                shell: ShellKind::Bash,
                venv: Some(PathBuf::from("/home/u/.venv")),
                conda: None,
                direnv: None,
                oldpwd: None,
                scrollback: Some(PathBuf::from("/tmp/sb.ansi")),
                history: Some(PathBuf::from("/tmp/state/history-43.txt")),
            },
        );
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 43}'"#;
        let got = patch_launch(line, &by_id);
        assert_eq!(
            got,
            "launch --var=ksession_id=uid-43 --env HISTFILE=/tmp/state/history-43.txt /bin/bash -l -c 'cat /tmp/sb.ansi 2>/dev/null; source /home/u/.venv/bin/activate; exec bash'"
        );
    }

    // ----- Scrollback replay for non-Shell programs -----

    #[test]
    fn scrollback_on_raw_program_is_not_replayed() {
        // ADR 0007 addendum: Program::Raw is excluded from the cat-replay
        // wrapper. Raw TUIs (pi/omp/claude) must start on a clean PTY —
        // replaying the ANSI transcript reads as a rerun of the session.
        // Even with a saved scrollback path, the argv is emitted directly.
        let w = Window {
            kitty_id: 50,
            ksession_id: "uid-50".into(),
            cwd: None,
            program: Program::Raw {
                argv: vec!["pi".into()],
            },
            scrollback: Some(PathBuf::from("/tmp/sb/win-50.ansi")),
        };
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 50}'"#;
        let got = patch_launch(line, &by_id);
        assert!(!got.contains("cat"), "no scrollback cat for Raw: {got}");
        assert!(
            !got.contains("/tmp/sb/win-50.ansi"),
            "no scrollback path reference for Raw: {got}"
        );
        assert!(
            !got.contains("/bin/sh -c"),
            "no /bin/sh -c wrapper for Raw: {got}"
        );
        assert!(got.contains("--hold"), "Raw keeps --hold: {got}");
        assert!(
            got.ends_with(" pi --continue"),
            "argv emitted directly, plus resume flag (ADR 0008): {got}"
        );
    }

    #[test]
    fn scrollback_on_nvim_program_still_wraps_argv() {
        // The Raw exclusion is surgical: other non-shell kinds (Nvim here)
        // keep the cat-before-exec replay chain exactly as before.
        let w = Window {
            kitty_id: 53,
            ksession_id: "uid-53".into(),
            cwd: None,
            program: Program::Nvim {
                session_vim: PathBuf::from("/tmp/s.vim"),
                manifest: None,
                truncated_buffers: 0,
            },
            scrollback: Some(PathBuf::from("/tmp/sb/win-53.ansi")),
        };
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 53}'"#;
        let got = patch_launch(line, &by_id);
        assert!(
            got.contains("cat /tmp/sb/win-53.ansi 2>/dev/null"),
            "scrollback cat for Nvim: {got}"
        );
        assert!(
            got.contains("exec nvim -S /tmp/s.vim"),
            "exec original argv: {got}"
        );
        assert!(got.contains("/bin/sh -c"), "wrapped in /bin/sh -c: {got}");
    }

    #[test]
    fn scrollback_on_bare_shell_wraps_argv() {
        let w = Window {
            kitty_id: 51,
            ksession_id: "uid-51".into(),
            cwd: None,
            program: Program::BareShell,
            scrollback: Some(PathBuf::from("/tmp/sb/win-51.ansi")),
        };
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 51}'"#;
        let got = patch_launch(line, &by_id);
        assert!(
            got.contains("cat /tmp/sb/win-51.ansi 2>/dev/null"),
            "scrollback cat for BareShell: {got}"
        );
        assert!(
            got.contains("exec /bin/bash -l"),
            "exec original BareShell argv: {got}"
        );
        assert!(got.contains("/bin/sh -c"), "wrapped in /bin/sh -c: {got}");
    }

    #[test]
    fn no_scrollback_on_raw_program_no_wrapping() {
        let w = Window {
            kitty_id: 52,
            ksession_id: "uid-52".into(),
            cwd: None,
            program: Program::Raw {
                argv: vec!["pi".into()],
            },
            scrollback: None,
        };
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 52}'"#;
        let got = patch_launch(line, &by_id);
        assert!(
            !got.contains("/bin/sh -c"),
            "no wrapper without scrollback: {got}"
        );
        assert!(got.contains("--hold"), "Raw still gets --hold: {got}");
        assert!(
            got.ends_with(" pi --continue"),
            "plain argv plus resume flag (ADR 0008): {got}"
        );
    }

    // ----- agent session resume (ADR 0008) -----

    fn sv(args: &[&str]) -> Vec<String> {
        args.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn agent_resume_each_known_agent_gets_continue() {
        for exe in ["claude", "pi", "opi", "omp"] {
            assert_eq!(
                agent_resume_flag(&sv(&[exe])),
                Some("--continue"),
                "agent {exe} must resume"
            );
        }
    }

    #[test]
    fn agent_resume_matches_basename_of_full_path() {
        assert_eq!(
            agent_resume_flag(&sv(&["/usr/bin/claude"])),
            Some("--continue")
        );
        assert_eq!(
            agent_resume_flag(&sv(&["/home/andrew/.local/bin/opi"])),
            Some("--continue")
        );
    }

    #[test]
    fn agent_resume_looks_past_script_runtime() {
        // Shebang scripts (`#!/usr/bin/env bun`) show up in /proc cmdline as
        // `bun /abs/path/omp`; the agent is argv[1].
        assert_eq!(
            agent_resume_flag(&sv(&["bun", "/home/andrew/.bun/bin/omp"])),
            Some("--continue")
        );
        assert_eq!(
            agent_resume_flag(&sv(&["/usr/bin/node", "/opt/claude/cli.js"])),
            None,
            "argv[1] basename cli.js is not a known agent"
        );
        assert_eq!(
            agent_resume_flag(&sv(&["bun", "/home/andrew/.bun/bin/omp", "--no-session"])),
            None,
            "skip flags still honored behind a runtime"
        );
        // Runtime subcommands/flags are not script paths.
        assert_eq!(agent_resume_flag(&sv(&["bun", "run", "omp"])), None);
        assert_eq!(agent_resume_flag(&sv(&["bun"])), None);
    }

    #[test]
    fn agent_resume_skips_when_already_resuming_or_noninteractive() {
        for argv in [
            sv(&["claude", "-c"]),
            sv(&["claude", "--continue"]),
            sv(&["claude", "--resume=abc"]),
            sv(&["claude", "-r", "abc"]),
            sv(&["claude", "--fork-session"]),
            sv(&["claude", "--from-pr", "42"]),
            sv(&["claude", "-p", "hello"]),
            sv(&["claude", "--print"]),
            sv(&["pi", "--session", "foo"]),
            sv(&["pi", "--session=foo"]),
            sv(&["omp", "--session-id", "abc"]),
            sv(&["opi", "--fork"]),
            sv(&["pi", "--no-session"]),
            sv(&["pi", "-p"]),
        ] {
            assert_eq!(
                agent_resume_flag(&argv),
                None,
                "must not append for {argv:?}"
            );
        }
    }

    #[test]
    fn agent_resume_ignores_non_agent_programs() {
        for argv in [sv(&["btop"]), sv(&["htop"]), sv(&["/usr/bin/btop"]), sv(&[])] {
            assert_eq!(agent_resume_flag(&argv), None, "no resume for {argv:?}");
        }
    }

    #[test]
    fn agent_resume_with_user_args_appends_after_them() {
        // Helper returns the flag; the Raw arm appends it after the argv.
        assert_eq!(
            agent_resume_flag(&sv(&["claude", "--model", "opus"])),
            Some("--continue")
        );
        let w = mk_window(
            60,
            Program::Raw {
                argv: sv(&["claude", "--model", "opus"]),
            },
        );
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 60}'"#;
        let got = patch_launch(line, &by_id);
        assert!(
            got.ends_with(" claude --model opus --continue"),
            "resume flag appended after user args: {got}"
        );
    }

    #[test]
    fn agent_resume_skip_flag_prefix_does_not_false_match() {
        // `--continue-on-error` and `-color` share a prefix with skip flags
        // but are NOT them; the flag must still be appended.
        assert_eq!(
            agent_resume_flag(&sv(&["claude", "--continue-on-error"])),
            Some("--continue")
        );
        assert_eq!(
            agent_resume_flag(&sv(&["pi", "-color"])),
            Some("--continue")
        );
    }

    #[test]
    fn agent_resume_non_agent_raw_render_unchanged() {
        let w = mk_window(
            61,
            Program::Raw {
                argv: sv(&["btop"]),
            },
        );
        let by_id = by_id_of(std::slice::from_ref(&w));
        let line = r#"launch 'kitty-unserialize-data={"id": 61}'"#;
        let got = patch_launch(line, &by_id);
        assert!(
            !got.contains("--continue"),
            "non-agent raw must render unchanged: {got}"
        );
        assert!(got.ends_with(" btop"), "argv intact: {got}");
    }
}
