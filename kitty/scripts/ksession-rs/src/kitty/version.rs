//! Parsing and compatibility comparison for `kitty --version` stdout.
//!
//! Per ADR 0002, every save stamps the running kitty's version onto the
//! manifest. The reader (`session::manifest::read`) compares the captured
//! version against the live one and surfaces a drift warning when their
//! major.minor pair differs — this is the diagnostic that lets a user
//! correlate a weird-looking restore with the version skew that broke it.
//!
//! This module is pure: parsing operates on strings, comparison operates
//! on the parsed structs. The production caller spawns `kitty --version`
//! and hands stdout to [`parse`]; tests can construct [`Version`]
//! literals or call [`parse`] on canned fixtures.

use std::time::Duration;

use tokio::process::Command;
use tokio::time::timeout;

use crate::error::KError;

const FETCH_TIMEOUT: Duration = Duration::from_secs(5);

/// A parsed `kitty --version` stdout line. `raw` preserves whatever
/// kitty actually printed (including dev-build suffixes such as
/// `kitty 0.42.1-rc1`) so the manifest round-trips it verbatim.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Version {
    pub major: u32,
    pub minor: u32,
    pub raw: String,
}

/// Result of [`Version::compat`]. `Same` is the happy path; the other
/// two map onto distinct user-facing warnings.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Compat {
    /// Same major.minor; patch differences are ignored per ADR 0002.
    Same,
    /// Major or minor differs — surface a drift warning.
    MajorMinorDiffers,
    /// Either side failed to parse; we cannot reason about
    /// compatibility, so callers should suppress the drift warning
    /// (we have nothing meaningful to say).
    Unparseable,
}

impl Version {
    /// Compare two parsed versions on (major, minor). Patch and any
    /// dev-build suffix are ignored.
    pub fn compat(&self, other: &Self) -> Compat {
        if self.major == other.major && self.minor == other.minor {
            Compat::Same
        } else {
            Compat::MajorMinorDiffers
        }
    }
}

/// Parse `kitty --version` stdout into a [`Version`].
///
/// Accepted shapes:
///   * `kitty 0.42.0`              → Version { major: 0, minor: 42, raw: "kitty 0.42.0" }
///   * `kitty 0.42.1-rc1`          → Version { major: 0, minor: 42, raw: "kitty 0.42.1-rc1" }
///   * `kitty 0.42`                → Version { major: 0, minor: 42, raw: "kitty 0.42" }
///   * Trailing fields (created by, ...) after the version number are tolerated.
///
/// Anything that doesn't yield two parseable `<digits>.<digits>` numbers
/// returns `Err(KError::KittyRemote)`. The reader treats any parse
/// failure as `Compat::Unparseable` — see [`Version::compat`].
pub fn parse(stdout: &str) -> Result<Version, KError> {
    let trimmed = stdout.trim();
    if trimmed.is_empty() {
        return Err(KError::KittyRemote(
            "kitty --version stdout was empty".to_string(),
        ));
    }

    // The first whitespace-separated token is the program name ("kitty");
    // the second is the version. We tolerate the program name being any
    // non-numeric token so a hypothetical fork still parses.
    let mut tokens = trimmed.split_whitespace();
    let _name = tokens.next();
    let ver_tok = tokens.next().ok_or_else(|| {
        KError::KittyRemote(format!(
            "kitty --version missing version token: {trimmed:?}"
        ))
    })?;

    // Strip any dev-build suffix introduced by a `-`: `0.42.1-rc1` → `0.42.1`.
    let core = ver_tok.split('-').next().unwrap_or(ver_tok);
    let mut parts = core.split('.');
    let major_s = parts.next().ok_or_else(|| {
        KError::KittyRemote(format!("kitty --version: missing major in {ver_tok:?}"))
    })?;
    let minor_s = parts.next().ok_or_else(|| {
        KError::KittyRemote(format!("kitty --version: missing minor in {ver_tok:?}"))
    })?;
    let major: u32 = major_s.parse().map_err(|_| {
        KError::KittyRemote(format!("kitty --version: non-numeric major in {ver_tok:?}"))
    })?;
    let minor: u32 = minor_s.parse().map_err(|_| {
        KError::KittyRemote(format!("kitty --version: non-numeric minor in {ver_tok:?}"))
    })?;

    Ok(Version {
        major,
        minor,
        raw: trimmed.to_string(),
    })
}

/// Like [`parse`] but maps any parse failure to [`Compat::Unparseable`]
/// at the reader's call site. Callers that need the diagnostic should
/// use [`parse`] directly.
fn parse_or_unparseable(stdout: &str) -> Option<Version> {
    parse(stdout).ok()
}

/// Compare two raw version strings (e.g. the manifest-captured value
/// against the live `kitty --version` output). Returns the [`Compat`]
/// classification — any side failing to parse yields
/// [`Compat::Unparseable`].
pub fn compat_strings(captured: &str, running: &str) -> Compat {
    match (
        parse_or_unparseable(captured),
        parse_or_unparseable(running),
    ) {
        (Some(a), Some(b)) => a.compat(&b),
        _ => Compat::Unparseable,
    }
}

/// Spawn `kitty --version` and return its stdout verbatim (with
/// trailing whitespace stripped). Surfaces failures as
/// [`KError::KittyRemote`].
///
/// Distinct from the `kitty @ ...` operations in [`crate::kitty::cli`]:
/// `--version` requires no remote-control permissions and does not
/// connect to a running kitty instance, so we keep it out of the
/// transport enum and call it directly from the save orchestration.
pub async fn fetch_running_version_stdout() -> Result<String, KError> {
    fetch_version_via("kitty").await
}

pub(crate) async fn fetch_version_via(bin: &str) -> Result<String, KError> {
    let fut = Command::new(bin).arg("--version").output();
    let output = match timeout(FETCH_TIMEOUT, fut).await {
        Ok(Ok(out)) => out,
        Ok(Err(e)) => {
            return Err(KError::KittyRemote(format!(
                "spawn `{bin} --version`: {e} (is kitty installed and on PATH?)"
            )));
        }
        Err(_) => {
            return Err(KError::KittyRemote(format!(
                "`{bin} --version` timed out after {}s",
                FETCH_TIMEOUT.as_secs_f32()
            )));
        }
    };

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let body = if stderr.is_empty() {
            match output.status.code() {
                Some(c) => format!("{bin} --version exited with status {c}"),
                None => format!("{bin} --version was killed by a signal"),
            }
        } else {
            stderr
        };
        return Err(KError::KittyRemote(body));
    }

    Ok(String::from_utf8_lossy(&output.stdout)
        .trim_end()
        .to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- parse ---------------------------------------------------------------

    #[test]
    fn parse_full_three_component_version() {
        let v = parse("kitty 0.42.0").expect("parses");
        assert_eq!(v.major, 0);
        assert_eq!(v.minor, 42);
        assert_eq!(v.raw, "kitty 0.42.0");
    }

    #[test]
    fn parse_dev_build_suffix_kept_in_raw() {
        let v = parse("kitty 0.42.1-rc1").expect("parses");
        assert_eq!(v.major, 0);
        assert_eq!(v.minor, 42);
        assert_eq!(
            v.raw, "kitty 0.42.1-rc1",
            "raw must preserve dev-build suffix verbatim (ADR 0002)",
        );
    }

    #[test]
    fn parse_two_component_version() {
        let v = parse("kitty 0.42").expect("parses");
        assert_eq!(v.major, 0);
        assert_eq!(v.minor, 42);
        assert_eq!(v.raw, "kitty 0.42");
    }

    #[test]
    fn parse_trims_trailing_whitespace_in_raw() {
        let v = parse("kitty 0.42.0\n").expect("parses");
        assert_eq!(v.raw, "kitty 0.42.0", "trailing newline trimmed from raw");
    }

    #[test]
    fn parse_garbage_is_error() {
        assert!(parse("garbage").is_err(), "no version token must error");
        assert!(
            parse("kitty zz.yy").is_err(),
            "non-numeric major must error"
        );
        assert!(parse("kitty 0").is_err(), "missing minor must error");
        assert!(parse("").is_err(), "empty input must error");
        assert!(parse("   ").is_err(), "whitespace-only input must error");
    }

    // --- compat --------------------------------------------------------------

    fn v(major: u32, minor: u32) -> Version {
        Version {
            major,
            minor,
            raw: format!("kitty {major}.{minor}"),
        }
    }

    #[test]
    fn compat_same_major_minor() {
        assert_eq!(v(0, 42).compat(&v(0, 42)), Compat::Same);
    }

    #[test]
    fn compat_same_major_minor_patch_ignored() {
        // Patch differences are stripped before parse stores into the
        // struct; comparing two `Version{major:0, minor:42}` values is
        // `Same` regardless of any patch the raw strings might encode.
        let a = parse("kitty 0.42.0").unwrap();
        let b = parse("kitty 0.42.5").unwrap();
        assert_eq!(a.compat(&b), Compat::Same);
    }

    #[test]
    fn compat_minor_diff() {
        assert_eq!(v(0, 42).compat(&v(0, 43)), Compat::MajorMinorDiffers);
    }

    #[test]
    fn compat_major_diff() {
        assert_eq!(v(0, 42).compat(&v(1, 42)), Compat::MajorMinorDiffers);
    }

    #[test]
    fn compat_strings_propagates_unparseable() {
        assert_eq!(
            compat_strings("garbage", "kitty 0.42.0"),
            Compat::Unparseable
        );
        assert_eq!(
            compat_strings("kitty 0.42.0", "garbage"),
            Compat::Unparseable
        );
        assert_eq!(compat_strings("", ""), Compat::Unparseable);
    }

    #[test]
    fn compat_strings_same_pair() {
        assert_eq!(compat_strings("kitty 0.42.0", "kitty 0.42.3"), Compat::Same,);
    }

    #[test]
    fn compat_strings_drift_pair() {
        assert_eq!(
            compat_strings("kitty 0.42.0", "kitty 0.43.0"),
            Compat::MajorMinorDiffers,
        );
    }
}
