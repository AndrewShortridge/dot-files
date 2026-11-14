//! `ksession tmux autosave` — throttled `save --auto --all` for hooks.
//!
//! Wired into tmux as `status-right '#(ksession tmux autosave)'` (polled
//! every `status-interval`) and `client-detached` → `autosave --force`.
//! Both callers are fire-and-forget, so this command is silent on stdout
//! (status-right would render it) and cheap on the no-op path: one stat of
//! `<root>/.autosave-stamp` decides whether a sweep is due.
//!
//! The stamp is touched *before* the sweep: the 2-second status tick must
//! not start a second sweep while the first is still saving, and a failed
//! sweep simply waits one interval instead of retrying every tick.

use std::path::Path;
use std::process::ExitCode;
use std::time::{Duration, SystemTime};

use super::{exit_code, resolve_all_targets, save, TmuxSessionError};

/// Basename of the throttle stamp inside the sessions root.
pub const STAMP_FILE: &str = ".autosave-stamp";

/// Sweep when due (or `force`d): save every session on the ambient server
/// under its `auto-*` name, then refresh the stamp. Exit 0 when nothing
/// was due, otherwise the save sweep's own code (0, or 2 when any session
/// degraded or failed — the sweep never aborts on one session, ADR 0001).
pub async fn run(
    root: &Path,
    every: Duration,
    force: bool,
    scrollback: bool,
) -> Result<ExitCode, TmuxSessionError> {
    let _span = crate::perf_span!(
        crate::perf::Level::Info,
        "tmux_session.autosave",
        every_s = every.as_secs(),
        force = force,
    );
    let stamp = root.join(STAMP_FILE);
    if !force && !is_due(stamp_mtime(&stamp), SystemTime::now(), every) {
        return Ok(ExitCode::SUCCESS);
    }
    touch(&stamp)?;
    let degraded = save::save_auto(root, resolve_all_targets().await?, scrollback).await;
    Ok(exit_code(degraded))
}

/// Whether a sweep is due: no stamp yet, or the stamp is at least `every`
/// old. A stamp from the future (clock stepped back) counts as fresh, so
/// a clock jump can never trigger a save storm.
pub fn is_due(stamp_mtime: Option<SystemTime>, now: SystemTime, every: Duration) -> bool {
    match stamp_mtime {
        None => true,
        Some(mtime) => now
            .duration_since(mtime)
            .map(|age| age >= every)
            .unwrap_or(false),
    }
}

/// `--every` syntax: `<N>s`, `<N>m`, `<N>h`, or bare `<N>` seconds. Zero
/// is rejected — it would turn every status tick into a full save.
pub fn parse_every(spec: &str) -> Result<Duration, TmuxSessionError> {
    let spec = spec.trim();
    let (digits, unit_secs) = match spec.as_bytes().last() {
        Some(b's') => (&spec[..spec.len() - 1], 1),
        Some(b'm') => (&spec[..spec.len() - 1], 60),
        Some(b'h') => (&spec[..spec.len() - 1], 3600),
        Some(b) if b.is_ascii_digit() => (spec, 1),
        _ => return Err(invalid_every(spec)),
    };
    let n: u64 = digits.parse().map_err(|_| invalid_every(spec))?;
    if n == 0 {
        return Err(invalid_every(spec));
    }
    Ok(Duration::from_secs(n.saturating_mul(unit_secs)))
}

fn invalid_every(spec: &str) -> TmuxSessionError {
    TmuxSessionError::Other(format!(
        "invalid --every '{spec}' (expected <N>s, <N>m, <N>h or seconds, non-zero)"
    ))
}

fn stamp_mtime(stamp: &Path) -> Option<SystemTime> {
    std::fs::metadata(stamp).and_then(|m| m.modified()).ok()
}

/// Create or bump the stamp's mtime. Writing zero bytes is the portable
/// `touch`: `File::create` truncates and updates mtime on every call.
fn touch(stamp: &Path) -> std::io::Result<()> {
    std::fs::File::create(stamp).map(drop)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    const MIN: Duration = Duration::from_secs(60);

    #[test]
    fn due_when_no_stamp() {
        assert!(is_due(None, SystemTime::now(), MIN));
    }

    #[test]
    fn not_due_while_stamp_is_young() {
        let now = SystemTime::now();
        assert!(!is_due(Some(now - Duration::from_secs(10)), now, MIN));
        assert!(!is_due(Some(now - Duration::from_secs(59)), now, MIN));
    }

    #[test]
    fn due_at_and_after_the_interval() {
        let now = SystemTime::now();
        assert!(is_due(Some(now - MIN), now, MIN));
        assert!(is_due(Some(now - Duration::from_secs(3600)), now, MIN));
    }

    #[test]
    fn stamp_from_the_future_is_fresh() {
        let now = SystemTime::now();
        assert!(!is_due(Some(now + Duration::from_secs(5)), now, MIN));
    }

    #[test]
    fn parse_every_units_and_bare_seconds() {
        assert_eq!(parse_every("90s").unwrap(), Duration::from_secs(90));
        assert_eq!(parse_every("15m").unwrap(), Duration::from_secs(900));
        assert_eq!(parse_every("1h").unwrap(), Duration::from_secs(3600));
        assert_eq!(parse_every("900").unwrap(), Duration::from_secs(900));
        assert_eq!(parse_every(" 2m ").unwrap(), Duration::from_secs(120));
    }

    #[test]
    fn parse_every_rejects_zero_empty_and_unknown_units() {
        for bad in ["", "0", "0m", "m", "15x", "1.5h", "-5", "5 m", "1d"] {
            assert!(
                matches!(parse_every(bad), Err(TmuxSessionError::Other(_))),
                "{bad:?} must be rejected"
            );
        }
    }

    #[test]
    fn touch_creates_then_bumps_mtime() {
        let dir = tempdir().unwrap();
        let stamp = dir.path().join(STAMP_FILE);
        assert_eq!(stamp_mtime(&stamp), None);
        touch(&stamp).unwrap();
        let first = stamp_mtime(&stamp).expect("stamp exists");
        // Backdate, then touch again: mtime must move forward again.
        let old = std::fs::File::options().write(true).open(&stamp).unwrap();
        old.set_modified(first - Duration::from_secs(600)).unwrap();
        drop(old);
        assert!(stamp_mtime(&stamp).unwrap() < first, "backdate must stick");
        touch(&stamp).unwrap();
        assert!(
            stamp_mtime(&stamp).unwrap() >= first,
            "touch must refresh mtime"
        );
    }
}
