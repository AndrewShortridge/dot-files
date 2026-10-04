//! Single chokepoint for loading `manifest.json` off disk.
//!
//! `restore`, `list`, and `show` all need the same combination of:
//!   1. Read the file (NotFound → `KError::NotFound`).
//!   2. Parse the JSON.
//!   3. Hard-reject any future-incompatible schema bump per ADR 0003
//!      (`KError::SchemaMismatch`).
//!   4. Surface *soft* drift signals as warnings instead of errors —
//!      currently the kitty-version drift from ADR 0002, but the shape
//!      leaves room for future entries (e.g. soft-schema-drift) without
//!      churning every call-site.
//!
//! The reader returns a [`Loaded`] carrying both the deserialised
//! [`SessionFile`] and the (possibly empty) warning list; callers
//! print/format/log warnings however they want.

use std::fs;
use std::path::Path;

use crate::error::KError;
use crate::kitty::version;
use crate::model::SessionFile;

/// Soft drift signal surfaced to the user. Currently the kitty-version
/// drift from ADR 0002 is the only variant, but the enum exists so
/// future additions (e.g. soft schema drift) can land without changing
/// the reader's signature.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Warning {
    /// The manifest's captured `kitty_version` major.minor differs from
    /// the running kitty's. Per ADR 0002 the restore proceeds anyway;
    /// this is purely a diagnostic.
    KittyVersionDrift { captured: String, running: String },
}

impl Warning {
    /// Single-line stderr rendering. Stable so tests can assert against
    /// the exact prefix (`ksession:`) the rest of the binary uses.
    pub fn to_stderr_line(&self) -> String {
        match self {
            Self::KittyVersionDrift { captured, running } => format!(
                "ksession: warning: session captured under {captured:?} but running kitty is {running:?}; restore may behave unexpectedly"
            ),
        }
    }
}

/// Manifest plus any soft warnings surfaced during load.
#[derive(Debug, Clone)]
pub struct Loaded {
    pub session: SessionFile,
    pub warnings: Vec<Warning>,
}

/// Read and validate a manifest file.
///
/// - `Err(KError::NotFound)` if `path` does not exist.
/// - `Err(KError::Io)` for any other IO error.
/// - `Err(KError::Json)` if the file exists but does not parse as a
///   `SessionFile`.
/// - `Err(KError::SchemaMismatch)` if the parsed `schema` exceeds
///   [`SessionFile::CURRENT_SCHEMA`].
/// - `Ok(Loaded { .. })` otherwise. The `warnings` vec is populated by
///   shelling out to `kitty --version` and comparing major.minor; on
///   any parse/spawn failure of the running kitty, the comparison is
///   suppressed (no warning emitted — we have nothing meaningful to
///   say without both sides).
pub async fn read(path: &Path) -> Result<Loaded, KError> {
    let raw = read_file(path)?;
    let session: SessionFile = serde_json::from_slice(&raw)?;

    if session.schema > SessionFile::CURRENT_SCHEMA {
        return Err(KError::SchemaMismatch {
            found: session.schema,
            supported: SessionFile::CURRENT_SCHEMA,
        });
    }

    let mut warnings = Vec::new();
    if !session.kitty_version.is_empty() {
        if let Ok(running) = version::fetch_running_version_stdout().await {
            if matches!(
                version::compat_strings(&session.kitty_version, &running),
                version::Compat::MajorMinorDiffers,
            ) {
                warnings.push(Warning::KittyVersionDrift {
                    captured: session.kitty_version.clone(),
                    running,
                });
            }
        }
        // `kitty --version` failure: silently skip the drift comparison.
        // The reader is called from read-only commands (list/show) where
        // aborting on a missing kitty binary would be unfriendly.
    }

    Ok(Loaded { session, warnings })
}

/// Synchronous variant — same schema check, but never emits any
/// warning that requires spawning a subprocess. Useful where the caller
/// already has the running-kitty stdout (e.g. save, which runs `kitty
/// --version` itself) or doesn't care about drift (e.g. unit tests that
/// just want to round-trip a manifest).
pub fn read_no_drift(path: &Path) -> Result<Loaded, KError> {
    let raw = read_file(path)?;
    let session: SessionFile = serde_json::from_slice(&raw)?;
    if session.schema > SessionFile::CURRENT_SCHEMA {
        return Err(KError::SchemaMismatch {
            found: session.schema,
            supported: SessionFile::CURRENT_SCHEMA,
        });
    }
    Ok(Loaded {
        session,
        warnings: Vec::new(),
    })
}

/// Like [`read`] but accepts the running-kitty version stdout
/// explicitly instead of spawning. The drift comparison still fires —
/// this is what tests use to assert on the warning shape without
/// depending on a real kitty being on `PATH`.
pub fn read_with_running_version(path: &Path, running: &str) -> Result<Loaded, KError> {
    let raw = read_file(path)?;
    let session: SessionFile = serde_json::from_slice(&raw)?;
    if session.schema > SessionFile::CURRENT_SCHEMA {
        return Err(KError::SchemaMismatch {
            found: session.schema,
            supported: SessionFile::CURRENT_SCHEMA,
        });
    }
    let mut warnings = Vec::new();
    if !session.kitty_version.is_empty()
        && matches!(
            version::compat_strings(&session.kitty_version, running),
            version::Compat::MajorMinorDiffers,
        )
    {
        warnings.push(Warning::KittyVersionDrift {
            captured: session.kitty_version.clone(),
            running: running.to_string(),
        });
    }
    Ok(Loaded { session, warnings })
}

fn read_file(path: &Path) -> Result<Vec<u8>, KError> {
    match fs::read(path) {
        Ok(bytes) => Ok(bytes),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            Err(KError::NotFound(path.display().to_string()))
        }
        Err(e) => Err(KError::Io(e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::OsWindow;
    use chrono::{TimeZone, Utc};
    use tempfile::tempdir;

    fn write_manifest(path: &Path, body: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, body).unwrap();
    }

    fn empty_session_json(schema: u32, kitty_version: &str) -> String {
        let s = SessionFile {
            name: "demo".to_string(),
            created_at: Utc.with_ymd_and_hms(2026, 5, 22, 12, 0, 0).unwrap(),
            schema,
            kitty_version: kitty_version.to_string(),
            os_windows: vec![OsWindow { tabs: vec![] }],
        };
        serde_json::to_string(&s).unwrap()
    }

    #[test]
    fn read_no_drift_valid_v1_returns_ok_with_no_warnings() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("manifest.json");
        write_manifest(&p, &empty_session_json(1, "kitty 0.42.0"));
        let loaded = read_no_drift(&p).expect("valid manifest reads");
        assert!(loaded.warnings.is_empty());
        assert_eq!(loaded.session.kitty_version, "kitty 0.42.0");
    }

    #[test]
    fn read_no_drift_missing_optional_fields_uses_serde_defaults() {
        // Manifest written by an older binary that didn't know about
        // `kitty_version`. serde default should fill it with "".
        let dir = tempdir().unwrap();
        let p = dir.path().join("manifest.json");
        let body = r#"{
            "name": "demo",
            "created_at": "2026-05-22T12:00:00Z",
            "schema": 1,
            "os_windows": []
        }"#;
        write_manifest(&p, body);
        let loaded = read_no_drift(&p).expect("manifest without kitty_version still reads");
        assert_eq!(
            loaded.session.kitty_version, "",
            "missing optional kitty_version must default to empty string",
        );
        assert!(loaded.warnings.is_empty());
    }

    #[test]
    fn read_returns_not_found_for_missing_file() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("nonexistent.json");
        let err = read_no_drift(&p).expect_err("missing file must error");
        assert!(matches!(err, KError::NotFound(_)), "got {err:?}");
    }

    #[test]
    fn read_rejects_schema_bump_beyond_current() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("manifest.json");
        write_manifest(&p, &empty_session_json(2, "kitty 0.42.0"));
        let err = read_no_drift(&p).expect_err("schema 2 must reject");
        assert!(
            matches!(
                err,
                KError::SchemaMismatch {
                    found: 2,
                    supported: 1
                }
            ),
            "got {err:?}",
        );
    }

    #[test]
    fn read_with_running_version_emits_drift_on_minor_mismatch() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("manifest.json");
        write_manifest(&p, &empty_session_json(1, "kitty 0.42.0"));
        let loaded = read_with_running_version(&p, "kitty 0.43.0").expect("ok");
        assert_eq!(loaded.warnings.len(), 1);
        match &loaded.warnings[0] {
            Warning::KittyVersionDrift { captured, running } => {
                assert_eq!(captured, "kitty 0.42.0");
                assert_eq!(running, "kitty 0.43.0");
            }
        }
    }

    #[test]
    fn read_with_running_version_no_warning_on_same_major_minor() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("manifest.json");
        write_manifest(&p, &empty_session_json(1, "kitty 0.42.0"));
        let loaded = read_with_running_version(&p, "kitty 0.42.5").expect("ok");
        assert!(
            loaded.warnings.is_empty(),
            "patch-only drift must be silent"
        );
    }

    #[test]
    fn read_with_running_version_no_warning_when_captured_empty() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("manifest.json");
        write_manifest(&p, &empty_session_json(1, ""));
        let loaded = read_with_running_version(&p, "kitty 0.43.0").expect("ok");
        assert!(
            loaded.warnings.is_empty(),
            "empty captured version (older manifest) must suppress drift",
        );
    }

    #[test]
    fn read_with_running_version_no_warning_when_unparseable() {
        let dir = tempdir().unwrap();
        let p = dir.path().join("manifest.json");
        write_manifest(&p, &empty_session_json(1, "garbage"));
        let loaded = read_with_running_version(&p, "kitty 0.43.0").expect("ok");
        assert!(
            loaded.warnings.is_empty(),
            "unparseable captured version must suppress drift (Compat::Unparseable)",
        );
    }

    #[test]
    fn drift_warning_stderr_line_mentions_both_versions() {
        let w = Warning::KittyVersionDrift {
            captured: "kitty 0.42.0".to_string(),
            running: "kitty 0.43.0".to_string(),
        };
        let line = w.to_stderr_line();
        assert!(line.contains("kitty 0.42.0"), "missing captured: {line}");
        assert!(line.contains("kitty 0.43.0"), "missing running: {line}");
        assert!(
            line.starts_with("ksession:"),
            "missing ksession: prefix: {line}"
        );
    }

    #[tokio::test]
    async fn async_read_succeeds_on_valid_manifest_when_kitty_missing() {
        // Async read path tries to spawn `kitty --version`; if not on PATH
        // it should silently suppress drift, not abort the read.
        let dir = tempdir().unwrap();
        let p = dir.path().join("manifest.json");
        write_manifest(&p, &empty_session_json(1, "kitty 0.42.0"));
        // Set PATH to nothing so the kitty spawn fails — drift comparison
        // is silently skipped.
        let prev = std::env::var_os("PATH");
        std::env::set_var("PATH", "");
        let loaded = read(&p).await;
        // Restore PATH before any assertion that could fail and unwind.
        match prev {
            Some(v) => std::env::set_var("PATH", v),
            None => std::env::remove_var("PATH"),
        }
        let loaded = loaded.expect("read must succeed even when kitty --version fails");
        assert!(
            loaded.warnings.is_empty(),
            "kitty --version failure must suppress drift, not surface it",
        );
    }
}
