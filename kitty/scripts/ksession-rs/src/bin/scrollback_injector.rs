//! Scrollback injector binary.
//!
//! Reads `$SCROLLBACK_FILE` env var, outputs scrollback content to stdout,
//! then exec's the remaining arguments (the actual program to run).
//!
//! This enables transparent scrollback replay - the terminal receives the
//! scrollback content before the program starts.

use std::env;
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::unix::process::CommandExt;
use std::process::Command;

fn main() {
    // Get the scrollback file path from environment.
    let scrollback_file = match env::var("SCROLLBACK_FILE") {
        Ok(path) => path,
        Err(env::VarError::NotPresent) => {
            // No scrollback file specified - just exec
            exec_program();
            return;
        }
        Err(env::VarError::NotUnicode(_)) => {
            eprintln!("scrollback_injector: SCROLLBACK_FILE is not valid UTF-8");
            exec_program();
            return;
        }
    };

    // Try to read and output the scrollback file.
    if let Err(e) = read_and_output_scrollback(&scrollback_file) {
        // On error, just proceed with exec (graceful degradation)
        eprintln!(
            "scrollback_injector: warning: could not read scrollback file: {}",
            e
        );
    }

    // Exec the program.
    exec_program();
}

/// Read the scrollback file and output to stdout.
fn read_and_output_scrollback(path: &str) -> io::Result<()> {
    let mut file = File::open(path)?;
    let mut contents = Vec::new();
    file.read_to_end(&mut contents)?;

    // Write to stdout
    io::stdout().write_all(&contents)?;

    // Flush stdout to ensure content is delivered before exec
    io::stdout().flush()?;

    Ok(())
}

/// Exec the program with remaining command-line arguments.
///
/// The first argument is the program, rest are its arguments.
fn exec_program() -> ! {
    // Get the remaining arguments (skip the binary name)
    let args: Vec<_> = env::args().skip(1).collect();

    if args.is_empty() {
        eprintln!("scrollback_injector: no program specified");
        std::process::exit(1);
    }

    let program = &args[0];
    let program_args = &args[1..];

    // Use Command::new to properly handle the exec.
    // This replaces the current process with the new program.
    let err = Command::new(program).args(program_args).exec();

    // If exec returns, it means it failed.
    eprintln!("scrollback_injector: failed to exec '{}': {}", program, err);
    std::process::exit(1);
}
