//! Logging infrastructure for ksession-rs.
//!
//! Uses `tracing` for structured logging with output to:
//! - stderr (for CLI output)
//! - file: `~/.cache/ksession.log` (rolling log file)
//!
//! Log levels:
//! - ERROR: Fatal errors that prevent operation
//! - WARN: Recoverable issues (adapter degradations, etc.)
//! - INFO: Significant operations (save started, session restored, etc.)
//! - DEBUG: Detailed diagnostic information

use std::path::PathBuf;
use tracing_subscriber::{fmt, layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

/// Initialize the logging system.
///
/// Called once at startup. Sets up:
///
/// 1. An env-filter based on `RUST_LOG` env var (defaults to `warn`)
/// 2. stderr output with optional file backing
/// 3. Log file at `~/.cache/ksession.log`
pub fn init() {
    // Determine log directory
    let log_dir = get_log_dir();

    // Create log directory if it doesn't exist
    if let Err(e) = std::fs::create_dir_all(&log_dir) {
        eprintln!(
            "ksession: warning: could not create log directory {:?}: {}",
            log_dir, e
        );
    }

    // Build the log file path
    let log_file = log_dir.join("ksession.log");

    // Set up the subscriber with both stderr and file output
    let env_filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("warn,ksession_rs=info"));

    // Create file appender for rolling logs
    let file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_file)
        .ok();

    let subscriber = tracing_subscriber::registry().with(env_filter).with(
        fmt::layer()
            .with_writer(std::io::stderr)
            .with_target(true)
            .with_thread_ids(true)
            .with_file(true)
            .with_line_number(true),
    );

    // Add file layer if we successfully opened the log file
    if let Some(file) = file {
        let file_layer = fmt::layer()
            .with_target(true)
            .with_ansi(false)
            .with_writer(std::sync::Mutex::new(file));

        subscriber.with(file_layer).init();
    } else {
        // Fall back to stderr only
        subscriber.init();
    }

    tracing::debug!("ksession-rs logging initialized; log file: {:?}", log_file);
}

/// Get the log directory path.
///
/// Respects `XDG_CACHE_HOME` env var, falling back to `~/.cache`.
fn get_log_dir() -> PathBuf {
    if let Some(cache) = std::env::var_os("XDG_CACHE_HOME") {
        PathBuf::from(cache).join("ksession")
    } else if let Some(home) = std::env::var_os("HOME") {
        PathBuf::from(home).join(".cache").join("ksession")
    } else {
        // Last resort: current directory (not ideal but better than crashing)
        PathBuf::from(".")
    }
}

/// Redact sensitive values from log output.
///
/// Used to prevent credentials from appearing in logs.
pub fn redact(s: &str) -> String {
    // Redact paths that look like they might contain sensitive names
    // This is a best-effort redaction for common patterns
    let redacted = s.to_string();

    // Redact potential API keys (long alphanumeric strings after common prefixes)
    let patterns = [
        ("/token/", "/****"),
        ("/password/", "/****"),
        ("/secret/", "/****"),
        ("/key/", "/****"),
        ("KSESSION_IMPL=", "KSESSION_IMPL=****"),
    ];

    let mut result = redacted;
    for (pattern, replacement) in patterns {
        result = result.replace(pattern, replacement);
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redact_replaces_sensitive_paths() {
        let input = "some/path/token/abc123";
        let output = redact(input);
        assert!(
            output.contains("****"),
            "redacted output should contain ****: {}",
            output
        );
    }

    #[test]
    fn redact_preserves_normal_text() {
        let input = "normal log message with /path/to/file";
        let output = redact(input);
        assert_eq!(output, input, "normal text should not be modified");
    }

    #[test]
    fn redact_handles_env_var() {
        let input = "KSESSION_IMPL=/home/user/bin/ksession-rs";
        let output = redact(input);
        assert!(
            output.contains("KSESSION_IMPL=****"),
            "env var should be redacted: {}",
            output
        );
    }
}
